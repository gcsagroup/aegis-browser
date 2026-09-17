#!/usr/bin/env node

import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {inferPromotionTitle} from './promotion-title.mjs';

const PROMOTION_BRANCH_PREFIX = 'automation/promote-';
const README_FILES = ['README.md', 'README.zh-CN.md', 'README.zh-TW.md'];
const MARKERS = Object.freeze({
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

export function qualityGateState(checkRuns, sha) {
  const candidates = (checkRuns ?? [])
    .filter((run) => run?.name === 'quality-gate' && run?.head_sha === sha && run?.app?.slug === 'github-actions')
    .sort((left, right) => Number(right.id ?? 0) - Number(left.id ?? 0));
  const latest = candidates[0];
  if (!latest) return 'missing';
  if (latest.status !== 'completed') return 'pending';
  return latest.conclusion === 'success' ? 'success' : 'failure';
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
    state: classifyBranchRelationship({
      originMain,
      upstreamMain,
      originMainAncestor: isAncestor('origin/main', 'upstream/main'),
      upstreamMainAncestor: isAncestor('upstream/main', 'origin/main'),
    }),
  };
}

async function requireGreenQuality(repo, commitSha, token) {
  const result = await githubApi(repo, `/commits/${commitSha}/check-runs?check_name=quality-gate&filter=latest&per_page=100`, {token});
  const state = qualityGateState(result?.check_runs, commitSha);
  if (state === 'success') return true;
  if (state === 'missing' || state === 'pending') {
    console.log(`Deferred: ${repo}@${commitSha.slice(0, 12)} quality-gate is ${state}`);
    return false;
  }
  throw new Error(`${repo}@${commitSha.slice(0, 12)} quality-gate failed`);
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
  if (hasBase(pr, 'main') && isPromotionHead(pr, personalRepo)) return 'promotion';
  return null;
}

function candidateUpstreamPull(pr, personalRepo) {
  return hasBase(pr, 'main') && isHead(pr, personalRepo, 'main');
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

function pushOrigin(refspec, token) {
  setupGitAuth(token);
  command('git', ['push', 'origin', refspec], {env: secretEnv(token)});
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

export function applyReadmeMirror({gitFn = git, commandFn = command} = {}) {
  gitFn('restore', '--source=upstream/main', '--', ...README_FILES);
  const changed = commandFn('git', ['diff', '--quiet', '--', ...README_FILES], {allowStatuses: [0, 1]}).status === 1;
  if (!changed) return false;
  gitFn('add', '--', ...README_FILES);
  commandFn('git', [
    '-c', 'user.name=github-actions[bot]',
    '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
    'commit', '-m', 'chore(promotion): mirror upstream README',
  ]);
  return true;
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
  if (active.kind === 'upstream') {
    await ensureCurrentCopilotReview(active.repo, active.pr, upstreamToken);
  } else {
    await ensureCurrentCopilotReview(active.repo, active.pr, forkToken);
    ensureExistingAutoMerge(active.repo, active.pr, forkToken);
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

async function createDevelopToMainPromotion(personalRepo, upstreamMain, originDevelop, forkToken) {
  const shortSha = originDevelop.slice(0, 12);
  const branch = `${PROMOTION_BRANCH_PREFIX}${shortSha}`;
  const previous = await findLatestMatchingPull(personalRepo, personalRepo, {base: 'main', branch}, forkToken);
  if (previous?.state === 'closed' && !previous.merged_at) {
    throw new Error(`Previous promotion PR #${previous.number} for ${branch} was closed without merge`);
  }

  const title = promotionTitle('origin/main', 'origin/develop');
  git('switch', '--force-create', branch, 'origin/develop');
  applyReadmeMirror();
  if (command('git', ['diff', '--quiet', 'origin/main', 'HEAD'], {allowStatuses: [0, 1]}).status === 0) {
    console.log('No public tree difference remains after applying the README mirror rule');
    return;
  }

  let promotionHead = sha('HEAD');
  const existingRemoteHead = remoteOriginBranchSha(branch, forkToken);
  if (existingRemoteHead) {
    fetchOriginBranch(branch, forkToken);
    if (command('git', ['diff', '--quiet', `origin/${branch}`, 'HEAD'], {allowStatuses: [0, 1]}).status !== 0) {
      throw new Error(`Fail closed: existing ${branch} differs from the expected promotion tree`);
    }
    promotionHead = sha(`origin/${branch}`);
    console.log(`Reusing existing promotion branch ${branch}@${promotionHead.slice(0, 12)}`);
  } else {
    pushOrigin(`HEAD:refs/heads/${branch}`, forkToken);
  }
  const pull = await createPull({
    repo: personalRepo,
    base: 'main',
    head: branch,
    title,
    token: forkToken,
    body: `${MARKERS.promotion}\n\nPromote the validated develop state to personal main.\n\n- develop source: \`${originDevelop}\`\n- promotion head: \`${promotionHead}\`\n- upstream README source: \`${upstreamMain}\`\n- merge method: merge commit\n- automation: serial; upstream PR creation waits for main push CI`,
  });
  ensureCopilotReview(personalRepo, pull.number, forkToken);
  ensureAutoMerge(personalRepo, pull.number, forkToken);
  console.log(`Created develop -> main promotion PR: ${pull.html_url}`);
}

async function createUpstreamPromotion(personalRepo, upstreamRepo, originMain, upstreamMain, upstreamToken) {
  const owner = repoOwner(personalRepo);
  const previous = await findLatestMatchingPull(upstreamRepo, personalRepo, {base: 'main', branch: 'main'}, upstreamToken);
  if (closedPullBlocks(previous, originMain)) {
    throw new Error(`Previous upstream PR #${previous.number} was closed without merge for ${originMain.slice(0, 12)}`);
  }
  const title = promotionTitle('upstream/main', 'origin/main');
  const pull = await createPull({
    repo: upstreamRepo,
    base: 'main',
    head: `${owner}:main`,
    title,
    token: upstreamToken,
    body: `${MARKERS.upstream}\n\nPromote the validated personal main to upstream main.\n\n- upstream base: \`${upstreamMain}\`\n- personal main: \`${originMain}\`\n- automation intentionally does not enable upstream auto-merge; upstream review and merge policy remain authoritative`,
  });
  ensureCopilotReview(upstreamRepo, pull.number, upstreamToken);
  console.log(`Created upstream promotion PR: ${pull.html_url}`);
}

function mainRelationshipIsStable(actual, expected, state) {
  return actual.state === state
    && actual.originMain === expected.originMain
    && actual.upstreamMain === expected.upstreamMain;
}

async function handleOriginBehind(config, relation, deps) {
  if (!await deps.requireGreenQuality(config.upstreamRepo, relation.upstreamMain, config.upstreamToken)) return;
  deps.refreshBranches(config);
  const refreshed = deps.branchRelationship();
  if (!mainRelationshipIsStable(refreshed, relation, 'origin-behind')) {
    deps.log('Deferred: main relationship changed after upstream quality verification');
    return;
  }
  deps.pushOrigin(`${relation.upstreamMain}:refs/heads/main`, config.forkToken);
  deps.log(`Fast-forwarded personal main to upstream ${relation.upstreamMain}`);
}

async function handleOriginAhead(config, relation, deps) {
  if (!await deps.requireGreenQuality(config.personalRepo, relation.originMain, config.readToken)) return;
  deps.refreshBranches(config);
  const refreshed = deps.branchRelationship();
  if (!mainRelationshipIsStable(refreshed, relation, 'origin-ahead')) {
    deps.log('Deferred: main relationship changed after personal main quality verification');
    return;
  }
  await deps.createUpstreamPromotion(
    config.personalRepo,
    config.upstreamRepo,
    refreshed.originMain,
    refreshed.upstreamMain,
    config.upstreamToken,
  );
}

async function handleDevelopPromotion(config, relation, deps) {
  const currentDevelop = deps.sha('origin/develop');
  if (currentDevelop === relation.originMain) {
    deps.log('No develop changes are waiting for promotion');
    return;
  }
  if (!await deps.requireGreenQuality(config.personalRepo, currentDevelop, config.readToken)) return;
  deps.refreshBranches(config);
  const refreshed = deps.branchRelationship();
  const refreshedDevelop = deps.sha('origin/develop');
  if (refreshed.state !== 'same' || refreshedDevelop !== currentDevelop) {
    deps.log(`Deferred: branch state changed during develop quality verification (${refreshed.state})`);
    return;
  }
  await deps.createDevelopToMainPromotion(
    config.personalRepo,
    refreshed.upstreamMain,
    refreshedDevelop,
    config.forkToken,
  );
}

async function handleSameMain(config, relation, deps) {
  if (!await deps.requireGreenQuality(config.personalRepo, relation.originMain, config.readToken)) return;
  deps.refreshBranches(config);
  const refreshed = deps.branchRelationship();
  if (refreshed.state !== 'same' || refreshed.originMain !== relation.originMain) {
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
    pushOrigin,
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
