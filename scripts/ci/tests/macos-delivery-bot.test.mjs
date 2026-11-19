import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtempSync, readFileSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import YAML from 'yaml';

const repository = 'gcsagroup/aegis-browser';
const sha = 'a'.repeat(40);
const policy = {appId: 40, slug: 'aegis-delivery', actorId: 50};
const bot = {id: 50, login: 'aegis-delivery[bot]', type: 'Bot'};
const environment = {GITHUB_REPOSITORY: repository, GITHUB_SHA: sha, GITHUB_RUN_ID: '100',
  AEGIS_MACOS_DELIVERY_ENABLED: 'true', AEGIS_IOS_DELIVERY_BOT: JSON.stringify(policy),
  BOT_INPUTS: JSON.stringify({operation: 'Package', version: '0.8.0', build: '800001', package_kind: 'ad-hoc', signing_mode: 'ad-hoc'})};
const load = () => import('../macos-delivery-bot.mjs');

function childInputs(changes = {}) {
  return {operation: 'Package', version: '0.8.0', build: '800001', package_kind: 'ad-hoc', signing_mode: 'ad-hoc',
    approved_source_sha: sha, tag_release: 'no', bot_callback: 'no', ...changes};
}

function run(id = 200) {
  return {id, run_attempt: 1, status: 'completed', conclusion: 'success', head_sha: sha, head_branch: 'main',
    path: '.github/workflows/macos-dmg.yml', event: 'workflow_dispatch',
    repository: {id: 1348409663, full_name: repository}, head_repository: {id: 1348409663, full_name: repository},
    actor: bot, triggering_actor: bot};
}

function fixture({shaReads = 0, dispatchBody = {workflow_run_id: 200}, dispatchError = false, runBody = run(), repositoryChanges = {}} = {}) {
  const requests = [];
  let reads = 0;
  const api = async (path, options = {}) => {
    requests.push({path, body: options.body, method: options.method || 'GET'});
    if (path === '/repos/'+repository) return {id: 1348409663, full_name: repository, default_branch: 'main', ...repositoryChanges};
    if (path.endsWith('/git/ref/heads/main')) {
      reads += 1;
      return {object: {sha: reads > shaReads && shaReads > 0 ? 'b'.repeat(40) : sha}};
    }
    if (path === '/repos/'+repository+'/actions/runs/200') return runBody;
    if (options.method === 'POST' && path.endsWith('/dispatches')) {
      if (dispatchError) throw Object.assign(new Error('secret response'), {status: 500});
      return dispatchBody;
    }
    throw new Error('Unexpected '+path);
  };
  return {api, requests, environment, quality: async () => true, sleep: async () => {}};
}

test('Package dispatches one arm64 DMG and waits for that child', async () => {
  const {driveMacosDmg} = await load();
  const f = fixture();
  const recorded = [];
  const value = await driveMacosDmg({...f, recordRun: receipt => recorded.push(receipt.state)});
  assert.equal(value.notarized, false);
  assert.equal(value.upload, false);
  assert.equal(value.packageKind, 'ad-hoc');
  assert.equal(value.run.id, 200);
  assert.equal(value.tag, undefined);
  assert.deepEqual(recorded, ['dispatched', 'completed']);
  assert.deepEqual(f.requests.filter(call => call.method === 'POST'), [{
    path: '/repos/'+repository+'/actions/workflows/macos-dmg.yml/dispatches',
    method: 'POST', body: {ref: 'main', inputs: childInputs()},
  }]);
});

test('Tag release asks the child to publish the candidate and returns its tag', async () => {
  const {driveMacosDmg} = await load();
  const f = fixture();
  const value = await driveMacosDmg({...f, environment: {...environment, BOT_INPUTS: JSON.stringify({
    operation: 'Tag release', version: '0.8.0', build: '800001', package_kind: 'unsigned-dmg', signing_mode: 'none'})}});
  assert.equal(value.tag, 'candidate/macos/0.8.0-ad-hoc.800001');
  assert.equal(value.notarized, false);
  assert.deepEqual(f.requests.find(call => call.method === 'POST').body.inputs, childInputs({
    package_kind: 'ad-hoc', signing_mode: 'ad-hoc', tag_release: 'yes'}));
});

test('a notarized package stays a DMG and is not an App Store upload', async () => {
  const {driveMacosDmg} = await load();
  const f = fixture();
  const value = await driveMacosDmg({...f, environment: {...environment, BOT_INPUTS: JSON.stringify({
    operation: 'Package', version: '0.8.0', build: '800001', package_kind: 'notarized', signing_mode: 'notarized'})}});
  assert.equal(value.notarized, true);
  assert.equal(value.upload, false);
  assert.equal(f.requests.find(call => call.method === 'POST').body.inputs.bot_callback, 'no');
});

