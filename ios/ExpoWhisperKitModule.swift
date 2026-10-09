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

    AsyncFunction("getModelStatus") { (model: String) async -> [String: Any] in
      ["model": model, "state": await self.engine.status(of: model)]
    }

    AsyncFunction("downloadModel") { (model: String) async throws in
      try await self.bridged { try await self.engine.download(model) }
    }

    AsyncFunction("deleteModel") { (model: String) async throws in
      try await self.bridged { try await self.engine.delete(model) }
    }

    AsyncFunction("listDownloadedModels") { () async -> [String] in
      await self.engine.store.listPresent()
    }

    AsyncFunction("loadModel") { (model: String) async throws in
      try await self.bridged { _ = try await self.engine.ensureLoaded(model, download: true) }
    }

    AsyncFunction("unloadModel") { () async in
      await self.engine.unload()
    }

    // MARK: Files

    AsyncFunction("transcribeFile") { (uri: String, options: DecodingRequest) async throws -> [String: Any] in
      let path = Self.filePath(from: uri)
      guard FileManager.default.fileExists(atPath: path) else {
        throw WhisperKitError(.decodeFailed, "No file at \(path)").asException()
      }
      return try await self.bridged { try await self.engine.transcribe(path: path, request: options) }
    }

    // MARK: Testing

    AsyncFunction("simulateMemoryWarningForTesting") { () async in
      await MainActor.run {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
      }
    }
  }

  /// Converts the Swift error into the Expo exception that carries the same code to JS.
  func bridged<T>(_ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let error as WhisperKitError {
      throw error.asException()
    }
  }

  static func filePath(from uri: String) -> String {
    if let url = URL(string: uri), url.isFileURL {
      return url.path
    }
    return uri
  }
}
