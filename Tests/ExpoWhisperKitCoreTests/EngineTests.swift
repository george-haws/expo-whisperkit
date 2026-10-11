import XCTest
import WhisperKit
@testable import ExpoWhisperKitCore

/// Collects emitted events from any thread.
final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var _states: [String] = []
  private var _progress: [Double] = []
  var states: [String] { lock.lock(); defer { lock.unlock() }; return _states }
  var progress: [Double] { lock.lock(); defer { lock.unlock() }; return _progress }
  func recordState(_ model: String, _ state: String) { lock.lock(); _states.append("\(model):\(state)"); lock.unlock() }
  func recordProgress(_ model: String, _ fraction: Double) { lock.lock(); _progress.append(fraction); lock.unlock() }
}

/// Counts loader calls and can hold the load open.
final class LoaderSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var _calls = 0
  private var _configs: [WhisperKitConfig] = []
  var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
  var configs: [WhisperKitConfig] { lock.lock(); defer { lock.unlock() }; return _configs }
  var error: Error?
  var gate: Gate?

  private func record(_ config: WhisperKitConfig) {
    lock.lock(); _calls += 1; _configs.append(config); lock.unlock()
  }

  func loader(returning model: FakeModel) -> ExpoWhisperKitCore.ModelLoader {
    { config in
      self.record(config)
      if let gate = self.gate { await gate.wait() }
      if let error = self.error { throw error }
      return model
    }
  }
}

func code(_ error: Error) -> WhisperKitErrorCode? { (error as? WhisperKitError)?.code }

/// Polls until `condition` holds, for at most two seconds.
func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
  for _ in 0..<200 {
    if await condition() { return }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  XCTFail("condition not met within 2 s", file: file, line: line)
}

final class EngineTests: XCTestCase {
  private var store: FakeStore!
  private var model: FakeModel!
  private var loader: LoaderSpy!
  private var events: EventLog!
  private var engine: Engine!

  override func setUp() async throws {
    store = FakeStore()
    await store.setPresent(["base"])
    model = FakeModel()
    loader = LoaderSpy()
    events = EventLog()
    let events = self.events!
    engine = Engine(
      store: store,
      loader: loader.loader(returning: model),
      emitState: { events.recordState($0, $1) },
      emitProgress: { events.recordProgress($0, $1) }
    )
  }

  private var request: DecodingRequest { DecodingRequest() }

  // MARK: Loading and transcribing

  func testTranscribeLoadsThePresentModelAndEmitsLoaded() async throws {
    let result = try await engine.transcribe(samples: [0.1, 0.2], request: request)
    XCTAssertEqual(result["text"] as? String, "hello")
    XCTAssertEqual(result["language"] as? String, "en")
    XCTAssertEqual(model.lastSamples, [0.1, 0.2])
    XCTAssertEqual(events.states, ["base:loaded"])
    let loaded = await engine.loadedModel
    XCTAssertEqual(loaded, "base")
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testLoaderGetsTheFinalFolderAndTheTokenizerFolder() async throws {
    _ = try await engine.transcribe(samples: [0.1], request: request)
    let config = try XCTUnwrap(loader.configs.first)
    XCTAssertEqual(config.modelFolder, "/fake/models/base")
    XCTAssertEqual(config.tokenizerFolder?.path, "/fake/tokenizers")
    XCTAssertEqual(config.download, false)
  }

  func testTranscribeByPathForwardsThePath() async throws {
    _ = try await engine.transcribe(path: "/tmp/clip.wav", request: request)
    XCTAssertEqual(model.lastPath, "/tmp/clip.wav")
  }

  func testSecondTranscribeOfTheSameModelLoadsOnce() async throws {
    _ = try await engine.transcribe(samples: [0.1], request: request)
    _ = try await engine.transcribe(samples: [0.2], request: request)
    XCTAssertEqual(loader.calls, 1)
    XCTAssertEqual(events.states, ["base:loaded"])
  }

  func testTranscribeDownloadsAnAbsentModelWhenAllowed() async throws {
    await store.setPresent([])
    _ = try await engine.transcribe(samples: [0.1], request: request)
    let downloads = await store.downloads
    XCTAssertEqual(downloads, ["base"])
    let committed = await store.committed
    XCTAssertEqual(committed, ["base"])
    XCTAssertEqual(events.states, ["base:downloading", "base:present", "base:loaded"])
    XCTAssertEqual(events.progress, [0.5, 1])
    // The probe loads from staging without prewarm; the real load from the final folder with it.
    XCTAssertEqual(loader.calls, 2)
    XCTAssertEqual(loader.configs[0].modelFolder, "/fake/downloads/base")
    XCTAssertEqual(loader.configs[0].prewarm, false)
    XCTAssertEqual(loader.configs[1].modelFolder, "/fake/models/base")
    XCTAssertEqual(loader.configs[1].prewarm, true)
  }

  func testTranscribeWithoutDownloadIsModelMissing() async {
    await store.setPresent([])
    do {
      _ = try await engine.transcribe(samples: [0.1], request: DecodingRequest(download: false))
      XCTFail("expected model-missing")
    } catch {
      XCTAssertEqual(code(error), .modelMissing)
    }
    XCTAssertEqual(events.states, [])
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testLoadFailureKeepsThePresentModelAndEmitsNothing() async {
    // Finding 7: a present model loaded once at download time, so a later failure is
    // environmental (memory pressure), not a corrupt file. The files stay.
    loader.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "out of memory"])
    do {
      _ = try await engine.transcribe(samples: [0.1], request: request)
      XCTFail("expected load-failed")
    } catch {
      XCTAssertEqual(code(error), .loadFailed)
      XCTAssertEqual((error as? WhisperKitError)?.message, "Loading base failed: out of memory")
    }
    let deleted = await store.deleted
    XCTAssertEqual(deleted, [])
    XCTAssertEqual(events.states, [])
    let status = await engine.status(of: "base")
    XCTAssertEqual(status, "present")
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testDecodeErrorIsDecodeFailedAndReleasesTheEngine() async {
    model.setResult(.failure(NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "boom"])))
    do {
      _ = try await engine.transcribe(samples: [0.1], request: request)
      XCTFail("expected decode-failed")
    } catch {
      XCTAssertEqual(code(error), .decodeFailed)
    }
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  // MARK: Exclusivity

