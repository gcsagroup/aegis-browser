import {pathToFileURL} from 'node:url';
import {githubApi} from './promotion-github.mjs';
import {requireGreenQuality} from './promotion-quality.mjs';
import {requireIosAdministrator} from './ios-operator.mjs';

export const IOS_REPOSITORY = 'gcsagroup/aegis-browser';
export const IOS_REPOSITORY_ID = '1348409663';

function exactCandidateTag(tag) {
  if (typeof tag !== 'string' || tag.length > 100) return false;
  const parts = tag.split('/');
  if (parts.length !== 3 || parts[0] !== 'candidate' || parts[1] !== 'ios') return false;
  const identity = parts[2].split('-');
  if (identity.length !== 2) return false;
  const version = identity[0].split('.');
  const audience = identity[1].split('.');
  const decimal = value => value.length >= 1 && value.length <= 10 && !/[^0-9]/u.test(value);
  return [2, 3].includes(version.length) && version.every(decimal) && audience.length === 2 &&
    ['alpha', 'beta', 'release'].includes(audience[0]) && decimal(audience[1]) && audience[1][0] !== '0';
}
export async function iosReleasePreflight(sha, {environment = process.env, api = githubApi, quality = requireGreenQuality, authorize = requireIosAdministrator} = {}) {
  if (!/^[0-9a-f]{40}$/u.test(sha ?? '')) throw new Error('Full source SHA required');
  const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
  if (!token || environment.AEGIS_IOS_RELEASE_ENABLED !== 'true') throw new Error('iOS release must be explicitly enabled with an admission token');
  const repository = environment.GITHUB_REPOSITORY || IOS_REPOSITORY;
  if (repository !== IOS_REPOSITORY) throw new Error('Privileged iOS delivery requires canonical upstream');
  await authorize({environment});
  const candidate = environment.GITHUB_EVENT_NAME === 'push' && environment.GITHUB_REF === `refs/tags/${environment.RELEASE_TAG}` && environment.RELEASE_DESTINATION === 'github-draft';
  if (environment.GITHUB_ACTIONS === 'true' && (environment.GITHUB_SHA !== sha || (!candidate && environment.GITHUB_EVENT_NAME !== 'workflow_dispatch'))) {
    throw new Error('iOS release requires exact-source dispatch or candidate tag');
  }
  const repo = await api(repository, '', {token});
  const assertTag = async () => {
    if (environment.RELEASE_DESTINATION !== 'github-draft') return;
    const tag = environment.RELEASE_TAG;
    if (!exactCandidateTag(tag)) throw new Error('Exact iOS candidate tag required');
    const tagged = await api(repository, `/commits/${encodeURIComponent(tag)}`, {token});
    if (tagged?.sha !== sha) throw new Error('Candidate tag changed or points to another source');
  };
  if (String(repo?.id) !== IOS_REPOSITORY_ID || repo?.default_branch !== 'main' ||
      (environment.GITHUB_ACTIONS === 'true' && (environment.GITHUB_REPOSITORY_ID !== IOS_REPOSITORY_ID || (!candidate && environment.GITHUB_REF !== 'refs/heads/main')))) {
    throw new Error('Upstream identity/default main/dispatch changed');
  }
  const assertMain = async () => {
    const main = await api(repository, '/git/ref/heads/main', {token});
    if (main?.object?.sha !== sha) throw new Error('Source must equal current upstream main');
  };
  await assertMain();
  await assertTag();
  if (!await quality(repository, 'main', sha, token, api)) throw new Error('Latest exact-source upstream quality has not passed');
  await assertMain();
  await assertTag();
  return {repository, sha, admission: 'upstream_quality_verified', releaseReady: false};
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length !== 4 || process.argv[2] !== '--sha') throw new Error('Usage: ios-release-preflight.mjs --sha SHA');
    console.log(JSON.stringify(await iosReleasePreflight(process.argv[3])));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
