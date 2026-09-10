import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { ARTIFACT_ROOT } from './constants.mjs';
import { EventJournal } from './events.mjs';
import { assertIsolatedProfile, assertPathWithin } from './security.mjs';

function timestampId() {
  return new Date().toISOString().replace(/[-:.]/g, '').replace('Z', 'Z-');
}

export function createRunContext({
  scenarioId,
  candidate,
  artifactRoot = ARTIFACT_ROOT,
  modelSelection = null,
}) {
  if (!/^[A-Z][A-Z0-9-]{0,31}$/.test(scenarioId)) throw new Error(`无效场景 ID：${scenarioId}`);
  if (!/^[a-z][a-z0-9-]{0,31}$/.test(candidate)) throw new Error(`无效候选 ID：${candidate}`);

  const runId = `${timestampId()}${candidate}-${scenarioId.toLowerCase()}-${randomUUID().slice(0, 8)}`;
  const runRoot = assertPathWithin(artifactRoot, path.join(artifactRoot, runId), 'run 目录');
  const profilePath = path.join(runRoot, 'profile');
  const workingDirectory = path.join(runRoot, 'work');
  for (const directory of [
    runRoot,
    profilePath,
    workingDirectory,
    path.join(runRoot, 'screenshots'),
    path.join(runRoot, 'logs-sanitized'),
  ]) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  }
  assertIsolatedProfile(runRoot, profilePath);

  const environment = {
    schemaVersion: 1,
    runId,
    scenarioId,
    candidate,
    createdAt: new Date().toISOString(),
    platform: process.platform,
    architecture: process.arch,
    node: process.version,
    osRelease: os.release(),
    profilePath,
    workingDirectory,
    modelSelection,
    secretValuesRecorded: false,
  };
  fs.writeFileSync(path.join(runRoot, 'environment.json'), `${JSON.stringify(environment, null, 2)}\n`, {
    encoding: 'utf8',
    mode: 0o600,
  });
  fs.writeFileSync(path.join(runRoot, 'network-destinations.json'), '[]\n', {
    encoding: 'utf8',
    mode: 0o600,
  });

  const journal = new EventJournal({ runId, scenarioId, runRoot });
  journal.append('run.started', { candidate, profilePath });
  return Object.freeze({
    runId,
    runRoot,
    profilePath,
    workingDirectory,
    journal,
  });
}
