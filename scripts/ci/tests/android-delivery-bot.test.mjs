import assert from 'node:assert/strict';
import test from 'node:test';
import {generateKeyPairSync, verify} from 'node:crypto';

const repository = 'gcsagroup/aegis-browser';
const sha = 'a'.repeat(40);
const policy = {appId: 40, slug: 'aegis-android', actorId: 50};
const environment = {GITHUB_REPOSITORY: repository, GITHUB_SHA: sha, GITHUB_RUN_ID: '100', GITHUB_ACTOR_ID: '99',
  GITHUB_ACTOR: 'admin', AEGIS_ANDROID_GITHUB_RELEASE_ENABLED: 'true', AEGIS_ANDROID_RELEASE_ENABLED: 'true',
  AEGIS_ANDROID_DELIVERY_BOT: JSON.stringify(policy),
  BOT_INPUTS: JSON.stringify({operation: 'Package and upload', version: '7.2.0.339', build: '2007000339', product: 'Release'})};
const load = () => import('../android-delivery-bot.mjs');
const actor = {id: 50, login: 'aegis-android[bot]', type: 'Bot'};

function fixture({failure, mutate = value => value, jobsFor = () => ['delivery / package', 'delivery / store', 'delivery / query']} = {}) {
  const requests = [];
  const runs = new Map();
  let next = 200;
  const api = async (path, options = {}) => {
    if (path === '/repos/' + repository) return {id: 1348409663, full_name: repository, default_branch: 'main'};
    if (path.endsWith('/git/ref/heads/main')) return {object: {sha}};
    const inventory = path.match(/\/actions\/runs\/(\d+)\/attempts\/1\/jobs\?per_page=100$/u);
    if (inventory) {
      const jobs = jobsFor(Number(inventory[1])).map((name, index) => ({id: 300 + index, name, run_id: Number(inventory[1]),
        run_attempt: 1, head_sha: sha, status: 'completed', conclusion: 'success'}));
      return {total_count: jobs.length, jobs};
    }
    if (options.method === 'POST') {
      requests.push({path, body: options.body});
      const id = next++;
      runs.set(id, mutate({id, run_attempt: 1, status: 'completed', conclusion: failure || 'success', head_sha: sha,
        head_branch: 'main', path: '.github/workflows/android-delivery.yml', event: 'workflow_dispatch',
        repository: {id: 1348409663, full_name: repository}, head_repository: {id: 1348409663, full_name: repository},
        actor, triggering_actor: actor}, options.body.inputs.operation));
      return {workflow_run_id: id};
    }
    return runs.get(Number(path.split('/').at(-1)));
  };
  return {api, requests, environment, quality: async () => true, sleep: async () => {}};
}

test('package and upload waits for the sealed package and the Play draft', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  const value = await driveDelivery(f);
  assert.deepEqual(value.runs.map(run => run.operation), ['Package and upload', 'Wait']);
  assert.equal(f.requests[0].body.inputs.approved_source_sha, sha);
  assert.equal(f.requests[0].body.inputs.operation, '打包并上传 / Package and upload');
  assert.equal(f.requests[0].body.inputs.product, 'Release · 通用 / Universal');
  assert.equal(f.requests[0].body.inputs.version, '7.2.0.339');
  assert.equal(f.requests[1].body.inputs.operation, '等待状态 / Wait');
});

test('a skipped package job does not advance to Wait', async () => {
  const {driveDelivery} = await load();
  const f = fixture({jobsFor: () => ['delivery / query']});
  await assert.rejects(driveDelivery(f), /jobs/iu);
  assert.equal(f.requests.length, 1);
});

test('GitHub release preview dispatches Release Wait and then the exact child', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  const receipts = [];
  const inputs = {operation: 'Preview GitHub release', version: '7.2.0.339', build: '2007000339', product: 'Release'};
  const value = await driveDelivery({...f, recordReleaseDispatch: receipt => receipts.push(receipt),
    environment: {...environment, BOT_INPUTS: JSON.stringify(inputs)}});
  assert.deepEqual(value.runs.map(run => run.id), [200, 201]);
  assert.equal(f.requests[0].body.inputs.operation, '发布核对 / Release Wait');
  assert.equal(f.requests[0].body.inputs.product, 'Release · 通用 / Universal');
  assert.equal(f.requests[1].path, '/repos/' + repository + '/actions/workflows/android-github-release.yml/dispatches');
  assert.deepEqual(f.requests[1].body.inputs, {operation: 'Preview', release_type: 'stable', version: '7.2.0.339',
    build: '2007000339', status_run_id: '200', controller_run_id: '100', controller_actor_id: '99',
    controller_actor_login: 'admin', approved_source_sha: sha});
  assert.equal(receipts[0].childRunId, 201);
  assert.deepEqual(receipts[0].inputs, f.requests[1].body.inputs);
});

