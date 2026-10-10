import XCTest
@testable import ExpoWhisperKitCore

final class StreamingDedupeTests: XCTestCase {
  func testFirstNonEmptyPairIsAChange() {
    XCTAssertTrue(StreamingDedupe().changed("hello", "wor"))
  }

  func testRepeatedPairIsNotAChange() {
    let dedupe = StreamingDedupe()
    _ = dedupe.changed("hello", "wor")
    XCTAssertFalse(dedupe.changed("hello", "wor"))
  }

  func testPendingTextChangeCounts() {
    let dedupe = StreamingDedupe()
    _ = dedupe.changed("hello", "wor")
    XCTAssertTrue(dedupe.changed("hello", "world"))
  }

  func testInitialEmptyPairIsNotAChange() {
    // The dedupe starts at ("", ""), so an empty first update is never emitted.
    XCTAssertFalse(StreamingDedupe().changed("", ""))
  }
}
