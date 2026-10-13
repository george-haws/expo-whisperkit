# Changelog

All notable changes to this package are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Model downloads are pinned and verified. `ios/ModelManifest.swift` lists, for each model, the Hugging Face repo commit and the sha256 of every file, plus the tokenizer's commit and hashes. A download whose files do not match is rejected with `download-failed` and nothing is kept on disk.
- A model name that is not in the manifest rejects with `download-failed`.
- WhisperKit's source pods are pinned to a commit and checked against `Package.resolved`.

### Changed

- Model names are checked against an allowlist of characters; any other name rejects with `model-missing`.
- Download progress events are throttled per model.

### Fixed

- `startStreaming` waits until the microphone is capturing, and rejects with `recording-failed` if the session ends before capture begins.
- A stop requested before capture starts no longer leaves the microphone open.
- When `stopRecording` or `stopStreaming` gets `busy`, the captured audio is kept and a retried stop decodes it.
- Interruptions read the system's interruption reason correctly.
- A download is validated after the loaded model is unloaded, and a model that is already present stays present when a later load fails.
- A download that finds the model already present skips the extra validating load.
- A tokenizer folder that fails verification is removed.

## 0.1.0 - 2026-10-09

First release, installable from the `v0.1.0` git tag.

- On-device transcription with WhisperKit on iOS and iPadOS: from files, push-to-talk recording, and streaming with partial results.
- Model management: download on demand, status, load, unload, delete and list.
- Microphone permission helpers and `downloadProgress`, `modelState`, `audioLevel` and `streamingUpdate` events.
- Every rejection is a `WhisperKitError` with a typed `code`.
- An Expo config plugin that sets the microphone usage text and adds the WhisperKit source pods.
- Android compiles, and every call rejects with `unsupported-platform`.
