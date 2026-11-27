import assert from 'node:assert/strict';
import test from 'node:test';

const repository = 'gcsagroup/aegis-browser';
const sha = 'a'.repeat(40);
const original = {id: 7, login: 'original', type: 'User'};
const rerunner = {id: 8, login: 'rerunner', type: 'User'};
const admin = user => ({...user, permissions: {admin: true}});
const environment = {GH_TOKEN: 'fixture-token', GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: repository,
  GITHUB_REPOSITORY_ID: '1348409663', GITHUB_RUN_ID: '200', GITHUB_RUN_ATTEMPT: '1', GITHUB_SHA: sha,
  GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/main', GITHUB_ACTOR: original.login,
  GITHUB_ACTOR_ID: String(original.id), GITHUB_TRIGGERING_ACTOR: original.login};
const load = () => import('../android-operator.mjs');

function fixture({admins = [admin(original)], trigger = original, runChanges = {}, path = '.github/workflows/android-delivery.yml'} = {}) {
  const run = {id: 200, run_attempt: 1, head_sha: sha, event: 'workflow_dispatch', head_branch: 'main', path,
    repository: {full_name: repository, id: 1348409663}, actor: original, triggering_actor: trigger, ...runChanges};
  const api = async (repo, request) => {
    assert.equal(repo, repository);
    if (request === '') return {id: 1348409663, full_name: repository, default_branch: 'main'};
    if (request === '/actions/runs/200') return run;
    if (request.startsWith('/collaborators?')) return admins;
    throw new Error('Unexpected endpoint ' + request);
  };
  return {api};
}

test('a current Admin can admit Android delivery on main', async () => {
  const {requireAndroidAdministrator, validAndroidCoordinate} = await load();
  assert.equal(validAndroidCoordinate('0.8.0', '1'), true);
  assert.equal(validAndroidCoordinate('0.8.0', '2007000345'), true);
  assert.equal(validAndroidCoordinate('0.08.0', '1'), false);
  assert.equal(validAndroidCoordinate('7.2.0.339', '2007000339'), true);
  assert.equal(validAndroidCoordinate('6.1.0.266', '2006000266'), true);
  assert.equal(validAndroidCoordinate('7.2.0.339', '2007000340'), false);
  const result = await requireAndroidAdministrator({environment, api: fixture().api});
  assert.equal(result.authorized, true);
  assert.deepEqual(result.principals.map(user => user.id), [7]);
  const full = fixture({path: '.github/workflows/android-delivery-full.yml'});
  assert.equal((await requireAndroidAdministrator({environment, api: full.api, context: 'delivery'})).authorized, true);
});

test('the original actor and the rerunner both need Admin', async () => {
  const {requireAndroidAdministrator} = await load();
  const env = {...environment, GITHUB_TRIGGERING_ACTOR: rerunner.login, GITHUB_RUN_ATTEMPT: '2'};
  for (const admins of [[admin(original)], [admin(rerunner)]]) {
    await assert.rejects(requireAndroidAdministrator({environment: env, api: fixture({admins, trigger: rerunner, runChanges: {run_attempt: 2}}).api}), /admin|grant/iu);
  }
});

test('repository, source, event, and workflow mismatches fail closed', async () => {
  const {requireAndroidAdministrator} = await load();
  for (const changes of [{GITHUB_SHA: 'b'.repeat(40)}, {GITHUB_REPOSITORY: 'other/repo'}, {GITHUB_EVENT_NAME: 'pull_request'},
    {GITHUB_REPOSITORY_ID: '1'}]) {
    await assert.rejects(requireAndroidAdministrator({environment: {...environment, ...changes}, api: fixture().api}), /identity|context|run|source|repository|event|attempt/iu);
  }
  await assert.rejects(requireAndroidAdministrator({environment: {...environment, GITHUB_EVENT_NAME: 'workflow_call'},
    api: fixture({runChanges: {event: 'push'}}).api}), /event/iu);
  const called = fixture();
  assert.equal((await requireAndroidAdministrator({environment: {...environment, GITHUB_EVENT_NAME: 'workflow_call'}, api: called.api})).authorized, true);
});

