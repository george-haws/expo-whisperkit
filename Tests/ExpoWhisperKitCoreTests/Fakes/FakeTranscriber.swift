import Foundation
import WhisperKit
@testable import ExpoWhisperKitCore

/// Reproduces the order of WhisperKit v1.1.1's `AudioStreamTranscriber.startStreamTranscription`:
/// await the permission check (here a gate), return quietly if it is refused, set `isRecording`,
/// start the processor (rethrowing its error), then loop while recording. `stopStreamTranscription`
/// clears `isRecording` and stops the processor, so a stop that lands before `isRecording` is set
/// is a no-op, exactly as upstream.
final class FakeTranscriber: StreamTranscribing, @unchecked Sendable {
  let permissionGate = Gate()
  private let processor: any AudioProcessing
  private let lock = NSLock()
  private var recording = false
  private var permissionGranted = true
  private var _startCalls = 0
  private var _stopCalls = 0

  init(processor: any AudioProcessing) {
    self.processor = processor
  }

  var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recording }
  var startCalls: Int { lock.lock(); defer { lock.unlock() }; return _startCalls }
  var stopCalls: Int { lock.lock(); defer { lock.unlock() }; return _stopCalls }

  func setPermissionGranted(_ granted: Bool) { lock.lock(); permissionGranted = granted; lock.unlock() }

  private func beginStart() -> Bool {
    lock.lock(); defer { lock.unlock() }
    _startCalls += 1
    return permissionGranted
  }

  private func setRecording(_ value: Bool) { lock.lock(); recording = value; lock.unlock() }

  func startStreamTranscription() async throws {
    let granted = beginStart()
    await permissionGate.wait()
    guard granted else { return }
    setRecording(true)
    do {
      try processor.startRecordingLive(inputDeviceID: nil, callback: nil)
    } catch {
      setRecording(false)
      throw error
    }
    while isRecording, !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func recordStop() {
    lock.lock()
    _stopCalls += 1
    recording = false
    lock.unlock()
  }

  func stopStreamTranscription() async {
    recordStop()
    processor.stopRecording()
  }
}
