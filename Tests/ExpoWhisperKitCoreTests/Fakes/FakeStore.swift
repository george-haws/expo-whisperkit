import Foundation
@testable import ExpoWhisperKitCore

/// In-memory ModelStoring with the staging model: `download` succeeds into a staging folder and
/// marks the model downloading; `commit` makes it present; `discard` drops it.
actor FakeStore: ModelStoring {
  let tokenizersDir = URL(fileURLWithPath: "/fake/tokenizers", isDirectory: true)
  private(set) var present: Set<String> = []
  private(set) var downloading: Set<String> = []
  private(set) var deleted: [String] = []
  private(set) var downloads: [String] = []
  private(set) var committed: [String] = []
  private(set) var discarded: [String] = []
  private var downloadError: Error?
  private var commitError: Error?
  private var turnsPresentDuringFetch = false

  func setPresent(_ models: Set<String>) { present = models }
  func setDownloading(_ models: Set<String>) { downloading = models }
  func setDownloadError(_ error: Error?) { downloadError = error }
  func setCommitError(_ error: Error?) { commitError = error }
  /// Models a concurrent commit: the next `download` finds the model present and fetches nothing.
  func setTurnsPresentDuringFetch(_ value: Bool) { turnsPresentDuringFetch = value }

  func finalFolder(for model: String) -> URL {
    URL(fileURLWithPath: "/fake/models/\(model)", isDirectory: true)
  }

  func stagingFolder(for model: String) -> URL {
    URL(fileURLWithPath: "/fake/downloads/\(model)", isDirectory: true)
  }

  func isPresent(_ model: String) -> Bool { present.contains(model) }
  func isDownloading(_ model: String) -> Bool { downloading.contains(model) }
  func listPresent() -> [String] { present.sorted() }

  func delete(_ model: String) throws {
    present.remove(model)
    deleted.append(model)
  }

  func download(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL? {
    downloads.append(model)
    if let downloadError { throw downloadError }
    if turnsPresentDuringFetch {
      present.insert(model)
      return nil
    }
    downloading.insert(model)
    progress(0.5)
    progress(1)
    return stagingFolder(for: model)
  }

  func commit(_ model: String) throws {
    if let commitError { throw commitError }
    committed.append(model)
    downloading.remove(model)
    present.insert(model)
  }

  func discard(_ model: String) {
    discarded.append(model)
    downloading.remove(model)
  }
}
