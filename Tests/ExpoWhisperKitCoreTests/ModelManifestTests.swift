import XCTest
@testable import ExpoWhisperKitCore

/// Guards the generated ModelManifest.swift against a broken generator run.
final class ModelManifestTests: XCTestCase {
  private func isHex(_ s: String, count: Int) -> Bool {
    s.count == count && s.allSatisfy { "0123456789abcdef".contains($0) }
  }

  func testBaseIsListedWithItsFolderAndRepos() throws {
    let base = try XCTUnwrap(ModelManifest.entries["base"])
    XCTAssertEqual(base.repo, "argmaxinc/whisperkit-coreml")
    XCTAssertEqual(base.folder, "openai_whisper-base")
    XCTAssertEqual(base.tokenizerRepo, "openai/whisper-base")
    XCTAssertTrue(isHex(base.revision, count: 40), base.revision)
    XCTAssertTrue(isHex(base.tokenizerRevision, count: 40), base.tokenizerRevision)
  }

  func testBaseListsTheCoreMLFilesAndTheTokenizer() throws {
    let base = try XCTUnwrap(ModelManifest.entries["base"])
    for path in ["config.json", "AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/weights/weight.bin", "MelSpectrogram.mlmodelc/coremldata.bin"] {
      XCTAssertNotNil(base.files[path], path)
    }
    XCTAssertEqual(Set(base.tokenizerFiles.keys), ["config.json", "tokenizer_config.json", "tokenizer.json"])
  }

  func testEveryHashIsSha256Hex() {
    for (name, entry) in ModelManifest.entries {
      XCTAssertFalse(entry.files.isEmpty, name)
      for (path, hash) in entry.files.merging(entry.tokenizerFiles, uniquingKeysWith: { a, _ in a }) {
        XCTAssertTrue(isHex(hash, count: 64), "\(name) \(path)")
        XCTAssertFalse(path.hasPrefix("/") || path.contains(".."), "\(name) \(path)")
      }
    }
  }
}
