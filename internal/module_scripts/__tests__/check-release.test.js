const { checkRelease, changelogSection, commitIsOnMain } = require('../check-release');

const CHANGELOG = [
  '# Changelog',
  '',
  'Intro.',
  '',
  '## Unreleased',
  '',
  '- Next thing.',
  '',
  '## 0.2.0 - 2026-10-14',
  '',
  '### Added',
  '',
  '- A feature.',
  '',
  '## 0.1.0 - 2026-10-09',
  '',
  '- First release.',
  '',
].join('\n');

describe('checkRelease', () => {
  it('accepts a tag that matches the version and a dated heading', () => {
    expect(checkRelease({ tag: 'v0.2.0', version: '0.2.0', changelog: CHANGELOG })).toEqual([]);
  });

  it('rejects a tag that does not match package.json', () => {
    expect(checkRelease({ tag: 'v0.2.1', version: '0.2.0', changelog: CHANGELOG })).toEqual([
      'tag v0.2.1 does not match package.json version 0.2.0',
    ]);
  });

  it('rejects a version with no CHANGELOG heading', () => {
    expect(checkRelease({ tag: 'v0.3.0', version: '0.3.0', changelog: CHANGELOG })).toEqual([
      'CHANGELOG.md has no "## 0.3.0 - YYYY-MM-DD" heading',
    ]);
  });

  it('rejects a heading without a date', () => {
    const changelog = CHANGELOG.replace('## 0.2.0 - 2026-10-14', '## 0.2.0');
    expect(checkRelease({ tag: 'v0.2.0', version: '0.2.0', changelog })).toHaveLength(1);
  });

  it('does not take 0.2.10 for 0.2.1', () => {
    const changelog = CHANGELOG.replace('## 0.2.0 - 2026-10-14', '## 0.2.10 - 2026-10-14');
    expect(checkRelease({ tag: 'v0.2.1', version: '0.2.1', changelog })).toHaveLength(1);
  });

  it('accepts a prerelease with its own heading', () => {
    const changelog = CHANGELOG.replace('## Unreleased', '## Unreleased\n\n## 0.2.1-rc.1 - 2026-10-20');
    expect(checkRelease({ tag: 'v0.2.1-rc.1', version: '0.2.1-rc.1', changelog })).toEqual([]);
  });
});

describe('changelogSection', () => {
  it('returns the body up to the next version heading', () => {
    expect(changelogSection(CHANGELOG, '0.2.0')).toBe('### Added\n\n- A feature.');
  });

  it('returns the last section up to the end of the file', () => {
    expect(changelogSection(CHANGELOG, '0.1.0')).toBe('- First release.');
  });

  it('returns null for a version with no heading', () => {
    expect(changelogSection(CHANGELOG, '0.9.0')).toBeNull();
  });
});

function fakeGit({ hasOriginMain = true, tagCommit = null, ancestor = true } = {}) {
  const calls = [];
  const git = (args) => {
    calls.push(args.join(' '));
    if (args[0] === 'rev-parse' && args[3] === 'refs/remotes/origin/main') return { status: hasOriginMain ? 0 : 1, stdout: '' };
    if (args[0] === 'rev-parse') return tagCommit ? { status: 0, stdout: `${tagCommit}\n` } : { status: 1, stdout: '' };
    if (args[0] === 'fetch') return { status: 0, stdout: '' };
    if (args[0] === 'merge-base') return { status: ancestor ? 0 : 1, stdout: '' };
    throw new Error(`unexpected git ${args.join(' ')}`);
  };
  return { git, calls };
}

describe('commitIsOnMain', () => {
  it("checks the tag's commit when the tag exists", () => {
    const { git, calls } = fakeGit({ tagCommit: 'abc123' });
    expect(commitIsOnMain('v0.2.0', git)).toEqual({ commit: 'abc123', onMain: true });
    expect(calls).toContain('merge-base --is-ancestor abc123 refs/remotes/origin/main');
  });

  it('checks HEAD when the tag does not exist yet', () => {
    const { git, calls } = fakeGit();
    expect(commitIsOnMain('v0.2.0', git)).toEqual({ commit: 'HEAD', onMain: true });
    expect(calls).toContain('merge-base --is-ancestor HEAD refs/remotes/origin/main');
  });

  it('fetches origin/main when it is missing', () => {
    const { git, calls } = fakeGit({ hasOriginMain: false });
    commitIsOnMain('v0.2.0', git);
    expect(calls).toContain('fetch --quiet origin +refs/heads/main:refs/remotes/origin/main');
  });

  it('does not fetch when origin/main is present', () => {
    const { git, calls } = fakeGit();
    commitIsOnMain('v0.2.0', git);
    expect(calls.some((c) => c.startsWith('fetch'))).toBe(false);
  });

  it('reports a commit that is not on main', () => {
    const { git } = fakeGit({ tagCommit: 'abc123', ancestor: false });
    expect(commitIsOnMain('v0.2.0', git).onMain).toBe(false);
  });
});
