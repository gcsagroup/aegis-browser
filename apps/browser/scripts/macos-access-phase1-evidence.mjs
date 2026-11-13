// P-mac-6: validate macOS Access product Phase 1 evidence pack structure.
// Overlay unit greens must never alone produce status=PASS (B4-2 / B4-3).
import {createHash} from 'node:crypto';
import {openAsBlob} from 'node:fs';
import {access, constants, opendir, realpath} from 'node:fs/promises';
import {dirname, isAbsolute, join, relative, resolve, sep} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const STEP_NAMES = ['on', 'load', 'fault', 'recovery', 'off'];
const STEP_IDS = ['B2-1', 'B2-2', 'B2-3', 'B2-4', 'B2-5'];
const VERDICTS = ['NOT_RUN', 'PASS', 'FAIL', 'BLOCKED', 'PARTIAL'];
const STATUSES = ['NOT_RUN', 'PASS', 'FAIL', 'BLOCKED', 'PARTIAL'];
const CORRELATION =
  /^aegis-mac-p1\/([a-f0-9]{8})\/([A-Za-z0-9_-]{1,64})\/(on|load|fault|recovery|off)$/u;

const STEP_NAME_BY_INDEX = new Map(STEP_NAMES.map((name, index) => [index, name]));
const STEP_ID_BY_INDEX = new Map(STEP_IDS.map((id, index) => [index, id]));

export function isValidCorrelationId(value) {
  return typeof value === 'string' && CORRELATION.test(value);
}

function requireValue(condition, reason) {
  if (!condition) {
    throw new Error(reason);
  }
}

function sha256(buffer) {
  return createHash('sha256').update(buffer).digest('hex');
}

async function readTextFile(path) {
  const blob = await openAsBlob(path);
  return blob.text();
}

async function readBinaryFile(path) {
  const blob = await openAsBlob(path);
  return Buffer.from(await blob.arrayBuffer());
}

async function loadJson(path) {
  try {
    return JSON.parse(await readTextFile(path));
  } catch (error) {
    throw error;
  }
}

async function pathExists(path) {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch (error) {
    return false;
  }
}

async function assertRegularFile(path) {
  const bytes = await readBinaryFile(path);
  requireValue(bytes.length > 0, `missing pack file: ${path}`);
  return bytes;
}

async function assertDirectory(path) {
  const dir = await opendir(path);
  await dir.close();
}

function stepIdAt(index) {
  const id = STEP_ID_BY_INDEX.get(index);
  requireValue(typeof id === 'string', `unknown step index ${index}`);
  return id;
}

function stepNameAt(index) {
  const name = STEP_NAME_BY_INDEX.get(index);
  requireValue(typeof name === 'string', `unknown step index ${index}`);
  return name;
}

