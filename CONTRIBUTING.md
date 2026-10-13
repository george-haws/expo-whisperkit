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

## CI

`.github/workflows/ci.yml` runs on every push to `main` and every pull request, and from the Actions tab (Run workflow). Three jobs run in parallel:

- `checks` (Linux): lint, the three Jest suites (`CI=1 npm test`, `CI=1 npm test plugin`, `CI=1 npm test internal`) and `npm run check:pack`, which fails if the tarball would ship maintainer files or miss a file consumers need.
- `swift` (macOS): `npm run test:ios`.
- `e2e` (macOS): the example app's Release build and all four Maestro flows. Flow 10 downloads the `base` model from Hugging Face every run; nothing is cached there on purpose. Every run uploads an `e2e-*` artifact with the Maestro report, screenshots and the build log.

`npm run --silent sim -- --boot` prints and boots the simulator CI uses; `EXPO_WHISPERKIT_SIM` pins one locally.

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

## Releasing

Pushing a tag `vX.Y.Z` runs `.github/workflows/release.yml`: it checks the tag, runs the full CI on the tagged commit, waits for approval of the `npm` environment, publishes through npm trusted publishing (with provenance, no token), and creates the GitHub Release from the CHANGELOG section.

1. Bump `version` in `package.json` and `package-lock.json` (`npm version X.Y.Z --no-git-tag-version`).
2. Rename `## Unreleased` in `CHANGELOG.md` to `## X.Y.Z - YYYY-MM-DD` and start a new empty `## Unreleased` above it.
3. Commit, merge to `main`, push `main`.
4. On an up-to-date `main`: `npm run check:release -- vX.Y.Z`.
5. `git tag vX.Y.Z && git push origin vX.Y.Z`.
6. Approve the `npm` deployment in the Actions run.

A prerelease (`X.Y.Z-rc.N`) publishes under the `next` dist-tag and is marked a prerelease on GitHub. Give it its own `## X.Y.Z-rc.N - YYYY-MM-DD` heading with a copy of the Unreleased notes, so the final release's section is still written from `Unreleased`.

If a release run fails: before `publish`, nothing was published; delete the tag (`git push origin :refs/tags/vX.Y.Z && git tag -d vX.Y.Z`), fix, and tag again. If `publish` or `github-release` failed, rerun the failed jobs; a version already on npm is skipped, not republished.

## Dependency advisories

`npm audit` reports advisories in Expo's prebuild tooling (`@expo/config-plugins` through `xcode`). The published package has no runtime dependencies, so none of them reach an app; they clear when Expo updates its tooling. Revisit on each Expo SDK bump.
