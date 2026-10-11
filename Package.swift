// swift-tools-version: 5.10
import PackageDescription

// The WhisperKit version must equal WHISPERKIT_TAG in ios/whisperkit_version.rb without the
// leading `v`, and the Package.resolved revision must equal WHISPERKIT_COMMIT there.
// `npm run test:ios` refuses to run when either differs.
let whisperKitVersion = "1.1.1"

let package = Package(
  name: "expo-whisperkit",
  platforms: [.iOS(.v16)],
  products: [
    .library(name: "ExpoWhisperKitCore", targets: ["ExpoWhisperKitCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: Version(stringLiteral: whisperKitVersion)),
  ],
  targets: [
    // The same files the pod compiles, minus the ones that need ExpoModulesCore.
    .target(
      name: "ExpoWhisperKitCore",
      dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
      path: "ios",
      exclude: [
        "ArgmaxCore.podspec",
        "WhisperKit.podspec",
        "ExpoWhisperKit.podspec",
        "whisperkit_version.rb",
        "ExpoWhisperKitModule.swift",
        "ExpoBridge.swift",
      ]
    ),
    .testTarget(
      name: "ExpoWhisperKitCoreTests",
      dependencies: ["ExpoWhisperKitCore"],
      path: "Tests/ExpoWhisperKitCoreTests"
    ),
  ]
)
