import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {cp, mkdir, rm, writeFile} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {openAsBlob} from 'node:fs';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {
  assertOverlayFixturePresent,
  isValidCorrelationId,
  validatePhase1EvidencePack,
} from './macos-access-phase1-evidence.mjs';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '../../..');
const packRoot = resolve(repoRoot,
    'docs/audit/evidence/macos-access-product-phase1');
const fixtureRoot = resolve(scriptDir, '.tmp-mac-p1-evidence');

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

test('correlation ID accepts only aegis-mac-p1 convention', () => {
  assert.equal(isValidCorrelationId('aegis-mac-p1/8ba3848a/run-1/on'), true);
  assert.equal(isValidCorrelationId('aegis-mac-p1/8ba3848a/run-1/load'), true);
  assert.equal(isValidCorrelationId('aegis-mac-p1/8BA3848A/run-1/on'), false);
  assert.equal(isValidCorrelationId('aegis-mac-p1/8ba3848a/run-1/healthy'), false);
  assert.equal(isValidCorrelationId('other/8ba3848a/run-1/on'), false);
});

test('checked-in pack scaffold stays NOT_RUN and excludes pmac4', async () => {
  const result = await validatePhase1EvidencePack(packRoot);
  assert.equal(result.ok, true);
  assert.equal(result.status, 'NOT_RUN');
  assert.equal(result.manifestPresent, false);
  assert.deepEqual(result.excludedFromExitClaim, ['pmac4']);
  assert.ok(result.exitCriteria.includes('pmac5'));
  assert.ok(result.exitCriteria.includes('pmac6'));
  await assertOverlayFixturePresent(repoRoot);
});

test('PASS without native artifacts is rejected', async () => {
  await withCopy(async () => {
    const sourceSha = 'a'.repeat(40);
    const runId = 'synthetic-pass';
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `B2-${index + 1}`,
      name,
      correlationId: `aegis-mac-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'PASS',
      artifacts: [],
    }));
    await writeFile(resolve(fixtureRoot, 'manifest.json'), JSON.stringify({
      schemaVersion: 1,
      kind: 'macos-access-product-phase1-evidence',
      status: 'PASS',
      candidate: {sourceSha, chromium: 'test', channel: 'DEV'},
      runId,
      exitCriteria: {
        pmac1: 'required', pmac2: 'required', pmac3: 'required',
        pmac4: 'excluded-while-open', pmac5: 'required', pmac6: 'required',
      },
      rules: {
        forbidDirectAsAccessSuccess: true,
        sameCandidateOnly: true,
        nativeBuildRequired: true,
        unitTestsAloneNotPass: true,
      },
      steps,
      uiEvidence: {onCapture: null, offCapture: null},
    }, null, 2));
    await assert.rejects(() => validatePhase1EvidencePack(fixtureRoot),
        /artifacts for B2-1|onCapture UI evidence/);
  });
});

test('filled same-candidate pack with UI captures validates', async () => {
  await withCopy(async () => {
    const sourceSha = 'b'.repeat(40);
    const runId = 'mac-run-1';
    const bytes = 'synthetic-log-line aegis-mac-p1\n';
    await writeFile(resolve(fixtureRoot, 'artifacts/on.log'), bytes);
    await writeFile(resolve(fixtureRoot, 'artifacts/off.png'), 'png-bytes');
    await writeFile(resolve(fixtureRoot, 'artifacts/ui-on.png'), 'on-ui');
    await writeFile(resolve(fixtureRoot, 'artifacts/ui-off.png'), 'off-ui');
    const logDigest = digest(bytes);
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `B2-${index + 1}`,
      name,
      correlationId: `aegis-mac-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'PASS',
      artifacts: [{path: 'artifacts/on.log', sha256: logDigest}],
    }));
    await writeFile(resolve(fixtureRoot, 'manifest.json'), JSON.stringify({
      schemaVersion: 1,
      kind: 'macos-access-product-phase1-evidence',
      status: 'PASS',
      candidate: {sourceSha, chromium: '155', channel: 'DEV'},
      runId,
      exitCriteria: {
        pmac1: 'required', pmac2: 'required', pmac3: 'required',
        pmac4: 'excluded-while-open', pmac5: 'required', pmac6: 'required',
      },
      rules: {
        forbidDirectAsAccessSuccess: true,
        sameCandidateOnly: true,
        nativeBuildRequired: true,
        unitTestsAloneNotPass: true,
      },
      steps,
      uiEvidence: {onCapture: 'artifacts/ui-on.png', offCapture: 'artifacts/ui-off.png'},
    }, null, 2));
    const result = await validatePhase1EvidencePack(fixtureRoot);
    assert.equal(result.manifestStatus, 'PASS');
  });
});

test('template forbids claiming pmac4 as required exit', async () => {
  const templatePath = resolve(packRoot, 'manifest.template.json');
  const template = JSON.parse(await (await openAsBlob(templatePath)).text());
  assert.equal(template.exitCriteria.pmac4, 'excluded-while-open');
  assert.equal(template.rules.unitTestsAloneNotPass, true);
});
