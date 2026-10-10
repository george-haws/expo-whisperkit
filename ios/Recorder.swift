import AVFoundation
import Foundation
import WhisperKit

typealias LevelEmitter = @Sendable (Float) -> Void
typealias StreamingEmitter = @Sendable (_ confirmed: String, _ pending: String) -> Void

/// Microphone capture (spec §3.3). One session at a time. Push-to-talk accumulates samples in
/// WhisperKit's `AudioProcessor`, which also configures the audio session (playAndRecord,
/// defaultToSpeaker, allowBluetooth) when recording starts.
actor Recorder {
  enum Mode { case idle, recording, streaming }

  private(set) var mode: Mode = .idle
  private let engine: Engine
  private let processor = AudioProcessor()
  /// Audio captured before an interruption or backgrounding, handed to the next `stopRecording`.
  private var pendingSamples: [Float]?
  private var levelTask: Task<Void, Never>?
  private var stopTask: Task<[String: Any], Error>?
  private let emitLevel: LevelEmitter
  let emitStreaming: StreamingEmitter

  // Streaming state (Task 7).
  var streamTranscriber: AudioStreamTranscriber?
  var streamTask: Task<Void, Never>?
  var streamRequest: DecodingRequest?
  /// Set by an interruption while streaming so a later `stopStreaming` can still transcribe the kept audio.
  var streamRequestAfterInterrupt: DecodingRequest?
  /// Set while `startStreaming` awaits the load, and while `endStreaming` tears down.
  private var streamStarting = false
  private var streamEnding = false
  /// An interruption or teardown that arrived while `startStreaming` was loading the model.
  /// Checked once the load returns, before the microphone starts; `.cancel` wins over `.interrupt`.
  private var streamAbortRequested: StreamAbort?
  enum StreamAbort { case interrupt, cancel }
  /// The session whose `startStreaming` is still waiting for the microphone to come up. A capture
  /// loop that throws while this matches the live session is a failed start, not an interruption.
  private var transcriberAwaitingStart: AudioStreamTranscriber?
  /// Recorded by `streamingEnded` after it has torn down a session that failed to start; read
  /// (and cleared) by the `startStreaming` call that owns `transcriber`.
  private var streamStartError: (transcriber: AudioStreamTranscriber, error: Error)?

  init(engine: Engine, emitLevel: @escaping LevelEmitter, emitStreaming: @escaping StreamingEmitter) {
    self.engine = engine
    self.emitLevel = emitLevel
    self.emitStreaming = emitStreaming
  }

  // MARK: Permission

  nonisolated static func permissionStatus() -> String {
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted: return "granted"
    case .denied: return "denied"
    default: return "undetermined"
    }
  }

  nonisolated static func requestPermission() async -> String {
    await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted ? "granted" : "denied")
      }
    }
  }

  // MARK: Push-to-talk

  func startRecording() throws {
    guard mode == .idle else {
      throw WhisperKitError(.busy, "A capture session is already active")
    }
    guard Self.permissionStatus() == "granted" else {
      throw WhisperKitError(.permissionDenied, "Microphone permission has not been granted")
    }
    pendingSamples = nil
    streamRequestAfterInterrupt = nil
    do {
      try processor.startRecordingLive(callback: nil)
    } catch {
      processor.stopRecording()
      deactivateSession()
      throw WhisperKitError(.recordingFailed, "Could not start the microphone: \(error.localizedDescription)", underlying: error)
    }
    mode = .recording
    let processor = self.processor
    startLevelTask { processor.relativeEnergy.last ?? 0 }
  }

  func stopRecording(request: DecodingRequest) async throws -> [String: Any] {
    // Guarantee: a call refused with `busy` keeps the captured audio for a retried
    // `stopRecording`. The in-flight check below runs before any audio is taken, and a `busy`
    // from the engine (a load, a download of the same model, a file transcription or a delete in
    // progress) puts the samples back. Other failures, and `cancelRecording`, discard the audio.
    guard stopTask == nil else {
      throw WhisperKitError(.busy, "A stopRecording call is already in flight")
    }
    let samples: [Float]
    if mode == .recording {
      samples = endCapture()
    } else if let pending = pendingSamples, streamRequestAfterInterrupt == nil {
      pendingSamples = nil
      samples = pending
    } else {
      throw WhisperKitError(.recordingFailed, "Not recording")
    }
    let engine = self.engine
    let task = Task { try await engine.transcribe(samples: samples, request: request) }
    stopTask = task
    defer { stopTask = nil }
    do {
      let result = try await task.value
      if task.isCancelled {
        throw WhisperKitError(.cancelled, "Recording was cancelled")
      }
      return result
    } catch {
      // Whatever the decode threw on its way out, a cancelRecording wins.
      if task.isCancelled {
        throw WhisperKitError(.cancelled, "Recording was cancelled")
      }
      if let error = error as? WhisperKitError, error.code == .busy {
        keepForRetry(samples, streamRequest: nil)
      }
      throw error
    }
  }

  /// The engine refused the final decode with `busy`: keep the audio so a retried stop decodes it.
  /// Skipped if another session has started or kept audio of its own meanwhile.
  private func keepForRetry(_ samples: [Float], streamRequest: DecodingRequest?) {
    guard mode == .idle, pendingSamples == nil, streamRequestAfterInterrupt == nil else { return }
    pendingSamples = samples
    streamRequestAfterInterrupt = streamRequest
  }

  func cancelRecording() {
    if mode == .recording {
      _ = endCapture()
    }
    // Audio kept by a streaming interruption belongs to `stopStreaming`; leave it alone.
    if streamRequestAfterInterrupt == nil {
      pendingSamples = nil
    }
    stopTask?.cancel()
  }

  /// Phone call, Siri, or the app leaving the foreground. Push-to-talk audio is kept for the
  /// next `stopRecording`; a streaming session ends and its audio is kept for the next
  /// `stopStreaming`. A streaming session still loading is aborted before the microphone starts.
  func interrupt() async {
    switch mode {
    case .recording:
      pendingSamples = endCapture()
    case .streaming:
      if streamStarting {
        if streamAbortRequested == nil {
          streamAbortRequested = .interrupt
        }
      } else {
        await interruptStreaming()
      }
    case .idle:
      break
    }
  }

  // MARK: Helpers shared with streaming

  private func endCapture() -> [Float] {
    processor.stopRecording()
    stopLevelTask()
    let samples = Array(processor.audioSamples)
    processor.purgeAudioSamples(keepingLast: 0)
    mode = .idle
    deactivateSession()
    return samples
  }

  func startLevelTask(_ read: @escaping @Sendable () -> Float) {
    let emitLevel = self.emitLevel
    levelTask = Task {
      while !Task.isCancelled {
        emitLevel(min(max(read(), 0), 1))
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  func stopLevelTask() {
    levelTask?.cancel()
    levelTask = nil
  }

  func deactivateSession() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // MARK: Streaming

  /// Starts a live session. Exclusivity on the engine is taken here and released exactly once,
  /// by `endStreaming` (or on a setup failure below).
  func startStreaming(request: DecodingRequest) async throws {
    guard mode == .idle else {
      throw WhisperKitError(.busy, "A capture session is already active")
    }
    guard Self.permissionStatus() == "granted" else {
      throw WhisperKitError(.permissionDenied, "Microphone permission has not been granted")
    }
    pendingSamples = nil
    streamRequestAfterInterrupt = nil
    // Reserve the capture before the first await, so a concurrent start gets `busy`.
    mode = .streaming
    streamStarting = true
    streamAbortRequested = nil
    let instance: WhisperKit
    do {
      instance = try await engine.beginExclusiveLoad(request.model, download: request.download)
    } catch {
      streamStarting = false
      streamAbortRequested = nil
      mode = .idle
      throw error
    }
    if let abort = streamAbortRequested {
      // Interrupted or torn down during the load: never bring the microphone up.
      await engine.endExclusive()
      streamStarting = false
      streamAbortRequested = nil
      mode = .idle
      if abort == .interrupt {
        // Ended without an error, like any interruption; a later `stopStreaming` resolves (empty).
        streamRequestAfterInterrupt = request
        pendingSamples = []
      }
      return
    }
    guard let tokenizer = instance.tokenizer else {
      await engine.endExclusive()
      streamStarting = false
      mode = .idle
      throw WhisperKitError(.loadFailed, "The tokenizer did not load")
    }

    let dedupe = StreamingDedupe()
    let emit = emitStreaming
    let placeholder = Self.waitingPlaceholder
    let transcriber = AudioStreamTranscriber(
      audioEncoder: instance.audioEncoder,
      featureExtractor: instance.featureExtractor,
      segmentSeeker: instance.segmentSeeker,
      textDecoder: instance.textDecoder,
      tokenizer: tokenizer,
      audioProcessor: instance.audioProcessor,
      decodingOptions: request.decodingOptions(tokenizer: tokenizer),
      stateChangeCallback: { _, state in
        let confirmed = state.confirmedSegments.map(\.text).joined()
          .trimmingCharacters(in: .whitespacesAndNewlines)
        // WhisperKit fills `currentText` with a placeholder while it waits for voice; it is not text.
        let current = state.currentText == placeholder ? "" : state.currentText
        let pending = (state.unconfirmedSegments.map(\.text).joined() + " " + current)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if dedupe.changed(confirmed, pending) {
          emit(confirmed, pending)
        }
      }
    )
    streamTranscriber = transcriber
    streamRequest = request
    streamStarting = false
    transcriberAwaitingStart = transcriber
    // The task is assigned below before this actor can run `streamingEnded`, which needs the actor.
    streamTask = Task { [weak self] in
      do {
        // Returns normally when WhisperKit's loop stops itself (a decode error, or its own
        // permission re-check failing) as well as after our own `stopStreamTranscription`.
        try await transcriber.startStreamTranscription()
        await self?.streamingEnded(nil)
      } catch {
        await self?.streamingEnded(error)
      }
    }
    let processor = instance.audioProcessor
    startLevelTask { processor.relativeEnergy.last ?? 0 }
    try await awaitMicrophone(transcriber, processor as? AudioProcessor)
  }

  /// WhisperKit starts the microphone inside `streamTask`, so a failure there would otherwise
  /// surface only as a silent, empty session. Waits up to about one second for the audio engine
  /// to run or the capture loop to fail; on a failure `streamingEnded` has already released the
  /// engine and reset the state, so this only rethrows. A timeout proceeds: slow is not failed.
  private func awaitMicrophone(_ transcriber: AudioStreamTranscriber, _ processor: AudioProcessor?) async throws {
    defer {
      if transcriberAwaitingStart === transcriber {
        transcriberAwaitingStart = nil
      }
    }
    var waited = 0
    while waited < 20 {
      if let failure = streamStartError, failure.transcriber === transcriber {
        streamStartError = nil
        throw WhisperKitError(
          .recordingFailed,
          "Could not start the microphone: \(failure.error.localizedDescription)",
          underlying: failure.error
        )
      }
      if !streamEnding {
        // Ended during the wait (an interruption or a stop): that session's own rules apply.
        if streamTranscriber !== transcriber { return }
        if processor?.audioEngine?.isRunning == true { return }
        waited += 1
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  func stopStreaming() async throws -> [String: Any] {
    if mode != .streaming, let pending = pendingSamples, let request = streamRequestAfterInterrupt {
      pendingSamples = nil
      streamRequestAfterInterrupt = nil
      return try await finalTranscription(pending, request)
    }
    guard mode == .streaming else {
      throw WhisperKitError(.recordingFailed, "Not streaming")
    }
    guard !streamStarting, !streamEnding, let request = streamRequest else {
      throw WhisperKitError(.busy, "The streaming session is starting or already stopping")
    }
    let samples = await endStreaming()
    return try await finalTranscription(samples, request)
  }

  /// No audio (a session aborted while loading, or ended before any buffer arrived) resolves
  /// with empty text instead of asking WhisperKit to decode an empty array.
  private func finalTranscription(_ samples: [Float], _ request: DecodingRequest) async throws -> [String: Any] {
    if samples.isEmpty {
      return ["text": "", "language": request.language ?? "", "segments": [[String: Any]]()]
    }
    do {
      return try await engine.transcribe(samples: samples, request: request)
    } catch let error as WhisperKitError where error.code == .busy {
      keepForRetry(samples, streamRequest: request)
      throw error
    }
  }

  /// Interruption while streaming: end the session; the audio and the request are kept so a
  /// later `stopStreaming` returns a transcription of what was captured.
  func interruptStreaming() async {
    guard isStreamLive else { return }
    streamRequestAfterInterrupt = streamRequest
    pendingSamples = await endStreaming()
  }

  /// Module teardown: end any live session and discard its audio.
  func cancelStreaming() async {
    if mode == .streaming && streamStarting {
      streamAbortRequested = .cancel
    }
    if isStreamLive {
      _ = await endStreaming()
    }
    if streamRequestAfterInterrupt != nil {
      pendingSamples = nil
      streamRequestAfterInterrupt = nil
    }
  }

  /// WhisperKit's capture loop ended on its own: it threw (for example the microphone could not
  /// start) or stopped itself. Ends the session like an interruption, keeping the audio for a later
  /// `stopStreaming`, except while `startStreaming` is still waiting for the microphone: a throw
  /// then is a failed start, recorded for `startStreaming` to reject with, and no audio is kept.
  /// A no-op when the Recorder started the stop (`streamEnding`). It runs inside `streamTask`, so
  /// the task is detached first: `endStreaming` must not await the task it runs in.
  private func streamingEnded(_ error: Error?) async {
    guard isStreamLive, let transcriber = streamTranscriber else { return }
    if let error {
      NSLog("[ExpoWhisperKit] streaming ended with an error: \(error.localizedDescription)")
    }
    let failedStart = error != nil && transcriberAwaitingStart === transcriber
    streamTask = nil
    if failedStart {
      // endStreaming releases the engine's exclusivity (once) and resets the session state.
      _ = await endStreaming()
      if let error {
        streamStartError = (transcriber, error)
      }
      return
    }
    streamRequestAfterInterrupt = streamRequest
    pendingSamples = await endStreaming()
  }

  /// A session that has finished starting and is not already ending.
  private var isStreamLive: Bool {
    mode == .streaming && !streamStarting && !streamEnding && streamTranscriber != nil
  }

  /// Ends the session once: stops the transcriber and the microphone, collects the audio,
  /// deactivates the audio session and releases the engine's exclusivity.
  private func endStreaming() async -> [Float] {
    streamEnding = true
    let transcriber = streamTranscriber
    let task = streamTask
    streamTranscriber = nil
    streamTask = nil
    streamRequest = nil
    if let transcriber {
      await transcriber.stopStreamTranscription()
    }
    await task?.value
    stopLevelTask()
    var samples: [Float] = []
    // Exclusivity is still held, so the instance cannot have been unloaded.
    if let instance = await engine.current {
      instance.audioProcessor.stopRecording()
      samples = Array(instance.audioProcessor.audioSamples)
      instance.audioProcessor.purgeAudioSamples(keepingLast: 0)
    }
    deactivateSession()
    await engine.endExclusive()
    streamEnding = false
    mode = .idle
    return samples
  }

  /// WhisperKit's own placeholder for `currentText`, copied from the `"Waiting for speech..."` strings
  /// in WhisperKit's `AudioStreamTranscriber.swift` (`transcribeCurrentBuffer`). Update if reworded.
  static let waitingPlaceholder = "Waiting for speech..."
}

/// `streamingUpdate` fires only when the text changes (spec §3.4).
final class StreamingDedupe: @unchecked Sendable {
  private var last: (String, String) = ("", "")
  private let lock = NSLock()

  func changed(_ confirmed: String, _ pending: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if last == (confirmed, pending) {
      return false
    }
    last = (confirmed, pending)
    return true
  }
}
