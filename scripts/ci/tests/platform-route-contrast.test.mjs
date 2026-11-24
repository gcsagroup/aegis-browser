import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';

const routerPath = 'scripts/ci/platform-impact.mjs';
// Upstream main keeps this router unchanged from the 0049a1f3 baseline.
const upstreamBaseline = '0049a1f3eb79fdbc97ebd9367ff764c70d36c674';
const upstreamMain = '423ac9840808da531e880e4e7c82244fd20c34d7';
// Fork develop after #412 and before #410.
const forkWithAndroidRules = '2c07cd24c5749e01820737d4354f77cceb0270f7';

const pr226 = {
  subject: 'fix(android): query Play generatedApks by versionCode',
  paths: [
    'scripts/release/android-play.py',
    'scripts/release/test_android_play.py',
    'scripts/release/test_android_release_matrix.py',
  ],
};
const pr217 = {
  subject: 'feat(windows): align uninstall dialog with installer',
  paths: [
    'apps/browser/overlay/chrome/browser/ui/views/uninstall_view.cc',
    'apps/browser/overlay/chrome/browser/ui/views/uninstall_view.h',
    'apps/browser/overlay/chrome/browser/ui/views/uninstall_view_unittest.cc',
    'apps/browser/overlay/chrome/browser/ui/views/aegis_uninstall_test_main.cc',
    'apps/browser/overlay/chrome/app/theme/chrome_unscaled_resources.grd',
    'apps/browser/patches/0532-align-windows-uninstall-ui.patch',
    'apps/browser/patches/series',
    'apps/browser/scripts/windows-uninstall-branding_test.py',
    'docs/windows-installer.zh-CN.md',
  ],
};

const hasCommit = sha => spawnSync('git', ['cat-file', '-e', `${sha}^{commit}`]).status === 0;
const routerAt = sha => execFileSync('git', ['show', `${sha}:${routerPath}`], {encoding: 'utf8'});

