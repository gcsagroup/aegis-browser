import assert from 'node:assert/strict';
import test from 'node:test';

const repository = 'gcsagroup/aegis-browser';
const fork = 'quinn521/aegis-browser';
const sha = 'a'.repeat(40);
const original = {id: 7, login: 'original', type: 'User'};
const bot = {id: 50, login: 'aegis-delivery[bot]', type: 'Bot'};
const policy = {actorId: 50, appId: 40, slug: 'aegis-delivery'};
const digest = 'sha256:'+'a'.repeat(64);
const environment = {GH_TOKEN: 'fixture-token', GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: repository,
  GITHUB_REPOSITORY_ID: '1348409663', GITHUB_RUN_ID: '200', GITHUB_RUN_ATTEMPT: '1', GITHUB_SHA: sha,
  GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/main', GITHUB_ACTOR: original.login,
  GITHUB_ACTOR_ID: String(original.id), GITHUB_TRIGGERING_ACTOR: original.login};
const inputs = {operation: 'Rebuild DMG', version: '1.1.0', signing_mode: 'ad-hoc', arch: 'arm64', app_path: '',
  product_checkout: '', product_sha: '', approved_source_sha: sha, controller_run_id: '300',
  controller_actor_id: String(original.id), controller_actor_login: original.login};
const load = () => import('../macos-operator.mjs');
const admin = user => ({...user, permissions: {admin: true}});

function deliveryFixture({repo = repository, repoId = 1348409663, actor = original, trigger = original, runChanges = {}, ref = 'refs/heads/main', branch = 'main'} = {}) {
  const env = {...environment, GITHUB_REPOSITORY: repo, GITHUB_REPOSITORY_ID: String(repoId), GITHUB_REF: ref,
    GITHUB_ACTOR: actor.login, GITHUB_ACTOR_ID: String(actor.id), GITHUB_TRIGGERING_ACTOR: trigger.login};
  const run = {id: 200, run_attempt: 1, head_sha: sha, head_branch: branch, event: 'workflow_dispatch',
    path: '.github/workflows/macos-delivery.yml', repository: {full_name: repo, id: repoId}, actor, triggering_actor: trigger, ...runChanges};
  const api = async (name, path) => {
    assert.equal(name, repo);
    if (path === '') return {id: repoId, full_name: repo};
    if (path === '/actions/runs/200') return run;
    if (path.startsWith('/collaborators?')) return [admin(original)];
    throw new Error('Unexpected '+path);
  };
  return {environment: env, api};
}

