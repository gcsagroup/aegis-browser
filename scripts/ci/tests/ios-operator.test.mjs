import assert from 'node:assert/strict';
import test from 'node:test';
import {URLSearchParams} from 'node:url';

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