test('store operations, a mismatched pair, and a closed gate never dispatch', async () => {
  const {driveMacosDmg} = await load();
  const cases = [
    {BOT_INPUTS: JSON.stringify({operation: 'Package and upload', version: '0.8.0', build: '800001'})},
    {BOT_INPUTS: JSON.stringify({operation: 'Status', version: '0.8.0', build: '800001'})},
    {BOT_INPUTS: JSON.stringify({operation: 'Wait', version: '0.8.0', build: '800001'})},
    {BOT_INPUTS: JSON.stringify({operation: 'Package', version: '0.8.0', build: '0', package_kind: 'ad-hoc', signing_mode: 'ad-hoc'})},
    {BOT_INPUTS: JSON.stringify({operation: 'Package', version: '0.8.0', build: '800001', package_kind: 'host-signed', signing_mode: 'ad-hoc'})},
    {AEGIS_MACOS_DELIVERY_ENABLED: 'false'},
    {AEGIS_IOS_DELIVERY_BOT: '{}'},
    {GITHUB_REPOSITORY: 'other/aegis-browser'},
  ];
  for (const changes of cases) {
    const f = fixture();
    await assert.rejects(driveMacosDmg({...f, environment: {...environment, ...changes}}), /DMG|App|fork|disabled|inputs|version|signing/u);
    assert.equal(f.requests.filter(call => call.method === 'POST').length, 0);
  }
});

test('the fork runs the same Package matrix before upstream promotion', async () => {
  const {driveMacosDmg} = await load();
  const fork = 'quinn521/aegis-browser';
  const requests = [];
  const api = async (path, options = {}) => {
    requests.push({path, body: options.body, method: options.method || 'GET'});
    if (path === '/repos/'+fork) return {id: 1363949860, full_name: fork, default_branch: 'main'};
    if (path.endsWith('/git/ref/heads/main')) return {object: {sha}};
    if (path === '/repos/'+fork+'/actions/runs/200') {
      return {id: 200, run_attempt: 1, status: 'completed', conclusion: 'success', head_sha: sha, head_branch: 'main',
        path: '.github/workflows/macos-dmg.yml', event: 'workflow_dispatch',
        repository: {id: 1363949860, full_name: fork}, head_repository: {id: 1363949860, full_name: fork},
        actor: bot, triggering_actor: bot};
    }
    if (options.method === 'POST') return {workflow_run_id: 200};
    throw new Error(path);
  };
  const value = await driveMacosDmg({api, quality: async () => true, sleep: async () => {},
    environment: {...environment, GITHUB_REPOSITORY: fork}});
  assert.equal(value.repository, fork);
  assert.equal(value.packageKind, 'ad-hoc');
  assert.equal(requests.some(call => call.path.includes('/macos-dmg.yml/dispatches')), true);
});

test('red quality and a main move after the first read do not dispatch', async () => {
  const {driveMacosDmg} = await load();
  const red = fixture();
  await assert.rejects(driveMacosDmg({...red, quality: async () => false}), /quality/u);
  assert.equal(red.requests.filter(call => call.method === 'POST').length, 0);
  const moved = fixture({shaReads: 1});
  await assert.rejects(driveMacosDmg(moved), /current main/u);
  assert.equal(moved.requests.filter(call => call.method === 'POST').length, 0);
});

test('an ambiguous or empty dispatch is not repeated', async () => {
  const {driveMacosDmg} = await load();
  for (const options of [{dispatchError: true}, {dispatchBody: {}}]) {
    const f = fixture(options);
    await assert.rejects(driveMacosDmg(f), /unknown|reconcile/u);
    assert.equal(f.requests.filter(call => call.method === 'POST').length, 1);
  }
});

test('a failed child is retained and not dispatched again', async () => {
  const {driveMacosDmg} = await load();
  const f = fixture({runBody: {...run(), conclusion: 'failure'}});
  await assert.rejects(driveMacosDmg(f), /failed|reconcile/u);
  assert.equal(f.requests.filter(call => call.method === 'POST').length, 1);
});

