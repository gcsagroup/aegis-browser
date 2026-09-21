import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
import YAML from 'yaml';

import {
  assertRemoteHeads,
  publishCandidate,
  validateActivePull,
  classifyBranchRelationship,
  closedPullBlocks,
  inferPromotionTitle,
  inspectOpenPromotionPulls,
  loadPromotionConfig,
  parseConventionalTitle,
  qualityWorkflowRunState,
  requireGreenQuality,
  runPromotionCycle,
} from '../promotion-orchestrator.mjs';

const root = resolve(import.meta.dirname, '../../..');
const promotionConfig = Object.freeze({
  personalRepo: 'quinn521/aegis-browser',
  upstreamRepo: 'gcsagroup/aegis-browser',
  readToken: 'read-token',
  forkToken: 'fork-token',
  upstreamToken: 'upstream-token',
});

function testDependencies(overrides = {}) {
  return {
    refreshBranches: () => {},
    handleExistingPulls: async () => false,
    branchRelationship: () => ({state: 'same', originMain: 'main', upstreamMain: 'main'}),
    requireGreenQuality: async () => true,
    createUpstreamSync: async () => {},
    createUpstreamPromotion: async () => {},
    isAncestor: () => true,
    createMainToDevelopSync: async () => {},
    sha: () => 'develop',
    createDevelopToMainPromotion: async () => {},
    log: () => {},
    ...overrides,
  };
}

function qualityRun({id, branch, sha, conclusion = 'success', runAttempt = 1}) {
  return {
    id,
    event: 'push',
    head_branch: branch,
    head_sha: sha,
    path: '.github/workflows/quality.yml',
    repository: {full_name: promotionConfig.personalRepo},
    status: 'completed',
    conclusion,
    run_attempt: runAttempt,
  };
}

function qualityJob(run, name, conclusion = 'success') {
  return {
    name,
    run_id: run.id,
    head_sha: run.head_sha,
    run_attempt: run.run_attempt,
    status: 'completed',
    conclusion,
  };
}

test('promotion title chooses the last feature and strips PR suffixes', () => {
  assert.equal(inferPromotionTitle([
    'feat(access): add request dispatch block barriers (#46)',
    'fix(access): address review feedback',
    'feat(access): enforce request dispatch gate (#51)',
    'fix(ci): stabilize fixture',
  ]), 'feat(access): enforce request dispatch gate');
});

test('promotion title falls back to the last non-release Conventional Commit', () => {
  assert.equal(inferPromotionTitle([
    'release: promote develop through PR #46',
    'docs(ci): document promotion automation',
    'fix(ci): fail closed on divergent main',
  ]), 'fix(ci): fail closed on divergent main');
  assert.equal(inferPromotionTitle(['release: promotion wrapper', 'Merge branch main']), null);
  assert.equal(parseConventionalTitle('ci: automate promotion (#52)')?.title, 'ci: automate promotion');
});

test('branch relationship classification is fail closed for divergence', () => {
  assert.equal(classifyBranchRelationship({originMain: 'a', upstreamMain: 'a', originMainAncestor: true, upstreamMainAncestor: true}), 'same');
  assert.equal(classifyBranchRelationship({originMain: 'a', upstreamMain: 'b', originMainAncestor: true, upstreamMainAncestor: false}), 'origin-behind');
  assert.equal(classifyBranchRelationship({originMain: 'b', upstreamMain: 'a', originMainAncestor: false, upstreamMainAncestor: true}), 'origin-ahead');
  assert.equal(classifyBranchRelationship({originMain: 'a', upstreamMain: 'b', originMainAncestor: false, upstreamMainAncestor: false}), 'diverged');
});

