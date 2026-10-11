import XCTest
@testable import ExpoWhisperKitCore

final class WhisperKitStreamingSessionTests: XCTestCase {
  private var processor: FakeProcessor!
  private var capturing: CapturingAudioProcessor!
  private var transcriber: FakeTranscriber!
  private var session: WhisperKitStreamingSession!

  override func setUp() {
    processor = FakeProcessor()
    capturing = CapturingAudioProcessor(processor)
    transcriber = FakeTranscriber(processor: capturing)
    session = WhisperKitStreamingSession(transcriber: transcriber, processor: capturing)
  }

  func testCaptureIsReportedOnceTheMicrophoneIsUp() async throws {
    let captured = Flag()
    let session = self.session!
    let start = Task { try await session.start(onCapturing: { captured.set() }) }
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertFalse(captured.isSet, "nothing is captured while the permission check is pending")
    await transcriber.permissionGate.open()
    await eventually { captured.isSet }
    XCTAssertTrue(processor.isRecording)
    await session.stop()
    try await start.value
    XCTAssertFalse(processor.isRecording)
  }

  func testStopBeforeTheMicrophoneIsUpStillEndsTheLoop() async throws {
    // Finding 1: WhisperKit's stop is a no-op until `isRecording` is set, which happens after
    // its permission await. A stop that lands in that window must still end the session.
    let done = Flag()
    let session = self.session!
    let start = Task {
      try await session.start(onCapturing: {})
      done.set()
    }
    let transcriber = self.transcriber!
    await eventually { transcriber.startCalls == 1 }
    await session.stop()
    XCTAssertFalse(done.isSet)
    await transcriber.permissionGate.open()
    await eventually { done.isSet }
    start.cancel()
    XCTAssertFalse(transcriber.isRecording)
    XCTAssertGreaterThanOrEqual(transcriber.stopCalls, 2, "the wrapper stops again once capture begins")
  }

  func testStartRethrowsWhenTheMicrophoneCannotStart() async {
    processor.setStartError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input"]))
    let captured = Flag()
    await transcriber.permissionGate.open()
    do {
      try await session.start(onCapturing: { captured.set() })
      XCTFail("expected the processor error")
    } catch {
      XCTAssertEqual((error as NSError).localizedDescription, "no input")
    }
    XCTAssertFalse(captured.isSet)
    XCTAssertFalse(transcriber.isRecording)
  }

  func testRefusedPermissionEndsQuietlyWithoutCapture() async throws {
    // Documents the upstream behaviour the Recorder must treat as a failed start (finding 2).
    transcriber.setPermissionGranted(false)
    let captured = Flag()
    await transcriber.permissionGate.open()
    try await session.start(onCapturing: { captured.set() })
    XCTAssertFalse(captured.isSet)
    XCTAssertEqual(processor.startCalls, 0)
  }
}
