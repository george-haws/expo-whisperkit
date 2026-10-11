import Foundation
import WhisperKit

/// The store calls Engine makes, so tests can substitute an in-memory store.
protocol ModelStoring: Actor {
  var tokenizersDir: URL { get }
  func finalFolder(for model: String) -> URL
  func isPresent(_ model: String) -> Bool
  func isDownloading(_ model: String) -> Bool
  func listPresent() -> [String]
  func delete(_ model: String) throws
  func download(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// Where models live and how they get there (spec §3.3).
///
///   <Application Support>/expo-whisperkit/models/<name>     final, "present"
///   <Application Support>/expo-whisperkit/downloads/<name>  in flight, cleared on launch and failure
///   <Application Support>/expo-whisperkit/tokenizers        WhisperKit's tokenizer cache, so loads work offline
actor ModelStore: ModelStoring {
  let root: URL
  let modelsDir: URL
  let downloadsDir: URL
  let tokenizersDir: URL
  private var downloading: Set<String> = []

  /// Names are limited to `A-Z a-z 0-9 . _ -`, which covers every WhisperKit variant name. The
  /// empty name and "." target the models folder itself, ".." the whole store, so they and any
  /// hidden name (leading ".") are refused too. Everything else never reaches the filesystem or
  /// the Hub search pattern.
  private static let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

  static func validated(_ model: String) throws -> String {
    if model.isEmpty || model.hasPrefix(".") || model.contains("..")
      || !model.allSatisfy({ allowedCharacters.contains($0) }) {
      throw WhisperKitError(.modelMissing, "Invalid model name")
    }
    return model
  }

  init() {
    let support = (try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )) ?? FileManager.default.temporaryDirectory
    self.init(root: support.appendingPathComponent("expo-whisperkit", isDirectory: true))
  }

  /// `root` is the `expo-whisperkit` folder itself; tests pass a temp folder.
  init(root: URL) {
    self.root = root
    modelsDir = root.appendingPathComponent("models", isDirectory: true)
    downloadsDir = root.appendingPathComponent("downloads", isDirectory: true)
    tokenizersDir = root.appendingPathComponent("tokenizers", isDirectory: true)
    try? FileManager.default.removeItem(at: downloadsDir)
    for dir in [modelsDir, downloadsDir, tokenizersDir] {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    var excluded = root
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? excluded.setResourceValues(values)
  }

  func finalFolder(for model: String) -> URL {
    modelsDir.appendingPathComponent(model, isDirectory: true)
  }

  func isPresent(_ model: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: finalFolder(for: model).path, isDirectory: &isDir) && isDir.boolValue
  }

  func isDownloading(_ model: String) -> Bool {
    downloading.contains(model)
  }

  func listPresent() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
    return names.filter { isPresent($0) }.sorted()
  }

  func delete(_ model: String) throws {
    for url in [finalFolder(for: model), downloadsDir.appendingPathComponent(model, isDirectory: true)] {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  /// Downloads `model`, performs one load (validates the files and caches the tokenizer), then
  /// moves the folder into place. Returns the final folder.
  func download(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    if isPresent(model) {
      return finalFolder(for: model)
    }
    guard !downloading.contains(model) else {
      throw WhisperKitError(.busy, "Model \(model) is already downloading")
    }
    downloading.insert(model)
    defer { downloading.remove(model) }

    let base = downloadsDir.appendingPathComponent(model, isDirectory: true)
    try? FileManager.default.removeItem(at: base)

    do {
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      let folder = try await WhisperKit.download(
        variant: model,
        downloadBase: base,
        progressCallback: { p in progress(p.fractionCompleted) }
      )
      progress(1)
      // First load. If this throws the files are unusable; the caller sees download-failed.
      let config = WhisperKitConfig(
        modelFolder: folder.path,
        tokenizerFolder: tokenizersDir,
        verbose: false,
        logLevel: .error,
        prewarm: false,
        load: true,
        download: false
      )
      let probe = try await WhisperKit(config)
      await probe.unloadModels()

      let final = finalFolder(for: model)
      try? FileManager.default.removeItem(at: final)
      try FileManager.default.moveItem(at: folder, to: final)
      try? FileManager.default.removeItem(at: base)
      return final
    } catch let error as WhisperKitError {
      try? FileManager.default.removeItem(at: base)
      throw error
    } catch {
      try? FileManager.default.removeItem(at: base)
      throw WhisperKitError(.downloadFailed, "Downloading \(model) failed: \(error.localizedDescription)", underlying: error)
    }
  }
}
