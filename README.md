# expo-whisperkit

On-device speech to text for Expo apps on iOS and iPadOS, powered by [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (Argmax, MIT). Models download on demand, transcription runs offline, and every failure carries a typed code.

Android is not supported: the package compiles there and every call rejects with `unsupported-platform`.

## Install

Until this is on npm, install from a git tag:

```sh
npm install github:georgeelliott/expo-whisperkit#v0.1.0
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

// Models are WhisperKit variant names: 'base', 'small.en', 'large-v3_turbo', ...
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
| `getModelStatus(model?)`, `downloadModel(model?)`, `deleteModel(model)`, `listDownloadedModels()`, `loadModel(model?)`, `unloadModel()` | Model is `DEFAULT_MODEL` (`'base'`) when omitted. Models load lazily on first use; `loadModel` is an optional prewarm. One model is loaded at a time. Model names must be non-empty, must not contain `/` or `..`, and must not start with `.`; any other name rejects with `model-missing`. |
| `transcribeFile(uri, options?)` | Any format AVFoundation reads |
| `getMicrophonePermission()`, `requestMicrophonePermission()` | Only `request` prompts |
| `startRecording()`, `stopRecording(options?)`, `cancelRecording()` | Push-to-talk; `stop` returns the transcription |
| `startStreaming(options?)`, `stopStreaming()` | Partial results via `streamingUpdate`; `stop` returns the full transcription |
| `addListener(event, fn)` | Returns `{ remove() }` |

The package also exports `DEFAULT_MODEL`, `WhisperKitError`, `ERROR_CODES` and the types below. `simulateMemoryWarningForTesting()` is a test hook for the example app, not part of the supported API.

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

Every rejection is a `WhisperKitError` with `code` in: `unsupported-platform`, `model-missing`, `download-failed`, `load-failed`, `permission-denied`, `recording-failed`, `decode-failed`, `busy`, `cancelled`. `busy` means a conflicting operation is running; nothing is queued. Because the set of codes is closed, `load-failed` also covers storage failures in the model-management calls (for example a delete that fails).

Interruptions (calls, Siri, backgrounding) end capture without an error; the audio captured so far is returned by the next `stopRecording` / `stopStreaming`. A memory warning unloads an idle model (`modelState` goes to `present`); the next call reloads it.

A streaming session can also end without any signal reaching JavaScript: an interruption or backgrounding that arrives while the model is still loading, or WhisperKit's capture loop stopping on an internal error. `stopStreaming` then resolves with whatever was captured, possibly empty text, rather than rejecting.

## Where models live

`<Application Support>/expo-whisperkit/models/<name>`, excluded from iCloud backup. A model is reported `present` only after a complete download and a first successful load, which also caches the tokenizer so later loads need no network.

## Bumping WhisperKit

1. Change `WHISPERKIT_TAG` in `ios/whisperkit_version.rb`.
2. `cd example && npx expo prebuild -p ios --clean && npx expo run:ios --configuration Release`.
3. Run the Maestro flows (`example/e2e`, see `CLAUDE.md`).
4. Tag a release.

## Development

- `npm run prepare` builds; `CI=1 npm test` and `CI=1 npm test plugin` run Jest; `npm run lint`.
- The example app in `example/` is the test bed; see `CLAUDE.md` for the simulator and Maestro commands.

## License

MIT. WhisperKit is MIT, copyright Argmax, Inc.
