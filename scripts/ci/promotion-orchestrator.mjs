#!/usr/bin/env node
import {resolve} from 'node:path';
import {pathToFileURL, URLSearchParams} from 'node:url';
import {buildCandidate, parseCandidate, sameTree, validateCandidate} from './promotion-candidate.mjs';
import {assertRemoteHeads, command, git, githubApi, isAncestor, listPulls} from './promotion-github.mjs';
import {requireGreenQuality} from './promotion-quality.mjs';
import {inferPromotionTitle} from './promotion-title.mjs';

export const MODE = 'direct-upstream-v2';
const PERSONAL = 'quinn521/aegis-browser';
const UPSTREAM = 'gcsagroup/aegis-browser';

export function loadPromotionConfig(env = process.env) {
  if (env.GITHUB_REPOSITORY !== PERSONAL || env.GITHUB_REF !== 'refs/heads/develop' ||
      !['push', 'schedule', 'workflow_dispatch'].includes(env.GITHUB_EVENT_NAME) ||
      env.AEGIS_PROMOTION_AUTOMATION !== MODE) {
    throw new Error('Controller requires the personal develop trusted context and v2 opt-in');
  }
  for (const name of ['GH_TOKEN', 'AEGIS_FORK_AUTOMATION_TOKEN', 'AEGIS_UPSTREAM_TOKEN']) {
    if (!env[name]) throw new Error(`${name} is required`);
  }
  return {personalRepo: PERSONAL, upstreamRepo: UPSTREAM, readToken: env.GH_TOKEN,
    forkToken: env.AEGIS_FORK_AUTOMATION_TOKEN, upstreamToken: env.AEGIS_UPSTREAM_TOKEN};
}

export function classifyBranchRelationship({originMain, upstreamMain, originMainAncestor, upstreamMainAncestor}) {
  if (originMain === upstreamMain) return 'same';
  if (originMainAncestor && !upstreamMainAncestor) return 'origin-behind';
  if (upstreamMainAncestor && !originMainAncestor) return 'origin-ahead';
  return 'diverged';
}

function headRef(repo, branch, sha, token) {
  return {repo, branch, sha, token};
}

function sourceRefs(config, state, includeDevelop = true) {
  return [headRef(config.personalRepo, 'main', state.originMain, config.forkToken),
    headRef(config.upstreamRepo, 'main', state.upstreamMain, config.upstreamToken),
    ...(includeDevelop ? [headRef(config.personalRepo, 'develop', state.develop, config.forkToken)] : [])];
}

function fetchBranch(repo, branch, token) {
  // Credentials stay in the environment; fetched code is never executed here.
  command('gh', ['auth', 'setup-git'], {token});
  command('git', ['fetch', `https://github.com/${repo}.git`, `refs/heads/${branch}`], {token});
  return git('rev-parse', 'FETCH_HEAD');
}

function refresh(config) {
  const originMain = fetchBranch(config.personalRepo, 'main', config.forkToken);
  const develop = fetchBranch(config.personalRepo, 'develop', config.forkToken);
  const upstreamMain = fetchBranch(config.upstreamRepo, 'main', config.upstreamToken);
  return {originMain, upstreamMain, develop, state: classifyBranchRelationship({originMain, upstreamMain,
    originMainAncestor: isAncestor(originMain, upstreamMain), upstreamMainAncestor: isAncestor(upstreamMain, originMain)})};
}

export function inspectOpenPromotionPulls({personalOpen, upstreamOpen, personalRepo, upstreamRepo}) {
  // Any upstream PR from this fork blocks another batch, including legacy #22.
  const upstream = upstreamOpen.filter((pr) => pr.base?.ref === 'main' && pr.head?.repo?.full_name === personalRepo);
  const personal = personalOpen.filter((pr) => pr.base?.ref === 'main' ||
    (pr.base?.ref === 'develop' && pr.head?.repo?.full_name === personalRepo &&
      (pr.head?.ref === 'main' || /^(?:codex\/backflow-|automation\/)/u.test(pr.head?.ref ?? ''))));
  const active = [...upstream.map((pr) => ({repo: upstreamRepo, pr})), ...personal.map((pr) => ({repo: personalRepo, pr}))];
  if (active.length > 1) throw new Error('Multiple active promotion/backflow paths require coordinator reconciliation');
  return active[0] ?? null;
}

