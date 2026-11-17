import {sign} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {requireGreenQuality} from './promotion-quality.mjs';

const REPOSITORY = 'gcsagroup/aegis-browser';
const REPOSITORY_ID = 1348409663;
const PREFIX = '/repos/'+REPOSITORY;
const OPERATIONS = ['Package', 'Package and upload', 'Draft', 'Status', 'Wait'];
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
  try { return response.status === 204 ? null : await response.json(); }
  catch { throw new Error('GitHub response unavailable; reconcile before repeating a mutation'); }
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
    Object.keys(value).every(key => ['operation', 'version', 'build', 'product', 'signing_mode'].includes(key)) &&
    Object.values(value).every(item => typeof item === 'string'), 'Unknown Bot inputs');
  const {operation = 'Status', version, build, product = 'Beta', signing_mode = 'cloud'} = value;
  const parts = (version || '').split('.');
  const validVersion = [2, 3].includes(parts.length) && parts.every(part => part.length > 0 && part.length <= 10 && !/[^0-9]/u.test(part));
  requireValue(OPERATIONS.includes(operation) && ['Alpha', 'Beta', 'Release'].includes(product) &&
    ['cloud', 'manual'].includes(signing_mode) && validVersion &&
    /^[1-9][0-9]{0,9}$/u.test(build || ''), 'Invalid Bot operation or package coordinate');
  return {operation, version, build, product, signing_mode, private_beta: 'no', approved_source_sha: environment.GITHUB_SHA};
}

export async function driveDelivery({environment = process.env, api, quality, recordRun = () => {}, sleep = ms => new Promise(resolve => globalThis.setTimeout(resolve, ms)), maxPolls = 240, pollMs = 15000}) {
  requireValue(environment.GITHUB_REPOSITORY === REPOSITORY && /^[0-9a-f]{40}$/u.test(environment.GITHUB_SHA || ''), 'Canonical source required');
  const inputs = requestInputs(environment);
  const policy = JSON.parse(environment.AEGIS_IOS_DELIVERY_BOT || 'null');
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
    const workflow = operation === 'Draft' ? 'ios-delivery-full' : 'ios-delivery';
    let receipt;
    try {
      receipt = await api(PREFIX+'/actions/workflows/'+workflow+'.yml/dispatches', {method: 'POST', body: {ref: 'main', inputs: {...inputs, operation}}});
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
        // A fresh dispatch receipt can precede visibility of its exact run.
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
        run.path === '.github/workflows/'+workflow+'.yml' && run.event === 'workflow_dispatch' && actor(run.actor) && actor(run.triggering_actor),
      'Child run identity/source/context differs: '+url);
      if (run.status === 'completed') {
        requireValue(run.conclusion === 'success', 'Child delivery failed; reconcile '+url);
        recordRun({...retained, state: 'completed', conclusion: 'success'});
        return {id, operation, url};
      }
      await sleep(pollMs);
    }
    throw new Error('Child run still pending; retain and reconcile '+url);
  };
  runs.push(await dispatch(inputs.operation));
  if (inputs.operation === 'Package and upload') runs.push(await dispatch('Wait'));
  return {sourceSha: environment.GITHUB_SHA, version: inputs.version, build: inputs.build, runs};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    requireValue(process.argv.length === 2, 'This controller takes inputs only through its environment');
    const policy = JSON.parse(process.env.AEGIS_IOS_DELIVERY_BOT || 'null');
    const api = installationClient({appId: policy?.appId, installationId: Number(process.env.AEGIS_IOS_BOT_INSTALLATION_ID), privateKey: process.env.AEGIS_IOS_BOT_PRIVATE_KEY});
    const recordRun = receipt => {
      console.log('- '+receipt.operation+' · '+receipt.state+' · '+receipt.version+'('+receipt.build+') · attempt '+receipt.attempt+
        ' · approved `'+receipt.approvedSourceSha+'`: [run '+receipt.id+']('+receipt.url+')');
      console.log(JSON.stringify({type: 'ios-delivery-bot-receipt', ...receipt}));
    };
    const result = await driveDelivery({api, recordRun});
    console.log(JSON.stringify(result));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
