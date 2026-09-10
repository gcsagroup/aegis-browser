import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { PROTOTYPE_ROOT } from '../src/constants.mjs';

test('第三方候选均固定精确版本和许可证', () => {
  const lock = JSON.parse(fs.readFileSync(`${PROTOTYPE_ROOT}/prototype-lock.json`, 'utf8'));
  assert.equal(lock.schemaVersion, 1);
  assert.equal(lock.modelSelection.mode, 'runtime-user-configured');
  assert.equal(lock.modelSelection.defaultProvider, null);
  assert.equal(lock.modelSelection.defaultModel, null);
  assert.deepEqual(lock.modelSelection.selectionEnvironment, [
    'AEGIS_V2_PROVIDER',
    'AEGIS_V2_MODEL',
    'AEGIS_V2_BASE_URL',
  ]);
  assert.equal(lock.localModelProvider.runtime.version, '0.31.3');
  assert.match(lock.localModelProvider.model.revision, /^[0-9a-f]{40}$/);
  assert.match(lock.localModelProvider.model.weightsSha256, /^[0-9a-f]{64}$/);
  assert.ok(lock.localModelProvider.model.weightsBytes > 0);
  assert.equal(lock.localModelProvider.model.remoteCodeAllowed, false);
  assert.equal(lock.localModelProvider.scope, 'isolated-prototype-only');
  assert.equal(Object.keys(lock.candidates).length, 6);
  for (const candidate of Object.values(lock.candidates)) {
    assert.match(candidate.version, /^\d+\.\d+\.\d+(?:[-.][A-Za-z0-9.-]+)?$/);
    assert.ok(candidate.license.length > 0);
  }
  assert.equal(lock.forcedEnvironment.ANONYMIZED_TELEMETRY, 'false');
  assert.equal(lock.forcedEnvironment.SKYVERN_TELEMETRY, 'false');
  assert.ok(lock.forbiddenCapabilities.includes('daily-profile'));
  assert.ok(lock.forbiddenCapabilities.includes('real-transaction'));
});