test('quality workflow state requires exact push identity and both mandatory jobs', () => {
  const expected = {repo: promotionConfig.personalRepo, branch: 'develop', sha: 'abc'};
  const run = {
    id: 7,
    event: 'push',
    head_branch: expected.branch,
    head_sha: expected.sha,
    path: '.github/workflows/quality.yml',
    repository: {full_name: expected.repo},
    status: 'completed',
    conclusion: 'success',
    run_attempt: 1,
  };
  const jobs = [
    qualityJob(run, 'quality'),
    qualityJob(run, 'quality-gate'),
  ];
  assert.equal(qualityWorkflowRunState(run, jobs, expected), 'success');
  assert.equal(qualityWorkflowRunState({...run, event: 'pull_request'}, jobs, expected), 'failure');
  assert.equal(qualityWorkflowRunState({...run, status: 'in_progress'}, jobs, expected), 'pending');
  assert.equal(qualityWorkflowRunState(run, jobs.slice(1), expected), 'failure');
  assert.equal(qualityWorkflowRunState(run, [{...jobs[0], conclusion: 'failure'}, jobs[1]], expected), 'failure');
  assert.equal(qualityWorkflowRunState(run, [{...jobs[0], run_attempt: 2}, jobs[1]], expected), 'failure');
});

test('quality verification ignores newer PR and wrong-workflow successes', async () => {
  const commitSha = 'develop-sha';
  const exactRun = qualityRun({id: 10, branch: 'develop', sha: commitSha, conclusion: 'failure'});
  const apiFn = async (_repo, path) => {
    if (path.startsWith('/actions/workflows/quality.yml/runs?')) {
      return {workflow_runs: [
        {...exactRun, id: 12, event: 'pull_request', conclusion: 'success'},
        {...exactRun, id: 11, path: '.github/workflows/other.yml', conclusion: 'success'},
        exactRun,
      ]};
    }
    if (path === '/actions/runs/10') return exactRun;
    throw new Error(`unexpected path: ${path}`);
  };
  await assert.rejects(
    requireGreenQuality(promotionConfig.personalRepo, 'develop', commitSha, promotionConfig.readToken, apiFn),
    /quality workflow failed/u,
  );
});

test('quality verification re-fetches the latest attempt before authorizing', async () => {
  const listed = qualityRun({id: 20, branch: 'main', sha: 'main-sha', runAttempt: 1});
  const rerun = {...listed, run_attempt: 2, conclusion: 'failure'};
  const apiFn = async (_repo, path) => {
    if (path.startsWith('/actions/workflows/quality.yml/runs?')) return {workflow_runs: [listed]};
    if (path === '/actions/runs/20') return rerun;
    throw new Error(`unexpected path: ${path}`);
  };
  await assert.rejects(
    requireGreenQuality(promotionConfig.personalRepo, 'main', 'main-sha', promotionConfig.readToken, apiFn),
    /quality workflow failed/u,
  );
});

test('quality verification accepts only successful jobs from the exact latest attempt', async () => {
  const run = qualityRun({id: 30, branch: 'main', sha: 'main-sha', runAttempt: 3});
  const paths = [];
  const apiFn = async (_repo, path) => {
    paths.push(path);
    if (path.startsWith('/actions/workflows/quality.yml/runs?')) return {workflow_runs: [run]};
    if (path === '/actions/runs/30') return run;
    if (path === '/actions/runs/30/attempts/3/jobs?per_page=100') {
      return {jobs: [
        qualityJob(run, 'quality'),
        qualityJob(run, 'quality-gate'),
      ]};
    }
    throw new Error(`unexpected path: ${path}`);
  };
  assert.equal(
    await requireGreenQuality(promotionConfig.personalRepo, 'main', 'main-sha', promotionConfig.readToken, apiFn),
    true,
  );
  assert.equal(paths.length, 4);
});

test('quality verification defers when a newer attempt starts after jobs are read', async () => {
  const run = qualityRun({id: 40, branch: 'main', sha: 'main-sha'});
  const rerun = {...run, run_attempt: 2, status: 'queued', conclusion: null};
  let runReads = 0;
  const apiFn = async (_repo, path) => {
    if (path.startsWith('/actions/workflows/quality.yml/runs?')) return {workflow_runs: [run]};
    if (path === '/actions/runs/40') return runReads++ === 0 ? run : rerun;
    if (path === '/actions/runs/40/attempts/1/jobs?per_page=100') {
      return {jobs: [qualityJob(run, 'quality'), qualityJob(run, 'quality-gate')]};
    }
    throw new Error(`unexpected path: ${path}`);
  };
  assert.equal(
    await requireGreenQuality(promotionConfig.personalRepo, 'main', 'main-sha', promotionConfig.readToken, apiFn),
    false,
  );
});

