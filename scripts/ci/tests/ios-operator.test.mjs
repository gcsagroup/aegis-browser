import assert from 'node:assert/strict';
import test from 'node:test';
import {URLSearchParams} from 'node:url';
import {readFileSync} from 'node:fs';

const repository = 'gcsagroup/aegis-browser';
const sha = 'a'.repeat(40);
const original = {id: 7, login: 'original'};
const rerunner = {id: 8, login: 'rerunner'};
const admin = user => ({...user, permissions: {admin: true}, role_name: 'admin'});
const environment = {GH_TOKEN: 'fixture-token', GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: repository,
  GITHUB_REPOSITORY_ID: '1348409663', GITHUB_RUN_ID: '200', GITHUB_RUN_ATTEMPT: '1', GITHUB_SHA: sha,
  GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/main', GITHUB_ACTOR: original.login,
  GITHUB_ACTOR_ID: String(original.id), GITHUB_TRIGGERING_ACTOR: original.login};
const load = () => import('../ios-operator.mjs');
test('candidate tag policy admits only active canonical namespace restrictions with repository Admin bypass', async () => {
  const {verifyCandidateTagPolicy} = await load();
  assert.equal(typeof verifyCandidateTagPolicy, 'function');
  const desired = JSON.parse(readFileSync('.github/ios-candidate-admin-ruleset.json', 'utf8'));
  const policy = {...desired, id: 300};
  const api = async (_repo, path) => path.startsWith('/rulesets?') ? [{id: 300, name: desired.name}] : policy;
  assert.equal((await verifyCandidateTagPolicy({environment, api})).id, 300);
  for (const change of [{enforcement: 'disabled'}, {target: 'branch'}, {bypass_actors: []},
    {bypass_actors: [{actor_type: 'RepositoryRole', actor_id: 4, bypass_mode: 'always'}]},
    {bypass_actors: [...policy.bypass_actors, {actor_type: 'User', actor_id: 7, bypass_mode: 'always'}]},
    {conditions: {ref_name: {include: ['refs/tags/*'], exclude: []}}}, {rules: [{type: 'creation'}]}]) {
    await assert.rejects(verifyCandidateTagPolicy({environment, api: async (_repo, path) => path.startsWith('/rulesets?') ? [{id:300,name:desired.name}] : {...policy,...change}}), /policy|ruleset/iu);
  }
});
function fixture({admins = [admin(original)], trigger = original, runChanges = {}, repoChanges = {}, failure, pages} = {}) {
  const calls = [];
  const run = {id: 200, run_attempt: 1, head_sha: sha, event: 'workflow_dispatch', head_branch: 'main',
    path: '.github/workflows/ios-delivery.yml', repository: {full_name: repository, id: 1348409663},
    head_repository: {full_name: repository}, actor: original, triggering_actor: trigger, ...runChanges};
  const api = async (repo, path) => {
    calls.push(path);
    assert.equal(repo, repository);
    if (failure?.(path)) throw new Error('HTTP403 private response must not be echoed');
    if (path === '') return {id: 1348409663, full_name: repository, default_branch: 'main', ...repoChanges};
    if (path === '/actions/runs/200') return run;
    if (path.startsWith('/collaborators?')) {
      assert(path.includes('affiliation=all') && path.includes('permission=admin') && path.includes('per_page=100'));
      const page = Number(new URLSearchParams(path.split('?')[1]).get('page'));
      return pages ? pages(page) : admins;
    }
    throw new Error('Unexpected endpoint '+path);
  };
  return {api, calls};
}
test('CI administrator and organization-owner effective Admin grants are accepted', async () => {
  const {requireIosAdministrator} = await load();
  const f = fixture();
  const result = await requireIosAdministrator({environment, api: f.api});
  assert.equal(result.authorized, true);
  assert.deepEqual(result.principals.map(p => p.id), [7]);
  const owner = fixture({admins: [{...admin(original), role_name: 'organization-owner-grant'}]});
  assert.equal((await requireIosAdministrator({environment, api: owner.api})).authorized, true);
});
test('all lower, misleading custom and unknown grants deny before privileged work', async () => {
  const {requireIosAdministrator} = await load();
  for (const role of ['maintain', 'write', 'triage', 'read', 'none', 'custom-Admin-title', undefined]) {
    const f = fixture({admins: [{...original, role_name: role, permissions: {admin: false}}]});
    await assert.rejects(requireIosAdministrator({environment, api: f.api}), /admin|permission|grant/iu);
  }
});
test('both original actor and actual rerunner require Admin', async () => {
  const {requireIosAdministrator} = await load();
  const env = {...environment, GITHUB_TRIGGERING_ACTOR: rerunner.login, GITHUB_RUN_ATTEMPT: '2'};
  for (const admins of [[admin(original)], [admin(rerunner)]]) {
    await assert.rejects(requireIosAdministrator({environment: env, api: fixture({admins, trigger: rerunner, runChanges: {run_attempt: 2}}).api}), /admin|grant/iu);
  }
  const good = fixture({admins: [admin(original), admin(rerunner)], trigger: rerunner, runChanges: {run_attempt: 2}});
  assert.equal((await requireIosAdministrator({environment: env, api: good.api})).principals.length, 2);
});
test('runtime identity repository source and attempt mismatches cannot borrow an Admin run', async () => {
  const {requireIosAdministrator} = await load();
  for (const changes of [{GITHUB_ACTOR: 'spoof'}, {GITHUB_ACTOR_ID: '9'}, {GITHUB_TRIGGERING_ACTOR: 'spoof'},
    {GITHUB_RUN_ATTEMPT: '2'}, {GITHUB_SHA: 'b'.repeat(40)}, {GITHUB_REPOSITORY_ID: '1'}, {GITHUB_REF: 'refs/heads/other'},
    {GITHUB_RUN_ID: ''}, {GITHUB_EVENT_NAME: 'pull_request'}]) {
    await assert.rejects(requireIosAdministrator({environment: {...environment, ...changes}, api: fixture().api}), /identity|context|run|source|repository|event|ref|attempt|actor/iu);
  }
  for (const runChanges of [{path: '.github/workflows/quality.yml'}, {head_repository: {full_name: 'foreign/repo'}}]) {
    await assert.rejects(requireIosAdministrator({environment, api: fixture({runChanges}).api}), /workflow|repository|context/iu);
  }
});
test('permission API errors malformed pages and incomplete pagination fail closed', async () => {
  const {requireIosAdministrator} = await load();
  await assert.rejects(requireIosAdministrator({environment, api: fixture({failure: p => p.startsWith('/collaborators?')}).api}), /verify|permission|admin/iu);
  for (const value of [null, {}, [{...original}], [{...admin(original), id: 'wrong'}]]) {
    await assert.rejects(requireIosAdministrator({environment, api: fixture({admins: value}).api}), /admin|inventory|identity|grant|permission/iu);
  }
  const full = Array.from({length: 100}, (_, i) => admin({id: 100+i, login: 'user-'+i}));
  await assert.rejects(requireIosAdministrator({environment, api: fixture({pages: () => full}).api}), /complete|pagination|inventory|duplicate/iu);
});
test('paginated filtered admin inventory is read completely under installation-token API', async () => {
  const {requireIosAdministrator, verifyAdminMetadataCapability} = await load();
  const first = Array.from({length: 100}, (_, i) => admin({id: 100+i, login: 'user-'+i}));
  const f = fixture({pages: page => page === 1 ? first : [admin(original)]});
  assert.equal((await requireIosAdministrator({environment, api: f.api})).authorized, true);
  assert.equal(f.calls.filter(p => p.startsWith('/collaborators?')).length, 2);
  const result = await verifyAdminMetadataCapability({repository, token: 'fixture-token', api: fixture().api});
  assert.equal(result.supported, true);
  assert(!JSON.stringify(result).includes('original'));
});
test('local authorization resolves real token user and ignores actor environment spoofing', async () => {
  const {requireIosAdministrator} = await load();
  const user = {id: 9, login: 'token-owner'};
  const local = {...environment, GITHUB_ACTIONS: 'false', GITHUB_ACTOR: 'pretend-admin'};
  const api = async (_repo, path) => path === '' ? {id: 1348409663, full_name: repository} :
    (assert.equal(path, '/collaborators/token-owner/permission'), {permission: 'admin', role_name: 'admin', user});
  assert.equal((await requireIosAdministrator({environment: local, api, userApi: async () => user})).authorized, true);
  await assert.rejects(requireIosAdministrator({environment: local, api: async (r,p) => p === '' ? api(r,p) : {permission: 'write', user}, userApi: async () => user}), /admin/iu);
  await assert.rejects(requireIosAdministrator({environment: local, api: async (r,p) => p === '' ? api(r,p) : {permission: 'admin', user: {...user,id: 1}}, userApi: async () => user}), /identity|permission|admin/iu);
});

