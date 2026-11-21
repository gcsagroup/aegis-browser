import {pathToFileURL} from 'node:url';
import {appendFileSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {isDeepStrictEqual} from 'node:util';

const UPSTREAM = 'gcsagroup/aegis-browser';
const UPSTREAM_ID = '1348409663';
const WORKFLOWS = new Map([
  ['delivery', ['.github/workflows/android-delivery.yml', '.github/workflows/android-delivery-full.yml']],
  ['controller', '.github/workflows/android-delivery-bot.yml'],
  ['github-release', '.github/workflows/android-github-release.yml'],
]);
class OperatorError extends Error {}
function requireValue(value, message) { if (!value) throw new OperatorError(message); }
function validUser(user) {
  return user && Number.isSafeInteger(user.id) && user.id > 0 && typeof user.login === 'string' && /^[A-Za-z0-9[\]-]{1,100}$/u.test(user.login);
}
function sameUser(a, b) { return validUser(a) && validUser(b) && a.id === b.id && a.login.toLowerCase() === b.login.toLowerCase(); }
function positiveInteger(value) {
  requireValue(typeof value === 'string' && /^[1-9][0-9]{0,15}$/u.test(value) && Number.isSafeInteger(Number(value)), 'Invalid Actions run/attempt identity');
  return Number(value);
}
export function validAndroidCoordinate(version, build) {
  if (typeof version !== 'string' || typeof build !== 'string') return false;
  const parts = version.split('.');
  if (parts.length !== 4 || !parts.every(part => /^(?:0|[1-9][0-9]{0,9})$/u.test(part))) return false;
  const number = Number(parts[3]);
  if (!Number.isSafeInteger(number) || number >= 10000 || !/^[1-9][0-9]{0,9}$/u.test(build)) return false;
  const code = Number(build);
  return Number.isSafeInteger(code) && code >= 1 && code <= 2100000000 && code % 10000 === number;
}
async function readGithub(path, token) {
  const response = await globalThis.fetch('https://api.github.com'+path, {method: 'GET', redirect: 'error', signal: globalThis.AbortSignal.timeout(30000),
    headers: {Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', Authorization: `Bearer ${token}`}});
  requireValue(response.ok, 'Unable to verify GitHub Admin permissions');
  return response.json();
}
const repositoryApi = (repository, path, {token}) => readGithub('/repos/'+repository+path, token);

async function administratorInventory(repository, token, api) {
  try {
    const users = [];
    const ids = new Set();
    for (let page = 1; page <= 20; page++) {
      const batch = await api(repository, `/collaborators?affiliation=all&permission=admin&per_page=100&page=${page}`, {token});
      requireValue(Array.isArray(batch) && batch.length <= 100, 'Invalid Admin permissions inventory');
      for (const user of batch) {
        requireValue(validUser(user) && user.permissions?.admin === true && !ids.has(user.id), 'Invalid or duplicate Admin permissions inventory');
        ids.add(user.id); users.push(user);
      }
      if (batch.length < 100) return users;
    }
    throw new OperatorError('Incomplete Admin permissions inventory pagination');
  } catch (error) {
    if (error instanceof OperatorError) throw error;
    throw new OperatorError('Unable to verify repository Admin authorization');
  }
}

function botPolicy(environment) {
  let policy;
  try { policy = JSON.parse(environment.AEGIS_ANDROID_DELIVERY_BOT || 'null'); }
  catch { throw new OperatorError('Invalid Android Bot configuration'); }
  requireValue(policy && Object.keys(policy).sort().join(',') === 'actorId,appId,slug' &&
    Number.isSafeInteger(policy.appId) && policy.appId > 0 && Number.isSafeInteger(policy.actorId) && policy.actorId > 0 &&
    typeof policy.slug === 'string' && /^[a-z0-9][a-z0-9-]{0,98}$/u.test(policy.slug), 'Pinned Android Bot App configuration required');
  return policy;
}

async function requireDeliveryBot(user, run, environment, identityApi, token, context) {
  const releaseContext = context === 'github-release';
  requireValue((releaseContext ? run.path === '.github/workflows/android-github-release.yml' :
    context === 'delivery' && WORKFLOWS.get('delivery').includes(run.path)) &&
    run.event === 'workflow_dispatch' && run.head_branch === 'main', 'Bot requires a canonical main Android dispatch');
  const policy = botPolicy(environment);
  let inputs;
  try { inputs = JSON.parse((releaseContext ? environment.RELEASE_INPUTS : environment.ANDROID_DELIVERY_INPUTS) || '{}'); }
  catch { throw new OperatorError('Invalid Android Bot inputs'); }
  requireValue(user.type === 'Bot' && user.id === policy.actorId && user.login === policy.slug+'[bot]', 'Bot actor identity differs');
  const releaseInputsValid = inputs && typeof inputs === 'object' && !Array.isArray(inputs) &&
    Object.keys(inputs).sort().join(',') === 'approved_source_sha,build,controller_actor_id,controller_actor_login,controller_run_id,operation,release_type,status_run_id,version' &&
    ['Preview', 'Publish prerelease', 'Promote stable'].includes(inputs.operation) && inputs.release_type === 'stable' &&
    validAndroidCoordinate(inputs.version, inputs.build) &&
    /^[1-9][0-9]{0,15}$/u.test(inputs.status_run_id || '') &&
    /^[1-9][0-9]{0,15}$/u.test(inputs.controller_run_id || '') &&
    /^[1-9][0-9]{0,15}$/u.test(inputs.controller_actor_id || '') &&
    /^[A-Za-z0-9-]{1,39}$/u.test(inputs.controller_actor_login || '');
  const deliveryInputsValid = inputs && typeof inputs === 'object' && !Array.isArray(inputs) &&
    inputs.approved_source_sha === environment.GITHUB_SHA && validAndroidCoordinate(inputs.version, inputs.build) &&
    ['Package', 'Package and upload', 'Status', 'Wait', 'Release Wait', '仅打包 / Package', '打包并上传 / Package and upload',
      '查询状态 / Status', '等待状态 / Wait', '发布核对 / Release Wait'].includes(inputs.operation);
  requireValue(inputs && inputs.approved_source_sha === environment.GITHUB_SHA &&
    (releaseContext ? releaseInputsValid : deliveryInputsValid), 'Bot operation and approved source inputs required');
  const app = await identityApi('/apps/'+policy.slug, token);
  const actor = await identityApi('/users/'+encodeURIComponent(user.login), token);
  requireValue(app?.id === policy.appId && app.slug === policy.slug && actor?.type === 'Bot' && sameUser(actor, user),
    'Live Bot App identity differs');
}

function readDispatchReceipt(repository, token, artifact) {
  const bytes = execFileSync('gh', ['api', 'repos/'+repository+'/actions/artifacts/'+artifact.id+'/zip'],
    {env: {...process.env, GH_TOKEN: token}, timeout: 30000, maxBuffer: 128 * 1024});
  requireValue('sha256:'+createHash('sha256').update(bytes).digest('hex') === artifact.digest, 'Controller dispatch receipt artifact digest differs');
  const directory = mkdtempSync(join(tmpdir(), 'aegis-android-dispatch-'));
  try {
    const zip = join(directory, 'receipt.zip');
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- This fixed filename belongs to a freshly created private receipt directory.
    writeFileSync(zip, bytes, {mode: 0o600});
    const name = 'aegis-android-release-dispatch.json';
    requireValue(execFileSync('unzip', ['-Z1', zip], {encoding: 'utf8', timeout: 5000, maxBuffer: 8192}).trim() === name,
      'Controller dispatch artifact must contain exactly one receipt');
    return JSON.parse(execFileSync('unzip', ['-p', zip, name], {encoding: 'utf8', timeout: 5000, maxBuffer: 8192}));
  } finally { rmSync(directory, {recursive: true}); }
}

export async function requireReleaseControllerAuthorization({environment = process.env, api = repositoryApi, readReceipt = readDispatchReceipt,
  sleep = ms => new Promise(resolve => globalThis.setTimeout(resolve, ms)), maxPolls = 12} = {}) {
  const repository = environment.GITHUB_REPOSITORY || UPSTREAM;
  const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
  let inputs;
  try { inputs = JSON.parse(environment.RELEASE_INPUTS || '{}'); }
  catch { throw new OperatorError('Invalid release workflow inputs'); }
  requireValue(inputs && ['Preview', 'Publish prerelease', 'Promote stable'].includes(inputs.operation) && inputs.release_type === 'stable',
    'Controller release operation/channel mismatch');
  const runId = Number(inputs.controller_run_id);
  const actorId = Number(inputs.controller_actor_id);
  requireValue(repository === UPSTREAM && token && Number.isSafeInteger(runId) && runId > 0 &&
    Number.isSafeInteger(actorId) && actorId > 0 && inputs.approved_source_sha === environment.GITHUB_SHA,
    'Exact human Admin controller/source identity required');
  let run;
  for (let poll = 0; poll < maxPolls; poll++) {
    run = await api(repository, `/actions/runs/${runId}`, {token});
    requireValue(run?.id === runId && run.run_attempt === 1 && run.path === '.github/workflows/android-delivery-bot.yml' &&
      run.event === 'workflow_dispatch' && run.head_branch === 'main' && run.head_sha === environment.GITHUB_SHA &&
      run.repository?.id === Number(UPSTREAM_ID) && run.repository?.full_name === repository, 'Parent controller run identity/source/context differs');
    if (run.status === 'completed') break;
    await sleep(5000);
  }
  requireValue(run?.status === 'completed' && run.conclusion === 'success', 'Parent Admin controller has not completed successfully');
  const controllerOperation = {Preview: 'Preview GitHub release', 'Publish prerelease': 'Publish prerelease', 'Promote stable': 'Promote to stable'}[inputs.operation];
  requireValue(run.display_title === `Android Bot ${controllerOperation} ${inputs.version}(${inputs.build})`,
    'Parent Admin controller does not identify the requested operation/version/build');
  const original = run.actor;
  const rerunner = run.triggering_actor;
  requireValue(validUser(original) && validUser(rerunner) && original.type !== 'Bot' && rerunner.type !== 'Bot' &&
    original.id === actorId && original.login === environment.CONTROLLER_ACTOR_LOGIN, 'Controller initiator must be the original human Admin');
  const admins = await administratorInventory(repository, token, api);
  const principals = sameUser(original, rerunner) ? [original] : [original, rerunner];
  requireValue(principals.every(user => admins.some(admin => sameUser(admin, user))),
    'Original controller actor and rerunner must both remain repository Admins');
  const inventory = await api(repository, `/actions/runs/${runId}/attempts/1/jobs?per_page=100`, {token});
  requireValue(Array.isArray(inventory?.jobs) && inventory.jobs.length <= 100 && inventory.total_count === inventory.jobs.length,
    'Incomplete parent controller job inventory');
  const controllerJobs = inventory.jobs.filter(job => job.name === 'controller');
  requireValue(controllerJobs.length === 1 && controllerJobs[0].conclusion === 'success', 'Human Admin controller job did not succeed');
  const steps = controllerJobs[0].steps;
  const adminSteps = Array.isArray(steps) ? steps.filter(step => step.name === 'Require current administrator for this controller request') : [];
  requireValue(adminSteps.length === 1 && adminSteps[0].conclusion === 'success', 'Human Admin controller authorization step did not succeed');
  const receiptArtifacts = await api(repository, `/actions/runs/${runId}/artifacts?per_page=100`, {token});
  requireValue(Array.isArray(receiptArtifacts?.artifacts) && receiptArtifacts.total_count === receiptArtifacts.artifacts.length,
    'Incomplete controller artifact inventory');
  const matches = receiptArtifacts.artifacts.filter(row => row.name === `android-github-release-dispatch-${runId}-1`);
  requireValue(matches.length === 1 && matches[0].expired === false && /^sha256:[0-9a-f]{64}$/u.test(matches[0].digest || ''),
    'Exact sealed controller dispatch receipt required');
  const receipt = await readReceipt(repository, token, matches[0]);
  requireValue(receipt?.childRunId === positiveInteger(environment.GITHUB_RUN_ID) && isDeepStrictEqual(receipt.inputs, inputs),
    'Controller dispatch receipt does not identify this child and its inputs');
  return {authorized: true, controllerRunId: runId, principals: principals.map(({id, login}) => ({id, login}))};
}

export async function requireAndroidAdministrator({environment = process.env, api = repositoryApi, identityApi = readGithub, context = 'delivery'} = {}) {
  try {
    const repository = environment.GITHUB_REPOSITORY || '';
    const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
    requireValue(token && WORKFLOWS.has(context) && repository === UPSTREAM, 'Privileged Android delivery repository must be canonical upstream');
    const metadata = await api(repository, '', {token});
    requireValue(metadata?.full_name === repository && String(metadata.id) === UPSTREAM_ID, 'Canonical repository identity changed');
    requireValue(environment.GITHUB_ACTIONS === 'true' && environment.GITHUB_REPOSITORY_ID === UPSTREAM_ID, 'Runtime repository identity changed');
    const id = positiveInteger(environment.GITHUB_RUN_ID);
    const attempt = positiveInteger(environment.GITHUB_RUN_ATTEMPT);
    requireValue(/^[0-9a-f]{40}$/u.test(environment.GITHUB_SHA || ''), 'Full run source identity required');
    const run = await api(repository, `/actions/runs/${id}`, {token});
    requireValue(run?.id === id && run.run_attempt === attempt && run.head_sha === environment.GITHUB_SHA, 'Actions run/source/attempt identity changed');
    requireValue(run.repository?.full_name === repository && [WORKFLOWS.get(context)].flat().includes(run.path), 'Actions workflow context changed');
    requireValue(run.event === 'workflow_dispatch' && ['workflow_dispatch', 'workflow_call'].includes(environment.GITHUB_EVENT_NAME),
      'Unauthorized operator event context');
    requireValue(environment.GITHUB_REF === 'refs/heads/'+run.head_branch, 'Actions run/ref context changed');
    requireValue(validUser(run.actor) && validUser(run.triggering_actor), 'Actions actor identity is incomplete');
    requireValue(run.actor.login === environment.GITHUB_ACTOR && String(run.actor.id) === environment.GITHUB_ACTOR_ID &&
      run.triggering_actor.login === environment.GITHUB_TRIGGERING_ACTOR, 'Actions original/triggering actor identity changed');
    if (context === 'github-release') requireValue(attempt === 1 && run.actor.type === 'Bot' && run.triggering_actor.type === 'Bot' &&
      sameUser(run.actor, run.triggering_actor), 'GitHub release requires the pinned App as both child actors on attempt one');
    const principals = [run.actor];
    if (!sameUser(run.actor, run.triggering_actor)) principals.push(run.triggering_actor);
    for (const user of principals.filter(item => item.type === 'Bot')) await requireDeliveryBot(user, run, environment, identityApi, token, context);
    const humans = principals.filter(user => user.type !== 'Bot');
    if (humans.length) {
      const admins = await administratorInventory(repository, token, api);
      requireValue(humans.every(user => admins.some(admin => sameUser(admin, user))), 'Repository Admin grant required for original actor and rerunner');
    }
    return {authorized: true, repository, mode: 'actions_run', runId: id, attempt, principals: principals.map(({id: userId, login}) => ({id: userId, login}))};
  } catch (error) {
    if (error instanceof OperatorError) throw error;
    throw new OperatorError('Unable to verify repository Admin authorization');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const context = process.argv.length === 2 ? 'delivery' : process.argv[2] === '--context' && process.argv[3];
    if (!context || !WORKFLOWS.has(context)) throw new OperatorError('Usage: android-operator.mjs [--context delivery|github-release|controller]');
    const result = await requireAndroidAdministrator({context});
    if (context === 'github-release') {
      const controller = await requireReleaseControllerAuthorization();
      const ids = controller.principals.map(user => user.id).join(',');
      // eslint-disable-next-line security/detect-non-literal-fs-filename -- GitHub Actions provides its job output file, and only validated numeric IDs are written.
      if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `controller_admin_ids=${ids}\n`);
      console.log(JSON.stringify({...result, controller}));
    } else console.log(JSON.stringify(result));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
