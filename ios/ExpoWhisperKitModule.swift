import ExpoModulesCore
import UIKit
import WhisperKit

public class ExpoWhisperKitModule: Module {
  private var engine: Engine!
  private var memoryWarningObserver: NSObjectProtocol?
  private let progressThrottle = Throttle(interval: 0.25)

  public func definition() -> ModuleDefinition {
    Name("ExpoWhisperKit")

    Events("downloadProgress", "modelState", "audioLevel", "streamingUpdate")

    OnCreate {
      let store = ModelStore()
      self.engine = Engine(
        store: store,
        emitState: { [weak self] model, state in
          self?.sendEvent("modelState", ["model": model, "state": state])
        },
        emitProgress: { [weak self] model, fraction in
          guard let self, self.progressThrottle.shouldSend(force: fraction >= 1) else { return }
          self.sendEvent("downloadProgress", ["model": model, "fraction": fraction])
        }
      )
      self.memoryWarningObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
      ) { [weak self] _ in
        guard let engine = self?.engine else { return }
        Task { await engine.unload() }
      }
    }

    OnDestroy {
      if let observer = self.memoryWarningObserver {
        NotificationCenter.default.removeObserver(observer)
      }
    }

    // MARK: Models

    AsyncFunction("getModelStatus") { (model: String) async throws -> [String: Any] in
      try await self.bridged(fallback: .loadFailed) {
        let name = try Self.validated(model)
        let state = await self.engine.status(of: name)
        return ["model": name, "state": state]
      }
    }

    AsyncFunction("downloadModel") { (model: String) async throws in
      try await self.bridged(fallback: .loadFailed) { try await self.engine.download(try Self.validated(model)) }
    }

    AsyncFunction("deleteModel") { (model: String) async throws in
      try await self.bridged(fallback: .loadFailed) { try await self.engine.delete(try Self.validated(model)) }
    }

    AsyncFunction("listDownloadedModels") { () async throws -> [String] in
      try await self.bridged(fallback: .loadFailed) { await self.engine.store.listPresent() }
    }

    AsyncFunction("loadModel") { (model: String) async throws in
      try await self.bridged(fallback: .loadFailed) {
        try await self.engine.ensureLoaded(try Self.validated(model), download: true)
      }
    }

    AsyncFunction("unloadModel") { () async throws in
      try await self.bridged(fallback: .loadFailed) { await self.engine.unload() }
    }

    // MARK: Files

    AsyncFunction("transcribeFile") { (uri: String, options: DecodingRequest) async throws -> [String: Any] in
      try await self.bridged(fallback: .decodeFailed) {
        _ = try Self.validated(options.model)
        let path = Self.filePath(from: uri)
        guard FileManager.default.fileExists(atPath: path) else {
          throw WhisperKitError(.decodeFailed, "No file at \(path)")
        }
        return try await self.engine.transcribe(path: path, request: options)
      }
    }

    // MARK: Testing

    AsyncFunction("simulateMemoryWarningForTesting") { () async in
      await MainActor.run {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
      }
    }
  }

  /// Converts any Swift error into the Expo exception that carries a WhisperKitError code to JS.
  /// Errors that are not already a `WhisperKitError` are wrapped with `fallback`.
  func bridged<T>(fallback: WhisperKitErrorCode, _ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let error as WhisperKitError {
      throw error.asException()
    } catch {
      throw WhisperKitError(fallback, error.localizedDescription, underlying: error).asException()
    }
  }

  /// Rejects names that would escape or alias the models folder: "" and "." target the folder
  /// itself, ".." the whole store, and "/" a nested path. Hidden names (leading ".") are refused too.
  static func validated(_ model: String) throws -> String {
    if model.isEmpty || model.hasPrefix(".") || model.contains("/") || model.contains("..") {
      throw WhisperKitError(.modelMissing, "Invalid model name")
    }
    return model
  }

  static func filePath(from uri: String) -> String {
    if let url = URL(string: uri), url.isFileURL {
      return url.path
    }
    return uri
  }
}
