import XCTest
import WhisperKit
@testable import ExpoWhisperKitCore

/// Collects Recorder events from any thread.
final class RecorderEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var _levels: [Float] = []
  private var _streaming: [String] = []
  var levels: [Float] { lock.lock(); defer { lock.unlock() }; return _levels }
  /// "confirmed|pending" per update.
  var streaming: [String] { lock.lock(); defer { lock.unlock() }; return _streaming }
  func recordLevel(_ value: Float) { lock.lock(); _levels.append(value); lock.unlock() }
  func recordStreaming(_ confirmed: String, _ pending: String) { lock.lock(); _streaming.append("\(confirmed)|\(pending)"); lock.unlock() }
}

final class RecorderTests: XCTestCase {
  private var store: FakeStore!
  private var model: FakeModel!
  private var loader: LoaderSpy!
  private var processor: FakeProcessor!
  private var events: RecorderEvents!
  private var engine: Engine!

  override func setUp() async throws {
    store = FakeStore()
    await store.setPresent(["base"])
    model = FakeModel()
    loader = LoaderSpy()
    processor = FakeProcessor()
    events = RecorderEvents()
    engine = Engine(store: store, loader: loader.loader(returning: model), emitState: { _, _ in }, emitProgress: { _, _ in })
  }

  private func makeRecorder(permission: String = "granted") -> Recorder {
    let events = self.events!
    return Recorder(
      engine: engine,
      processor: processor,
      permission: { permission },
      emitLevel: { events.recordLevel($0) },
      emitStreaming: { events.recordStreaming($0, $1) }
    )
  }

  private var request: DecodingRequest { DecodingRequest() }

  // MARK: Push-to-talk

  func testStartRecordingNeedsPermission() async {
    let recorder = makeRecorder(permission: "denied")
    do {
      try await recorder.startRecording()
      XCTFail("expected permission-denied")
    } catch {
      XCTAssertEqual(code(error), .permissionDenied)
    }
    XCTAssertEqual(processor.startCalls, 0)
  }

  func testStartRecordingStartsTheProcessor() async throws {
    let recorder = makeRecorder()
    try await recorder.startRecording()
    XCTAssertTrue(processor.isRecording)
    let mode = await recorder.mode
    XCTAssertEqual(mode, .recording)
  }

  func testStartRecordingTwiceIsBusy() async throws {
    let recorder = makeRecorder()
    try await recorder.startRecording()
    do {
      try await recorder.startRecording()
      XCTFail("expected busy")
    } catch {
      XCTAssertEqual(code(error), .busy)
    }
  }

  func testStartRecordingFailureIsRecordingFailedAndCleansUp() async {
    processor.setStartError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input"]))
    let recorder = makeRecorder()
    do {
      try await recorder.startRecording()
      XCTFail("expected recording-failed")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
      XCTAssertEqual((error as? WhisperKitError)?.message, "Could not start the microphone: no input")
    }
    XCTAssertEqual(processor.stopCalls, 1)
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
  }

  func testStopRecordingTranscribesTheCapturedAudio() async throws {
    let recorder = makeRecorder()
    try await recorder.startRecording()
    processor.feed([0.1, 0.2, 0.3])
    let result = try await recorder.stopRecording(request: request)
    XCTAssertEqual(result["text"] as? String, "hello")
    XCTAssertEqual(model.lastSamples, [0.1, 0.2, 0.3])
    XCTAssertEqual(processor.stopCalls, 1)
    XCTAssertEqual(Array(processor.audioSamples), [])
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
  }

  func testStopWithoutStartIsRecordingFailed() async {
    let recorder = makeRecorder()
    do {
      _ = try await recorder.stopRecording(request: request)
      XCTFail("expected recording-failed")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
    }
  }

  func testCancelRecordingDiscardsTheAudio() async throws {
    let recorder = makeRecorder()
    try await recorder.startRecording()
    processor.feed([0.1])
    await recorder.cancelRecording()
    XCTAssertEqual(processor.stopCalls, 1)
    do {
      _ = try await recorder.stopRecording(request: request)
      XCTFail("expected recording-failed")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
    }
    XCTAssertEqual(model.transcribeCalls, 0)
  }

