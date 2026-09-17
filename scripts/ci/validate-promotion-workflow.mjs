#!/usr/bin/env node

import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import YAML from 'yaml';

function fail(message) {
  throw new Error(message);
}

try {
  const path = resolve(process.argv[2] ?? '.github/workflows/promotion-orchestrator.yml');
  const source = readFileSync(path, 'utf8');
  const workflow = YAML.parse(source);
  if (!workflow || typeof workflow !== 'object') fail('Promotion workflow must be a YAML object');

  const triggers = workflow.on ?? {};
  if (JSON.stringify(Object.keys(triggers).sort()) !== JSON.stringify(['push', 'schedule', 'workflow_dispatch'])) {
    fail('Promotion workflow must use only push, schedule and workflow_dispatch');
  }
  if (JSON.stringify([...(triggers.push?.branches ?? [])].sort()) !== JSON.stringify(['develop', 'main'])) {
    fail('Promotion workflow push must target exactly main and develop');
  }
  if (JSON.stringify(triggers.schedule) !== JSON.stringify([{cron: '*/15 * * * *'}])) {
    fail('Promotion workflow schedule must be exactly every 15 minutes');
  }
  if (Object.keys(triggers.workflow_dispatch ?? {}).length !== 0) fail('Promotion workflow dispatch may not accept mutable inputs');

  const permissions = workflow.permissions ?? {};
  if (JSON.stringify(permissions) !== JSON.stringify({checks: 'read', contents: 'read'})) {
    fail('Promotion workflow GITHUB_TOKEN must be read-only checks + contents');
  }
  if (workflow.concurrency?.group !== 'aegis-promotion-orchestrator' || workflow.concurrency?.['cancel-in-progress'] !== false) {
    fail('Promotion workflow must serialize every run without cancellation');
  }

  const jobs = workflow.jobs ?? {};
  if (JSON.stringify(Object.keys(jobs)) !== JSON.stringify(['promote'])) fail('Promotion workflow job set must be exactly promote');
  const job = jobs.promote;
  if (job?.name !== 'promotion-orchestrator' || job?.['runs-on'] !== 'ubuntu-24.04' || job?.['timeout-minutes'] !== 10) {
    fail('Promotion job identity, runner, or timeout changed');
  }
  if (job?.if !== "${{ vars.AEGIS_PROMOTION_AUTOMATION == 'enabled' }}") {
    fail('Promotion job must remain explicitly gated by AEGIS_PROMOTION_AUTOMATION');
  }
  if (job.permissions || 'continue-on-error' in job) fail('Promotion job may not override permissions or suppress failures');

  const steps = Array.isArray(job.steps) ? job.steps : [];
  if (steps.length !== 3) fail('Promotion job must contain exactly checkout, setup-node, and orchestrator steps');
  const checkout = steps[0];
  if (
    checkout?.uses !== 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' ||
    checkout.with?.['fetch-depth'] !== 0 || checkout.with?.['persist-credentials'] !== false
  ) fail('Promotion checkout must use the approved pin, full history, and no persisted credentials');
  const setupNode = steps[1];
  if (
    setupNode?.uses !== 'actions/setup-node@820762786026740c76f36085b0efc47a31fe5020' ||
    setupNode.with?.['node-version'] !== '22.23.1'
  ) fail('Promotion workflow must use the approved Node 22.23.1 setup');
  const runner = steps[2];
  if (runner?.run !== 'node scripts/ci/promotion-orchestrator.mjs') fail('Promotion workflow must call the dedicated orchestrator entrypoint');
  if (
    runner?.env?.GH_TOKEN !== '${{ github.token }}' ||
    runner?.env?.AEGIS_FORK_AUTOMATION_TOKEN !== '${{ secrets.AEGIS_FORK_AUTOMATION_TOKEN }}' ||
    runner?.env?.AEGIS_UPSTREAM_TOKEN !== '${{ secrets.AEGIS_UPSTREAM_TOKEN }}' ||
    runner?.env?.AEGIS_UPSTREAM_REPOSITORY !== 'gcsagroup/aegis-browser'
  ) fail('Promotion workflow token and upstream bindings changed');
  if ('continue-on-error' in runner || runner.if) fail('Promotion transition may not suppress or conditionally hide failures');

  if (/pull_request(?:_target)?|workflow_run|self-hosted/u.test(source)) fail('Promotion workflow may not execute from PR, workflow_run, or self-hosted contexts');
  const secretNames = [...source.matchAll(/secrets\.([A-Z0-9_]+)/gu)].map((match) => match[1]).sort();
  if (JSON.stringify(secretNames) !== JSON.stringify(['AEGIS_FORK_AUTOMATION_TOKEN', 'AEGIS_UPSTREAM_TOKEN'])) {
    fail(`Unexpected promotion secret set: ${secretNames.join(', ')}`);
  }
  console.log(JSON.stringify({status: 'PASS', path, triggers: Object.keys(triggers), jobs: Object.keys(jobs)}));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
