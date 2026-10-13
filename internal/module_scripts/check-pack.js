#!/usr/bin/env node
// Checks what `npm publish` would ship. The `files` allowlist in package.json decides the tarball;
// this catches an edit to it that lets maintainer files in or drops something consumers need.
// Run `npm run prepare` first: build/ and plugin/build/ are required.
const { spawnSync } = require('child_process');
const path = require('path');

const FORBIDDEN_PREFIXES = ['CLAUDE.md', 'docs/', 'example/', 'Tests/', 'internal/', '.github/'];
const FORBIDDEN_FOLDERS = ['__tests__/', '__mocks__/'];

const REQUIRED = [
  'build/index.js',
  'build/index.d.ts',
  'plugin/build/withWhisperKit.js',
  'app.plugin.js',
  'expo-module.config.json',
  'ios/ExpoWhisperKit.podspec',
  'ios/WhisperKit.podspec',
  'ios/ArgmaxCore.podspec',
  'ios/whisperkit_version.rb',
  'README.md',
  'LICENSE',
  'CHANGELOG.md',
];

function isForbidden(file) {
  return (
    FORBIDDEN_PREFIXES.some((prefix) => file.startsWith(prefix)) ||
    FORBIDDEN_FOLDERS.some((folder) => file.startsWith(folder) || file.includes(`/${folder}`))
  );
}

function checkPack(paths) {
  return {
    forbidden: paths.filter(isForbidden),
    missing: REQUIRED.filter((file) => !paths.includes(file)),
  };
}

module.exports = { checkPack, REQUIRED };

if (require.main === module) {
  const root = path.join(__dirname, '..', '..');
  // --ignore-scripts: `prepare` would otherwise print its output into the JSON on stdout.
  const pack = spawnSync('npm', ['pack', '--dry-run', '--json', '--ignore-scripts'], { cwd: root, encoding: 'utf8' });
  if (pack.status !== 0) {
    process.stderr.write(pack.stderr);
    process.exit(1);
  }
  const paths = JSON.parse(pack.stdout)[0].files.map((f) => f.path);
  const { forbidden, missing } = checkPack(paths);
  for (const file of forbidden) console.error(`check-pack: must not ship ${file}`);
  for (const file of missing) console.error(`check-pack: missing ${file}`);
  if (forbidden.length || missing.length) process.exit(1);
  console.log(`check-pack: ${paths.length} files, ok`);
}
