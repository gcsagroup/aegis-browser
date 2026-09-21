#!/usr/bin/env node

import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';
import {pathToFileURL, URLSearchParams} from 'node:url';
import {inferPromotionTitle} from './promotion-title.mjs';
import {README_FILES, buildCandidate, classifyProductRelationship, readmeEntries, validateCandidate} from './promotion-candidate.mjs';

const PROMOTION_BRANCH_PREFIX = 'automation/promote-';
const QUALITY_WORKFLOW_PATH = '.github/workflows/quality.yml';
const REQUIRED_QUALITY_JOBS = ['quality', 'quality-gate'];
const MARKERS = Object.freeze({
  upstreamSync: '<!-- aegis-promotion-orchestrator:upstream-to-main -->',
  sync: '<!-- aegis-promotion-orchestrator:main-to-develop -->',
  promotion: '<!-- aegis-promotion-orchestrator:develop-to-main -->',
  upstream: '<!-- aegis-promotion-orchestrator:upstream-main -->',
});

export {inferPromotionTitle, parseConventionalTitle} from './promotion-title.mjs';

function command(commandName, args, options = {}) {
  const env = options.env ?? process.env;
  const allowStatuses = options.allowStatuses ?? [0];
  const result = spawnSync(commandName, args, {encoding: 'utf8', env});
  if (result.error) throw result.error;
  if (!allowStatuses.includes(result.status)) {
    const detail = [result.stderr, result.stdout].filter(Boolean).join('\n').trim();
    const detailSuffix = detail ? `: ${detail}` : '';
    throw new Error(`${commandName} ${args.join(' ')} failed with status ${result.status}${detailSuffix}`);
  }
  return result;
}

function git(...args) {
  return command('git', args).stdout.trim();
}

function secretEnv(token) {
  return {...process.env, GH_TOKEN: token};
}

function requireToken(name, token) {
  if (!token) throw new Error(`${name} is required for this promotion transition`);
  return token;
}

export function loadPromotionConfig(env = process.env) {
  const personalRepo = env.GITHUB_REPOSITORY;
  const readToken = env.GH_TOKEN;
  if (!personalRepo || !readToken) throw new Error('GITHUB_REPOSITORY and GH_TOKEN are required');
  return {
    personalRepo,
    upstreamRepo: env.AEGIS_UPSTREAM_REPOSITORY || 'gcsagroup/aegis-browser',
    readToken,
    forkToken: requireToken('AEGIS_FORK_AUTOMATION_TOKEN', env.AEGIS_FORK_AUTOMATION_TOKEN),
    upstreamToken: requireToken('AEGIS_UPSTREAM_TOKEN', env.AEGIS_UPSTREAM_TOKEN),
  };
}

export function classifyBranchRelationship({originMain, upstreamMain, originMainAncestor, upstreamMainAncestor}) {
  if (originMain === upstreamMain) return 'same';
  if (originMainAncestor && !upstreamMainAncestor) return 'origin-behind';
  if (!originMainAncestor && upstreamMainAncestor) return 'origin-ahead';
  return 'diverged';
}

function qualityRunMatches(run, {repo, branch, sha}) {
  return qualityRunSourceMatches(run) &&
    qualityRunTargetMatches(run, {repo, branch, sha});
}

function qualityRunSourceMatches(run) {
  return run?.event === 'push' && run?.path === QUALITY_WORKFLOW_PATH;
}

function qualityRunTargetMatches(run, {repo, branch, sha}) {
  return run?.head_branch === branch && run?.head_sha === sha &&
    run?.repository?.full_name === repo;
}

function qualityRunState(run, expected) {
  if (!run) return 'missing';
  if (!qualityRunMatches(run, expected)) return 'failure';
  if (run.status !== 'completed') return 'pending';
  return run.conclusion === 'success' ? 'success' : 'failure';
}

function requiredQualityJobsState(jobs, run, expected) {
  for (const name of REQUIRED_QUALITY_JOBS) {
    const matches = (jobs ?? []).filter((job) => job?.name === name);
    if (matches.length !== 1) return 'failure';
    const job = matches[0];
    if (job.run_id !== run.id || job.head_sha !== expected.sha ||
        job.run_attempt !== run.run_attempt) return 'failure';
    if (job.status !== 'completed') return 'pending';
    if (job.conclusion !== 'success') return 'failure';
  }
  return 'success';
}

