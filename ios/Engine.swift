import Foundation
import WhisperKit

typealias StateEmitter = @Sendable (_ model: String, _ state: String) -> Void
typealias ProgressEmitter = @Sendable (_ model: String, _ fraction: Double) -> Void

/// Owns at most one WhisperKit instance (spec §3.3). Serialises loading, decoding and the validating load of a download; a conflicting user-facing call gets busy instead of waiting, a download's validating load waits.
actor Engine {
  let store: any ModelStoring
  private let loader: ModelLoader
  private var whisperKit: (any SpeechModel)?
  private(set) var loadedModel: String?
  private var busy = false
  private var unloadAfterCurrent = false
  /// Downloads waiting for exclusivity (see `awaitExclusive`).
  private var exclusiveWaiters: [CheckedContinuation<Void, Never>] = []
  private let emitState: StateEmitter
  private let emitProgress: ProgressEmitter

  init(
    store: any ModelStoring,
    loader: @escaping ModelLoader = { config in try await WhisperKit(config) },
    emitState: @escaping StateEmitter,
    emitProgress: @escaping ProgressEmitter
  ) {
    self.store = store
    self.loader = loader
    self.emitState = emitState
    self.emitProgress = emitProgress
  }

  /// The loaded instance, for the streaming session (Task 7). Callers must hold exclusivity; nothing here checks it.
  var current: (any SpeechModel)? { whisperKit }

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

  /// Downloads `model`, validates it with a first load (which also caches the tokenizer), and
  /// moves it into place. The fetch runs without exclusivity so a download never blocks
  /// push-to-talk; the first load needs exclusivity so at most one WhisperKit instance exists,
  /// and waits for a running operation instead of throwing a finished download away with `busy`.
  func download(_ model: String) async throws {
    if await store.isPresent(model) {
      return
    }
    let staging = try await fetch(model)
    await awaitExclusive()
    do {
      try await validateAndCommitLocked(model, staging: staging)
    } catch {
      await endExclusive()
      throw error
    }
    await endExclusive()
  }

  /// The network part of a download. Emits `downloading` first and `absent` on failure.
  private func fetch(_ model: String) async throws -> URL {
    // Refuse a second download before emitting anything, so listeners never see a false "absent".
    if await store.isDownloading(model) {
      throw WhisperKitError(.busy, "Model \(model) is already downloading")
    }
    emitState(model, "downloading")
    do {
      let emitProgress = self.emitProgress
      return try await store.download(model) { fraction in emitProgress(model, fraction) }
    } catch let error as WhisperKitError where error.code == .busy {
      // Another download of this model won the race; its own events describe the state.
      throw error
    } catch {
      emitState(model, "absent")
      throw error
    }
  }

  /// The first load of a downloaded model, from its staging folder, then the move into place.
  /// Unloads whatever is loaded first so only the probe instance exists. The caller holds
  /// exclusivity. On failure the staging folder is discarded and the error is `download-failed`.
  private func validateAndCommitLocked(_ model: String, staging: URL) async throws {
    await unloadNow()
    let config = WhisperKitConfig(
      modelFolder: staging.path,
      tokenizerFolder: await store.tokenizersDir,
      verbose: false,
      logLevel: .error,
      prewarm: false,
      load: true,
      download: false
    )
    do {
      let probe = try await loader(config)
      await probe.unloadModels()
      try await store.commit(model)
      emitState(model, "present")
    } catch let error as WhisperKitError {
      await store.discard(model)
      emitState(model, "absent")
      throw error
    } catch {
      await store.discard(model)
      emitState(model, "absent")
      throw WhisperKitError(.downloadFailed, "Downloading \(model) failed: \(error.localizedDescription)", underlying: error)
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
  func beginExclusiveLoad(_ model: String, download: Bool) async throws -> any SpeechModel {
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
  private func loadLocked(_ model: String, download: Bool) async throws -> any SpeechModel {
    if let whisperKit, loadedModel == model {
      return whisperKit
    }
    if !(await store.isPresent(model)) {
      guard download else {
        throw WhisperKitError(.modelMissing, "Model \(model) is not downloaded")
      }
      let staging = try await fetch(model)
      try await validateAndCommitLocked(model, staging: staging)
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
      let instance = try await loader(config)
      whisperKit = instance
      loadedModel = model
      emitState(model, "loaded")
      return instance
    } catch {
      // A present model loaded once at download time; a failure now is environmental (memory
      // pressure, a compile cache), so the files are kept and the state is unchanged.
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
      try await instance.transcribe(path: path, options: request.decodingOptions(tokenizer: instance.tokenizer))
    }
  }

  func transcribe(samples: [Float], request: DecodingRequest) async throws -> [String: Any] {
    try await exclusiveTranscription(request) { instance in
      try await instance.transcribe(samples: samples, options: request.decodingOptions(tokenizer: instance.tokenizer))
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

  /// Takes exclusivity, waiting for the current operation to end instead of failing with `busy`.
  /// Only downloads use it (their validating load must not fail a finished download); every
  /// user-facing call keeps `beginExclusive`'s immediate `busy`. Returns with exclusivity held:
  /// `endExclusive` hands it over to the first waiter without clearing `busy` in between.
  private func awaitExclusive() async {
    if !busy {
      busy = true
      return
    }
    await withCheckedContinuation { exclusiveWaiters.append($0) }
  }

  /// Runs any deferred unload first, then hands exclusivity to a waiting download, or releases it.
  func endExclusive() async {
    while unloadAfterCurrent {
      unloadAfterCurrent = false
      await unloadNow()
    }
    if !exclusiveWaiters.isEmpty {
      exclusiveWaiters.removeFirst().resume()
      return
    }
    busy = false
  }

  /// One exclusive section covering load and decode, so a deferred unload (memory warning) runs
  /// only after decoding finishes. `endExclusive` runs exactly once on every path.
  private func exclusiveTranscription(
    _ request: DecodingRequest,
    _ body: (any SpeechModel) async throws -> [TranscriptionResult]
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
