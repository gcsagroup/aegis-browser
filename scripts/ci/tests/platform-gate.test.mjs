import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {test} from 'node:test';
import YAML from 'yaml';
import {checkPlatformResults, selectPlatformChecks} from '../check-platform-gate.mjs';

const base = 'a'.repeat(40);
const tested = 'b'.repeat(40);
const plan = {
  schemaVersion: 3, tested, rulesSha: base, gate: true, docs: false,
  integrate: true, deep: false, android: true, ios: false, linux: false, macos: false, windows: true,
};
const needs = {
  plan: {result: 'success'}, android: {result: 'success'}, ios: {result: 'skipped'},
  linux: {result: 'skipped'}, macos: {result: 'skipped'}, windows: {result: 'success'},
};

test('platform gate accepts only decisions from the bound policy and tested source', () => {
  assert.deepEqual(selectPlatformChecks(plan, tested, base), ['android', 'windows']);
  assert.throws(() => selectPlatformChecks(plan, base, base), /identity mismatch/u);
  assert.throws(() => selectPlatformChecks({...plan, rulesSha: tested}, tested, base), /identity mismatch/u);
  assert.throws(() => selectPlatformChecks({...plan, schemaVersion: 2}, tested, base), /schema/u);
  assert.throws(() => selectPlatformChecks({...plan, windows: 'true'}, tested, base), /decisions/u);
  assert.throws(() => selectPlatformChecks({...plan, docs: true}, tested, base), /documentation/u);
  assert.throws(() => selectPlatformChecks({...plan, integrate: false}, tested, base), /integration stage/u);
  assert.throws(() => selectPlatformChecks({...plan, android: false, windows: false, deep: true, integrate: false},
    tested, base), /integration stage/u);
  const docs = {...plan, docs: true, integrate: false, android: false, windows: false};
  assert.deepEqual(selectPlatformChecks(docs, tested, base), []);
});

test('selected jobs must succeed and a skipped job is valid only for an unselected platform', () => {
  const required = ['android', 'windows'];
  assert.deepEqual(checkPlatformResults(required, needs),
    {result: 'PASS', required, notApplicable: ['ios', 'linux', 'macos']});
  for (const result of ['failure', 'cancelled', 'timed_out', 'skipped', 'neutral', '']) {
    assert.throws(() => checkPlatformResults(required, {...needs, windows: {result}}), /windows=/u);
  }
  assert.throws(() => checkPlatformResults(required, {...needs, windows: undefined}), /windows=missing/u);
  assert.throws(() => checkPlatformResults(required, {...needs, ios: {result: 'success'}}), /expected skipped/u);
  assert.throws(() => checkPlatformResults(required, {...needs, plan: {result: 'failure'}}), /plan did not succeed/u);
  assert.throws(() => checkPlatformResults(['android', 'android'], needs), /selection/u);
  assert.throws(() => checkPlatformResults(['quality'], needs), /selection/u);
  assert.deepEqual(checkPlatformResults([], {...needs, android: {result: 'skipped'}, windows: {result: 'skipped'}}).required, []);
});

test('the observational check is separate from quality and always summarizes its own five jobs', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/platform-gate.yml', 'utf8'));
  assert.deepEqual(Object.keys(workflow.on).sort(), ['pull_request', 'push']);
  for (const trigger of Object.values(workflow.on)) {
    assert.deepEqual(trigger.branches, ['develop', 'main']);
    assert.ok(!trigger.paths && !trigger['paths-ignore']);
  }
  assert.deepEqual(workflow.on.pull_request.types,
    ['opened', 'reopened', 'synchronize', 'ready_for_review', 'converted_to_draft']);
  assert.deepEqual(workflow.permissions, {contents: 'read'});
  const summary = workflow.jobs['platform-summary'];
  assert.deepEqual(summary.needs, ['plan', 'android', 'ios', 'linux', 'macos', 'windows']);
  assert.match(summary.if, /always\(\).*draft\) == 'false'/u);
  assert.match(summary.name, /'platform-gate'.*'platform-deferred-draft-or-missing-metadata'/u);
  const planning = workflow.jobs.plan.steps.find(step => step.id === 'route').run;
  assert.match(planning, /git show "\$rules:scripts\/ci\/platform-impact\.mjs"/u);
  assert.match(planning, /git show "\$rules:scripts\/ci\/check-platform-gate\.mjs"/u);
  for (const name of ['android', 'ios', 'linux', 'macos', 'windows']) {
    const job = Object.entries(workflow.jobs).find(([id]) => id === name)[1];
    assert.equal(job.needs, 'plan');
    assert.match(job.if, /needs\.plan\.result == 'success'/u);
    assert.ok(job.if.includes("'" + name + "'"));
    assert.ok(!('continue-on-error' in job));
  }
  const android = workflow.jobs.android.steps.find(step => step.name === 'Run Android host, pin and release regressions');
  assert.match(android.run, /python3 -B scripts\/ci\/check-android-platform-inputs\.py/u);
  assert.match(android.run, /node --test scripts\/ci\/tests\/android-\*\.test\.mjs/u);
  assert.ok(workflow.jobs.android.steps.some(step => step.run === 'pnpm install --frozen-lockfile --ignore-scripts'));
  const ios = workflow.jobs.ios.steps.find(step => step.name === 'Run iOS release and WebExtension contracts');
  for (const fixture of [
    'test_verify_ios_archive.py', 'test_verify_signed_ios.py', 'test_verify_ios_dsyms.py',
    'test_development_signing.py', 'test_development_key_access.py',
    'test_verify_ipa.py', 'test_hosted_signing.py', 'test_cloud_archive.py',
    'test_native_signing_session.py', 'test_artifact_transport.py', 'test_product_delivery.py',
    'test_private_alpha_inputs.py',
  ]) assert.ok(ios.run.includes('scripts/release/' + fixture), fixture);
  assert.match(ios.run, /generate-tracker-rules\.mjs --check/u);
  assert.ok(workflow.jobs.ios.steps.some(step => step.run === 'pnpm install --frozen-lockfile --ignore-scripts'));
  for (const [name, job] of [['linux', workflow.jobs.linux], ['windows', workflow.jobs.windows]]) {
    assert.equal(job.uses, './.github/workflows/other-platform-coverage.yml');
    assert.deepEqual(job.with, {lane: name});
  }
  const nativeCoverage = YAML.parse(readFileSync('.github/workflows/other-platform-coverage.yml', 'utf8'));
  const windowsCandidate = nativeCoverage.jobs['powershell-coverage'].steps.find(step =>
    step.name === 'Test candidate orchestration on Windows');
  assert.equal(windowsCandidate.env.PYTHONUTF8, '1');
  assert.match(windowsCandidate.run, /unittest discover -s apps\/browser\/scripts\/ci/u);
  assert.match(windowsCandidate.run, /release-contract_test\.py/u);
  const report = nativeCoverage.jobs['lane-result'];
  assert.deepEqual(report.needs, ['shell-coverage', 'powershell-coverage']);
  assert.match(report.steps[0].run, /test "\$LINUX_RESULT" = success && test "\$WINDOWS_RESULT" = skipped/u);
  assert.match(report.steps[0].run, /test "\$WINDOWS_RESULT" = success && test "\$LINUX_RESULT" = skipped/u);
});

