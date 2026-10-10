import XCTest
@testable import ExpoWhisperKitCore

final class ModelStoreTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  private func makeFolder(_ relative: String) throws -> URL {
    let url = root.appendingPathComponent(relative, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testInitCreatesTheThreeFolders() {
    _ = ModelStore(root: root)
    for name in ["models", "downloads", "tokenizers"] {
      XCTAssertTrue(isDirectory(root.appendingPathComponent(name)), name)
    }
  }

  func testInitClearsALeftoverDownload() throws {
    let leftover = try makeFolder("downloads/base")
    _ = ModelStore(root: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    XCTAssertTrue(isDirectory(root.appendingPathComponent("downloads")))
  }

  func testFinalFolderIsUnderModels() async {
    let store = ModelStore(root: root)
    let folder = await store.finalFolder(for: "base")
    XCTAssertEqual(folder.path, root.appendingPathComponent("models/base").path)
  }

  func testPresentNeedsADirectoryNotAFile() async throws {
    let store = ModelStore(root: root)
    let absent = await store.isPresent("base")
    XCTAssertFalse(absent)
    FileManager.default.createFile(atPath: root.appendingPathComponent("models/base").path, contents: Data())
    let file = await store.isPresent("base")
    XCTAssertFalse(file)
    try FileManager.default.removeItem(at: root.appendingPathComponent("models/base"))
    _ = try makeFolder("models/base")
    let directory = await store.isPresent("base")
    XCTAssertTrue(directory)
  }

  func testListPresentIsSortedAndSkipsFiles() async throws {
    let store = ModelStore(root: root)
    for name in ["small", "base", "tiny"] { _ = try makeFolder("models/\(name)") }
    FileManager.default.createFile(atPath: root.appendingPathComponent("models/stray.txt").path, contents: Data())
    let listed = await store.listPresent()
    XCTAssertEqual(listed, ["base", "small", "tiny"])
  }

  func testDeleteRemovesBothLocationsAndToleratesAbsence() async throws {
    let store = ModelStore(root: root)
    let final = try makeFolder("models/base")
    let inflight = try makeFolder("downloads/base")
    try await store.delete("base")
    XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: inflight.path))
    try await store.delete("base")
  }

  func testFreshStoreIsNotDownloading() async {
    let store = ModelStore(root: root)
    let downloading = await store.isDownloading("base")
    XCTAssertFalse(downloading)
  }

  func testModelStoreIsAModelStoring() {
    let store: any ModelStoring = ModelStore(root: root)
    XCTAssertNotNil(store)
  }
}
