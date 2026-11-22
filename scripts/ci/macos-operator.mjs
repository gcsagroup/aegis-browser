#!/usr/bin/env node
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {isDeepStrictEqual} from 'node:util';

const UPSTREAM = 'gcsagroup/aegis-browser';
const UPSTREAM_ID = '1348409663';
const FORK = 'quinn521/aegis-browser';
const FORK_ID = '1363949860';
const ALLOWED = new Map([[FORK, FORK_ID], [UPSTREAM, UPSTREAM_ID]]);
const WORKFLOWS = new Map([
  ['delivery', '.github/workflows/macos-delivery.yml'],
  ['controller', '.github/workflows/macos-delivery-bot.yml'],
  ['bot-dmg', '.github/workflows/macos-delivery.yml'],
  ['dmg', '.github/workflows/macos-dmg.yml'],
]);
const COMPONENT = /^(?:0|[1-9][0-9]{0,9})$/u;
const DMG_INPUT_KEYS = 'app_path,approved_source_sha,arch,controller_actor_id,controller_actor_login,controller_run_id,operation,product_checkout,product_sha,signing_mode,version';
const RECEIPT_NAME = 'aegis-macos-dmg-dispatch.json';

class OperatorError extends Error {}
function requireValue(value, message) { if (!value) throw new OperatorError(message); }
function validVersion(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 44) return false;
  const parts = value.split('.');
  return parts.length >= 2 && parts.length <= 4 && parts.every(part => COMPONENT.test(part));
}
function validUser(user) {
  return user && Number.isSafeInteger(user.id) && user.id > 0 && typeof user.login === 'string' && /^[A-Za-z0-9[\]-]{1,100}$/u.test(user.login);
}
function sameUser(a, b) { return validUser(a) && validUser(b) && a.id === b.id && a.login.toLowerCase() === b.login.toLowerCase(); }
function positiveInteger(value) {
  requireValue(typeof value === 'string' && /^[1-9][0-9]{0,15}$/u.test(value) && Number.isSafeInteger(Number(value)), 'Invalid Actions run identity');
  return Number(value);
}
function repositoryName(repository) {
  requireValue(typeof repository === 'string' && repository.split('/').length === 2 && repository.split('/').every(part => /^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}$/u.test(part) && !part.includes('..')), 'Invalid repository identity');
  return repository;
}

