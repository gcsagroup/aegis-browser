import {pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
import {appendFileSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {isDeepStrictEqual} from 'node:util';

const UPSTREAM = 'gcsagroup/aegis-browser';
const UPSTREAM_ID = '1348409663';
const WORKFLOWS = new Map([['delivery', ['.github/workflows/ios-delivery.yml', '.github/workflows/ios-delivery-full.yml', '.github/workflows/ios-clear-empty-upload.yml']], ['controller', '.github/workflows/ios-delivery-bot.yml'], ['github-release', '.github/workflows/ios-github-release.yml'], ['validation', '.github/workflows/ios-release-validation.yml'], ['coverage', '.github/workflows/ios-coverage.yml']]);
const requirePolicy = createRequire(import.meta.url);
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
function repositoryName(repository) {
  requireValue(typeof repository === 'string' && repository.split('/').length === 2 && repository.split('/').every(p => /^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}$/u.test(p) && !p.includes('..')), 'Invalid repository identity');
  return repository;
}
async function readGithub(path, token) {
  const response = await globalThis.fetch('https://api.github.com'+path, {method: 'GET', redirect: 'error', signal: globalThis.AbortSignal.timeout(30000),
    headers: {Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', Authorization: `Bearer ${token}`}});
  requireValue(response.ok, 'Unable to verify GitHub Admin permissions');
  return response.json();
}
const repositoryApi = (repository, path, {token}) => readGithub('/repos/'+repositoryName(repository)+path, token);
const authenticatedUserApi = token => readGithub('/user', token);

async function requireDeliveryBot(user, run, environment, identityApi, token, context) {
  const releaseContext = context === 'github-release';
  requireValue((releaseContext ? run.path === '.github/workflows/ios-github-release.yml' :
    context === 'delivery' && ['.github/workflows/ios-delivery.yml', '.github/workflows/ios-delivery-full.yml'].includes(run.path)) &&
    run.event === 'workflow_dispatch' && run.head_branch === 'main',
  'Bot requires a canonical main delivery dispatch');
  let policy, inputs;
  try {
    policy = JSON.parse(environment.AEGIS_IOS_DELIVERY_BOT || 'null');
    inputs = JSON.parse((releaseContext ? environment.RELEASE_INPUTS : environment.DELIVERY_INPUTS) || '{}');
  } catch { throw new OperatorError('Invalid Bot configuration or inputs'); }
  requireValue(policy && Object.keys(policy).sort().join(',') === 'actorId,appId,slug' &&
    Number.isSafeInteger(policy.appId) && policy.appId > 0 && Number.isSafeInteger(policy.actorId) && policy.actorId > 0 &&
    typeof policy.slug === 'string' && /^[a-z0-9][a-z0-9-]{0,98}$/u.test(policy.slug), 'Pinned Bot App configuration required');
  requireValue(user.type === 'Bot' && user.id === policy.actorId && user.login === policy.slug+'[bot]', 'Bot actor identity differs');
  const releaseInputsValid = inputs && typeof inputs === 'object' && !Array.isArray(inputs) &&
    Object.keys(inputs).sort().join(',') === 'approved_source_sha,build,controller_actor_id,controller_actor_login,controller_run_id,operation,release_type,status_run_id,version' &&
    ['Preview', 'Publish prerelease', 'Promote stable'].includes(inputs.operation) && inputs.release_type === 'stable' &&
    validIosVersion(inputs.version) &&
    /^[1-9][0-9]{0,9}$/u.test(inputs.build || '') && /^[1-9][0-9]{0,15}$/u.test(inputs.status_run_id || '') &&
    /^[1-9][0-9]{0,15}$/u.test(inputs.controller_run_id || '') && /^[1-9][0-9]{0,15}$/u.test(inputs.controller_actor_id || '') &&
    /^[A-Za-z0-9-]{1,39}$/u.test(inputs.controller_actor_login || '');
  const deliveryInputsValid = inputs && typeof inputs === 'object' && !Array.isArray(inputs) &&
    inputs.approved_source_sha === environment.GITHUB_SHA &&
    ['Package', 'Package and upload', 'Draft', 'Status', 'Wait', 'Release Wait'].includes(inputs.operation) &&
    (!inputs.private_beta || inputs.private_beta === 'no');
  requireValue(inputs && inputs.approved_source_sha === environment.GITHUB_SHA &&
    (releaseContext ? releaseInputsValid : deliveryInputsValid), 'Bot operation and approved source inputs required');
  const app = await identityApi('/apps/'+policy.slug, token);
  const actor = await identityApi('/users/'+encodeURIComponent(user.login), token);
  requireValue(app?.id === policy.appId && app.slug === policy.slug && actor?.type === 'Bot' && sameUser(actor, user),
    'Live Bot App identity differs');
}

export function validIosVersion(value) {
  if (typeof value !== 'string' || value.length > 32) return false;
  const parts = value.split('.');
  return [2, 3].includes(parts.length) && parts.every(part => /^[0-9]{1,10}$/u.test(part));
}

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
    throw new OperatorError('Unable to read complete Admin permissions inventory');
  }
}

function readDispatchReceipt(repository, token, artifact) {
  const bytes = execFileSync('gh', ['api', 'repos/'+repository+'/actions/artifacts/'+artifact.id+'/zip'],
    {env: {...process.env, GH_TOKEN: token}, timeout: 30000, maxBuffer: 128 * 1024});
  requireValue('sha256:'+createHash('sha256').update(bytes).digest('hex') === artifact.digest,
    'Controller dispatch receipt artifact digest differs');
  const directory = mkdtempSync(join(tmpdir(), 'aegis-ios-dispatch-'));
  try {
    const zip = join(directory, 'receipt.zip');
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- This fixed filename belongs to a freshly created private receipt directory.
    writeFileSync(zip, bytes, {mode: 0o600});
    const name = 'aegis-ios-release-dispatch.json';
    requireValue(execFileSync('unzip', ['-Z1', zip], {encoding: 'utf8', timeout: 5000, maxBuffer: 8192}).trim() === name,
      'Controller dispatch artifact must contain exactly one receipt');
    return JSON.parse(execFileSync('unzip', ['-p', zip, name], {encoding: 'utf8', timeout: 5000, maxBuffer: 8192}));
  } finally {
    rmSync(directory, {recursive: true});
  }
}

export async function requireReleaseControllerAuthorization({environment = process.env, api = repositoryApi, readReceipt = readDispatchReceipt,
  sleep = ms => new Promise(resolve => globalThis.setTimeout(resolve, ms)), maxPolls = 12} = {}) {
  const repository = repositoryName(environment.GITHUB_REPOSITORY || UPSTREAM);
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
    requireValue(run?.id === runId && run.run_attempt === 1 && run.path === '.github/workflows/ios-delivery-bot.yml' &&
      run.event === 'workflow_dispatch' && run.head_branch === 'main' && run.head_sha === environment.GITHUB_SHA &&
      run.repository?.id === Number(UPSTREAM_ID) && run.repository?.full_name === repository &&
      run.head_repository?.id === Number(UPSTREAM_ID) && run.head_repository?.full_name === repository,
    'Parent controller run identity/source/context differs');
    if (run.status === 'completed') break;
    await sleep(5000);
  }
  requireValue(run?.status === 'completed' && run.conclusion === 'success',
    'Parent Admin controller has not completed successfully');
  const controllerOperation = {
    Preview: 'Preview GitHub release',
    'Publish prerelease': 'Publish prerelease',
    'Promote stable': 'Promote to stable',
  }[inputs.operation];
  requireValue(run.display_title === `iOS Bot ${controllerOperation} ${inputs.version}(${inputs.build})`,
    'Parent Admin controller does not identify the requested operation/version/build');
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
  const matches = receiptArtifacts.artifacts.filter(row => row.name === `ios-github-release-dispatch-${runId}-1`);
  requireValue(matches.length === 1 && Number.isSafeInteger(matches[0].id) && matches[0].id > 0 &&
    matches[0].expired === false && /^sha256:[0-9a-f]{64}$/u.test(matches[0].digest || ''),
  'Exact sealed controller dispatch receipt required');
  const receipt = await readReceipt(repository, token, matches[0]);
  requireValue(receipt?.childRunId === positiveInteger(environment.GITHUB_RUN_ID) &&
    isDeepStrictEqual(receipt.inputs, inputs), 'Controller dispatch receipt does not identify this child and its inputs');
  return {authorized: true, controllerRunId: runId,
    principals: principals.map(({id, login}) => ({id, login}))};
}
export async function verifyAdminMetadataCapability({repository, token, api = repositoryApi}) {
  try {
    requireValue(token, 'Token required for Admin metadata verification');
    const users = await administratorInventory(repositoryName(repository), token, api);
    return {supported: true, administratorCount: users.length};
  } catch (error) {
    if (error instanceof OperatorError) throw error;
    throw new OperatorError('Unable to verify complete Admin permissions metadata');
  }
}

export async function verifyCandidateTagPolicy({environment = process.env, api = repositoryApi} = {}) {
  const repository = environment.GITHUB_REPOSITORY || UPSTREAM;
  const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
  requireValue(repository === UPSTREAM && token, 'Canonical candidate tag policy verification requires a token');
  const desired = requirePolicy('../../.github/ios-candidate-admin-ruleset.json');
  const matches = [];
  let complete = false;
  for (let page = 1; page <= 20; page++) {
    const rows = await api(repository, `/rulesets?includes_parents=true&per_page=100&page=${page}`, {token});
    requireValue(Array.isArray(rows) && rows.length <= 100, 'Incomplete candidate ruleset policy inventory');
    matches.push(...rows.filter(row => row.name === desired.name));
    if (rows.length < 100) {complete = true; break;}
  }
  requireValue(complete && matches.length === 1 && Number.isSafeInteger(matches[0].id), 'Unique candidate ruleset policy required');
  const policy = await api(repository, `/rulesets/${matches[0].id}`, {token});
  requireValue(policy?.id === matches[0].id && policy.name === desired.name && policy.target === desired.target && policy.enforcement === 'active' &&
    isDeepStrictEqual(policy.conditions, desired.conditions) && isDeepStrictEqual(policy.bypass_actors, desired.bypass_actors) &&
    Array.isArray(policy.rules) && policy.rules.length === 3 && isDeepStrictEqual(policy.rules.map(rule => rule.type).sort(), ['creation', 'deletion', 'update']),
  'Candidate ruleset policy must restrict all candidate tag writes to repository Admin');
  return {verified: true, id: policy.id, adminRoleId: 5};
}

export async function requireIosAdministrator({environment = process.env, api = repositoryApi, userApi = authenticatedUserApi, identityApi = readGithub, context = 'delivery'} = {}) {
  try {
    const repository = repositoryName(environment.GITHUB_REPOSITORY || UPSTREAM);
    const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
    requireValue(token && WORKFLOWS.has(context), 'Token and known operator context required for Admin verification');
    if (['delivery', 'controller', 'github-release'].includes(context)) requireValue(repository === UPSTREAM, 'Privileged iOS delivery repository must be canonical upstream');
    const metadata = await api(repository, '', {token});
    requireValue(metadata?.full_name === repository && Number.isSafeInteger(metadata.id) && metadata.id > 0, 'Repository identity could not be verified');
    if (['delivery', 'controller', 'github-release'].includes(context)) requireValue(String(metadata.id) === UPSTREAM_ID, 'Canonical repository identity changed');
    if (environment.GITHUB_ACTIONS !== 'true') {
      requireValue(context !== 'github-release', 'GitHub release requires a pinned App dispatch');
      const user = await userApi(token);
      requireValue(validUser(user), 'Authenticated token user identity is invalid');
      const grant = await api(repository, `/collaborators/${encodeURIComponent(user.login)}/permission`, {token});
      requireValue(grant?.permission === 'admin' && sameUser(grant.user, user), 'Actual token user requires verified repository Admin permission');
      return {authorized: true, repository, mode: 'authenticated_user', principals: [{id: user.id, login: user.login}]};
    }
    requireValue(String(metadata.id) === environment.GITHUB_REPOSITORY_ID, 'Runtime repository identity changed');
    const id = positiveInteger(environment.GITHUB_RUN_ID);
    const attempt = positiveInteger(environment.GITHUB_RUN_ATTEMPT);
    requireValue(/^[0-9a-f]{40}$/u.test(environment.GITHUB_SHA || ''), 'Full run source identity required');
    const run = await api(repository, `/actions/runs/${id}`, {token});
    requireValue(run?.id === id && run.run_attempt === attempt && run.head_sha === environment.GITHUB_SHA, 'Actions run/source/attempt identity changed');
    requireValue(run.repository?.full_name === repository && run.repository?.id === metadata.id && run.head_repository?.full_name === repository, 'Actions repository context changed');
    requireValue([WORKFLOWS.get(context)].flat().includes(run.path), 'Actions workflow context changed');
    requireValue(run.event === environment.GITHUB_EVENT_NAME && (run.event === 'workflow_dispatch' ||
      (context === 'delivery' && run.path === '.github/workflows/ios-delivery.yml' && run.event === 'push' && environment.GITHUB_REF?.startsWith('refs/tags/candidate/ios/'))), 'Unauthorized operator event context');
    const ref = run.event === 'push' ? 'refs/tags/' : 'refs/heads/';
    requireValue(environment.GITHUB_REF === ref+run.head_branch, 'Actions run/ref context changed');
    requireValue(validUser(run.actor) && validUser(run.triggering_actor), 'Actions actor identity is incomplete');
    requireValue(run.actor.login === environment.GITHUB_ACTOR && String(run.actor.id) === environment.GITHUB_ACTOR_ID &&
      run.triggering_actor.login === environment.GITHUB_TRIGGERING_ACTOR, 'Actions original/triggering actor identity changed');
    if (context === 'github-release') requireValue(attempt === 1 && run.actor.type === 'Bot' &&
      run.triggering_actor.type === 'Bot' && sameUser(run.actor, run.triggering_actor),
    'GitHub release requires the pinned App as both child actors on attempt one');
    const principals = [run.actor];
    if (!sameUser(run.actor, run.triggering_actor)) principals.push(run.triggering_actor);
    const bots = principals.filter(user => user.type === 'Bot');
    for (const user of bots) await requireDeliveryBot(user, run, environment, identityApi, token, context);
    const humans = principals.filter(user => user.type !== 'Bot');
    if (humans.length) {
      const admins = await administratorInventory(repository, token, api);
      requireValue(humans.every(user => admins.some(a => sameUser(a, user))), 'Repository Admin grant required for original actor and rerunner');
    }
    return {authorized: true, repository, mode: 'actions_run', runId: id, attempt, principals: principals.map(({id: userId, login}) => ({id: userId, login}))};
  } catch (error) {
    if (error instanceof OperatorError) throw error;
    throw new OperatorError('Unable to verify repository Admin authorization');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length === 3 && process.argv[2] === '--probe-admin-metadata') {
      console.log(JSON.stringify(await verifyAdminMetadataCapability({repository: process.env.GITHUB_REPOSITORY, token: process.env.GH_TOKEN || process.env.GITHUB_TOKEN})));
    } else if (process.argv.length === 3 && process.argv[2] === '--verify-candidate-tag-policy') {
      await requireIosAdministrator();
      console.log(JSON.stringify(await verifyCandidateTagPolicy()));
    } else {
      if (process.argv.length !== 4 || process.argv[2] !== '--context') throw new OperatorError('Usage: ios-operator.mjs --context delivery|github-release|validation|coverage');
      const context = process.argv[3];
      const result = await requireIosAdministrator({context});
      if (context === 'github-release') {
        const controller = await requireReleaseControllerAuthorization();
        const ids = controller.principals.map(user => user.id).join(',');
        // eslint-disable-next-line security/detect-non-literal-fs-filename -- GitHub Actions provides its job output file, and only validated numeric IDs are written.
        if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `controller_admin_ids=${ids}\n`);
        console.log(JSON.stringify({...result, controller}));
      } else console.log(JSON.stringify(result));
    }
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
