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
  GITHUB_ACTOR: bot.login, GITHUB_ACTOR_ID: String(bot.id),
  AEGIS_MACOS_DELIVERY_ENABLED: 'true', AEGIS_IOS_DELIVERY_BOT: JSON.stringify(policy),
  BOT_INPUTS: JSON.stringify({operation: 'Package', version: '0.8.0', build: '800001', package_kind: 'ad-hoc', signing_mode: 'ad-hoc'})};
const load = () => import('../macos-delivery-bot.mjs');

function childInputs(changes = {}) {
  return {operation: 'Package', version: '0.8.0', build: '800001', package_kind: 'ad-hoc', signing_mode: 'ad-hoc',
    approved_source_sha: sha, tag_release: 'no', bot_callback: 'yes', ...changes};
}

function run(id = 200) {
  return {id, run_attempt: 1, status: 'completed', conclusion: 'success', head_sha: sha, head_branch: 'main',
    path: '.github/workflows/macos-dmg.yml', event: 'workflow_dispatch',
    repository: {id: 1348409663, full_name: repository}, head_repository: {id: 1348409663, full_name: repository},
    actor: bot, triggering_actor: bot};
}

function fixture({shaReads = 0, dispatchBody = {workflow_run_id: 200}, dispatchError = false, runBody = run(),
  repositoryChanges = {}, initialInputs = childInputs(), transform = (_kind, value) => value} = {}) {
  const requests = [];
  let reads = 0;
  let dispatched = initialInputs, evidence;
  const repositoryName = repositoryChanges.full_name || repository;
  const repositoryId = repositoryChanges.id || 1348409663;
  function makeEvidence() {
    const kind = dispatched.package_kind;
    const filename = 'GCSA-aegis-0.8.0-mac-arm64.dmg';
    const manifest = transform('manifest', {schema: 'aegis-macos-delivery-v1', repository: repositoryName,
      sourceSha: sha, version: '0.8.0', build: '800001', packageKind: kind, notarized: kind === 'notarized',
      architectures: ['arm64'], artifacts: [{filename, architecture: 'arm64', role: 'package', uploadable: false,
        sha256: 'c'.repeat(64), sizeBytes: 100}]});
    const receipt = transform('receipt', {sourceSha: sha, packagingSourceSha: sha, version: '0.8.0', arch: 'arm64',
      notarized: false, signingMode: kind === 'ad-hoc' ? 'ad-hoc' : 'developer-id', notarizationSigning: kind === 'notarized',
      dmg: {name: filename, sha256: 'c'.repeat(64)}});
    const archive = execFileSync('python3', ['-c', 'import io,json,sys,zipfile\nv=json.load(sys.stdin)\nb=io.BytesIO()\nwith zipfile.ZipFile(b,"w") as z:\n for k,x in v.items(): z.writestr(k,json.dumps(x,separators=(",",":")))\nsys.stdout.buffer.write(b.getvalue())'],
      {input: JSON.stringify({'macos-delivery-manifest.json': manifest, 'macos-delivery-receipt.json': receipt})});
    const meta = {expired: false, size_in_bytes: archive.length, digest: 'sha256:'+createHash('sha256').update(archive).digest('hex'),
      workflow_run: {id: 200, head_sha: sha, head_branch: 'main'}};
    return {archive, manifest, artifacts: transform('artifacts', {total_count: 2, artifacts: [
      {id: 301, name: 'macos-dmg-200-1', ...meta}, {id: 302, name: 'macos-dmg-evidence-200-1', ...meta}]}),
    release: transform('release', {tag_name: `candidate/macos/0.8.0-${kind}.800001`, prerelease: true, draft: false,
      assets: [{id: 401, name: filename, state: 'uploaded', size: 100, digest: 'sha256:'+'c'.repeat(64)}]})};
  }
  const api = async (path, options = {}) => {
    requests.push({path, body: options.body, method: options.method || 'GET'});
    if (path === '/repos/'+repositoryName) return {id: repositoryId, full_name: repositoryName, default_branch: 'main', ...repositoryChanges};
    if (path.endsWith('/git/ref/heads/main')) {
      reads += 1;
      return {object: {sha: reads > shaReads && shaReads > 0 ? 'b'.repeat(40) : sha}};
    }
    if (path === '/repos/'+repositoryName+'/actions/runs/200') return {...runBody,
      repository: {id: repositoryId, full_name: repositoryName}, head_repository: {id: repositoryId, full_name: repositoryName}};
    if (path.endsWith('/attempts/1/jobs?per_page=100')) {
      const names = ['admission', 'package-'+dispatched.package_kind, ...(dispatched.tag_release === 'yes' ? ['candidate'] : [])];
      return transform('jobs', {total_count: names.length, jobs: names.map((name, index) => ({id: index+1,
        run_id: 200, run_attempt: 1, head_sha: sha, status: 'completed', conclusion: 'success', name}))});
    }
    if (path.endsWith('/artifacts?per_page=100')) {
      evidence = makeEvidence();
      return evidence.artifacts;
    }
    if (path.endsWith('/actions/artifacts/302/zip')) return transform('archive', evidence.archive);
    if (path.includes('/releases/tags/')) return evidence.release;
    if (options.method === 'POST' && path.endsWith('/dispatches')) {
      if (dispatchError) throw Object.assign(new Error('secret response'), {status: 500});
      dispatched = options.body.inputs;
      return dispatchBody;
    }
    throw new Error('Unexpected '+path);
  };
  return {api, requests, environment, quality: async () => true, sleep: async () => {}, sealedManifest: () => makeEvidence().manifest};
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
    method: 'POST', body: {ref: 'main', return_run_details: true, inputs: childInputs()},
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
  assert.equal(f.requests.find(call => call.method === 'POST').body.inputs.bot_callback, 'yes');
});

