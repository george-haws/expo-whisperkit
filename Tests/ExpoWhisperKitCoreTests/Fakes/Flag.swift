import Foundation

/// A lock-protected "it happened" boolean for assertions from any thread.
final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }

  func set() { lock.lock(); value = true; lock.unlock() }
}