const withRepo = (body) => {
  const root = mkdtempSync(join(tmpdir(), 'route-contrast-'));
  const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  const save = (path, text) => {
    mkdirSync(join(root, path, '..'), {recursive: true});
    writeFileSync(join(root, path), text);
  };
  try {
    git('init', '-q', '-b', 'develop');
    git('config', 'user.name', 'Route Contrast');
    git('config', 'user.email', 'route-contrast@example.invalid');
    return body({root, git, save});
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
};

// Replays the input as a PR merge candidate and runs the given router source.
const replay = (routerSource, {paths, subjects}, {schema = 2, admitted = 'false'} = {}) => withRepo(({root, git, save}) => {
  for (const path of paths) save(path, 'base');
  git('add', '-A');
  git('commit', '-q', '-m', 'base');
  const base = git('rev-parse', 'HEAD');
  git('checkout', '-q', '-b', 'topic');
  subjects.forEach((subject, index) => {
    for (const path of paths) save(path, `change ${index}`);
    git('add', '-A');
    git('commit', '-q', '-m', subject);
  });
  const head = git('rev-parse', 'HEAD');
  git('checkout', '-q', 'develop');
  git('merge', '-q', '--no-ff', 'topic', '-m', 'candidate');
  const tested = git('rev-parse', 'HEAD');
  const router = join(root, '.git', 'router.mjs');
  const event = join(root, '.git', 'event.json');
  writeFileSync(router, routerSource);
  writeFileSync(event, JSON.stringify({pull_request: {draft: false, base: {sha: base}, head: {sha: head}}}));
  const result = spawnSync(process.execPath, [router], {
    cwd: root,
    encoding: 'utf8',
    env: {
      ...process.env,
      CI_LIGHTWEIGHT_ADMITTED: admitted,
      GITHUB_EVENT_NAME: 'pull_request',
      GITHUB_SHA: tested,
      GITHUB_EVENT_PATH: event,
      GITHUB_OUTPUT: '',
    },
  });
  assert.equal(result.status, 0, result.stderr);
  const plan = JSON.parse(result.stdout);
  assert.equal(plan.schemaVersion, schema);
  assert.equal(plan.rulesSha, base);
  return plan;
});

const platforms = plan => ({
  ios: plan.ios, android: plan.android, macos: plan.macos, windows: plan.windows, linux: plan.linux,
});
const none = {ios: false, android: false, macos: false, windows: false, linux: false};
const route = (source, input, options) => platforms(replay(source, {paths: input.paths, subjects: [input.subject]}, options));
const current = () => readFileSync(resolve(routerPath), 'utf8');
// Reviewed explanation file kept by the current router as lightweight document content.
const explanationFile = 'docs/ios-webkit-protection.en.md';

test('upstream main keeps the baseline router used for contrast', {skip: !hasCommit(upstreamMain) && 'upstream main is not fetched'}, () => {
  assert.equal(routerAt(upstreamMain), routerAt(upstreamBaseline));
});

test('upstream baseline rules miss both #226 Android and #217 Windows', {skip: !hasCommit(upstreamBaseline) && 'baseline is not fetched'}, () => {
  const source = routerAt(upstreamBaseline);
  assert.deepEqual(route(source, pr226), {...none, macos: true});
  assert.deepEqual(route(source, pr217), {...none, macos: true});
});

test('fork develop with #412 selects #226 Android but still misses #217 Windows', {skip: !hasCommit(forkWithAndroidRules) && 'fork develop rules are not fetched'}, () => {
  const source = routerAt(forkWithAndroidRules);
  assert.deepEqual(route(source, pr226), {...none, android: true});
  assert.deepEqual(route(source, pr217), {...none, macos: true});
});

test('current develop rules select #226 Android and #217 Windows with the shared macOS contract', () => {
  const source = current();
  const schema3 = {schema: 3};
  assert.deepEqual(route(source, pr226, schema3), {...none, android: true});
  assert.deepEqual(route(source, pr217, schema3), {...none, macos: true, windows: true});
});

test('current develop rules keep Android patches with windows in the name off Windows', () => {
  const source = current();
  const input = {
    subject: 'fix: refresh android track',
    paths: ['apps/browser/patches-android/0237-windows-midl-path-095.patch'],
  };
  assert.deepEqual(route(source, input, {schema: 3}), {...none, android: true});
});

test('only a reviewed explanation file can take the lightweight document route', () => {
  const source = current();
  const admitted = replay(source, {paths: [explanationFile], subjects: ['docs: refresh overview']}, {schema: 3, admitted: 'true'});
  assert.equal(admitted.docs, true);
  assert.equal(admitted.integrate, false);
  assert.equal(admitted.deep, false);
  const unadmitted = replay(source, {paths: [explanationFile], subjects: ['docs: refresh overview']}, {schema: 3, admitted: 'false'});
  assert.equal(unadmitted.docs, false);
  assert.equal(unadmitted.reason, 'document-content-unadmitted');
  assert.equal(unadmitted.integrate, false);
  const readme = replay(source, {paths: ['README.md'], subjects: ['docs: refresh overview']}, {schema: 3, admitted: 'true'});
  assert.equal(readme.docs, false);
  assert.equal(readme.integrate, true);
});

test('promotion merge subjects keep the deep stage', () => {
  const source = current();
  const plan = replay(source, {
    paths: [explanationFile],
    subjects: ['docs: refresh overview', 'Merge pull request #1 from fork/codex/feature'],
  }, {schema: 3, admitted: 'true'});
  assert.equal(plan.docs, false);
  assert.equal(plan.integrate, true);
  assert.equal(plan.deep, true);
});

test('current develop rules route a representative input of every platform', () => {
  const source = current();
  const only = (...selected) => ({...none, ...Object.fromEntries(selected.map(name => [name, true]))});
  const cases = [
    ['ios simulator script', 'fix: repair ios', 'apps/ios/scripts/run-simulator-tests.sh', only('ios')],
    ['ios fastlane helper', 'fix: repair ios', 'fastlane/lib/ios_status.rb', only('ios')],
    ['ios release action', 'fix: repair ios', 'scripts/release/ios-action.py', only('ios')],
    ['android play script', 'fix(android): play', 'scripts/release/android-play.py', only('android')],
    ['android pin', 'chore: android input', 'apps/browser/ci-pins/android.json', only('android')],
    ['desktop patch series', 'feat: shared product', 'apps/browser/patches/series', only('macos', 'windows')],
    ['macos workflow', 'ci: macos', '.github/workflows/macos-contract.yml', only('macos')],
    ['windows powershell', 'perf: windows', 'scripts/ci/platform-tests/windows-acceptance.ps1', only('windows')],
    ['windows installer', 'feat: installer', 'apps/browser/overlay/chrome/installer/setup/aegis_launch_policy.h', only('macos', 'windows')],
    ['linux shell coverage', 'fix: shell cov', 'scripts/ci/run-shell-coverage.sh', only('linux')],
    ['linux ripgrep', 'fix: ripgrep', 'scripts/ci/install-ripgrep.sh', only('linux')],
    ['linux kcov fixture', 'fix: kcov', 'scripts/ci/platform-tests/kcov-fixture.sh', only('linux')],
  ];
  for (const [name, subject, path, expected] of cases) {
    assert.deepEqual(route(source, {subject, paths: [path]}, {schema: 3}), expected, name);
  }
});
