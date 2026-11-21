import {createHash, sign} from 'node:crypto';
import {lstatSync, readFileSync} from 'node:fs';
import {basename} from 'node:path';
import {pathToFileURL} from 'node:url';
import {performance} from 'node:perf_hooks';
import {githubRequest} from './ios-delivery-bot.mjs';
import {requireGreenQuality} from './promotion-quality.mjs';
import {downloadEvidenceArchive, requireDmgEvidence} from './macos-delivery-evidence.mjs';

const UPSTREAM = 'gcsagroup/aegis-browser';
const FORK = 'quinn521/aegis-browser';
const REPOSITORY_IDS = new Map([[UPSTREAM, 1348409663], [FORK, 1363949860]]);
const VERSION = /^[0-9]+\.[0-9]+\.[0-9]+$/u;
const BUILD = /^[1-9][0-9]*$/u;
const KINDS = new Set(['ad-hoc', 'host-signed', 'notarized']);
const requireValue = (value, message) => { if (!value) throw new Error(message); };
const positiveId = value => Number.isSafeInteger(value) && value > 0;

function admittedRepository(name) {
  requireValue(REPOSITORY_IDS.has(name), 'DMG Bot starts on the fork first, then the upstream repository');
  return {name, id: REPOSITORY_IDS.get(name), prefix: '/repos/'+name};
}

export function installationClient({appId, installationId, privateKey, repository, request = githubRequest, now = Date.now}) {
  const admitted = admittedRepository(repository);
  requireValue(positiveId(appId) && positiveId(installationId), 'Pinned App and installation IDs required');
  let token, expires = 0;
  return async (path, options = {}) => {
    requireValue(path === admitted.prefix || path.startsWith(admitted.prefix+'/'),
      'Bot token is limited to the admitted repository');
    if (expires - now() < 60000) {
      const seconds = Math.floor(now()/1000);
      const header = Buffer.from(JSON.stringify({alg: 'RS256', typ: 'JWT'})).toString('base64url');
      const claims = Buffer.from(JSON.stringify({iss: String(appId), iat: seconds-30, exp: seconds+540})).toString('base64url');
      const payload = header+'.'+claims;
      const jwt = payload+'.'+sign('RSA-SHA256', Buffer.from(payload), privateKey).toString('base64url');
      const value = await request('/app/installations/'+installationId+'/access_tokens', {token: jwt, method: 'POST',
        body: {repository_ids: [admitted.id], permissions: {actions: 'write', contents: 'read'}}});
      const permissions = value?.permissions;
      const nextExpiry = Date.parse(value?.expires_at);
      requireValue(typeof value?.token === 'string' && value.token.length > 0 && nextExpiry > now()+60000 && nextExpiry <= now()+3660000 &&
        permissions?.actions === 'write' && permissions.contents === 'read' &&
        Object.keys(permissions).every(key => ['actions', 'contents', 'metadata'].includes(key)) &&
        (!permissions.metadata || permissions.metadata === 'read'), 'Installation token scope or expiry differs');
      token = value.token;
      expires = nextExpiry;
    }
    return options.archive ? downloadEvidenceArchive(path, token) : request(path, {...options, token});
  };
}

function normalize(packageKind, signingMode) {
  if (packageKind === 'unsigned-dmg') packageKind = 'ad-hoc';
  if (signingMode === 'none') signingMode = 'ad-hoc';
  return {packageKind, signingMode};
}

function requestInputs(environment) {
  const raw = environment.BOT_INPUTS || '{}';
  requireValue(raw.length <= 10000, 'Bot inputs exceed limit');
  let value;
  try { value = JSON.parse(raw); }
  catch { throw new Error('Unknown Bot inputs'); }
  requireValue(value && typeof value === 'object' && !Array.isArray(value), 'Unknown Bot inputs');
  requireValue(Object.values(value).every(item => item == null || typeof item === 'string'), 'Unknown Bot inputs');
  const operation = value.operation || '';
  const version = value.version || '';
  const build = value.build || '';
  const normalized = normalize(value.package_kind || 'ad-hoc', value.signing_mode || 'ad-hoc');
  requireValue(operation === 'Package' || operation === 'Tag release', 'macOS Bot only packages a DMG or tags that DMG');
  requireValue(VERSION.test(version) && BUILD.test(build), 'Enter version and build, for example 0.8.0 and 800001');
  requireValue(KINDS.has(normalized.packageKind) && normalized.signingMode === normalized.packageKind,
    'DMG signing mode must match ad-hoc, host-signed, or notarized');
  return {operation, version, build, ...normalized};
}