export async function validateActivePull(active, config, deps = {}) {
  const candidate = parseCandidate(active.pr.head?.ref ?? '');
  if (!candidate) return false; // Legacy/manual path: wait without adopting or modifying it.
  const {pr, repo} = active;
  const expectedRepo = candidate.kind === 'promotion' ? config.upstreamRepo : config.personalRepo;
  const expectedBase = candidate.kind === 'promotion' ? 'main' : 'develop';
  if (repo !== expectedRepo || pr.base?.repo?.full_name !== expectedRepo || pr.base?.ref !== expectedBase ||
      pr.head?.repo?.full_name !== config.personalRepo || pr.auto_merge) {
    throw new Error('Candidate identity changed or unverified auto-merge is enabled');
  }
  const fetched = (deps.fetchBranch ?? fetchBranch)(config.personalRepo, candidate.branch, config.forkToken);
  if (fetched !== pr.head.sha) throw new Error('Candidate changed during fetch');
  validateCandidate(candidate, fetched, deps.isAncestor ?? isAncestor);
  await (deps.assertHeads ?? assertRemoteHeads)([headRef(config.personalRepo, candidate.branch, fetched, config.forkToken),
    headRef(expectedRepo, expectedBase, pr.base.sha, candidate.kind === 'promotion' ? config.upstreamToken : config.forkToken)]);
  return true;
}

async function inventory(config) {
  const [personalOpen, upstreamOpen] = await Promise.all([
    listPulls(config.personalRepo, config.forkToken), listPulls(config.upstreamRepo, config.upstreamToken),
  ]);
  return inspectOpenPromotionPulls({...config, personalOpen, upstreamOpen});
}

export async function mirrorMain(config, state, deps = {}) {
  if (state.state !== 'origin-behind') throw new Error('Mirror requires a fast-forward relationship');
  const api = deps.api ?? githubApi;
  await (deps.assertHeads ?? assertRemoteHeads)(sourceRefs(config, state, false), api);
  const [repo, protection] = await Promise.all([
    api(config.personalRepo, '', {token: config.forkToken}),
    api(config.personalRepo, '/branches/main/protection', {token: config.forkToken}),
  ]);
  if (repo.parent?.full_name !== config.upstreamRepo || !protection.lock_branch?.enabled ||
      !protection.allow_fork_syncing?.enabled || !protection.enforce_admins?.enabled ||
      protection.allow_force_pushes?.enabled || protection.allow_deletions?.enabled) {
    throw new Error('Mirror requires a locked fork branch, enforced protection and upstream-only syncing');
  }
  await (deps.assertHeads ?? assertRemoteHeads)(sourceRefs(config, state, false), api);
  const result = await api(config.personalRepo, '/merge-upstream', {
    token: config.forkToken, method: 'POST', body: {branch: 'main'},
  });
  if (!['fast-forward', 'none'].includes(result?.merge_type)) throw new Error('Unexpected fork sync result; mirror equality is unverified');
  const main = await api(config.personalRepo, '/git/ref/heads/main', {token: config.forkToken});
  const upstream = await api(config.upstreamRepo, '/git/ref/heads/main', {token: config.upstreamToken});
  if (main?.object?.sha !== upstream?.object?.sha) throw new Error('Upstream changed or mirror differs; retry with fresh refs');
  return main.object.sha;
}

async function remoteBranch(config, branch) {
  const result = command('git', ['ls-remote', '--heads', `https://github.com/${config.personalRepo}.git`, `refs/heads/${branch}`], {token: config.forkToken});
  return result.split(/\s+/u)[0] || null;
}

export async function publishCandidate(config, candidate, state, deps = {}) {
  const api = deps.api ?? githubApi;
  const assertHeads = deps.assertHeads ?? assertRemoteHeads;
  await assertHeads(sourceRefs(config, state), api);
  let head = await (deps.remoteBranch ?? remoteBranch)(config, candidate.branch);
  if (!head) {
    await api(config.personalRepo, '/git/refs', {token: config.forkToken, method: 'POST',
      body: {ref: `refs/heads/${candidate.branch}`, sha: candidate.source}});
    head = candidate.source;
  }
  const fetched = (deps.fetchBranch ?? fetchBranch)(config.personalRepo, candidate.branch, config.forkToken);
  if (head !== fetched) throw new Error('Candidate changed during publication');
  validateCandidate(candidate, head, deps.isAncestor ?? isAncestor);
  await assertHeads([...sourceRefs(config, state), headRef(config.personalRepo, candidate.branch, head, config.forkToken)], api);
  return head;
}

