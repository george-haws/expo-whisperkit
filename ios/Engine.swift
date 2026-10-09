import Foundation
import WhisperKit

typealias StateEmitter = @Sendable (_ model: String, _ state: String) -> Void
typealias ProgressEmitter = @Sendable (_ model: String, _ fraction: Double) -> Void

/// Owns at most one `WhisperKit` instance (spec §3.3). Serialises loading and decoding; a
/// conflicting call gets `busy` instead of waiting.
actor Engine {
  let store: ModelStore
  private var whisperKit: WhisperKit?
  private(set) var loadedModel: String?
  private var busy = false
  private var unloadAfterCurrent = false
  private let emitState: StateEmitter
  private let emitProgress: ProgressEmitter

  init(store: ModelStore, emitState: @escaping StateEmitter, emitProgress: @escaping ProgressEmitter) {
    self.store = store
    self.emitState = emitState
    self.emitProgress = emitProgress
  }

  /// The loaded instance, for the streaming session (Task 7).
  var current: WhisperKit? { whisperKit }

  var isBusy: Bool { busy }

  func status(of model: String) async -> String {
    if whisperKit != nil, loadedModel == model {
      return "loaded"
    }
    if await store.isDownloading(model) {
      return "downloading"
    }
    return await store.isPresent(model) ? "present" : "absent"
  }

  func download(_ model: String) async throws {
    if await store.isPresent(model) {
      return
    }
    emitState(model, "downloading")
    do {
      let emitProgress = self.emitProgress
      _ = try await store.download(model) { fraction in emitProgress(model, fraction) }
      emitState(model, "present")
    } catch {
      emitState(model, "absent")
      throw error
    }
  }

  func delete(_ model: String) async throws {
    if loadedModel == model {
      await unloadNow()
    }
    try await store.delete(model)
    emitState(model, "absent")
  }

  func ensureLoaded(_ model: String, download: Bool) async throws -> WhisperKit {
    if let whisperKit, loadedModel == model {
      return whisperKit
    }
    if busy {
      throw WhisperKitError(.busy, "Another operation is running")
    }
    if !(await store.isPresent(model)) {
      guard download else {
        throw WhisperKitError(.modelMissing, "Model \(model) is not downloaded")
      }
      try await self.download(model)
      if busy {
        throw WhisperKitError(.busy, "Another operation is running")
      }
    }
    busy = true
    defer { busy = false }
    await unloadNow()
    let folder = await store.finalFolder(for: model)
    let config = WhisperKitConfig(
      modelFolder: folder.path,
      tokenizerFolder: await store.tokenizersDir,
      verbose: false,
      logLevel: .error,
      prewarm: true,
      load: true,
      download: false
    )
    do {
      let instance = try await WhisperKit(config)
      whisperKit = instance
      loadedModel = model
      emitState(model, "loaded")
      return instance
    } catch {
      try? await store.delete(model)
      emitState(model, "absent")
      throw WhisperKitError(.loadFailed, "Loading \(model) failed: \(error.localizedDescription)", underlying: error)
    }
  }

  /// Memory warning or explicit unload. Deferred until the current transcription finishes.
  func unload() async {
    if busy {
      unloadAfterCurrent = true
      return
    }
    await unloadNow()
  }

  private func unloadNow() async {
    guard let instance = whisperKit else { return }
    await instance.unloadModels()
    let model = loadedModel
    whisperKit = nil
    loadedModel = nil
    if let model {
      emitState(model, "present")
    }
  }

  func transcribe(path: String, request: DecodingRequest) async throws -> [String: Any] {
    let instance = try await ensureLoaded(request.model, download: request.download)
    return try await decode(with: instance) {
      try await instance.transcribe(audioPath: path, decodeOptions: request.decodingOptions(tokenizer: instance.tokenizer))
    }
  }

  func transcribe(samples: [Float], request: DecodingRequest) async throws -> [String: Any] {
    let instance = try await ensureLoaded(request.model, download: request.download)
    return try await decode(with: instance) {
      try await instance.transcribe(audioArray: samples, decodeOptions: request.decodingOptions(tokenizer: instance.tokenizer))
    }
  }

  /// Marks the engine busy for the duration of a streaming session (Task 7).
  func beginExclusive() throws {
    if busy {
      throw WhisperKitError(.busy, "Another operation is running")
    }
    busy = true
  }

  func endExclusive() async {
    busy = false
    if unloadAfterCurrent {
      unloadAfterCurrent = false
      await unloadNow()
    }
  }

  private func decode(with instance: WhisperKit, _ body: () async throws -> [TranscriptionResult]) async throws -> [String: Any] {
    try beginExclusive()
    do {
      let results = try await body()
      await endExclusive()
      if Task.isCancelled {
        throw WhisperKitError(.cancelled, "Transcription was cancelled")
      }
      return Payloads.merged(results)
    } catch let error as WhisperKitError {
      await endExclusive()
      throw error
    } catch {
      await endExclusive()
      throw WhisperKitError(.decodeFailed, "Transcription failed: \(error.localizedDescription)", underlying: error)
    }
  }
}