  func testSecondTranscribeWhileTheFirstRunsIsBusy() async throws {
    let gate = Gate()
    model.transcribeGate = gate
    let engine = self.engine!
    let first = Task { try await engine.transcribe(samples: [0.1], request: self.request) }
    let model = self.model!
    await eventually { model.transcribeCalls == 1 }
    do {
      _ = try await engine.transcribe(samples: [0.2], request: request)
      XCTFail("expected busy")
    } catch {
      XCTAssertEqual(code(error), .busy)
    }
    await gate.open()
    let result = try await first.value
    XCTAssertEqual(result["text"] as? String, "hello")
    XCTAssertEqual(model.transcribeCalls, 1)
  }

  func testUnloadWhileBusyIsDeferredUntilTheTranscriptionEnds() async throws {
    let gate = Gate()
    model.transcribeGate = gate
    let engine = self.engine!
    let first = Task { try await engine.transcribe(samples: [0.1], request: self.request) }
    let model = self.model!
    await eventually { model.transcribeCalls == 1 }
    await engine.unload()
    XCTAssertEqual(model.unloads, 0)
    let stillLoaded = await engine.loadedModel
    XCTAssertEqual(stillLoaded, "base")
    await gate.open()
    _ = try await first.value
    XCTAssertEqual(model.unloads, 1)
    let loaded = await engine.loadedModel
    XCTAssertNil(loaded)
    XCTAssertEqual(events.states, ["base:loaded", "base:present"])
  }

  func testUnloadWhenIdleUnloadsNow() async throws {
    try await engine.ensureLoaded("base", download: true)
    await engine.unload()
    XCTAssertEqual(model.unloads, 1)
    XCTAssertEqual(events.states, ["base:loaded", "base:present"])
    let current = await engine.current
    XCTAssertNil(current)
  }

  func testUnloadWithNothingLoadedIsANoop() async {
    await engine.unload()
    XCTAssertEqual(model.unloads, 0)
    XCTAssertEqual(events.states, [])
  }

  func testBeginExclusiveLoadKeepsExclusivityUntilEndExclusive() async throws {
    let instance = try await engine.beginExclusiveLoad("base", download: true)
    XCTAssertTrue(instance === model)
    let busy = await engine.isBusy
    XCTAssertTrue(busy)
    do {
      _ = try await engine.transcribe(samples: [0.1], request: request)
      XCTFail("expected busy")
    } catch {
      XCTAssertEqual(code(error), .busy)
    }
    await engine.endExclusive()
    let released = await engine.isBusy
    XCTAssertFalse(released)
  }

  // MARK: Download, delete, status

  func testDownloadEmitsDownloadingThenPresentAndProbesOnce() async throws {
    await store.setPresent([])
    try await engine.download("base")
    XCTAssertEqual(events.states, ["base:downloading", "base:present"])
    XCTAssertEqual(loader.calls, 1)
    XCTAssertEqual(loader.configs[0].modelFolder, "/fake/downloads/base")
    XCTAssertEqual(model.unloads, 1, "the probe instance is unloaded after validating")
    let committed = await store.committed
    XCTAssertEqual(committed, ["base"])
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
    let loaded = await engine.loadedModel
    XCTAssertNil(loaded)
  }

