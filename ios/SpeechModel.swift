import AVFoundation
import CoreML
import Foundation
import WhisperKit

/// Confirmed text, then pending text, already mapped from WhisperKit's streaming state.
typealias StreamingTextCallback = @Sendable (_ confirmed: String, _ pending: String) -> Void

/// A live session over the microphone (harness design §4.2).
protocol StreamingSession: AnyObject, Sendable {
  /// Returns when the capture loop ends: after `stop()`, or on its own (a decode error, or
  /// WhisperKit's permission re-check failing). Throws when the microphone cannot start.
  /// `onCapturing` is called at most once, from any thread, when the microphone is up.
  /// It must not block: in production it runs on WhisperKit's transcriber actor inside `startRecordingLive`.
  func start(onCapturing: @escaping @Sendable () -> Void) async throws
  func stop() async
}

/// What Engine and Recorder use from a loaded WhisperKit instance.
protocol SpeechModel: AnyObject, Sendable {
  var tokenizer: (any WhisperTokenizer)? { get }
  var audioProcessor: any AudioProcessing { get }
  func transcribe(path: String, options: DecodingOptions) async throws -> [TranscriptionResult]
  func transcribe(samples: [Float], options: DecodingOptions) async throws -> [TranscriptionResult]
  func unloadModels() async
  /// Throws `load-failed` when the instance has no tokenizer.
  func makeStreamingSession(options: DecodingOptions, onText: @escaping StreamingTextCallback) throws -> any StreamingSession
}

/// The two calls the session makes on WhisperKit's `AudioStreamTranscriber`, as a seam so a fake
/// can reproduce upstream's start ordering in tests.
protocol StreamTranscribing: AnyObject, Sendable {
  func startStreamTranscription() async throws
  func stopStreamTranscription() async
}

extension AudioStreamTranscriber: StreamTranscribing {}

/// Constructs a loaded model from a config. Production: `WhisperKit.init`.
typealias ModelLoader = @Sendable (WhisperKitConfig) async throws -> any SpeechModel

/// The `(confirmed, pending)` text for a `streamingUpdate` (spec §3.4). Takes the three state
/// fields rather than `AudioStreamTranscriber.State`, which has no public initialiser.
enum StreamingText {
  /// WhisperKit's own placeholder for `currentText`, copied from the `"Waiting for speech..."`
  /// strings in WhisperKit's `AudioStreamTranscriber.swift` (`transcribeCurrentBuffer`). Update if reworded.
  static let waitingPlaceholder = "Waiting for speech..."

  static func from(
    confirmed: [TranscriptionSegment], unconfirmed: [TranscriptionSegment], current: String
  ) -> (confirmed: String, pending: String) {
    let confirmedText = confirmed.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    // WhisperKit fills `currentText` with a placeholder while it waits for voice; it is not text.
    let currentText = current == waitingPlaceholder ? "" : current
    let pending = (unconfirmed.map(\.text).joined() + " " + currentText)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (confirmedText, pending)
  }
}

// MARK: - WhisperKit conformance

// Safe because Engine's exclusivity serialises every use of the instance: transcribe runs inside exclusiveTranscription, and a streaming session holds exclusivity from beginExclusiveLoad to endStreaming.
extension WhisperKit: @retroactive @unchecked Sendable {}

extension WhisperKit: SpeechModel {
  // WhisperKit's own transcribe methods carry defaulted extra parameters, which Swift does not
  // match against a protocol requirement, so they are forwarded explicitly.
  func transcribe(path: String, options: DecodingOptions) async throws -> [TranscriptionResult] {
    try await transcribe(audioPath: path, decodeOptions: options)
  }

  func transcribe(samples: [Float], options: DecodingOptions) async throws -> [TranscriptionResult] {
    try await transcribe(audioArray: samples, decodeOptions: options)
  }

  func makeStreamingSession(options: DecodingOptions, onText: @escaping StreamingTextCallback) throws -> any StreamingSession {
    guard let tokenizer else {
      throw WhisperKitError(.loadFailed, "The tokenizer did not load")
    }
    let capturing = CapturingAudioProcessor(audioProcessor)
    let transcriber = AudioStreamTranscriber(
      audioEncoder: audioEncoder,
      featureExtractor: featureExtractor,
      segmentSeeker: segmentSeeker,
      textDecoder: textDecoder,
      tokenizer: tokenizer,
      audioProcessor: capturing,
      decodingOptions: options,
      stateChangeCallback: { _, state in
        let text = StreamingText.from(
          confirmed: state.confirmedSegments, unconfirmed: state.unconfirmedSegments, current: state.currentText
        )
        onText(text.confirmed, text.pending)
      }
    )
    return WhisperKitStreamingSession(transcriber: transcriber, processor: capturing)
  }
}

