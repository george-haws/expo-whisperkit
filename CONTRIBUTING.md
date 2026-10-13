# Contributing

## Setup

Requires Node 20.19.4 or newer, Xcode 16 or newer and CocoaPods. WhisperKit compiles from source as two pods; there are no Ruby gems to install. The generated Podfile shells out to `node`, so the `node` on your `PATH` must be a working install (an nvm-managed one is fine).

```sh
npm install   # also runs `npm run prepare`, which builds build/ and plugin/build/
```

## Checks

- `npm run lint`
- `CI=1 npm test` runs the TypeScript Jest suite; `CI=1 npm test plugin` runs the config plugin suite. Without `CI=1` Jest enters watch mode on a TTY.
- `npm run test:ios` runs the Swift unit tests (`xcodebuild test` over the root `Package.swift`) on a simulator. Set `EXPO_WHISPERKIT_SIM=<simulator UDID>` (`xcrun simctl list devices available` lists them). Pass xcodebuild flags after `--`, for example `-- -only-testing:ExpoWhisperKitCoreTests/EngineTests`. `VERBOSE=1` shows the full build log.

## Example app and end-to-end flows

The app in `example/` is the test bed. A Release build embeds the JS bundle, so the Maestro flows need no Metro.

```sh
SIM=<simulator UDID>
cd example
npx expo prebuild -p ios --clean
npx expo run:ios --configuration Release --device $SIM --no-bundler
xcrun simctl privacy $SIM grant microphone expo.modules.whisperkit.example
maestro --device $SIM test e2e/
```

The simulator uses the Mac's microphone, so the flows check behaviour, not recognition quality. Changes to recording, streaming or interruption handling also need a run on a physical device.
