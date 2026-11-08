import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {cp, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {
  assertOverlayFixturePresent,
  isValidCorrelationId,
  validatePhase1EvidencePack,
} from './macos-access-phase1-evidence.mjs';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '../../..');
const packRoot = join(repoRoot,
    'docs/audit/evidence/macos-access-product-phase1');

const digest = value => createHash('sha256').update(value).digest('hex');

async function withCopy(action) {
  const root = await mkdtemp(join(tmpdir(), 'aegis-mac-p1-evidence-'));
  try {
    await cp(packRoot, root, {recursive: true});
    await action(root);
  } finally {
    await rm(root, {recursive: true, force: true});
  }
}

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
  await withCopy(async root => {
    const sourceSha = 'a'.repeat(40);
    const runId = 'synthetic-pass';
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `B2-${index + 1}`,
      name,
      correlationId: `aegis-mac-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'PASS',
      artifacts: [],
    }));
    await writeFile(join(root, 'manifest.json'), JSON.stringify({
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
    await assert.rejects(() => validatePhase1EvidencePack(root),
        /artifacts for B2-1|onCapture UI evidence/);
  });
});

test('filled same-candidate pack with UI captures validates', async () => {
  await withCopy(async root => {
    const sourceSha = 'b'.repeat(40);
    const runId = 'mac-run-1';
    const bytes = 'synthetic-log-line aegis-mac-p1\n';
    const relative = 'artifacts/on.log';
    await writeFile(join(root, relative), bytes);
    const offRelative = 'artifacts/off.png';
    await writeFile(join(root, offRelative), 'png-bytes');
    const onUi = 'artifacts/ui-on.png';
    const offUi = 'artifacts/ui-off.png';
    await writeFile(join(root, onUi), 'on-ui');
    await writeFile(join(root, offUi), 'off-ui');
    const logDigest = digest(bytes);
    const steps = ['on', 'load', 'fault', 'recovery', 'off'].map((name, index) => ({
      id: `B2-${index + 1}`,
      name,
      correlationId: `aegis-mac-p1/${sourceSha.slice(0, 8)}/${runId}/${name}`,
      verdict: 'PASS',
      artifacts: [{path: relative, sha256: logDigest}],
    }));
    await writeFile(join(root, 'manifest.json'), JSON.stringify({
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
      uiEvidence: {onCapture: onUi, offCapture: offUi},
    }, null, 2));
    const result = await validatePhase1EvidencePack(root);
    assert.equal(result.manifestStatus, 'PASS');
  });
});

test('template forbids claiming pmac4 as required exit', async () => {
  const template = JSON.parse(await readFile(
      join(packRoot, 'manifest.template.json'), 'utf8'));
  assert.equal(template.exitCriteria.pmac4, 'excluded-while-open');
  assert.equal(template.rules.unitTestsAloneNotPass, true);
});
