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
  private var _session = FakeSession()
  private var sessionError: Error?
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
  var session: FakeSession { lock.lock(); defer { lock.unlock() }; return _session }

  func setResult(_ value: Result<[TranscriptionResult], Error>) { lock.lock(); result = value; lock.unlock() }
  func setSession(_ value: FakeSession) { lock.lock(); _session = value; lock.unlock() }
  func setSessionError(_ error: Error?) { lock.lock(); sessionError = error; lock.unlock() }

  func transcribe(path: String, options: DecodingOptions) async throws -> [TranscriptionResult] {
    lock.lock(); _lastPath = path; lock.unlock()
    return try await run()
  }

  func transcribe(samples: [Float], options: DecodingOptions) async throws -> [TranscriptionResult] {
    lock.lock(); _lastSamples = samples; lock.unlock()
    return try await run()
  }

  private func run() async throws -> [TranscriptionResult] {
    lock.lock(); _transcribeCalls += 1; let gate = transcribeGate; lock.unlock()
    if let gate { await gate.wait() }
    lock.lock(); defer { lock.unlock() }
    return try result.get()
  }

  func unloadModels() async {
    lock.lock(); _unloads += 1; lock.unlock()
  }

  func makeStreamingSession(options: DecodingOptions, onText: @escaping StreamingTextCallback) throws -> any StreamingSession {
    lock.lock(); let error = sessionError; let session = _session; lock.unlock()
    if let error { throw error }
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
