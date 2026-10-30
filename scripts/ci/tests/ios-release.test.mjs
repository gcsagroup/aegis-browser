import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import {parse} from 'yaml';

const sha = 'a'.repeat(40);
const repository = 'gcsagroup/aegis-browser';
const environment = {GH_TOKEN: 'fixture', GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: repository,
  GITHUB_REPOSITORY_ID: '1348409663', GITHUB_SHA: sha, GITHUB_REF: 'refs/heads/main',
  GITHUB_EVENT_NAME: 'workflow_dispatch', AEGIS_IOS_RELEASE_ENABLED: 'true', RELEASE_DESTINATION: 'artifacts'};
const load = () => import('../ios-release-preflight.mjs');
function apiFixture({moved = false, parent = repository, pending = false} = {}) {
  let reads = 0;
  return async (repo, path) => {
    if (path === '') return repo === repository ? {id: 1348409663, default_branch: 'main'} : {id: 1363949860, fork: true, parent: {full_name: parent}};
    if (path === '/git/ref/heads/main') return {object: {sha: moved && ++reads > 1 ? 'b'.repeat(40) : sha}};
    if (path.startsWith('/commits/')) return {sha: moved ? 'b'.repeat(40) : sha};
    const run = {id: 12, run_attempt: 2, head_sha: sha, head_branch: 'codex/ios-release-upstream-20261030',
      repository: {full_name: repo}, event: 'push', path: '.github/workflows/ios-release-validation.yml', status: pending ? 'in_progress' : 'completed', conclusion: pending ? null : 'success'};
    if (path.includes('/workflows/')) return {workflow_runs: [run, {...run, id: 11, run_attempt: 1, status: 'completed', conclusion: 'success'}]};
    if (path.endsWith('/jobs?per_page=100')) return {total_count: 2, jobs: ['contracts', 'ios-archive'].map(name => ({name, run_id: 12, run_attempt: 2, head_sha: sha, status: 'completed', conclusion: 'success'}))};
    if (path === '/actions/runs/12') return run;
    throw new Error(`Unexpected fixture endpoint ${path}`);
  };
}
test('upstream admission rechecks main after quality and rejects moving main or tag', async () => {
  const {iosReleasePreflight} = await load();
  assert.equal((await iosReleasePreflight(sha, {environment, api: apiFixture(), quality: async () => true})).admission, 'upstream_quality_verified');
  await assert.rejects(iosReleasePreflight(sha, {environment, api: apiFixture({moved: true}), quality: async () => true}), /main|changed/u);
  await assert.rejects(iosReleasePreflight(sha, {environment: {...environment, RELEASE_DESTINATION: 'github-draft', RELEASE_TAG: 'candidate/ios/1.0.0-alpha.6'}, api: apiFixture({moved: true}), quality: async () => true}), /tag|main/u);
});
test('disabled path and wrong repository identity cannot reach quality', async () => {
  const {iosReleasePreflight} = await load();
  for (const changes of [{AEGIS_IOS_RELEASE_ENABLED: 'false'}, {GITHUB_REPOSITORY_ID: '123'}, {GITHUB_EVENT_NAME: 'pull_request'}]) {
    await assert.rejects(iosReleasePreflight(sha, {environment: {...environment, ...changes}, api: apiFixture(), quality: async () => {throw new Error('credential boundary crossed');}}), /enabled|identity|dispatch/u);
  }
});
test('fork requires exact opt-in parent/ref and latest terminal validation attempt', async () => {
  const {iosReleasePreflight} = await load();
  const fork = {...environment, GITHUB_REPOSITORY: 'quinn521/aegis-browser', GITHUB_REPOSITORY_ID: '1363949860',
    GITHUB_REF: 'refs/heads/codex/ios-release-upstream-20261030', AEGIS_IOS_FORK_REPOSITORY_ID: '1363949860',
    AEGIS_IOS_FORK_REF: 'refs/heads/codex/ios-release-upstream-20261030', AEGIS_IOS_FORK_REHEARSAL: 'true'};
  assert.equal((await iosReleasePreflight(sha, {environment: fork, api: apiFixture()})).admission, 'fork_rehearsal_only');
  await assert.rejects(iosReleasePreflight(sha, {environment: fork, api: apiFixture({pending: true})}), /validation/u);
  await assert.rejects(iosReleasePreflight(sha, {environment: fork, api: apiFixture({parent: 'foreign/repo'})}), /parent|fork/u);
});
test('iOS workflow credentials and permissions stay in their protected stage', () => {
  const workflow = name => parse(readFileSync(`.github/workflows/${name}.yml`, 'utf8'));
  const validation = workflow('ios-release-validation');
  assert.deepEqual(validation.permissions, {contents: 'read'});
  assert(!JSON.stringify(validation).includes('secrets.'));
  const release = workflow('ios-release');
  assert.equal(release.jobs['ios-package'].environment, 'aegis-ios-signing');
  assert.equal(release.jobs['ios-draft'].environment, 'aegis-ios-draft');
  assert.equal(release.jobs['ios-draft'].permissions.contents, 'write');
  assert(!JSON.stringify(release.jobs['ios-package']).includes('AEGIS_ASC'));
  assert(!JSON.stringify(release.jobs.preflight).includes('secrets.'));
  const store = workflow('ios-testflight');
  assert.equal(store.jobs.store.environment, 'aegis-ios-store');
  assert(!JSON.stringify(store.jobs.import).includes('secrets.'));
  assert(!JSON.stringify(store).includes('contents:write'));
  for (const doc of [release, store]) {
    assert(!JSON.stringify(doc).includes('secrets:inherit'));
    assert(!JSON.stringify(doc).includes('pull_request_target'));
  }
});

test('candidate admission bounds version components and rejects trailing data before tag lookup', async () => {
  const {iosReleasePreflight} = await load();
  const run = async tag => iosReleasePreflight(sha, {environment: {...environment, RELEASE_DESTINATION: 'github-draft', RELEASE_TAG: tag}, api: apiFixture(), quality: async () => true});
  for (const tag of ['candidate/ios/1.0-alpha.6', 'candidate/ios/1.0.0-beta.7', 'candidate/ios/1.0.0-release.8']) {
    assert.equal((await run(tag)).admission, 'upstream_quality_verified');
  }
  for (const tag of [`candidate/ios/${'1'.repeat(128)}.0.0-alpha.6`, 'candidate/ios/1.0.0-release.8\n', 'candidate/ios/1.0.0.0-alpha.6', 'candidate/ios/1.0.0-alpha.0']) {
    await assert.rejects(run(tag), /candidate tag/iu);
  }
});
