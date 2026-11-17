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
  const pr = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')).pull_request;
  const parents = git('show', '-s', '--format=%P', tested).split(' ');
  if (parents.length !== 2 || parents[1] !== sha(pr.head.sha)) {
    throw new Error('Merge candidate must have the exact current base/head parents');
  }
  git('merge-base', '--is-ancestor', sha(pr.base.sha), parents[0]);
  [base, head] = parents;
}
// Only one verified documentation input is admitted initially. New types require
// consumer tests and a reviewed expansion of this trusted rule.
const raw = git('diff', '--raw', '--no-abbrev', '--no-renames', '-z', base, tested);
const fields = raw ? raw.split('\0') : [];
if (fields.at(-1) === '') fields.pop();
const changes = [];
for (let index = 0; index < fields.length; index += 2) {
  const match = /^:(\d{6}) (\d{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([AMDT])$/u.exec(fields[index]);
  if (!match || !fields[index + 1]) throw new Error('Incomplete or unsupported Git diff');
  changes.push({path: fields[index + 1], beforeMode: match[1], afterMode: match[2], status: match[5]});
}
const docsOnly = event === 'pull_request' && changes.length > 0 && changes.every(change =>
  change.path === 'docs/plans/access-build-portability/acceptance.md' &&
  change.status === 'M' && change.beforeMode === '100644' && change.afterMode === '100644');
const plan = {schemaVersion: 1, event, base, head, tested, rulesSha: base, changes,
  ios: !docsOnly, reason: docsOnly ? 'verified-document-content' : 'full-platform-fallback'};
console.log(JSON.stringify(plan, null, 2));
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `ios=${plan.ios}\n`);
