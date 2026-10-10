import Foundation
import WhisperKit

/// The resolved decoding request. Built from `DecodingRequestRecord` (ExpoBridge.swift), which
/// mirrors `NativeDecodingOptions` in TypeScript: `model` and `download` are always present.
struct DecodingRequest: Sendable {
  var model: String = "base"
  var language: String? = nil
  var task: String? = nil
  var prompt: String? = nil
  var download: Bool = true

  func decodingOptions(tokenizer: (any WhisperTokenizer)?) -> DecodingOptions {
    var options = DecodingOptions(
      task: task == "translate" ? .translate : .transcribe,
      language: language,
      detectLanguage: language == nil,
      skipSpecialTokens: true
    )
    if let prompt, !prompt.isEmpty, let tokenizer {
      let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
      options.promptTokens = tokenizer.encode(text: " " + prompt).filter { $0 < specialTokenBegin }
      options.usePrefillPrompt = true
    }
    return options
  }
}

enum Payloads {
  static func transcription(_ result: TranscriptionResult) -> [String: Any] {
    [
      "text": result.text.trimmingCharacters(in: .whitespacesAndNewlines),
      "language": result.language,
      "segments": result.segments.map { segment -> [String: Any] in
        [
          "text": segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
          "start": Double(segment.start),
          "end": Double(segment.end),
        ]
      },
    ]
  }

  static func merged(_ results: [TranscriptionResult]) -> [String: Any] {
    transcription(TranscriptionUtilities.mergeTranscriptionResults(results))
  }
}

/// Rate limiter for events (spec §3.4). Thread-safe; callbacks arrive from URLSession and audio threads.
final class Throttle: @unchecked Sendable {
  private let interval: TimeInterval
  private var last: Date = .distantPast
  private let lock = NSLock()

  init(interval: TimeInterval) {
    self.interval = interval
  }

  /// True when enough time has passed since the last accepted call, or when `force` is set.
  func shouldSend(force: Bool = false) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    if force || now.timeIntervalSince(last) >= interval {
      last = now
      return true
    }
    return false
  }
}