/// `AudioStreamTranscriber` behind the `StreamingSession` protocol.
///
/// WhisperKit's `stopStreamTranscription` only clears `isRecording`, which its start sets after
/// an `await` on the permission check. A stop that lands in that window is a no-op and the loop
/// would then run forever. `stop()` therefore also tells the `CapturingAudioProcessor`, which
/// refuses to open the microphone once a stop has been requested, so the start throws before
/// the loop begins (review finding 1).
final class WhisperKitStreamingSession: StreamingSession, Sendable {
  private let transcriber: any StreamTranscribing
  private let processor: CapturingAudioProcessor

  init(transcriber: any StreamTranscribing, processor: CapturingAudioProcessor) {
    self.transcriber = transcriber
    self.processor = processor
  }

  func start(onCapturing: @escaping @Sendable () -> Void) async throws {
    processor.setOnCapturing(onCapturing)
    try await transcriber.startStreamTranscription()
  }

  func stop() async {
    processor.requestStop()
    await transcriber.stopStreamTranscription()
  }
}

/// Forwards every `AudioProcessing` call to the model's processor and reports the moment the
/// microphone is up: `startRecordingLive` returning without throwing is where WhisperKit's
/// `AudioProcessor` has started its `AVAudioEngine`.
final class CapturingAudioProcessor: AudioProcessing, @unchecked Sendable {
  // `var` only because `AudioProcessing` is not class-bound and `relativeEnergyWindow` has a setter; nothing in this module calls that setter.
  private var base: any AudioProcessing
  private let lock = NSLock()
  private var onCapturing: (@Sendable () -> Void)?
  private var stopRequested = false

  init(_ base: any AudioProcessing) {
    self.base = base
  }

  func setOnCapturing(_ callback: @escaping @Sendable () -> Void) {
    lock.lock(); onCapturing = callback; lock.unlock()
  }

  var audioSamples: ContiguousArray<Float> { base.audioSamples }
  func purgeAudioSamples(keepingLast keep: Int) { base.purgeAudioSamples(keepingLast: keep) }
  var relativeEnergy: [Float] { base.relativeEnergy }
  var relativeEnergyWindow: Int {
    get { base.relativeEnergyWindow }
    set { base.relativeEnergyWindow = newValue }
  }

  func requestStop() {
    lock.lock(); stopRequested = true; lock.unlock()
  }

  /// A stop that arrived before WhisperKit reached `startRecordingLive` would otherwise open the
  /// microphone for a moment and need a second stop. Throwing here makes upstream reset
  /// `isRecording` and rethrow, so the loop never starts and the microphone never opens; the
  /// Recorder ignores that throw because it began the stop.
  func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
    lock.lock(); let stopped = stopRequested; lock.unlock()
    if stopped { throw CancellationError() }
    try base.startRecordingLive(inputDeviceID: inputDeviceID, callback: callback)
    lock.lock(); let capturing = onCapturing; onCapturing = nil; lock.unlock()
    capturing?()
  }

  func startStreamingRecordingLive(inputDeviceID: DeviceID?)
    -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation)
  {
    base.startStreamingRecordingLive(inputDeviceID: inputDeviceID)
  }

  func pauseRecording() { base.pauseRecording() }
  func stopRecording() { base.stopRecording() }

  func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
    try base.resumeRecordingLive(inputDeviceID: inputDeviceID, callback: callback)
  }

  func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int)
    -> (any AudioProcessorOutputType)?
  {
    base.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
  }

  static func loadAudio(
    fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?,
    maxReadFrameSize: AVAudioFrameCount?
  ) throws -> AVAudioPCMBuffer {
    try AudioProcessor.loadAudio(
      fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime,
      maxReadFrameSize: maxReadFrameSize
    )
  }

  static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
    await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
  }

  static func padOrTrimAudio(
    fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool
  ) -> MLMultiArray? {
    AudioProcessor.padOrTrimAudio(
      fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment
    )
  }
}