  func testInterruptKeepsTheAudioForTheNextStop() async throws {
    let recorder = makeRecorder()
    try await recorder.startRecording()
    processor.feed([0.4, 0.5])
    await recorder.interrupt()
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    XCTAssertEqual(processor.stopCalls, 1)
    let result = try await recorder.stopRecording(request: request)
    XCTAssertEqual(result["text"] as? String, "hello")
    XCTAssertEqual(model.lastSamples, [0.4, 0.5])
  }

  func testBusyFinalDecodeKeepsTheAudioForARetry() async throws {
    let recorder = makeRecorder()
    try await recorder.startRecording()
    processor.feed([0.6])
    try await engine.beginExclusive()
    do {
      _ = try await recorder.stopRecording(request: request)
      XCTFail("expected busy")
    } catch {
      XCTAssertEqual(code(error), .busy)
    }
    await engine.endExclusive()
    let result = try await recorder.stopRecording(request: request)
    XCTAssertEqual(result["text"] as? String, "hello")
    XCTAssertEqual(model.lastSamples, [0.6])
  }

  func testLevelEventsFlowWhileRecording() async throws {
    processor.setEnergy([0.25])
    let recorder = makeRecorder()
    try await recorder.startRecording()
    let events = self.events!
    await eventually { events.levels.count >= 2 }
    XCTAssertEqual(events.levels.first, 0.25)
    _ = try await recorder.stopRecording(request: request)
    let count = events.levels.count
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertEqual(events.levels.count, count, "level events stop with the capture")
  }

  // MARK: Streaming

  func testStartStreamingNeedsPermission() async {
    let recorder = makeRecorder(permission: "undetermined")
    do {
      try await recorder.startStreaming(request: request)
      XCTFail("expected permission-denied")
    } catch {
      XCTAssertEqual(code(error), .permissionDenied)
    }
    XCTAssertEqual(model.session.startCalls, 0)
  }

  func testStartStreamingMakesASessionAndHoldsTheEngine() async throws {
    let recorder = makeRecorder()
    try await recorder.startStreaming(request: request)
    XCTAssertEqual(model.session.startCalls, 1)
    let mode = await recorder.mode
    XCTAssertEqual(mode, .streaming)
    let busy = await engine.isBusy
    XCTAssertTrue(busy)
    _ = try await recorder.stopStreaming()
  }

  func testSecondStartWhileStreamingIsBusy() async throws {
    let recorder = makeRecorder()
    try await recorder.startStreaming(request: request)
    do {
      try await recorder.startStreaming(request: request)
      XCTFail("expected busy")
    } catch {
      XCTAssertEqual(code(error), .busy)
    }
    do {
      try await recorder.startRecording()
      XCTFail("expected busy")
    } catch {
      XCTAssertEqual(code(error), .busy)
    }
    _ = try await recorder.stopStreaming()
  }

  func testStreamingUpdateIsEmittedOncePerDistinctText() async throws {
    let recorder = makeRecorder()
    try await recorder.startStreaming(request: request)
    model.session.emit("hello", "wor")
    model.session.emit("hello", "wor")
    model.session.emit("hello", "world")
    XCTAssertEqual(events.streaming, ["hello|wor", "hello|world"])
    _ = try await recorder.stopStreaming()
  }

