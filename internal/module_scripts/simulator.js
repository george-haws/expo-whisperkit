#!/usr/bin/env node
// Picks the iOS simulator for the Swift tests and the e2e job. EXPO_WHISPERKIT_SIM pins a UDID.
// Otherwise a booted iPhone, else an iPhone on the newest iOS runtime.
// `npm run --silent sim [-- --boot]` prints the UDID alone on stdout; every log line goes to stderr,
// so `$(npm run --silent sim)` captures just the UDID. `--boot` boots it and waits for the boot.
const { spawnSync } = require('child_process');

function chooseIphone(devicesByRuntime) {
  const iphones = Object.entries(devicesByRuntime)
    .map(([runtime, devices]) => {
      const match = /\.iOS-(\d+)-(\d+)$/.exec(runtime);
      return match ? devices.map((d) => ({ ...d, os: Number(match[1]) * 100 + Number(match[2]) })) : [];
    })
    .flat()
    .filter((d) => d.name.startsWith('iPhone'))
    .sort((a, b) => b.os - a.os);
  return iphones.find((d) => d.state === 'Booted') || iphones[0] || null;
}

function pickSimulator() {
  if (process.env.EXPO_WHISPERKIT_SIM) return process.env.EXPO_WHISPERKIT_SIM;
  const list = spawnSync('xcrun', ['simctl', 'list', 'devices', 'available', '-j'], { encoding: 'utf8' });
  if (list.status !== 0) {
    console.error('simulator: `xcrun simctl list` failed; is Xcode installed?');
    process.exit(1);
  }
  const device = chooseIphone(JSON.parse(list.stdout).devices);
  if (!device) {
    console.error('simulator: no available iPhone simulator. Create one in Xcode, or set EXPO_WHISPERKIT_SIM.');
    process.exit(1);
  }
  console.error(`simulator: using ${device.name} (${device.udid}); set EXPO_WHISPERKIT_SIM to pin another`);
  return device.udid;
}

// `bootstatus -b` boots the device if needed and returns once it has finished booting.
function boot(udid) {
  const result = spawnSync('xcrun', ['simctl', 'bootstatus', udid, '-b'], { stdio: ['ignore', 'ignore', 'inherit'] });
  if (result.status !== 0) {
    console.error(`simulator: could not boot ${udid}`);
    process.exit(1);
  }
}

module.exports = { chooseIphone, pickSimulator };

if (require.main === module) {
  const udid = pickSimulator();
  if (process.argv.includes('--boot')) boot(udid);
  console.log(udid);
}