test('closed unmerged PR blocks only the same source head', () => {
  const pull = {state: 'closed', merged_at: null, head: {sha: 'same'}};
  assert.equal(closedPullBlocks(pull, 'same'), true);
  assert.equal(closedPullBlocks(pull, 'new'), false);
  assert.equal(closedPullBlocks({...pull, merged_at: '2026-09-17T00:00:00Z'}, 'same'), false);
});

test('promotion config validates all mandatory repositories and tokens before transitions', () => {
  const env = {
    GITHUB_REPOSITORY: promotionConfig.personalRepo,
    GH_TOKEN: promotionConfig.readToken,
    AEGIS_FORK_AUTOMATION_TOKEN: promotionConfig.forkToken,
    AEGIS_UPSTREAM_TOKEN: promotionConfig.upstreamToken,
  };
  assert.deepEqual(loadPromotionConfig(env), promotionConfig);
  assert.throws(() => loadPromotionConfig({...env, GITHUB_REPOSITORY: ''}), /GITHUB_REPOSITORY and GH_TOKEN are required/u);
  assert.throws(() => loadPromotionConfig({...env, GH_TOKEN: ''}), /GITHUB_REPOSITORY and GH_TOKEN are required/u);
  assert.throws(() => loadPromotionConfig({...env, AEGIS_FORK_AUTOMATION_TOKEN: ''}), /AEGIS_FORK_AUTOMATION_TOKEN is required/u);
  assert.throws(() => loadPromotionConfig({...env, AEGIS_UPSTREAM_TOKEN: ''}), /AEGIS_UPSTREAM_TOKEN is required/u);
});

test('open promotion inspection classifies manual, active, empty, and conflicting paths', () => {
  const personalRepo = promotionConfig.personalRepo;
  const upstreamRepo = promotionConfig.upstreamRepo;
  const syncPull = {
    number: 52,
    body: '<!-- aegis-promotion-orchestrator:main-to-develop -->',
    base: {ref: 'develop'},
    head: {repo: {full_name: personalRepo}, ref: 'main'},
  };
  const upstreamPull = {
    number: 53,
    body: '<!-- aegis-promotion-orchestrator:upstream-main -->',
    base: {ref: 'main'},
    head: {repo: {full_name: personalRepo}, ref: 'main'},
  };
  const manual = inspectOpenPromotionPulls({
    personalOpen: [{...syncPull, body: ''}],
    upstreamOpen: [],
    personalRepo,
    upstreamRepo,
  });
  assert.equal(manual.status, 'manual');
  assert.match(manual.message, /non-automation PR/u);

  const manualUpstream = inspectOpenPromotionPulls({
    personalOpen: [],
    upstreamOpen: [{...upstreamPull, body: ''}],
    personalRepo,
    upstreamRepo,
  });
  assert.equal(manualUpstream.status, 'manual');
  assert.match(manualUpstream.message, /non-automation upstream PR/u);

  const empty = inspectOpenPromotionPulls({personalOpen: [], upstreamOpen: [], personalRepo, upstreamRepo});
  assert.equal(empty.status, 'none');

  const active = inspectOpenPromotionPulls({personalOpen: [syncPull], upstreamOpen: [], personalRepo, upstreamRepo});
  assert.equal(active.status, 'active');
  assert.equal(active.active.kind, 'sync');
  assert.equal(active.active.pr.number, syncPull.number);

  const multiple = inspectOpenPromotionPulls({
    personalOpen: [syncPull],
    upstreamOpen: [upstreamPull],
    personalRepo,
    upstreamRepo,
  });
  assert.equal(multiple.status, 'multiple');
  assert.deepEqual(multiple.automation.map(({kind}) => kind), ['sync', 'upstream']);
});

test('origin-behind transition verifies upstream quality then requests a preserving sync PR', async () => {
  const relation = {state: 'origin-behind', originMain: 'personal-old', upstreamMain: 'upstream-new'};
  const relations = [relation, {...relation}];
  const qualityCalls = [];
  const pushes = [];
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    requireGreenQuality: async (...args) => {
      qualityCalls.push(args);
      return true;
    },
    createUpstreamSync: async (...args) => pushes.push(args),
  }));
  assert.deepEqual(qualityCalls, [[promotionConfig.upstreamRepo, 'main', 'upstream-new', promotionConfig.upstreamToken]]);
  assert.deepEqual(pushes, [[promotionConfig, relation]]);
});

