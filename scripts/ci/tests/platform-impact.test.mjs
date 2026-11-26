import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {copyFileSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync, rmSync, chmodSync, symlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';
import YAML from 'yaml';
import {selectPlatformChecks} from '../check-platform-gate.mjs';

const script = resolve('scripts/ci/platform-impact.mjs');

test('Android coverage uses the complete tested diff and the actual PR parents', () => {
  const root = mkdtempSync(join(tmpdir(), 'coverage-impact-'));
  const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}).trim();
  const save = (path, text) => {
    mkdirSync(join(root, path, '..'), {recursive: true});
    writeFileSync(join(root, path), text);
  };
  const commit = (message) => {
    git('add', '-A');
    git('commit', '-m', message);
    return git('rev-parse', 'HEAD');
  };
  const outputFile = join(root, '.git', 'coverage-output');
  const routeSource = readFileSync('scripts/ci/coverage-impact.sh', 'utf8');
  const workflow = YAML.parse(readFileSync('.github/workflows/android-java-coverage.yml', 'utf8'));
  const runShell = (run, env) => spawnSync('bash', ['-e', '-o', 'pipefail', '-c', run], {
    cwd: root,
    encoding: 'utf8',
    env: {...process.env, RUNNER_TEMP: join(root, '.git'), GITHUB_OUTPUT: outputFile, ...env},
  });
  const route = (event) => {
    writeFileSync(outputFile, '');
    const step = workflow.jobs.impact.steps.find(item => item.id === 'route');
    const result = runShell(step.run, event);
    return {result, output: readFileSync(outputFile, 'utf8')};
  };
  try {
    git('init', '-b', 'develop');
    git('config', 'user.name', 'Coverage Test');
    git('config', 'user.email', 'coverage@example.invalid');
    const fdReader = 'apps/browser/scripts/android-ui-driver/assets/read-profile-fds.sh';
    save(fdReader, readFileSync(fdReader, 'utf8'));
    save('apps/ios/Feature.swift', 'old');
    const eventBase = commit('initial');
    save('apps/ios/Feature.swift', 'new');
    save('scripts/ci/coverage-impact.sh', routeSource);
    const actualBase = commit('iOS change already on develop');

    git('checkout', '-b', 'candidate', eventBase);
    save('apps/ios/Feature.swift', 'new');
    save('scripts/ci/ios-release-preflight.mjs', '// release only');
    save('apps/browser/scripts/windows-installer-fixture.py', '# Windows only');
    save('apps/browser/scripts/android-ui-driver/README.md', 'documentation only');
    save('apps/browser/scripts/write-build-identity.mjs', '// stubbed by the package guard');
    for (let index = 0; index < 305; index += 1) save(`aaa/docs/file-${index}.md`, 'unrelated');
    const head = commit('same iOS change plus docs and release preflight');
    git('checkout', 'develop');
    git('merge', '--no-ff', 'candidate', '-m', 'first tested merge');
    const tested = git('rev-parse', 'HEAD');
    const event = {GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: tested, EVENT_PR_BASE: eventBase, EVENT_PR_HEAD: head};
    save('scripts/ci/coverage-impact.sh', 'exit 42');
    const first = route(event);
    assert.equal(first.result.status, 0, first.result.stderr);
    assert.equal(first.output, `run=false\npr_base=${actualBase}\npr_head=${head}\n`);
    assert.notEqual(route({...event, EVENT_PR_HEAD: eventBase}).result.status, 0);
    assert.notEqual(route({...event, GITHUB_SHA: head}).result.status, 0);

    const exerciseSingleInput = (file, selected) => {
      git('reset', '--hard', actualBase);
      git('checkout', '-B', 'candidate', head);
      save(file, 'new platform input after the other 305 paths');
      const changedHead = commit('add single platform input');
      git('checkout', 'develop');
      git('merge', '--no-ff', 'candidate', '-m', 'tested single-platform merge');
      const changedTested = git('rev-parse', 'HEAD');
      const pr = route({...event, GITHUB_SHA: changedTested, EVENT_PR_HEAD: changedHead});
      assert.equal(pr.result.status, 0, pr.result.stderr);
      assert.equal(pr.output, `run=${selected}\npr_base=${actualBase}\npr_head=${changedHead}\n`);
      const push = route({GITHUB_EVENT_NAME: 'push', GITHUB_SHA: changedTested, EVENT_PUSH_BEFORE: actualBase});
      assert.equal(push.result.status, 0, push.result.stderr);
      assert.equal(push.output, `run=${selected}\npr_base=\npr_head=\n`);
      return {changedHead, changedTested};
    };
    exerciseSingleInput('apps/ios/Later.swift', false);
    exerciseSingleInput('apps/browser/CHROMIUM_VERSION', true);
    exerciseSingleInput(fdReader, true);
    const {changedHead, changedTested} = exerciseSingleInput(
      'apps/browser/scripts/android-ui-driver/Driver.java', true);
    const manual = route({GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_SHA: changedTested});
    assert.equal(manual.result.status, 0, manual.result.stderr);
    assert.equal(manual.output, 'run=true\npr_base=\npr_head=\n');

    const evidence = join(root, '.git', 'android-report');
    const verify = workflow.jobs['android-java-coverage'].steps.find(step =>
      step.name === 'Bind report to exact SHA and scope');
    save('.git/android-report/coverage/summary.json', JSON.stringify({
      testedSha: changedTested, repositoryDirtyAtBuild: false, selfTestCases: 6,
      browserTested: false, passed: true, line: {covered: 1, missed: 1, total: 2},
    }));
    const verifyParents = (base, head) => {
      save('.git/android-report/ci-context.json', JSON.stringify({
        eventName: 'pull_request', testedSha: changedTested, pullRequestBaseSha: base, pullRequestHeadSha: head,
      }));
      return runShell(verify.run, {EVIDENCE_DIR: evidence, AEGIS_TESTED_SHA: changedTested, GITHUB_EVENT_NAME: 'pull_request'});
    };
    const correct = verifyParents(actualBase, changedHead);
    assert.equal(correct.status, 0, correct.stderr);
    assert.notEqual(verifyParents(changedHead, actualBase).status, 0, 'swapped PR parents must fail');

    git('checkout', '--detach', eventBase);
    git('merge', '--no-ff', 'candidate', '-m', 'first rollout before baseline has routing');
    const rolloutEvent = {...event, GITHUB_SHA: git('rev-parse', 'HEAD'), EVENT_PR_HEAD: changedHead};
    const rollout = route(rolloutEvent);
    assert.equal(rollout.result.status, 0, rollout.result.stderr);
    assert.equal(rollout.output, `run=true\npr_base=${eventBase}\npr_head=${changedHead}\n`);

    git('checkout', '--detach', eventBase);
    save('scripts/ci/coverage-impact.sh', 'exit 0');
    commit('trusted router with no decision');
    git('merge', '--no-ff', 'candidate', '-m', 'routing must fail rather than skip');
    const silent = route({...rolloutEvent, GITHUB_SHA: git('rev-parse', 'HEAD')});
    assert.notEqual(silent.result.status, 0);
    assert.equal(silent.output, '');

    git('checkout', '-b', 'candidate-router', actualBase);
    save('scripts/ci/coverage-impact.sh', 'echo run=false >> "$GITHUB_OUTPUT"\n');
    save('apps/browser/scripts/android-ui-driver/Driver.java', 'changed Android driver');
    const changedRouterHead = commit('change the Android driver and replace the router');
    git('checkout', '--detach', actualBase);
    git('merge', '--no-ff', 'candidate-router', '-m', 'tested merge with a replaced router');
    const trusted = route({...event, GITHUB_SHA: git('rev-parse', 'HEAD'), EVENT_PR_HEAD: changedRouterHead});
    assert.equal(trusted.result.status, 0, trusted.result.stderr);
    assert.equal(trusted.output, `run=true\npr_base=${actualBase}\npr_head=${changedRouterHead}\n`);
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});

