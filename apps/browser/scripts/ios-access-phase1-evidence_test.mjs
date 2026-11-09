import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {cp, mkdir, rm, writeFile} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {openAsBlob} from 'node:fs';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {
  assertCorrelationFixturePresent,
  inspectFaultFixturePresent,
  isValidCorrelationId,
  validatePhase1EvidencePack,
} from './ios-access-phase1-evidence.mjs';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '../../..');
const packRoot = resolve(repoRoot,
    'docs/audit/evidence/ios-access-product-phase1');
const fixtureRoot = resolve(scriptDir, '.tmp-ios-p1-evidence');

const digest = value => createHash('sha256').update(value).digest('hex');

const withCopy = async action => {
  await rm(fixtureRoot, {recursive: true, force: true});
  await mkdir(fixtureRoot, {recursive: true});
  await cp(packRoot, fixtureRoot, {recursive: true});
  try {
    await action();
  } finally {
    await rm(fixtureRoot, {recursive: true, force: true});
  }
};

test('correlation ID accepts only aegis-ios-p1 convention', () => {
  assert.equal(isValidCorrelationId('aegis-ios-p1/a01308c9/run-1/on'), true);
  assert.equal(isValidCorrelationId('aegis-ios-p1/a01308c9/run-1/load'), true);
  assert.equal(isValidCorrelationId('aegis-ios-p1/A01308C9/run-1/on'), false);
  assert.equal(isValidCorrelationId('aegis-ios-p1/a01308c9/run-1/healthy'), false);
  assert.equal(isValidCorrelationId('aegis-mac-p1/a01308c9/run-1/on'), false);
});

test('checked-in pack scaffold stays NOT_RUN and excludes pios4', async () => {
  const result = await validatePhase1EvidencePack(packRoot, {repoRoot});
  assert.equal(result.ok, true);
  assert.equal(result.status, 'NOT_RUN');
  assert.equal(result.manifestPresent, false);
  assert.deepEqual(result.excludedFromExitClaim, ['pios4']);
  assert.ok(result.exitCriteria.includes('pios5'));
  assert.ok(result.exitCriteria.includes('pios6'));
  assert.equal(result.deviceAndTestFlight, 'NOT_RUN');
  assert.equal(result.faultStep, 'fixture-present');
  await assertCorrelationFixturePresent(repoRoot);
});

test('SIMULATOR_PASS without native artifacts is rejected', async () => {
  await withCopy(async () => {
    const sourceSha = 'a'.repeat(40);
    const runId = 'synthetic-pass';
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `A2-${index + 1}`,
      name,
      correlationId: `aegis-ios-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'SIMULATOR_PASS',
      artifacts: [],
    }));
    await writeFile(resolve(fixtureRoot, 'manifest.json'), JSON.stringify({
      schemaVersion: 1,
      kind: 'ios-access-product-phase1-evidence',
      status: 'SIMULATOR_PASS',
      candidate: {sourceSha, channel: 'SIMULATOR'},
      runId,
      exitCriteria: {
        pios1: 'required', pios2: 'required', pios3: 'required',
        pios4: 'excluded-while-open', pios5: 'required', pios6: 'required',
      },
      rules: {
        forbidDirectAsAccessSuccess: true,
        sameCandidateOnly: true,
        simulatorBuildAllowed: true,
        deviceAndTestFlightOutOfScope: true,
        unitTestsAloneNotPass: true,
      },
      steps,
      uiEvidence: {onCapture: null, offCapture: null},
      deviceEvidence: {status: 'NOT_RUN', testFlight: 'NOT_RUN'},
    }, null, 2));
    await assert.rejects(() => validatePhase1EvidencePack(fixtureRoot, {repoRoot}),
        /artifacts for A2-1|onCapture UI evidence/);
  });
});

test('device PASS status is rejected as out of scope', async () => {
  await withCopy(async () => {
    const sourceSha = 'c'.repeat(40);
    const runId = 'device-run';
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `A2-${index + 1}`,
      name,
      correlationId: `aegis-ios-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'PASS',
      artifacts: [{path: 'artifacts/on.log', sha256: digest('x')}],
    }));
    await writeFile(resolve(fixtureRoot, 'artifacts/on.log'), 'x');
    await writeFile(resolve(fixtureRoot, 'manifest.json'), JSON.stringify({
      schemaVersion: 1,
      kind: 'ios-access-product-phase1-evidence',
      status: 'PASS',
      candidate: {sourceSha, channel: 'DEVICE'},
      runId,
      exitCriteria: {
        pios1: 'required', pios2: 'required', pios3: 'required',
        pios4: 'excluded-while-open', pios5: 'required', pios6: 'required',
      },
      rules: {
        forbidDirectAsAccessSuccess: true,
        sameCandidateOnly: true,
        simulatorBuildAllowed: true,
        deviceAndTestFlightOutOfScope: true,
        unitTestsAloneNotPass: true,
      },
      steps,
      uiEvidence: {onCapture: 'artifacts/on.log', offCapture: 'artifacts/on.log'},
      deviceEvidence: {status: 'NOT_RUN', testFlight: 'NOT_RUN'},
    }, null, 2));
    await assert.rejects(() => validatePhase1EvidencePack(fixtureRoot, {repoRoot}),
        /device PASS is out of scope/);
  });
});

