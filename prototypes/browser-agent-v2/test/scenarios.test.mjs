import assert from 'node:assert/strict';
import test from 'node:test';
import { SCENARIOS, getScenario } from '../src/scenarios.mjs';

test('定义 E0–E11 且 ID 唯一', () => {
  assert.equal(SCENARIOS.length, 12);
  assert.deepEqual(SCENARIOS.map(({ id }) => id), Array.from({ length: 12 }, (_, index) => `E${index}`));
  assert.equal(new Set(SCENARIOS.map(({ id }) => id)).size, 12);
});

test('场景全部限制为本地 fixture 和外部只读', () => {
  for (const scenario of SCENARIOS) {
    assert.equal(scenario.source, 'local-fixture');
    assert.equal(scenario.readOnlyOutsideFixture, true);
    assert.match(scenario.fixturePath, /^\//);
  }
  assert.equal(getScenario('E8').fixturePath, '/prompt-injection');
  assert.throws(() => getScenario('E99'), /未知场景/);
});
