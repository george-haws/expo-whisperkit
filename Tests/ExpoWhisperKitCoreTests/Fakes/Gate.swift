/// A latch: `wait()` suspends until `open()`; once open it returns at once.
actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let resumed = waiters
    waiters = []
    resumed.forEach { $0.resume() }
  }
}
