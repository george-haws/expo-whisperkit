import Foundation
import WhisperKit
@testable import ExpoWhisperKitCore

/// A SpeechModel with scripted transcriptions and a scripted streaming session.
final class FakeModel: SpeechModel, @unchecked Sendable {
  let tokenizer: (any WhisperTokenizer)? = nil
  let audioProcessor: any AudioProcessing
  let fakeProcessor: FakeProcessor

  private let lock = NSLock()
  private var result: Result<[TranscriptionResult], Error> = .success([FakeModel.result(text: "hello")])
  private var _unloads = 0
  private var _transcribeCalls = 0
  private var _lastSamples: [Float]?
  private var _lastPath: String?
  private var next = FakeSession()
  private var handedOut: [FakeSession] = []
  private var sessionError: Error?
  private var override: (any StreamingSession)?
  /// When set, `transcribe` waits on it, holding the engine busy.
  var transcribeGate: Gate?

  init() {
    fakeProcessor = FakeProcessor()
    audioProcessor = fakeProcessor
  }

  var unloads: Int { lock.lock(); defer { lock.unlock() }; return _unloads }
  var transcribeCalls: Int { lock.lock(); defer { lock.unlock() }; return _transcribeCalls }
  var lastSamples: [Float]? { lock.lock(); defer { lock.unlock() }; return _lastSamples }
  var lastPath: String? { lock.lock(); defer { lock.unlock() }; return _lastPath }
  /// The most recently handed-out session, or the preset when none has been handed out yet.
  var session: FakeSession { lock.lock(); defer { lock.unlock() }; return handedOut.last ?? next }
  /// Every session `makeStreamingSession` has handed out, oldest first.
  var sessions: [FakeSession] { lock.lock(); defer { lock.unlock() }; return handedOut }

  func setResult(_ value: Result<[TranscriptionResult], Error>) { lock.lock(); result = value; lock.unlock() }
  func setSession(_ value: FakeSession) { lock.lock(); next = value; lock.unlock() }
  func setSessionOverride(_ session: any StreamingSession) { lock.lock(); override = session; lock.unlock() }
  func setSessionError(_ error: Error?) { lock.lock(); sessionError = error; lock.unlock() }

  func transcribe(path: String, options: DecodingOptions) async throws -> [TranscriptionResult] {
    record(path: path)
    return try await run()
  }

  func transcribe(samples: [Float], options: DecodingOptions) async throws -> [TranscriptionResult] {
    record(samples: samples)
    return try await run()
  }

  private func run() async throws -> [TranscriptionResult] {
    let gate = beginRun()
    if let gate { await gate.wait() }
    return try currentResult()
  }

  private func record(path: String) { lock.lock(); _lastPath = path; lock.unlock() }
  private func record(samples: [Float]) { lock.lock(); _lastSamples = samples; lock.unlock() }
  private func beginRun() -> Gate? { lock.lock(); defer { lock.unlock() }; _transcribeCalls += 1; return transcribeGate }
  private func currentResult() throws -> [TranscriptionResult] { lock.lock(); defer { lock.unlock() }; return try result.get() }
  private func recordUnload() { lock.lock(); _unloads += 1; lock.unlock() }

  /// Hands out the preset session (or the error) and presets a fresh one for the next call.
  private func takeSession() -> (Error?, (any StreamingSession)?, FakeSession) {
    lock.lock(); defer { lock.unlock() }
    if let sessionError { return (sessionError, nil, next) }
    if let override { return (nil, override, next) }
    let session = next
    handedOut.append(session)
    next = FakeSession()
    return (nil, nil, session)
  }

  func unloadModels() async {
    recordUnload()
  }

  func makeStreamingSession(options: DecodingOptions, onText: @escaping StreamingTextCallback) throws -> any StreamingSession {
    let (error, overridden, session) = takeSession()
    if let error { throw error }
    if let overridden { return overridden }
    session.setOnText(onText)
    return session
  }

  static func result(text: String, language: String = "en") -> TranscriptionResult {
    TranscriptionResult(
      text: text,
      segments: [TranscriptionSegment(start: 0, end: 1, text: text)],
      language: language,
      timings: TranscriptionTimings()
    )
  }
}
