import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {cp, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
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
const packRoot = join(repoRoot,
    'docs/audit/evidence/ios-access-product-phase1');

const digest = value => createHash('sha256').update(value).digest('hex');

const withCopy = async action => {
  const root = await mkdtemp(join(tmpdir(), 'aegis-ios-p1-evidence-'));
  let error = null;
  try {
    await cp(packRoot, root, {recursive: true});
    await action(root);
  } catch (caught) {
    error = caught;
  }
  await rm(root, {recursive: true, force: true});
  if (error) {
    throw error;
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
  assert.equal(result.faultStep, 'pending-pios5');
  await assertCorrelationFixturePresent(repoRoot);
});

test('SIMULATOR_PASS without native artifacts is rejected', async () => {
  await withCopy(async root => {
    const sourceSha = 'a'.repeat(40);
    const runId = 'synthetic-pass';
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `A2-${index + 1}`,
      name,
      correlationId: `aegis-ios-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'SIMULATOR_PASS',
      artifacts: [],
    }));
    await writeFile(join(root, 'manifest.json'), JSON.stringify({
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
    await assert.rejects(() => validatePhase1EvidencePack(root, {repoRoot}),
        /artifacts for A2-1|onCapture UI evidence/);
  });
});

test('device PASS status is rejected as out of scope', async () => {
  await withCopy(async root => {
    const sourceSha = 'c'.repeat(40);
    const runId = 'device-run';
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `A2-${index + 1}`,
      name,
      correlationId: `aegis-ios-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'PASS',
      artifacts: [{path: 'artifacts/on.log', sha256: digest('x')}],
    }));
    await writeFile(join(root, 'artifacts/on.log'), 'x');
    await writeFile(join(root, 'manifest.json'), JSON.stringify({
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
    await assert.rejects(() => validatePhase1EvidencePack(root, {repoRoot}),
        /device PASS is out of scope/);
  });
});

test('filled same-candidate Simulator pack with UI captures validates', async () => {
  await withCopy(async root => {
    const sourceSha = 'b'.repeat(40);
    const runId = 'ios-run-1';
    const bytes = 'synthetic-log-line aegis-ios-p1\n';
    const relative = 'artifacts/on.log';
    await writeFile(join(root, relative), bytes);
    const onUi = 'artifacts/ui-on.png';
    const offUi = 'artifacts/ui-off.png';
    await writeFile(join(root, onUi), 'on-ui');
    await writeFile(join(root, offUi), 'off-ui');
    const logDigest = digest(bytes);
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `A2-${index + 1}`,
      name,
      correlationId: `aegis-ios-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'SIMULATOR_PASS',
      artifacts: [{path: relative, sha256: logDigest}],
    }));
    await writeFile(join(root, 'manifest.json'), JSON.stringify({
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
      uiEvidence: {onCapture: onUi, offCapture: offUi},
      deviceEvidence: {status: 'NOT_RUN', testFlight: 'NOT_RUN'},
    }, null, 2));
    // Scaffold may land before P-iOS-5; skip fault fixture gate in this unit case.
    const result = await validatePhase1EvidencePack(root, {
      repoRoot,
      requireFaultFixture: false,
    });
    assert.equal(result.manifestStatus, 'SIMULATOR_PASS');
  });
});

test('template forbids claiming pios4 as required exit', async () => {
  const template = JSON.parse(await readFile(
      join(packRoot, 'manifest.template.json'), 'utf8'));
  assert.equal(template.exitCriteria.pios4, 'excluded-while-open');
  assert.equal(template.rules.unitTestsAloneNotPass, true);
  assert.equal(template.rules.simulatorBuildAllowed, true);
  assert.equal(template.deviceEvidence.status, 'NOT_RUN');
});

test('fault fixture inspection reports absent until P-iOS-5 lands', async () => {
  const fault = await inspectFaultFixturePresent(repoRoot);
  // Develop tip may or may not have P-iOS-5 yet; only assert shape.
  assert.equal(typeof fault.present, 'boolean');
  assert.ok('path' in fault);
});
