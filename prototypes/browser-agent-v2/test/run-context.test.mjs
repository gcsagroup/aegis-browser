import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { createRunContext } from '../src/run-context.mjs';

test('run context 生成完整、脱敏且隔离的证据骨架', (t) => {
  const artifactRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-artifacts-'));
  t.after(() => fs.rmSync(artifactRoot, { recursive: true, force: true }));
  const context = createRunContext({ scenarioId: 'E0', candidate: 'harness', artifactRoot });
  assert.ok(context.profilePath.startsWith(`${context.runRoot}${path.sep}`));
  assert.equal(fs.statSync(context.profilePath).mode & 0o777, 0o700);

  context.journal.append('adapter.output', {
    apiKey: ['sk', 'examplevalue123456789'].join('-'),
    message: 'ok',
  });
  context.journal.assertion('fixture-ready', true, { authorization: 'Bearer abcdefghijklmnop' });
  context.journal.append('run.finished', { status: 'passed' });

  const environment = JSON.parse(fs.readFileSync(path.join(context.runRoot, 'environment.json'), 'utf8'));
  assert.equal(environment.secretValuesRecorded, false);
  const lines = fs.readFileSync(path.join(context.runRoot, 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(lines.map(({ sequence }) => sequence), [1, 2, 3, 4]);
  assert.equal(lines[1].payload.apiKey, '[REDACTED]');
  assert.equal(lines[2].payload.details.authorization, '[REDACTED]');
});