test('origin-behind transition defers when branch state drifts after quality verification', async () => {
  const relations = [
    {state: 'origin-behind', originMain: 'personal-old', upstreamMain: 'upstream-new'},
    {state: 'same', originMain: 'upstream-new', upstreamMain: 'upstream-new'},
  ];
  let pushed = false;
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    createUpstreamSync: async () => { pushed = true; },
  }));
  assert.equal(pushed, false);
});

test('origin-ahead transition creates upstream promotion after exact personal main quality', async () => {
  const relation = {state: 'origin-ahead', originMain: 'personal-new', upstreamMain: 'upstream-old'};
  const relations = [relation, {...relation}];
  const created = [];
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    createUpstreamPromotion: async (...args) => created.push(args),
  }));
  assert.deepEqual(created, [[promotionConfig, relation]]);
});

test('origin-ahead transition defers when branch state drifts after quality verification', async () => {
  const relations = [
    {state: 'origin-ahead', originMain: 'personal-new', upstreamMain: 'upstream-old'},
    {state: 'diverged', originMain: 'personal-new', upstreamMain: 'upstream-new'},
  ];
  let created = false;
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    createUpstreamPromotion: async () => { created = true; },
  }));
  assert.equal(created, false);
});

test('diverged main relationship fails closed before any promotion mutation', async () => {
  let mutated = false;
  await assert.rejects(
    runPromotionCycle(promotionConfig, testDependencies({
      branchRelationship: () => ({state: 'diverged', originMain: 'personal-sha', upstreamMain: 'upstream-sha'}),
      createUpstreamSync: async () => { mutated = true; },
      createUpstreamPromotion: async () => { mutated = true; },
      createMainToDevelopSync: async () => { mutated = true; },
      createDevelopToMainPromotion: async () => { mutated = true; },
    })),
    /Fail closed: personal main personal-sha and upstream main upstream-sha diverged/u,
  );
  assert.equal(mutated, false);
});

test('same-main transition creates main-to-develop sync when develop lacks main', async () => {
  const relation = {state: 'same', originMain: 'main-sha', upstreamMain: 'main-sha'};
  const relations = [relation, {...relation}];
  const syncCalls = [];
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    isAncestor: () => false,
    createMainToDevelopSync: async (...args) => syncCalls.push(args),
  }));
  assert.deepEqual(syncCalls, [[promotionConfig.personalRepo, promotionConfig.forkToken, 'main-sha']]);
});

test('same-main transition promotes validated develop after both quality rechecks stay stable', async () => {
  const relation = {state: 'same', originMain: 'main-sha', upstreamMain: 'main-sha'};
  const relations = [relation, {...relation}, {...relation}];
  const qualityCalls = [];
  const promotionCalls = [];
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    requireGreenQuality: async (...args) => {
      qualityCalls.push(args);
      return true;
    },
    sha: () => 'develop-sha',
    createDevelopToMainPromotion: async (...args) => promotionCalls.push(args),
  }));
  assert.deepEqual(qualityCalls, [
    [promotionConfig.personalRepo, 'main', 'main-sha', promotionConfig.readToken],
    [promotionConfig.personalRepo, 'develop', 'develop-sha', promotionConfig.readToken],
  ]);
  assert.deepEqual(promotionCalls, [[promotionConfig, relation, 'develop-sha']]);
});

test('same-main transition is a no-op when develop already equals main', async () => {
  const relation = {state: 'same', originMain: 'main-sha', upstreamMain: 'main-sha'};
  const relations = [relation, {...relation}];
  const qualityCalls = [];
  let promoted = false;
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    requireGreenQuality: async (...args) => {
      qualityCalls.push(args);
      return true;
    },
    sha: () => 'main-sha',
    createDevelopToMainPromotion: async () => { promoted = true; },
  }));
  assert.deepEqual(qualityCalls, [[promotionConfig.personalRepo, 'main', 'main-sha', promotionConfig.readToken]]);
  assert.equal(promoted, false);
});

