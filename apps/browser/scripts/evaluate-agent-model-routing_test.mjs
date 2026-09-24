import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
import {ARMS, attemptCostUnits, evaluateRouting} from './evaluate-agent-model-routing.mjs';

function attempt(overrides = {}) {
  return {kind: 'generation', model: 'fixture-model', effort: 'low',
    inputTokens: 1000, cachedInputTokens: 200, outputTokens: 500, reasoningTokens: 300,
    prices: {inputMicrousdPerMillion: 1000000, cachedInputMicrousdPerMillion: 100000,
      outputMicrousdPerMillion: 2000000}, ...overrides};
}

function fixture() {
  return {manifest: {schemaVersion: 1, datasetId: 'synthetic-unit-test', datasetSha256: 'a'.repeat(64),
    browserRevision: 'fixture-revision', policyRevision: 'fixture-policy', budgetRevision: 'fixture-budget',
    cases: [{caseId: 'simple', fixtureSha256: 'b'.repeat(64)}, {caseId: 'complex', fixtureSha256: 'c'.repeat(64)}],
    repeats: 1}, records: ARMS.flatMap(arm => ['simple', 'complex'].map((caseId, index) => ({
    taskId: `${arm}-${caseId}`, caseId, fixtureSha256: (index ? 'c' : 'b').repeat(64),
    repeat: 0, arm, status: 'completed', correct: true, latencyMs: index ? 1000 : 100,
    fallbackUsed: false, attempts: [attempt()],
  })))};
}

test('actual cache rates and reasoning subset produce exact cost without double billing', () => {
  assert.equal(attemptCostUnits(attempt()), 1820000000n);
  assert.equal(attemptCostUnits(attempt({reasoningTokens: 0})), 1820000000n);
  assert.equal(attemptCostUnits(attempt({reasoningTokens: null})), 1820000000n);
});

test('unknown usage, prices, and cache split never silently become free', () => {
  assert.equal(attemptCostUnits(attempt({inputTokens: null, cachedInputTokens: null})), null);
  assert.equal(attemptCostUnits(attempt({inputTokens: null})), null);
  assert.equal(attemptCostUnits(attempt({outputTokens: null})), null);
  assert.equal(attemptCostUnits(attempt({cachedInputTokens: null})), null);
  assert.equal(attemptCostUnits(attempt({prices: {inputMicrousdPerMillion: 1,
    cachedInputMicrousdPerMillion: null, outputMicrousdPerMillion: 2}})), null);
  assert.equal(attemptCostUnits(attempt({cachedInputTokens: null, prices: {
    inputMicrousdPerMillion: 1000000, cachedInputMicrousdPerMillion: 1000000,
    outputMicrousdPerMillion: 2000000}})), 2000000000n);
  assert.equal(attemptCostUnits(attempt({inputTokens: 0, cachedInputTokens: null, outputTokens: 0,
    reasoningTokens: null, prices: {inputMicrousdPerMillion: null, cachedInputMicrousdPerMillion: null,
      outputMicrousdPerMillion: null}})), 0n);
});

test('TypeSafe, failed attempts and fallback are included in total and cost per correct task', () => {
  const input = fixture();
  const row = input.records.find(row => row.arm === 'auto');
  row.fallbackUsed = true;
  row.attempts.push(attempt({kind: 'typesafe', effort: ''}), attempt({model: 'fallback-model', effort: 'high'}));
  const result = evaluateRouting(input);
  assert.equal(result.arms.auto.attempts, 4);
  assert.equal(result.arms.auto.typesafeAttempts, 1);
  assert.equal(result.arms.auto.fallbackRate, 0.5);
  assert.equal(result.arms.auto.totalCostUsd, 0.00728);
  assert.equal(result.arms.auto.costPerCorrectTaskUsd, 0.00364);
  assert.equal(result.comparisons.fixed_high.totalCostChange, 1);
  assert.equal(result.releaseEligible, false);
});

test('failed tasks remain in denominators and their costs cannot disappear', () => {
  const input = fixture();
  const row = input.records.find(row => row.arm === 'auto');
  row.status = 'failed';
  row.correct = false;
  const result = evaluateRouting(input);
  assert.equal(result.arms.auto.correctness, 0.5);
  assert.equal(result.arms.auto.costPerCorrectTaskUsd, 0.00364);
  assert.equal(result.comparisons.fixed_high.correctnessDelta, -0.5);
  row.correct = true;
  assert.throws(() => evaluateRouting(input), /unsuccessful task/);
});