test('Windows fixture verifies Gitiles headers against the selected Chromium pin', () => {
  const result = spawnSync('python3', ['-B', '-c', `
import base64
import hashlib
import io
import runpy
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import patch

fixture = runpy.run_path("apps/browser/scripts/windows-installer-fixture.py")
pinned_headers = fixture["pinned_headers"]
download = fixture["download"]
header = fixture["UTIL_CONSTANTS"]
gitiles_digests = {
    "43a195105613ac83c21d3f14de279f4a045c7da0":
        "f40b2e5872bb326970857f23949b411964a902fa76f9feabe07b40bfaec2c749",
    "b8c2be851f62f6a394ec57955d7f31335d7cb6d4":
        "a0afe0f69ad9165af8d2f21680568df9eac95294ef8d493e1a6c4b07f121a859",
}
case = TestCase()
for pin, expected in gitiles_digests.items():
    case.assertEqual(pinned_headers(pin)[header], expected, pin)
with case.assertRaisesRegex(RuntimeError, "Update pinned fixture inputs"):
    pinned_headers("f" * 40)

contents = {pin: f"fixture header for {pin}".encode("ascii") for pin in gitiles_digests}
fixture_digests = {pin: hashlib.sha256(data).hexdigest() for pin, data in contents.items()}
with TemporaryDirectory() as root, patch.dict(fixture["UTIL_CONSTANTS_SHA256"], fixture_digests, clear=True):
    for pin, source in contents.items():
        expected = pinned_headers(pin)[header]
        assert expected == fixture_digests[pin]
        url = f"https://fixture.invalid/{pin}/{header}?format=TEXT"
        destination = Path(root) / pin / "util_constants.h"
        with patch("urllib.request.urlopen", return_value=io.BytesIO(base64.b64encode(source))):
            assert download(url, destination, expected, gitiles_text=True) == expected
        assert destination.read_bytes() == source
        other = next(data for other_pin, data in contents.items() if other_pin != pin)
        rejected = destination.with_name("rejected.h")
        with patch("urllib.request.urlopen", return_value=io.BytesIO(base64.b64encode(other))):
            with case.assertRaisesRegex(RuntimeError, "Pinned download mismatch"):
                download(url, rejected, expected, gitiles_text=True)
        assert not rejected.exists()
    import urllib.error
    pin = next(iter(contents))
    expected = pinned_headers(pin)[header]
    url = f"https://fixture.invalid/{pin}/{header}?format=TEXT"
    unavailable = urllib.error.HTTPError(url, 503, "Service Unavailable", {}, None)
    with patch("time.sleep") as sleep, patch("urllib.request.urlopen", side_effect=[unavailable, io.BytesIO(base64.b64encode(contents[pin]))]):
        assert download(url, Path(root) / "retried.h", expected, gitiles_text=True) == expected
    assert sleep.call_count == 1
    missing = urllib.error.HTTPError(url, 404, "Not Found", {}, None)
    with patch("time.sleep") as sleep, patch("urllib.request.urlopen", side_effect=missing):
        with case.assertRaises(urllib.error.HTTPError):
            download(url, Path(root) / "missing.h", expected, gitiles_text=True)
    assert sleep.call_count == 0
    with patch("time.sleep") as sleep, patch("urllib.request.urlopen", side_effect=unavailable):
        with case.assertRaises(urllib.error.HTTPError):
            download(url, Path(root) / "exhausted.h", expected, gitiles_text=True)
    assert sleep.call_count == len(fixture["RETRY_DELAYS"])
    assert not (Path(root) / "exhausted.h").exists()
`], {encoding: 'utf8'});
  assert.equal(result.status, 0, result.error?.message ?? result.stderr);
});

const routeDefaultSource = readFileSync('scripts/ci/fill-platform-route-defaults.mjs', 'utf8');
const assertTrustedRouteDefaults = run => {
  assert.match(run, /git show "\$ROUTE_BASE_SHA:scripts\/ci\/platform-impact\.mjs"/u);
  assert.match(run, /git show "\$ROUTE_BASE_SHA:scripts\/ci\/fill-platform-route-defaults\.mjs" > "\$RUNNER_TEMP\/fill-platform-route-defaults\.mjs"/u);
  assert.match(run, /node "\$RUNNER_TEMP\/fill-platform-route-defaults\.mjs"/u);
  assert.doesNotMatch(run, /node scripts\/ci\/fill-platform-route-defaults\.mjs/u);
  const fallback = run.match(/<<'EOF'\n([\s\S]*?)\nEOF/u);
  assert.ok(fallback, 'workflow must embed the trusted fallback');
  assert.equal(`${fallback[1]}\n`, routeDefaultSource);
};

