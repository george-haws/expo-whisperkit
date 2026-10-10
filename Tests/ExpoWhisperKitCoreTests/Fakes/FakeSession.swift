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
  private var _startCalls = 0
  private var _stopCalls = 0
  private var _onText: StreamingTextCallback?
  /// When set, `stop()` waits on it before returning, to hold the Recorder in its ending state.
  var stopGate: Gate?

  var startCalls: Int { lock.lock(); defer { lock.unlock() }; return _startCalls }
  var stopCalls: Int { lock.lock(); defer { lock.unlock() }; return _stopCalls }

  func setBehaviour(_ value: StartBehaviour) { lock.lock(); behaviour = value; lock.unlock() }
  func setOnText(_ callback: @escaping StreamingTextCallback) { lock.lock(); _onText = callback; lock.unlock() }

  /// Pushes a text update through the Recorder's callback, as WhisperKit's state change would.
  func emit(_ confirmed: String, _ pending: String) {
    lock.lock(); let callback = _onText; lock.unlock()
    callback?(confirmed, pending)
  }

  func start() async throws {
    lock.lock()
    _startCalls += 1
    let behaviour = self.behaviour
    lock.unlock()
    switch behaviour {
    case .returnAtOnce:
      return
    case .throwError(let error):
      throw error
    case .runUntilStopped, .hangUntilReleased:
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        lock.lock()
        if case .runUntilStopped = behaviour, stopRequested {
          lock.unlock()
          c.resume()
          return
        }
        continuation = c
        lock.unlock()
      }
    }
  }

  func stop() async {
    if let stopGate { await stopGate.wait() }
    lock.lock()
    _stopCalls += 1
    stopRequested = true
    var resume: CheckedContinuation<Void, Never>?
    if case .runUntilStopped = behaviour {
      resume = continuation
      continuation = nil
    }
    lock.unlock()
    resume?.resume()
  }

  /// Ends a `.hangUntilReleased` start.
  func release() {
    lock.lock()
    let resume = continuation
    continuation = nil
    lock.unlock()
    resume?.resume()
  }
}