test('promotion accepts the initiating Admin recorded by the controller receipt', async () => {
  const {requireReleaseControllerAuthorization} = await load();
  const inputs = {operation: 'Promote stable', release_type: 'stable', version: '7.2.0.339', build: '2007000339',
    status_run_id: '80', controller_run_id: '50', controller_actor_id: '7', controller_actor_login: original.login,
    approved_source_sha: sha};
  const env = {...environment, GITHUB_RUN_ID: '90', RELEASE_INPUTS: JSON.stringify(inputs), CONTROLLER_ACTOR_LOGIN: original.login};
  const api = async (repo, request) => {
    assert.equal(repo, repository);
    if (request === '/actions/runs/50') {
      return {id: 50, run_attempt: 1, status: 'completed', conclusion: 'success', event: 'workflow_dispatch',
        path: '.github/workflows/android-delivery-bot.yml', head_branch: 'main', head_sha: sha,
        display_title: 'Android Bot Promote to stable 7.2.0.339(2007000339)',
        repository: {id: 1348409663, full_name: repository}, actor: original, triggering_actor: original};
    }
    if (request.startsWith('/collaborators?')) return [admin(original)];
    if (request === '/actions/runs/50/attempts/1/jobs?per_page=100') {
      return {total_count: 1, jobs: [{name: 'controller', conclusion: 'success',
        steps: [{name: 'Require current administrator for this controller request', conclusion: 'success'}]}]};
    }
    if (request === '/actions/runs/50/artifacts?per_page=100') {
      return {total_count: 1, artifacts: [{name: 'android-github-release-dispatch-50-1', expired: false, digest: 'sha256:' + 'ab'.repeat(32)}]};
    }
    throw new Error(request);
  };
  const result = await requireReleaseControllerAuthorization({environment: env, api, readReceipt: async () => ({childRunId: 90, inputs}), sleep: async () => {}});
  assert.equal(result.controllerRunId, 50);
  await assert.rejects(requireReleaseControllerAuthorization({environment: env, api,
    readReceipt: async () => ({childRunId: 91, inputs}), sleep: async () => {}}), /receipt/iu);
});

test('humans cannot enter the release workflow and the Bot cannot start the controller', async () => {
  const {requireAndroidAdministrator} = await load();
  const bot = {id: 50, login: 'aegis-android[bot]', type: 'Bot'};
  const humanRelease = fixture({path: '.github/workflows/android-github-release.yml'});
  await assert.rejects(requireAndroidAdministrator({environment, api: humanRelease.api, context: 'github-release'}), /pinned App/iu);
  const policy = JSON.stringify({actorId: 50, appId: 40, slug: 'aegis-android'});
  const botEnv = {...environment, GITHUB_ACTOR: bot.login, GITHUB_ACTOR_ID: '50', GITHUB_TRIGGERING_ACTOR: bot.login,
    AEGIS_ANDROID_DELIVERY_BOT: policy};
  const controller = fixture({path: '.github/workflows/android-delivery-bot.yml', runChanges: {actor: bot, triggering_actor: bot}});
  await assert.rejects(requireAndroidAdministrator({environment: botEnv, api: controller.api, context: 'controller'}), /Bot|dispatch/iu);
});

test('paginated Admin inventory is consumed and a full twenty pages fail closed', async () => {
  const {requireAndroidAdministrator} = await load();
  const page = number => number === 1 ? Array.from({length: 100}, (_item, index) => admin({id: 1000 + index, login: 'admin-' + index, type: 'User'}))
    : [admin(original)];
  let pages = 0;
  const api = async (repo, request) => {
    if (request.startsWith('/collaborators?')) { pages += 1; return page(pages); }
    return fixture().api(repo, request);
  };
  assert.equal((await requireAndroidAdministrator({environment, api})).authorized, true);
  assert.equal(pages, 2);
  const stuck = async (repo, request) => request.startsWith('/collaborators?')
    ? Array.from({length: 100}, (_item, index) => admin({id: index + 1, login: 'admin-' + index, type: 'User'}))
    : fixture().api(repo, request);
  await assert.rejects(requireAndroidAdministrator({environment, api: stuck}), /pagination|Admin/iu);
});
