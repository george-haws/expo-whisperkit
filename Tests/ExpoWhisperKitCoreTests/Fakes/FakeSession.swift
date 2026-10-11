import Foundation
@testable import ExpoWhisperKitCore

/// A StreamingSession with a scripted `start()`.
///
/// - `.runUntilStopped`: `start()` suspends until `stop()` is called, like WhisperKit's loop.
/// - `.returnAtOnce`: `start()` returns immediately with no error (WhisperKit's permission re-check
///   failing, or its loop stopping itself after a decode error).
/// - `.throwError`: `start()` throws (the microphone could not start).
/// - `.hangUntilReleased`: `start()` ignores `stop()` and returns only on `release()`, which is what a
///   stop that lands during WhisperKit's permission await produces.
final class FakeSession: StreamingSession, @unchecked Sendable {
  enum StartBehaviour {
    case runUntilStopped
    case returnAtOnce
    case throwError(Error)
    case hangUntilReleased
  }

  private let lock = NSLock()
  private var behaviour: StartBehaviour = .runUntilStopped
  private var continuation: CheckedContinuation<Void, Never>?
  private var stopRequested = false
  private var released = false
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

  private func beginStart(_ onCapturing: @escaping @Sendable () -> Void) -> StartBehaviour {
    lock.lock(); defer { lock.unlock() }
    _startCalls += 1
    _onCapturing = onCapturing
    return behaviour
  }

  /// Returns false when the continuation must be resumed at once (a stop already landed).
  private func park(_ c: CheckedContinuation<Void, Never>, for behaviour: StartBehaviour) -> Bool {
    lock.lock(); defer { lock.unlock() }
    if case .runUntilStopped = behaviour, stopRequested { return false }
    if case .hangUntilReleased = behaviour, released { return false }
    continuation = c
    return true
  }

  private func finishStop() -> CheckedContinuation<Void, Never>? {
    lock.lock(); defer { lock.unlock() }
    _stopCalls += 1
    stopRequested = true
    guard case .runUntilStopped = behaviour else { return nil }
    let resume = continuation
    continuation = nil
    return resume
  }

  func start(onCapturing: @escaping @Sendable () -> Void) async throws {
    let behaviour = beginStart(onCapturing)
    switch behaviour {
    case .returnAtOnce:
      return
    case .throwError(let error):
      throw error
    case .runUntilStopped, .hangUntilReleased:
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        if !park(c, for: behaviour) { c.resume() }
      }
    }
  }

  private func enterStop() { lock.lock(); _stopEntered += 1; lock.unlock() }

  func stop() async {
    enterStop()
    if let stopGate { await stopGate.wait() }
    finishStop()?.resume()
  }

  /// Ends a `.hangUntilReleased` start.
  func release() {
    lock.lock()
    released = true
    let resume = continuation
    continuation = nil
    lock.unlock()
    resume?.resume()
  }
}
