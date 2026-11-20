import {URLSearchParams} from 'node:url';
import {githubApi} from './promotion-github.mjs';

const QUALITY = {name: 'quality', jobs: ['quality', 'quality-gate']};
const SECRET_SCANNING = {name: 'secret-scanning', jobs: ['gitleaks']};

function matchesPush(run, {repo, branch, sha}, workflow) {
  return run?.event === 'push' && run?.path === `.github/workflows/${workflow.name}.yml` &&
    run?.head_branch === branch && run?.head_sha === sha &&
    run?.repository?.full_name === repo;
}

function workflowRunState(run, expected, workflow) {
  if (!run) return 'missing';
  if (!matchesPush(run, expected, workflow)) return 'failure';
  if (run.status !== 'completed') return 'pending';
  return run.conclusion === 'success' ? 'success' : 'failure';
}

function requiredJobsState(jobs, run, expected, workflow) {
  for (const name of workflow.jobs) {
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

function workflowState(run, jobs, expected, workflow) {
  const runState = workflowRunState(run, expected, workflow);
  return runState === 'success'
    ? requiredJobsState(jobs, run, expected, workflow)
    : runState;
}

export function qualityWorkflowRunState(run, jobs, expected) {
  return workflowState(run, jobs, expected, QUALITY);
}

function checkState(state, {repo, branch, sha}, workflow) {
  if (state === 'success') return true;
  if (state === 'missing' || state === 'pending') {
    console.log(`Deferred: ${repo}:${branch}@${sha.slice(0, 12)} ${workflow.name} workflow is ${state}`);
    return false;
  }
  throw new Error(`${repo}:${branch}@${sha.slice(0, 12)} ${workflow.name} workflow failed`);
}

async function readAttemptJobs(repo, run, token, apiFn) {
  const pageSize = 100;
  const path = `/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=${pageSize}`;
  const jobs = [];
  let total;
  let page = 1;
  do {
    let batch;
    try {
      batch = await apiFn(repo, page === 1 ? path : `${path}&page=${page}`, {token});
    } catch (cause) {
      throw new Error(`${repo} run ${run.id} attempt ${run.run_attempt}: cannot read jobs page ${page}`, {cause});
    }
    if (page === 1) total = batch?.total_count;
    if (!Number.isSafeInteger(total) || total < 0 || batch?.total_count !== total ||
        !Array.isArray(batch.jobs) || batch.jobs.length !== Math.min(pageSize, total - jobs.length)) {
      throw new Error(`${repo} run ${run.id} attempt ${run.run_attempt}: incomplete job list`);
    }
    jobs.push(...batch.jobs);
    page++;
  } while (jobs.length < total);
  return jobs;
}

async function readPushEvidence(expected, workflow, token, apiFn) {
  const {repo, branch, sha} = expected;
  const query = new URLSearchParams({branch, event: 'push', head_sha: sha, per_page: '100'});
  const result = await apiFn(repo, `/actions/workflows/${workflow.name}.yml/runs?${query}`, {token});
  const selected = (result?.workflow_runs ?? [])
    .filter(run => matchesPush(run, expected, workflow))
    .sort((left, right) => Number(right.id) - Number(left.id))[0];
  if (!selected) return checkState('missing', expected, workflow);
  const run = await apiFn(repo, `/actions/runs/${selected.id}`, {token});
  if (run?.id !== selected.id) return checkState('failure', expected, workflow);
  if (!checkState(workflowRunState(run, expected, workflow), expected, workflow)) return false;
  const attempt = run.run_attempt;
  if (!Number.isInteger(attempt) || attempt < 1) return checkState('failure', expected, workflow);
  const jobs = await readAttemptJobs(repo, run, token, apiFn);
  return {run, jobs, workflow};
}

export async function requireGreenQuality(repo, branch, commitSha, token, apiFn = githubApi) {
  const expected = {repo, branch, sha: commitSha};
  const quality = await readPushEvidence(expected, QUALITY, token, apiFn);
  if (!quality) return false;
  const scan = await readPushEvidence(expected, SECRET_SCANNING, token, apiFn);
  if (!scan) return false;
  // Re-read both attempts after collecting both sets of jobs.
  const results = await Promise.all([quality, scan].map(async ({run, jobs, workflow}) => {
    const final = await apiFn(repo, `/actions/runs/${run.id}`, {token});
    if (final?.id !== run.id) return checkState('failure', expected, workflow);
    if (final.run_attempt !== run.run_attempt) return checkState('pending', expected, workflow);
    return checkState(workflowState(final, jobs, expected, workflow), expected, workflow);
  }));
  return results.every(Boolean);
}
