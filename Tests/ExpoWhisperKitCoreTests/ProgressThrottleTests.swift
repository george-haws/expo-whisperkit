import XCTest
@testable import ExpoWhisperKitCore

final class ProgressThrottleTests: XCTestCase {
  func testEachModelHasItsOwnWindow() {
    let throttle = ProgressThrottle(interval: 60)
    XCTAssertTrue(throttle.shouldSend(model: "base", fraction: 0.1))
    XCTAssertTrue(throttle.shouldSend(model: "small", fraction: 0.1), "a second model is not starved by the first")
    XCTAssertFalse(throttle.shouldSend(model: "base", fraction: 0.2))
    XCTAssertFalse(throttle.shouldSend(model: "small", fraction: 0.2))
  }

  func testCompletionIsAlwaysSentAndResetsTheModel() {
    let throttle = ProgressThrottle(interval: 60)
    XCTAssertTrue(throttle.shouldSend(model: "base", fraction: 0.1))
    XCTAssertTrue(throttle.shouldSend(model: "base", fraction: 1))
    XCTAssertTrue(throttle.shouldSend(model: "base", fraction: 0.1), "a new download of the same model starts a fresh window")
  }
}