  func testStopStreamingStopsTheSessionAndTranscribesTheAudio() async throws {
    let recorder = makeRecorder()
    try await recorder.startStreaming(request: request)
    model.fakeProcessor.feed([0.7, 0.8])
    let result = try await recorder.stopStreaming()
    XCTAssertEqual(result["text"] as? String, "hello")
    XCTAssertEqual(model.lastSamples, [0.7, 0.8])
    XCTAssertEqual(model.session.stopCalls, 1)
    XCTAssertEqual(model.fakeProcessor.stopCalls, 1)
    XCTAssertEqual(Array(model.fakeProcessor.audioSamples), [])
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testStopStreamingWithNoAudioResolvesEmptyWithoutDecoding() async throws {
    let recorder = makeRecorder()
    try await recorder.startStreaming(request: DecodingRequest(language: "en"))
    let result = try await recorder.stopStreaming()
    XCTAssertEqual(result["text"] as? String, "")
    XCTAssertEqual(result["language"] as? String, "en")
    XCTAssertEqual(model.transcribeCalls, 0)
  }

  func testStopStreamingWhenIdleIsRecordingFailed() async {
    let recorder = makeRecorder()
    do {
      _ = try await recorder.stopStreaming()
      XCTFail("expected recording-failed")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
    }
  }

  func testStopWhileAlreadyStoppingIsBusy() async throws {
    let recorder = makeRecorder()
    let gate = Gate()
    model.session.stopGate = gate
    try await recorder.startStreaming(request: request)
    let first = Task { try await recorder.stopStreaming() }
    // The stop gate holds the first call inside the session's stop, so once the session has been
    // entered the Recorder is in its ending state.
    let session = model.session
    await eventually { session.stopEntered == 1 }
    do {
      _ = try await recorder.stopStreaming()
      XCTFail("expected busy")
    } catch {
      XCTAssertEqual(code(error), .busy)
    }
    await gate.open()
    let result = try await first.value
    XCTAssertEqual(result["text"] as? String, "")
  }

  func testInterruptKeepsTheAudioAndRequestForALaterStop() async throws {
    let recorder = makeRecorder()
    try await recorder.startStreaming(request: request)
    model.fakeProcessor.feed([0.9])
    await recorder.interrupt()
    XCTAssertEqual(model.session.stopCalls, 1)
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
    let result = try await recorder.stopStreaming()
    XCTAssertEqual(result["text"] as? String, "hello")
    XCTAssertEqual(model.lastSamples, [0.9])
  }

  func testCancelStreamingDiscardsKeptAudio() async throws {
    let recorder = makeRecorder()
    try await recorder.startStreaming(request: request)
    model.fakeProcessor.feed([0.9])
    await recorder.interrupt()
    await recorder.cancelStreaming()
    do {
      _ = try await recorder.stopStreaming()
      XCTFail("expected recording-failed")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
    }
  }

  func testStartStreamingFailsWhenTheSessionThrows() async {
    model.session.setBehaviour(.throwError(NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "no input"])))
    let recorder = makeRecorder()
    do {
      try await recorder.startStreaming(request: request)
      XCTFail("expected recording-failed")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
      XCTAssertEqual((error as? WhisperKitError)?.message, "Could not start the microphone: no input")
    }
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testSessionFactoryFailureReleasesTheEngine() async {
    model.setSessionError(WhisperKitError(.loadFailed, "The tokenizer did not load"))
    let recorder = makeRecorder()
    do {
      try await recorder.startStreaming(request: request)
      XCTFail("expected load-failed")
    } catch {
      XCTAssertEqual(code(error), .loadFailed)
    }
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
  }

  func testInterruptDuringTheLoadAbortsBeforeTheSessionIsMade() async throws {
    let gate = Gate()
    loader.gate = gate
    let recorder = makeRecorder()
    let start = Task { try await recorder.startStreaming(request: self.request) }
    let engine = self.engine!
    await eventually { await engine.isBusy }
    await recorder.interrupt()
    await gate.open()
    try await start.value
    XCTAssertEqual(model.session.startCalls, 0)
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
    let result = try await recorder.stopStreaming()
    XCTAssertEqual(result["text"] as? String, "")
  }

  func testCancelDuringTheLoadAbortsAndKeepsNothing() async throws {
    let gate = Gate()
    loader.gate = gate
    let recorder = makeRecorder()
    let start = Task { try await recorder.startStreaming(request: self.request) }
    let engine = self.engine!
    await eventually { await engine.isBusy }
    await recorder.cancelStreaming()
    await gate.open()
    try await start.value
    XCTAssertEqual(model.session.startCalls, 0)
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
    do {
      _ = try await recorder.stopStreaming()
      XCTFail("expected recordingFailed")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
    }
  }

  // MARK: Streaming start (review findings 1 to 4)