export function qualityWorkflowRunState(run, jobs, expected) {
  const runState = qualityRunState(run, expected);
  return runState === 'success'
    ? requiredQualityJobsState(jobs, run, expected)
    : runState;
}

function latestQualityRun(workflowRuns, expected) {
  return (workflowRuns ?? [])
    .filter((run) => qualityRunMatches(run, expected))
    .sort((left, right) => Number(right.id ?? 0) - Number(left.id ?? 0))[0];
}

function finalQualityAttemptState(run, finalRun, attempt, jobs, expected) {
  if (finalRun?.id !== run.id) return 'failure';
  if (finalRun.run_attempt !== attempt) return 'pending';
  return qualityWorkflowRunState(finalRun, jobs, expected);
}

async function verifiedQualityRunState(repo, run, expected, token, apiFn) {
  const state = qualityRunState(run, expected);
  if (state !== 'success') return state;
  const attempt = Number(run.run_attempt);
  if (!Number.isInteger(attempt) || attempt < 1) return 'failure';
  const result = await apiFn(repo, `/actions/runs/${run.id}/attempts/${attempt}/jobs?per_page=100`, {token});
  const finalRun = await apiFn(repo, `/actions/runs/${run.id}`, {token});
  return finalQualityAttemptState(run, finalRun, attempt, result?.jobs, expected);
}

export function closedPullBlocks(pr, expectedHeadSha) {
  return Boolean(pr && pr.state === 'closed' && !pr.merged_at && pr.head?.sha === expectedHeadSha);
}

