import Foundation
@testable import ExpoWhisperKitCore

/// A StreamingSession with a scripted `start()`.
///
/// - `.runUntilStopped`: `start()` suspends until `stop()` or `fail(with:)`, like WhisperKit's loop.
/// - `.returnAtOnce`: `start()` returns immediately with no error (WhisperKit's permission re-check
///   failing, or its loop stopping itself after a decode error).
/// - `.throwError`: `start()` throws (the microphone could not start).
///
/// By default a `.runUntilStopped` start reports capture at once, as a healthy microphone would.
/// `setCapturesOnStart(false)` holds that back so a test can call `capture()` itself.
final class FakeSession: StreamingSession, @unchecked Sendable {
  enum StartBehaviour {
    case runUntilStopped
    case returnAtOnce
    case throwError(Error)
  }

  private let lock = NSLock()
  private var behaviour: StartBehaviour = .runUntilStopped
  private var capturesOnStart = true
  private var continuation: CheckedContinuation<Void, Error>?
  private var stopRequested = false
  private var _stopEntered = 0
  private var _startCalls = 0
  private var _stopCalls = 0
  private var _onText: StreamingTextCallback?
  private var _onCapturing: (@Sendable () -> Void)?
  /// When set, `stop()` waits on it before returning, to hold the Recorder in its ending state.
  var stopGate: Gate?

  var startCalls: Int { lock.lock(); defer { lock.unlock() }; return _startCalls }
  /// Incremented at the top of `stop()`, before it waits on `stopGate`.
  var stopEntered: Int { lock.lock(); defer { lock.unlock() }; return _stopEntered }
  var stopCalls: Int { lock.lock(); defer { lock.unlock() }; return _stopCalls }

  func setBehaviour(_ value: StartBehaviour) { lock.lock(); behaviour = value; lock.unlock() }
  func setCapturesOnStart(_ value: Bool) { lock.lock(); capturesOnStart = value; lock.unlock() }
  func setOnText(_ callback: @escaping StreamingTextCallback) { lock.lock(); _onText = callback; lock.unlock() }

  /// Pushes a text update through the Recorder's callback, as WhisperKit's state change would.
  func emit(_ confirmed: String, _ pending: String) {
    lock.lock(); let callback = _onText; lock.unlock()
    callback?(confirmed, pending)
  }

  /// Reports the microphone as up, as the production wrapper does when `startRecordingLive` returns.
  func capture() {
    lock.lock(); let callback = _onCapturing; lock.unlock()
    callback?()
  }

  /// Ends a suspended `start()` with `error`, as a capture loop that dies after the microphone
  /// came up (or never came up) would.
  func fail(with error: Error) {
    lock.lock()
    let resume = continuation
    continuation = nil
    lock.unlock()
    resume?.resume(throwing: error)
  }

  private func beginStart(_ onCapturing: @escaping @Sendable () -> Void) -> (StartBehaviour, Bool) {
    lock.lock(); defer { lock.unlock() }
    _startCalls += 1
    _onCapturing = onCapturing
    return (behaviour, capturesOnStart)
  }

  /// Returns false when the continuation must be resumed at once (a stop already landed).
  private func park(_ c: CheckedContinuation<Void, Error>) -> Bool {
    lock.lock(); defer { lock.unlock() }
    if stopRequested { return false }
    continuation = c
    return true
  }

  private func finishStop() -> CheckedContinuation<Void, Error>? {
    lock.lock(); defer { lock.unlock() }
    _stopCalls += 1
    stopRequested = true
    let resume = continuation
    continuation = nil
    return resume
  }

  func start(onCapturing: @escaping @Sendable () -> Void) async throws {
    let (behaviour, capturesOnStart) = beginStart(onCapturing)
    switch behaviour {
    case .returnAtOnce:
      return
    case .throwError(let error):
      throw error
    case .runUntilStopped:
      if capturesOnStart { onCapturing() }
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        if !park(c) { c.resume() }
      }
    }
  }

  private func enterStop() { lock.lock(); _stopEntered += 1; lock.unlock() }

  func stop() async {
    enterStop()
    if let stopGate { await stopGate.wait() }
    finishStop()?.resume()
  }
}