function dmgFixture({inputChanges = {}, runChanges = {}, parentChanges = {}, actor = bot, trigger = bot, admins = [admin(original)],
  jobChanges = {}, artifactChanges = {}, receiptChanges = {}, parentStatus = 'completed'} = {}) {
  const body = {...inputs, ...inputChanges};
  const env = {...environment, GITHUB_ACTOR: actor.login, GITHUB_ACTOR_ID: String(actor.id), GITHUB_TRIGGERING_ACTOR: trigger.login,
    AEGIS_IOS_DELIVERY_BOT: JSON.stringify(policy), MACOS_DMG_INPUTS: JSON.stringify(body), CONTROLLER_ACTOR_LOGIN: original.login};
  const child = {id: 200, run_attempt: 1, head_sha: sha, head_branch: 'main', event: 'workflow_dispatch',
    path: '.github/workflows/macos-delivery.yml', repository: {full_name: repository, id: 1348409663},
    head_repository: {full_name: repository, id: 1348409663}, actor, triggering_actor: trigger, ...runChanges};
  let polls = 0;
  const parent = () => {
    polls += 1;
    const finished = parentStatus === 'completed' || (parentStatus === 'waiting' && polls >= 2);
    return {id: 300, run_attempt: 1, head_sha: sha, head_branch: 'main', event: 'workflow_dispatch',
      path: '.github/workflows/macos-delivery-bot.yml', display_title: 'macOS Bot Package DMG 1.1.0',
      status: finished ? 'completed' : 'in_progress', conclusion: finished ? 'success' : null,
      repository: {full_name: repository, id: 1348409663}, head_repository: {full_name: repository, id: 1348409663},
      actor: original, triggering_actor: original, ...parentChanges};
  };
  const api = async (name, path) => {
    assert.equal(name, repository);
    if (path === '') return {id: 1348409663, full_name: repository};
    if (path === '/actions/runs/200') return child;
    if (path === '/actions/runs/300') return parent();
    if (path.startsWith('/actions/runs/300/attempts/1/jobs')) return {total_count: 1, jobs: [{id: 3001, name: 'controller',
      run_id: 300, run_attempt: 1, head_sha: sha, status: 'completed', conclusion: 'success',
      steps: [{name: 'Require current administrator for this controller request', status: 'completed', conclusion: 'success'}],
      ...jobChanges}]};
    if (path.startsWith('/actions/runs/300/artifacts')) return {total_count: 1, artifacts: [{name: 'macos-dmg-dispatch-300-1',
      id: 444, expired: false, digest, ...artifactChanges}]};
    if (path.startsWith('/collaborators?')) return admins;
    throw new Error('Unexpected '+path);
  };
  const identityApi = async path => {
    if (path === '/apps/aegis-delivery') return {id: 40, slug: 'aegis-delivery'};
    if (path === '/users/'+encodeURIComponent(bot.login)) return bot;
    throw new Error('Unexpected identity '+path);
  };
  const readReceipt = async () => ({childRunId: 200, inputs: body, ...receiptChanges});
  return {environment: env, api, identityApi, readReceipt, sleep: async () => {}};
}

test('manual delivery still accepts an Admin on the fork or upstream, including a non-main branch', async () => {
  const {requireMacosAdministrator} = await load();
  assert.equal((await requireMacosAdministrator(deliveryFixture())).authorized, true);
  assert.equal((await requireMacosAdministrator(deliveryFixture({repo: fork, repoId: 1363949860}))).authorized, true);
  assert.equal((await requireMacosAdministrator(deliveryFixture({ref: 'refs/heads/develop', branch: 'develop'}))).authorized, true);
});

test('manual delivery rejects a Bot actor, another workflow, and a non-admin', async () => {
  const {requireMacosAdministrator} = await load();
  await assert.rejects(requireMacosAdministrator(deliveryFixture({actor: bot, trigger: bot})), /Admin|grant/u);
  await assert.rejects(requireMacosAdministrator(deliveryFixture({runChanges: {path: '.github/workflows/macos-delivery-bot.yml'}})), /workflow|context/u);
  await assert.rejects(requireMacosAdministrator({...deliveryFixture(), api: async (name, path) => path.startsWith('/collaborators?') ? [] : deliveryFixture().api(name, path)}), /Admin|grant/u);
});

test('the DMG controller admits the initiating Admin and rejects the delivery Bot', async () => {
  const {requireMacosAdministrator} = await load();
  const controller = deliveryFixture({runChanges: {path: '.github/workflows/macos-delivery-bot.yml',
    head_repository: {full_name: repository, id: 1348409663}}});
  assert.equal((await requireMacosAdministrator({...controller, context: 'controller'})).authorized, true);
  const machine = deliveryFixture({actor: bot, trigger: bot, runChanges: {path: '.github/workflows/macos-delivery-bot.yml',
    head_repository: {full_name: repository, id: 1348409663}}});
  await assert.rejects(requireMacosAdministrator({...machine, context: 'controller'}), /Bot|Admin/u);
  const again = deliveryFixture({runChanges: {path: '.github/workflows/macos-delivery-bot.yml', run_attempt: 2,
    head_repository: {full_name: repository, id: 1348409663}}});
  await assert.rejects(requireMacosAdministrator({...again, environment: {...again.environment, GITHUB_RUN_ATTEMPT: '2'}, context: 'controller'}), /attempt|main/u);
});

