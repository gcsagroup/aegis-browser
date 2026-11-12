// P-iOS-6: validate iOS Access product Phase 1 evidence pack structure.
// Simulator unit greens must never alone produce status=SIMULATOR_PASS (A4-2 / A4-3).
// Device/TestFlight remain NOT_RUN / out of scope for this pack.
import {createHash} from 'node:crypto';
import {readFile, realpath, stat} from 'node:fs/promises';
import {dirname, isAbsolute, join, relative, resolve, sep} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const STEP_NAMES = ['on', 'load', 'fault', 'recovery', 'off'];
const STEP_IDS = ['A2-1', 'A2-2', 'A2-3', 'A2-4', 'A2-5'];
const VERDICTS = ['NOT_RUN', 'PASS', 'FAIL', 'BLOCKED', 'PARTIAL', 'SIMULATOR_PASS'];
const STATUSES = ['NOT_RUN', 'PASS', 'FAIL', 'BLOCKED', 'PARTIAL', 'SIMULATOR_PASS'];
const CORRELATION =
  /^aegis-ios-p1\/([a-f0-9]{8})\/([A-Za-z0-9_-]{1,64})\/(on|load|fault|recovery|off)$/u;

const FAULT_FIXTURE_MARKERS = [
  'AccessSiteSessionFault',
  'notifyRuntimeFault',
  'FailClosed',
  'forbidDirect',
  'noDirect',
];

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

