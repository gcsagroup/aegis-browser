import {pathToFileURL} from 'node:url';
import {githubApi} from './promotion-github.mjs';
import {requireGreenQuality} from './promotion-quality.mjs';
import {requireAndroidAdministrator} from './android-operator.mjs';
import {releaseLines} from './android-release-lines.mjs';

const REPOSITORY = 'gcsagroup/aegis-browser';
const REPOSITORY_ID = '1348409663';
const DESTINATIONS = new Set(['artifacts', 'play-draft', 'play-internal', 'play-beta', 'play-production', 'github-draft']);

function exactCandidateTag(tag) {
  if (typeof tag !== 'string' || tag.length > 160) return false;
  const parts = tag.split('/');
  if (parts.length !== 3 || parts[0] !== 'candidate' || parts[1] !== 'android') return false;
  const dash = parts[2].lastIndexOf('-');
  if (dash <= 0 || dash >= parts[2].length - 1) return false;
  const version = parts[2].slice(0, dash);
  const audience = parts[2].slice(dash + 1).split('.');
  const components = version.split('.');
  const decimal = value => typeof value === 'string' && value.length >= 1 && value.length <= 10 &&
    (value === '0' || (/^[1-9][0-9]*$/u.test(value) && value.length <= 10));
  if (components.length !== 4 || !components.every(decimal) || audience.length !== 2) return false;
  if (!['alpha', 'beta', 'release'].includes(audience[0]) || !/^[1-9][0-9]{0,9}$/u.test(audience[1])) return false;
  const code = Number(audience[1]);
  const build = Number(components[3]);
  return Number.isSafeInteger(code) && code <= 2100000000 && code % 10000 === build && build < 10000;
}

export async function androidReleasePreflight(sha, {environment = process.env, api = githubApi, quality = requireGreenQuality,
  authorize = requireAndroidAdministrator, authorizationContext = 'delivery', lines = releaseLines()} = {}) {
  if (!/^[0-9a-f]{40}$/u.test(sha ?? '')) throw new Error('Full source SHA required');
  const token = environment.GH_TOKEN || environment.GITHUB_TOKEN;
  if (!token || environment.AEGIS_ANDROID_RELEASE_ENABLED !== 'true') throw new Error('Android release must be explicitly enabled with an admission token');
  const repository = environment.GITHUB_REPOSITORY || '';
  if (repository !== REPOSITORY) throw new Error('Privileged Android delivery requires canonical upstream');
  if (!DESTINATIONS.has(environment.RELEASE_DESTINATION || '')) throw new Error('Unknown Android release destination');
  await authorize({environment, context: authorizationContext});
  if (environment.GITHUB_ACTIONS === 'true' && (environment.GITHUB_SHA !== sha || !['workflow_dispatch', 'workflow_call'].includes(environment.GITHUB_EVENT_NAME))) {
    throw new Error('Android release requires exact-source dispatch');
  }
  const repo = await api(repository, '', {token});
  if (String(repo?.id) !== REPOSITORY_ID || repo?.default_branch !== 'main' || environment.GITHUB_REF !== 'refs/heads/main') {
    throw new Error('Upstream identity/default main/dispatch changed');
  }
  const line = lines.find(item => item.ref === environment.GITHUB_REF);
  if (!line || await api(repository, `/git/ref/heads/${line.name}`, {token}).then(ref => ref?.object?.sha) !== sha) {
    throw new Error('Source must equal the admitted Android release line tip');
  }
  if (environment.RELEASE_DESTINATION === 'github-draft') {
    const tag = environment.RELEASE_TAG;
    if (!exactCandidateTag(tag)) throw new Error('Exact Android candidate tag required');
    const tagged = await api(repository, `/commits/${encodeURIComponent(tag)}`, {token});
    if (tagged?.sha !== sha) throw new Error('Candidate tag changed or points to another source');
  } else if (environment.RELEASE_TAG) throw new Error('Android release tag is only valid for a GitHub Draft');
  if (!await quality(repository, line.name, sha, token, api)) throw new Error('Latest exact-source upstream quality has not passed');
  return {repository, sha, line: line.name, admission: 'upstream_quality_verified', releaseReady: false};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (![4, 6].includes(process.argv.length) || process.argv[2] !== '--sha' ||
        (process.argv.length === 6 && process.argv[4] !== '--context')) throw new Error('Usage: release-preflight.mjs --sha SHA [--context delivery|github-release]');
    const context = process.argv[5] || 'delivery';
    if (!['delivery', 'github-release'].includes(context)) throw new Error('Unknown Android release authorization context');
    console.log(JSON.stringify(await androidReleasePreflight(process.argv[3], {authorizationContext: context})));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
