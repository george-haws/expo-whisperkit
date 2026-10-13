# expo-whisperkit

On-device speech to text for Expo apps on iOS and iPadOS, powered by [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (Argmax, MIT). Models download on demand, transcription runs offline, and every failure carries a typed code.

This is a community package. It is not affiliated with or endorsed by Argmax, Inc.

Android is not supported: the package compiles there and every call rejects with `unsupported-platform`.

## Install

Until this is on npm, install from a git tag:

```sh
npm install github:george-haws/expo-whisperkit#v0.1.0
```

Add the config plugin to `app.json`:

```json
{
  "expo": {
    "plugins": [
      ["expo-whisperkit", { "microphonePermission": "Allow $(PRODUCT_NAME) to use the microphone for speech to text." }]
    ]
  }
}
```

Then `npx expo prebuild -p ios` and build a dev build (`npx expo run:ios`). The plugin adds two pods that compile WhisperKit from source; no CocoaPods plugin or Ruby gem is needed. First `pod install` clones the WhisperKit repo once into the CocoaPods cache.

Requirements: Expo SDK 57, iOS 16.4, Xcode 16 or newer; tested with Xcode 27.

Known limitation of the config plugin: it inserts its pods after a Podfile line that has `use_expo_modules!` alone on it (indentation allowed). If your Podfile calls `use_expo_modules!` with arguments or a trailing comment, prebuild fails with a clear error. In that case add this block by hand, right after the `use_expo_modules!` call. The two marker comments are required: the plugin skips its insertion when it finds `# expo-whisperkit (begin)`, and without the markers every prebuild fails again.

```ruby
# expo-whisperkit (begin)
pod 'ArgmaxCore', :podspec => '../node_modules/expo-whisperkit/ios/ArgmaxCore.podspec'
pod 'WhisperKit', :podspec => '../node_modules/expo-whisperkit/ios/WhisperKit.podspec'
# expo-whisperkit (end)
```

## Usage

```ts
import * as WhisperKit from 'expo-whisperkit';

// Models are WhisperKit variant names listed in the package's manifest (currently 'base').
await WhisperKit.downloadModel('base');              // emits downloadProgress
const { state } = await WhisperKit.getModelStatus(); // 'absent' | 'downloading' | 'present' | 'loaded'

// Push-to-talk
if ((await WhisperKit.requestMicrophonePermission()) === 'granted') {
  await WhisperKit.startRecording();
  // ... user speaks ...
  const { text } = await WhisperKit.stopRecording({ language: 'en' });
}

// Any audio file
const result = await WhisperKit.transcribeFile(fileUri, { prompt: 'tahini, za\'atar' });

// Streaming
const sub = WhisperKit.addListener('streamingUpdate', ({ confirmedText, pendingText }) => {});
await WhisperKit.startStreaming();
const final = await WhisperKit.stopStreaming();
sub.remove();
```

## API

| Function | Notes |
|---|---|
| `isAvailable()` | `false` on Android or without the native module |
| `getModelStatus(model?)`, `downloadModel(model?)`, `deleteModel(model)`, `listDownloadedModels()`, `loadModel(model?)`, `unloadModel()` | Model is `DEFAULT_MODEL` (`'base'`) when omitted. Models load lazily on first use; `loadModel` is an optional prewarm. One model is loaded at a time. A download's validating first load evicts the loaded model; the next call reloads it. Model names may contain only ASCII letters, digits, `.`, `_` and `-`, must not start with `.` and must not contain `..`; any other name rejects with `model-missing`. |
| `transcribeFile(uri, options?)` | Any format AVFoundation reads |
| `getMicrophonePermission()`, `requestMicrophonePermission()` | Only `request` prompts |
| `startRecording()`, `stopRecording(options?)`, `cancelRecording()` | Push-to-talk; `stop` returns the transcription |
| `startStreaming(options?)`, `stopStreaming()` | Partial results via `streamingUpdate`; `stop` returns the full transcription |
| `addListener(event, fn)` | Returns `{ remove() }` |

The package also exports `DEFAULT_MODEL`, `WhisperKitError`, `ERROR_CODES` and the types below. `simulateMemoryWarningForTesting()` is a test hook for the example app, not part of the supported API. It stays in the production module by design: it posts a memory warning the app would receive anyway, and only the app's own JavaScript can call it.

`DecodingOptions`: `{ model?, language?, task?: 'transcribe' | 'translate', prompt?, download?: boolean }`. With `download: false` an absent model rejects with `model-missing` instead of downloading.

`Transcription`: `{ text, language, segments: [{ text, start, end }] }` (seconds).

### Events

| Event | Payload |
|---|---|
| `downloadProgress` | `{ model, fraction }` |
| `modelState` | `{ model, state }` |
| `audioLevel` | `{ level }` 0..1, about 10 Hz while capturing |
| `streamingUpdate` | `{ confirmedText, pendingText }` |

### Errors

Every rejection is a `WhisperKitError` with `code` in: `unsupported-platform`, `model-missing`, `download-failed`, `load-failed`, `permission-denied`, `recording-failed`, `decode-failed`, `busy`, `cancelled`. `busy` means a conflicting operation is running; nothing is queued. `busy` also covers a model load or prewarm, a downloaded model's first load, a download of the same model, or a delete in progress; when `stopRecording` or `stopStreaming` gets `busy`, the captured audio is kept and a retried stop decodes it. `downloadModel` resolves only after the downloaded files have loaded once; if a decode or streaming session is running when the download finishes, it waits for that to end. Because the set of codes is closed, `load-failed` also covers storage failures in the model-management calls (for example a delete that fails).

`download-failed` also covers a model name that is not in the package's manifest (`Model <name> is not in the manifest`) and a download whose files do not match the manifest (`Model <name> failed verification: ...`); in both cases nothing is kept on disk.

Interruptions (calls, Siri, backgrounding) end capture without an error; the audio captured so far is returned by the next `stopRecording` / `stopStreaming`. A memory warning unloads an idle model (`modelState` goes to `present`); the next call reloads it.

Audio kept across an interruption lives in memory only, never on disk, until the next `stopRecording`, `stopStreaming` or `cancelRecording` returns or discards it.

A streaming session can also end without any signal reaching JavaScript: an interruption or backgrounding that arrives while the model is still loading, or WhisperKit's capture loop stopping on an internal error. `stopStreaming` then resolves with whatever was captured, possibly empty text, rather than rejecting.

`startStreaming` resolves once the microphone is capturing. It rejects with `recording-failed` if the microphone cannot be started or the session ends before capture begins; a stop or interruption during the start resolves it, and the audio captured so far is kept for the next `stopStreaming`.

## Where models live

`<Application Support>/expo-whisperkit/models/<name>`, excluded from iCloud backup. Models come from Argmax's Hugging Face repo `argmaxinc/whisperkit-coreml` and their tokenizer from the matching `openai/whisper-*` repo, both over HTTPS. The package only downloads what `ios/ModelManifest.swift` lists: for each variant, the repo commit, the model folder and the sha256 of every file, plus the tokenizer repo commit and the sha256 of its three files. After download every file is hashed and the folder is rejected on any mismatch, missing or extra file. The tokenizer is prefetched into `<Application Support>/expo-whisperkit/tokenizers/`, so a present model needs no network. A model is reported `present` only after a complete, verified download and a first successful load. Models downloaded by an earlier version of this package are not re-verified: a present folder is used as is, and an unlisted variant that was downloaded earlier keeps working until it is deleted, after which it cannot be downloaded again.

Trust boundary: the manifest pins what Argmax and OpenAI published at those commits. It does not verify who published them; it makes a later change to either repo, or a compromised account, fail verification rather than silently change what the app runs.

### Regenerating the manifest

`npm run manifest -- base [small.en ...]` resolves `main` of both repos, downloads every file of each variant at that commit, and rewrites `ios/ModelManifest.swift`. Pass `--revision <sha>` or `--tokenizer-revision <sha>` to pin instead of resolving. Review the diff before committing: a changed hash means the published files changed.

## Contributing

Setup, checks, the example app, the Maestro flows and how to bump WhisperKit are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. WhisperKit is MIT, copyright Argmax, Inc.