test('the workflow uses the actual merge parent and fails when the trusted base lacks a gate', () => {
  const workflow = YAML.parse(readFileSync('.github/workflows/platform-gate.yml', 'utf8'));
  const command = workflow.jobs.plan.steps.find(step => step.id === 'route').run;
  const root = mkdtempSync(join(tmpdir(), 'aegis-platform-gate-'));
  const git = (...args) => execFileSync('git', ['-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', ...args],
    {cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}).trim();
  const save = (name, value) => {
    const file = join(root, name);
    mkdirSync(dirname(file), {recursive: true});
    writeFileSync(file, value);
  };
  const run = (env) => {
    save('.git/platform-job-outputs', '');
    return spawnSync('bash', ['-e', '-o', 'pipefail', '-c', command], {
      cwd: root,
      encoding: 'utf8',
      env: {
        ...process.env, GITHUB_EVENT_NAME: 'pull_request', GITHUB_SHA: git('rev-parse', 'HEAD'),
        RUNNER_TEMP: join(root, '.git'), GITHUB_OUTPUT: join(root, '.git', 'platform-job-outputs'), ...env,
      },
    });
  };
  try {
    git('init', '-b', 'main');
    git('config', 'user.name', 'CI fixture');
    git('config', 'user.email', 'fixture@example.invalid');
    save('README.md', 'baseline\n');
    git('add', 'README.md');
    git('commit', '-m', 'docs: baseline before platform gate');
    const oldBase = git('rev-parse', 'HEAD');
    for (const name of ['scripts/ci/platform-impact.mjs', 'scripts/ci/check-platform-gate.mjs']) {
      save(name, readFileSync(name, 'utf8'));
    }
    git('add', 'scripts');
    git('commit', '-m', 'ci: register platform CI');
    const trustedBase = git('rev-parse', 'HEAD');
    git('checkout', '-b', 'candidate');
    save('apps/browser/ci-pins/android.json', '{}\n');
    git('add', 'apps');
    git('commit', '-m', 'chore: update Android pin');
    const head = git('rev-parse', 'HEAD');
    git('checkout', 'main');
    git('merge', '--no-ff', 'candidate', '-m', 'test: integrate candidate');
    const tested = git('rev-parse', 'HEAD');

    const event = {PR_HEAD: head, PR_BASE: oldBase, ROUTE_PUSH_BEFORE: '', CI_LIGHTWEIGHT_ADMITTED: 'false'};
    save('.git/pr-event.json', JSON.stringify({pull_request: {base: {sha: oldBase}, head: {sha: head}}}));
    save('scripts/ci/platform-impact.mjs', 'throw new Error("candidate router must not run");');
    const prEnv = {...event, GITHUB_EVENT_PATH: join(root, '.git', 'pr-event.json')};
    const result = run(prEnv);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(join(root, '.git', 'platform-job-outputs'), 'utf8'),
      'required=["android"]\nrules=' + trustedBase + '\n');
    const plan = JSON.parse(readFileSync(join(root, '.git', 'platform-plan.json'), 'utf8'));
    assert.equal(plan.tested, tested);
    assert.equal(plan.base, trustedBase);
    assert.equal(plan.head, head);
    assert.notEqual(run({...prEnv, PR_HEAD: oldBase}).status, 0);

    git('restore', 'scripts/ci/platform-impact.mjs');
    git('checkout', '--detach', oldBase);
    git('merge', '--no-ff', 'candidate', '-m', 'test: bootstrap platform gate');
    assert.match(run(prEnv).stdout, /trusted base predates platform-gate/u);
    assert.equal(readFileSync(join(root, '.git', 'platform-job-outputs'), 'utf8'), '');
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});
