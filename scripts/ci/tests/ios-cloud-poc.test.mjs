import test from 'node:test';
import assert from 'node:assert/strict';
import {admitCloudPoc} from '../ios-cloud-poc-admission.mjs';

const SHA = 'a'.repeat(40);
const env = {GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: 'gcsagroup/aegis-browser', GITHUB_REPOSITORY_ID: '1348409663',
  GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/codex/ios-cloud-signing-poc',
  GITHUB_SHA: SHA, AEGIS_IOS_CLOUD_POC_SOURCE_SHA: SHA, POC_SOURCE_SHA: SHA, POC_VERSION: '0.8.0', POC_BUILD: '101', GH_TOKEN: 'fixture'};

test('cloud PoC binds an Admin dispatch to an exact frozen candidate without changing production admission', async () => {
  let authorization;
  const value = await admitCloudPoc({environment: env, authorize: async args => { authorization = args; },
    api: async (_repo, path) => { assert.equal(path, '/git/ref/heads/codex/ios-cloud-signing-poc'); return {object: {sha: SHA}}; }});
  assert.equal(authorization.context, 'validation');
  assert.equal(value.sourceSha, SHA);
  assert.equal(value.productionAdmissionChanged, false);
});

test('forks, other branches, unpinned source and malformed native inputs fail before secret-consuming work', async () => {
  for (const changes of [{GITHUB_REPOSITORY: 'fork/aegis-browser'}, {GITHUB_EVENT_NAME: 'pull_request'},
    {GITHUB_REF: 'refs/heads/main'}, {GITHUB_REPOSITORY_ID: '1'}, {POC_SOURCE_SHA: 'b'.repeat(40)},
    {AEGIS_IOS_CLOUD_POC_SOURCE_SHA: ''}, {POC_VERSION: '0.8.0;touch'}, {POC_VERSION: '0.8.'},
    {POC_VERSION: '0.8.0.1'}, {POC_VERSION: '0.12345678901.0'}, {POC_BUILD: '0'}]) {
    await assert.rejects(admitCloudPoc({environment: {...env, ...changes}, authorize: async () => { throw Error('should not authorize'); }}), /canonical manual dispatch/u);
  }
});

test('non-Admin operator and branch movement refuse candidate execution', async () => {
  await assert.rejects(admitCloudPoc({environment: env, authorize: async () => { throw Error('Admin required'); }}), /Admin/u);
  await assert.rejects(admitCloudPoc({environment: env, authorize: async () => {}, api: async () => ({object: {sha: 'b'.repeat(40)}})}), /moved/u);
});
