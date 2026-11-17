import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync, chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';
import YAML from 'yaml';
import {readFileSync} from 'node:fs';

const script = resolve('scripts/ci/platform-impact.mjs');
test('platform routing binds real merge parents and rejects hidden product changes', () => {
  const root = mkdtempSync(join(tmpdir(), 'platform-impact-'));
  const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  const doc = 'docs/plans/access-build-portability/acceptance.md';
  const save = (path, text) => { mkdirSync(join(root, path, '..'), {recursive: true}); writeFileSync(join(root, path), text); };
  try {
    git('init', '-b', 'develop'); git('config', 'user.name', 'Routing Test'); git('config', 'user.email', 'routing@example.invalid');
    save(doc, 'initial'); git('add', '.'); git('commit', '-m', 'base');
    const earlierBase = git('rev-parse', 'HEAD');
    save('base-marker.txt', 'advanced base'); git('add', '.'); git('commit', '-m', 'base advanced');
    const base = git('rev-parse', 'HEAD');
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
    run(() => {save(doc, 'updated'); save('apps/ios/Feature.swift', 'invalid');}, true);
    const iosOnly = run(() => save('apps/ios/Feature.swift', 'feature'), true);
    assert.equal(iosOnly.macos, false);
    run(() => save('unknown.file', 'unknown'), true);
    run(() => rmSync(join(root, doc)), true);
    run(() => git('mv', doc, 'docs/renamed.md'), true);
    run(() => chmodSync(join(root, doc), 0o755), true);
    run(() => save('scripts/ci/platform-impact.mjs', 'console.log("ios=false")'), true);
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
