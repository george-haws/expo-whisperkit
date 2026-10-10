import XCTest
@testable import ExpoWhisperKitCore

final class ModelNameTests: XCTestCase {
  func testOrdinaryNamePasses() throws {
    XCTAssertEqual(try ModelStore.validated("openai_whisper-base"), "openai_whisper-base")
    XCTAssertEqual(try ModelStore.validated("base"), "base")
  }

  func testEscapingNamesAreRejectedWithModelMissing() {
    for name in ["", ".", "..", ".hidden", "a/b", "a..b"] {
      XCTAssertThrowsError(try ModelStore.validated(name), "\"\(name)\" should be rejected") { error in
        XCTAssertEqual((error as? WhisperKitError)?.code, .modelMissing, name)
      }
    }
  }
}
