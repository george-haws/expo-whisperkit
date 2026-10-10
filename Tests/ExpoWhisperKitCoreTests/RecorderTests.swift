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
}