export async function validatePhase1EvidencePack(packDirectory, options = {}) {
  const root = await realpath(packDirectory);
  const statusPath = join(root, 'status.json');
  const templatePath = join(root, 'manifest.template.json');
  const readmePath = join(root, 'README.md');
  const correlationDocPath = join(root, 'correlation.md');
  const artifactsDir = join(root, 'artifacts');

  for (const path of [statusPath, templatePath, readmePath, correlationDocPath]) {
    await assertRegularFile(path);
  }
  await assertDirectory(artifactsDir);

  const status = await loadJson(statusPath);
  requireValue(status?.kind === 'macos-access-product-phase1-evidence-status',
      'status.json kind mismatch');
  requireValue(status.schemaVersion === 1, 'status.json schemaVersion must be 1');
  requireValue(STATUSES.includes(status.status), 'status.json status invalid');
  requireValue(Array.isArray(status.exitCriteria) &&
      ['pmac1', 'pmac2', 'pmac3', 'pmac5', 'pmac6'].every(id =>
        status.exitCriteria.includes(id)),
  'exit criteria must cover pmac1+2+3+5+6');
  requireValue(Array.isArray(status.excludedFromExitClaim) &&
      status.excludedFromExitClaim.includes('pmac4'),
  'pmac4 must stay excluded from exit claim while DEV-only / unfinished');
  requireValue(status.forbidDirectAsAccessSuccess === true,
      'forbidDirectAsAccessSuccess must be true');

  const template = await loadJson(templatePath);
  requireValue(template?.kind === 'macos-access-product-phase1-evidence',
      'manifest.template.json kind mismatch');
  requireValue(template.schemaVersion === 1, 'manifest schemaVersion must be 1');
  requireValue(template.rules?.unitTestsAloneNotPass === true,
      'unitTestsAloneNotPass must be true');
  requireValue(template.rules?.nativeBuildRequired === true,
      'nativeBuildRequired must be true');
  requireValue(template.rules?.forbidDirectAsAccessSuccess === true,
      'template must forbid DIRECT as Access success');
  requireValue(template.exitCriteria?.pmac4 === 'excluded-while-open',
      'template must exclude unfinished pmac4 from PASS claim');
  requireValue(Array.isArray(template.steps) && template.steps.length === 5,
      'template must list five B2 steps');
  template.steps.forEach((step, index) => {
    requireValue(step.id === stepIdAt(index) && step.name === stepNameAt(index),
        `step ${index} must be ${stepIdAt(index)}/${stepNameAt(index)}`);
    requireValue(VERDICTS.includes(step.verdict), `step ${step.id} verdict invalid`);
  });

  const manifestPath = join(root, 'manifest.json');
  let manifest = null;
  let manifestPresent = false;
  if (await pathExists(manifestPath)) {
    manifestPresent = true;
  }

  if (manifestPresent) {
    manifest = await loadJson(manifestPath);
    requireValue(manifest?.kind === 'macos-access-product-phase1-evidence',
        'manifest.json kind mismatch');
    requireValue(manifest.schemaVersion === 1, 'manifest.json schemaVersion must be 1');
    requireValue(STATUSES.includes(manifest.status), 'manifest status invalid');
    requireValue(/^[a-f0-9]{40}$/u.test(manifest.candidate?.sourceSha ?? ''),
        'candidate.sourceSha must be 40 lowercase hex');
    requireValue(typeof manifest.runId === 'string' &&
        /^[A-Za-z0-9_-]{1,64}$/u.test(manifest.runId),
    'runId invalid');
    requireValue(Array.isArray(manifest.steps) && manifest.steps.length === 5,
        'manifest must list five steps');
    const candidate8 = manifest.candidate.sourceSha.slice(0, 8);
    for (let index = 0; index < 5; index += 1) {
      const step = manifest.steps.at(index);
      requireValue(step && step.id === stepIdAt(index) && step.name === stepNameAt(index),
          `manifest step ${index} id/name mismatch`);
      requireValue(isValidCorrelationId(step.correlationId),
          `invalid correlationId for ${step.id}`);
      const match = step.correlationId.match(CORRELATION);
      requireValue(match[1] === candidate8, 'correlation candidate8 must match sourceSha');
      requireValue(match[2] === manifest.runId, 'correlation run_id must match runId');
      requireValue(match[3] === step.name, 'correlation step must match step name');
      requireValue(VERDICTS.includes(step.verdict), `manifest step ${step.id} verdict invalid`);
      requireValue(Array.isArray(step.artifacts), `artifacts list required for ${step.id}`);
      for (const artifact of step.artifacts) {
        requireValue(artifact && typeof artifact.path === 'string' && artifact.path &&
            !isAbsolute(artifact.path) &&
            !artifact.path.split(/[\\/]/u).includes('..') &&
            /^[a-f0-9]{64}$/u.test(artifact.sha256),
        `artifact for ${step.id} path/sha256 invalid`);
        const absolute = await realpath(resolve(root, artifact.path));
        const child = relative(root, absolute);
        requireValue(child && child !== '..' && !child.startsWith(`..${sep}`) &&
            !isAbsolute(child),
        `artifact path escapes pack for ${step.id}`);
        const bytes = await assertRegularFile(absolute);
        requireValue(sha256(bytes) === artifact.sha256,
            `artifact digest mismatch for ${step.id}`);
      }
    }

    if (manifest.status === 'PASS') {
      requireValue(manifest.rules?.nativeBuildRequired === true,
          'PASS requires nativeBuildRequired');
      requireValue(manifest.rules?.unitTestsAloneNotPass === true,
          'PASS must keep unitTestsAloneNotPass');
      requireValue(manifest.exitCriteria?.pmac4 !== 'required',
          'PASS must not require unfinished pmac4');
      for (const step of manifest.steps) {
        requireValue(step.verdict === 'PASS', `PASS pack requires ${step.id}=PASS`);
        requireValue(step.artifacts.length > 0, `PASS pack requires artifacts for ${step.id}`);
      }
      requireValue(typeof manifest.uiEvidence?.onCapture === 'string' &&
          manifest.uiEvidence.onCapture,
      'PASS requires onCapture UI evidence');
      requireValue(typeof manifest.uiEvidence?.offCapture === 'string' &&
          manifest.uiEvidence.offCapture,
      'PASS requires offCapture UI evidence');
      if (options.allowUnitOnlyPass) {
        throw new Error('unit-only PASS is forbidden for product B4');
      }
    }
  } else {
    requireValue(status.status === 'NOT_RUN' || status.status === 'BLOCKED' ||
        status.status === 'PARTIAL',
    'without manifest.json, pack status cannot be PASS');
  }

  return {
    ok: true,
    status: status.status,
    manifestPresent,
    manifestStatus: manifest?.status ?? null,
    exitCriteria: status.exitCriteria,
    excludedFromExitClaim: status.excludedFromExitClaim,
  };
}

export async function assertOverlayFixturePresent(repoRoot) {
  const header = join(repoRoot,
      'apps/browser/overlay/chrome/browser/aegis/access/access_site_proxy_phase1_evidence_fixture.h');
  const source = join(repoRoot,
      'apps/browser/overlay/chrome/browser/aegis/access/access_site_proxy_phase1_evidence_fixture.cc');
  const text = await readTextFile(header);
  requireValue(text.includes('RunSiteProxyPhase1EvidenceDrill'),
      'overlay fixture must expose RunSiteProxyPhase1EvidenceDrill');
  requireValue(text.includes('BuildPhase1EvidenceCorrelationId'),
      'overlay fixture must expose BuildPhase1EvidenceCorrelationId');
  requireValue(await pathExists(source), 'overlay fixture cc missing');
  return true;
}

export async function main(argv = process.argv.slice(2)) {
  const checkIndex = argv.indexOf('--check');
  if (checkIndex < 0 || !argv[checkIndex + 1]) {
    console.error('usage: node macos-access-phase1-evidence.mjs --check PACK_DIR');
    process.exitCode = 2;
    return;
  }
  const packDir = resolve(argv[checkIndex + 1]);
  const result = await validatePhase1EvidencePack(packDir);
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const repoRoot = resolve(scriptDir, '../../..');
  await assertOverlayFixturePresent(repoRoot);
  console.log(JSON.stringify(result, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  });
}
