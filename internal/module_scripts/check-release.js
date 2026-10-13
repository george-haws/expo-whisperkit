#!/usr/bin/env node
// `check-release <tag>` fails unless the tag is v + package.json's version, CHANGELOG.md has a dated
// heading for that version, and the commit (the tag's, or HEAD before tagging) is on origin/main.
// `check-release <tag> --notes` runs none of those checks and prints only that version's CHANGELOG
// section, for the GitHub Release body.
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const headingPattern = (version) => new RegExp(`^## ${escape(version)} - \\d{4}-\\d{2}-\\d{2}$`);

function checkRelease({ tag, version, changelog }) {
  const errors = [];
  if (tag !== `v${version}`) errors.push(`tag ${tag} does not match package.json version ${version}`);
  if (!changelog.split('\n').some((line) => headingPattern(version).test(line))) {
    errors.push(`CHANGELOG.md has no "## ${version} - YYYY-MM-DD" heading`);
  }
  return errors;
}

function changelogSection(changelog, version) {
  const lines = changelog.split('\n');
  const start = lines.findIndex((line) => headingPattern(version).test(line));
  if (start === -1) return null;
  const rest = lines.slice(start + 1);
  const end = rest.findIndex((line) => line.startsWith('## '));
  return (end === -1 ? rest : rest.slice(0, end)).join('\n').trim();
}

const runGit = (args) => spawnSync('git', args, { encoding: 'utf8' });

function commitIsOnMain(tag, git = runGit) {
  if (git(['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main']).status !== 0) {
    git(['fetch', '--quiet', 'origin', '+refs/heads/main:refs/remotes/origin/main']);
  }
  const tagged = git(['rev-parse', '--verify', '--quiet', `refs/tags/${tag}^{commit}`]);
  const commit = tagged.status === 0 ? tagged.stdout.trim() : 'HEAD';
  const onMain = git(['merge-base', '--is-ancestor', commit, 'refs/remotes/origin/main']).status === 0;
  return { commit, onMain };
}

module.exports = { checkRelease, changelogSection, commitIsOnMain };

if (require.main === module) {
  const root = path.join(__dirname, '..', '..');
  const args = process.argv.slice(2);
  const tag = args.find((arg) => !arg.startsWith('--'));
  if (!tag) {
    console.error('usage: check-release <tag> [--notes]');
    process.exit(2);
  }
  const changelog = fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8');

  if (args.includes('--notes')) {
    const section = changelogSection(changelog, tag.replace(/^v/, ''));
    if (section === null) {
      console.error(`check-release: CHANGELOG.md has no section for ${tag}`);
      process.exit(1);
    }
    process.stdout.write(`${section}\n`);
    process.exit(0);
  }

  const { version } = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const errors = checkRelease({ tag, version, changelog });
  const { commit, onMain } = commitIsOnMain(tag);
  if (!onMain) errors.push(`${commit} is not on origin/main`);
  for (const error of errors) console.error(`check-release: ${error}`);
  if (errors.length) process.exit(1);
  console.log(`check-release: ${tag} ok`);
}
