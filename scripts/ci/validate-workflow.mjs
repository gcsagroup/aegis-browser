#!/usr/bin/env node
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import YAML from 'yaml';

const expectedActions = new Set([
  'actions/checkout@11d5960a326750d5838078e36cf38b85af677262',
  'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020',
  'actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1',
  'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
  'pnpm/action-setup@b906affcce14559ad1aafd4ab0e942779e9f58b1',
]);

function fail(message) {
  throw new Error(message);
}

function array(value) {
  return Array.isArray(value) ? value : value == null ? [] : [value];
}

try {
  const path = resolve(process.argv[2] ?? '.github/workflows/quality.yml');
  const source = readFileSync(path, 'utf8');
  const workflow = YAML.parse(source);
  if (!workflow || typeof workflow !== 'object') fail('Workflow must be a YAML object');
  const triggers = workflow.on ?? {};
  const triggerNames = Object.keys(triggers).sort();
  if (JSON.stringify(triggerNames) !== JSON.stringify(['pull_request', 'push', 'workflow_dispatch'])) {
    fail(`Unexpected workflow triggers: ${triggerNames.join(', ')}`);
  }
  for (const event of ['pull_request', 'push']) {
    const config = triggers[event] ?? {};
    if (!array(config.branches).includes('main')) fail(`${event} must target main`);
    if ('paths' in config || 'paths-ignore' in config) fail(`${event} may not filter paths`);
  }
  const dispatchInputs = triggers.workflow_dispatch?.inputs ?? {};
  for (const input of ['base_sha', 'target_sha']) {
    if (dispatchInputs[input]?.required !== true) fail(`workflow_dispatch input ${input} must be required`);
  }

  if (workflow.permissions?.contents !== 'read') fail('Workflow contents permission must be read-only');
  for (const [name, permission] of Object.entries(workflow.permissions ?? {})) {
    if (permission === 'write') fail(`Workflow permission ${name} may not be write`);
  }
  if (!workflow.concurrency || workflow.concurrency['cancel-in-progress'] == null) {
    fail('Workflow must define concurrency and cancellation policy');
  }

  const jobs = workflow.jobs ?? {};
  const quality = jobs.quality;
  const gate = jobs['quality-gate'];
  if (!quality || !gate || Object.keys(jobs).length !== 2) fail('Workflow must contain only quality and quality-gate jobs');
  if (quality.name !== 'quality') fail('Quality job check name must be quality');
  if (quality['runs-on'] !== 'macos-15') fail('Quality job must use macos-15');
  if (quality['timeout-minutes'] !== 40) fail('Quality job timeout must be 40 minutes');
  if ('if' in quality) fail('Required quality job may not be conditional');
  if (gate.name !== 'quality-gate') fail('Required summary check name must be quality-gate');
  if (!String(gate.if).includes('always()')) fail('quality-gate must run with always()');
  if (!array(gate.needs).includes('quality')) fail('quality-gate must require quality');
  if (gate['timeout-minutes'] !== 5) fail('quality-gate timeout must be 5 minutes');

  const allSteps = [...array(quality.steps), ...array(gate.steps)];
  for (const step of allSteps) {
    if (step.uses) {
      if (String(step.uses).startsWith('./')) continue;
      if (!/@[0-9a-f]{40}$/u.test(step.uses)) fail(`Action is not pinned to a full commit: ${step.uses}`);
      if (!expectedActions.has(step.uses)) fail(`Action pin is not approved: ${step.uses}`);
    }
    if (step.run && String(step.run).includes('${{')) {
      fail(`Expressions must enter shell steps through env, not run text: ${step.name ?? 'unnamed step'}`);
    }
  }
  const checkoutSteps = allSteps.filter((step) => String(step.uses ?? '').startsWith('actions/checkout@'));
  if (checkoutSteps.length !== 2) fail('Both jobs must use the approved checkout action exactly once');
  for (const step of checkoutSteps) {
    if (step.with?.['persist-credentials'] !== false) fail('Checkout must disable persisted credentials');
    if (step.with?.['fetch-depth'] !== 0) fail('Checkout must fetch history for identity validation');
  }
  const qualityRun = array(quality.steps).find((step) => String(step.run ?? '').includes('run-quality.mjs'));
  if (!qualityRun) fail('Quality job must call the shared run-quality entrypoint');
  for (const name of ['CI_BASE_SHA', 'CI_HEAD_SHA', 'CI_TESTED_SHA', 'CI_EVENT', 'CI_REF', 'REPORT_DIR']) {
    if (!qualityRun.env?.[name]) fail(`Quality entrypoint environment is missing ${name}`);
  }
  const gateRun = array(gate.steps).find((step) => String(step.run ?? '').includes('check-required-results.mjs'));
  if (!gateRun || !gateRun.env?.REQUIRED_RESULTS) fail('quality-gate must fail closed through check-required-results.mjs');
  const upload = array(quality.steps).find((step) => String(step.uses ?? '').startsWith('actions/upload-artifact@'));
  if (!upload || !String(upload.if).includes('always()') || upload.with?.['retention-days'] !== 14) {
    fail('Evidence upload must run always and retain artifacts for 14 days');
  }
  if (/pull_request_target|workflow_run|self-hosted/u.test(source)) {
    fail('Untrusted or self-hosted execution trigger detected');
  }
  console.log(JSON.stringify({status: 'PASS', path, jobs: Object.keys(jobs)}));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
