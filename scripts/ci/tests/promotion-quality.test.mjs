import assert from 'node:assert/strict';
import test from 'node:test';
import {qualityWorkflowRunState, requireGreenQuality} from '../promotion-quality.mjs';
const promotionConfig = {personalRepo: 'fixture-maintainer/aegis-browser', readToken: 'read', forkToken: 'fork', upstreamToken: 'upstream'};
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
  assert.equal(qualityWorkflowRunState({...run, event: 'workflow_dispatch'}, jobs, expected), 'failure');
  assert.equal(qualityWorkflowRunState({...run, event: 'pull_request'}, jobs, expected), 'failure');
  assert.equal(qualityWorkflowRunState({...run, status: 'in_progress'}, jobs, expected), 'pending');
  assert.equal(qualityWorkflowRunState(run, jobs.slice(1), expected), 'failure');
  assert.equal(qualityWorkflowRunState(run, [{...jobs[0], conclusion: 'failure'}, jobs[1]], expected), 'failure');
  assert.equal(qualityWorkflowRunState(run, [{...jobs[0], run_attempt: 2}, jobs[1]], expected), 'failure');
});

test('quality verification ignores newer dispatch, PR and wrong-workflow successes', async () => {
  const commitSha = 'develop-sha';
  const exactRun = qualityRun({id: 10, branch: 'develop', sha: commitSha, conclusion: 'failure'});
  const apiFn = async (_repo, path) => {
    if (path.startsWith('/actions/workflows/quality.yml/runs?')) {
      return {workflow_runs: [
        {...exactRun, id: 13, event: 'workflow_dispatch', conclusion: 'success'},
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

test('quality verification defers when only successful tip diagnostics exist', async () => {
  const run = {...qualityRun({id: 50, branch: 'main', sha: 'main-sha'}), event: 'workflow_dispatch'};
  const apiFn = async (_repo, path) => {
    if (path.startsWith('/actions/workflows/quality.yml/runs?')) {
      assert.match(path, /head_sha=main-sha/u);
      assert.match(path, /event=push/u);
      return {workflow_runs: [run]};
    }
    throw new Error(`unexpected path: ${path}`);
  };
  assert.equal(
    await requireGreenQuality(promotionConfig.personalRepo, 'main', 'main-sha', promotionConfig.readToken, apiFn),
    false,
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
  const scan = {...run, id: 31, path: '.github/workflows/secret-scanning.yml'};
  const paths = [];
  const apiFn = async (_repo, path) => {
    paths.push(path);
    if (path.startsWith('/actions/workflows/quality.yml/runs?')) return {workflow_runs: [run]};
    if (path === '/actions/runs/30') return run;
    if (path === '/actions/runs/30/attempts/3/jobs?per_page=100') {
      return {total_count: 2, jobs: [
        qualityJob(run, 'quality'),
        qualityJob(run, 'quality-gate'),
      ]};
    }
    if (path.startsWith('/actions/workflows/secret-scanning.yml/runs?')) return {workflow_runs: [scan]};
    if (path === '/actions/runs/31') return scan;
    if (path === '/actions/runs/31/attempts/3/jobs?per_page=100') {
      return {total_count: 1, jobs: [qualityJob(scan, 'gitleaks')]};
    }
    throw new Error(`unexpected path: ${path}`);
  };
  assert.equal(
    await requireGreenQuality(promotionConfig.personalRepo, 'main', 'main-sha', promotionConfig.readToken, apiFn),
    true,
  );
  assert.equal(paths.length, 8);
});

test('promotion requires gitleaks from the newest exact source push attempt', async t => {
  const quality = qualityRun({id: 60, branch: 'develop', sha: 'candidate'});
  const scan = {...quality, id: 61, path: '.github/workflows/secret-scanning.yml', run_attempt: 2};
  const passes = [qualityJob(scan, 'gitleaks')];
  const otherJobs = Array.from({length: 100}, (_, index) => qualityJob(scan, `other-${index}`));
  const cases = [
    ['missing', null, passes, scan, false],
    ['queued', {...scan, status: 'queued'}, passes, scan, false],
    ['failure', {...scan, conclusion: 'failure'}, passes, scan, /secret-scanning workflow failed/u],
    ['stale job', scan, [{...passes[0], run_attempt: 1}], scan, /secret-scanning workflow failed/u],
    ['new attempt during read', scan, passes, {...scan, run_attempt: 3, status: 'queued'}, false],
    ['missing gitleaks', scan, [], scan, /secret-scanning workflow failed/u],
    ['success', scan, passes, scan, true],
    ['gitleaks on second page', scan, otherJobs, scan, true, passes],
    ['duplicate across pages', scan, [...passes, ...otherJobs.slice(1)], scan, /secret-scanning workflow failed/u, passes],
    ['incomplete second page', scan, [...passes, ...otherJobs.slice(1)], scan, /incomplete job list/u, []],
  ];
  for (const [name, selected, jobs, finalRun, expected, secondPage] of cases) {
    await t.test(name, async () => {
      let scanReads = 0;
      const apiFn = async (repo, path, {token}) => {
        assert.equal(repo, promotionConfig.personalRepo);
        assert.equal(token, promotionConfig.readToken);
        if (path.startsWith('/actions/workflows/quality.yml/runs?')) return {workflow_runs: [quality]};
        if (path === '/actions/runs/60') return quality;
        if (path === '/actions/runs/60/attempts/1/jobs?per_page=100') {
          return {total_count: 2, jobs: ['quality', 'quality-gate'].map(name => qualityJob(quality, name))};
        }
        if (path.startsWith('/actions/workflows/secret-scanning.yml/runs?')) {
          assert.match(path, /branch=develop&event=push&head_sha=candidate/u);
          return {workflow_runs: [
            {...scan, id: 63, event: 'workflow_dispatch'},
            {...scan, id: 62, head_sha: 'unrelated'},
            ...(selected ? [selected, {...scan, id: 59}] : []),
          ]};
        }
        if (path === '/actions/runs/61') return scanReads++ === 0 ? selected : finalRun;
        if (path === '/actions/runs/61/attempts/2/jobs?per_page=100') {
          return {total_count: secondPage ? 101 : jobs.length, jobs};
        }
        if (path === '/actions/runs/61/attempts/2/jobs?per_page=100&page=2') {
          return {total_count: 101, jobs: secondPage};
        }
        throw new Error(`unexpected path: ${path}`);
      };
      const verified = requireGreenQuality(promotionConfig.personalRepo, 'develop', quality.head_sha,
        promotionConfig.readToken, apiFn);
      if (expected instanceof RegExp) await assert.rejects(verified, expected);
      else assert.equal(await verified, expected);
    });
  }
});

test('quality verification defers when a newer attempt starts after jobs are read', async () => {
  const run = qualityRun({id: 40, branch: 'main', sha: 'main-sha'});
  const rerun = {...run, run_attempt: 2, status: 'queued', conclusion: null};
  const scan = {...run, id: 41, path: '.github/workflows/secret-scanning.yml'};
  let runReads = 0;
  const apiFn = async (_repo, path) => {
    if (path.startsWith('/actions/workflows/quality.yml/runs?')) return {workflow_runs: [run]};
    if (path === '/actions/runs/40') return runReads++ === 0 ? run : rerun;
    if (path === '/actions/runs/40/attempts/1/jobs?per_page=100') {
      return {total_count: 2, jobs: [qualityJob(run, 'quality'), qualityJob(run, 'quality-gate')]};
    }
    if (path.startsWith('/actions/workflows/secret-scanning.yml/runs?')) return {workflow_runs: [scan]};
    if (path === '/actions/runs/41') return scan;
    if (path === '/actions/runs/41/attempts/1/jobs?per_page=100') {
      return {total_count: 1, jobs: [qualityJob(scan, 'gitleaks')]};
    }
    throw new Error(`unexpected path: ${path}`);
  };
  assert.equal(
    await requireGreenQuality(promotionConfig.personalRepo, 'main', 'main-sha', promotionConfig.readToken, apiFn),
    false,
  );
});

test('promotion defers if quality reruns while collecting secret scanning evidence', async () => {
  const quality = qualityRun({id: 70, branch: 'develop', sha: 'candidate'});
  const scan = {...quality, id: 71, path: '.github/workflows/secret-scanning.yml'};
  let scanJobsRead = false;
  const apiFn = async (_repo, path) => {
    if (path.startsWith('/actions/workflows/quality.yml/runs?')) return {workflow_runs: [quality]};
    if (path === '/actions/runs/70') {
      return scanJobsRead ? {...quality, run_attempt: 2, status: 'queued', conclusion: null} : quality;
    }
    if (path === '/actions/runs/70/attempts/1/jobs?per_page=100') {
      return {total_count: 2, jobs: ['quality', 'quality-gate'].map(name => qualityJob(quality, name))};
    }
    if (path.startsWith('/actions/workflows/secret-scanning.yml/runs?')) return {workflow_runs: [scan]};
    if (path === '/actions/runs/71') return scan;
    if (path === '/actions/runs/71/attempts/1/jobs?per_page=100') {
      scanJobsRead = true;
      return {total_count: 1, jobs: [qualityJob(scan, 'gitleaks')]};
    }
    throw new Error(`unexpected path: ${path}`);
  };
  assert.equal(await requireGreenQuality(promotionConfig.personalRepo, 'develop', quality.head_sha,
    promotionConfig.readToken, apiFn), false);
});