test('release publication stays disabled and bad coordinates never dispatch', async () => {
  const {driveDelivery} = await load();
  const preview = {operation: 'Publish prerelease', version: '7.2.0.339', build: '2007000339', product: 'Release'};
  const disabled = fixture();
  await assert.rejects(driveDelivery({...disabled, environment: {...environment, AEGIS_ANDROID_GITHUB_RELEASE_ENABLED: 'false',
    BOT_INPUTS: JSON.stringify(preview)}}), /disabled/iu);
  assert.equal(disabled.requests.length, 0);
  for (const input of [{build: '2007000340'}, {version: '7.2.0'}, {product: 'Alpha', operation: 'Preview GitHub release'}, {unknown: 'value'}]) {
    const f = fixture();
    await assert.rejects(driveDelivery({...f, environment: {...environment, BOT_INPUTS: JSON.stringify({...preview, ...input})}}));
    assert.equal(f.requests.length, 0);
  }
});

test('failed, moved, and invisible children do not launch another mutation', async () => {
  const {driveDelivery} = await load();
  const failed = fixture({failure: 'failure'});
  await assert.rejects(driveDelivery(failed), /failed|reconcile/iu);
  assert.equal(failed.requests.length, 1);
  const moved = fixture();
  const api = (path, options) => path.endsWith('/git/ref/heads/main') && moved.requests.length
    ? {object: {sha: 'b'.repeat(40)}} : moved.api(path, options);
  await assert.rejects(driveDelivery({...moved, api, environment: {...environment, BOT_INPUTS: JSON.stringify({
    operation: 'Package and upload', version: '7.2.0.339', build: '2007000339', product: 'Release'})}}), /source|main/iu);
  assert.equal(moved.requests.length, 1);
  const invisible = fixture();
  let reads = 0;
  const missing = (path, options) => {
    if (path.includes('/actions/runs/')) { reads += 1; throw Object.assign(new Error('not visible'), {status: 404}); }
    return invisible.api(path, options);
  };
  await assert.rejects(driveDelivery({...invisible, api: missing, environment: {...environment, BOT_INPUTS: JSON.stringify({
    operation: 'Status', version: '7.2.0.339', build: '2007000339', product: 'Alpha'})}}), /not visible/iu);
  assert.equal(reads, 5);
  assert.equal(invisible.requests.length, 1);
});

test('installation tokens stay on this repository and reject broader permissions', async () => {
  const {installationClient, githubRequest} = await load();
  const {privateKey, publicKey} = generateKeyPairSync('rsa', {modulusLength: 2048});
  const now = Date.parse('2026-11-19T08:00:00Z');
  let captured;
  const request = async (path, options) => {
    if (path === '/app/installations/60/access_tokens') {
      captured = options;
      return {token: 'installation-token', expires_at: '2026-11-19T09:00:00Z', permissions: {actions: 'write', contents: 'read', metadata: 'read'}};
    }
    return {ok: options.token === 'installation-token'};
  };
  const api = installationClient({appId: 40, installationId: 60, privateKey: privateKey.export({type: 'pkcs8', format: 'pem'}), now: () => now, request});
  assert.equal((await api('/repos/' + repository)).ok, true);
  const parts = captured.token.split('.');
  assert(verify('RSA-SHA256', Buffer.from(parts.slice(0, 2).join('.')), publicKey, Buffer.from(parts[2], 'base64url')));
  assert.equal(JSON.parse(Buffer.from(parts[1], 'base64url')).iss, '40');
  await assert.rejects(api('/repos/other/repo'), /canonical repository/iu);
  for (const permissions of [{actions: 'write', contents: 'write'}, {actions: 'write', contents: 'read', administration: 'write'}]) {
    const rejected = installationClient({appId: 40, installationId: 60, privateKey, now: () => now,
      request: async () => ({token: 'installation-token', expires_at: '2026-11-19T09:00:00Z', permissions})});
    await assert.rejects(rejected('/repos/' + repository), /scope|expiry/iu);
  }
  const original = globalThis.fetch;
  globalThis.fetch = async () => ({ok: false, status: 404, json: async () => ({secret: 'do not expose'})});
  try {
    await assert.rejects(githubRequest('/repos/' + repository, {token: 'private-token'}), error => error.status === 404 && !error.message.includes('secret'));
  } finally { globalThis.fetch = original; }
});
