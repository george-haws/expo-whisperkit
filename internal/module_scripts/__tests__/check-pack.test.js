const { checkPack, REQUIRED } = require('../check-pack');

describe('checkPack', () => {
  it('passes a tarball with every required file and nothing forbidden', () => {
    expect(checkPack([...REQUIRED, 'src/index.ts', 'ios/Engine.swift'])).toEqual({ forbidden: [], missing: [] });
  });

  it.each([
    'CLAUDE.md',
    'docs/superpowers/WORKLOG.md',
    'example/App.tsx',
    'Tests/ExpoWhisperKitCoreTests/EngineTests.swift',
    'internal/module_scripts/test.js',
    '.github/workflows/ci.yml',
    'src/__tests__/errors.test.ts',
    '__mocks__/expo.ts',
    'src/__mocks__/expo.ts',
  ])('flags %s', (path) => {
    expect(checkPack([...REQUIRED, path]).forbidden).toEqual([path]);
  });

  it('does not flag names that only share a prefix with a forbidden folder', () => {
    expect(checkPack([...REQUIRED, 'documentation.md', 'src/examples.ts']).forbidden).toEqual([]);
  });

  it('reports each missing required file', () => {
    const paths = REQUIRED.filter((p) => p !== 'build/index.js' && p !== 'ios/WhisperKit.podspec');
    expect(checkPack(paths).missing).toEqual(['build/index.js', 'ios/WhisperKit.podspec']);
  });
});
