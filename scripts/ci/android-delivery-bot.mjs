import {writeFileSync} from 'node:fs';
import {sign} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {requireGreenQuality} from './promotion-quality.mjs';
import {validAndroidCoordinate} from './android-operator.mjs';

const REPOSITORY = 'gcsagroup/aegis-browser';
const REPOSITORY_ID = 1348409663;
const PREFIX = '/repos/'+REPOSITORY;
const OPERATIONS = ['Package', 'Package and upload', 'Status', 'Wait', 'Release Wait',
  'Preview GitHub release', 'Publish prerelease', 'Promote to stable'];
const DELIVERY_OPERATION = new Map([
  ['Package', '仅打包 / Package'],
  ['Package and upload', '打包并上传 / Package and upload'],
  ['Status', '查询状态 / Status'],
  ['Wait', '等待状态 / Wait'],
  ['Release Wait', '发布核对 / Release Wait'],
]);
const DELIVERY_PRODUCT = new Map([
  ['Alpha', 'Alpha · 仅内测 / Internal only'],
  ['Beta', 'Beta · 内外测 / Internal and external'],
  ['Release', 'Release · 通用 / Universal'],
]);
const requireValue = (value, message) => { if (!value) throw new Error(message); };
const positiveId = value => Number.isSafeInteger(value) && value > 0;

export async function githubRequest(path, {token, method = 'GET', body} = {}) {
  let response;
  try {
    response = await globalThis.fetch('https://api.github.com'+path, {method, redirect: 'error', signal: globalThis.AbortSignal.timeout(30000),
      headers: {Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2026-03-10', Authorization: 'Bearer '+token,
        ...(body === undefined ? {} : {'Content-Type': 'application/json'})},
      body: body === undefined ? undefined : JSON.stringify(body)});
  } catch { throw new Error('GitHub request outcome unavailable; reconcile before repeating a mutation'); }
  if (!response.ok) throw Object.assign(new Error('GitHub request failed: HTTP '+response.status), {status: response.status});
  if (response.status === 204) return null;
  try {
    const payload = await response.json();
    return payload;
  } catch {
    throw new Error('GitHub response unavailable; reconcile before repeating a mutation');
  }
}

export function installationClient({appId, installationId, privateKey, request = githubRequest, now = Date.now}) {
  requireValue(positiveId(appId) && positiveId(installationId), 'Pinned App and installation IDs required');
  let token, expires = 0;
  return async (path, options = {}) => {
    requireValue(path === PREFIX || path.startsWith(PREFIX+'/'), 'Bot token is limited to the canonical repository');
    if (expires - now() < 60000) {
      const seconds = Math.floor(now()/1000);
      const header = Buffer.from(JSON.stringify({alg: 'RS256', typ: 'JWT'})).toString('base64url');
      const claims = Buffer.from(JSON.stringify({iss: String(appId), iat: seconds-30, exp: seconds+540})).toString('base64url');
      const payload = header+'.'+claims;
      const jwt = payload+'.'+sign('RSA-SHA256', Buffer.from(payload), privateKey).toString('base64url');
      const value = await request('/app/installations/'+installationId+'/access_tokens', {token: jwt, method: 'POST',
        body: {repository_ids: [REPOSITORY_ID], permissions: {actions: 'write', contents: 'read'}}});
      const permissions = value?.permissions;
      const nextExpiry = Date.parse(value?.expires_at);
      requireValue(typeof value?.token === 'string' && value.token.length > 0 && nextExpiry > now()+60000 && nextExpiry <= now()+3660000 &&
        permissions?.actions === 'write' && permissions.contents === 'read' &&
        Object.keys(permissions).every(key => ['actions', 'contents', 'metadata'].includes(key)) &&
        (!permissions.metadata || permissions.metadata === 'read'), 'Installation token scope or expiry differs');
      token = value.token;
      expires = nextExpiry;
    }
    return request(path, {...options, token});
  };
}

function requestInputs(environment) {
  const raw = environment.BOT_INPUTS || '{}';
  requireValue(raw.length <= 10000, 'Bot inputs exceed limit');
  const value = JSON.parse(raw);
  requireValue(value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).every(key => ['operation', 'version', 'build', 'product'].includes(key)) &&
    Object.values(value).every(item => typeof item === 'string'), 'Unknown Bot inputs');
  const {operation = 'Status', version, build, product = 'Alpha'} = value;
  requireValue(OPERATIONS.includes(operation) && ['Alpha', 'Beta', 'Release'].includes(product) &&
    validAndroidCoordinate(version, build), 'Invalid Bot operation or package coordinate');
  if (['Preview GitHub release', 'Publish prerelease', 'Promote to stable'].includes(operation)) {
    requireValue(product === 'Release', 'GitHub release accepts only the Release product');
  }
  return {operation, version, build, product, approved_source_sha: environment.GITHUB_SHA};
}