export async function createCandidatePull(config, state, candidate, overrides = {}) {
  const ops = {api: githubApi, listPulls, inventory, publish: publishCandidate, git, command,
    assertHeads: assertRemoteHeads, log: console.log, ...overrides};
  const promotion = candidate.kind === 'promotion';
  const repo = promotion ? config.upstreamRepo : config.personalRepo;
  const token = promotion ? config.upstreamToken : config.forkToken;
  const base = promotion ? 'main' : 'develop';
  const owner = config.personalRepo.split('/')[0];
  const query = new URLSearchParams({state: 'all', base, head: `${owner}:${candidate.branch}`});
  const previous = await ops.listPulls(repo, token, query.toString());
  if (previous.length) throw new Error('Existing/closed batch requires coordinator reconciliation; not reopening or duplicating it');
  if (await ops.inventory(config)) throw new Error('Another promotion path appeared during preparation');
  const head = await ops.publish(config, candidate, state);
  if (promotion) ops.command('node', ['scripts/ci/check-public-diff.mjs', '--base', candidate.base, '--head', head]);
  const subjects = ops.git('log', '--reverse', '--format=%s', `${candidate.base}..${head}`).split('\n');
  const title = promotion ? inferPromotionTitle(subjects) : 'chore(sync): backflow upstream main into develop';
  if (!title) throw new Error('No Conventional Commit title available for candidate');
  const body = `Frozen ${candidate.kind} batch.\n\n- source: \`${candidate.source}\`\n- initial base: \`${candidate.base}\`\n- current head: \`${head}\`\n- review fixes may be appended; every new head requires fresh review and CI\n- merge method: merge commit; no automatic merge\n- upstream promotion requires Codacy and applicable native validation\n- personal main is an exact upstream mirror; all fixes return to develop\n`;
  await ops.assertHeads([...sourceRefs(config, state),
    headRef(config.personalRepo, candidate.branch, head, config.forkToken)]);
  // Concurrency groups cannot serialize other human/automation writers.
  if (await ops.inventory(config)) throw new Error('Another promotion path appeared before PR creation');
  const pull = await ops.api(repo, '/pulls', {token, method: 'POST',
    body: {base, head: `${owner}:${candidate.branch}`, title, body}});
  if (pull.head?.sha !== head || pull.base?.sha !== candidate.base ||
      pull.head?.ref !== candidate.branch || pull.head?.repo?.full_name !== config.personalRepo ||
      pull.base?.repo?.full_name !== repo || pull.base?.ref !== base) throw new Error('PR identity changed during creation');
  const active = await ops.inventory(config);
  if (active?.repo !== repo || active.pr?.number !== pull.number || active.pr.head?.sha !== head) {
    throw new Error('Active promotion path changed after PR creation; coordinator reconciliation required');
  }
  await ops.assertHeads([...sourceRefs(config, state),
    headRef(config.personalRepo, candidate.branch, head, config.forkToken)]);
  // GitHub rulesets request Copilot review. The controller never approves/merges.
  ops.log(`Created ${candidate.kind}: ${pull.html_url}`);
}

function defaults() {
  return {refresh, inventory, validateActive: validateActivePull, mirror: mirrorMain,
    green: requireGreenQuality, ancestor: isAncestor, sameTree, create: createCandidatePull,
    assertHeads: assertRemoteHeads, log: console.log};
}

export async function runPromotionCycle(config, overrides = {}) {
  const ops = {...defaults(), ...overrides};
  const state = await ops.refresh(config);
  // Never synchronize over a personal-only commit, even if trees happen to match.
  const active = await ops.inventory(config);
  if (active) {
    await ops.validateActive(active, config);
    ops.log(`Waiting for ${active.repo}#${active.pr.number}; current head ${active.pr.head.sha}; no branch overwrite or auto-merge`);
    return 'waiting';
  }
  if (['origin-ahead', 'diverged'].includes(state.state)) throw new Error('Personal main is not a mirror; preserve commits and reconcile the migration');
  if (state.state === 'origin-behind') {
    await ops.mirror(config, state);
    return 'mirrored';
  }
  if (state.state !== 'same') throw new Error('Unknown mirror relationship');
  // Failed upstream push CI blocks future batches, not truthful mirroring.
  if (!await ops.green(config.upstreamRepo, 'main', state.upstreamMain, config.upstreamToken)) return 'waiting-quality';
  if (!ops.ancestor(state.upstreamMain, state.develop)) {
    await ops.assertHeads(sourceRefs(config, state));
    await ops.create(config, state, buildCandidate('backflow', state.upstreamMain, state.develop, ops.ancestor));
    return 'backflow';
  }
  if (ops.sameTree(state.upstreamMain, state.develop)) return 'idle';
  if (!await ops.green(config.personalRepo, 'develop', state.develop, config.readToken)) return 'waiting-quality';
  await ops.assertHeads(sourceRefs(config, state));
  await ops.create(config, state, buildCandidate('promotion', state.develop, state.upstreamMain, ops.ancestor));
  return 'promotion';
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  runPromotionCycle(loadPromotionConfig()).catch((error) => {console.error(error.message); process.exitCode = 1;});
}
