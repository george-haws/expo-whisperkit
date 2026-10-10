import Foundation
import WhisperKit

/// Confirmed text, then pending text, already mapped from WhisperKit's streaming state.
typealias StreamingTextCallback = @Sendable (_ confirmed: String, _ pending: String) -> Void

/// A live session over the microphone (harness design §4.2).
protocol StreamingSession: AnyObject, Sendable {
  /// Returns when the capture loop ends: after `stop()`, or on its own (a decode error, or
  /// WhisperKit's permission re-check failing). Throws when the microphone cannot start.
  func start() async throws
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
    let transcriber = AudioStreamTranscriber(
      audioEncoder: audioEncoder,
      featureExtractor: featureExtractor,
      segmentSeeker: segmentSeeker,
      textDecoder: textDecoder,
      tokenizer: tokenizer,
      audioProcessor: audioProcessor,
      decodingOptions: options,
      stateChangeCallback: { _, state in
        let text = StreamingText.from(
          confirmed: state.confirmedSegments, unconfirmed: state.unconfirmedSegments, current: state.currentText
        )
        onText(text.confirmed, text.pending)
      }
    )
    return WhisperKitStreamingSession(transcriber)
  }
}

/// `AudioStreamTranscriber` behind the `StreamingSession` protocol.
final class WhisperKitStreamingSession: StreamingSession {
  private let transcriber: AudioStreamTranscriber

  init(_ transcriber: AudioStreamTranscriber) {
    self.transcriber = transcriber
  }

  func start() async throws {
    try await transcriber.startStreamTranscription()
  }

  func stop() async {
    await transcriber.stopStreamTranscription()
  }
}