test('filled same-candidate Simulator pack with UI captures validates', async () => {
  await withCopy(async () => {
    const sourceSha = 'b'.repeat(40);
    const runId = 'ios-run-1';
    const bytes = 'synthetic-log-line aegis-ios-p1\n';
    await writeFile(resolve(fixtureRoot, 'artifacts/on.log'), bytes);
    await writeFile(resolve(fixtureRoot, 'artifacts/ui-on.png'), 'on-ui');
    await writeFile(resolve(fixtureRoot, 'artifacts/ui-off.png'), 'off-ui');
    const logDigest = digest(bytes);
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `A2-${index + 1}`,
      name,
      correlationId: `aegis-ios-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'SIMULATOR_PASS',
      artifacts: [{path: 'artifacts/on.log', sha256: logDigest}],
    }));
    await writeFile(resolve(fixtureRoot, 'manifest.json'), JSON.stringify({
      schemaVersion: 1,
      kind: 'ios-access-product-phase1-evidence',
      status: 'SIMULATOR_PASS',
      candidate: {sourceSha, channel: 'SIMULATOR'},
      runId,
      exitCriteria: {
        pios1: 'required', pios2: 'required', pios3: 'required',
        pios4: 'excluded-while-open', pios5: 'required', pios6: 'required',
      },
      rules: {
        forbidDirectAsAccessSuccess: true,
        sameCandidateOnly: true,
        simulatorBuildAllowed: true,
        deviceAndTestFlightOutOfScope: true,
        unitTestsAloneNotPass: true,
      },
      steps,
      uiEvidence: {onCapture: 'artifacts/ui-on.png', offCapture: 'artifacts/ui-off.png'},
      deviceEvidence: {status: 'NOT_RUN', testFlight: 'NOT_RUN'},
    }, null, 2));
    // Scaffold may land before P-iOS-5; skip fault fixture gate in this unit case.
    const result = await validatePhase1EvidencePack(fixtureRoot, {
      repoRoot,
      requireFaultFixture: false,
    });
    assert.equal(result.manifestStatus, 'SIMULATOR_PASS');
  });
});

test('template forbids claiming pios4 as required exit', async () => {
  const templatePath = resolve(packRoot, 'manifest.template.json');
  const template = JSON.parse(await (await openAsBlob(templatePath)).text());
  assert.equal(template.exitCriteria.pios4, 'excluded-while-open');
  assert.equal(template.rules.unitTestsAloneNotPass, true);
  assert.equal(template.rules.simulatorBuildAllowed, true);
  assert.equal(template.deviceEvidence.status, 'NOT_RUN');
});

test('fault fixture inspection finds the P-iOS-5 API on this branch', async () => {
  const fault = await inspectFaultFixturePresent(repoRoot);
  assert.equal(fault.present, true);
  assert.equal(typeof fault.path, 'string');
  assert.ok(fault.path.endsWith('AccessSiteSessionFault.swift'));
});