async function githubApi(repo, path, {token = process.env.GH_TOKEN, method = 'GET', body} = {}) {
  const headers = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'aegis-promotion-orchestrator',
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const response = await globalThis.fetch(`https://api.github.com/repos/${repo}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`GitHub API ${method} ${repo}${path} failed: ${response.status} ${text.slice(0, 800)}`);
  return text ? JSON.parse(text) : null;
}

function repoOwner(repo) {
  const [owner] = repo.split('/');
  if (!owner) throw new Error(`Invalid repository: ${repo}`);
  return owner;
}

function ensureRemote(name, url) {
  const existing = command('git', ['remote', 'get-url', name], {allowStatuses: [0, 2, 128]});
  if (existing.status === 0) git('remote', 'set-url', name, url);
  else git('remote', 'add', name, url);
}

function refreshBranches({personalRepo, upstreamRepo, forkToken, upstreamToken}) {
  ensureRemote('origin', `https://github.com/${personalRepo}.git`);
  ensureRemote('upstream', `https://github.com/${upstreamRepo}.git`);
  setupGitAuth(forkToken);
  command('git', ['fetch', '--prune', 'origin', '+refs/heads/main:refs/remotes/origin/main', '+refs/heads/develop:refs/remotes/origin/develop'], {
    env: secretEnv(forkToken),
  });
  setupGitAuth(upstreamToken);
  command('git', ['fetch', '--prune', 'upstream', '+refs/heads/main:refs/remotes/upstream/main'], {
    env: secretEnv(upstreamToken),
  });
}

function sha(ref) {
  return git('rev-parse', ref);
}

function isAncestor(ancestor, descendant) {
  const result = command('git', ['merge-base', '--is-ancestor', ancestor, descendant], {allowStatuses: [0, 1]});
  return result.status === 0;
}

function branchRelationship() {
  const originMain = sha('origin/main');
  const upstreamMain = sha('upstream/main');
  return {
    originMain,
    upstreamMain,
    state: classifyProductRelationship(originMain, upstreamMain),
  };
}

export async function requireGreenQuality(
  repo,
  branch,
  commitSha,
  token,
  apiFn = githubApi,
) {
  const expected = {repo, branch, sha: commitSha};
  const query = new URLSearchParams({branch, event: 'push', head_sha: commitSha, per_page: '100'});
  const result = await apiFn(repo, `/actions/workflows/quality.yml/runs?${query}`, {token});
  const selected = latestQualityRun(result?.workflow_runs, expected);
  if (!selected) {
    console.log(`Deferred: ${repo}:${branch}@${commitSha.slice(0, 12)} quality workflow is missing`);
    return false;
  }
  const run = await apiFn(repo, `/actions/runs/${selected.id}`, {token});
  const state = await verifiedQualityRunState(repo, run, expected, token, apiFn);
  if (state === 'success') return true;
  if (state === 'missing' || state === 'pending') {
    console.log(`Deferred: ${repo}:${branch}@${commitSha.slice(0, 12)} quality workflow is ${state}`);
    return false;
  }
  throw new Error(`${repo}:${branch}@${commitSha.slice(0, 12)} quality workflow failed`);
}

async function listPulls(repo, state, token) {
  return githubApi(repo, `/pulls?state=${state}&per_page=100&sort=updated&direction=desc`, {token});
}

function isHead(pr, repo, branch) {
  return pr?.head?.repo?.full_name === repo && pr?.head?.ref === branch;
}

function hasMarker(pr, marker) {
  return String(pr?.body ?? '').includes(marker);
}

function hasBase(pr, branch) {
  return pr?.base?.ref === branch;
}

function isPromotionHead(pr, personalRepo) {
  const branch = String(pr?.head?.ref ?? '');
  return pr?.head?.repo?.full_name === personalRepo && branch.startsWith(PROMOTION_BRANCH_PREFIX);
}

function candidatePersonalPull(pr, personalRepo) {
  if (hasBase(pr, 'develop') && isHead(pr, personalRepo, 'main')) return 'sync';
  if (hasBase(pr, 'main') && pr?.head?.repo?.full_name === personalRepo &&
      String(pr?.head?.ref ?? '').startsWith('automation/upstream-sync-')) return 'upstreamSync';
  if (hasBase(pr, 'main') && isPromotionHead(pr, personalRepo)) return 'promotion';
  return null;
}

function candidateUpstreamPull(pr, personalRepo) {
  return hasBase(pr, 'main') && pr?.head?.repo?.full_name === personalRepo &&
    (pr.head.ref === 'main' || String(pr.head.ref).startsWith('automation/export-'));
}

function runGh(args, token) {
  return command('gh', args, {env: secretEnv(token)}).stdout.trim();
}

function ensureCopilotReview(repo, pullNumber, token) {
  runGh(['pr', 'edit', String(pullNumber), '--repo', repo, '--add-reviewer', '@copilot'], token);
  console.log(`Copilot review requested for ${repo}#${pullNumber}`);
}

function isCopilotLogin(login) {
  return String(login ?? '').toLowerCase().includes('copilot');
}

async function hasCurrentCopilotReview(repo, pull, token) {
  const [requested, reviews] = await Promise.all([
    githubApi(repo, `/pulls/${pull.number}/requested_reviewers`, {token}),
    githubApi(repo, `/pulls/${pull.number}/reviews?per_page=100`, {token}),
  ]);
  if ((requested?.users ?? []).some((user) => isCopilotLogin(user?.login))) return true;
  return (reviews ?? []).some((review) => isCopilotLogin(review?.user?.login) && review?.commit_id === pull?.head?.sha);
}

async function ensureCurrentCopilotReview(repo, pull, token) {
  if (await hasCurrentCopilotReview(repo, pull, token)) {
    console.log(`Copilot review is already requested or current for ${repo}#${pull.number}`);
    return;
  }
  ensureCopilotReview(repo, pull.number, token);
}

function ensureAutoMerge(repo, pullNumber, token) {
  runGh(['pr', 'merge', String(pullNumber), '--repo', repo, '--auto', '--merge'], token);
  console.log(`Merge-commit auto-merge enabled for ${repo}#${pullNumber}`);
}

function ensureExistingAutoMerge(repo, pull, token) {
  if (pull?.auto_merge) {
    console.log(`Merge-commit auto-merge is already enabled for ${repo}#${pull.number}`);
    return;
  }
  ensureAutoMerge(repo, pull.number, token);
}

async function createPull({repo, base, head, title, body, token}) {
  return githubApi(repo, '/pulls', {
    token,
    method: 'POST',
    body: {base, head, title, body: `${body.trim()}\n`},
  });
}

function setupGitAuth(token) {
  command('gh', ['auth', 'setup-git'], {env: secretEnv(token)});
}

function remoteOriginBranchSha(branch, token) {
  setupGitAuth(token);
  const result = command('git', ['ls-remote', '--exit-code', '--heads', 'origin', `refs/heads/${branch}`], {
    env: secretEnv(token),
    allowStatuses: [0, 2],
  });
  if (result.status === 2) return null;
  return result.stdout.trim().split(/\s+/u)[0] || null;
}

function fetchOriginBranch(branch, token) {
  setupGitAuth(token);
  command('git', ['fetch', 'origin', `+refs/heads/${branch}:refs/remotes/origin/${branch}`], {
    env: secretEnv(token),
  });
}

function promotionSubjects(baseRef, headRef) {
  const output = git('log', '--reverse', '--format=%s', `${baseRef}..${headRef}`);
  return output ? output.split(/\r?\n/u) : [];
}

function promotionTitle(baseRef, headRef) {
  const title = inferPromotionTitle(promotionSubjects(baseRef, headRef));
  if (!title) throw new Error(`No unambiguous Conventional Commit title found in ${baseRef}..${headRef}`);
  return title;
}

async function findLatestMatchingPull(repo, personalRepo, {base, branch}, token) {
  const pulls = await listPulls(repo, 'all', token);
  return pulls.find((pr) => pr?.base?.ref === base && isHead(pr, personalRepo, branch)) ?? null;
}

export function inspectOpenPromotionPulls({personalOpen, upstreamOpen, personalRepo, upstreamRepo}) {
  const personalCandidates = personalOpen
    .map((pr) => ({pr, kind: candidatePersonalPull(pr, personalRepo)}))
    .filter((entry) => entry.kind);
  const upstreamCandidates = upstreamOpen.filter((pr) => candidateUpstreamPull(pr, personalRepo));
  const manualPersonal = personalCandidates.find(({pr, kind}) => !hasMarker(pr, MARKERS[kind]));
  if (manualPersonal) {
    return {
      status: 'manual',
      message: `existing non-automation PR ${personalRepo}#${manualPersonal.pr.number} uses the promotion path`,
    };
  }
  const manualUpstream = upstreamCandidates.find((pr) => !hasMarker(pr, MARKERS.upstream));
  if (manualUpstream) {
    return {
      status: 'manual',
      message: `existing non-automation upstream PR ${upstreamRepo}#${manualUpstream.number} uses ${repoOwner(personalRepo)}:main`,
    };
  }

  const automation = [
    ...personalCandidates.filter(({pr, kind}) => hasMarker(pr, MARKERS[kind])).map(({pr, kind}) => ({repo: personalRepo, pr, kind})),
    ...upstreamCandidates.filter((pr) => hasMarker(pr, MARKERS.upstream)).map((pr) => ({repo: upstreamRepo, pr, kind: 'upstream'})),
  ];
  if (automation.length > 1) return {status: 'multiple', automation};
  if (automation.length === 0) return {status: 'none'};
  return {status: 'active', active: automation[0]};
}

function dependency(value, fallback) {
  return value === undefined ? fallback : value;
}

function activePullDependencies(deps) {
  return {
    git: dependency(deps.git, git),
    sha: dependency(deps.sha, sha),
    assertHeads: dependency(deps.assertHeads, assertRemoteHeads),
    build: dependency(deps.build, buildCandidate),
    fetchBranch: dependency(deps.fetchBranch, fetchOriginBranch),
    validate: dependency(deps.validate, validateCandidate),
  };
}

async function validateSyncPull(pr, config, relation, deps) {
  if (pr.head.sha !== relation.originMain || pr.base.sha !== deps.sha('origin/develop')) throw new Error('Fail closed: sync PR source/base changed');
  await deps.assertHeads(sourceHeads(config, relation, pr.base.sha));
}

function validateLegacyUpstreamPull(pr, relation, deps) {
  if (pr.head.sha !== relation.originMain ||
      deps.git('diff', '--name-only', relation.originMain, relation.upstreamMain, '--', ...README_FILES)) {
    throw new Error('Fail closed: legacy personal:main upstream PR would export personal README changes');
  }
}

async function validatePersonalPromotionPull(pr, config, relation, deps) {
  const develop = deps.sha('origin/develop');
  if (pr.head.ref !== `${PROMOTION_BRANCH_PREFIX}${develop}-${relation.originMain}` || pr.head.sha !== develop) {
    throw new Error('Fail closed: stale or legacy personal promotion candidate');
  }
  await deps.assertHeads(sourceHeads(config, relation, develop));
}

function validateImmutablePull({pr, kind}, config, relation, deps) {
  const branch = pr.head.ref;
  const candidate = deps.build(kind === 'upstream' ? 'export' : 'upstream-sync', relation.originMain, relation.upstreamMain);
  if (candidate.branch !== branch) throw new Error('Fail closed: stale candidate source SHAs');
  deps.fetchBranch(branch, config.forkToken);
  const fetched = deps.sha(`origin/${branch}`);
  if (fetched !== pr.head.sha) throw new Error('Fail closed: active PR head changed');
  deps.validate(candidate, fetched);
}

async function validateActiveCandidatePull(active, config, relation, deps) {
  const {pr, kind} = active;
  const base = kind === 'upstream' ? relation.upstreamMain : relation.originMain;
  if (pr.base.sha !== base) throw new Error('Fail closed: active candidate PR base changed');
  if (pr.auto_merge) throw new Error('Fail closed: candidate PR must wait for explicit final CI/review and merge');
  if (kind === 'upstream' && pr.head.ref === 'main') {
    validateLegacyUpstreamPull(pr, relation, deps);
  } else if (kind === 'promotion') {
    await validatePersonalPromotionPull(pr, config, relation, deps);
  } else {
    validateImmutablePull(active, config, relation, deps);
  }
}

export async function validateActivePull(active, config, deps = {}) {
  const operations = activePullDependencies(deps);
  const relation = {originMain: operations.sha('origin/main'), upstreamMain: operations.sha('upstream/main')};
  const {pr, kind} = active;
  if (kind === 'sync') {
    await validateSyncPull(pr, config, relation, operations);
    return;
  }
  await validateActiveCandidatePull(active, config, relation, operations);
  await operations.assertHeads([...sourceHeads(config, relation),
    {repo: config.personalRepo, branch: pr.head.ref, sha: pr.head.sha, token: config.forkToken}]);
}

async function handleExistingPulls(personalRepo, upstreamRepo, forkToken, upstreamToken) {
  const personalOpen = await listPulls(personalRepo, 'open', forkToken);
  const upstreamOpen = await listPulls(upstreamRepo, 'open', upstreamToken);
  const inspection = inspectOpenPromotionPulls({personalOpen, upstreamOpen, personalRepo, upstreamRepo});
  if (inspection.status === 'manual') {
    console.log(`Deferred: ${inspection.message}`);
    return true;
  }
  if (inspection.status === 'multiple') {
    throw new Error(`Multiple promotion PRs are open: ${inspection.automation.map(({repo, pr}) => `${repo}#${pr.number}`).join(', ')}`);
  }
  if (inspection.status === 'none') return false;

  const {active} = inspection;
  await validateActivePull(active, {personalRepo, upstreamRepo, forkToken, upstreamToken});
  if (active.kind === 'upstream') {
    await ensureCurrentCopilotReview(active.repo, active.pr, upstreamToken);
  } else {
    await ensureCurrentCopilotReview(active.repo, active.pr, forkToken);
    if (active.kind === 'sync') ensureExistingAutoMerge(active.repo, active.pr, forkToken);
  }
  console.log(`Deferred: waiting for ${active.kind} PR ${active.repo}#${active.pr.number}`);
  return true;
}

async function createMainToDevelopSync(personalRepo, forkToken, originMain) {
  const existing = await findLatestMatchingPull(personalRepo, personalRepo, {base: 'develop', branch: 'main'}, forkToken);
  if (closedPullBlocks(existing, originMain)) {
    throw new Error(`Previous main -> develop PR #${existing.number} was closed without merge for ${originMain.slice(0, 12)}`);
  }
  const pull = await createPull({
    repo: personalRepo,
    base: 'develop',
    head: 'main',
    title: 'chore(sync): merge main into develop',
    token: forkToken,
    body: `${MARKERS.sync}\n\nSync the latest personal main into develop before the next public promotion.\n\n- source: \`${originMain}\`\n- merge method: merge commit\n- automation: serial; the next transition waits for this PR and the resulting develop push CI`,
  });
  ensureCopilotReview(personalRepo, pull.number, forkToken);
  ensureAutoMerge(personalRepo, pull.number, forkToken);
  console.log(`Created main -> develop sync PR: ${pull.html_url}`);
}

// Ref creation uses the GitHub create-ref API: an existing name is never updated,
// even if another writer creates it between inspection and publication.
export async function assertRemoteHeads(expected, apiFn = githubApi) {
  for (const {repo, branch, sha: expectedSha, token} of expected) {
    const ref = await apiFn(repo, `/git/ref/heads/${branch}`, {token});
    if (ref?.object?.sha !== expectedSha) throw new Error(`Fail closed: ${repo}:${branch} changed during candidate preparation`);
  }
}

function sourceHeads(config, relation, develop) {
  const heads = [
    {repo: config.personalRepo, branch: 'main', sha: relation.originMain, token: config.forkToken},
    {repo: config.upstreamRepo, branch: 'main', sha: relation.upstreamMain, token: config.upstreamToken},
  ];
  if (develop) heads.push({repo: config.personalRepo, branch: 'develop', sha: develop, token: config.forkToken});
  return heads;
}

export async function publishCandidate(config, candidate, deps = {}) {
  const api = deps.api ?? githubApi;
  const remoteSha = deps.remoteSha ?? remoteOriginBranchSha;
  const fetchBranch = deps.fetchBranch ?? fetchOriginBranch;
  const validate = deps.validate ?? validateCandidate;
  const entries = deps.entries ?? readmeEntries;
  const assertSources = () => assertRemoteHeads(sourceHeads(config, candidate), api);
  await assertSources();
  let head = remoteSha(candidate.branch, config.forkToken);
  if (!head) {
    const tree = await api(config.personalRepo, '/git/trees', {
      token: config.forkToken, method: 'POST',
      body: {base_tree: candidate.baseTree, tree: entries(candidate.readmeSource)},
    });
    if (tree?.sha !== candidate.tree) throw new Error('Fail closed: remote candidate tree mismatch');
    const commit = await api(config.personalRepo, '/git/commits', {
      token: config.forkToken, method: 'POST',
      body: {message: candidate.message, tree: candidate.tree, parents: candidate.parents},
    });
    head = commit.sha;
    await assertSources();
    await api(config.personalRepo, '/git/refs', {
      token: config.forkToken, method: 'POST',
      body: {ref: `refs/heads/${candidate.branch}`, sha: head},
    });
  }
  fetchBranch(candidate.branch, config.forkToken);
  // Fetch and ls-remote must agree; validate the fetched object, not an old local SHA.
  const fetched = (deps.sha ?? sha)(`origin/${candidate.branch}`);
  if (head !== fetched) throw new Error('Fail closed: candidate branch changed during fetch');
  validate(candidate, fetched);
  await assertSources();
  await assertRemoteHeads([{repo: config.personalRepo, branch: candidate.branch, sha: head, token: config.forkToken}], api);
  return head;
}

function assertPullIdentity(pull, config, baseRepo, baseSha, branch, head) {
  if (pull?.base?.repo?.full_name !== baseRepo || pull?.base?.ref !== 'main' ||
      pull?.base?.sha !== baseSha || !isHead(pull, config.personalRepo, branch) || pull?.head?.sha !== head) {
    throw new Error('Fail closed: created PR identity changed; review and CI must cover the new base/head');
  }
}

async function createDevelopToMainPromotion(config, relation, originDevelop) {
  const branch = `${PROMOTION_BRANCH_PREFIX}${originDevelop}-${relation.originMain}`;
  const previous = await findLatestMatchingPull(config.personalRepo, config.personalRepo, {base: 'main', branch}, config.forkToken);
  if (previous?.state === 'closed') throw new Error(`Fail closed: previous promotion PR #${previous.number} is closed`);
  if (git('rev-parse', `${relation.originMain}^{tree}`) === git('rev-parse', `${originDevelop}^{tree}`)) {
    console.log('No personal tree changes are waiting for promotion');
    return;
  }
  const title = promotionTitle(relation.originMain, originDevelop);
  await assertRemoteHeads(sourceHeads(config, relation, originDevelop));
  const existing = remoteOriginBranchSha(branch, config.forkToken);
  if (existing && existing !== originDevelop) throw new Error('Fail closed: existing promotion branch changed');
  if (!existing) await githubApi(config.personalRepo, '/git/refs', {
    token: config.forkToken, method: 'POST', body: {ref: `refs/heads/${branch}`, sha: originDevelop},
  });
  await assertRemoteHeads([...sourceHeads(config, relation, originDevelop),
    {repo: config.personalRepo, branch, sha: originDevelop, token: config.forkToken}]);
  const pull = await createPull({
    repo: config.personalRepo, base: 'main', head: branch, title, token: config.forkToken,
    body: `${MARKERS.promotion}\n\nPromote the complete validated personal develop tree, including its personal README badges.\n\n- develop source and promotion head: \`${originDevelop}\`\n- personal base: \`${relation.originMain}\`\n- merge method: merge commit\n- resulting main push CI is required before export`,
  });
  assertPullIdentity(pull, config, config.personalRepo, relation.originMain, branch, originDevelop);
  await assertRemoteHeads([...sourceHeads(config, relation, originDevelop),
    {repo: config.personalRepo, branch, sha: originDevelop, token: config.forkToken}]);
  ensureCopilotReview(config.personalRepo, pull.number, config.forkToken);
  // Candidate PRs require an explicit merge after final base/head review and CI.
  // In particular, an advancing base must not auto-merge a stale snapshot.
  console.log(`Created develop -> main promotion PR: ${pull.html_url}`);
}

async function createCandidatePull(config, relation, kind) {
  const candidate = buildCandidate(kind, relation.originMain, relation.upstreamMain);
  const exporting = kind === 'export';
  const repo = exporting ? config.upstreamRepo : config.personalRepo;
  const token = exporting ? config.upstreamToken : config.forkToken;
  const previous = await findLatestMatchingPull(repo, config.personalRepo, {base: 'main', branch: candidate.branch}, token);
  if (previous?.state === 'closed') throw new Error(`Fail closed: previous candidate PR #${previous.number} is closed`);
  const title = exporting ? promotionTitle(relation.upstreamMain, relation.originMain) : 'chore(sync): merge upstream while preserving personal README';
  const head = await publishCandidate(config, candidate);
  await assertRemoteHeads([...sourceHeads(config, relation),
    {repo: config.personalRepo, branch: candidate.branch, sha: head, token: config.forkToken}]);
  const pull = await createPull({
    repo, base: 'main', head: exporting ? `${repoOwner(config.personalRepo)}:${candidate.branch}` : candidate.branch,
    title, token,
    body: `${exporting ? MARKERS.upstream : MARKERS.upstreamSync}\n\n${exporting ? 'Export the validated personal main with exactly the upstream README files.' : 'Merge upstream product changes and retain exactly the personal main README files.'}\n\n- personal main: \`${relation.originMain}\`\n- upstream main: \`${relation.upstreamMain}\`\n- immutable candidate: \`${head}\`\n- final candidate PR CI and review are required; source push CI is not candidate CI\n- no automatic merge; merge commit is required for personal synchronization`,
  });
  assertPullIdentity(pull, config, repo, exporting ? relation.upstreamMain : relation.originMain, candidate.branch, head);
  await assertRemoteHeads([...sourceHeads(config, relation),
    {repo: config.personalRepo, branch: candidate.branch, sha: head, token: config.forkToken}]);
  ensureCopilotReview(repo, pull.number, token);
  console.log(`Created ${kind} PR: ${pull.html_url}`);
}

async function createUpstreamPromotion(config, relation) {
  await createCandidatePull(config, relation, 'export');
}

async function createUpstreamSync(config, relation) {
  await createCandidatePull(config, relation, 'upstream-sync');
}

function mainRelationshipIsStable(actual, expected, state) {
  return actual.state === state
    && actual.originMain === expected.originMain
    && actual.upstreamMain === expected.upstreamMain;
}

async function handleOriginBehind(config, relation, deps) {
  if (!await deps.requireGreenQuality(config.upstreamRepo, 'main', relation.upstreamMain, config.upstreamToken)) return;
  deps.refreshBranches(config);
  const refreshed = deps.branchRelationship();
  if (!mainRelationshipIsStable(refreshed, relation, 'origin-behind')) {
    deps.log('Deferred: main relationship changed after upstream quality verification');
    return;
  }
  await deps.createUpstreamSync(config, refreshed);
}

async function handleOriginAhead(config, relation, deps) {
  if (!await deps.requireGreenQuality(config.personalRepo, 'main', relation.originMain, config.readToken)) return;
  deps.refreshBranches(config);
  const refreshed = deps.branchRelationship();
  if (!mainRelationshipIsStable(refreshed, relation, 'origin-ahead')) {
    deps.log('Deferred: main relationship changed after personal main quality verification');
    return;
  }
  await deps.createUpstreamPromotion(config, refreshed);
}

async function handleDevelopPromotion(config, relation, deps) {
  const currentDevelop = deps.sha('origin/develop');
  if (currentDevelop === relation.originMain) {
    deps.log('No develop changes are waiting for promotion');
    return;
  }
  if (!await deps.requireGreenQuality(config.personalRepo, 'develop', currentDevelop, config.readToken)) return;
  deps.refreshBranches(config);
  const refreshed = deps.branchRelationship();
  const refreshedDevelop = deps.sha('origin/develop');
  if (!mainRelationshipIsStable(refreshed, relation, 'same') ||
      refreshedDevelop !== currentDevelop) {
    deps.log(`Deferred: branch state changed during develop quality verification (${refreshed.state})`);
    return;
  }
  await deps.createDevelopToMainPromotion(config, refreshed, refreshedDevelop);
}

async function handleSameMain(config, relation, deps) {
  if (!await deps.requireGreenQuality(config.personalRepo, 'main', relation.originMain, config.readToken)) return;
  deps.refreshBranches(config);
  const refreshed = deps.branchRelationship();
  if (!mainRelationshipIsStable(refreshed, relation, 'same')) {
    deps.log(`Deferred: main relationship changed after personal main quality verification (${refreshed.state})`);
    return;
  }
  if (!deps.isAncestor('origin/main', 'origin/develop')) {
    await deps.createMainToDevelopSync(config.personalRepo, config.forkToken, refreshed.originMain);
    return;
  }
  await handleDevelopPromotion(config, refreshed, deps);
}

function handleDiverged(_config, relation) {
  throw new Error(`Fail closed: personal main ${relation.originMain.slice(0, 12)} and upstream main ${relation.upstreamMain.slice(0, 12)} diverged`);
}

function defaultPromotionDependencies() {
  return {
    refreshBranches,
    handleExistingPulls,
    branchRelationship,
    requireGreenQuality,
    createUpstreamSync,
    createUpstreamPromotion,
    isAncestor,
    createMainToDevelopSync,
    sha,
    createDevelopToMainPromotion,
    log: (message) => console.log(message),
  };
}

const TRANSITION_HANDLERS = Object.freeze({
  'origin-behind': handleOriginBehind,
  'origin-ahead': handleOriginAhead,
  same: handleSameMain,
  diverged: handleDiverged,
});

export async function runPromotionCycle(config, deps = defaultPromotionDependencies()) {
  deps.refreshBranches(config);
  if (await deps.handleExistingPulls(config.personalRepo, config.upstreamRepo, config.forkToken, config.upstreamToken)) return;
  const relation = deps.branchRelationship();
  const handler = TRANSITION_HANDLERS[relation.state];
  if (!handler) throw new Error(`Unknown main relationship state: ${relation.state}`);
  await handler(config, relation, deps);
}

async function main() {
  await runPromotionCycle(loadPromotionConfig());
}

const invoked = process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
if (invoked) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