test('Full caller keeps current Admin admission; unknown workflows and full tag pushes are denied', async () => {
  const {requireIosAdministrator} = await load();
  const allowed = fixture({runChanges: {path: '.github/workflows/ios-delivery-full.yml'}});
  assert.equal((await requireIosAdministrator({environment, api: allowed.api})).authorized, true);
  for (const path of ['.github/workflows/other.yml', '.github/workflows/ios-delivery-reusable.yml']) {
    await assert.rejects(requireIosAdministrator({environment, api: fixture({runChanges: {path}}).api}), /workflow context/iu);
  }
  const tag = 'candidate/ios/1.0.0-alpha.36';
  await assert.rejects(requireIosAdministrator({environment: {...environment, GITHUB_EVENT_NAME: 'push', GITHUB_REF: 'refs/tags/'+tag},
    api: fixture({runChanges: {path: '.github/workflows/ios-delivery-full.yml', event: 'push', head_branch: tag}}).api}), /event context/iu);
  await assert.rejects(requireIosAdministrator({environment,
    api: fixture({admins: [], runChanges: {path: '.github/workflows/ios-delivery-full.yml'}}).api}), /Admin grant/iu);
});

const bot = {id: 50, login: 'aegis-delivery[bot]', type: 'Bot'};
const botPolicy = JSON.stringify({appId: 40, slug: 'aegis-delivery', actorId: 50});
function botFixture({policy = botPolicy, inputs = {}, actor = bot, trigger = actor, env = {}, changes = {}, app = {id: 40, slug: 'aegis-delivery'}} = {}) {
  const runtime = {...environment, GITHUB_ACTOR: actor.login, GITHUB_ACTOR_ID: String(actor.id),
    GITHUB_TRIGGERING_ACTOR: trigger.login, AEGIS_IOS_DELIVERY_BOT: policy,
    DELIVERY_INPUTS: JSON.stringify({operation: 'Package and upload', product: 'Beta', version: '1.1.0', build: '4', approved_source_sha: sha, ...inputs}), ...env};
  const f = fixture({admins: [admin(original)], trigger, runChanges: {actor, triggering_actor: trigger, ...changes}});
  const identityApi = async path => {
    if (path === '/apps/aegis-delivery') return app;
    assert.equal(path, '/users/aegis-delivery%5Bbot%5D');
    return bot;
  };
  return {environment: runtime, api: f.api, identityApi};
}
test('the configured App can dispatch an exact-source Beta without an Admin user grant', async () => {
  const {requireIosAdministrator} = await load();
  const value = await requireIosAdministrator(botFixture());
  assert.equal(value.authorized, true);
  assert.deepEqual(value.principals, [{id: 50, login: 'aegis-delivery[bot]'}]);
});
test('release versions must be text with two or three decimal components', async () => {
  const {requireIosAdministrator} = await load();
  const releaseInputs = {operation: 'Preview', release_type: 'stable', version: '1.2', build: '9',
    status_run_id: '210', controller_run_id: '300', controller_actor_id: '7',
    controller_actor_login: 'original', approved_source_sha: sha};
  const check = version => requireIosAdministrator({...botFixture({
    changes: {path: '.github/workflows/ios-github-release.yml'},
    env: {RELEASE_INPUTS: JSON.stringify({...releaseInputs, version})},
  }), context: 'github-release'});
  for (const version of ['1.2', '1.2.0']) assert.equal((await check(version)).authorized, true);
  for (const version of [['1.2'], '1..2', '1.12345678901']) {
    await assert.rejects(check(version), /operation and approved source inputs required/u);
  }
});
test('Bot admission rejects missing configuration, impersonation and replaced App identities', async () => {
  const {requireIosAdministrator} = await load();
  for (const options of [{policy: ''}, {policy: '{'}, {policy: JSON.stringify({appId: 40, slug: 'aegis-delivery', actorId: 51})},
    {actor: {...bot, id: 51}}, {actor: {...bot, login: 'other[bot]'}}, {app: {id: 41, slug: 'aegis-delivery'}}]) {
    await assert.rejects(requireIosAdministrator(botFixture(options)), /Bot|App|identity|configuration/iu);
  }
});
test('Bot cannot borrow candidate pushes, other contexts, stale sources or broader operations', async () => {
  const {requireIosAdministrator} = await load();
  for (const options of [{inputs: {approved_source_sha: ''}}, {inputs: {approved_source_sha: 'b'.repeat(40)}},
    {inputs: {operation: 'Distribute external'}}, {inputs: {private_beta: 'yes'}},
    {env: {GITHUB_REF: 'refs/heads/releases/ios/1.0'}, changes: {head_branch: 'releases/ios/1.0'}},
    {env: {GITHUB_EVENT_NAME: 'push', GITHUB_REF: 'refs/tags/candidate/ios/1.1.0-beta.4'}, changes: {event: 'push', head_branch: 'candidate/ios/1.1.0-beta.4'}},
    {changes: {path: '.github/workflows/ios-clear-empty-upload.yml'}}]) {
    await assert.rejects(requireIosAdministrator(botFixture(options)), /Bot|source|dispatch|operation|context|input/iu);
  }
});
test('an Admin may reconcile a Bot run but a lower-role rerunner cannot borrow it', async () => {
  const {requireIosAdministrator} = await load();
  assert.equal((await requireIosAdministrator(botFixture({trigger: original}))).principals.length, 2);
  await assert.rejects(requireIosAdministrator(botFixture({trigger: rerunner})), /Admin|grant/iu);
});
test('controller entrypoint retains human Admin admission and cannot be started by the Bot', async () => {
  const {requireIosAdministrator} = await load();
  const path = '.github/workflows/ios-delivery-bot.yml';
  assert.equal((await requireIosAdministrator({environment, context: 'controller', api: fixture({runChanges: {path}}).api})).authorized, true);
  await assert.rejects(requireIosAdministrator({...botFixture({changes: {path}}), context: 'controller'}), /Bot|Admin|grant/iu);
});

