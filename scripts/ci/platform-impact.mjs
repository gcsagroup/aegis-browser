#!/usr/bin/env node
import {appendFileSync, readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';

// This file is extracted from the merge candidate's first parent before use.
const git = (...args) => execFileSync('git', args, {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}).trimEnd();
const sha = value => {
  if (!/^[0-9a-f]{40}$/u.test(value ?? '')) throw new Error('Full commit SHA required');
  return git('rev-parse', '--verify', `${value}^{commit}`);
};
const isAncestor = (parent, child) => {
  try {
    execFileSync('git', ['merge-base', '--is-ancestor', parent, child], {stdio: 'ignore'});
    return true;
  } catch {
    return false;
  }
};
const event = process.env.GITHUB_EVENT_NAME;
const tested = sha(process.env.GITHUB_SHA);
if (git('rev-parse', 'HEAD') !== tested) throw new Error('Checkout differs from tested SHA');
let base = tested;
let head = tested;
let legacyFull = event === 'workflow_dispatch';
if (event === 'pull_request') {
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- GitHub Actions provides the event file to this trusted base-owned script.
  const pr = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')).pull_request;
  const parents = git('show', '-s', '--format=%P', tested).split(' ');
  if (parents.length !== 2 || parents[1] !== sha(pr.head.sha)) {
    throw new Error('Merge candidate must have the exact current base/head parents');
  }
  git('merge-base', '--is-ancestor', sha(pr.base.sha), parents[0]);
  [base, head] = parents;
} else if (event === 'push') {
  const before = process.env.ROUTE_PUSH_BEFORE ?? '';
  if (!/^[0-9a-f]{40}$/u.test(before) || /^0{40}$/u.test(before)) legacyFull = true;
  else {
    let resolved = '';
    try {
      resolved = sha(before);
    } catch {
      legacyFull = true;
    }
    if (!legacyFull && resolved === tested) legacyFull = true;
    else if (!legacyFull && !isAncestor(resolved, tested)) legacyFull = true;
    else if (!legacyFull) base = resolved;
  }
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
const routerPath = 'scripts/ci/platform-impact.mjs';
const conventionalTypes = new Set(['build', 'chore', 'ci', 'docs', 'feat', 'fix', 'perf', 'refactor', 'release', 'revert', 'style', 'test']);
const conventionalTitle = /^(?<type>[a-z][a-z0-9-]*)(?:\([^()\r\n]*\))?!?: (?<subject>\S.*)$/u;
const integrateTypes = new Set(['feat', 'fix', 'perf', 'refactor', 'build', 'test', 'revert']);
const deepTypes = new Set(['feat', 'fix', 'perf', 'refactor', 'build', 'revert']);
const blankPlatforms = () => ({ios: false, android: false, macos: false, windows: false, linux: false});
const selectsIos = path => path.startsWith('apps/ios/')
  || path.startsWith('.github/workflows/ios-')
  || path.startsWith('scripts/ci/ios-')
  || path.startsWith('scripts/ci/run-ios-');
const selectsAndroid = path => path.startsWith('apps/browser/patches-android/')
  || (path.startsWith('apps/browser/scripts/') && path.toLowerCase().includes('android'))
  || path.startsWith('.github/workflows/android-')
  || path.startsWith('scripts/ci/android-')
  || path.startsWith('scripts/ci/run-android-');
const selectsMacos = path => path.startsWith('.github/workflows/macos-')
  || (path.startsWith('scripts/release/') && path.toLowerCase().includes('macos'));
const selectsWindows = path => path.endsWith('.ps1')
  || path.startsWith('scripts/ci/platform-tests/windows-')
  || path.startsWith('apps/browser/scripts/ci/windows')
  || (path.startsWith('apps/browser/scripts/') && path.toLowerCase().includes('winrm'));
const selectsLinux = path => path === 'scripts/ci/run-shell-coverage.sh' || path.startsWith('scripts/ci/platform-tests/kcov-');
const selectsShared = path => path.startsWith('packages/core/')
  || path.startsWith('apps/browser/overlay/')
  || (path.startsWith('apps/browser/patches/') && !path.startsWith('apps/browser/patches-android/'));
const classifyPath = path => {
  const selected = blankPlatforms();
  if (explanationPaths.has(path) || path === routerPath) return selected;
  if (selectsIos(path)) selected.ios = true;
  if (selectsAndroid(path)) selected.android = true;
  if (selectsMacos(path)) selected.macos = true;
  if (selectsWindows(path)) selected.windows = true;
  if (selectsLinux(path)) selected.linux = true;
  if (selectsShared(path)) selected.macos = true;
  if (!Object.values(selected).some(Boolean)) selected.macos = true;
  return selected;
};
const isUnsafe = change => change.status === 'D' || change.status === 'T'
  || change.beforeMode === '120000' || change.afterMode === '120000'
  || (change.status === 'M' && change.beforeMode !== change.afterMode);
const raw = legacyFull ? '' : git('diff', '--raw', '--no-abbrev', '--no-renames', '-z', base, tested);
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
const log = !legacyFull && base !== head ? git('log', '--format=%s', `${base}..${head}`) : '';
const subjects = log ? log.split('\n') : [];
const types = new Set();
let nonConventional = false;
for (const subject of subjects) {
  const match = conventionalTitle.exec(subject);
  if (!match || !conventionalTypes.has(match.groups.type)) nonConventional = true;
  else types.add(match.groups.type);
}
if (!legacyFull && changes.length > 0 && subjects.length === 0) nonConventional = true;
const contentEdit = change => change.status === 'M' && change.beforeMode === '100644' && change.afterMode === '100644';
const explanationOnly = changes.length > 0 && changes.every(change => explanationPaths.has(change.path) && contentEdit(change));
const selfEdit = changes.some(change => change.path === routerPath);
const unsafe = changes.some(isUnsafe);
const strict = selfEdit || unsafe || nonConventional;
const docs = event === 'pull_request' && explanationOnly && !strict && process.env.CI_LIGHTWEIGHT_ADMITTED === 'true';
const platforms = blankPlatforms();
let reason = 'path-and-type';
if (docs) reason = 'verified-document-content';
else if (event === 'pull_request' && explanationOnly && !strict) reason = 'document-content-unadmitted';
else if (selfEdit) {
  reason = 'router-self-edit';
  for (const key of Object.keys(platforms)) platforms[key] = true;
} else if (legacyFull) {
  reason = 'full-platform-fallback';
  platforms.ios = true;
  platforms.macos = true;
} else if (!explanationOnly) {
  for (const change of changes) {
    const selected = classifyPath(change.path);
    for (const [key, value] of Object.entries(selected)) if (value) platforms[key] = true;
  }
  if (strict) reason = 'strict-change';
}
const typeList = [...types];
const deepen = !docs && (legacyFull || event === 'push' || strict || typeList.some(type => deepTypes.has(type)));
const integrate = deepen || (!docs && (legacyFull || event === 'push' || strict || typeList.some(type => integrateTypes.has(type))));
const deep = deepen;
const plan = {
  schemaVersion: 2, event, base, head, tested, rulesSha: event === 'pull_request' ? base : tested, changes,
  types: [...types].sort(), strict, docs, ...platforms, gate: true, integrate, deep, reason,
};
console.log(JSON.stringify(plan, null, 2));
// eslint-disable-next-line security/detect-non-literal-fs-filename -- The runner supplies its own job output file and only boolean decisions are written.
if (process.env.GITHUB_OUTPUT) {
  const lines = ['docs', 'ios', 'android', 'macos', 'windows', 'linux', 'integrate', 'deep']
    .map(key => `${key}=${plan[key]}`);
  appendFileSync(process.env.GITHUB_OUTPUT, `${lines.join('\n')}\n`);
}