test('unknown verdict is not inferred from completed; differences withheld for unmatched labels', () => {
  const input = fixture();
  input.records[0].correct = null;
  const result = evaluateRouting(input);
  assert.equal(result.arms.fixed_high.unjudged, 1);
  assert.equal(result.arms.fixed_high.correctness, 1);
  assert.equal(result.comparisons.fixed_high.correctnessDelta, null);
  assert.equal(result.comparisons.fixed_high.costPerCorrectTaskChange, null);
  assert.equal(result.evidenceComplete, false);
});

test('incomplete or duplicate cohorts and changed fixtures fail closed', () => {
  const input = fixture();
  input.records.pop();
  assert.throws(() => evaluateRouting(input), /incomplete paired cohort/);
  const duplicate = fixture();
  duplicate.records.push(structuredClone(duplicate.records[0]));
  assert.throws(() => evaluateRouting(duplicate), /duplicate task/);
  const changed = fixture();
  changed.records[0].fixtureSha256 = 'd'.repeat(64);
  assert.throws(() => evaluateRouting(changed), /fixture changed/);
});

test('unknown router price invalidates total savings, preserves known subtotal', () => {
  const input = fixture();
  input.records[4].attempts.push(attempt({kind: 'typesafe', effort: '', prices: {
    inputMicrousdPerMillion: null, cachedInputMicrousdPerMillion: null, outputMicrousdPerMillion: null}}));
  const result = evaluateRouting(input);
  assert.equal(result.arms.auto.knownCostUsd, 0.00364);
  assert.equal(result.arms.auto.unknownCostTasks, 1);
  assert.equal(result.arms.auto.totalCostUsd, null);
  assert.equal(result.comparisons.fixed_high.totalCostChange, null);
  assert.equal(result.evidenceComplete, false);
});

test('failed TypeSafe calls with no returned model remain in the accounting cohort', () => {
  const input = fixture();
  input.records[4].attempts.push(attempt({kind: 'typesafe', model: '', effort: '',
    inputTokens: null, cachedInputTokens: null, outputTokens: null, reasoningTokens: null}));
  const result = evaluateRouting(input);
  assert.equal(result.arms.auto.typesafeAttempts, 1);
  assert.equal(result.arms.auto.totalCostUsd, null);
  assert.equal(result.evidenceComplete, false);
});

test('non-model tasks do not dilute fallback rate; null token details stay unknown', () => {
  const input = fixture();
  input.records[4].attempts = [];
  input.records[5].fallbackUsed = true;
  input.records[5].attempts.push(attempt({reasoningTokens: null}));
  const result = evaluateRouting(input);
  assert.equal(result.arms.auto.fallbackRate, 1);
  assert.equal(result.arms.auto.tokens.reasoningTokens.known, 300);
  assert.equal(result.arms.auto.tokens.reasoningTokens.unknownAttempts, 1);
  assert.equal(result.arms.auto.latencyMs.p95, 1000);
});

test('invalid detail subsets, negative values and extra sensitive fields are rejected', () => {
  assert.throws(() => attemptCostUnits(attempt({reasoningTokens: 501})), /inconsistent subset/);
  assert.throws(() => attemptCostUnits(attempt({cachedInputTokens: 1001})), /inconsistent subset/);
  assert.throws(() => attemptCostUnits(attempt({outputTokens: -1})), /invalid count/);
  const input = fixture();
  input.records[0].prompt = 'must not accept raw goal in evaluation artifact';
  assert.throws(() => evaluateRouting(input), /unexpected or missing/);
});

test('CLI writes once, refuses overwriting evidence, and produces no savings claim for unknown cost', () => {
  const directory = mkdtempSync(join(tmpdir(), 'aegis-routing-eval-'));
  try {
    const source = join(directory, 'input.json');
    const report = join(directory, 'report.json');
    writeFileSync(source, JSON.stringify(fixture()));
    const script = fileURLToPath(new URL('./evaluate-agent-model-routing.mjs', import.meta.url));
    const first = spawnSync(process.execPath, [script, source, report], {encoding: 'utf8'});
    assert.equal(first.status, 0, first.stderr);
    const bytes = readFileSync(report, 'utf8');
    assert.equal(JSON.parse(bytes).releaseEligible, false);
    const second = spawnSync(process.execPath, [script, source, report], {encoding: 'utf8'});
    assert.notEqual(second.status, 0);
    assert.equal(readFileSync(report, 'utf8'), bytes);
  } finally { rmSync(directory, {recursive: true, force: true}); }
});