export async function driveDelivery({environment = process.env, api, quality, recordRun = () => {}, recordReleaseDispatch = () => {},
  sleep = ms => new Promise(resolve => globalThis.setTimeout(resolve, ms)), maxPolls = 240, pollMs = 15000}) {
  requireValue(environment.GITHUB_REPOSITORY === REPOSITORY && /^[0-9a-f]{40}$/u.test(environment.GITHUB_SHA || ''), 'Canonical source required');
  const inputs = requestInputs(environment);
  const policy = JSON.parse(environment.AEGIS_ANDROID_DELIVERY_BOT || 'null');
  requireValue(policy && positiveId(policy.appId) && positiveId(policy.actorId) &&
    typeof policy.slug === 'string' && /^[a-z0-9][a-z0-9-]{0,98}$/u.test(policy.slug), 'Pinned App configuration required');
  const repository = await api(PREFIX);
  requireValue(repository?.id === REPOSITORY_ID && repository.full_name === REPOSITORY && repository.default_branch === 'main', 'Repository identity differs');
  const assertSource = async () => {
    const tip = await api(PREFIX+'/git/ref/heads/main');
    requireValue(tip?.object?.sha === environment.GITHUB_SHA, 'Approved source is no longer current main');
  };
  await assertSource();
  const green = quality || (() => requireGreenQuality(REPOSITORY, 'main', environment.GITHUB_SHA, undefined,
    (_repo, path, options) => api(PREFIX+path, options)));
  requireValue(await green(), 'Exact-source quality has not passed');
  const runs = [];
  const dispatch = async operation => {
    await assertSource();
    const operationLabel = DELIVERY_OPERATION.get(operation);
    const productLabel = DELIVERY_PRODUCT.get(inputs.product);
    requireValue(operationLabel && productLabel, 'Android delivery operation cannot be dispatched');
    let receipt;
    try {
      receipt = await api(PREFIX+'/actions/workflows/android-delivery.yml/dispatches', {method: 'POST', body: {ref: 'main',
        inputs: {...inputs, operation: operationLabel, product: productLabel}}});
    } catch { throw new Error('Dispatch outcome unknown for '+inputs.version+'('+inputs.build+'); reconcile before another request'); }
    requireValue(positiveId(receipt?.workflow_run_id), 'Dispatch run identity unknown; reconcile without retrying');
    const id = receipt.workflow_run_id;
    const url = 'https://github.com/'+REPOSITORY+'/actions/runs/'+id;
    const retained = {id, attempt: 1, operation, url, approvedSourceSha: environment.GITHUB_SHA, version: inputs.version, build: inputs.build};
    recordRun({...retained, state: 'dispatched'});
    let observed = false, invisibleReads = 0;
    for (let poll = 0; poll < maxPolls; poll++) {
      let run;
      try { run = await api(PREFIX+'/actions/runs/'+id); }
      catch (error) {
        if (observed || error.status !== 404 || invisibleReads >= 4 || poll+1 >= maxPolls) throw error;
        invisibleReads++;
        await sleep(pollMs);
        continue;
      }
      observed = true;
      const actor = user => user?.type === 'Bot' && user.id === policy.actorId && user.login === policy.slug+'[bot]';
      requireValue(run?.id === id && run.run_attempt === 1 && run.head_sha === environment.GITHUB_SHA && run.head_branch === 'main' &&
        run.repository?.id === REPOSITORY_ID && run.repository.full_name === REPOSITORY &&
        run.head_repository?.id === REPOSITORY_ID && run.head_repository.full_name === REPOSITORY &&
        run.path === '.github/workflows/android-delivery.yml' && run.event === 'workflow_dispatch' && actor(run.actor) && actor(run.triggering_actor),
        'Child run identity/source/context differs: '+url);
      if (run.status === 'completed') {
        requireValue(run.conclusion === 'success', 'Child delivery failed; reconcile '+url);
        const required = operation === 'Package' ? ['delivery / package']
          : operation === 'Package and upload' ? ['delivery / package', 'delivery / store']
            : ['Wait', 'Release Wait', 'Status'].includes(operation) ? ['delivery / query'] : null;
        if (required) {
          const inventory = await api(PREFIX+'/actions/runs/'+id+'/attempts/1/jobs?per_page=100');
          requireValue(Array.isArray(inventory?.jobs) && inventory.jobs.length <= 100 &&
            inventory.total_count === inventory.jobs.length, 'Incomplete Android jobs inventory; reconcile '+url);
          for (const name of required) {
            const jobs = inventory.jobs.filter(job => job.name === name);
            requireValue(jobs.length === 1 && positiveId(jobs[0].id) && jobs[0].run_id === id && jobs[0].run_attempt === 1 &&
              jobs[0].head_sha === environment.GITHUB_SHA && jobs[0].status === 'completed' && jobs[0].conclusion === 'success',
              'Required Android jobs did not succeed; reconcile '+url);
          }
        }
        recordRun({...retained, state: 'completed', conclusion: 'success'});
        return {id, operation, url};
      }
      await sleep(pollMs);
    }
    throw new Error('Child run still pending; retain and reconcile '+url);
  };
  const releaseOperation = {'Preview GitHub release': 'Preview', 'Publish prerelease': 'Publish prerelease', 'Promote to stable': 'Promote stable'};
  if (Object.hasOwn(releaseOperation, inputs.operation)) {
    requireValue(environment.AEGIS_ANDROID_GITHUB_RELEASE_ENABLED === 'true' && environment.AEGIS_ANDROID_RELEASE_ENABLED === 'true',
      'GitHub release is disabled until the repository release gates are configured');
    const statusRun = await dispatch('Release Wait');
    runs.push(statusRun);
    const operation = releaseOperation[inputs.operation];
    await assertSource();
    const controllerId = Number(environment.GITHUB_RUN_ID);
    const controllerActorId = Number(environment.GITHUB_ACTOR_ID);
    requireValue(positiveId(controllerId) && positiveId(controllerActorId), 'Human Admin controller identity required');
    const releaseInputs = {operation, release_type: 'stable', version: inputs.version, build: inputs.build,
      status_run_id: String(statusRun.id), controller_run_id: String(controllerId),
      controller_actor_id: String(controllerActorId), controller_actor_login: environment.GITHUB_ACTOR,
      approved_source_sha: environment.GITHUB_SHA};
    let receipt;
    try {
      receipt = await api(PREFIX+'/actions/workflows/android-github-release.yml/dispatches',
        {method: 'POST', body: {ref: 'main', inputs: releaseInputs}});
    } catch { throw new Error('Release workflow dispatch outcome unknown; reconcile before another request'); }
    requireValue(positiveId(receipt?.workflow_run_id), 'Release workflow run identity unknown; reconcile without redispatch');
    const id = receipt.workflow_run_id;
    const url = 'https://github.com/'+REPOSITORY+'/actions/runs/'+id;
    const retained = {id, attempt: 1, operation, url, approvedSourceSha: environment.GITHUB_SHA,
      version: inputs.version, build: inputs.build, state: 'dispatched'};
    recordRun(retained);
    recordReleaseDispatch({childRunId: id, inputs: releaseInputs});
    runs.push(retained);
    return {sourceSha: environment.GITHUB_SHA, version: inputs.version, build: inputs.build, runs};
  }
  runs.push(await dispatch(inputs.operation));
  if (inputs.operation === 'Package and upload') runs.push(await dispatch('Wait'));
  return {sourceSha: environment.GITHUB_SHA, version: inputs.version, build: inputs.build, runs};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    requireValue(process.argv.length === 2, 'This controller takes inputs only through its environment');
    const policy = JSON.parse(process.env.AEGIS_ANDROID_DELIVERY_BOT || 'null');
    const api = installationClient({appId: policy?.appId, installationId: Number(process.env.AEGIS_ANDROID_BOT_INSTALLATION_ID),
      privateKey: process.env.AEGIS_ANDROID_BOT_PRIVATE_KEY});
    const recordRun = receipt => {
      console.log('- '+receipt.operation+' · '+receipt.state+' · '+receipt.version+'('+receipt.build+') · attempt '+receipt.attempt+
        ' · approved `'+receipt.approvedSourceSha+'`: [run '+receipt.id+']('+receipt.url+')');
    };
    const result = await driveDelivery({api, recordRun, recordReleaseDispatch: receipt => {
      const path = process.env.RELEASE_DISPATCH_RECEIPT;
      requireValue(path, 'Controller dispatch receipt path is required');
      // eslint-disable-next-line security/detect-non-literal-fs-filename -- The protected controller sets the receipt path in runner.temp and creates it exclusively.
      writeFileSync(path, JSON.stringify(receipt), {flag: 'wx', mode: 0o600});
    }});
    console.log(JSON.stringify(result));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