test('hosted monitoring defers truthfully to the verified callback without shortening the child budget', async () => {
  const {driveMacosDmg} = await load();
  let elapsed = 0;
  const recorded = [];
  const f = fixture({runBody: {...run(), status: 'in_progress', conclusion: null}});
  const value = await driveMacosDmg({...f, now: () => elapsed, monitorBudgetMs: 1000, pollMs: 15000,
    sleep: async ms => { elapsed += ms; }, recordRun: receipt => recorded.push(receipt)});
  assert.equal(elapsed, 1000);
  assert.equal(value.pending, true);
  assert.equal(value.notarized, false);
  assert.equal(value.tag, undefined);
  assert.equal(value.run.state, 'monitoring-deferred');
  assert.deepEqual(recorded.map(receipt => receipt.state), ['dispatched', 'monitoring-deferred']);
  assert.equal(f.requests.filter(call => call.method === 'POST').length, 1);
  assert.equal(f.requests.find(call => call.method === 'POST').body.inputs.bot_callback, 'yes');
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
  const f = fixture({repositoryChanges: {id: 1363949860, full_name: fork, default_branch: 'develop'}});
  const value = await driveMacosDmg({...f,
    environment: {...environment, GITHUB_REPOSITORY: fork}});
  assert.equal(value.repository, fork);
  assert.equal(value.packageKind, 'ad-hoc');
  assert.equal(f.requests.some(call => call.path.includes('/macos-dmg.yml/dispatches')), true);
});

test('overall success cannot replace exact-attempt jobs and sealed artifact evidence', async () => {
  const {driveMacosDmg} = await load();
  const cases = [
    ['jobs', value => ({...value, jobs: value.jobs.map(job => ({...job, conclusion: 'skipped'}))})],
    ['jobs', value => ({...value, jobs: value.jobs.map(job => ({...job, run_attempt: 2}))})],
    ['jobs', value => ({...value, total_count: 1000})],
    ['jobs', value => ({total_count: value.total_count, artifacts: value.jobs})],
    ['artifacts', value => ({...value, artifacts: value.artifacts.map(item => ({...item, expired: true}))})],
    ['artifacts', value => ({...value, total_count: 0, artifacts: []})],
    ['artifacts', value => ({...value, total_count: 1000})],
    ['artifacts', value => ({total_count: value.total_count, jobs: value.artifacts})],
    ['artifacts', value => ({...value, artifacts: value.artifacts.map(item => ({...item, digest: 'sha256:'+'0'.repeat(64)}))})],
    ['manifest', value => ({...value, sourceSha: 'b'.repeat(40)})],
    ['manifest', value => ({...value, packageKind: 'notarized', notarized: true})],
    ['receipt', value => ({...value, sourceSha: 'b'.repeat(40)})],
    ['archive', () => Buffer.from('unsealed')],
  ];
  for (const [kind, change] of cases) {
    const recorded = [];
    const f = fixture({transform: (part, value) => part === kind ? change(value) : value});
    await assert.rejects(driveMacosDmg({...f, recordRun: value => recorded.push(value)}), /DMG|inventory/u);
    assert.deepEqual(recorded.map(value => value.state), ['dispatched']);
    assert.equal(recorded[0].notarized, false);
    assert.equal(f.requests.filter(call => call.method === 'POST').length, 1);
  }
});

