import {pathToFileURL} from 'node:url';
import {readFileSync} from 'node:fs';
import {isDeepStrictEqual} from 'node:util';

const UPSTREAM = 'gcsagroup/aegis-browser';
const UPSTREAM_ID = '1348409663';
const WORKFLOWS = {delivery: '.github/workflows/ios-delivery.yml', validation: '.github/workflows/ios-release-validation.yml', coverage: '.github/workflows/ios-coverage.yml'};
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

async function administratorInventory(repository, token, api) {
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
}
export async function verifyAdminMetadataCapability({repository, token, api = repositoryApi}) {
  try {
    requireValue(token, 'Token required for Admin metadata verification');
    const users = await administratorInventory(repositoryName(repository), token, api);
    return {supported: true, administratorCount: users.length};
  } catch { throw new OperatorError('Unable to verify complete Admin permissions metadata'); }
}

export async function verifyCandidateTagPolicy({environment = process.env, api = repositoryApi} = {}) {
  const repository = environment.GITHUB_REPOSITORY || UPSTREAM;
  const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
  requireValue(repository === UPSTREAM && token, 'Canonical candidate tag policy verification requires a token');
  const desired = JSON.parse(readFileSync(new URL('../../.github/ios-candidate-admin-ruleset.json', import.meta.url), 'utf8'));
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

export async function requireIosAdministrator({environment = process.env, api = repositoryApi, userApi = authenticatedUserApi, context = 'delivery'} = {}) {
  try {
    const repository = repositoryName(environment.GITHUB_REPOSITORY || UPSTREAM);
    const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
    requireValue(token && Object.hasOwn(WORKFLOWS, context), 'Token and known operator context required for Admin verification');
    if (context === 'delivery') requireValue(repository === UPSTREAM, 'Privileged iOS delivery repository must be canonical upstream');
    const metadata = await api(repository, '', {token});
    requireValue(metadata?.full_name === repository && Number.isSafeInteger(metadata.id) && metadata.id > 0, 'Repository identity could not be verified');
    if (context === 'delivery') requireValue(String(metadata.id) === UPSTREAM_ID, 'Canonical repository identity changed');
    if (environment.GITHUB_ACTIONS !== 'true') {
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
    requireValue(run.path === WORKFLOWS[context], 'Actions workflow context changed');
    requireValue(run.event === environment.GITHUB_EVENT_NAME && (run.event === 'workflow_dispatch' ||
      (context === 'delivery' && run.event === 'push' && environment.GITHUB_REF?.startsWith('refs/tags/candidate/ios/'))), 'Unauthorized operator event context');
    const ref = run.event === 'push' ? 'refs/tags/' : 'refs/heads/';
    requireValue(environment.GITHUB_REF === ref+run.head_branch, 'Actions run/ref context changed');
    requireValue(validUser(run.actor) && validUser(run.triggering_actor), 'Actions actor identity is incomplete');
    requireValue(run.actor.login === environment.GITHUB_ACTOR && String(run.actor.id) === environment.GITHUB_ACTOR_ID &&
      run.triggering_actor.login === environment.GITHUB_TRIGGERING_ACTOR, 'Actions original/triggering actor identity changed');
    const admins = await administratorInventory(repository, token, api);
    const principals = [run.actor];
    if (!sameUser(run.actor, run.triggering_actor)) principals.push(run.triggering_actor);
    requireValue(principals.every(user => admins.some(a => sameUser(a, user))), 'Repository Admin grant required for original actor and rerunner');
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
      if (process.argv.length !== 4 || process.argv[2] !== '--context') throw new OperatorError('Usage: ios-operator.mjs --context delivery|validation|coverage');
      console.log(JSON.stringify(await requireIosAdministrator({context: process.argv[3]})));
    }
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
