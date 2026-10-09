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
    // Checked before any audio is taken, so a refused call does not discard the capture.
    guard stopTask == nil else {
      throw WhisperKitError(.busy, "A stopRecording call is already in flight")
    }
    let samples: [Float]
    if mode == .recording {
      samples = endCapture()
    } else if let pending = pendingSamples {
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
      throw error
    }
  }

  func cancelRecording() {
    if mode == .recording {
      _ = endCapture()
    }
    pendingSamples = nil
    stopTask?.cancel()
  }

  /// Phone call, Siri, or the app leaving the foreground. Push-to-talk audio is kept for the
  /// next `stopRecording`; a streaming session ends with its final result discarded to the
  /// caller's pending `stopStreaming`, if any (Task 7).
  func interrupt() async {
    switch mode {
    case .recording:
      pendingSamples = endCapture()
    case .streaming:
      await interruptStreaming()
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

  /// Placeholder until Task 7 fills it in.
  func interruptStreaming() async {}
}
