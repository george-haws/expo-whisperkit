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
  /// Push-to-talk capture. Streaming uses the loaded model's own processor instead.
  private let processor: any AudioProcessing
  private let permission: @Sendable () -> String
  /// Audio captured before an interruption or backgrounding, handed to the next `stopRecording`.
  private var pendingSamples: [Float]?
  private var levelTask: Task<Void, Never>?
  private var stopTask: Task<[String: Any], Error>?
  private let emitLevel: LevelEmitter
  let emitStreaming: StreamingEmitter

  // Streaming state (Task 7).
  var streamTranscriber: (any StreamingSession)?
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
  /// The `startStreaming` call still waiting for the microphone to come up. Resumed by the capture
  /// signal, by `endStreaming` when a stop or interruption ends the session first (the session's own
  /// rules then apply), or by `streamingEnded` with `recording-failed` when the capture loop ends
  /// on its own before capture began.
  private var streamStart: (session: any StreamingSession, continuation: CheckedContinuation<Void, Error>)?

  init(
    engine: Engine,
    processor: any AudioProcessing = AudioProcessor(),
    permission: @escaping @Sendable () -> String = { Recorder.permissionStatus() },
    emitLevel: @escaping LevelEmitter,
    emitStreaming: @escaping StreamingEmitter
  ) {
    self.engine = engine
    self.processor = processor
    self.permission = permission
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
    guard permission() == "granted" else {
      throw WhisperKitError(.permissionDenied, "Microphone permission has not been granted")
    }
    pendingSamples = nil
    streamRequestAfterInterrupt = nil
    do {
      try processor.startRecordingLive(inputDeviceID: nil, callback: nil)
    } catch {
      processor.stopRecording()
      deactivateSession()
      throw WhisperKitError.microphoneStartFailed(error.localizedDescription, underlying: error)
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
    guard permission() == "granted" else {
      throw WhisperKitError(.permissionDenied, "Microphone permission has not been granted")
    }
    pendingSamples = nil
    streamRequestAfterInterrupt = nil
    // Reserve the capture before the first await, so a concurrent start gets `busy`.
    mode = .streaming
    streamStarting = true
    streamAbortRequested = nil
    let instance: any SpeechModel
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
    let dedupe = StreamingDedupe()
    let emit = emitStreaming
    let session: any StreamingSession
    do {
      session = try instance.makeStreamingSession(options: request.decodingOptions(tokenizer: instance.tokenizer)) { confirmed, pending in
        if dedupe.changed(confirmed, pending) {
          emit(confirmed, pending)
        }
      }
    } catch {
      await engine.endExclusive()
      streamStarting = false
      mode = .idle
      throw error
    }
    streamTranscriber = session
    streamRequest = request
    streamStarting = false
    // The task is assigned below before this actor can run `streamingEnded` or `microphoneStarted`:
    // both need the actor, and `awaitMicrophone` installs the continuation before the first suspension.
    streamTask = Task { [weak self] in
      do {
        // Returns normally when WhisperKit's loop stops itself (a decode error, or its own
        // permission re-check failing) as well as after our own stop.
        try await session.start(onCapturing: { [weak self] in
          Task { await self?.microphoneStarted(session) }
        })
        await self?.streamingEnded(nil)
      } catch {
        await self?.streamingEnded(error)
      }
    }
    let processor = instance.audioProcessor
    startLevelTask { processor.relativeEnergy.last ?? 0 }
    try await awaitMicrophone(session)
  }

  /// WhisperKit starts the microphone inside `streamTask`, so a failure there would otherwise
  /// surface only as a silent, empty session. Suspends until the session reports capture, ends on
  /// its own (a failed start, rethrown here), or is ended by a stop or interruption (resolved: that
  /// session's own rules apply). There is no time cap: slow is not failed.
  private func awaitMicrophone(_ session: any StreamingSession) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      streamStart = (session, continuation)
    }
  }

  /// The capture signal from the session's audio processor. Ignored once a stop or interruption has
  /// begun tearing the session down: `endStreaming` resolves the waiter after the state is reset.
  private func microphoneStarted(_ session: any StreamingSession) {
    guard !streamEnding else { return }
    resumeStart(for: session, throwing: nil)
  }

  /// Resumes a `startStreaming` still waiting on `session`, if any.
  private func resumeStart(for session: any StreamingSession, throwing error: Error?) {
    guard let waiting = streamStart, waiting.session === session else { return }
    streamStart = nil
    if let error {
      waiting.continuation.resume(throwing: error)
    } else {
      waiting.continuation.resume()
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
  /// start) or stopped itself (its permission re-check failed, or a decode error). Ends the session
  /// like an interruption, keeping the audio for a later `stopStreaming`, except while
  /// `startStreaming` is still waiting for capture: any end then is a failed start, which rejects
  /// the pending start and keeps no audio. A no-op when the Recorder started the stop
  /// (`streamEnding`). It runs inside `streamTask`, so the task is detached first: `endStreaming`
  /// must not await the task it runs in.
  private func streamingEnded(_ error: Error?) async {
    guard isStreamLive, let session = streamTranscriber else { return }
    if let error {
      NSLog("[ExpoWhisperKit] streaming ended with an error: \(error.localizedDescription)")
    }
    streamTask = nil
    if let waiting = streamStart, waiting.session === session {
      // Take the waiter first so endStreaming cannot resolve it; then reject it.
      streamStart = nil
      _ = await endStreaming()
      let failure = error.map { WhisperKitError.microphoneStartFailed($0.localizedDescription, underlying: $0) }
        ?? WhisperKitError.microphoneStartFailed("the capture loop ended before recording began")
      waiting.continuation.resume(throwing: failure)
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
  /// deactivates the audio session and releases the engine's exclusivity. A `startStreaming`
  /// still waiting for capture resolves at the end: the session it started is over and its own
  /// rules (kept audio after an interruption) apply.
  private func endStreaming() async -> [Float] {
    streamEnding = true
    let session = streamTranscriber
    let task = streamTask
    streamTranscriber = nil
    streamTask = nil
    streamRequest = nil
    if let session {
      await session.stop()
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
    if let session {
      resumeStart(for: session, throwing: nil)
    }
    return samples
  }
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

/// Which `AVAudioSession.interruptionNotification` payloads end a capture (spec §3.3).
enum AudioInterruption {
  /// `AVAudioSession.InterruptionReason.appWasSuspended.rawValue`. The case is deprecated from
  /// iOS 16 (the system no longer sends it), so the raw value is spelled out rather than
  /// referencing the symbol; on earlier systems the notification still carries it.
  static let appWasSuspendedReason: UInt = 1

  /// True for a `began` interruption, except one delivered on resume because the app had been
  /// suspended: that one is stale and would end a capture started right after the app returned.
  static func shouldInterrupt(userInfo: [AnyHashable: Any]?) -> Bool {
    guard let type = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          type == AVAudioSession.InterruptionType.began.rawValue
    else { return false }
    if let reason = userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt, reason == appWasSuspendedReason {
      return false
    }
    return true
  }
}
