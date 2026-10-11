import AVFoundation
import XCTest
@testable import ExpoWhisperKitCore

final class AudioInterruptionTests: XCTestCase {
  private let began = AVAudioSession.InterruptionType.began.rawValue
  private let ended = AVAudioSession.InterruptionType.ended.rawValue

  func testBeganInterrupts() {
    XCTAssertTrue(AudioInterruption.shouldInterrupt(userInfo: [AVAudioSessionInterruptionTypeKey: began]))
  }

  func testBeganWithTheDefaultReasonInterrupts() {
    XCTAssertTrue(AudioInterruption.shouldInterrupt(userInfo: [
      AVAudioSessionInterruptionTypeKey: began,
      AVAudioSessionInterruptionReasonKey: UInt(0),
    ]))
  }

  func testBeganBecauseTheAppWasSuspendedDoesNotInterrupt() {
    XCTAssertFalse(AudioInterruption.shouldInterrupt(userInfo: [
      AVAudioSessionInterruptionTypeKey: began,
      AVAudioSessionInterruptionReasonKey: AudioInterruption.appWasSuspendedReason,
    ]))
  }

  func testEndedDoesNotInterrupt() {
    XCTAssertFalse(AudioInterruption.shouldInterrupt(userInfo: [AVAudioSessionInterruptionTypeKey: ended]))
  }

  func testNSNumberPayloadBridges() {
    XCTAssertTrue(AudioInterruption.shouldInterrupt(userInfo: [
      AVAudioSessionInterruptionTypeKey: NSNumber(value: began),
    ]))
    XCTAssertFalse(AudioInterruption.shouldInterrupt(userInfo: [
      AVAudioSessionInterruptionTypeKey: NSNumber(value: began),
      AVAudioSessionInterruptionReasonKey: NSNumber(value: AudioInterruption.appWasSuspendedReason),
    ]))
  }

  func testMissingPayloadDoesNotInterrupt() {
    XCTAssertFalse(AudioInterruption.shouldInterrupt(userInfo: nil))
    XCTAssertFalse(AudioInterruption.shouldInterrupt(userInfo: [:]))
  }
}
