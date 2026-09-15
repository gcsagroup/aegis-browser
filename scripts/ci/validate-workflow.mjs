#!/usr/bin/env node
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import YAML from 'yaml';

const expectedActions = new Set([
  'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
  'actions/setup-node@820762786026740c76f36085b0efc47a31fe5020',
  'actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97',
  'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
  'actions/setup-node@2028fbc5c25fe9cf00d9f06a71cc4710d4507903',
  'actions/setup-java@0f481fcb613427c0f801b606911222b5b6f3083a',
  'actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f',
  'reactivecircus/android-emulator-runner@a421e43855164a8197daf9d8d40fe71c6996bb0d',
  'pnpm/action-setup@ea17c68df8912ef543352723c149a84f56e3d413',
]);

function fail(message) {
  throw new Error(message);
}

function array(value) {
  return Array.isArray(value) ? value : value == null ? [] : [value];
}

try {
  const path = resolve(process.argv[2] ?? '.github/workflows/quality.yml');
  const iosPath = resolve(process.argv[3] ?? '.github/workflows/ios-coverage.yml');
  const otherPath = resolve(process.argv[4] ?? '.github/workflows/other-platform-coverage.yml');
  const androidPath = resolve(process.argv[5] ?? '.github/workflows/android-java-coverage.yml');
  const otherSource = readFileSync(otherPath, 'utf8');
  const androidSource = readFileSync(androidPath, 'utf8');
  const otherWorkflow = YAML.parse(otherSource);
  const androidWorkflow = YAML.parse(androidSource);
  const source = readFileSync(path, 'utf8');
  const iosSource = readFileSync(iosPath, 'utf8');
  const workflow = YAML.parse(source);
  const iosWorkflow = YAML.parse(iosSource);
  if (!workflow || typeof workflow !== 'object') fail('Workflow must be a YAML object');
  if (!iosWorkflow || typeof iosWorkflow !== 'object') fail('iOS workflow must be a YAML object');
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
  for (const [label, manual] of [['iOS', iosWorkflow], ['Other platform', otherWorkflow], ['Android', androidWorkflow]]) {
    if (JSON.stringify(Object.keys(manual?.on ?? {})) !== JSON.stringify(['workflow_dispatch'])) {
      fail(`${label} workflow must be manual-only`);
    }
    if (manual.permissions?.contents !== 'read' || Object.values(manual.permissions ?? {}).includes('write')) {
      fail(`${label} workflow permissions must be read-only`);
    }
    if (!manual.concurrency || manual.concurrency['cancel-in-progress'] == null) {
      fail(`${label} workflow must define concurrency and cancellation policy`);
    }
  }
  const dispatchInputs = triggers.workflow_dispatch?.inputs ?? {};
  for (const input of ['base_sha', 'target_sha']) {
    if (dispatchInputs[input]?.required !== true) fail(`workflow_dispatch input ${input} must be required`);
  }

  if (workflow.permissions?.contents !== 'read') fail('Workflow contents permission must be read-only');
  for (const [name, permission] of Object.entries(workflow.permissions ?? {})) {
    if (permission === 'write') fail(`Workflow permission ${name} may not be write`);
  }
  if (iosWorkflow.permissions?.contents !== 'read') fail('iOS workflow contents permission must be read-only');
  for (const [name, permission] of Object.entries(iosWorkflow.permissions ?? {})) {
    if (permission === 'write') fail(`iOS workflow permission ${name} may not be write`);
  }
  if (!workflow.concurrency || workflow.concurrency['cancel-in-progress'] == null) {
    fail('Workflow must define concurrency and cancellation policy');
  }
  if (!iosWorkflow.concurrency || iosWorkflow.concurrency['cancel-in-progress'] == null) {
    fail('iOS workflow must define concurrency and cancellation policy');
  }

  const jobs = workflow.jobs ?? {};
  const iosJobs = iosWorkflow.jobs ?? {};
  const quality = jobs.quality;
  const iosCoverage = iosJobs['ios-coverage'];
  const shellCoverage = otherWorkflow.jobs?.['shell-coverage'];
  const powershellCoverage = otherWorkflow.jobs?.['powershell-coverage'];
  const gate = jobs['quality-gate'];
  const expectedJobs = ['quality', 'quality-gate'];
  if (JSON.stringify(Object.keys(otherWorkflow.jobs ?? {}).sort()) !== JSON.stringify(['powershell-coverage', 'shell-coverage'])) fail('Other platform job set must be exactly shell-coverage and powershell-coverage');
  if (JSON.stringify(Object.keys(androidWorkflow.jobs ?? {})) !== JSON.stringify(['android-java-coverage'])) fail('Android job set must be exactly android-java-coverage');
  if (JSON.stringify(Object.keys(jobs).sort()) !== JSON.stringify(expectedJobs)) {
    fail(`Workflow job set must be exactly: ${expectedJobs.join(', ')}`);
  }
  if (JSON.stringify(Object.keys(iosJobs)) !== JSON.stringify(['ios-coverage'])) {
    fail('iOS workflow job set must be exactly: ios-coverage');
  }
  if (quality.name !== 'quality') fail('Quality job check name must be quality');
  if (quality['runs-on'] !== 'macos-15') fail('Quality job must use macos-15');
  if (quality['timeout-minutes'] !== 40) fail('Quality job timeout must be 40 minutes');
  if ('if' in quality) fail('Required quality job may not be conditional');
  for (const [id, job, runner, timeout] of [
    ['shell-coverage', shellCoverage, 'ubuntu-24.04', 30],
    ['powershell-coverage', powershellCoverage, 'windows-2025', 20],
  ]) {
    if (job?.name !== id) fail(`${id} job check name must be ${id}`);
    if (job?.['runs-on'] !== runner) fail(`${id} job must use ${runner}`);
    if (job?.['timeout-minutes'] !== timeout) fail(`${id} timeout must be ${timeout} minutes`);
    if ('if' in job) fail(`Manual ${id} job may not be conditional`);
  }
  if (iosCoverage?.name !== 'ios-coverage') fail('iOS report job check name must be ios-coverage');
  if (iosCoverage?.['runs-on'] !== 'macos-26') fail('iOS report job must use macos-26');
  if (iosCoverage?.['timeout-minutes'] !== 60) fail('iOS report timeout must be 60 minutes');
  if ('if' in iosCoverage) fail('iOS report job may not be conditional within its manual workflow');
  if ('continue-on-error' in iosCoverage) fail('iOS report job must preserve test failures');
  if (gate.name !== 'quality-gate') fail('Required summary check name must be quality-gate');
  if (gate.if !== '${{ always() }}') fail('quality-gate must run with always()');
  const expectedNeeds = ['quality'];
  if (JSON.stringify(array(gate.needs).sort()) !== JSON.stringify(expectedNeeds)) {
    fail(`quality-gate needs must be exactly: ${expectedNeeds.join(', ')}`);
  }
  if (gate['timeout-minutes'] !== 5) fail('quality-gate timeout must be 5 minutes');

  if (gate['runs-on'] !== 'macos-15') fail('quality-gate must use macos-15');
  const allJobs = {...jobs, ...otherWorkflow.jobs, ...androidWorkflow.jobs, 'ios-report/ios-coverage': iosCoverage};
  for (const [id, job] of Object.entries(allJobs)) {
    if ('continue-on-error' in job) fail(`${id} may not suppress failures`);
    if (job.permissions && (job.permissions === 'write-all' || Object.values(job.permissions).some((value) => value !== 'read' && value !== 'none'))) fail(`${id} permissions must be read-only`);
  }
  const allSteps = Object.values(allJobs).flatMap((job) => array(job.steps));
  for (const step of allSteps) {
    if ('continue-on-error' in step) fail(`Step may not suppress failures: ${step.name ?? 'unnamed step'}`);
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
  if (checkoutSteps.length !== 6) fail('Every job must use the approved checkout action exactly once');
  for (const step of checkoutSteps) {
    if (step.with?.['persist-credentials'] !== false) fail('Checkout must disable persisted credentials');
    if (step.with?.['fetch-depth'] !== 0) fail('Checkout must fetch history for identity validation');
  }
  for (const [id, job] of Object.entries(allJobs)) {
    const count = array(job.steps).filter((step) => String(step.uses ?? '').startsWith('actions/checkout@')).length;
    if (count !== 1) fail(`${id} must use the approved checkout action exactly once`);
  }
  const qualityRun = array(quality.steps).find((step) => String(step.run ?? '').includes('run-quality.mjs'));
  if (!qualityRun) fail('Quality job must call the shared run-quality entrypoint');
  for (const name of ['CI_BASE_SHA', 'CI_HEAD_SHA', 'CI_TESTED_SHA', 'CI_EVENT', 'CI_REF', 'REPORT_DIR']) {
    if (!qualityRun.env?.[name]) fail(`Quality entrypoint environment is missing ${name}`);
  }
  const ripgrepInstall = array(quality.steps).find((step) => String(step.run ?? '') === 'bash scripts/ci/install-ripgrep.sh');
  if (!ripgrepInstall || ripgrepInstall['timeout-minutes'] !== 5) {
    fail('Quality job must install the fixed ripgrep tool before preflight');
  }
  const iosRun = array(iosCoverage.steps).find((step) => String(step.run ?? '').includes('run-simulator-tests.sh'));
  const iosNode = array(iosCoverage.steps).find((step) => String(step.uses ?? '').startsWith('actions/setup-node@'));
  if (
    !iosRun || !String(iosRun.run).includes('--execute') || !String(iosRun.run).includes('$IOS_REPORT_DIR') ||
    iosRun.env?.DEVELOPER_DIR !== '/Applications/Xcode_26.6.app/Contents/Developer' ||
    !String(iosCoverage.env?.IOS_REPORT_DIR ?? '').startsWith('/tmp/aegis-ios-') ||
    iosNode?.with?.['node-version'] !== '22.23.1'
  ) fail('ios-coverage must use the frozen simulator coverage interface with Xcode 26.6');
  const iosUpload = array(iosCoverage.steps).find((step) => String(step.uses ?? '').startsWith('actions/upload-artifact@'));
  if (
    String(iosUpload?.with?.path ?? '').includes('DerivedData') ||
    !String(iosUpload?.with?.path ?? '').includes('*.xcresult') ||
    !String(iosUpload?.with?.path ?? '').includes('*-xcodebuild.log') ||
    !String(iosUpload?.with?.path ?? '').includes('*-coverage.json') ||
    !String(iosUpload?.with?.path ?? '').includes('run-metadata.txt')
  ) fail('ios-coverage must upload compact test, coverage, and diagnostic evidence without DerivedData');
  const shellRun = array(shellCoverage.steps).find((step) => String(step.run ?? '').includes('run-shell-coverage.sh'));
  if (!shellRun || !String(shellRun.run).includes('--tested-sha "$GITHUB_SHA"') || !shellRun.env?.REPORT_DIR) {
    fail('shell-coverage must bind the coverage report to GITHUB_SHA');
  }
  const powershellRun = array(powershellCoverage.steps).find((step) => String(step.run ?? '').includes('run-powershell-coverage.ps1'));
  if (
    !powershellRun || !String(powershellRun.run).includes('-TestedSha $env:GITHUB_SHA') ||
    !String(powershellRun.run).includes('-PesterModulePath $module') || !powershellRun.env?.REPORT_DIR
  ) fail('powershell-coverage must bind Pester coverage to GITHUB_SHA and the verified module');
  const gateRun = array(gate.steps).find((step) => String(step.run ?? '').includes('check-required-results.mjs'));
  if (!gateRun || !gateRun.env?.REQUIRED_RESULTS) fail('quality-gate must fail closed through check-required-results.mjs');
  const requiredResults = JSON.parse(gateRun.env.REQUIRED_RESULTS);
  if (JSON.stringify(requiredResults) !== JSON.stringify({quality: '${{ needs.quality.result }}'})) {
    fail('quality-gate required results must be exactly the quality result expression');
  }
  if (gateRun.run !== 'node scripts/ci/check-required-results.mjs' || 'if' in gateRun) {
    fail('quality-gate must execute the fail-closed checker unconditionally');
  }
  for (const [id, job] of [
    ['quality', quality],
    ['ios-coverage', iosCoverage],
    ['shell-coverage', shellCoverage],
    ['powershell-coverage', powershellCoverage],
  ]) {
    const uploads = array(job.steps).filter((step) => String(step.uses ?? '').startsWith('actions/upload-artifact@'));
    if (
      uploads.length !== 1 || !String(uploads[0].if).includes('always()') ||
      uploads[0].with?.['retention-days'] !== 14
    ) fail(`${id} evidence upload must run always and retain artifacts for 14 days`);
  }
  if (/pull_request_target|workflow_run|self-hosted/u.test(`${source}\n${iosSource}\n${otherSource}\n${androidSource}`)) {
    fail('Untrusted or self-hosted execution trigger detected');
  }
  console.log(JSON.stringify({status: 'PASS', path, iosPath, jobs: Object.keys(jobs), iosJobs: Object.keys(iosJobs)}));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