test('bot DMG admission binds the pinned App, successful Admin controller, and exact receipt', async () => {
  const {requireMacosAdministrator} = await load();
  const ready = dmgFixture();
  const result = await requireMacosAdministrator({...ready, context: 'bot-dmg'});
  assert.equal(result.mode, 'dmg_bot');
  assert.deepEqual(result.controller, {authorized: true, controllerRunId: 300, principals: [{id: original.id, login: original.login}]});
  const waiting = dmgFixture({parentStatus: 'waiting'});
  assert.equal((await requireMacosAdministrator({...waiting, context: 'bot-dmg'})).authorized, true);
});

test('bot DMG rejects another package, a human pretending to be the Bot, and a mismatched receipt', async () => {
  const {requireMacosAdministrator} = await load();
  const cases = [
    dmgFixture({inputChanges: {operation: 'Package DMG'}}),
    dmgFixture({inputChanges: {signing_mode: 'developer-id'}}),
    dmgFixture({inputChanges: {arch: 'x64'}}),
    dmgFixture({inputChanges: {app_path: '/tmp/Aegis.app'}}),
    dmgFixture({inputChanges: {product_sha: sha}}),
    dmgFixture({inputChanges: {notarize: 'true'}}),
    dmgFixture({actor: original, trigger: original}),
    dmgFixture({receiptChanges: {childRunId: 201}}),
    dmgFixture({parentChanges: {display_title: 'macOS Bot Package DMG 9.9.9'}}),
    dmgFixture({parentChanges: {conclusion: 'failure'}}),
    dmgFixture({jobChanges: {steps: [{name: 'Require current administrator for this controller request', status: 'completed', conclusion: 'failure'}]}}),
    dmgFixture({artifactChanges: {digest: 'sha256:short'}}),
    dmgFixture({admins: [admin({id: 8, login: 'other', type: 'User'})]}),
  ];
  for (const fixture of cases) {
    await assert.rejects(requireMacosAdministrator({...fixture, context: 'bot-dmg', maxPolls: 2}), /DMG|Bot|App|Admin|receipt|controller|attempt|identity/u);
  }
  const pending = dmgFixture({parentStatus: 'in_progress'});
  await assert.rejects(requireMacosAdministrator({...pending, context: 'bot-dmg', maxPolls: 2}), /completed|succeed/u);
});

test('the DMG workflow admits an Admin or the pinned App on fork or upstream main', async () => {
  const {requireMacosAdministrator} = await load();
  const human = deliveryFixture({runChanges: {path: '.github/workflows/macos-dmg.yml',
    head_repository: {full_name: repository, id: 1348409663}}});
  assert.equal((await requireMacosAdministrator({...human, context: 'dmg'})).authorized, true);
  const machine = deliveryFixture({actor: bot, trigger: bot, runChanges: {path: '.github/workflows/macos-dmg.yml',
    head_repository: {full_name: repository, id: 1348409663}}});
  const identityApi = async path => {
    if (path === '/apps/aegis-delivery') return {id: 40, slug: 'aegis-delivery'};
    if (path === '/users/'+encodeURIComponent(bot.login)) return bot;
    throw new Error(path);
  };
  const admitted = await requireMacosAdministrator({...machine, context: 'dmg', identityApi,
    environment: {...machine.environment, AEGIS_IOS_DELIVERY_BOT: JSON.stringify(policy)}});
  assert.equal(admitted.mode, 'dmg_bot');
  const forkRun = deliveryFixture({repo: fork, repoId: 1363949860, runChanges: {path: '.github/workflows/macos-dmg.yml',
    head_repository: {full_name: fork, id: 1363949860}}});
  assert.equal((await requireMacosAdministrator({...forkRun, context: 'dmg'})).authorized, true);
  const forkController = deliveryFixture({repo: fork, repoId: 1363949860, runChanges: {path: '.github/workflows/macos-delivery-bot.yml',
    head_repository: {full_name: fork, id: 1363949860}}});
  assert.equal((await requireMacosAdministrator({...forkController, context: 'controller'})).authorized, true);
  await assert.rejects(requireMacosAdministrator({...machine, context: 'controller'}), /workflow|Bot|Admin/u);
});