test('same-main transition defers when develop changes after its quality verification', async () => {
  const relation = {state: 'same', originMain: 'main-sha', upstreamMain: 'main-sha'};
  const relations = [relation, {...relation}, {...relation}];
  const developShas = ['develop-verified', 'develop-new'];
  let promoted = false;
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    sha: () => developShas.shift(),
    createDevelopToMainPromotion: async () => { promoted = true; },
  }));
  assert.equal(promoted, false);
});

test('same-main transition defers when both main branches advance during develop verification', async () => {
  const oldRelation = {state: 'same', originMain: 'main-old', upstreamMain: 'main-old'};
  const newRelation = {state: 'same', originMain: 'main-new', upstreamMain: 'main-new'};
  const relations = [oldRelation, {...oldRelation}, newRelation];
  let promoted = false;
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    sha: () => 'develop-unchanged',
    createDevelopToMainPromotion: async () => { promoted = true; },
  }));
  assert.equal(promoted, false);
});

test('promotion workflow validator rejects trust-boundary mutations', () => {
  const workflowPath = join(root, '.github/workflows/promotion-orchestrator.yml');
  const validator = join(root, 'scripts/ci/validate-promotion-workflow.mjs');
  const run = (path) => spawnSync(process.execPath, [validator, path], {cwd: root, encoding: 'utf8'});
  assert.equal(run(workflowPath).status, 0);

  const directory = mkdtempSync(join(tmpdir(), 'aegis-promotion-workflow-'));
  try {
    const source = YAML.parse(readFileSync(workflowPath, 'utf8'));
    const mutations = [
      (workflow) => { workflow.on.pull_request = {branches: ['main']}; },
      (workflow) => { workflow.permissions.contents = 'write'; },
      (workflow) => { workflow.concurrency['cancel-in-progress'] = true; },
      (workflow) => { workflow.jobs.promote.if = '${{ always() }}'; },
      (workflow) => { workflow.jobs.promote.steps[0].with['persist-credentials'] = true; },
      (workflow) => { workflow.jobs.promote.steps[2].env.AEGIS_EXTRA_TOKEN = '${{ secrets.EXTRA_TOKEN }}'; },
    ];
    for (const [index, mutate] of mutations.entries()) {
      const copy = structuredClone(source);
      mutate(copy);
      const path = join(directory, `mutation-${index}.yml`);
      writeFileSync(path, YAML.stringify(copy));
      assert.notEqual(run(path).status, 0, `workflow mutation ${index} unexpectedly passed`);
    }
  } finally {
    rmSync(directory, {recursive: true, force: true});
  }
});

test('export and upstream-sync PRs are detected, manual export blocks and legacy main is retained', () => {
  const personalRepo = promotionConfig.personalRepo;
  const upstreamRepo = promotionConfig.upstreamRepo;
  const make = (ref, marker) => ({base: {ref: 'main'}, head: {ref, repo: {full_name: personalRepo}}, body: marker});
  const exportPull = make('automation/export-main-upstream', '<!-- aegis-promotion-orchestrator:upstream-main -->');
  const inspect = (personalOpen, upstreamOpen) => inspectOpenPromotionPulls({personalOpen, upstreamOpen, personalRepo, upstreamRepo});
  assert.equal(inspect([], [exportPull]).active.kind, 'upstream');
  assert.equal(inspect([], [{...exportPull, body: ''}]).status, 'manual');
  assert.equal(inspect([make('automation/upstream-sync-main-upstream', '<!-- aegis-promotion-orchestrator:upstream-to-main -->')], []).active.kind, 'upstreamSync');
  assert.equal(inspect([], [exportPull, {...exportPull, head: {...exportPull.head, ref: 'main'}}]).status, 'multiple');
});

test('remote source drift rejects candidate authorization', async () => {
  await assert.rejects(assertRemoteHeads([{repo: 'owner/repo', branch: 'main', sha: 'expected'}], async () => ({object: {sha: 'changed'}})), /changed during candidate preparation/u);
});

