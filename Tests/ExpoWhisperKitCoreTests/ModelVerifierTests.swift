import XCTest
@testable import ExpoWhisperKitCore

final class ModelVerifierTests: XCTestCase {
  private var folder: URL!
  // sha256("abc") and sha256("") are fixed test vectors.
  private let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelVerifierTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  private func write(_ relative: String, _ text: String) throws {
    let url = folder.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.data(using: .utf8)!.write(to: url)
  }

  private func assertFails(_ files: [String: String], message: String, line: UInt = #line) {
    XCTAssertThrowsError(try ModelVerifier.verify(folder: folder, files: files, model: "base"), line: line) { error in
      XCTAssertEqual((error as? WhisperKitError)?.code, .downloadFailed, line: line)
      XCTAssertEqual((error as? WhisperKitError)?.message, message, line: line)
    }
  }

  func testSha256OfKnownContent() throws {
    try write("a.txt", "abc")
    try write("empty.bin", "")
    XCTAssertEqual(try ModelVerifier.sha256(of: folder.appendingPathComponent("a.txt")), abcHash)
    XCTAssertEqual(try ModelVerifier.sha256(of: folder.appendingPathComponent("empty.bin")), emptyHash)
  }

  func testSha256StreamsALargeFile() throws {
    // 3 MiB of zeros crosses the 1 MiB read chunk more than once. The expected digest is the
    // sha256 of 3,145,728 zero bytes: `head -c 3145728 /dev/zero | shasum -a 256`.
    let url = folder.appendingPathComponent("big.bin")
    try Data(count: 3 * 1024 * 1024).write(to: url)
    let hash = try ModelVerifier.sha256(of: url)
    XCTAssertEqual(hash, "bbd05cf6097ac9b1f89ea29d2542c1b7b67ee46848393895f5a9e43fa1f621e5")
    XCTAssertEqual(hash.count, 64)
    XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
    XCTAssertEqual(hash, try ModelVerifier.sha256(of: url), "deterministic")
    XCTAssertNotEqual(hash, emptyHash, "all chunks were hashed")
  }

  func testVerifyOrRemoveDeletesTheFolderOnMismatch() throws {
    try write("tokenizer.json", "abd")
    XCTAssertThrowsError(try ModelVerifier.verifyOrRemove(folder: folder, files: ["tokenizer.json": abcHash], model: "base")) { error in
      XCTAssertEqual((error as? WhisperKitError)?.code, .downloadFailed)
      XCTAssertEqual((error as? WhisperKitError)?.message, "Model base failed verification: tokenizer.json does not match the manifest")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
  }

  func testVerifyOrRemoveKeepsAMatchingFolder() throws {
    try write("tokenizer.json", "abc")
    XCTAssertNoThrow(try ModelVerifier.verifyOrRemove(folder: folder, files: ["tokenizer.json": abcHash], model: "base"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path))
  }

  func testRegularFilesAreRelativeSortedAndIncludeHidden() throws {
    try write("b/two.txt", "2")
    try write("a.txt", "1")
    try write(".cache/huggingface/download/a.txt.metadata", "m")
    XCTAssertEqual(try ModelVerifier.regularFiles(under: folder), [".cache/huggingface/download/a.txt.metadata", "a.txt", "b/two.txt"])
  }

  func testMatchingFolderPasses() throws {
    try write("config.json", "abc")
    try write("weights/weight.bin", "")
    try write(".cache/huggingface/download/config.json.metadata", "ignored")
    XCTAssertNoThrow(try ModelVerifier.verify(folder: folder, files: ["config.json": abcHash, "weights/weight.bin": emptyHash], model: "base"))
  }

  func testMissingFileFails() throws {
    try write("config.json", "abc")
    assertFails(["config.json": abcHash, "weights/weight.bin": emptyHash], message: "Model base failed verification: weights/weight.bin is missing")
  }

  func testWrongHashFails() throws {
    try write("config.json", "abd")
    assertFails(["config.json": abcHash], message: "Model base failed verification: config.json does not match the manifest")
  }

  func testUnexpectedFileFails() throws {
    try write("config.json", "abc")
    try write("extra.bin", "")
    assertFails(["config.json": abcHash], message: "Model base failed verification: unexpected file extra.bin")
  }

  func testHiddenUnexpectedFileOutsideCacheFails() throws {
    try write("config.json", "abc")
    try write(".incomplete", "")
    assertFails(["config.json": abcHash], message: "Model base failed verification: unexpected file .incomplete")
  }
}
