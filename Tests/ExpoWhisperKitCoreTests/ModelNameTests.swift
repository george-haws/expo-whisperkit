import XCTest
@testable import ExpoWhisperKitCore

final class ModelNameTests: XCTestCase {
  func testOrdinaryNamesPass() throws {
    for name in ["openai_whisper-base", "base", "small.en", "large-v3_turbo", "distil-large-v3", "Tiny"] {
      XCTAssertEqual(try ModelStore.validated(name), name)
    }
  }

  func testEscapingNamesAreRejectedWithModelMissing() {
    for name in ["", ".", "..", ".hidden", "a/b", "a..b"] {
      XCTAssertThrowsError(try ModelStore.validated(name), "\"\(name)\" should be rejected") { error in
        XCTAssertEqual((error as? WhisperKitError)?.code, .modelMissing, name)
      }
    }
  }

  func testCharactersOutsideTheAllowlistAreRejected() {
    for name in ["base*", "a b", "base\n", "a\u{0}b", "bäse", "base?", "[base]", "base:en", "base\\en"] {
      XCTAssertThrowsError(try ModelStore.validated(name), "\"\(name)\" should be rejected") { error in
        XCTAssertEqual((error as? WhisperKitError)?.code, .modelMissing, name)
        XCTAssertEqual((error as? WhisperKitError)?.message, "Invalid model name")
      }
    }
  }
}
