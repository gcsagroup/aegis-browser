import {pathToFileURL} from 'node:url';
import {requireIosAdministrator} from './ios-operator.mjs';
import {githubApi} from './promotion-github.mjs';

const REPOSITORY = 'gcsagroup/aegis-browser';
const BRANCH = 'codex/ios-cloud-signing-poc';

function validVersion(value) {
  if (typeof value !== 'string' || value.length > 32) return false;
  const parts = value.split('.');
  return [2, 3].includes(parts.length) && parts.every(part => /^[0-9]{1,10}$/u.test(part));
}

export async function admitCloudPoc({environment = process.env, api = githubApi, authorize = requireIosAdministrator} = {}) {
  const sha = environment.GITHUB_SHA;
  if (environment.GITHUB_ACTIONS !== 'true' || environment.GITHUB_REPOSITORY !== REPOSITORY ||
      environment.GITHUB_REPOSITORY_ID !== '1348409663' || environment.GITHUB_EVENT_NAME !== 'workflow_dispatch' ||
      environment.GITHUB_REF !== 'refs/heads/'+BRANCH || !/^[0-9a-f]{40}$/u.test(sha || '') ||
      sha !== environment.AEGIS_IOS_CLOUD_POC_SOURCE_SHA || sha !== environment.POC_SOURCE_SHA ||
      !validVersion(environment.POC_VERSION) ||
      !/^[1-9][0-9]{0,9}$/u.test(environment.POC_BUILD || '')) {
    throw new Error('Cloud PoC requires canonical manual dispatch at the explicitly frozen branch/SHA and native identity');
  }
  await authorize({environment, context: 'validation'});
  const remote = await api(REPOSITORY, '/git/ref/heads/'+BRANCH, {token: environment.GH_TOKEN || environment.GITHUB_TOKEN});
  if (remote?.object?.sha !== sha) throw new Error('Cloud PoC branch moved after source freeze');
  return {repository: REPOSITORY, branch: BRANCH, sourceSha: sha, productionAdmissionChanged: false};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { console.log(JSON.stringify(await admitCloudPoc())); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
