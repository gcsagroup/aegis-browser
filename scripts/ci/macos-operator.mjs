#!/usr/bin/env node
import {pathToFileURL} from 'node:url';

const ALLOWED = new Map([['quinn521/aegis-browser', ''], ['gcsagroup/aegis-browser', '1348409663']]);
const WORKFLOW = '.github/workflows/macos-delivery.yml';

class OperatorError extends Error {}
function requireValue(value, message) { if (!value) throw new OperatorError(message); }
function validUser(user) {
  return user && Number.isSafeInteger(user.id) && user.id > 0 && typeof user.login === 'string' && /^[A-Za-z0-9[\]-]{1,100}$/u.test(user.login);
}
function sameUser(a, b) { return validUser(a) && validUser(b) && a.id === b.id && a.login.toLowerCase() === b.login.toLowerCase(); }
function positiveInteger(value) {
  requireValue(typeof value === 'string' && /^[1-9][0-9]{0,15}$/u.test(value) && Number.isSafeInteger(Number(value)), 'Invalid Actions run identity');
  return Number(value);
}

async function readGithub(path, token) {
  const response = await globalThis.fetch('https://api.github.com' + path, {method: 'GET', redirect: 'error', signal: globalThis.AbortSignal.timeout(30000),
    headers: {Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', Authorization: `Bearer ${token}`}});
  requireValue(response.ok, 'Unable to verify GitHub Admin permissions');
  return response.json();
}
const repositoryApi = (repository, path, {token}) => readGithub('/repos/' + repository + path, token);

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

export async function requireMacosAdministrator({environment = process.env, api = repositoryApi} = {}) {
  try {
    const repository = environment.GITHUB_REPOSITORY || '';
    const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
    requireValue(ALLOWED.has(repository) && token, 'macOS delivery is limited to the fork and upstream repository');
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
    requireValue(run.repository?.full_name === repository && run.path === WORKFLOW && run.event === 'workflow_dispatch', 'Actions workflow context changed');
    requireValue(environment.GITHUB_REF === 'refs/heads/' + run.head_branch, 'Actions run/ref context changed');
    requireValue(validUser(run.actor) && validUser(run.triggering_actor), 'Actions actor identity is incomplete');
    requireValue(run.actor.login === environment.GITHUB_ACTOR && String(run.actor.id) === environment.GITHUB_ACTOR_ID &&
      run.triggering_actor.login === environment.GITHUB_TRIGGERING_ACTOR, 'Actions original/triggering actor identity changed');
    const admins = await administratorInventory(repository, token, api);
    const principals = [run.actor];
    if (!sameUser(run.actor, run.triggering_actor)) principals.push(run.triggering_actor);
    requireValue(principals.every(user => admins.some(admin => sameUser(admin, user))), 'Repository Admin grant required for original actor and rerunner');
    return {authorized: true, repository, principals: principals.map(({id: userId, login}) => ({id: userId, login}))};
  } catch (error) {
    if (error instanceof OperatorError) throw error;
    throw new OperatorError('Unable to verify repository Admin authorization');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length !== 4 || process.argv[2] !== '--context' || process.argv[3] !== 'delivery') {
      throw new OperatorError('Usage: macos-operator.mjs --context delivery');
    }
    console.log(JSON.stringify(await requireMacosAdministrator()));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