test('complete dispatches the bot receipt for the sealed manifest and does not package again', async () => {
  const {completeMacosDmg} = await load();
  const directory = mkdtempSync(join(tmpdir(), 'aegis-macos-complete-'));
  const manifest = {schema: 'aegis-macos-delivery-v1', repository, sourceSha: sha, packageKind: 'host-signed',
    version: '0.8.0', build: '800001', notarized: false,
    artifacts: [{architecture: 'arm64', uploadable: false, sha256: 'c'.repeat(64)}]};
  const path = join(directory, 'macos-delivery-manifest.json');
  writeFileSync(path, JSON.stringify(manifest));
  const digest = createHash('sha256').update(readFileSync(path)).digest('hex');
  const f = fixture({dispatchBody: {workflow_run_id: 90}});
  const value = await completeMacosDmg({api: f.api, manifestPath: path, environment: {...environment,
    AEGIS_MACOS_DELIVERY_VERSION: '0.8.0', AEGIS_MACOS_DELIVERY_BUILD: '800001',
    AEGIS_MACOS_DELIVERY_PACKAGE_KIND: 'host-signed', AEGIS_MACOS_DELIVERY_SIGNING_MODE: 'host-signed'}});
  assert.equal(value.workflowRunId, 90);
  assert.equal(value.operation, 'package');
  assert.equal(value.manifestSha256, digest);
  assert.equal(f.requests.filter(call => call.method === 'POST').length, 1);
  assert.equal(f.requests[0].body.inputs.operation, 'Complete');
  assert.equal(f.requests[0].body.inputs.completed_operation, 'package');
  assert.equal(f.requests[0].path.endsWith('/macos-delivery-bot.yml/dispatches'), true);
});

test('the controller form packages or tags a DMG, and promotion is a separate admin job', () => {
  const doc = YAML.parse(readFileSync('.github/workflows/macos-delivery-bot.yml', 'utf8'));
  const child = YAML.parse(readFileSync('.github/workflows/macos-dmg.yml', 'utf8'));
  const manual = YAML.parse(readFileSync('.github/workflows/macos-delivery.yml', 'utf8'));
  assert.deepEqual(Object.keys(doc.on), ['workflow_dispatch']);
  assert.deepEqual(doc.permissions, {contents: 'read', actions: 'read'});
  assert.equal(doc.concurrency['cancel-in-progress'], false);
  const job = doc.jobs.controller;
  assert.equal(job.environment, 'aegis-ios-bot');
  assert.equal(job['timeout-minutes'], 430);
  for (const condition of ["github.repository == 'quinn521/aegis-browser'", "github.repository == 'gcsagroup/aegis-browser'",
    "github.ref == 'refs/heads/main'", "github.event_name == 'workflow_dispatch'", 'github.run_attempt == 1',
    "inputs.operation != 'Promote'", "vars.AEGIS_MACOS_DELIVERY_ENABLED == 'true'"]) assert(job.if.includes(condition));
  const guard = job.steps.findIndex(step => step.run === 'node scripts/ci/macos-operator.mjs --context controller');
  const keyStep = job.steps.findIndex(step => step.env?.AEGIS_IOS_BOT_PRIVATE_KEY);
  assert(guard >= 0 && keyStep > guard);
  assert.equal(job.steps[keyStep].run, 'bash scripts/ci/run-macos-delivery-bot.sh');
  assert.deepEqual(doc.on.workflow_dispatch.inputs.operation.options, ['Package', 'Tag release', 'Promote', 'Complete']);
  assert.deepEqual(doc.jobs.promote.permissions, {actions: 'read', contents: 'write'});
  assert.equal(doc.jobs.promote.environment, 'aegis-macos-dmg-stable');
  assert.match(doc.jobs.promote.if, /gcsagroup\/aegis-browser/u);
  assert.equal(doc.jobs.promote.if.includes('quinn521'), false);
  assert.equal(doc.jobs['accept-complete'].environment, undefined);
  assert.match(child.jobs.admission.if, /quinn521\/aegis-browser/u);
  const text = JSON.stringify(doc);
  for (const forbidden of ['notarytool', 'stapler', 'altool', 'AEGIS_ASC_', 'P12', 'Publish prerelease', 'Package and upload', 'macos-26']) {
    assert.equal(text.includes(forbidden), false, forbidden);
  }
  assert.equal(JSON.stringify(manual).includes('notarytool'), false);
  assert.equal(JSON.stringify(child).includes('notarytool'), true);
  assert.equal(JSON.stringify(child).includes('store-credentials'), false);
  assert.equal(JSON.stringify(child).includes('macos-26'), false);
  assert.deepEqual(child.on.workflow_dispatch.inputs.operation.options, ['Package']);
  assert.equal(child.jobs['package-ad-hoc']['timeout-minutes'], 360);
  assert.equal(child.jobs['package-notarized']['timeout-minutes'], 400);
  assert.match(child.jobs['call-bot'].steps.at(-1).run, /complete/u);
});

test('DMG summary confinement executes through the real shell adapter', () => {
  execFileSync('python3', ['-B', '-m', 'unittest', 'discover', '-s', 'scripts/release', '-p', 'test_macos_delivery_bot_summary.py'], {stdio: 'pipe'});
});
