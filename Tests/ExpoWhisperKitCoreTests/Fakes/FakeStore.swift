import Foundation
@testable import ExpoWhisperKitCore

/// In-memory ModelStoring. `download` succeeds and marks the model present unless an error is set.
actor FakeStore: ModelStoring {
  let tokenizersDir = URL(fileURLWithPath: "/fake/tokenizers", isDirectory: true)
  private(set) var present: Set<String> = []
  private(set) var downloading: Set<String> = []
  private(set) var deleted: [String] = []
  private(set) var downloads: [String] = []
  private var downloadError: Error?

  func setPresent(_ models: Set<String>) { present = models }
  func setDownloading(_ models: Set<String>) { downloading = models }
  func setDownloadError(_ error: Error?) { downloadError = error }

  func finalFolder(for model: String) -> URL {
    URL(fileURLWithPath: "/fake/models/\(model)", isDirectory: true)
  }

  func isPresent(_ model: String) -> Bool { present.contains(model) }
  func isDownloading(_ model: String) -> Bool { downloading.contains(model) }
  func listPresent() -> [String] { present.sorted() }

  func delete(_ model: String) throws {
    present.remove(model)
    deleted.append(model)
  }

  func download(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    downloads.append(model)
    if let downloadError { throw downloadError }
    progress(0.5)
    progress(1)
    present.insert(model)
    return finalFolder(for: model)
  }
}
