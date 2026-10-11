import AVFoundation
import ExpoModulesCore
import UIKit
import WhisperKit

public class ExpoWhisperKitModule: Module {
  private var engine: Engine!
  private var memoryWarningObserver: NSObjectProtocol?
  private var recorder: Recorder!
  private var sessionObservers: [NSObjectProtocol] = []
  private let progressThrottle = ProgressThrottle(interval: 0.25)

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
          guard let self, self.progressThrottle.shouldSend(model: model, fraction: fraction) else { return }
          self.sendEvent("downloadProgress", ["model": model, "fraction": fraction])
        }
      )
      self.memoryWarningObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
      ) { [weak self] _ in
        guard let engine = self?.engine else { return }
        Task { await engine.unload() }
      }
      self.recorder = Recorder(
        engine: self.engine,
        emitLevel: { [weak self] level in
          self?.sendEvent("audioLevel", ["level": level])
        },
        emitStreaming: { [weak self] confirmed, pending in
          self?.sendEvent("streamingUpdate", ["confirmedText": confirmed, "pendingText": pending])
        }
      )
      let center = NotificationCenter.default
      self.sessionObservers = [
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
          guard AudioInterruption.shouldInterrupt(userInfo: note.userInfo), let recorder = self?.recorder else { return }
          Task { await recorder.interrupt() }
        },
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
          guard let recorder = self?.recorder else { return }
          Task { await recorder.interrupt() }
        },
      ]
    }

    OnDestroy {
      if let observer = self.memoryWarningObserver {
        NotificationCenter.default.removeObserver(observer)
      }
      for observer in self.sessionObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      self.sessionObservers = []
      // A reload mid-capture must not leave the microphone tap and the audio session live.
      if let recorder = self.recorder {
        Task {
          await recorder.cancelRecording()
          await recorder.cancelStreaming()
        }
      }
    }

    // MARK: Models

    AsyncFunction("getModelStatus") { (model: String) async throws -> [String: Any] in
      try await self.bridged(fallback: .loadFailed) {
        let name = try ModelStore.validated(model)
        let state = await self.engine.status(of: name)
        return ["model": name, "state": state]
      }
    }

    AsyncFunction("downloadModel") { (model: String) async throws in
      try await self.bridged(fallback: .loadFailed) { try await self.engine.download(try ModelStore.validated(model)) }
    }

    AsyncFunction("deleteModel") { (model: String) async throws in
      try await self.bridged(fallback: .loadFailed) { try await self.engine.delete(try ModelStore.validated(model)) }
    }

    AsyncFunction("listDownloadedModels") { () async throws -> [String] in
      try await self.bridged(fallback: .loadFailed) { await self.engine.store.listPresent() }
    }

    AsyncFunction("loadModel") { (model: String) async throws in
      try await self.bridged(fallback: .loadFailed) {
        try await self.engine.ensureLoaded(try ModelStore.validated(model), download: true)
      }
    }

    AsyncFunction("unloadModel") { () async throws in
      try await self.bridged(fallback: .loadFailed) { await self.engine.unload() }
    }

    // MARK: Files

    AsyncFunction("transcribeFile") { (uri: String, options: DecodingRequestRecord) async throws -> [String: Any] in
      try await self.bridged(fallback: .decodeFailed) {
        _ = try ModelStore.validated(options.model)
        let path = Self.filePath(from: uri)
        guard FileManager.default.fileExists(atPath: path) else {
          throw WhisperKitError(.decodeFailed, "No file at \(path)")
        }
        return try await self.engine.transcribe(path: path, request: options.request)
      }
    }

    // MARK: Push-to-talk

    AsyncFunction("getMicrophonePermission") { () -> String in
      Recorder.permissionStatus()
    }

    AsyncFunction("requestMicrophonePermission") { () async -> String in
      await Recorder.requestPermission()
    }

    AsyncFunction("startRecording") { () async throws in
      try await self.bridged(fallback: .recordingFailed) { try await self.recorder.startRecording() }
    }

    AsyncFunction("stopRecording") { (options: DecodingRequestRecord) async throws -> [String: Any] in
      try await self.bridged(fallback: .decodeFailed) {
        _ = try ModelStore.validated(options.model)
        return try await self.recorder.stopRecording(request: options.request)
      }
    }

    AsyncFunction("cancelRecording") { () async throws in
      try await self.bridged(fallback: .recordingFailed) { await self.recorder.cancelRecording() }
    }

    // MARK: Streaming

    AsyncFunction("startStreaming") { (options: DecodingRequestRecord) async throws in
      try await self.bridged(fallback: .recordingFailed) {
        _ = try ModelStore.validated(options.model)
        try await self.recorder.startStreaming(request: options.request)
      }
    }

    AsyncFunction("stopStreaming") { () async throws -> [String: Any] in
      try await self.bridged(fallback: .decodeFailed) { try await self.recorder.stopStreaming() }
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

  static func filePath(from uri: String) -> String {
    if let url = URL(string: uri), url.isFileURL {
      return url.path
    }
    return uri
  }
}
