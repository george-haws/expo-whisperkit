import Foundation

/// The closed set of codes shared with TypeScript (spec §4). `unsupported-platform` never
/// originates natively.
enum WhisperKitErrorCode: String {
  case modelMissing = "model-missing"
  case downloadFailed = "download-failed"
  case loadFailed = "load-failed"
  case permissionDenied = "permission-denied"
  case recordingFailed = "recording-failed"
  case decodeFailed = "decode-failed"
  case busy = "busy"
  case cancelled = "cancelled"
}

struct WhisperKitError: Error, CustomStringConvertible {
  let code: WhisperKitErrorCode
  let message: String
  let underlying: Error?

  init(_ code: WhisperKitErrorCode, _ message: String, underlying: Error? = nil) {
    self.code = code
    self.message = message
    self.underlying = underlying
  }

  var description: String { message }
}

extension WhisperKitError {
  /// `recording-failed` for a microphone that could not start, worded the same for push-to-talk
  /// and streaming.
  static func microphoneStartFailed(_ reason: String, underlying: Error? = nil) -> WhisperKitError {
    WhisperKitError(.recordingFailed, "Could not start the microphone: \(reason)", underlying: underlying)
  }
}