  func testDownloadOfAPresentModelEmitsNothing() async throws {
    try await engine.download("base")
    XCTAssertEqual(events.states, [])
    let downloads = await store.downloads
    XCTAssertEqual(downloads, [])
  }

  func testDownloadWhileDownloadingIsBusyBeforeAnyEvent() async {
    await store.setPresent([])
    await store.setDownloading(["base"])
    do {
      try await engine.download("base")
      XCTFail("expected busy")
    } catch {
      XCTAssertEqual(code(error), .busy)
    }
    XCTAssertEqual(events.states, [])
  }

  func testDownloadFailureEmitsAbsentAndRethrows() async {
    await store.setPresent([])
    await store.setDownloadError(WhisperKitError(.downloadFailed, "Downloading base failed: offline"))
    do {
      try await engine.download("base")
      XCTFail("expected download-failed")
    } catch {
      XCTAssertEqual(code(error), .downloadFailed)
    }
    XCTAssertEqual(events.states, ["base:downloading", "base:absent"])
  }

  func testProbeFailureDiscardsTheStagingFolderAndIsDownloadFailed() async {
    await store.setPresent([])
    loader.error = NSError(domain: "test", code: 5, userInfo: [NSLocalizedDescriptionKey: "corrupt"])
    do {
      try await engine.download("base")
      XCTFail("expected download-failed")
    } catch {
      XCTAssertEqual(code(error), .downloadFailed)
      XCTAssertEqual((error as? WhisperKitError)?.message, "Downloading base failed: corrupt")
    }
    let discarded = await store.discarded
    XCTAssertEqual(discarded, ["base"])
    let committed = await store.committed
    XCTAssertEqual(committed, [])
    XCTAssertEqual(events.states, ["base:downloading", "base:absent"])
    let present = await store.isPresent("base")
    XCTAssertFalse(present)
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testDownloadUnloadsTheLoadedModelBeforeTheProbe() async throws {
    // Finding 6: never two instances. The loaded model is unloaded before the probe load.
    await store.setPresent(["tiny"])
    try await engine.ensureLoaded("tiny", download: false)
    XCTAssertEqual(model.unloads, 0)
    try await engine.download("base")
    XCTAssertEqual(model.unloads, 2, "the loaded model, then the probe")
    XCTAssertEqual(events.states, ["tiny:loaded", "base:downloading", "tiny:present", "base:present"])
    let loaded = await engine.loadedModel
    XCTAssertNil(loaded)
  }

  func testDownloadWaitsForARunningTranscriptionInsteadOfFailingBusy() async throws {
    // Finding 6: the validating load needs exclusivity, and a finished download must not be
    // thrown away with `busy`, so the download waits for the running operation.
    await store.setPresent(["tiny"])
    let gate = Gate()
    model.transcribeGate = gate
    let engine = self.engine!
    let decode = Task { try await engine.transcribe(samples: [0.1], request: DecodingRequest(model: "tiny")) }
    let model = self.model!
    await eventually { model.transcribeCalls == 1 }
    let downloaded = Flag()
    let download = Task {
      try await engine.download("base")
      downloaded.set()
    }
    let store = self.store!
    await eventually { await store.isDownloading("base") }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(downloaded.isSet, "the probe waits for the decode")
    let committedEarly = await store.committed
    XCTAssertEqual(committedEarly, [])
    await gate.open()
    _ = try await decode.value
    try await download.value
    let committed = await store.committed
    XCTAssertEqual(committed, ["base"])
    XCTAssertEqual(events.states, ["tiny:loaded", "base:downloading", "tiny:present", "base:present"])
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testDeleteOfTheLoadedModelUnloadsFirst() async throws {
    try await engine.ensureLoaded("base", download: true)
    try await engine.delete("base")
    XCTAssertEqual(model.unloads, 1)
    let deleted = await store.deleted
    XCTAssertEqual(deleted, ["base"])
    XCTAssertEqual(events.states, ["base:loaded", "base:present", "base:absent"])
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testDeleteWhileDownloadingIsBusy() async {
    await store.setDownloading(["base"])
    do {
      try await engine.delete("base")
      XCTFail("expected busy")
    } catch {
      XCTAssertEqual(code(error), .busy)
    }
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testStatusReportsEachState() async throws {
    var status = await engine.status(of: "tiny")
    XCTAssertEqual(status, "absent")
    await store.setDownloading(["tiny"])
    status = await engine.status(of: "tiny")
    XCTAssertEqual(status, "downloading")
    status = await engine.status(of: "base")
    XCTAssertEqual(status, "present")
    try await engine.ensureLoaded("base", download: true)
    status = await engine.status(of: "base")
    XCTAssertEqual(status, "loaded")
  }
}
