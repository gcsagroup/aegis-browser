import {URLSearchParams} from 'node:url';
import {githubApi} from './promotion-github.mjs';

const QUALITY_WORKFLOW_PATH = '.github/workflows/quality.yml';
const REQUIRED_QUALITY_JOBS = ['quality', 'quality-gate'];

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

