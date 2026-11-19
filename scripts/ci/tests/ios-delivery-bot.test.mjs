import assert from 'node:assert/strict';
import test from 'node:test';
import {generateKeyPairSync, verify} from 'node:crypto';

const repository = 'gcsagroup/aegis-browser';
const sha = 'a'.repeat(40);
const policy = {appId: 40, slug: 'aegis-delivery', actorId: 50};
const environment = {GITHUB_REPOSITORY: repository, GITHUB_SHA: sha,
  GITHUB_RUN_ID: '100', GITHUB_ACTOR_ID: '99', GITHUB_ACTOR: 'admin',
  AEGIS_IOS_GITHUB_RELEASE_ENABLED: 'true', AEGIS_IOS_RELEASE_ENABLED: 'true',
  AEGIS_IOS_DELIVERY_BOT: JSON.stringify(policy), BOT_INPUTS: JSON.stringify({operation: 'Package and upload', version: '1.1.0', build: '4', product: 'Beta', signing_mode: 'manual'})};
const load = () => import('../ios-delivery-bot.mjs');
function fixture({failure, mutate = value => value, mutateJobs = value => value, dispatchError = false} = {}) {
  const requests = [];
  const runs = new Map();
  const operations = new Map();
  let next = 200;
  const api = async (path, options = {}) => {
    if (path === '/repos/'+repository) return {id: 1348409663, full_name: repository, default_branch: 'main'};
    if (path.endsWith('/git/ref/heads/main')) return {object: {sha}};
    const inventory = path.match(/\/actions\/runs\/(\d+)\/attempts\/1\/jobs\?per_page=100$/u);
    if (inventory) {
      const names = ['Wait', 'Release Wait'].includes(operations.get(Number(inventory[1]))) ? ['status-query'] : ['ios-package', 'seal-package', 'upload-new'];
      const jobs = names.map((name, index) => ({id: 300+index,
        name, run_id: Number(inventory[1]), run_attempt: 1, head_sha: sha, status: 'completed', conclusion: 'success'}));
      return mutateJobs({total_count: jobs.length, jobs});
    }
    if (path.endsWith('/pending_deployments')) return [{environment: {name: 'aegis-ios-github-production'}}];
    if (options.method === 'POST') {
      requests.push({path, body: options.body});
      if (dispatchError) throw new Error('secret response');
      const id = next++;
      const release = path.includes('ios-github-release.yml');
      const operation = options.body.inputs.operation;
      operations.set(id, operation);
      const workflow = release ? 'ios-github-release' : path.includes('ios-delivery-full') ? 'ios-delivery-full' : 'ios-delivery';
      const waiting = release && operation === 'Promote stable';
      runs.set(id, mutate({id, run_attempt: 1, status: waiting ? 'waiting' : 'completed', conclusion: waiting ? null : failure || 'success',
        head_sha: sha, head_branch: 'main', path: '.github/workflows/'+workflow+'.yml', event: 'workflow_dispatch',
        repository: {id: 1348409663, full_name: repository}, head_repository: {id: 1348409663, full_name: repository},
        actor: {id: 50, login: 'aegis-delivery[bot]', type: 'Bot'}, triggering_actor: {id: 50, login: 'aegis-delivery[bot]', type: 'Bot'}}));
      return {workflow_run_id: id};
    }
    return runs.get(Number(path.split('/').at(-1)));
  };
  return {api, requests, environment, quality: async () => true, sleep: async () => {}};
}
test('Beta upload dispatches the exact approved source then waits for that coordinate', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  const value = await driveDelivery(f);
  assert.deepEqual(value.runs.map(run => run.id), [200, 201]);
  assert.equal(value.runs[1].operation, 'Wait');
  assert.deepEqual(f.requests[0].body, {ref: 'main', inputs: {operation: 'Package and upload', version: '1.1.0', build: '4', product: 'Beta', signing_mode: 'manual', archive_signing: 'development', private_beta: 'no', approved_source_sha: sha}});
  assert.equal(f.requests[1].body.inputs.build, '4');
});
test('failed producer and ambiguous dispatch stop without a second mutation', async () => {
  const {driveDelivery} = await load();
  for (const options of [{failure: 'failure'}, {dispatchError: true}]) {
    const f = fixture(options);
    await assert.rejects(driveDelivery(f), /failed|unknown|reconcile/iu);
    assert.equal(f.requests.length, 1);
  }
});
test('a green producer with a skipped, missing or unbound upload never advances to Wait', async () => {
  const {driveDelivery} = await load();
  for (const patch of [{conclusion: 'skipped'}, {conclusion: 'failure'}, {status: 'queued'},
    {run_id: 201}, {run_attempt: 2}, {head_sha: 'b'.repeat(40)}]) {
    const f = fixture({mutateJobs: value => ({...value, jobs: value.jobs.map(job => job.name === 'upload-new' ? {...job, ...patch} : job)})});
    const receipts = [];
    await assert.rejects(driveDelivery({...f, recordRun: row => receipts.push(row)}), /upload|jobs/iu);
    assert.equal(f.requests.length, 1);
    assert.deepEqual(receipts.map(row => row.state), ['dispatched']);
  }
  for (const mutateJobs of [() => ({total_count: 0, jobs: []}), value => ({...value, total_count: 101}),
    value => ({...value, jobs: [...value.jobs, value.jobs[2]], total_count: 4})]) {
    const f = fixture({mutateJobs});
    await assert.rejects(driveDelivery(f), /upload|jobs/iu);
    assert.equal(f.requests.length, 1);
  }
});
test('monitor rejects another repository, source, Bot or rerun instead of advancing', async () => {
  const {driveDelivery} = await load();
  for (const patch of [{head_sha: 'b'.repeat(40)}, {run_attempt: 2}, {actor: {id: 51, login: 'other[bot]', type: 'Bot'}},
    {head_repository: {id: 1, full_name: 'other/repo'}}, {path: '.github/workflows/quality.yml'}, {event: 'push'}]) {
    const f = fixture({mutate: run => ({...run, ...patch})});
    await assert.rejects(driveDelivery(f), /identity|source|run|context/iu);
    assert.equal(f.requests.length, 1);
  }
});
test('invalid coordinates, production operations and non-green sources never dispatch', async () => {
  const {driveDelivery} = await load();
  for (const input of [{operation: 'Distribute external'}, {build: '0'}, {version: '1.1.0;echo bad'}, {private_beta: 'yes'}, {unknown: 'value'}]) {
    const f = fixture();
    const inputs = {...JSON.parse(environment.BOT_INPUTS), ...input};
    await assert.rejects(driveDelivery({...f, environment: {...environment, BOT_INPUTS: JSON.stringify(inputs)}}));
    assert.equal(f.requests.length, 0);
  }
  const f = fixture();
  await assert.rejects(driveDelivery({...f, quality: async () => false}), /quality/iu);
  assert.equal(f.requests.length, 0);
});
test('version parsing accepts bounded decimal components and rejects malformed or excessive components', async () => {
  const {driveDelivery} = await load();
  for (const [version, accepted] of [['1.1', true], ['1.1.0', true], ['0000000000.1.0', true],
    ['10000000000.1.0', false], ['1..0', false], ['1.1.0.4', false], ['１.1.0', false], ['1.1.0\n', false],
    ['1.'+'1'.repeat(5000)+'.0', false]]) {
    const f = fixture();
    const inputs = {...JSON.parse(environment.BOT_INPUTS), operation: 'Status', version};
    const task = driveDelivery({...f, environment: {...environment, BOT_INPUTS: JSON.stringify(inputs)}});
    if (accepted) assert.equal((await task).version, version);
    else { await assert.rejects(task); assert.equal(f.requests.length, 0); }
  }
});
test('Draft uses the existing Full workflow without granting tag or release writes', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  const inputs = {...JSON.parse(environment.BOT_INPUTS), operation: 'Draft'};
  await driveDelivery({...f, environment: {...environment, BOT_INPUTS: JSON.stringify(inputs)}});
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].path, '/repos/gcsagroup/aegis-browser/actions/workflows/ios-delivery-full.yml/dispatches');
});
test('source movement after upload prevents a new dispatch and retains the producer identity', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  const api = (path, options) => path.endsWith('/git/ref/heads/main') && f.requests.length
    ? {object: {sha: 'b'.repeat(40)}} : f.api(path, options);
  await assert.rejects(driveDelivery({...f, api}), /source|main/iu);
  assert.equal(f.requests.length, 1);
});
test('a queued run times out with its exact URL instead of launching another producer', async () => {
  const {driveDelivery} = await load();
  const f = fixture({mutate: run => ({...run, status: 'queued', conclusion: null})});
  await assert.rejects(driveDelivery({...f, maxPolls: 2}), /pending.*actions\/runs\/200/iu);
  assert.equal(f.requests.length, 1);
});
test('a polling transport failure retains the dispatch identity before its first GET', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  const retained = [];
  const api = (path, options) => {
    if (path.endsWith('/actions/runs/200')) throw new Error('polling transport failed');
    return f.api(path, options);
  };
  await assert.rejects(driveDelivery({...f, api, recordRun: value => retained.push(value)}), /polling transport/iu);
  assert.deepEqual(retained.map(value => [value.id, value.attempt, value.state]), [[200, 1, 'dispatched']]);
  assert.equal(retained[0].url, 'https://github.com/gcsagroup/aegis-browser/actions/runs/200');
});
test('a later Wait failure retains the successful producer and both exact run receipts', async () => {
  const {driveDelivery} = await load();
  const f = fixture({mutate: run => ({...run, conclusion: run.id === 201 ? 'failure' : 'success'})});
  const retained = [];
  await assert.rejects(driveDelivery({...f, recordRun: value => retained.push(value)}), /failed/iu);
  assert.deepEqual(retained.map(value => [value.id, value.state]), [[200, 'dispatched'], [200, 'completed'], [201, 'dispatched']]);
  assert.equal(retained[1].conclusion, 'success');
  assert.equal(retained[1].approvedSourceSha, sha);
});
test('GitHub release preview waits for Apple VALID and dispatches only the exact release evidence', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  const inputs = {...JSON.parse(environment.BOT_INPUTS), operation: 'Preview GitHub release',
    version: '1.2.0', build: '9', product: 'Release'};
  const value = await driveDelivery({...f, environment: {...environment, BOT_INPUTS: JSON.stringify(inputs)}});
  assert.deepEqual(value.runs.map(row => row.id), [200, 201]);
  assert.equal(f.requests[0].body.inputs.operation, 'Release Wait');
  assert.equal(f.requests[1].path, '/repos/'+repository+'/actions/workflows/ios-github-release.yml/dispatches');
  assert.deepEqual(f.requests[1].body.inputs, {operation: 'Preview', release_type: 'stable', version: '1.2.0', build: '9',
    status_run_id: '200', controller_run_id: '100', controller_actor_id: '99', controller_actor_login: 'admin',
    approved_source_sha: sha});
});
test('prerelease and promotion controllers seal the exact child dispatch', async () => {
  const {driveDelivery} = await load();
  for (const [operation, child] of [['Publish prerelease', 'Publish prerelease'], ['Promote to stable', 'Promote stable']]) {
    const f = fixture();
    const receipts = [];
    const inputs = {...JSON.parse(environment.BOT_INPUTS), operation,
      version: '1.2.0', build: '9', product: 'Release'};
    const value = await driveDelivery({...f, recordReleaseDispatch: receipt => receipts.push(receipt),
      environment: {...environment, BOT_INPUTS: JSON.stringify(inputs)}});
    assert.equal(f.requests.length, 2);
    assert.equal(f.requests[1].body.inputs.operation, child);
    assert.equal(f.requests[1].body.inputs.release_type, 'stable');
    assert.equal(value.runs[1].state, 'dispatched');
    assert.deepEqual(receipts, [{childRunId: 201, inputs: f.requests[1].body.inputs}]);
  }
});
test('the current TestFlight build can only be previewed and release settings are required before dispatch', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  const publish = {...JSON.parse(environment.BOT_INPUTS), operation: 'Publish prerelease', product: 'Release', version: '1.1.0', build: '8'};
  await assert.rejects(driveDelivery({...f, environment: {...environment, BOT_INPUTS: JSON.stringify(publish)}}), /preview-only/iu);
  const promote = {...publish, operation: 'Promote to stable'};
  await assert.rejects(driveDelivery({...f, environment: {...environment, BOT_INPUTS: JSON.stringify(promote)}}), /preview-only/iu);
  const beta = {...publish, operation: 'Publish Beta release', product: 'Beta', version: '1.2.0', build: '9'};
  await assert.rejects(driveDelivery({...f, environment: {...environment, BOT_INPUTS: JSON.stringify(beta)}}), /Invalid Bot operation/iu);
  const previewBeta = {...beta, operation: 'Preview GitHub release'};
  await assert.rejects(driveDelivery({...f, environment: {...environment, BOT_INPUTS: JSON.stringify(previewBeta)}}), /Release product/iu);
  assert.equal(f.requests.length, 0);
  const preview = {...publish, operation: 'Preview GitHub release'};
  await assert.rejects(driveDelivery({...f, environment: {...environment, AEGIS_IOS_GITHUB_RELEASE_ENABLED: 'false',
    BOT_INPUTS: JSON.stringify(preview)}}), /disabled|configured/iu);
  assert.equal(f.requests.length, 0);
});
test('App authentication signs a short JWT and limits the installation token to this repository', async () => {
  const {installationClient} = await load();
  const {privateKey, publicKey} = generateKeyPairSync('rsa', {modulusLength: 2048});
  const privatePem = privateKey.export({type: 'pkcs8', format: 'pem'});
  const now = Date.parse('2026-11-17T12:00:00Z');
  let captured;
  const request = async (path, options) => {
    if (path === '/app/installations/60/access_tokens') {
      captured = options;
      return {token: 'private-installation-token', expires_at: '2026-11-17T13:00:00Z', permissions: {actions: 'write', contents: 'read'}};
    }
    return {ok: options.token === 'private-installation-token'};
  };
  const api = installationClient({appId: 40, installationId: 60, privateKey: privatePem, now: () => now, request});
  assert.equal((await api('/repos/'+repository)).ok, true);
  assert.deepEqual(captured.body, {repository_ids: [1348409663], permissions: {actions: 'write', contents: 'read'}});
  const parts = captured.token.split('.');
  assert(verify('RSA-SHA256', Buffer.from(parts.slice(0,2).join('.')), publicKey, Buffer.from(parts[2], 'base64url')));
  const claims = JSON.parse(Buffer.from(parts[1], 'base64url'));
  assert.equal(claims.iss, '40');
  assert(claims.exp - claims.iat <= 600);
});
test('foreign repository paths, excess token permissions and invalid expiry fail closed', async () => {
  const {installationClient} = await load();
  const {privateKey} = generateKeyPairSync('rsa', {modulusLength: 2048});
  const now = Date.parse('2026-11-17T12:00:00Z');
  for (const patch of [{permissions: {actions: 'write', contents: 'write'}},
    {permissions: {actions: 'write', contents: 'read', administration: 'write'}}, {expires_at: '2026-11-17T11:59:00Z'}]) {
    const api = installationClient({appId: 40, installationId: 60, privateKey, now: () => now,
      request: async () => ({token: 'private-token', expires_at: '2026-11-17T13:00:00Z', permissions: {actions: 'write', contents: 'read'}, ...patch})});
    await assert.rejects(api('/repos/'+repository), /scope|expiry/iu);
    await assert.rejects(api('/repos/other/repo'), /canonical repository/iu);
  }
});


