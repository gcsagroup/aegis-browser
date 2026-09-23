import assert from 'node:assert/strict';
import test from 'node:test';
import {qualityWorkflowRunState, requireGreenQuality} from '../promotion-quality.mjs';
const promotionConfig = {personalRepo: 'quinn521/aegis-browser', readToken: 'read', forkToken: 'fork', upstreamToken: 'upstream'};
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

