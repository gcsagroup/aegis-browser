import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveCandidateSet } from '../src/m2-model-matrix.mjs';

test('M2 候选集默认包含 P1/P2，并可在安全失败后只运行 P1', () => {
  assert.deepEqual([...resolveCandidateSet('p1,p2')], ['p1', 'p2']);
  assert.deepEqual([...resolveCandidateSet('p1')], ['p1']);
  assert.throws(() => resolveCandidateSet('p1,unknown'), /只允许/);
});