test('fresh child visibility retries only GET on the retained run before continuing', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  const reads = new Map();
  const receipts = [];
  let sleeps = 0;
  const api = (path, options) => {
    if (/\/actions\/runs\/\d+$/u.test(path)) {
      const count = (reads.get(path) || 0) + 1;
      reads.set(path, count);
      if (count <= 2) throw Object.assign(new Error('not visible'), {status: 404});
    }
    return f.api(path, options);
  };
  const result = await driveDelivery({...f, api, recordRun: row => receipts.push(row), sleep: async () => { sleeps++; }});
  assert.deepEqual(result.runs.map(row => row.id), [200, 201]);
  assert.equal(f.requests.length, 2);
  assert.deepEqual([...reads.values()], [3, 3]);
  assert.equal(sleeps, 4);
  assert.deepEqual(receipts.map(row => [row.id, row.state]), [[200, 'dispatched'], [200, 'completed'], [201, 'dispatched'], [201, 'completed']]);
});
test('persistent initial 404 is bounded and never redispatches a mutation', async () => {
  const {driveDelivery} = await load();
  const f = fixture();
  let reads = 0;
  const receipts = [];
  const api = (path, options) => {
    if (path.includes('/actions/runs/')) { reads++; throw Object.assign(new Error('not visible'), {status: 404}); }
    return f.api(path, options);
  };
  await assert.rejects(driveDelivery({...f, api, recordRun: row => receipts.push(row)}), /not visible/);
  assert.equal(reads, 5);
  assert.equal(f.requests.length, 1);
  assert.deepEqual(receipts.map(row => [row.id, row.state]), [[200, 'dispatched']]);
});
test('a visible child disappearing and non-404 errors fail without further reads', async () => {
  const {driveDelivery} = await load();
  for (const status of [403, 500, 404]) {
    const f = fixture({mutate: row => ({...row, status: 'queued', conclusion: null})});
    let reads = 0;
    const api = (path, options) => {
      if (path.includes('/actions/runs/')) {
        reads++;
        if (status !== 404 || reads > 1) throw Object.assign(new Error('read rejected'), {status});
      }
      return f.api(path, options);
    };
    await assert.rejects(driveDelivery({...f, api}), /read rejected/);
    assert.equal(reads, status === 404 ? 2 : 1);
    assert.equal(f.requests.length, 1);
  }
});
test('GitHub HTTP errors expose status for safe read classification without response secrets', async () => {
  const {githubRequest} = await load();
  const original = globalThis.fetch;
  globalThis.fetch = async () => ({ok: false, status: 404, json: async () => ({secret: 'do not expose'})});
  try {
    await assert.rejects(githubRequest('/repos/'+repository+'/actions/runs/200', {token: 'private-token'}), error => {
      assert.equal(error.status, 404);
      assert.equal(error.message, 'GitHub request failed: HTTP 404');
      return true;
    });
  } finally { globalThis.fetch = original; }
});