async function readGithub(path, token) {
  const response = await globalThis.fetch('https://api.github.com' + path, {method: 'GET', redirect: 'error', signal: globalThis.AbortSignal.timeout(30000),
    headers: {Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', Authorization: `Bearer ${token}`}});
  requireValue(response.ok, 'Unable to verify GitHub Admin permissions');
  return response.json();
}
const repositoryApi = (repository, path, {token}) => readGithub('/repos/' + repositoryName(repository) + path, token);

async function administratorInventory(repository, token, api) {
  const users = [];
  const ids = new Set();
  for (let page = 1; page <= 20; page++) {
    const batch = await api(repository, `/collaborators?affiliation=all&permission=admin&per_page=100&page=${page}`, {token});
    requireValue(Array.isArray(batch) && batch.length <= 100, 'Invalid Admin permissions inventory');
    for (const user of batch) {
      requireValue(validUser(user) && user.permissions?.admin === true && !ids.has(user.id), 'Invalid or duplicate Admin permissions inventory');
      ids.add(user.id);
      users.push(user);
    }
    if (batch.length < 100) return users;
  }
  throw new OperatorError('Incomplete Admin permissions inventory pagination');
}

function parseDmgInputs(environment) {
  let inputs;
  try { inputs = JSON.parse(environment.MACOS_DMG_INPUTS || '{}'); }
  catch { throw new OperatorError('Invalid DMG Bot inputs'); }
  requireValue(inputs && typeof inputs === 'object' && !Array.isArray(inputs) &&
    Object.keys(inputs).sort().join(',') === DMG_INPUT_KEYS &&
    Object.values(inputs).every(item => typeof item === 'string'), 'Invalid DMG Bot inputs');
  requireValue(inputs.operation === 'Rebuild DMG' && inputs.arch === 'arm64' && inputs.signing_mode === 'ad-hoc' &&
    inputs.app_path === '' && inputs.product_checkout === '' && inputs.product_sha === '' &&
    inputs.approved_source_sha === environment.GITHUB_SHA && validVersion(inputs.version) &&
    /^[1-9][0-9]{0,15}$/u.test(inputs.controller_run_id) && /^[1-9][0-9]{0,15}$/u.test(inputs.controller_actor_id) &&
    /^[A-Za-z0-9-]{1,39}$/u.test(inputs.controller_actor_login) &&
    inputs.controller_actor_login === environment.CONTROLLER_ACTOR_LOGIN,
  'DMG Bot only accepts the approved arm64 ad-hoc rebuild');
  return inputs;
}

async function requirePinnedDeliveryBot(user, environment, identityApi, token) {
  let policy;
  try { policy = JSON.parse(environment.AEGIS_IOS_DELIVERY_BOT || 'null'); }
  catch { throw new OperatorError('Pinned Bot App configuration required'); }
  requireValue(policy && Object.keys(policy).sort().join(',') === 'actorId,appId,slug' &&
    Number.isSafeInteger(policy.appId) && policy.appId > 0 && Number.isSafeInteger(policy.actorId) && policy.actorId > 0 &&
    typeof policy.slug === 'string' && /^[a-z0-9][a-z0-9-]{0,98}$/u.test(policy.slug), 'Pinned Bot App configuration required');
  requireValue(user.type === 'Bot' && user.id === policy.actorId && user.login === policy.slug+'[bot]', 'Bot actor identity differs');
  const app = await identityApi('/apps/'+policy.slug, token);
  const actor = await identityApi('/users/'+encodeURIComponent(user.login), token);
  requireValue(app?.id === policy.appId && app.slug === policy.slug && actor?.type === 'Bot' && sameUser(actor, user),
    'Live Bot App identity differs');
  return policy;
}

async function requireMacosDmgBot(user, run, environment, identityApi, token) {
  requireValue(run.path === WORKFLOWS.get('bot-dmg') && run.event === 'workflow_dispatch' && run.head_branch === 'main',
    'Bot requires a canonical main DMG dispatch');
  let policy;
  try { policy = JSON.parse(environment.AEGIS_IOS_DELIVERY_BOT || 'null'); }
  catch { throw new OperatorError('Pinned Bot App configuration required'); }
  requireValue(policy && Object.keys(policy).sort().join(',') === 'actorId,appId,slug' &&
    Number.isSafeInteger(policy.appId) && policy.appId > 0 && Number.isSafeInteger(policy.actorId) && policy.actorId > 0 &&
    typeof policy.slug === 'string' && /^[a-z0-9][a-z0-9-]{0,98}$/u.test(policy.slug), 'Pinned Bot App configuration required');
  requireValue(user.type === 'Bot' && user.id === policy.actorId && user.login === policy.slug+'[bot]', 'Bot actor identity differs');
  const inputs = parseDmgInputs(environment);
  const app = await identityApi('/apps/'+policy.slug, token);
  const actor = await identityApi('/users/'+encodeURIComponent(user.login), token);
  requireValue(app?.id === policy.appId && app.slug === policy.slug && actor?.type === 'Bot' && sameUser(actor, user),
    'Live Bot App identity differs');
  return inputs;
}

function readDispatchReceipt(repository, token, artifact) {
  let bytes;
  try {
    bytes = execFileSync('gh', ['api', 'repos/'+repository+'/actions/artifacts/'+artifact.id+'/zip'],
      {env: {...process.env, GH_TOKEN: token}, timeout: 30000, maxBuffer: 128 * 1024});
  } catch { throw new OperatorError('Controller dispatch receipt could not be read'); }
  requireValue('sha256:'+createHash('sha256').update(bytes).digest('hex') === artifact.digest,
    'Controller dispatch receipt artifact digest differs');
  const directory = mkdtempSync(join(tmpdir(), 'aegis-macos-dispatch-'));
  try {
    const zip = join(directory, 'receipt.zip');
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- This fixed filename belongs to a freshly created private receipt directory.
    writeFileSync(zip, bytes, {mode: 0o600});
    requireValue(execFileSync('unzip', ['-Z1', zip], {encoding: 'utf8', timeout: 5000, maxBuffer: 8192}).trim() === RECEIPT_NAME,
      'Controller dispatch artifact must contain exactly one receipt');
    return JSON.parse(execFileSync('unzip', ['-p', zip, RECEIPT_NAME], {encoding: 'utf8', timeout: 5000, maxBuffer: 8192}));
  } catch (error) {
    if (error instanceof OperatorError) throw error;
    throw new OperatorError('Controller dispatch receipt could not be read');
  } finally {
    rmSync(directory, {recursive: true});
  }
}

export async function requireMacosControllerAuthorization({environment = process.env, api = repositoryApi, readReceipt = readDispatchReceipt,
  sleep = ms => new Promise(resolve => globalThis.setTimeout(resolve, ms)), maxPolls = 24, inputs} = {}) {
  const repository = repositoryName(environment.GITHUB_REPOSITORY || UPSTREAM);
  const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
  const parsed = inputs || parseDmgInputs(environment);
  const runId = Number(parsed.controller_run_id);
  const actorId = Number(parsed.controller_actor_id);
  requireValue(ALLOWED.has(repository) && token && Number.isSafeInteger(runId) && runId > 0 &&
    Number.isSafeInteger(actorId) && actorId > 0 && parsed.approved_source_sha === environment.GITHUB_SHA,
  'Exact human Admin controller/source identity required');
  const repositoryId = Number(ALLOWED.get(repository));
  let run;
  for (let poll = 0; poll < maxPolls; poll++) {
    run = await api(repository, `/actions/runs/${runId}`, {token});
    requireValue(run?.id === runId && run.run_attempt === 1 && run.path === WORKFLOWS.get('controller') &&
      run.event === 'workflow_dispatch' && run.head_branch === 'main' && run.head_sha === environment.GITHUB_SHA &&
      run.repository?.id === repositoryId && run.repository?.full_name === repository &&
      run.head_repository?.id === repositoryId && run.head_repository?.full_name === repository,
    'Parent controller run identity/source/context differs');
    if (run.status === 'completed') break;
    await sleep(5000);
  }
  requireValue(run?.status === 'completed' && run.conclusion === 'success',
    'Parent Admin controller has not completed successfully');
  requireValue(run.display_title === `macOS Bot Package DMG ${parsed.version}`,
    'Parent Admin controller does not identify the requested DMG version');
  const original = run.actor;
  const rerunner = run.triggering_actor;
  requireValue(validUser(original) && validUser(rerunner) && original.type !== 'Bot' && rerunner.type !== 'Bot' &&
    original.id === actorId && original.login === environment.CONTROLLER_ACTOR_LOGIN,
  'Controller initiator must be the original human Admin');
  const admins = await administratorInventory(repository, token, api);
  const principals = sameUser(original, rerunner) ? [original] : [original, rerunner];
  requireValue(principals.every(user => admins.some(admin => sameUser(admin, user))),
    'Original controller actor and rerunner must both remain repository Admins');
  const inventory = await api(repository, `/actions/runs/${runId}/attempts/1/jobs?per_page=100`, {token});
  requireValue(Array.isArray(inventory?.jobs) && inventory.jobs.length <= 100 &&
    inventory.total_count === inventory.jobs.length, 'Incomplete parent controller job inventory');
  const controllerJobs = inventory.jobs.filter(job => job.name === 'controller');
  requireValue(controllerJobs.length === 1 && controllerJobs[0].run_id === runId &&
    controllerJobs[0].run_attempt === 1 && controllerJobs[0].head_sha === environment.GITHUB_SHA &&
    controllerJobs[0].status === 'completed' && controllerJobs[0].conclusion === 'success',
  'Human Admin controller job did not succeed');
  const steps = controllerJobs[0].steps;
  const adminSteps = Array.isArray(steps) ? steps.filter(step => step.name === 'Require current administrator for this controller request') : [];
  requireValue(adminSteps.length === 1 && adminSteps[0].status === 'completed' && adminSteps[0].conclusion === 'success',
    'Human Admin controller authorization step did not succeed');
  const receiptArtifacts = await api(repository, `/actions/runs/${runId}/artifacts?per_page=100`, {token});
  requireValue(Array.isArray(receiptArtifacts?.artifacts) && receiptArtifacts.total_count === receiptArtifacts.artifacts.length &&
    receiptArtifacts.artifacts.length <= 100, 'Incomplete controller artifact inventory');
  const matches = receiptArtifacts.artifacts.filter(row => row.name === `macos-dmg-dispatch-${runId}-1`);
  requireValue(matches.length === 1 && Number.isSafeInteger(matches[0].id) && matches[0].id > 0 &&
    matches[0].expired === false && /^sha256:[0-9a-f]{64}$/u.test(matches[0].digest || ''),
  'Exact sealed controller dispatch receipt required');
  const receipt = await readReceipt(repository, token, matches[0]);
  requireValue(receipt?.childRunId === positiveInteger(environment.GITHUB_RUN_ID) &&
    isDeepStrictEqual(receipt.inputs, parsed), 'Controller dispatch receipt does not identify this child and its inputs');
  return {authorized: true, controllerRunId: runId, principals: principals.map(({id, login}) => ({id, login}))};
}

export async function requireMacosAdministrator({environment = process.env, api = repositoryApi, identityApi = readGithub, context = 'delivery',
  readReceipt = readDispatchReceipt, sleep = ms => new Promise(resolve => globalThis.setTimeout(resolve, ms)), maxPolls = 24} = {}) {
  try {
    const repository = environment.GITHUB_REPOSITORY || '';
    const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
    requireValue(ALLOWED.has(repository) && token && WORKFLOWS.has(context), 'macOS delivery is limited to the fork and upstream repository');
    requireValue(environment.GITHUB_EVENT_NAME === 'workflow_dispatch', 'macOS delivery only runs from a manual dispatch');
    const metadata = await api(repository, '', {token});
    requireValue(metadata?.full_name === repository && Number.isSafeInteger(metadata.id) && metadata.id > 0, 'Repository identity could not be verified');
    const pinned = ALLOWED.get(repository);
    if (pinned) requireValue(String(metadata.id) === pinned, 'Canonical repository identity changed');
    requireValue(environment.GITHUB_ACTIONS === 'true' && String(metadata.id) === environment.GITHUB_REPOSITORY_ID, 'Runtime repository identity changed');
    const id = positiveInteger(environment.GITHUB_RUN_ID);
    const attempt = positiveInteger(environment.GITHUB_RUN_ATTEMPT);
    requireValue(/^[0-9a-f]{40}$/u.test(environment.GITHUB_SHA || ''), 'Full run source identity required');
    const run = await api(repository, `/actions/runs/${id}`, {token});
    requireValue(run?.id === id && run.run_attempt === attempt && run.head_sha === environment.GITHUB_SHA, 'Actions run/source/attempt identity changed');
    requireValue(run.repository?.full_name === repository && run.path === WORKFLOWS.get(context) && run.event === 'workflow_dispatch', 'Actions workflow context changed');
    requireValue(environment.GITHUB_REF === 'refs/heads/' + run.head_branch, 'Actions run/ref context changed');
    requireValue(validUser(run.actor) && validUser(run.triggering_actor), 'Actions actor identity is incomplete');
    requireValue(run.actor.login === environment.GITHUB_ACTOR && String(run.actor.id) === environment.GITHUB_ACTOR_ID &&
      run.triggering_actor.login === environment.GITHUB_TRIGGERING_ACTOR, 'Actions original/triggering actor identity changed');
    const principals = [run.actor];
    if (!sameUser(run.actor, run.triggering_actor)) principals.push(run.triggering_actor);
    if (context === 'controller' || context === 'bot-dmg' || context === 'dmg') {
      requireValue(ALLOWED.has(repository) && String(metadata.id) === ALLOWED.get(repository),
        'Privileged macOS DMG delivery starts on the fork, then syncs to upstream');
      requireValue(attempt === 1 && run.head_branch === 'main', 'macOS DMG Bot requires main on the first attempt');
      requireValue(run.repository?.id === metadata.id && run.head_repository?.full_name === repository && run.head_repository?.id === metadata.id,
        'Actions repository context changed');
    }
    if (context === 'dmg' && (run.actor.type === 'Bot' || run.triggering_actor.type === 'Bot')) {
      requireValue(run.actor.type === 'Bot' && run.triggering_actor.type === 'Bot' && sameUser(run.actor, run.triggering_actor),
        'DMG delivery requires the pinned App as both child actors on attempt one');
      await requirePinnedDeliveryBot(run.actor, environment, identityApi, token);
      return {authorized: true, repository, mode: 'dmg_bot', runId: id, attempt,
        principals: principals.map(({id: userId, login}) => ({id: userId, login}))};
    }
    if (context === 'bot-dmg') {
      requireValue(run.actor.type === 'Bot' && run.triggering_actor.type === 'Bot' && sameUser(run.actor, run.triggering_actor),
        'DMG rebuild requires the pinned App as both child actors on attempt one');
      const inputs = await requireMacosDmgBot(run.actor, run, environment, identityApi, token);
      const controller = await requireMacosControllerAuthorization({environment, api, readReceipt, sleep, maxPolls, inputs});
      return {authorized: true, repository, mode: 'dmg_bot', runId: id, attempt, controller,
        principals: principals.map(({id: userId, login}) => ({id: userId, login}))};
    }
    if (context === 'controller') {
      requireValue(principals.every(user => user.type !== 'Bot'), 'Repository Admin grant required; the delivery Bot cannot start this controller');
    }
    const admins = await administratorInventory(repository, token, api);
    requireValue(principals.every(user => admins.some(admin => sameUser(admin, user))), 'Repository Admin grant required for original actor and rerunner');
    return {authorized: true, repository, principals: principals.map(({id: userId, login}) => ({id: userId, login}))};
  } catch (error) {
    if (error instanceof OperatorError) throw error;
    throw new OperatorError('Unable to verify repository Admin authorization');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length !== 4 || process.argv[2] !== '--context' || !WORKFLOWS.has(process.argv[3])) {
      throw new OperatorError('Usage: macos-operator.mjs --context delivery|controller|bot-dmg|dmg');
    }
    console.log(JSON.stringify(await requireMacosAdministrator({context: process.argv[3]})));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
