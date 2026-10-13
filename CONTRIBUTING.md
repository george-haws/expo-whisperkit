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

## Bumping WhisperKit

1. Change `WHISPERKIT_TAG` and `WHISPERKIT_COMMIT` in `ios/whisperkit_version.rb` (`git ls-remote --tags https://github.com/argmaxinc/argmax-oss-swift.git 'v*'` shows the commit), `whisperKitVersion` in `Package.swift`, and let `npm run test:ios` refresh `Package.resolved`; it refuses to run while the three disagree.
2. `cd example && npx expo prebuild -p ios --clean && npx expo run:ios --configuration Release`.
3. Run the Maestro flows in `example/e2e` (see [above](#example-app-and-end-to-end-flows)).
4. Tag a release.

## Dependency advisories

`npm audit` reports advisories in Expo's prebuild tooling (`@expo/config-plugins` through `xcode`). The published package has no runtime dependencies, so none of them reach an app; they clear when Expo updates its tooling. Revisit on each Expo SDK bump.