function childInputs(environment, inputs) {
  return {
    operation: 'Package',
    version: inputs.version,
    build: inputs.build,
    package_kind: inputs.packageKind,
    signing_mode: inputs.signingMode,
    approved_source_sha: environment.GITHUB_SHA,
    tag_release: inputs.operation === 'Tag release' ? 'yes' : 'no',
    bot_callback: 'yes',
  };
}

export async function driveMacosDmg({environment = process.env, api, quality, recordRun = () => {}, sleep = ms => new Promise(resolve => globalThis.setTimeout(resolve, ms)), maxPolls = 1200, pollMs = 15000, now = () => performance.now(), monitorBudgetMs = 300 * 60000} = {}) {
  requireValue(Number.isFinite(monitorBudgetMs) && monitorBudgetMs > 0 && monitorBudgetMs <= 300 * 60000,
    'DMG monitoring must fit the hosted controller budget');
  const deadline = now() + monitorBudgetMs;
  requireValue(environment.AEGIS_MACOS_DELIVERY_ENABLED === 'true', 'macOS DMG delivery is disabled until AEGIS_MACOS_DELIVERY_ENABLED=true');
  const inputs = requestInputs(environment);
  const admitted = admittedRepository(environment.GITHUB_REPOSITORY);
  requireValue(/^[0-9a-f]{40}$/u.test(environment.GITHUB_SHA || ''), 'Approved source required');
  let policy;
  try { policy = JSON.parse(environment.AEGIS_IOS_DELIVERY_BOT || 'null'); }
  catch { throw new Error('Pinned App configuration required'); }
  requireValue(policy && positiveId(policy.appId) && positiveId(policy.actorId) &&
    typeof policy.slug === 'string' && /^[a-z0-9][a-z0-9-]{0,98}$/u.test(policy.slug),
  'Pinned App configuration required');
  const repository = await api(admitted.prefix);
  requireValue(repository?.id === admitted.id && repository.full_name === admitted.name,
    'Repository identity differs');
  const assertSource = async () => {
    const tip = await api(admitted.prefix+'/git/ref/heads/main');
    requireValue(tip?.object?.sha === environment.GITHUB_SHA, 'Approved source is no longer current main');
  };
  await assertSource();
  const green = quality || (() => requireGreenQuality(admitted.name, 'main', environment.GITHUB_SHA, undefined,
    (_repo, path, options) => api(admitted.prefix+path, options)));
  requireValue(await green(), 'Exact-source quality has not passed');
  await assertSource();
  const dispatched = childInputs(environment, inputs);
  let receipt;
  try {
    receipt = await api(admitted.prefix+'/actions/workflows/macos-dmg.yml/dispatches',
      {method: 'POST', body: {ref: 'main', inputs: dispatched}});
  } catch { throw new Error('DMG dispatch outcome unknown for '+inputs.version+'('+inputs.build+'); reconcile before another request'); }
  requireValue(positiveId(receipt?.workflow_run_id), 'DMG run identity unknown; reconcile without retrying');
  const id = receipt.workflow_run_id;
  const url = 'https://github.com/'+admitted.name+'/actions/runs/'+id;
  const retained = {id, attempt: 1, operation: inputs.operation, packageKind: inputs.packageKind,
    signingMode: inputs.signingMode, notarized: false, upload: false,
    url, approvedSourceSha: environment.GITHUB_SHA, version: inputs.version, build: inputs.build,
    repository: admitted.name};
  recordRun({...retained, state: 'dispatched'});
  const botLogin = policy.slug+'[bot]';
  let observed = false, invisible = 0;
  for (let poll = 0; poll < maxPolls && now() < deadline; poll++) {
    let run;
    try { run = await api(admitted.prefix+'/actions/runs/'+id); }
    catch (error) {
      if (observed || error.status !== 404 || invisible >= 4 || poll+1 >= maxPolls) throw error;
      invisible++;
      await sleep(Math.max(0, Math.min(pollMs, deadline-now())));
      continue;
    }
    observed = true;
    const actor = user => user?.type === 'Bot' && user.id === policy.actorId && user.login === botLogin;
    requireValue(run?.id === id && run.run_attempt === 1 && run.head_sha === environment.GITHUB_SHA && run.head_branch === 'main' &&
      run.repository?.id === admitted.id && run.repository.full_name === admitted.name &&
      run.head_repository?.id === admitted.id && run.head_repository.full_name === admitted.name &&
      run.path === '.github/workflows/macos-dmg.yml' && run.event === 'workflow_dispatch' && actor(run.actor) && actor(run.triggering_actor),
    'Child run identity/source/context differs: '+url);
    if (run.status === 'completed') {
      requireValue(run.conclusion === 'success', 'Child DMG delivery failed; reconcile '+url);
      const evidence = await requireDmgEvidence({api, repository: admitted.name, sha: environment.GITHUB_SHA, id, inputs});
      const completed = {...retained, ...evidence, state: 'completed', conclusion: 'success'};
      recordRun(completed);
      const result = {sourceSha: environment.GITHUB_SHA, version: inputs.version, build: inputs.build,
        packageKind: inputs.packageKind, notarized: evidence.notarized, upload: false,
        repository: admitted.name, run: completed};
      if (inputs.operation === 'Tag release') result.tag = `candidate/macos/${inputs.version}-${inputs.packageKind}.${inputs.build}`;
      return result;
    }
    await sleep(Math.max(0, Math.min(pollMs, deadline-now())));
  }
  const pending = {...retained, state: 'monitoring-deferred', completion: 'verified-child-callback'};
  recordRun(pending);
  return {sourceSha: environment.GITHUB_SHA, version: inputs.version, build: inputs.build,
    packageKind: inputs.packageKind, notarized: false, upload: false, pending: true,
    repository: admitted.name, run: pending};
}