function publicationFixture({existing = null, fetched = 'candidate-head', drift = false} = {}) {
  const candidate = {branch: 'automation/export-main-upstream', originMain: 'main', upstreamMain: 'upstream', productSource: 'main', baseTree: 'base-tree', readmeSource: 'upstream', tree: 'expected-tree', parents: ['main'], message: 'export'};
  const writes = [];
  const validations = [];
  let sourceReads = 0;
  const deps = {
    remoteSha: () => existing,
    fetchBranch: () => {},
    sha: () => fetched,
    entries: () => [],
    validate: (...args) => validations.push(args),
    api: async (repo, path, request) => {
      if (request.method === 'POST') {
        writes.push({path, ...request});
        if (path === '/git/trees') return {sha: 'expected-tree'};
        if (path === '/git/commits') return {sha: 'candidate-head'};
        if (path === '/git/refs') return {};
        throw new Error(`Unexpected write ${path}`);
      }
      if (path === '/git/ref/heads/main') {
        sourceReads += 1;
        return {object: {sha: drift && sourceReads > 2 ? 'changed' : repo === promotionConfig.personalRepo ? 'main' : 'upstream'}};
      }
      return {object: {sha: fetched}};
    },
  };
  return {candidate, writes, validations, deps};
}

test('publication creates a new immutable ref only after tree verification, with no ref updates', async () => {
  const f = publicationFixture();
  assert.equal(await publishCandidate(promotionConfig, f.candidate, f.deps), 'candidate-head');
  assert.deepEqual(f.writes.map(({path}) => path), ['/git/trees', '/git/commits', '/git/refs']);
  assert.equal(f.writes[0].body.base_tree, 'base-tree');
  assert.deepEqual(f.writes[1].body.parents, ['main']);
  assert.deepEqual(f.writes[2].body, {ref: `refs/heads/${f.candidate.branch}`, sha: 'candidate-head'});
  assert.deepEqual(f.validations, [[f.candidate, 'candidate-head']]);
});

test('publication safely reuses the immutable branch without writes and rejects fetch races', async () => {
  const f = publicationFixture({existing: 'candidate-head'});
  assert.equal(await publishCandidate(promotionConfig, f.candidate, f.deps), 'candidate-head');
  assert.deepEqual(f.writes, []);
  assert.equal(f.validations.length, 1);
  const changed = publicationFixture({existing: 'old-head', fetched: 'changed-head'});
  await assert.rejects(publishCandidate(promotionConfig, changed.candidate, changed.deps), /changed during fetch/u);
  assert.deepEqual(changed.writes, []);
});

test('source movement during remote object creation stops before publishing the ref', async () => {
  const f = publicationFixture({drift: true});
  await assert.rejects(publishCandidate(promotionConfig, f.candidate, f.deps), /changed during candidate preparation/u);
  assert.deepEqual(f.writes.map(({path}) => path), ['/git/trees', '/git/commits']);
});

test('remote tree mismatch stops before publishing a commit or ref', async () => {
  const f = publicationFixture();
  const api = f.deps.api;
  f.deps.api = (...args) => args[1] === '/git/trees' ? {sha: 'wrong-tree'} : api(...args);
  await assert.rejects(publishCandidate(promotionConfig, f.candidate, f.deps), /remote candidate tree mismatch/u);
  assert.deepEqual(f.writes, []);
});

test('create-ref collision fails closed without attempting update or force push', async () => {
  const f = publicationFixture();
  const api = f.deps.api;
  f.deps.api = (...args) => {
    if (args[1] === '/git/refs') throw new Error('Reference already exists');
    return api(...args);
  };
  await assert.rejects(publishCandidate(promotionConfig, f.candidate, f.deps), /Reference already exists/u);
  assert.deepEqual(f.writes.map(({path}) => path), ['/git/trees', '/git/commits']);
});

test('active export rejects source drift and candidate auto-merge before requesting review', async () => {
  const candidate = {branch: 'automation/export-current-upstream'};
  const active = {kind: 'upstream', pr: {head: {ref: 'automation/export-old-upstream', sha: 'head'}, base: {sha: 'upstream'}}};
  const deps = {sha: (ref) => ref === 'origin/main' ? 'current' : 'upstream', build: () => candidate};
  await assert.rejects(validateActivePull(active, promotionConfig, deps), /stale candidate source SHAs/u);
  await assert.rejects(validateActivePull({...active, pr: {...active.pr, auto_merge: {}}}, promotionConfig, deps), /explicit final CI\/review/u);
});
