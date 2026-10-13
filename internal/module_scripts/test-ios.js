#!/usr/bin/env node
// Runs the Swift unit tests on the iOS simulator. Refuses to run when Package.swift and
// ios/whisperkit_version.rb pin different WhisperKit versions. Extra arguments go to xcodebuild,
// e.g. `npm run test:ios -- -only-testing:ExpoWhisperKitCoreTests/EngineTests`.
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..', '..');
const SCHEME = 'expo-whisperkit';

function read(relative, pattern, what) {
  const text = fs.readFileSync(path.join(root, relative), 'utf8');
  const match = pattern.exec(text);
  if (!match) {
    console.error(`test-ios: ${what} not found in ${relative}`);
    process.exit(1);
  }
  return match[1];
}

const tag = read('ios/whisperkit_version.rb', /WHISPERKIT_TAG\s*=\s*'([^']+)'/, 'WHISPERKIT_TAG');
const commit = read('ios/whisperkit_version.rb', /WHISPERKIT_COMMIT\s*=\s*'([0-9a-f]{40})'/, 'WHISPERKIT_COMMIT');
const version = read('Package.swift', /let whisperKitVersion\s*=\s*"([^"]+)"/, 'whisperKitVersion');
if (`v${version}` !== tag) {
  console.error(
    `test-ios: WhisperKit version drift: ios/whisperkit_version.rb pins ${tag}, Package.swift pins ${version}`
  );
  process.exit(1);
}
const resolved = JSON.parse(fs.readFileSync(path.join(root, 'Package.resolved'), 'utf8'));
const pin = (resolved.pins || []).find((p) => p.identity === 'argmax-oss-swift');
if (!pin || pin.state.revision !== commit) {
  console.error(
    `test-ios: WhisperKit commit drift: ios/whisperkit_version.rb pins ${commit}, Package.resolved pins ${pin ? pin.state.revision : 'nothing'}`
  );
  process.exit(1);
}

// EXPO_WHISPERKIT_SIM pins a simulator UDID. Otherwise use a booted iPhone, else an iPhone on the
// newest iOS runtime.
function pickSimulator() {
  if (process.env.EXPO_WHISPERKIT_SIM) return process.env.EXPO_WHISPERKIT_SIM;
  const list = spawnSync('xcrun', ['simctl', 'list', 'devices', 'available', '-j'], { encoding: 'utf8' });
  if (list.status !== 0) {
    console.error('test-ios: `xcrun simctl list` failed; is Xcode installed?');
    process.exit(1);
  }
  const iphones = Object.entries(JSON.parse(list.stdout).devices)
    .map(([runtime, devices]) => {
      const match = /\.iOS-(\d+)-(\d+)$/.exec(runtime);
      return match ? devices.map((d) => ({ ...d, os: Number(match[1]) * 100 + Number(match[2]) })) : [];
    })
    .flat()
    .filter((d) => d.name.startsWith('iPhone'))
    .sort((a, b) => b.os - a.os);
  const device = iphones.find((d) => d.state === 'Booted') || iphones[0];
  if (!device) {
    console.error('test-ios: no available iPhone simulator. Create one in Xcode, or set EXPO_WHISPERKIT_SIM.');
    process.exit(1);
  }
  console.log(`test-ios: using ${device.name} (${device.udid}); set EXPO_WHISPERKIT_SIM to pin another`);
  return device.udid;
}

const simulator = pickSimulator();
const args = [
  'test',
  '-scheme', SCHEME,
  '-destination', `platform=iOS Simulator,id=${simulator}`,
  '-derivedDataPath', path.join(root, '.build', 'xcode'),
  '-test-timeouts-enabled', 'YES',
  '-default-test-execution-time-allowance', '60',
  ...process.argv.slice(2),
];

if (process.env.VERBOSE) {
  const result = spawnSync('xcodebuild', args, { cwd: root, stdio: 'inherit' });
  process.exit(result.status ?? 1);
}

// xcodebuild prints thousands of build lines; keep the test lines and anything that explains a failure.
const KEEP = /(^|\s)(error|warning):|Test Case|Test Suite|Executed \d+ tests?|\*\* (TEST|BUILD)|xcodebuild: error|XCTAssert|failed:/;
const result = spawnSync('xcodebuild', args, { cwd: root, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
const lines = `${result.stdout ?? ''}\n${result.stderr ?? ''}`.split('\n');
for (const line of lines) {
  if (KEEP.test(line)) console.log(line);
}
if (result.status !== 0) {
  console.error(`test-ios: xcodebuild exited with ${result.status}. Re-run with VERBOSE=1 for the full log.`);
}
process.exit(result.status ?? 1);
