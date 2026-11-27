import assert from 'node:assert/strict';
import test from 'node:test';
import {execFileSync, spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {parse} from 'yaml';

const sha = 'a'.repeat(40);
const repository = 'gcsagroup/aegis-browser';

test('public Android release keeps write permission on the publisher only', () => {
  const doc = parse(readFileSync('.github/workflows/android-github-release.yml', 'utf8'));
  assert.deepEqual(Object.keys(doc.on), ['workflow_dispatch']);
  assert.deepEqual(doc.permissions, {actions: 'read', contents: 'read'});
  assert.deepEqual(doc.jobs.preview.permissions, {actions: 'read', contents: 'read'});
  assert.deepEqual(doc.jobs.publish.permissions, {actions: 'read', contents: 'write'});
  assert.deepEqual(doc.jobs.publish.needs, ['preview', 'stable-approval']);
  assert(doc.jobs.publish.if.includes("inputs.operation == 'Publish prerelease'"));
  assert(doc.jobs.publish.if.includes("inputs.operation == 'Promote stable'"));
  assert(doc.jobs.publish.if.includes("needs.stable-approval.result == 'skipped'"));
  assert(doc.jobs.publish.if.includes("needs.stable-approval.result == 'success'"));
  assert.equal(doc.jobs.publish.environment, undefined);
  assert.equal(doc.jobs['stable-approval'].environment, 'aegis-android-github-production');
  assert.deepEqual(doc.jobs['stable-approval'].permissions, {});
  assert.equal(doc.jobs.publish.concurrency.queue, 'max');
  const controller = parse(readFileSync('.github/workflows/android-delivery-bot.yml', 'utf8'));
  assert.match(controller.concurrency.group, /Preview GitHub release.*release-preview/u);
  assert.equal(controller.jobs.controller.environment, 'aegis-android-bot');
  for (const job of [doc.jobs.preview, doc.jobs.publish]) {
    assert.equal(job.steps.filter(step => step.uses?.startsWith('actions/download-artifact@')).length, 0);
    const download = job.steps.find(step => step.run?.includes('android-github-release.py download-package'));
    assert.equal(download.env.PACKAGE_ARTIFACT_ID, '${{ steps.locate.outputs.package_artifact_id }}');
    assert(!download.run.includes('${{'));
    const plan = job.steps.find(step => /android-github-release\.py (?:preview|publish) /u.test(step.run));
    assert.equal(plan.env.STATUS_ARTIFACT_ID, '${{ steps.locate.outputs.status_artifact_id }}');
    assert(!plan.run.includes('${{'));
  }
});

test('Android delivery runs on canonical main and records the sealed package before Play', () => {
  const simple = parse(readFileSync('.github/workflows/android-delivery.yml', 'utf8'));
  const full = parse(readFileSync('.github/workflows/android-delivery-full.yml', 'utf8'));
  const backend = parse(readFileSync('.github/workflows/android-delivery-backend.yml', 'utf8'));
  assert(simple.jobs.delivery.if.includes("github.ref == 'refs/heads/main'"));
  assert(simple.jobs.delivery.if.includes("github.repository == 'gcsagroup/aegis-browser'"));
  assert(!simple.jobs.delivery.if.includes('android-release-acceptance'));
  assert.deepEqual(simple.on.push.branches, [
    'codex/android-release-handoff',
    'codex/android-delivery-modes',
    'codex/android-github-public-release-20261119',
  ]);
  assert(simple.jobs.contracts.if.includes("github.event_name == 'push'"));
  assert(full.jobs.delivery.if.includes("github.ref == 'refs/heads/main'"));
  assert(full.jobs.delivery.if.includes("github.repository == 'gcsagroup/aegis-browser'"));
  assert(simple.on.workflow_dispatch.inputs.operation.options.includes('发布核对 / Release Wait'));
  assert(backend.jobs.admission.steps.some(step => step.run?.includes('runner.rb') && step.if.includes("operation == 'package-upload'")));
  assert(backend.jobs.package.if.includes("operation == 'package-upload'"));
  assert(backend.jobs.package.if.includes("operation == 'draft'"));
  const setupJava = backend.jobs.package.steps.findIndex(step => step.uses?.startsWith('actions/setup-java@'));
  const packageStep = backend.jobs.package.steps.findIndex(step => step.run === 'python3 scripts/release/android-delivery.py package');
  assert(setupJava >= 0 && packageStep > setupJava);
  assert.equal(backend.jobs.package.steps[setupJava].with['java-version'], '17');
  const importStep = backend.jobs.store.steps.findIndex(step => step.run === 'python3 scripts/release/android-delivery.py import');
  const playStep = backend.jobs.store.steps.findIndex(step => step.env?.AEGIS_PLAY_JSON_KEY_DATA);
  assert(importStep >= 0 && playStep > importStep);
  assert.equal(backend.jobs.package.steps.find(step => step.uses?.startsWith('actions/upload-artifact@')).with.name,
    'android-package-${{ github.run_id }}-${{ github.run_attempt }}');
  assert(backend.jobs.package.steps.some(step => step.run === 'python3 scripts/release/android-delivery.py record-package'));
  assert.deepEqual(backend.jobs.store.needs, ['admission', 'package']);
  assert(backend.jobs.store.if.includes('package-upload'));
  assert(backend.jobs.query.if.includes('status-release-wait'));
  assert(backend.jobs.query.env.RELEASE_QUERY_MODE.includes('release-wait'));
  assert(backend.jobs.admission.if.includes('workflow_call'));
  assert(!JSON.stringify(backend.jobs.admission).includes('AEGIS_PLAY_JSON_KEY'));
  assert(backend.jobs.store.steps.some(step => step.env?.AEGIS_PLAY_JSON_KEY_DATA?.includes('secrets.AEGIS_PLAY_JSON_KEY_DATA')));
  assert.equal(backend.jobs.query.steps.find(step => step.run?.includes('android-status.rb')).env.AEGIS_PLAY_JSON_KEY_DATA,
    '${{ secrets.AEGIS_PLAY_JSON_KEY_DATA }}');
  const releaseWorkflow = parse(readFileSync('.github/workflows/android-github-release.yml', 'utf8'));
  assert(!JSON.stringify(releaseWorkflow.jobs).includes('secrets.'));
  assert(!simple.on.workflow_dispatch.inputs.operation.options.includes('Promote to stable'));
  assert(!full.on.workflow_dispatch.inputs.operation.options.some(option => option.includes('package-upload')));
});

test('producer retirement reports failure without blocking the sealed package', () => {
  const {jobs} = parse(readFileSync('.github/workflows/android-delivery-backend.yml', 'utf8'));
  const producer = jobs.package;
  const upload = producer.steps.findIndex(step => step.uses?.startsWith('actions/upload-artifact@'));
  const record = producer.steps.findIndex(step => step.run === 'python3 scripts/release/android-delivery.py record-package');
  const retire = producer.steps.findIndex(step => step.run?.includes('android-delivery.py retire-producer-output'));
  assert(upload >= 0 && record > upload && retire > record);
  const retirement = producer.steps[retire];
  assert.match(retirement.name, /Retire/u);
  assert.equal(retirement.if, undefined);
  assert.equal(retirement.env.CHROMIUM_ROOT, '${{ vars.AEGIS_CHROMIUM_ROOT }}');
  assert.equal(producer['continue-on-error'], undefined);
  assert.deepEqual(producer.steps.filter(step => step['continue-on-error'] !== undefined), [retirement]);
  assert.equal(retirement['continue-on-error'], true);
  assert(jobs.draft.if.includes("needs.package.result == 'success'"));
  assert(jobs.store.if.includes("operation != 'package-upload' || needs.package.result == 'success'"));

  for (const status of [0, 1]) {
    const result = spawnSync('bash', ['-e', '-c', `python3() { return ${status}; }\n${retirement.run}`],
      {encoding: 'utf8'});
    assert.equal(result.status, status);
    if (status === 1) {
      assert.match(result.stdout, /::warning title=Android producer output retirement failed::/u);
    } else {
      assert.equal(result.stdout, '');
    }
  }
});

test('preflight stays closed until Android release is enabled on current main', async () => {
  const {androidReleasePreflight} = await import('../release-preflight.mjs');
  const environment = {GH_TOKEN: 'fixture', GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: repository,
    GITHUB_SHA: sha, GITHUB_REF: 'refs/heads/main', GITHUB_EVENT_NAME: 'workflow_dispatch',
    AEGIS_ANDROID_RELEASE_ENABLED: 'true', RELEASE_DESTINATION: 'artifacts'};
  const api = async (_repo, path) => {
    if (path === '') return {id: '1348409663', default_branch: 'main'};
    if (path === '/git/ref/heads/main') return {object: {sha}};
    if (path.startsWith('/commits/')) return {sha};
    throw new Error(path);
  };
  const options = {environment, api, authorize: async () => ({authorized: true}), quality: async () => true};
  assert.equal((await androidReleasePreflight(sha, options)).line, 'main');
  await assert.rejects(androidReleasePreflight(sha, {...options, environment: {...environment, AEGIS_ANDROID_RELEASE_ENABLED: 'false'}}), /enabled/iu);
  await assert.rejects(androidReleasePreflight(sha, {...options, quality: async () => false}), /quality/iu);
  await assert.rejects(androidReleasePreflight(sha, {...options, environment: {...environment, RELEASE_DESTINATION: 'github-draft', RELEASE_TAG: 'candidate/android/7.2.0.339-release.1'}}), /tag/iu);
  await assert.rejects(androidReleasePreflight(sha, {...options, environment: {...environment, GITHUB_REPOSITORY: 'quinn521/aegis-browser'}}), /canonical upstream/iu);
  const admitted = await androidReleasePreflight(sha, {...options, environment: {...environment, RELEASE_DESTINATION: 'github-draft',
    RELEASE_TAG: 'candidate/android/7.2.0.339-release.2007000339'}});
  assert.equal(admitted.releaseReady, false);
  const semantic = await androidReleasePreflight(sha, {...options, environment: {...environment, RELEASE_DESTINATION: 'github-draft',
    RELEASE_TAG: 'candidate/android/0.8.0-alpha.1'}});
  assert.equal(semantic.releaseReady, false);
});

test('runner selection stays on the ready x64 host unless ARM64 is explicitly experimental', () => {
  const base = {...process.env, ANDROID_RUNNERS_READY: 'true', AEGIS_ANDROID_RUNNER_ARCH: 'x64', AEGIS_ANDROID_EXPERIMENTAL_ARM64: ''};
  const ready = execFileSync('ruby', ['scripts/release/runner.rb'], {env: base, encoding: 'utf8'});
  assert.equal(ready.trim(), 'runner=["self-hosted","Linux","X64","aegis-android-linux-x64"]');
  assert.throws(() => execFileSync('ruby', ['scripts/release/runner.rb'], {env: {...base, AEGIS_ANDROID_RUNNER_ARCH: 'arm64'}, stdio: 'pipe'}));
  const arm = execFileSync('ruby', ['scripts/release/runner.rb'], {env: {...base, AEGIS_ANDROID_RUNNER_ARCH: 'arm64', AEGIS_ANDROID_EXPERIMENTAL_ARM64: 'true'}, encoding: 'utf8'});
  assert.match(arm, /aegis-android-linux-arm64/);
});