function releaseControllerFixture({runChanges = {}, admins = [admin(original)], inputChanges = {}, controllerJobChanges = {}, receiptChanges = {}} = {}) {
  const inputs = {operation: 'Promote stable', release_type: 'stable', version: '1.2.0', build: '9',
    status_run_id: '210', controller_run_id: '300', controller_actor_id: String(original.id),
    controller_actor_login: original.login, approved_source_sha: sha, ...inputChanges};
  const environment = {...environmentBase(), GITHUB_RUN_ID: '301', GITHUB_RUN_ATTEMPT: '1',
    GITHUB_SHA: sha, CONTROLLER_ACTOR_LOGIN: original.login, RELEASE_INPUTS: JSON.stringify(inputs)};
  const run = {id: 300, run_attempt: 1, status: 'completed', conclusion: 'success', head_sha: sha,
    head_branch: 'main', event: 'workflow_dispatch', path: '.github/workflows/ios-delivery-bot.yml',
    display_title: 'iOS Bot Promote to stable 1.2.0(9)', repository: {id: 1348409663, full_name: repository},
    head_repository: {id: 1348409663, full_name: repository}, actor: original, triggering_actor: original, ...runChanges};
  const api = async (repo, path) => {
    assert.equal(repo, repository);
    if (path === '') return {id: 1348409663, full_name: repository};
    if (path === '/actions/runs/300') return run;
    if (path.startsWith('/collaborators?')) return admins;
    if (path === '/actions/runs/300/attempts/1/jobs?per_page=100') {
      const active = run.status === 'in_progress';
      return {total_count: 1, jobs: [{id: 3001, name: 'controller', run_id: 300, run_attempt: 1, head_sha: sha,
        status: active ? 'in_progress' : 'completed', conclusion: active ? null : 'success',
        steps: [
          {name: 'Require current administrator for this controller request', status: 'completed', conclusion: 'success'},
          {name: 'Dispatch and monitor exact App-owned delivery runs', status: active ? 'in_progress' : 'completed', conclusion: active ? null : 'success'},
        ], ...controllerJobChanges}]};
    }
    if (path === '/actions/runs/300/artifacts?per_page=100') return {total_count: 1, artifacts: [
      {name: 'ios-github-release-dispatch-300-1', id: 444, expired: false, digest: 'sha256:'+'a'.repeat(64)}]};
    throw new Error('Unexpected controller API path '+path);
  };
  return {environment, api, readReceipt: async () => ({childRunId: 301, inputs, ...receiptChanges})};
}
function environmentBase() { return {...environment, GITHUB_RUN_ID: '301', GITHUB_RUN_ATTEMPT: '1'}; }
test('release workflow binds the Admin controller, operation coordinates and successful controller job', async () => {
  const {requireReleaseControllerAuthorization} = await load();
  const fixture = releaseControllerFixture();
  const result = await requireReleaseControllerAuthorization({...fixture, sleep: async () => {}});
  assert.deepEqual(result, {authorized: true, controllerRunId: 300, principals: [{id: original.id, login: original.login}]});
});
test('release child waits for the sealed controller handoff and rejects another child receipt', async () => {
  const {requireReleaseControllerAuthorization} = await load();
  await assert.rejects(requireReleaseControllerAuthorization({
    ...releaseControllerFixture({runChanges: {status: 'in_progress', conclusion: null}}),
    sleep: async () => {}, maxPolls: 1,
  }), /has not completed/u);
  await assert.rejects(requireReleaseControllerAuthorization({
    ...releaseControllerFixture({receiptChanges: {childRunId: 302}}),
  }), /does not identify this child/u);
});
test('direct human dispatch cannot enter the public release workflow', async () => {
  const {requireIosAdministrator} = await load();
  await assert.rejects(requireIosAdministrator({environment, context: 'github-release',
    api: fixture({runChanges: {path: '.github/workflows/ios-github-release.yml'}}).api}), /pinned App/u);
});
test('release workflow rejects a lower-role rerunner, altered controller title and failed parent', async () => {
  const {requireReleaseControllerAuthorization} = await load();
  const lowerRerunner = {...rerunner, permissions: {admin: false}};
  for (const fixture of [
    releaseControllerFixture({admins: [admin(original), lowerRerunner], runChanges: {triggering_actor: rerunner}}),
    releaseControllerFixture({runChanges: {display_title: 'iOS Bot Preview GitHub release 1.2.0(9)'}}),
    releaseControllerFixture({runChanges: {conclusion: 'failure'}}),
    releaseControllerFixture({runChanges: {status: 'in_progress', conclusion: null},
      controllerJobChanges: {steps: [
        {name: 'Require current administrator for this controller request', status: 'completed', conclusion: 'failure'},
        {name: 'Dispatch and monitor exact App-owned delivery runs', status: 'in_progress', conclusion: null},
      ]}}),
    releaseControllerFixture({inputChanges: {release_type: 'beta'}}),
    releaseControllerFixture({inputChanges: {controller_actor_id: '8'}}),
  ]) {
    await assert.rejects(requireReleaseControllerAuthorization({...fixture, sleep: async () => {}}), /Admin|controller|succeed|initiator/iu);
  }
});
