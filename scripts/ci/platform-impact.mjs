#!/usr/bin/env node
import {appendFileSync, readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';

// This file is extracted from the merge candidate's first parent before use.
const git = (...args) => execFileSync('git', args, {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}).trimEnd();
const sha = value => {
  if (!/^[0-9a-f]{40}$/u.test(value ?? '')) throw new Error('Full commit SHA required');
  return git('rev-parse', '--verify', `${value}^{commit}`);
};
const event = process.env.GITHUB_EVENT_NAME;
const tested = sha(process.env.GITHUB_SHA);
if (git('rev-parse', 'HEAD') !== tested) throw new Error('Checkout differs from tested SHA');
let base = tested;
let head = tested;
if (event === 'pull_request') {
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- GitHub Actions provides the event file to this trusted base-owned script.
  const pr = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')).pull_request;
  const parents = git('show', '-s', '--format=%P', tested).split(' ');
  if (parents.length !== 2 || parents[1] !== sha(pr.head.sha)) {
    throw new Error('Merge candidate must have the exact current base/head parents');
  }
  git('merge-base', '--is-ancestor', sha(pr.base.sha), parents[0]);
  [base, head] = parents;
}
// Exact, reviewed explanation files only: their document-link consumer runs in
// the Linux gate. Never admit a directory, suffix, generated page or test input.
// New consumers require re-auditing their inputs before retaining this route.
// Keep this list inline: the classifier is extracted alone from the trusted base.
const explanationPaths = new Set([
  'docs/plans/access-build-portability/acceptance.md',
  'docs/ios-webkit-protection.en.md',
  'docs/ios-webkit-protection.zh-CN.md',
  'docs/ios-webkit-protection.zh-TW.md',
  'docs/plans/macos-access-toolbar-bubble-NOTES.md',
  'docs/plans/macos-access-bubble-session-NOTES.md',
]);
const raw = git('diff', '--raw', '--no-abbrev', '--no-renames', '-z', base, tested);
const fields = raw ? raw.split('\0') : [];
if (fields.at(-1) === '') fields.pop();
const changes = [];
const entries = fields.values();
for (const header of entries) {
  const match = /^:(\d{6}) (\d{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([AMDT])$/u.exec(header);
  const {value: path} = entries.next();
  if (!match || !path) throw new Error('Incomplete or unsupported Git diff');
  changes.push({path, beforeMode: match[1], afterMode: match[2], status: match[5]});
}
const docsOnly = event === 'pull_request' && changes.length > 0 && changes.every(change =>
  explanationPaths.has(change.path) &&
  change.status === 'M' && change.beforeMode === '100644' && change.afterMode === '100644');
const iosOnly = event === 'pull_request' && changes.length > 0 && changes.every(change => change.path.startsWith('apps/ios/'));
const plan = {schemaVersion: 1, event, base, head, tested, rulesSha: base, changes,
  docs: docsOnly && process.env.CI_LIGHTWEIGHT_ADMITTED === 'true', ios: !docsOnly, macos: !docsOnly && !iosOnly, reason: docsOnly ? 'verified-document-content' : 'full-platform-fallback'};
console.log(JSON.stringify(plan, null, 2));
// eslint-disable-next-line security/detect-non-literal-fs-filename -- The runner supplies its own job output file and only boolean decisions are written.
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `docs=${plan.docs}\nios=${plan.ios}\nmacos=${plan.macos}\n`);
