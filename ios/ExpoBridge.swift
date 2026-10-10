import ExpoModulesCore
import Foundation

// Everything that needs ExpoModulesCore, apart from the module itself. Excluded from the
// SwiftPM target in Package.swift so the core compiles without Expo under test.

extension WhisperKitError {
  /// The Expo exception whose JS `code` is the same string.
  func asException() -> Exception {
    let exception = Exception(name: "WhisperKitError", description: message, code: code.rawValue)
    exception.cause = underlying
    return exception
  }
}

/// Mirrors `NativeDecodingOptions` in TypeScript: `model` and `download` are always present.
struct DecodingRequestRecord: Record {
  @Field var model: String = "base"
  @Field var language: String? = nil
  @Field var task: String? = nil
  @Field var prompt: String? = nil
  @Field var download: Bool = true

  var request: DecodingRequest {
    DecodingRequest(model: model, language: language, task: task, prompt: prompt, download: download)
  }
}