test('platform routing binds real merge parents and rejects hidden product changes', () => {
  const root = mkdtempSync(join(tmpdir(), 'platform-impact-'));
  const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  const doc = 'docs/plans/access-build-portability/acceptance.md';
  const iosDocs = ['en', 'zh-CN', 'zh-TW'].map(language => `docs/ios-webkit-protection.${language}.md`);
  const macDocs = ['toolbar-bubble', 'bubble-session'].map(topic => `docs/plans/macos-access-${topic}-NOTES.md`);
  const executableDocs = [
    'docs/plans/access-service-v1.0/spec.zh-CN.md',
    'docs/platform-features.zh-CN.md',
    'docs/audit/evidence/macos-access-product-phase1/README.md',
    'docs/audit/evidence/ios-access-product-phase1/correlation.md',
    'docs/plans/access-service-v1.0/interaction-example.html',
    'apps/browser/scripts/testdata/translation-quality/long-v1.json',
    'docs/unregistered-explanation.md',
  ];
  const save = (path, text) => { mkdirSync(join(root, path, '..'), {recursive: true}); writeFileSync(join(root, path), text); };
  try {
    git('init', '-b', 'develop'); git('config', 'user.name', 'Routing Test'); git('config', 'user.email', 'routing@example.invalid');
    for (const path of [doc, ...iosDocs, ...macDocs, ...executableDocs]) save(path, 'initial');
    git('add', '.'); git('commit', '-m', 'base');
    const earlierBase = git('rev-parse', 'HEAD');
    save('base-marker.txt', 'advanced base'); git('add', '.'); git('commit', '-m', 'base advanced');
    let base = git('rev-parse', 'HEAD');
    const closed = {docs: false, ios: false, android: false, macos: false, windows: false, linux: false};
    const documented = {...closed, docs: true, integrate: false, deep: false};
    const strictClosed = {...closed, macos: true, integrate: true, deep: true};
    const run = (mutate, expected, message = 'docs: candidate') => {
      git('checkout', '-B', 'topic', base); mutate(); git('add', '-A'); git('commit', '-m', message);
      const head = git('rev-parse', 'HEAD');
      git('checkout', 'develop'); git('merge', '--no-ff', 'topic', '-m', 'candidate');
      const tested = git('rev-parse', 'HEAD');
      const event = join(root, 'event.json');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: base}, head: {sha: head}}}));
      const env = {...process.env, CI_LIGHTWEIGHT_ADMITTED: 'true', GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: tested, GITHUB_EVENT_PATH: event, GITHUB_OUTPUT: ''};
      const result = spawnSync(process.execPath, [script], {cwd: root, env, encoding: 'utf8'});
      assert.equal(result.status, 0, result.stderr);
      const plan = JSON.parse(result.stdout);
      assert.equal(plan.schemaVersion, 3);
      for (const [key, value] of Object.entries(expected)) assert.equal(plan[key], value, `${key} (${message})`);
      assert.equal(plan.base, base); assert.equal(plan.head, head); assert.equal(plan.tested, tested);
      if (expected.docs === true) {
        const unadmitted = spawnSync(process.execPath, [script], {cwd: root, env: {...env, CI_LIGHTWEIGHT_ADMITTED: 'false'}, encoding: 'utf8'});
        assert.equal(JSON.parse(unadmitted.stdout).docs, false, 'outside the trusted fork rollout retain full quality');
        assert.equal(JSON.parse(unadmitted.stdout).ios, false, 'unadmitted explanations still do not open iOS');
      }
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: earlierBase}, head: {sha: head}}}));
      const stale = spawnSync(process.execPath, [script], {cwd: root, env, encoding: 'utf8'});
      assert.equal(stale.status, 0, stale.stderr);
      assert.equal(JSON.parse(stale.stdout).base, base, 'route against actual merge parent despite lagging metadata');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: base}, head: {sha: base}}}));
      assert.notEqual(spawnSync(process.execPath, [script], {cwd: root, env}).status, 0, 'wrong head must block');
      assert.notEqual(spawnSync(process.execPath, [script], {cwd: root, env: {...env, GITHUB_SHA: base}}).status, 0, 'wrong checkout must block');
      const push = spawnSync(process.execPath, [script], {cwd: root, env: {...env, GITHUB_EVENT_NAME: 'push'}, encoding: 'utf8'});
      const pushed = JSON.parse(push.stdout);
      assert.equal(pushed.ios, true, 'push without a before SHA retains iOS');
      assert.equal(pushed.macos, true, 'push without a before SHA retains macOS');
      assert.equal(pushed.android, false, 'ordinary fallback leaves android on its prior route');
      assert.equal(pushed.windows, false, 'ordinary fallback leaves windows on its prior route');
      assert.equal(pushed.linux, false, 'ordinary fallback leaves linux on its prior route');
      assert.equal(pushed.docs, false);
      assert.equal(pushed.integrate, true);
      assert.equal(pushed.deep, true);
      rmSync(event); git('reset', '--hard', base);
      return plan;
    };
    run(() => save(doc, 'updated'), documented);
    for (const path of [...iosDocs, ...macDocs]) {
      run(() => save(path, 'updated'), documented);
      run(() => rmSync(join(root, path)), strictClosed);
      run(() => chmodSync(join(root, path), 0o755), strictClosed);
      run(() => {rmSync(join(root, path)); symlinkSync('untrusted.md', join(root, path));}, strictClosed);
      run(() => git('mv', path, 'docs/unregistered-renamed.md'), {...closed, macos: true, integrate: true, deep: true});
    }
    run(() => { for (const path of [doc, ...iosDocs, ...macDocs]) save(path, 'updated'); }, documented);
    for (const path of executableDocs) {
      const android = !path.startsWith('docs/') && !path.endsWith('.md');
      const plan = run(() => {save(iosDocs[0], 'updated'); save(path, 'changed input');}, {...closed, macos: true, android, integrate: true, deep: false});
      assert.equal(plan.macos, true, `unregistered or consumed document keeps the macOS contract route: ${path}`);
      assert.equal(plan.ios, false, `unregistered document must not open iOS archive: ${path}`);
    }
    run(() => {save(iosDocs[0], 'updated'); save('scripts/ci/platform-impact.mjs', 'console.log("docs=true")');}, {docs: false, ios: true, android: true, macos: true, windows: true, linux: true, integrate: true, deep: true});
    run(() => {save(iosDocs[0], 'updated'); save('docs/ios-webkit-protection.new.md', 'new explanation');}, {...closed, macos: true, integrate: true, deep: false});
    run(() => {save(macDocs[0], 'updated'); save('docs/plans/macos-access-phase1-evidence-NOTES.md', 'unreviewed neighbor');}, {...closed, macos: true, integrate: true, deep: false});
    run(() => git('mv', '-f', iosDocs[0], iosDocs[1]), strictClosed);
    run(() => {save(doc, 'updated'); save('apps/ios/Feature.swift', 'invalid');}, {...closed, ios: true, integrate: true, deep: true});
    const iosOnly = run(() => save('apps/ios/Feature.swift', 'feature'), {...closed, ios: true, integrate: true, deep: true});
    assert.equal(iosOnly.macos, false);
    run(() => save('unknown.file', 'unknown'), {...closed, macos: true, android: true, integrate: true, deep: false});
    run(() => save('apps/browser/unregistered/build-input.gni', 'unknown'), {...closed, macos: true, android: true, integrate: true, deep: false});
    run(() => save('apps/browser/unregistered/notes.md', 'unknown'), {...closed, macos: true, integrate: true, deep: false});
    run(() => rmSync(join(root, doc)), strictClosed);
    run(() => git('mv', doc, 'docs/renamed.md'), {...closed, macos: true, integrate: true, deep: true});
    run(() => chmodSync(join(root, doc), 0o755), strictClosed);
    run(() => save('scripts/ci/platform-impact.mjs', 'console.log("ios=false")'), {docs: false, ios: true, android: true, macos: true, windows: true, linux: true, integrate: true, deep: true});
    git('rm', iosDocs[0]); git('commit', '-m', 'remove explanation from base');
    base = git('rev-parse', 'HEAD');
    run(() => save(iosDocs[0], 'new registered path'), {...closed, macos: true, integrate: true, deep: false});
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('paths select platforms and commit types select stage depth', () => {
  const root = mkdtempSync(join(tmpdir(), 'platform-route-'));
  const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  const save = (path, text) => { mkdirSync(join(root, path, '..'), {recursive: true}); writeFileSync(join(root, path), text); };
  const planFor = env => {
    const result = spawnSync(process.execPath, [script], {cwd: root, env: {...process.env, CI_LIGHTWEIGHT_ADMITTED: 'true', GITHUB_OUTPUT: '', ...env}, encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  try {
    git('init', '-b', 'develop'); git('config', 'user.name', 'Routing Test'); git('config', 'user.email', 'routing@example.invalid');
    const commonScript = 'apps/browser/scripts/common.sh';
    const iosArchiveTests = ['scripts/release/test_verify_ios_archive.py', 'scripts/release/test_ios_embedded_core.py',
      'scripts/release/test_ios_archive_seal.py',
      'scripts/ci/tests/ios-archive-cancel-isolation.test.mjs', 'scripts/ci/tests/ios-archive-supervisor-fixture.py',
      'scripts/ci/tests/ios-embedded-core-prepare.test.mjs'];
    const iosPrepareWorker = 'scripts/ci/run-ios-embedded-core-prepare.sh';
    const iosCliTest = 'fastlane/tests/cli_test.rb';
    const aabCertificate = 'scripts/release/VerifiedAabCertificate.java';
    const realWindowsPatch = 'apps/browser/patches/0500-align-product-display-name-and-policy-identity.patch';
    const runScript = 'apps/browser/scripts/run.sh';
    const runTests = 'apps/browser/scripts/run_test.sh';
    const trackedInputs = [realWindowsPatch, runScript, runTests,
      'apps/browser/CHROMIUM_VERSION', 'apps/browser/scripts/ci/candidate.py',
      'apps/browser/overlay/chrome/browser/ui/webui/help/aegis_github_update.h',
      'apps/ios/scripts/run-simulator-tests.sh', 'scripts/release/cli.rb', 'scripts/release/verify-ios-dsyms.py'];
    for (const file of trackedInputs) save(file, readFileSync(resolve(file), 'utf8'));
    save('README.md', 'base');
    save('docs/ios-webkit-protection.en.md', 'initial');
    const defaultsPath = 'scripts/ci/fill-platform-route-defaults.mjs';
    for (const path of [commonScript, ...iosArchiveTests, iosCliTest, aabCertificate, defaultsPath]) save(path, 'initial');
    git('add', '.'); git('commit', '-m', 'base');
    const before = git('rev-parse', 'HEAD');
    const pr = (mutate, message) => {
      git('checkout', '-B', 'topic', before); mutate(); git('add', '-A'); git('commit', '-m', message);
      const head = git('rev-parse', 'HEAD');
      git('checkout', 'develop'); git('merge', '--no-ff', 'topic', '-m', 'candidate');
      const tested = git('rev-parse', 'HEAD');
      const event = join(root, 'event.json');
      writeFileSync(event, JSON.stringify({pull_request: {draft: false, base: {sha: before}, head: {sha: head}}}));
      const plan = planFor({GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: tested, GITHUB_EVENT_PATH: event});
      rmSync(event); git('reset', '--hard', before);
      return plan;
    };
    const feature = pr(() => save('apps/ios/Feature.swift', 'feature'), 'feat(ios): add feature');
    assert.equal(feature.ios, true); assert.equal(feature.macos, false); assert.equal(feature.integrate, true); assert.equal(feature.deep, true);
    const tested = pr(() => save('apps/ios/Tests/AegisTests/FeatureTests.swift', 'test'), 'test(ios): cover feature');
    assert.equal(tested.integrate, true); assert.equal(tested.deep, false);
    const chore = pr(() => save('apps/ios/Notes.swift', 'chore'), 'chore(ios): tidy');
    assert.equal(chore.ios, true); assert.equal(chore.integrate, true); assert.equal(chore.deep, true);
    const android = pr(() => save('apps/browser/patches-android/change.patch', 'android'), 'fix: repair android');
    assert.equal(android.android, true); assert.equal(android.ios, false); assert.equal(android.macos, false); assert.equal(android.deep, true);
    const route = ({ios, android, macos, windows, linux, integrate, deep}) => ({ios, android, macos, windows, linux, integrate, deep});
    const iosRoute = {ios: true, android: false, macos: false, windows: false, linux: false, integrate: true, deep: true};
    const androidRoute = {...iosRoute, ios: false, android: true};
    const sharedSetup = pr(() => save(commonScript, 'updated'), 'fix: repair browser setup');
    assert.deepEqual(route(sharedSetup), {...androidRoute, macos: true, linux: true});
    const sharedSetupWithIos = pr(() => {
      save(commonScript, 'updated');
      save(iosPrepareWorker, 'updated');
      save('unknown.file', 'updated');
    }, 'fix: repair browser setup and iOS');
    assert.deepEqual(route(sharedSetupWithIos), {...iosRoute, android: true, macos: true, linux: true});
    for (const path of ['scripts/ci/ios-archive-go.py', 'scripts/ci/ios-archive-supervisor.py', 'scripts/ci/run-ios-unsigned-archive.sh',
      iosPrepareWorker, '.github/workflows/ios-release-validation.yml']) {
      assert.deepEqual(route(pr(() => save(path, 'updated'), 'fix: protect archive logs')), iosRoute, path);
    }
    for (const path of iosArchiveTests) {
      const isWorkflow = path === '.github/workflows/ios-release-validation.yml';
      assert.deepEqual(route(pr(() => save(path, 'updated'), 'test: cover archive input')), {...iosRoute, deep: isWorkflow}, path);
    }
    const cliTestOnly = pr(() => save(iosCliTest, 'updated'), 'test: cover iOS release CLI');
    assert.deepEqual(route(cliTestOnly), {...iosRoute, deep: false});
    for (const file of [
      'build-ios-access-core.sh', 'development_key_access.py', 'development_signing.py',
      'ios_core_build.py', 'ios_embedded_core.py', 'ios_linked_core.py', 'prepare-ios-access-core.sh', 'record-ios-access-core-digests.sh',
      'safari_manifest.py', 'test_development_key_access.py', 'test_development_signing.py',
      'test_ios_linked_bundle.py', 'test_ios_profile_trust.py', 'verify-ios-archive.py', 'verify-signed-ios.py',
    ]) {
      assert.deepEqual(route(pr(() => save(`scripts/release/${file}`, 'ios'), 'fix: repair archive')),
        {...iosRoute, deep: true}, file);
    }
    for (const path of [
      'scripts/release/android-delivery.py', 'scripts/release/android_product_delivery.py',
      'scripts/release/test_android_release_matrix.py', 'scripts/release/runner.rb', 'scripts/release/verify-aab.py',
      aabCertificate, 'scripts/ci/run-android-release-tests.py', 'scripts/ci/tests/android-release.test.mjs',
      'scripts/ci/release-preflight.mjs', '.github/android-public-release-tag-ruleset.json',
    ]) {
      assert.deepEqual(route(pr(() => save(path, 'android'), 'fix: repair android release')), androidRoute, path);
    }
    const releaseContracts = pr(() => {
      for (const path of [
        'scripts/release/ios-delivery-plan.py', 'scripts/release/ios_access_test_gate.py',
        'scripts/release/test_ios_publish.py', 'scripts/release/prepare-ios-package-core.sh',
        'scripts/release/cli.rb', 'scripts/release/test_product_delivery.py',
        'scripts/release/verify-ipa.py', 'scripts/release/product_delivery.py',
        'scripts/release/test_cloud_signing_poc.py', 'scripts/release/fixtures/safari-icon-xcode.png',
        'scripts/ci/tests/ios-release.test.mjs',
      ]) save(path, 'changed');
    }, 'test(android): cover release helpers');
    assert.deepEqual(route(releaseContracts), {...iosRoute, deep: false});
    const allPlatforms = {...iosRoute, android: true, windows: true, linux: true, macos: true};
    for (const [type, integrate, deep] of [['ci', true, false], ['test', true, false], ['fix', true, true]]) {
      const defaults = pr(() => save(defaultsPath, '// edit'), `${type}: update routing defaults`);
      assert.deepEqual(route(defaults), {...allPlatforms, integrate, deep});
      assert.equal(defaults.strict, false);
      assert.deepEqual(selectPlatformChecks(defaults, defaults.tested, defaults.rulesSha),
        ['android', 'ios', 'linux', 'macos', 'windows']);
    }
    const unknownRelease = pr(() => save('scripts/release/prepare-ios-access-core-extra.sh', 'unknown'), 'fix: repair helper');
    assert.deepEqual(route(unknownRelease), {...iosRoute, ios: false, macos: true, android: true});
    const unknownFastlane = pr(() => save('fastlane/tests/support/helper_test.rb', 'unknown'), 'test: cover helper');
    assert.deepEqual(route(unknownFastlane), {...iosRoute, ios: false, macos: true, android: true, deep: false});
    const mixedRelease = pr(() => {
      save('scripts/release/verify-ios-archive.py', 'ios');
      save('scripts/release/android-delivery.py', 'android');
    }, 'fix: repair both release paths');
    assert.deepEqual(route(mixedRelease), {...iosRoute, android: true});
    const windows = pr(() => save('scripts/ci/platform-tests/windows-acceptance.ps1', 'win'), 'perf: speed windows');
    assert.equal(windows.windows, true); assert.equal(windows.macos, false); assert.equal(windows.deep, true);
    const uninstall = pr(() => {
      save('apps/browser/overlay/chrome/browser/ui/views/uninstall_view.cc', 'changed Windows UI');
      save('apps/browser/patches/0532-align-windows-uninstall-ui.patch', 'Windows patch');
      save('apps/browser/patches/series', 'updated series');
      save('apps/browser/scripts/windows-uninstall-branding_test.py', 'Windows fixture');
    }, 'chore: refresh uninstall');
    assert.equal(uninstall.windows, true);
    assert.equal(uninstall.ios, false);
    assert.equal(uninstall.integrate, true);
    for (const file of ['apps/browser/ci-pins/android.json', 'apps/browser/args/aegis-android.gn']) {
      assert.equal(pr(() => save(file, 'updated'), 'chore: change Android build input').android, true, file);
    }
    const releaseHelper = pr(() => save('fastlane/lib/ios_status.rb', 'changed'), 'docs: tidy iOS release');
    assert.deepEqual(route(releaseHelper), {...iosRoute, deep: false});
    const sharedIos = pr(() => save('packages/core/src/agent/contracts/v1/agent-contract-v1.vectors.json', '{}'), 'chore: change shared vectors');
    assert.deepEqual(route(sharedIos), {...iosRoute, macos: true, deep: false});
    const sharedTracker = pr(() => save('packages/core/src/tracker/builtin-rules.ts', 'tracker rules'), 'chore: change shared rules');
    assert.deepEqual(route(sharedTracker), {...iosRoute, macos: true});
    for (const file of [
      'scripts/ci/ios-ci-storage.py', 'scripts/release/test_ios_linked_bundle.py',
      'scripts/release/test_ios_profile_trust.py', 'scripts/release/test_development_signing.py',
      'scripts/release/test_development_key_access.py',
      'apps/ios/scripts/firebase_config.py', 'apps/ios/scripts/private_test_node.py',
      'apps/ios/scripts/private_test_subscription.py',
      'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared/core.js',
    ]) assert.equal(pr(() => save(file, 'updated'), 'chore: change archive consumer').deep, true, file);
    for (const file of ['scripts/release/ios-action.py', 'scripts/release/test_ios_action.py',
      'scripts/release/cli.rb', 'scripts/release/verify-ios-dsyms.py',
      'scripts/release/hosted-signing.py', 'scripts/release/test_hosted_signing.py',
      'scripts/release/verify-ipa.py', 'scripts/release/test_verify_ipa.py',
      'scripts/release/test_verify_ios_dsyms.py', 'scripts/release/test_verify_signed_ios.py',
      'apps/ios/scripts/run-simulator-tests.sh', 'scripts/ci/tests/ios-release.test.mjs',
      'scripts/release/fixtures/safari-icon-xcode.png', '.github/ios-public-release-tag-ruleset.json',
      'scripts/release/cloud-archive.py', 'scripts/release/test_cloud_archive.py',
      'scripts/release/artifact-transport.py', 'scripts/release/product_delivery.py',
      'scripts/release/ios-private-alpha.rb', 'scripts/release/private_alpha_inputs.py',
      'scripts/release/test_private_alpha_inputs.py',
      'scripts/release/test_native_signing_session.py']) {
      assert.deepEqual(route(pr(() => save(file, 'updated'), 'fix: repair iOS contract')), {...iosRoute, deep: false});
    }
    for (const file of [
      'apps/browser/overlay/chrome/browser/ui/views/uninstall_view.cc',
      'apps/browser/overlay/chrome/app/theme/gcsa_aegis/win/chromium.ico',
      'apps/browser/CHROMIUM_COMMIT',
      'apps/browser/overlay/chrome/browser/aegis/access/access_local_core_win_unittest.cc',
      'apps/browser/overlay/chrome/browser/aegis/agent/aegis_agent_browsertest.cc',
    ]) {
      const onlyWindowsInput = pr(() => save(file, 'updated'), 'chore: update Windows input');
      assert.equal(onlyWindowsInput.windows, true, file);
      assert.equal(onlyWindowsInput.integrate, true, file);
    }
    const desktopRoute = {...iosRoute, ios: false, windows: true, macos: true};
    assert.deepEqual(route(pr(() => save(realWindowsPatch, 'updated patch'), 'fix: update desktop patch')), desktopRoute);
    const desktopVersion = 'apps/browser/CHROMIUM_VERSION';
    const productVersion = 'apps/browser/overlay/chrome/browser/ui/webui/help/aegis_github_update.h';
    for (const file of [desktopVersion, 'apps/browser/scripts/ci/candidate.py',
      'apps/browser/scripts/ci/candidate_test.py', 'apps/browser/scripts/release-contract.py',
      'apps/browser/scripts/release-contract_test.py', 'apps/browser/release-feature-contract.json']) {
      assert.deepEqual(route(pr(() => save(file, 'update'), 'fix: update shared candidate input')),
        {...desktopRoute, android: true}, file);
    }
    assert.deepEqual(route(pr(() => save(productVersion, 'updated header'), 'fix: update product version')),
      {...desktopRoute, android: true, windows: false});
    for (const file of [runScript, runTests]) {
      assert.deepEqual(route(pr(() => save(file, '# update'), 'fix: update covered script')),
        {...iosRoute, ios: false, linux: true, macos: true}, file);
    }
    const workspaceLock = pr(() => save('pnpm-lock.yaml', 'changed lockfile'), 'fix: refresh lock');
    assert.deepEqual(route(workspaceLock), {...iosRoute, android: true, macos: true, linux: true, deep: false});
    const sharedBot = pr(() => save('scripts/ci/ios-delivery-bot.mjs', 'updated'), 'fix: update bot transport');
    assert.deepEqual(route(sharedBot), {...iosRoute, macos: true, deep: false});
    const ripgrep = pr(() => save('scripts/ci/install-ripgrep.sh', 'new checksum'), 'fix: update ripgrep');
    assert.equal(ripgrep.linux, true);
    const linux = pr(() => save('scripts/ci/platform-tests/kcov-child.sh', 'kcov'), 'refactor: reshape coverage');
    assert.equal(linux.linux, true); assert.equal(linux.macos, false); assert.equal(linux.deep, true);
    const mixedContracts = pr(() => {
      save('scripts/ci/tests/shell-coverage.test.mjs', 'linux');
      save('scripts/release/android-status.py', 'android');
      save('scripts/ci/platform-tests/windows-acceptance.ps1', 'windows');
    }, 'test(ios): exercise portable contracts');
    assert.deepEqual(route(mixedContracts), {...androidRoute, windows: true, linux: true, deep: false});
    const shared = pr(() => save('packages/core/src/core.ts', 'core'), 'build: refresh core');
    assert.equal(shared.macos, true); assert.equal(shared.ios, false); assert.equal(shared.android, false); assert.equal(shared.windows, false);
    git('checkout', '-B', 'topic', before);
    save('apps/ios/Feature.swift', 'one'); git('add', '-A'); git('commit', '-m', 'chore: first');
    save('apps/ios/Feature.swift', 'two'); git('add', '-A'); git('commit', '-m', 'feat: second');
    const head = git('rev-parse', 'HEAD');
    git('checkout', 'develop'); git('merge', '--no-ff', 'topic', '-m', 'candidate');
    const mixedEvent = join(root, 'event.json');
    writeFileSync(mixedEvent, JSON.stringify({pull_request: {base: {sha: before}, head: {sha: head}}}));
    const mixed = planFor({GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: git('rev-parse', 'HEAD'), GITHUB_EVENT_PATH: mixedEvent});
    assert.equal(mixed.deep, true, 'mixed types take the stricter stage');
    assert.deepEqual(mixed.types, ['chore', 'feat']);
    rmSync(mixedEvent); git('reset', '--hard', before);
    const emptyOldest = pr(() => {
      save('apps/ios/Feature.swift', 'initial change');
      git('add', '-A');
      const parent = git('rev-parse', 'HEAD');
      const tree = git('write-tree');
      const emptyCommit = execFileSync('git', ['commit-tree', '--no-gpg-sign', tree, '-p', parent], {
        cwd: root, encoding: 'utf8', input: '',
      }).trim();
      git('update-ref', 'HEAD', emptyCommit, parent);
      assert.equal(git('show', '-s', '--format=[%s]', 'HEAD'), '[]', 'fixture subject is empty');
      save('apps/ios/Feature.swift', 'follow-up');
    }, 'chore: tidy');
    assert.deepEqual(emptyOldest.types, ['chore']);
    assert.equal(emptyOldest.strict, true);
    assert.equal(emptyOldest.reason, 'strict-change');
    assert.deepEqual(route(emptyOldest), iosRoute);
    const loose = pr(() => save('apps/ios/Feature.swift', 'loose'), 'update the feature');
    assert.equal(loose.strict, true); assert.equal(loose.deep, true); assert.equal(loose.ios, true);
    git('checkout', 'develop');
    save('apps/ios/Push.swift', 'push'); git('add', '-A'); git('commit', '-m', 'chore: push ios');
    const pushed = git('rev-parse', 'HEAD');
    const ranged = planFor({GITHUB_EVENT_NAME: 'push', GITHUB_SHA: pushed, ROUTE_PUSH_BEFORE: before});
    assert.equal(ranged.base, before); assert.equal(ranged.ios, true); assert.equal(ranged.macos, false); assert.equal(ranged.deep, true); assert.equal(ranged.docs, false);
    git('reset', '--hard', before);
    save('docs/ios-webkit-protection.en.md', 'updated'); git('add', '-A'); git('commit', '-m', 'docs: explain');
    const docsPush = git('rev-parse', 'HEAD');
    const docsPlan = planFor({GITHUB_EVENT_NAME: 'push', GITHUB_SHA: docsPush, ROUTE_PUSH_BEFORE: before});
    assert.equal(docsPlan.docs, false, 'push does not take the lightweight docs route');
    assert.equal(docsPlan.ios, false); assert.equal(docsPlan.macos, false);
    const legacy = planFor({GITHUB_EVENT_NAME: 'push', GITHUB_SHA: docsPush, ROUTE_PUSH_BEFORE: '0'.repeat(40)});
    assert.equal(legacy.reason, 'full-platform-fallback');
    assert.equal(legacy.ios, true); assert.equal(legacy.macos, true); assert.equal(legacy.android, false);
    const observed = planFor({GITHUB_EVENT_NAME: 'push', GITHUB_SHA: docsPush, ROUTE_PUSH_BEFORE: '0'.repeat(40),
      CI_PLATFORM_OBSERVATION: 'true'});
    assert.deepEqual(route(observed), {ios: true, android: true, macos: true, windows: true,
      linux: true, integrate: true, deep: true});
    const dispatch = planFor({GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_SHA: docsPush});
    assert.equal(dispatch.ios, true); assert.equal(dispatch.macos, true); assert.equal(dispatch.android, false); assert.equal(dispatch.deep, true);
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('missing route keys default without overriding an explicit false', () => {
  const root = mkdtempSync(join(tmpdir(), 'route-defaults-'));
  const fill = resolve('scripts/ci/fill-platform-route-defaults.mjs');
  const output = join(root, 'output');
  const planPath = join(root, 'plan.json');
  try {
    writeFileSync(output, 'ios=true\nandroid=false\nintegrate=false\n');
    writeFileSync(planPath, JSON.stringify({ios: true, android: false, integrate: false}));
    const filled = spawnSync(process.execPath, [fill, planPath], {env: {...process.env, GITHUB_OUTPUT: output, ROUTE_DEFAULT_MISSING_MACOS: 'true'}, encoding: 'utf8'});
    assert.equal(filled.status, 0, filled.stderr);
    const text = readFileSync(output, 'utf8');
    assert.match(text, /^android=false$/m);
    assert.match(text, /^integrate=false$/m);
    assert.match(text, /^macos=true$/m);
    assert.match(text, /^windows=false$/m);
    assert.match(text, /^linux=false$/m);
    assert.match(text, /^deep=true$/m);
    assert.equal(JSON.parse(readFileSync(planPath, 'utf8')).platformReason, 'missing-platform-rule-default');
    const complete = ['docs=false', 'ios=false', 'android=false', 'macos=false', 'windows=false', 'linux=false', 'integrate=false', 'deep=false'].join('\n') + '\n';
    writeFileSync(output, complete);
    writeFileSync(planPath, JSON.stringify({android: false, integrate: false, deep: false}));
    const kept = spawnSync(process.execPath, [fill, planPath], {env: {...process.env, GITHUB_OUTPUT: output, ROUTE_DEFAULT_MISSING_MACOS: 'true', ROUTE_DEFAULT_MISSING_IOS: 'true'}, encoding: 'utf8'});
    assert.equal(kept.status, 0, kept.stderr);
    assert.equal(readFileSync(output, 'utf8'), complete);
    assert.equal(JSON.parse(readFileSync(planPath, 'utf8')).platformReason, undefined);
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('iOS archive waits for contracts and keeps failed archives out of distributable artifacts', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  assert.deepEqual(workflow.on.pull_request.branches, ['main', 'develop']);
  const job = workflow.jobs['ios-archive'];
  assert.deepEqual(job.needs, ['impact', 'contracts']);
  assert.equal(workflow.jobs.contracts.needs, 'impact');
  assert.match(workflow.jobs.impact.if, /inputs.exercise != 'cloud-poc'/u);
  assert.match(workflow.jobs.contracts.if, /needs.impact.outputs.ios == 'true'/u);
  assert.match(workflow.jobs.contracts.if, /needs.impact.outputs.integrate == 'true'/u);
  assert.match(workflow.jobs.contracts.if, /needs.impact.result == 'success'/u);
  assert.match(job.if, /needs.contracts.result == 'success'/u);
  assert.match(job.if, /needs.impact.outputs.deep == 'true'/u);
  assert.match(job.if, /github.event_name == 'workflow_dispatch'/u);
  const uploads = job.steps.filter(step => step.uses?.startsWith('actions/upload-artifact@'));
  const archive = uploads.find(step => step.with.name.startsWith('ios-unsigned-'));
  const diagnostics = uploads.find(step => step.with.name.startsWith('ios-archive-diagnostics-'));
  assert.match(archive.if, /success\(\)/u);
  assert.match(diagnostics.if, /failure\(\)/u);
  assert(!diagnostics.with.path.includes('.xcarchive'));
  assert.match(workflow.concurrency.group, /github.sha/u);
  assertTrustedRouteDefaults(workflow.jobs.impact.steps.find(step => step.id === 'impact').run);
});


test('macOS automatic contracts wait for trusted routing and exclude Draft or manual jobs', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/macos-delivery.yml', 'utf8'));
  const {impact, contracts, admission, package: packaging} = workflow.jobs;
  assert.equal(contracts.needs, 'impact');
  assert.match(contracts.if, /needs.impact.outputs.macos == 'true'/u);
  assert.match(contracts.if, /needs.impact.outputs.integrate == 'true'/u);
  assert.match(contracts.if, /needs.impact.result == 'success'/u);
  for (const job of [impact, contracts]) {
    assert.match(job.if, /toJSON\(github.event.pull_request.draft\) == 'false'/u);
    assert.match(job.if, /github.event_name != 'workflow_dispatch'/u);
  }
  assert(workflow.on.pull_request.types.includes('converted_to_draft'));
  assert.match(workflow.concurrency.group, /github.sha/u);
  assert.equal(workflow.concurrency['cancel-in-progress'], "${{ github.event_name == 'pull_request' }}");
  assert.match(admission.if, /workflow_dispatch/u);
  assert.deepEqual(packaging.needs, ['admission', 'access-tests']);
  const run = impact.steps.find(step => step.id === 'impact').run;
  assertTrustedRouteDefaults(run);
  assert.doesNotMatch(run, /echo 'macos=true'/u);
  assert.equal(impact.steps.find(step => step.id === 'impact').env.ROUTE_DEFAULT_MISSING_MACOS, 'true');
  assert.equal(impact.outputs.integrate, '${{ steps.impact.outputs.integrate }}');
});


test('quality preflight selects Linux docs and preserves full checks on all other routes', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/quality.yml', 'utf8'));
  const {impact, quality, 'quality-summary': summary} = workflow.jobs;
  assert.equal(impact['runs-on'], 'ubuntu-24.04');
  assert.equal(quality.needs, 'impact');
  assert.match(quality['runs-on'], /needs.impact.outputs.docs == 'true' && 'ubuntu-24.04'/u);
  assert.equal(summary['runs-on'], 'ubuntu-24.04');
  const admission = impact.steps.find(step => step.id === 'impact').env.CI_LIGHTWEIGHT_ADMITTED;
  for (const requirement of ["base.ref == 'develop'", 'head.repo.full_name == github.repository', 'github.repository == vars.AEGIS_SELF_HOSTED_TEST_REPOSITORY']) assert(admission.includes(requirement));
  const heavy = quality.steps.find(step => step.name === 'Run full quality gate');
  const docs = quality.steps.find(step => step.name === 'Run documentation quality gate');
  assert.equal(heavy.if, "${{ needs.impact.outputs.docs != 'true' }}");
  assert.equal(docs.if, "${{ needs.impact.outputs.docs == 'true' }}");
  assert.match(docs.run, /node scripts\/check-repo-contracts.mjs/u);
  assert.match(workflow.concurrency.group, /github.ref, github.sha/u);
  const other = workflow.jobs['other-platforms'];
  assert.equal(other['runs-on'], 'ubuntu-24.04');
  assert.deepEqual(other.needs, ['impact', 'quality']);
  assert.match(other.if, /needs.quality.result == 'success'/u);
  assert.equal(other['continue-on-error'], true);
  assert.match(other.if, /needs.impact.outputs.integrate == 'true'/u);
  for (const platform of ['android', 'windows', 'linux']) {
    assert.equal(impact.outputs[platform], '${{ steps.impact.outputs.' + platform + ' }}');
    const guard = `needs.impact.outputs.${platform} == 'true'`;
    assert.ok(other.if.includes(guard));
    const suite = other.steps.filter(step => step.run === `corepack pnpm run quality:${platform}`);
    assert.equal(suite.length, 1, platform);
    assert.equal(suite[0].if, "${{ !cancelled() && steps.node.outcome == 'success' && " + guard + ' }}');
  }
  assert(other.steps.find(step => step.id === 'node')?.uses.startsWith('actions/setup-node@'));
  assert.equal(summary.steps.find(step => step.name === 'Require every mandatory job to succeed').env.REQUIRED_RESULTS, '{"quality":"${{ needs.quality.result }}"}');
  assertTrustedRouteDefaults(impact.steps.find(step => step.id === 'impact').run);
});

const archiveScript = 'scripts/ci/run-ios-unsigned-archive.sh';
const delegateArchiveSupervisor = `case "$3" in
  */ios-archive-supervisor.py)
    shift 2
    exec "$ARCHIVE_TEST_PYTHON" -I -B "$ARCHIVE_TEST_SUPERVISOR" "$@"
    ;;
esac
`;

function prepareArchiveFixture(root) {
  const source = join(root, 'Source');
  for (const path of [archiveScript, 'scripts/ci/ios-archive-supervisor.py']) {
    mkdirSync(join(source, path, '..'), {recursive: true});
    copyFileSync(path, join(source, path));
  }
  mkdirSync(join(source, 'apps/ios/Aegis.xcodeproj'), {recursive: true});
  mkdirSync(join(source, 'apps/ios/EmbeddedCore'), {recursive: true});
  writeFileSync(join(source, 'apps/ios/Aegis.xcodeproj/project.pbxproj'), '// fixture\n');
  writeFileSync(join(source, 'apps/ios/EmbeddedCore/embedded-core-lock.json'), '{}\n');
  for (const name of ['tmp', 'DerivedData', 'SourcePackages', 'PackageCache', 'ModuleCache']) {
    mkdirSync(join(root, name), {recursive: true});
  }
  return source;
}

test('archive keeps only trusted compiler status in Actions and the uploaded log before sealing', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  const step = workflow.jobs['ios-archive'].steps.find(item => item.name === 'Compile uncredentialed native archive');
  assert.match(step.run, /run-ios-unsigned-archive\.sh/u);
  assert.equal(step.env.IOS_CI_SOURCE, '${{ steps.storage.outputs.source }}');
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'archive-diagnostics-'));
  const bin = join(root, 'bin');
  const shared = join(root, 'shared checkout');
  const trace = join(root, 'python-calls.txt');
  const launch = join(root, 'compiler-cwd.txt');
  mkdirSync(bin);
  mkdirSync(join(shared, 'scripts/ci'), {recursive: true});
  writeFileSync(join(shared, archiveScript), 'exit 99\n');
  const source = prepareArchiveFixture(root);
  const python = execFileSync('python3', ['-c', 'import sys; print(sys.executable)'], {encoding: 'utf8'}).trim();
  const rejectGitSelectors = `for name in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE \\
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH \\
  GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_NO_REPLACE_OBJECTS GIT_SHALLOW_FILE \\
  GIT_NAMESPACE GIT_ATTR_SOURCE; do
  if [[ "\${!name+x}" ]]; then exit 98; fi
done
`;
  writeFileSync(join(bin, 'python3'), `#!/bin/bash
${rejectGitSelectors}${delegateArchiveSupervisor}printf '%s\\n' "$*" >> "$ARCHIVE_TEST_TRACE"
if [[ "$ARCHIVE_TEST_SOURCE_CHANGE" == 1 && "$2" == */ios_embedded_core.py && "$3" == verify ]]; then
  mv -- "$IOS_CI_SOURCE" "$IOS_CI_ROOT/MovedSource"
fi
`);
  writeFileSync(join(bin, 'xcodebuild'), `#!/bin/bash
${rejectGitSelectors}pwd -P > "$ARCHIVE_TEST_LAUNCH"
printf 'archive-compiler-diagnostic\\n' >&2
exit "$ARCHIVE_TEST_EXIT"
`);
  chmodSync(join(bin, 'python3'), 0o755);
  chmodSync(join(bin, 'xcodebuild'), 0o755);
  const run = overrides => spawnSync('bash', ['-e', '-o', 'pipefail', '-c', step.run], {
    cwd: shared, encoding: 'utf8', timeout: 10000, env: {
      PATH: `${bin}:/usr/bin:/bin`, HOME: root, IOS_CI_ROOT: root, IOS_CI_SOURCE: source,
      GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_ALLOW_PROTOCOL: 'file',
      GIT_DIR: join(shared, '.git'), GIT_WORK_TREE: shared, GIT_COMMON_DIR: join(shared, '.git'),
      GIT_OBJECT_DIRECTORY: join(shared, '.git', 'objects'), GIT_INDEX_FILE: join(shared, '.git', 'index'),
      GIT_IMPLICIT_WORK_TREE: '0', GIT_ALTERNATE_OBJECT_DIRECTORIES: shared, GIT_QUARANTINE_PATH: shared,
      GIT_GRAFT_FILE: join(shared, 'grafts'), GIT_REPLACE_REF_BASE: 'refs/fixture/', GIT_NO_REPLACE_OBJECTS: '1',
      GIT_SHALLOW_FILE: join(shared, 'shallow'), GIT_NAMESPACE: 'fixture', GIT_ATTR_SOURCE: 'wrong-tree',
      ARCHIVE_TEST_PYTHON: python, ARCHIVE_TEST_TRACE: trace, ARCHIVE_TEST_LAUNCH: launch,
      ARCHIVE_TEST_SUPERVISOR: resolve('scripts/ci/tests/ios-archive-supervisor-fixture.py'), ARCHIVE_TEST_LEAF_COMPILER: '1',
      ...overrides,
    },
  });
  try {
    writeFileSync(trace, '');
    const absent = run({IOS_CI_SOURCE: join(root, 'absent')});
    assert.equal(absent.status, 1, absent.stderr);
    assert.match(absent.stderr, /cd:.*absent/u);
    assert.equal(readFileSync(trace, 'utf8'), '');
    const vanished = run({ARCHIVE_TEST_SOURCE_CHANGE: '1', ARCHIVE_TEST_EXIT: '0'});
    assert.equal(vanished.status, 1, vanished.stderr);
    assert.match(vanished.stdout, /pre-compile EmbeddedCore verification exited with status 0/u);
    assert.match(vanished.stdout, /source became unavailable before compilation/u);
    assert.throws(() => readFileSync(launch), {code: 'ENOENT'});
    assert.doesNotMatch(readFileSync(trace, 'utf8'), /verify-ios-archive\.py|ios-ci-storage\.py seal/u);
    renameSync(join(root, 'MovedSource'), source);

    const cases = [[65, null], [0, null], [0, 'open'], [65, 'open'], [0, 'write'], [65, 'write']];
    for (const [compilerExit, logFailure] of cases) {
      const log = join(root, 'xcodebuild.log');
      rmSync(log, {force: true});
      rmSync(launch, {force: true});
      if (logFailure === 'open') mkdirSync(log);
      writeFileSync(trace, '');
      const result = run({ARCHIVE_TEST_SOURCE_CHANGE: '0', ARCHIVE_TEST_EXIT: String(compilerExit),
        ARCHIVE_TEST_LOG_FAILURE: logFailure ?? ''});
      assert.ifError(result.error);
      assert.equal(result.status, compilerExit || (logFailure ? 74 : 0), result.stderr);
      assert.equal(readFileSync(launch, 'utf8').trim(), source);
      const console = result.stdout + result.stderr;
      assert.match(console, /archive diagnostics withheld/u);
      assert(console.includes('compiler exited with status ' + compilerExit));
      assert.doesNotMatch(console, /archive-compiler-diagnostic|synthetic-log-error-value/u);
      if (logFailure) assert.match(result.stderr, /failed to retain xcodebuild\.log/u);
      if (logFailure === 'open') rmSync(log, {recursive: true});
      else {
        const retained = readFileSync(log, 'utf8');
        if (logFailure === 'write') assert.equal(retained, '');
        else {
          assert(retained.includes('compiler exited with status ' + compilerExit));
          assert.doesNotMatch(retained, /archive-compiler-diagnostic/u);
        }
      }
      const calls = readFileSync(trace, 'utf8').trim().split('\n');
      const succeeded = compilerExit === 0 && !logFailure;
      assert.equal(console.includes('unsigned archive verification exited with status 0'), succeeded);
      assert(calls[0].startsWith(`-B ${source}/scripts/release/ios_embedded_core.py verify `));
      assert.equal(calls.some(line => line.startsWith(`${source}/scripts/release/verify-ios-archive.py `)), succeeded);
      assert.equal(calls.some(line => line.startsWith(`-B ${source}/scripts/release/test_ios_linked_bundle.py `)), succeeded);
      assert.equal(calls.some(line => line.startsWith(`-I -B ${source}/scripts/ci/ios-ci-storage.py seal `)), succeeded);
    }
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('archive package resolution preserves runner proxy and Git configuration', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  const step = workflow.jobs['ios-archive'].steps.find(item => item.name === 'Compile uncredentialed native archive');
  assert.match(step.run, /run-ios-unsigned-archive\.sh/u);
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'archive-git-policy-'));
  const bin = join(root, 'bin');
  mkdirSync(bin);
  const source = prepareArchiveFixture(root);
  const trace = join(root, 'git-policy.txt');
  const args = join(root, 'xcode-args.txt');
  const config = join(root, 'gitconfig');
  const python = execFileSync('python3', ['-c', 'import sys; print(sys.executable)'], {encoding: 'utf8'}).trim();
  const gitConfig = '[http]\n proxy = http://127.0.0.1:9\n version = HTTP/2\n[credential]\n helper = retained-fixture-helper\n';
  writeFileSync(config, gitConfig);
  const executables = {
    python3: `#!/bin/bash\n${delegateArchiveSupervisor}exit 0\n`,
    xcodebuild: `#!/bin/bash
printf 'proxy=%s\\n' "$(git config --get-urlmatch http.proxy https://github.com/firebase/firebase-ios-sdk.git)" > "$ARCHIVE_TEST_TRACE"
printf 'http=%s\\n' "$(git config --get http.version)" >> "$ARCHIVE_TEST_TRACE"
printf 'credential=%s\\n' "$(git config --get credential.helper)" >> "$ARCHIVE_TEST_TRACE"
printf 'prompt=%s\\n' "\${GIT_TERMINAL_PROMPT-}" >> "$ARCHIVE_TEST_TRACE"
printf 'https_proxy=%s\\n' "\${https_proxy-}" >> "$ARCHIVE_TEST_TRACE"
printf 'no_proxy=%s\\n' "\${no_proxy-}" >> "$ARCHIVE_TEST_TRACE"
printf 'NO_PROXY=%s\\n' "\${NO_PROXY-}" >> "$ARCHIVE_TEST_TRACE"
printf '%s\\n' "$*" > "$ARCHIVE_TEST_ARGS"
exit 65
`,
  };
  for (const [name, body] of Object.entries(executables)) {
    writeFileSync(join(bin, name), body); chmodSync(join(bin, name), 0o755);
  }
  try {
    const result = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', step.run], {encoding: 'utf8', env: {
      PATH: `${bin}:/usr/bin:/bin`, HOME: root, IOS_CI_ROOT: root,
      IOS_CI_SOURCE: source,
      GIT_CONFIG_GLOBAL: config, GIT_CONFIG_NOSYSTEM: '1', GIT_ALLOW_PROTOCOL: 'file',
      https_proxy: 'http://127.0.0.1:10', HTTPS_PROXY: 'http://127.0.0.1:10',
      no_proxy: 'localhost', NO_PROXY: 'localhost',
      ARCHIVE_TEST_PYTHON: python, ARCHIVE_TEST_TRACE: trace, ARCHIVE_TEST_ARGS: args,
      ARCHIVE_TEST_SUPERVISOR: resolve('scripts/ci/tests/ios-archive-supervisor-fixture.py'), ARCHIVE_TEST_LEAF_COMPILER: '1',
    }});
    assert.equal(result.status, 65, result.stderr);
    const policy = readFileSync(trace, 'utf8');
    assert.match(policy, /^proxy=http:\/\/127\.0\.0\.1:9$/mu);
    assert.match(policy, /^http=HTTP\/2$/mu);
    assert.match(policy, /^credential=retained-fixture-helper$/mu);
    assert.match(policy, /^prompt=0$/mu);
    assert.match(policy, /^https_proxy=http:\/\/127\.0\.0\.1:10$/mu);
    assert.match(policy, /^no_proxy=localhost$/mu);
    assert.match(policy, /^NO_PROXY=localhost$/mu);
    assert.match(readFileSync(args, 'utf8'), /-scmProvider system/u);
    assert.equal(readFileSync(config, 'utf8'), gitConfig);
  } finally { rmSync(root, {recursive: true, force: true}); }
});