async function loadJsonFile(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

async function pathExists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

export async function validatePhase1EvidencePack(packDirectory, options = {}) {
  const root = await realpath(packDirectory);
  const statusPath = join(root, 'status.json');
  const templatePath = join(root, 'manifest.template.json');
  const readmePath = join(root, 'README.md');
  const correlationDocPath = join(root, 'correlation.md');
  const artifactsDir = join(root, 'artifacts');

  for (const path of [statusPath, templatePath, readmePath, correlationDocPath]) {
    const info = await stat(path);
    requireValue(info.isFile() && info.size > 0, `missing pack file: ${path}`);
  }
  requireValue((await stat(artifactsDir)).isDirectory(), 'artifacts/ required');

  const status = await loadJsonFile(statusPath);
  requireValue(status?.kind === 'ios-access-product-phase1-evidence-status',
      'status.json kind mismatch');
  requireValue(status.schemaVersion === 1, 'status.json schemaVersion must be 1');
  requireValue(STATUSES.includes(status.status), 'status.json status invalid');
  requireValue(Array.isArray(status.exitCriteria) &&
      ['pios1', 'pios2', 'pios3', 'pios5', 'pios6'].every(id =>
        status.exitCriteria.includes(id)),
  'exit criteria must cover pios1+2+3+5+6');
  requireValue(Array.isArray(status.excludedFromExitClaim) &&
      status.excludedFromExitClaim.includes('pios4'),
  'pios4 must stay excluded from exit claim while DEV-only / unfinished');
  requireValue(status.forbidDirectAsAccessSuccess === true,
      'forbidDirectAsAccessSuccess must be true');
  requireValue(status.allowSimulatorPass === true,
      'allowSimulatorPass must be true');
  requireValue(status.deviceAndTestFlight === 'NOT_RUN',
      'deviceAndTestFlight must remain NOT_RUN for this pack');

  const template = await loadJsonFile(templatePath);
  requireValue(template?.kind === 'ios-access-product-phase1-evidence',
      'manifest.template.json kind mismatch');
  requireValue(template.schemaVersion === 1, 'manifest schemaVersion must be 1');
  requireValue(template.rules?.unitTestsAloneNotPass === true,
      'unitTestsAloneNotPass must be true');
  requireValue(template.rules?.simulatorBuildAllowed === true,
      'simulatorBuildAllowed must be true');
  requireValue(template.rules?.deviceAndTestFlightOutOfScope === true,
      'deviceAndTestFlightOutOfScope must be true');
  requireValue(template.rules?.forbidDirectAsAccessSuccess === true,
      'template must forbid DIRECT as Access success');
  requireValue(template.exitCriteria?.pios4 === 'excluded-while-open',
      'template must exclude unfinished pios4 from PASS claim');
  requireValue(Array.isArray(template.steps) && template.steps.length === 5,
      'template must list five A2 steps');
  template.steps.forEach((step, index) => {
    requireValue(step.id === STEP_IDS[index] && step.name === STEP_NAMES[index],
        `step ${index} must be ${STEP_IDS[index]}/${STEP_NAMES[index]}`);
    requireValue(VERDICTS.includes(step.verdict), `step ${step.id} verdict invalid`);
  });
  requireValue(template.deviceEvidence?.status === 'NOT_RUN',
      'template deviceEvidence.status must be NOT_RUN');
  requireValue(template.deviceEvidence?.testFlight === 'NOT_RUN',
      'template deviceEvidence.testFlight must be NOT_RUN');

  const manifestPath = join(root, 'manifest.json');
  let manifest = null;
  let manifestPresent = false;
  if (await pathExists(manifestPath)) {
    const info = await stat(manifestPath);
    manifestPresent = info.isFile();
  }

  if (manifestPresent) {
    manifest = await loadJsonFile(manifestPath);
    requireValue(manifest?.kind === 'ios-access-product-phase1-evidence',
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
      const step = manifest.steps[index];
      requireValue(step.id === STEP_IDS[index] && step.name === STEP_NAMES[index],
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
        const info = await stat(absolute);
        requireValue(info.isFile() && info.size > 0, `artifact missing for ${step.id}`);
        requireValue(sha256(await readFile(absolute)) === artifact.sha256,
            `artifact digest mismatch for ${step.id}`);
      }
    }

    if (manifest.status === 'PASS') {
      throw new Error(
          'device PASS is out of scope for this pack; use SIMULATOR_PASS');
    }

    if (manifest.status === 'SIMULATOR_PASS') {
      requireValue(manifest.rules?.simulatorBuildAllowed === true,
          'SIMULATOR_PASS requires simulatorBuildAllowed');
      requireValue(manifest.rules?.unitTestsAloneNotPass === true,
          'SIMULATOR_PASS must keep unitTestsAloneNotPass');
      requireValue(manifest.rules?.forbidDirectAsAccessSuccess === true,
          'SIMULATOR_PASS must forbid DIRECT as Access success');
      requireValue(manifest.rules?.deviceAndTestFlightOutOfScope === true,
          'SIMULATOR_PASS must keep device/TestFlight out of scope');
      requireValue(manifest.exitCriteria?.pios4 !== 'required',
          'SIMULATOR_PASS must not require unfinished pios4');
      requireValue(manifest.candidate?.channel === 'SIMULATOR',
          'SIMULATOR_PASS requires candidate.channel=SIMULATOR');
      requireValue(manifest.deviceEvidence?.status === 'NOT_RUN',
          'SIMULATOR_PASS must keep deviceEvidence.status=NOT_RUN');
      requireValue(manifest.deviceEvidence?.testFlight === 'NOT_RUN',
          'SIMULATOR_PASS must keep deviceEvidence.testFlight=NOT_RUN');
      for (const step of manifest.steps) {
        requireValue(step.verdict === 'SIMULATOR_PASS' || step.verdict === 'PASS',
            `SIMULATOR_PASS pack requires ${step.id}=SIMULATOR_PASS`);
        requireValue(step.artifacts.length > 0,
            `SIMULATOR_PASS pack requires artifacts for ${step.id}`);
      }
      requireValue(typeof manifest.uiEvidence?.onCapture === 'string' &&
          manifest.uiEvidence.onCapture,
      'SIMULATOR_PASS requires onCapture UI evidence');
      requireValue(typeof manifest.uiEvidence?.offCapture === 'string' &&
          manifest.uiEvidence.offCapture,
      'SIMULATOR_PASS requires offCapture UI evidence');
      if (options.allowUnitOnlyPass) {
        throw new Error('unit-only SIMULATOR_PASS is forbidden for product A4');
      }
      if (options.requireFaultFixture !== false) {
        const repoRoot = options.repoRoot;
        if (repoRoot) {
          const fault = await inspectFaultFixturePresent(repoRoot);
          requireValue(fault.present,
              'SIMULATOR_PASS requires P-iOS-5 fault fixture API on develop');
        }
      }
    }
  } else {
    requireValue(status.status === 'NOT_RUN' || status.status === 'BLOCKED' ||
        status.status === 'PARTIAL',
    'without manifest.json, pack status cannot be SIMULATOR_PASS');
  }

  return {
    ok: true,
    status: status.status,
    manifestPresent,
    manifestStatus: manifest?.status ?? null,
    exitCriteria: status.exitCriteria,
    excludedFromExitClaim: status.excludedFromExitClaim,
    faultStep: status.faultStep ?? null,
    deviceAndTestFlight: status.deviceAndTestFlight,
  };
}

export async function assertCorrelationFixturePresent(repoRoot) {
  const source = join(repoRoot,
      'apps/ios/AccessKit/AccessSitePhase1Evidence.swift');
  const text = await readFile(source, 'utf8');
  requireValue(text.includes('AccessSitePhase1EvidenceStep'),
      'AccessKit fixture must expose AccessSitePhase1EvidenceStep');
  requireValue(text.includes('buildCorrelationId'),
      'AccessKit fixture must expose buildCorrelationId');
  requireValue(text.includes('aegis-ios-p1'),
      'AccessKit fixture must use aegis-ios-p1 prefix');
  return true;
}

export async function inspectFaultFixturePresent(repoRoot) {
  const candidates = [
    join(repoRoot, 'apps/ios/AccessKit/AccessSiteSessionFault.swift'),
    join(repoRoot, 'apps/ios/AccessKit/AccessSiteSessionFaultHandling.swift'),
    join(repoRoot, 'apps/ios/AccessKit/AccessSiteSessionController.swift'),
  ];
  for (const path of candidates) {
    if (!(await pathExists(path))) {
      continue;
    }
    const text = await readFile(path, 'utf8');
    const hit = FAULT_FIXTURE_MARKERS.some(marker => text.includes(marker));
    if (hit && (path.endsWith('Fault.swift') ||
        path.endsWith('FaultHandling.swift') ||
        text.includes('notifyRuntimeFault') ||
        text.includes('AccessSiteSessionFaultMode'))) {
      return {present: true, path};
    }
  }
  return {present: false, path: null};
}

export async function main(argv = process.argv.slice(2)) {
  const checkIndex = argv.indexOf('--check');
  if (checkIndex < 0 || !argv[checkIndex + 1]) {
    console.error('usage: node ios-access-phase1-evidence.mjs --check <pack-dir>');
    process.exitCode = 2;
    return;
  }
  const packDir = resolve(argv[checkIndex + 1]);
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const repoRoot = resolve(scriptDir, '../../..');
  const result = await validatePhase1EvidencePack(packDir, {repoRoot});
  await assertCorrelationFixturePresent(repoRoot);
  const fault = await inspectFaultFixturePresent(repoRoot);
  console.log(JSON.stringify({...result, faultFixturePresent: fault.present}, null, 2));
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  });
}
