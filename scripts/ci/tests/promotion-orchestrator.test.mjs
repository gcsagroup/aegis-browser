import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
import YAML from 'yaml';

import {
  applyReadmeMirror,
  classifyBranchRelationship,
  closedPullBlocks,
  inferPromotionTitle,
  inspectOpenPromotionPulls,
  loadPromotionConfig,
  parseConventionalTitle,
  qualityGateState,
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
    pushOrigin: () => {},
    createUpstreamPromotion: async () => {},
    isAncestor: () => true,
    createMainToDevelopSync: async () => {},
    sha: () => 'develop',
    createDevelopToMainPromotion: async () => {},
    log: () => {},
    ...overrides,
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

test('quality gate state requires the exact SHA and GitHub Actions success', () => {
  const sha = 'abc';
  assert.equal(qualityGateState([], sha), 'missing');
  assert.equal(qualityGateState([{id: 1, name: 'quality-gate', head_sha: sha, app: {slug: 'github-actions'}, status: 'in_progress'}], sha), 'pending');
  assert.equal(qualityGateState([{id: 1, name: 'quality-gate', head_sha: sha, app: {slug: 'github-actions'}, status: 'completed', conclusion: 'failure'}], sha), 'failure');
  assert.equal(qualityGateState([
    {id: 1, name: 'quality-gate', head_sha: 'old', app: {slug: 'github-actions'}, status: 'completed', conclusion: 'success'},
    {id: 2, name: 'quality-gate', head_sha: sha, app: {slug: 'github-actions'}, status: 'completed', conclusion: 'success'},
  ], sha), 'success');
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

test('README mirror commits only when upstream README content changes the promotion tree', () => {
  const unchangedGitCalls = [];
  const unchanged = applyReadmeMirror({
    gitFn: (...args) => unchangedGitCalls.push(args),
    commandFn: () => ({status: 0}),
  });
  assert.equal(unchanged, false);
  assert.equal(unchangedGitCalls.length, 1);

  const changedGitCalls = [];
  const changedCommandCalls = [];
  const changed = applyReadmeMirror({
    gitFn: (...args) => changedGitCalls.push(args),
    commandFn: (name, args, options) => {
      changedCommandCalls.push({name, args, options});
      return {status: args[0] === 'diff' ? 1 : 0};
    },
  });
  assert.equal(changed, true);
  assert.equal(changedGitCalls.length, 2);
  assert.deepEqual(changedGitCalls[1].slice(0, 2), ['add', '--']);
  assert.equal(changedCommandCalls.at(-1).args.at(-2), '-m');
  assert.equal(changedCommandCalls.at(-1).args.at(-1), 'chore(promotion): mirror upstream README');
});

test('origin-behind transition verifies upstream quality then fast-forwards personal main', async () => {
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
    pushOrigin: (...args) => pushes.push(args),
  }));
  assert.deepEqual(qualityCalls, [[promotionConfig.upstreamRepo, 'upstream-new', promotionConfig.upstreamToken]]);
  assert.deepEqual(pushes, [['upstream-new:refs/heads/main', promotionConfig.forkToken]]);
});

test('origin-behind transition defers when branch state drifts after quality verification', async () => {
  const relations = [
    {state: 'origin-behind', originMain: 'personal-old', upstreamMain: 'upstream-new'},
    {state: 'same', originMain: 'upstream-new', upstreamMain: 'upstream-new'},
  ];
  let pushed = false;
  await runPromotionCycle(promotionConfig, testDependencies({
    branchRelationship: () => relations.shift(),
    pushOrigin: () => { pushed = true; },
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
  assert.deepEqual(created, [[
    promotionConfig.personalRepo,
    promotionConfig.upstreamRepo,
    'personal-new',
    'upstream-old',
    promotionConfig.upstreamToken,
  ]]);
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
      pushOrigin: () => { mutated = true; },
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
    [promotionConfig.personalRepo, 'main-sha', promotionConfig.readToken],
    [promotionConfig.personalRepo, 'develop-sha', promotionConfig.readToken],
  ]);
  assert.deepEqual(promotionCalls, [[
    promotionConfig.personalRepo,
    'main-sha',
    'develop-sha',
    promotionConfig.forkToken,
  ]]);
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
  assert.deepEqual(qualityCalls, [[promotionConfig.personalRepo, 'main-sha', promotionConfig.readToken]]);
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
