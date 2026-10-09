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
    // Refuse a second download before emitting anything, so listeners never see a false "absent".
    if await store.isDownloading(model) {
      throw WhisperKitError(.busy, "Model \(model) is already downloading")
    }
    emitState(model, "downloading")
    do {
      let emitProgress = self.emitProgress
      _ = try await store.download(model) { fraction in emitProgress(model, fraction) }
      emitState(model, "present")
    } catch let error as WhisperKitError where error.code == .busy {
      // Another download of this model won the race; its own events describe the state.
      throw error
    } catch {
      emitState(model, "absent")
      throw error
    }
  }

  func delete(_ model: String) async throws {
    // Hold exclusivity for the whole delete so no load or decode can start during its awaits.
    try beginExclusive()
    do {
      if await store.isDownloading(model) {
        throw WhisperKitError(.busy, "Model \(model) is downloading")
      }
      if loadedModel == model {
        await unloadNow()
      }
      try await store.delete(model)
      emitState(model, "absent")
    } catch {
      await endExclusive()
      throw error
    }
    await endExclusive()
  }

  /// Loads `model` (downloading it first if `download` is set). Used by `loadModel`; it returns
  /// nothing because an instance handed out after exclusivity ends could already be unloading.
  func ensureLoaded(_ model: String, download: Bool) async throws {
    if whisperKit != nil, loadedModel == model {
      return
    }
    try beginExclusive()
    do {
      _ = try await loadLocked(model, download: download)
    } catch {
      await endExclusive()
      throw error
    }
    // Exit through endExclusive so a memory warning that arrived during the load is honoured now.
    await endExclusive()
  }

  /// Takes exclusivity and loads `model`. On success the instance is returned with exclusivity
  /// STILL HELD: the caller must call `endExclusive()` when done (streaming, Task 7). On failure
  /// exclusivity is released before the error is rethrown.
  func beginExclusiveLoad(_ model: String, download: Bool) async throws -> WhisperKit {
    try beginExclusive()
    do {
      return try await loadLocked(model, download: download)
    } catch {
      await endExclusive()
      throw error
    }
  }

  /// Downloads if needed, unloads any other model, and loads `model`. The caller must already
  /// hold exclusivity (`beginExclusive`), so nothing here checks or changes `busy`.
  private func loadLocked(_ model: String, download: Bool) async throws -> WhisperKit {
    if let whisperKit, loadedModel == model {
      return whisperKit
    }
    if !(await store.isPresent(model)) {
      guard download else {
        throw WhisperKitError(.modelMissing, "Model \(model) is not downloaded")
      }
      try await self.download(model)
    }
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
    // Detach first, so no fast path can observe an instance that is being unloaded.
    let model = loadedModel
    whisperKit = nil
    loadedModel = nil
    if let model {
      emitState(model, "present")
    }
    await instance.unloadModels()
  }

  func transcribe(path: String, request: DecodingRequest) async throws -> [String: Any] {
    try await exclusiveTranscription(request) { instance in
      try await instance.transcribe(audioPath: path, decodeOptions: request.decodingOptions(tokenizer: instance.tokenizer))
    }
  }

  func transcribe(samples: [Float], request: DecodingRequest) async throws -> [String: Any] {
    try await exclusiveTranscription(request) { instance in
      try await instance.transcribe(audioArray: samples, decodeOptions: request.decodingOptions(tokenizer: instance.tokenizer))
    }
  }

  /// Marks the engine busy: a single synchronous check-and-set (no await), so actor reentrancy
  /// cannot let two callers through. Used by loads, transcriptions and streaming (Task 7).
  func beginExclusive() throws {
    if busy {
      throw WhisperKitError(.busy, "Another operation is running")
    }
    busy = true
  }

  /// Runs any deferred unload first and releases `busy` only after it completes.
  func endExclusive() async {
    while unloadAfterCurrent {
      unloadAfterCurrent = false
      await unloadNow()
    }
    busy = false
  }

  /// One exclusive section covering load and decode, so a deferred unload (memory warning) runs
  /// only after decoding finishes. `endExclusive` runs exactly once on every path.
  private func exclusiveTranscription(
    _ request: DecodingRequest,
    _ body: (WhisperKit) async throws -> [TranscriptionResult]
  ) async throws -> [String: Any] {
    try beginExclusive()
    let results: [TranscriptionResult]
    do {
      let instance = try await loadLocked(request.model, download: request.download)
      results = try await body(instance)
    } catch let error as WhisperKitError {
      await endExclusive()
      throw error
    } catch is CancellationError {
      await endExclusive()
      throw WhisperKitError(.cancelled, "Transcription was cancelled")
    } catch {
      await endExclusive()
      throw WhisperKitError(.decodeFailed, "Transcription failed: \(error.localizedDescription)", underlying: error)
    }
    await endExclusive()
    if Task.isCancelled {
      throw WhisperKitError(.cancelled, "Transcription was cancelled")
    }
    return Payloads.merged(results)
  }
}
