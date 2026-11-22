import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync, chmodSync, symlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';
import YAML from 'yaml';
import {readFileSync} from 'node:fs';

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
`], {encoding: 'utf8'});
  assert.equal(result.status, 0, result.error?.message ?? result.stderr);
});

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
    const run = (mutate, expected) => {
      git('checkout', '-B', 'topic', base); mutate(); git('add', '-A'); git('commit', '-m', 'docs: candidate');
      const head = git('rev-parse', 'HEAD');
      git('checkout', 'develop'); git('merge', '--no-ff', 'topic', '-m', 'candidate');
      const tested = git('rev-parse', 'HEAD');
      const event = join(root, 'event.json');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: base}, head: {sha: head}}}));
      const env = {...process.env, CI_LIGHTWEIGHT_ADMITTED: 'true', GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: tested, GITHUB_EVENT_PATH: event, GITHUB_OUTPUT: ''};
      const result = spawnSync(process.execPath, [script], {cwd: root, env, encoding: 'utf8'});
      assert.equal(result.status, 0, result.stderr);
      const plan = JSON.parse(result.stdout);
      assert.equal(plan.ios, expected); assert.equal(plan.docs, !expected); assert.equal(typeof plan.macos, 'boolean'); assert.equal(plan.base, base); assert.equal(plan.head, head); assert.equal(plan.tested, tested);
      if (!expected) assert.equal(plan.macos, false, 'approved explanations must allocate neither native platform');
      const unadmitted = spawnSync(process.execPath, [script], {cwd: root, env: {...env, CI_LIGHTWEIGHT_ADMITTED: 'false'}, encoding: 'utf8'});
      assert.equal(JSON.parse(unadmitted.stdout).docs, false, 'outside the trusted fork rollout retain full quality');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: earlierBase}, head: {sha: head}}}));
      const stale = spawnSync(process.execPath, [script], {cwd: root, env, encoding: 'utf8'});
      assert.equal(stale.status, 0, stale.stderr);
      assert.equal(JSON.parse(stale.stdout).base, base, 'route against actual merge parent despite lagging metadata');
      writeFileSync(event, JSON.stringify({pull_request: {base: {sha: base}, head: {sha: base}}}));
      assert.notEqual(spawnSync(process.execPath, [script], {cwd: root, env}).status, 0, 'wrong head must block');
      assert.notEqual(spawnSync(process.execPath, [script], {cwd: root, env: {...env, GITHUB_SHA: base}}).status, 0, 'wrong checkout must block');
      const push = spawnSync(process.execPath, [script], {cwd: root, env: {...env, GITHUB_EVENT_NAME: 'push'}, encoding: 'utf8'});
      assert.equal(JSON.parse(push.stdout).ios, true, 'actual push retains full platform checks');
      assert.equal(JSON.parse(push.stdout).macos, true, 'push must retain macOS contracts');
      rmSync(event); git('reset', '--hard', base);
      return plan;
    };
    run(() => save(doc, 'updated'), false);
    for (const path of [...iosDocs, ...macDocs]) {
      run(() => save(path, 'updated'), false);
      run(() => rmSync(join(root, path)), true);
      run(() => chmodSync(join(root, path), 0o755), true);
      run(() => {rmSync(join(root, path)); symlinkSync('untrusted.md', join(root, path));}, true);
      run(() => git('mv', path, 'docs/unregistered-renamed.md'), true);
    }
    run(() => { for (const path of [doc, ...iosDocs, ...macDocs]) save(path, 'updated'); }, false);
    for (const path of executableDocs) {
      const plan = run(() => {save(iosDocs[0], 'updated'); save(path, 'changed input');}, true);
      assert.equal(plan.macos, true, `unregistered or consumed document must retain full route: ${path}`);
    }
    run(() => {save(iosDocs[0], 'updated'); save('scripts/ci/platform-impact.mjs', 'console.log("docs=true")');}, true);
    run(() => {save(iosDocs[0], 'updated'); save('docs/ios-webkit-protection.new.md', 'new explanation');}, true);
    run(() => {save(macDocs[0], 'updated'); save('docs/plans/macos-access-phase1-evidence-NOTES.md', 'unreviewed neighbor');}, true);
    run(() => git('mv', '-f', iosDocs[0], iosDocs[1]), true);
    run(() => {save(doc, 'updated'); save('apps/ios/Feature.swift', 'invalid');}, true);
    const iosOnly = run(() => save('apps/ios/Feature.swift', 'feature'), true);
    assert.equal(iosOnly.macos, false);
    run(() => save('unknown.file', 'unknown'), true);
    run(() => rmSync(join(root, doc)), true);
    run(() => git('mv', doc, 'docs/renamed.md'), true);
    run(() => chmodSync(join(root, doc), 0o755), true);
    run(() => save('scripts/ci/platform-impact.mjs', 'console.log("ios=false")'), true);
    git('rm', iosDocs[0]); git('commit', '-m', 'remove explanation from base');
    base = git('rev-parse', 'HEAD');
    run(() => save(iosDocs[0], 'new registered path'), true);
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('iOS archive waits for contracts and keeps failed archives out of distributable artifacts', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  assert.deepEqual(workflow.on.pull_request.branches, ['main', 'develop']);
  const job = workflow.jobs['ios-archive'];
  assert.equal(job.needs, 'contracts');
  assert.match(job.if, /needs.contracts.outputs.ios == 'true'/u);
  const uploads = job.steps.filter(step => step.uses?.startsWith('actions/upload-artifact@'));
  const archive = uploads.find(step => step.with.name.startsWith('ios-unsigned-'));
  const diagnostics = uploads.find(step => step.with.name.startsWith('ios-archive-diagnostics-'));
  assert.match(archive.if, /success\(\)/u);
  assert.match(diagnostics.if, /failure\(\)/u);
  assert(!diagnostics.with.path.includes('.xcarchive'));
  assert.match(workflow.concurrency.group, /github.sha/u);
});


test('macOS automatic contracts wait for trusted routing and exclude Draft or manual jobs', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/macos-delivery.yml', 'utf8'));
  const {impact, contracts, admission, package: packaging} = workflow.jobs;
  assert.equal(contracts.needs, 'impact');
  assert.match(contracts.if, /needs.impact.outputs.macos == 'true'/u);
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
  assert.match(run, /git show "\$ROUTE_BASE_SHA:scripts\/ci\/platform-impact.mjs"/u);
  assert.match(run, /grep -q '\^macos='/u);
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
});

test('archive compiler diagnostics reach Actions and retain exit status before sealing', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  const step = workflow.jobs['ios-archive'].steps.find(item => item.name === 'Compile uncredentialed native archive');
  const root = mkdtempSync(join(tmpdir(), 'archive-diagnostics-'));
  const bin = join(root, 'bin');
  const trace = join(root, 'python-calls.txt');
  mkdirSync(bin);
  writeFileSync(join(bin, 'python3'), '#!/bin/bash\nprintf "%s\\n" "$*" >> "$ARCHIVE_TEST_TRACE"\n');
  writeFileSync(join(bin, 'xcodebuild'), '#!/bin/bash\nprintf "archive-compiler-diagnostic\\n" >&2\nexit "$ARCHIVE_TEST_EXIT"\n');
  chmodSync(join(bin, 'python3'), 0o755);
  chmodSync(join(bin, 'xcodebuild'), 0o755);
  try {
    for (const exitCode of [65, 0]) {
      writeFileSync(trace, '');
      const result = spawnSync('bash', ['-e', '-c', step.run], {encoding: 'utf8', env: {
        ...process.env, PATH: `${bin}:${process.env.PATH}`, IOS_CI_ROOT: root,
        ARCHIVE_TEST_TRACE: trace, ARCHIVE_TEST_EXIT: String(exitCode),
      }});
      assert.equal(result.status, exitCode, result.stderr);
      assert.match(result.stdout + result.stderr, /archive-compiler-diagnostic/u);
      assert.match(readFileSync(join(root, 'xcodebuild.log'), 'utf8'), /archive-compiler-diagnostic/u);
      const calls = readFileSync(trace, 'utf8');
      assert.equal(calls.includes('verify-ios-archive.py'), exitCode === 0);
      assert.equal(calls.includes('ios-ci-storage.py seal'), exitCode === 0);
    }
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('archive package resolution inherits the existing GitHub transport policy', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/ios-release-validation.yml', 'utf8'));
  const step = workflow.jobs['ios-archive'].steps.find(item => item.name === 'Compile uncredentialed native archive');
  const root = mkdtempSync(join(tmpdir(), 'archive-git-policy-'));
  const bin = join(root, 'bin');
  mkdirSync(bin);
  const trace = join(root, 'git-policy.txt');
  const args = join(root, 'xcode-args.txt');
  const config = join(root, 'gitconfig');
  writeFileSync(config, '[http]\n proxy = http://127.0.0.1:9\n[credential]\n helper = retained-fixture-helper\n');
  const executables = {
    python3: '#!/bin/bash\nexit 0\n',
    scutil: '#!/bin/bash\nexit 0\n',
    xcodebuild: `#!/bin/bash
