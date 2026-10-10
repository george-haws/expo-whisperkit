import XCTest
import WhisperKit
@testable import ExpoWhisperKitCore

final class StreamingTextTests: XCTestCase {
  private func segment(_ text: String) -> TranscriptionSegment { TranscriptionSegment(text: text) }

  func testJoinsAndTrimsConfirmedSegments() {
    let text = StreamingText.from(confirmed: [segment(" Hello"), segment(" world ")], unconfirmed: [], current: "")
    XCTAssertEqual(text.confirmed, "Hello world")
    XCTAssertEqual(text.pending, "")
  }

  func testPendingIsUnconfirmedSegmentsThenCurrentText() {
    let text = StreamingText.from(confirmed: [], unconfirmed: [segment(" one"), segment(" two")], current: "thr")
    XCTAssertEqual(text.pending, "one two thr")
  }

  func testWaitingPlaceholderIsNotText() {
    let text = StreamingText.from(confirmed: [], unconfirmed: [segment(" one")], current: StreamingText.waitingPlaceholder)
    XCTAssertEqual(text.pending, "one")
    let empty = StreamingText.from(confirmed: [], unconfirmed: [], current: StreamingText.waitingPlaceholder)
    XCTAssertEqual(empty.pending, "")
  }
}
