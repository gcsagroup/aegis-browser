#!/usr/bin/env node
import {appendFileSync, readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';

// This file is extracted from the merge candidate's first parent before use.
const gitRaw = (...args) => execFileSync('git', args, {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
const git = (...args) => gitRaw(...args).trimEnd();
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
const defaultsPath = 'scripts/ci/fill-platform-route-defaults.mjs';
const conventionalTypes = new Set(['build', 'chore', 'ci', 'docs', 'feat', 'fix', 'perf', 'refactor', 'release', 'revert', 'style', 'test']);
const isTypeName = value => {
  if (value.length === 0 || value.charCodeAt(0) < 97 || value.charCodeAt(0) > 122) return false;
  for (let index = 1; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    const lower = code >= 97 && code <= 122;
    const digit = code >= 48 && code <= 57;
    if (!lower && !digit && code !== 45) return false;
  }
  return conventionalTypes.has(value);
};
const parseConventionalType = subject => {
  const mark = subject.indexOf(': ');
  if (mark <= 0) return null;
  const body = subject.slice(mark + 2);
  if (body.length === 0 || body.charCodeAt(0) <= 32) return null;
  let head = subject.slice(0, mark);
  if (head.endsWith('!')) head = head.slice(0, -1);
  const open = head.indexOf('(');
  if (open !== -1) {
    if (!head.endsWith(')')) return null;
    const scope = head.slice(open + 1, -1);
    if (scope.length === 0 || scope.includes('(') || scope.includes(')')) return null;
    head = head.slice(0, open);
  }
  return isTypeName(head) ? head : null;
};
const integrateTypes = new Set(['feat', 'fix', 'perf', 'refactor', 'build', 'test', 'revert']);
const deepTypes = new Set(['feat', 'fix', 'perf', 'refactor', 'build', 'revert']);
const blankPlatforms = () => ({ios: false, android: false, macos: false, windows: false, linux: false});
const browserCommonScript = 'apps/browser/scripts/common.sh';
// These iOS release inputs have names outside the ios- / ios_ families.
// Keep ownership explicit so a new, unidentified release tool retains the macOS fallback.
const iosReleaseInputs = new Set([
  'scripts/release/artifact-transport.py',
  'scripts/release/build-ios-access-core.sh',
  'scripts/release/clear-empty-build-upload.rb',
  'scripts/release/cli.rb',
  'scripts/release/cloud-archive.py',
  'scripts/release/cloud-signing-poc.py',
  'scripts/release/development_key_access.py',
  'scripts/release/development_signing.py',
  'scripts/release/fixtures/safari-icon-xcode.png',
  'scripts/release/hosted-signing.py',
  'scripts/release/local-ios-signing.py',
  'scripts/release/prepare-ios-access-core.sh',
  'scripts/release/prepare-ios-package-core.sh',
  'scripts/release/private-beta-inputs.py',
  'scripts/release/product_artifacts.py',
  'scripts/release/product_delivery.py',
  'scripts/release/record-ios-access-core-digests.sh',
  'scripts/release/safari_manifest.py',
  'scripts/release/test_artifact_transport.py',
  'scripts/release/test_cloud_archive.py',
  'scripts/release/test_cloud_signing_poc.py',
  'scripts/release/test_development_key_access.py',
  'scripts/release/test_development_signing.py',
  'scripts/release/test_hosted_signing.py',
  'scripts/release/test_local_ios_signing.py',
  'scripts/release/test_native_signing_session.py',
  'scripts/release/test_private_beta_inputs.py',
  'scripts/release/test_product_artifacts.py',
  'scripts/release/test_product_delivery.py',
  'scripts/release/test_verify_ios_archive.py',
  'scripts/release/test_verify_ios_dsyms.py',
  'scripts/release/test_verify_ipa.py',
  'scripts/release/test_verify_signed_ios.py',
  'scripts/release/verify-ios-archive.py',
  'scripts/release/verify-ios-dsyms.py',
  'scripts/release/verify-ipa.py',
  'scripts/release/verify-signed-ios.py',
]);
// Match the top-level Ruby tests discovered by ios-release-validation.yml.
const iosFastlaneTest = /^fastlane\/tests\/(?!\.)[^/]*_test\.rb$/u;
const selectsIos = path => path.startsWith('apps/ios/')
  || path.startsWith('.github/workflows/ios-')
  || path.startsWith('scripts/ci/ios-')
  || path.startsWith('scripts/ci/run-ios-')
  || path.startsWith('scripts/ci/tests/ios-')
  || iosFastlaneTest.test(path)
  || /^scripts\/release\/(?:test_)?ios[-_]/u.test(path)
  || iosReleaseInputs.has(path);
const selectsAndroid = path => path.startsWith('apps/browser/patches-android/')
  || (path.startsWith('apps/browser/scripts/') && path.toLowerCase().includes('android'))
  || path === browserCommonScript
  || path.startsWith('.github/workflows/android-')
  || path.startsWith('scripts/ci/android-')
  || path.startsWith('scripts/ci/run-android-')
  || path.startsWith('scripts/ci/tests/android-')
  || path.startsWith('scripts/release/android-')
  || path.startsWith('scripts/release/android_')
  || (path.startsWith('scripts/release/test_android') && path.endsWith('.py'))
  || path === 'scripts/release/runner.rb'
  || path === 'scripts/release/verify-aab.py'
  || path === 'scripts/release/VerifiedAabCertificate.java';
const selectsMacos = path => path.startsWith('.github/workflows/macos-')
  || path === browserCommonScript
  || (path.startsWith('scripts/release/') && path.toLowerCase().includes('macos'));
const selectsWindows = path => path.endsWith('.ps1')
  || path.startsWith('scripts/ci/platform-tests/windows-')
  || path.startsWith('apps/browser/scripts/ci/windows')
  || (path.startsWith('apps/browser/scripts/') && path.toLowerCase().includes('winrm'));
const selectsLinux = path => path === 'scripts/ci/run-shell-coverage.sh'
  || path === 'scripts/ci/tests/shell-coverage.test.mjs'
  || path.startsWith('scripts/ci/platform-tests/kcov-');
const selectsShared = path => path.startsWith('packages/core/')
  || path.startsWith('apps/browser/overlay/')
  || (path.startsWith('apps/browser/patches/') && !path.startsWith('apps/browser/patches-android/'));
const classifyPath = path => {
  const selected = blankPlatforms();
  if (explanationPaths.has(path)) return selected;
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
const log = !legacyFull && base !== head ? gitRaw('log', '-z', '--format=tformat:%s', `${base}..${head}`) : '';
const subjects = log.split('\0');
if (subjects.pop() !== '') throw new Error('Incomplete Git subject log');
const types = new Set();
let nonConventional = false;
for (const subject of subjects) {
  const type = parseConventionalType(subject);
  if (!type) nonConventional = true;
  else types.add(type);
}
if (!legacyFull && changes.length > 0 && subjects.length === 0) nonConventional = true;
const contentEdit = change => change.status === 'M' && change.beforeMode === '100644' && change.afterMode === '100644';
const explanationOnly = changes.length > 0 && changes.every(change => explanationPaths.has(change.path) && contentEdit(change));
const selfEdit = changes.some(change => change.path === routerPath);
const defaultsEdit = changes.some(change => change.path === defaultsPath);
const unsafe = changes.some(isUnsafe);
const strict = selfEdit || unsafe || nonConventional;
const docs = event === 'pull_request' && explanationOnly && !strict && process.env.CI_LIGHTWEIGHT_ADMITTED === 'true';
const platforms = blankPlatforms();
let reason = 'path-and-type';
if (docs) reason = 'verified-document-content';
else if (event === 'pull_request' && explanationOnly && !strict) reason = 'document-content-unadmitted';
else if (selfEdit || defaultsEdit) {
  reason = selfEdit ? 'router-self-edit' : 'route-defaults-edit';
  platforms.ios = true;
  platforms.android = true;
  platforms.macos = true;
  platforms.windows = true;
  platforms.linux = true;
} else if (legacyFull) {
  reason = 'full-platform-fallback';
  platforms.ios = true;
  platforms.macos = true;
} else if (!explanationOnly) {
  for (const change of changes) {
    const selected = classifyPath(change.path);
    if (selected.ios) platforms.ios = true;
    if (selected.android) platforms.android = true;
    if (selected.macos) platforms.macos = true;
    if (selected.windows) platforms.windows = true;
    if (selected.linux) platforms.linux = true;
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
if (process.env.GITHUB_OUTPUT) {
  const lines = `docs=${plan.docs}\nios=${plan.ios}\nandroid=${plan.android}\nmacos=${plan.macos}\nwindows=${plan.windows}\nlinux=${plan.linux}\nintegrate=${plan.integrate}\ndeep=${plan.deep}\n`;
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- The runner supplies its own job output file and only boolean decisions are written.
  appendFileSync(process.env.GITHUB_OUTPUT, lines);
}