test('Tag release also requires a successful candidate job and the published DMG asset', async () => {
  const {driveMacosDmg} = await load();
  for (const kind of ['jobs', 'release']) {
    const f = fixture({transform: (part, value) => {
      if (part !== kind) return value;
      if (part === 'jobs') return {...value, jobs: value.jobs.map(job => job.name === 'candidate' ? {...job, conclusion: 'skipped'} : job)};
      return {...value, assets: []};
    }});
    await assert.rejects(driveMacosDmg({...f, environment: {...environment, BOT_INPUTS: JSON.stringify({
      operation: 'Tag release', version: '0.8.0', build: '800001', package_kind: 'ad-hoc', signing_mode: 'ad-hoc'})}}), /DMG/u);
  }
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
  const f = fixture({dispatchBody: {workflow_run_id: 90},
    initialInputs: childInputs({package_kind: 'host-signed', signing_mode: 'host-signed', tag_release: 'yes'})});
  const manifest = f.sealedManifest();
  const path = join(directory, 'macos-delivery-manifest.json');
  writeFileSync(path, JSON.stringify(manifest));
  const digest = createHash('sha256').update(readFileSync(path)).digest('hex');
  const value = await completeMacosDmg({api: f.api, manifestPath: path, environment: {...environment,
    GITHUB_RUN_ID: '200', AEGIS_MACOS_DELIVERY_TAG_RELEASE: 'true',
    AEGIS_MACOS_DELIVERY_VERSION: '0.8.0', AEGIS_MACOS_DELIVERY_BUILD: '800001',
    AEGIS_MACOS_DELIVERY_PACKAGE_KIND: 'host-signed', AEGIS_MACOS_DELIVERY_SIGNING_MODE: 'host-signed'}});
  assert.equal(value.workflowRunId, 90);
  assert.equal(value.operation, 'package');
  assert.equal(value.manifestSha256, digest);
  assert.equal(value.candidateTag, 'candidate/macos/0.8.0-host-signed.800001');
  assert.equal(f.requests.filter(call => call.method === 'POST').length, 1);
  const dispatch = f.requests.find(call => call.method === 'POST');
  assert.equal(dispatch.body.return_run_details, true);
  assert.equal(dispatch.body.inputs.operation, 'Complete');
  assert.equal(dispatch.body.inputs.completed_operation, 'package');
  assert.equal(dispatch.path.endsWith('/macos-delivery-bot.yml/dispatches'), true);
  for (const fail of ['jobs', 'manifest', 'parent']) {
    const denied = fixture({runBody: {...run(), ...(fail === 'parent' ? {run_attempt: 2} : {})},
      initialInputs: childInputs({package_kind: 'host-signed', signing_mode: 'host-signed', tag_release: 'yes'}),
      transform: (kind, data) => kind !== fail ? data : kind === 'jobs'
        ? {...data, jobs: data.jobs.map(job => ({...job, conclusion: 'skipped'}))} : {...data, sourceSha: 'b'.repeat(40)}});
    await assert.rejects(completeMacosDmg({api: denied.api, manifestPath: path, environment: {...environment,
      GITHUB_RUN_ID: '200', AEGIS_MACOS_DELIVERY_TAG_RELEASE: 'true',
      AEGIS_MACOS_DELIVERY_VERSION: '0.8.0', AEGIS_MACOS_DELIVERY_BUILD: '800001',
      AEGIS_MACOS_DELIVERY_PACKAGE_KIND: 'host-signed', AEGIS_MACOS_DELIVERY_SIGNING_MODE: 'host-signed'}}), /DMG|parent/u);
    assert.equal(denied.requests.filter(call => call.method === 'POST').length, 0);
  }
});

test('DMG dispatch choices preserve yes and no as strings under boolean YAML parsing', () => {
  const source = readFileSync('.github/workflows/macos-dmg.yml', 'utf8');
  const doc = YAML.parse(source, {version: '1.1'});
  const inputs = doc.true.workflow_dispatch.inputs;
  assert.deepEqual(inputs.tag_release.options, ['yes', 'no']);
  assert.equal(inputs.tag_release.default, 'no');
  assert.deepEqual(inputs.bot_callback.options, ['yes', 'no']);
  assert.equal(inputs.bot_callback.default, 'yes');
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
  assert.equal(job['timeout-minutes'], 355);
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
  assert.equal(child.jobs['package-ad-hoc']['timeout-minutes'], 1080);
  assert.equal(child.jobs['package-notarized']['timeout-minutes'], 400);
  for (const kind of ['ad-hoc', 'host-signed', 'notarized']) {
    const packageJob = child.jobs['package-'+kind];
    assert(packageJob.steps.some(step => step.with?.name === 'macos-dmg-evidence-${{ github.run_id }}-${{ github.run_attempt }}'));
    assert.equal(JSON.stringify(packageJob.env || {}).includes('runner.'), false);
    assert(packageJob.steps.some(step => step.name === 'Bind job-local DMG output' && step.run.includes('$GITHUB_ENV')));
    if (kind !== 'ad-hoc') {
      const setup = packageJob.steps.find(step => step.id === 'identity');
      assert.equal(Number(setup.env.AEGIS_MACOS_SIGNING_KEYCHAIN_TIMEOUT_SECONDS), packageJob['timeout-minutes'] * 60);
    }
  }
  const signed = child.jobs['package-notarized'].steps.find(step => step.name === 'Rebuild the Developer ID arm64 DMG');
  assert.equal(signed.env.MACOS_NOTARIZATION_SIGNING, '1');
  assert(child.jobs['package-notarized'].steps.some(step => step.run?.includes('xcrun stapler validate')));
  assert.match(child.jobs['call-bot'].steps.at(-1).run, /complete/u);
});

test('DMG summary confinement executes through the real shell adapter', () => {
  execFileSync('python3', ['-B', '-m', 'unittest', 'discover', '-s', 'scripts/release', '-p', 'test_macos_delivery_bot_summary.py'], {stdio: 'pipe'});
});