  func testStartStreamingResolvesOnTheCaptureSignalNotATimer() async throws {
    // Finding 4 (and 3): the Recorder used to poll WhisperKit's audio engine for a second.
    model.session.setCapturesOnStart(false)
    let recorder = makeRecorder()
    let session = model.session
    let started = Flag()
    let start = Task {
      try await recorder.startStreaming(request: self.request)
      started.set()
    }
    await eventually { session.startCalls == 1 }
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertFalse(started.isSet, "start waits for the capture signal")
    let before = Date()
    session.capture()
    try await start.value
    XCTAssertLessThan(Date().timeIntervalSince(before), 0.3, "start resolves on the signal, not on a timer")
    let mode = await recorder.mode
    XCTAssertEqual(mode, .streaming)
    _ = try await recorder.stopStreaming()
  }

  func testQuietSessionEndDuringStartIsRecordingFailed() async {
    // Finding 2: WhisperKit returns normally when its permission re-check fails or its loop stops
    // itself after a decode error. During start that is a failed start, not an interruption.
    model.session.setBehaviour(.returnAtOnce)
    let recorder = makeRecorder()
    do {
      try await recorder.startStreaming(request: request)
      XCTFail("expected recording-failed")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
      XCTAssertEqual(
        (error as? WhisperKitError)?.message,
        "Could not start the microphone: the capture loop ended before recording began"
      )
    }
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
    do {
      _ = try await recorder.stopStreaming()
      XCTFail("nothing is kept after a failed start")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
    }
  }

  func testFailureAfterASlowStartIsStillRecordingFailed() async throws {
    // Finding 3: a microphone failure that surfaces after the old one-second window used to be
    // reported as a successful start and then silently turned into an interruption.
    model.session.setCapturesOnStart(false)
    let recorder = makeRecorder()
    let session = model.session
    let start = Task { try await recorder.startStreaming(request: self.request) }
    await eventually { session.startCalls == 1 }
    try await Task.sleep(nanoseconds: 1_200_000_000)
    session.fail(with: NSError(domain: "test", code: 4, userInfo: [NSLocalizedDescriptionKey: "route lost"]))
    do {
      try await start.value
      XCTFail("expected recording-failed")
    } catch {
      XCTAssertEqual(code(error), .recordingFailed)
      XCTAssertEqual((error as? WhisperKitError)?.message, "Could not start the microphone: route lost")
    }
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }

  func testInterruptWhileWaitingForTheMicrophoneResolvesStartAndKeepsAudio() async throws {
    // Finding 1, Recorder half: a stop that ends the session during the start wait resolves the
    // pending start (the session's own rules apply) instead of spinning.
    model.session.setCapturesOnStart(false)
    let recorder = makeRecorder()
    let session = model.session
    let start = Task { try await recorder.startStreaming(request: self.request) }
    await eventually { session.startCalls == 1 }
    model.fakeProcessor.feed([0.2])
    await recorder.interrupt()
    try await start.value
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    XCTAssertEqual(session.stopCalls, 1)
    let result = try await recorder.stopStreaming()
    XCTAssertEqual(result["text"] as? String, "hello")
    XCTAssertEqual(model.lastSamples, [0.2])
  }

  func testCaptureDuringAStopIsResolvedAfterTheTeardown() async throws {
    // Ruling 1: a capture signal that lands while a stop is tearing the session down must not
    // resolve the pending start mid-teardown; endStreaming resolves it once the state is reset.
    model.session.setCapturesOnStart(false)
    let recorder = makeRecorder()
    let session = model.session
    let gate = Gate()
    session.stopGate = gate
    let started = Flag()
    let start = Task {
      try await recorder.startStreaming(request: self.request)
      started.set()
    }
    await eventually { session.startCalls == 1 }
    let stop = Task { try await recorder.stopStreaming() }
    await eventually { session.stopEntered == 1 }
    session.capture()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(started.isSet, "a capture during teardown does not resolve the start early")
    await gate.open()
    try await start.value
    let result = try await stop.value
    XCTAssertEqual(result["text"] as? String, "")
    let mode = await recorder.mode
    XCTAssertEqual(mode, .idle)
    let busy = await engine.isBusy
    XCTAssertFalse(busy)
  }
}
