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

  func testCommitMovesTheStagedFolderIntoPlace() async throws {
    let store = ModelStore(root: root)
    let staged = try makeFolder("downloads/base/nested/base")
    FileManager.default.createFile(atPath: staged.appendingPathComponent("config.json").path, contents: Data())
    await store.stage("base", folder: staged)
    let downloading = await store.isDownloading("base")
    XCTAssertTrue(downloading)
    try await store.commit("base")
    XCTAssertTrue(isDirectory(root.appendingPathComponent("models/base")))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("models/base/config.json").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("downloads/base").path))
    let stillDownloading = await store.isDownloading("base")
    XCTAssertFalse(stillDownloading)
    let present = await store.isPresent("base")
    XCTAssertTrue(present)
  }

  func testDiscardRemovesTheStagingFolder() async throws {
    let store = ModelStore(root: root)
    let staged = try makeFolder("downloads/base/nested/base")
    await store.stage("base", folder: staged)
    await store.discard("base")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("downloads/base").path))
    let downloading = await store.isDownloading("base")
    XCTAssertFalse(downloading)
    let present = await store.isPresent("base")
    XCTAssertFalse(present)
  }

  func testCommitWithNothingStagedToleratesAPresentModel() async throws {
    let store = ModelStore(root: root)
    _ = try makeFolder("models/base")
    try await store.commit("base")
    let present = await store.isPresent("base")
    XCTAssertTrue(present)
  }

  func testCommitWithNothingStagedAndNothingPresentIsDownloadFailed() async {
    let store = ModelStore(root: root)
    do {
      try await store.commit("base")
      XCTFail("expected download-failed")
    } catch {
      XCTAssertEqual((error as? WhisperKitError)?.code, .downloadFailed)
    }
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

  func testDownloadOfAnUnlistedModelRejectsBeforeAnyNetwork() async {
    let store = ModelStore(root: root)
    do {
      _ = try await store.download("not-a-model") { _ in }
      XCTFail("expected download-failed")
    } catch {
      XCTAssertEqual((error as? WhisperKitError)?.code, .downloadFailed)
      XCTAssertEqual((error as? WhisperKitError)?.message, "Model not-a-model is not in the manifest")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("downloads/not-a-model").path))
    let downloading = await store.isDownloading("not-a-model")
    XCTAssertFalse(downloading)
  }

  func testDownloadOfAPresentModelReturnsNilEvenIfUnlisted() async throws {
    // Present wins over the manifest, so a model downloaded by an earlier version keeps working.
    let store = ModelStore(root: root)
    _ = try makeFolder("models/not-a-model")
    let returned = try await store.download("not-a-model") { _ in }
    XCTAssertNil(returned)
    let downloading = await store.isDownloading("not-a-model")
    XCTAssertFalse(downloading)
  }
}