export async function completeMacosDmg({environment = process.env, api, manifestPath} = {}) {
  const admitted = admittedRepository(environment.GITHUB_REPOSITORY);
  const sha = environment.GITHUB_SHA || '';
  const version = environment.AEGIS_MACOS_DELIVERY_VERSION || '';
  const build = environment.AEGIS_MACOS_DELIVERY_BUILD || '';
  const packageKind = environment.AEGIS_MACOS_DELIVERY_PACKAGE_KIND || '';
  const signingMode = environment.AEGIS_MACOS_DELIVERY_SIGNING_MODE || '';
  const parent = environment.GITHUB_RUN_ID || '';
  const tagRelease = environment.AEGIS_MACOS_DELIVERY_TAG_RELEASE || 'false';
  requireValue(/^[0-9a-f]{40}$/u.test(sha), 'Completed delivery source is malformed');
  requireValue(VERSION.test(version) && BUILD.test(build), 'Completed delivery coordinate is malformed');
  requireValue(KINDS.has(packageKind) && signingMode === packageKind, 'Completed DMG kind differs');
  requireValue(/^[1-9][0-9]*$/u.test(parent), 'Completed delivery run is malformed');
  requireValue(['true', 'false'].includes(tagRelease), 'Completed candidate request is malformed');
  requireValue(basename(manifestPath || '') === 'macos-delivery-manifest.json', 'Completed manifest name differs');
  /* eslint-disable security/detect-non-literal-fs-filename -- The delivery workflow passes the sealed manifest it just downloaded. */
  const stat = lstatSync(manifestPath);
  requireValue(stat.isFile(), 'Completed manifest is missing');
  const bytes = readFileSync(manifestPath);
  /* eslint-enable security/detect-non-literal-fs-filename */
  const manifest = JSON.parse(bytes.toString('utf8'));
  const digest = createHash('sha256').update(bytes).digest('hex');
  requireValue(manifest?.schema === 'aegis-macos-delivery-v1' && manifest.repository === admitted.name &&
    manifest.sourceSha === sha && manifest.version === version && String(manifest.build) === build &&
    manifest.packageKind === packageKind && manifest.notarized === (packageKind === 'notarized') &&
    manifest.artifacts?.length === 1 && manifest.artifacts[0].architecture === 'arm64' &&
    manifest.artifacts[0].uploadable === false && manifest.artifacts[0].sha256?.length === 64,
  'Completed manifest differs');
  const parentRun = await api(admitted.prefix+'/actions/runs/'+parent);
  requireValue(parentRun?.id === Number(parent) && parentRun.run_attempt === 1 && parentRun.head_sha === sha &&
    (parentRun.status === 'in_progress' || (parentRun.status === 'completed' && parentRun.conclusion === 'success')) &&
    parentRun.head_branch === 'main' && parentRun.path === '.github/workflows/macos-dmg.yml' &&
    parentRun.event === 'workflow_dispatch' && parentRun.repository?.id === admitted.id &&
    parentRun.repository.full_name === admitted.name && parentRun.head_repository?.id === admitted.id &&
    parentRun.head_repository.full_name === admitted.name &&
    String(parentRun.actor?.id) === environment.GITHUB_ACTOR_ID && parentRun.actor?.login === environment.GITHUB_ACTOR &&
    parentRun.triggering_actor?.id === parentRun.actor.id,
  'Completed parent run identity differs');
  const evidence = await requireDmgEvidence({api, repository: admitted.name, sha, id: Number(parent),
    inputs: {version, build, packageKind, operation: tagRelease === 'true' ? 'Tag release' : 'Package'}});
  requireValue(evidence.manifestSha256 === digest, 'Completed local and sealed manifest digests differ');
  const inputs = {
    operation: 'Complete', version, build, package_kind: packageKind, signing_mode: signingMode,
    approved_source_sha: sha, manifest_sha256: digest, completed_operation: 'package',
    parent_run_id: parent, candidate_tag: tagRelease === 'true' ? `candidate/macos/${version}-${packageKind}.${build}` : '',
  };
  let receipt;
  try {
    receipt = await api(admitted.prefix+'/actions/workflows/macos-delivery-bot.yml/dispatches',
      {method: 'POST', body: {ref: 'main', inputs}});
  } catch { throw new Error('Bot dispatch outcome unknown; reconcile before another request'); }
  requireValue(positiveId(receipt?.workflow_run_id), 'Bot run identity unknown; reconcile without retrying');
  return {workflowRunId: receipt.workflow_run_id, parentRunId: Number(parent), operation: 'package',
    manifestSha256: digest, candidateTag: inputs.candidate_tag, repository: admitted.name};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const completing = process.argv[2] === 'complete';
  try {
    requireValue(completing ? process.argv.length === 4 : process.argv.length === 2,
      'Drive takes environment inputs; complete takes the sealed manifest path');
    const policy = JSON.parse(process.env.AEGIS_IOS_DELIVERY_BOT || 'null');
    const api = installationClient({appId: policy?.appId, installationId: Number(process.env.AEGIS_IOS_BOT_INSTALLATION_ID),
      privateKey: process.env.AEGIS_IOS_BOT_PRIVATE_KEY, repository: process.env.GITHUB_REPOSITORY});
    if (completing) {
      console.log(JSON.stringify(await completeMacosDmg({api, manifestPath: process.argv[3]})));
    } else {
      const recordRun = receipt => {
        console.log('- '+receipt.operation+' · '+receipt.state+' · '+receipt.version+'('+receipt.build+') · '+receipt.packageKind+
          ' · upload false · attempt '+receipt.attempt+' · approved `'+receipt.approvedSourceSha+'`: [run '+receipt.id+']('+receipt.url+')');
        console.log(JSON.stringify({type: 'macos-delivery-bot-receipt', ...receipt}));
      };
      console.log(JSON.stringify(await driveMacosDmg({api, recordRun})));
    }
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