printf 'proxy=%s\\n' "$(git config --get-urlmatch http.proxy https://github.com/firebase/firebase-ios-sdk.git)" > "$ARCHIVE_TEST_TRACE"
printf 'http=%s\\n' "$(git config --get http.version)" >> "$ARCHIVE_TEST_TRACE"
printf 'credential=%s\\n' "$(git config --get credential.helper)" >> "$ARCHIVE_TEST_TRACE"
printf 'prompt=%s\\n' "\${GIT_TERMINAL_PROMPT-}" >> "$ARCHIVE_TEST_TRACE"
printf 'bypass=%s\\n' "\${NO_PROXY-}" >> "$ARCHIVE_TEST_TRACE"
printf '%s\\n' "$*" > "$ARCHIVE_TEST_ARGS"
exit 65
`,
  };
  for (const [name, body] of Object.entries(executables)) {
    writeFileSync(join(bin, name), body); chmodSync(join(bin, name), 0o755);
  }
  try {
    const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_CONFIG_')));
    const result = spawnSync('bash', ['-e', '-c', step.run], {encoding: 'utf8', env: {
      ...environment, PATH: `${bin}:${process.env.PATH}`, IOS_CI_ROOT: root,
      GIT_CONFIG_GLOBAL: config, GIT_CONFIG_NOSYSTEM: '1',
      ARCHIVE_TEST_TRACE: trace, ARCHIVE_TEST_ARGS: args,
    }});
    assert.equal(result.status, 65, result.stderr);
    const policy = readFileSync(trace, 'utf8');
    assert.match(policy, /^proxy=$/mu);
    assert.match(policy, /^http=HTTP\/1\.1$/mu);
    assert.match(policy, /^credential=retained-fixture-helper$/mu);
    assert.match(policy, /^prompt=0$/mu);
    assert.match(policy, /bypass=.*github\.com/u);
    assert.match(readFileSync(args, 'utf8'), /-scmProvider system/u);
    assert.equal(readFileSync(config, 'utf8'), '[http]\n proxy = http://127.0.0.1:9\n[credential]\n helper = retained-fixture-helper\n');
  } finally { rmSync(root, {recursive: true, force: true}); }
});
