import XCTest
@testable import ExpoWhisperKitCore

final class ThrottleTests: XCTestCase {
  func testFirstCallIsSent() {
    let throttle = Throttle(interval: 60)
    XCTAssertTrue(throttle.shouldSend())
  }

  func testSecondCallWithinTheIntervalIsDropped() {
    let throttle = Throttle(interval: 60)
    _ = throttle.shouldSend()
    XCTAssertFalse(throttle.shouldSend())
  }

  func testForceSendsWithinTheInterval() {
    let throttle = Throttle(interval: 60)
    _ = throttle.shouldSend()
    XCTAssertTrue(throttle.shouldSend(force: true))
  }

  func testSendsAgainAfterTheInterval() {
    let throttle = Throttle(interval: 0.01)
    _ = throttle.shouldSend()
    Thread.sleep(forTimeInterval: 0.03)
    XCTAssertTrue(throttle.shouldSend())
  }
}
