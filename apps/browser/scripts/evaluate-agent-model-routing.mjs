#!/usr/bin/env node
// Offline paired evaluation. Verdicts come from independent acceptance labels,
// never from a task's completed state or the router's confidence.
import {readFileSync, writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

export const ARMS = ['fixed_high', 'fixed_low', 'auto'];
const EFFORTS = ['', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'];

function requireThat(condition, message) {
  if (!condition) throw new Error(message);
}

function fields(value, names, label) {
  requireThat(value && typeof value === 'object' && !Array.isArray(value), `${label}: object required`);
  requireThat(Object.keys(value).length === names.length &&
    names.every(name => Object.hasOwn(value, name)), `${label}: unexpected or missing fields`);
}

function token(value, label) {
  requireThat(typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,160}$/.test(value), `${label}: invalid identifier`);
}

function count(value, label, nullable = true) {
  requireThat((nullable && value === null) ||
    (Number.isSafeInteger(value) && value >= 0 && value <= 1e12), `${label}: invalid count`);
}

function validateAttempt(attempt) {
  fields(attempt, ['kind', 'model', 'effort', 'inputTokens', 'cachedInputTokens',
    'outputTokens', 'reasoningTokens', 'prices'], 'attempt');
  requireThat(['generation', 'typesafe'].includes(attempt.kind), 'invalid attempt kind');
  requireThat(typeof attempt.model === 'string' &&
    (attempt.model.length > 0 || attempt.kind === 'typesafe') &&
    attempt.model.length <= 256 && !/\s/.test(attempt.model) &&
    [...attempt.model].every(character => character.charCodeAt(0) >= 32 &&
      character.charCodeAt(0) !== 127), 'invalid model');
  requireThat(EFFORTS.includes(attempt.effort), 'invalid effort');
  for (const name of ['inputTokens', 'cachedInputTokens', 'outputTokens', 'reasoningTokens']) {
    count(attempt[name], name);
  }
  for (const [part, total] of [['cachedInputTokens', 'inputTokens'], ['reasoningTokens', 'outputTokens']]) {
    requireThat(attempt[part] === null || attempt[total] === null ||
      attempt[part] <= attempt[total], `${part}: inconsistent subset`);
  }
  fields(attempt.prices, ['inputMicrousdPerMillion', 'cachedInputMicrousdPerMillion',
    'outputMicrousdPerMillion'], 'prices');
  for (const [name, value] of Object.entries(attempt.prices)) count(value, name);
}

// Return integer millionths of a micro-dollar to avoid floating point billing.
// reasoningTokens is already included in outputTokens: never bill it twice.
export function attemptCostUnits(attempt) {
  validateAttempt(attempt);
  const {inputTokens: input, outputTokens: output, cachedInputTokens: cached, prices} = attempt;
  if (input === null || output === null) return null;
  const {inputMicrousdPerMillion: regularRate, cachedInputMicrousdPerMillion: cachedRate,
    outputMicrousdPerMillion: outputRate} = prices;
  if (output > 0 && outputRate === null) return null;
  let inputCost = 0n;
  if (input > 0) {
    if (cached === null) {
      if (regularRate === null || cachedRate !== regularRate) return null;
      inputCost = BigInt(input) * BigInt(regularRate);
    } else {
      if ((input > cached && regularRate === null) || (cached > 0 && cachedRate === null)) return null;
      inputCost = BigInt(input - cached) * BigInt(regularRate ?? 0) +
        BigInt(cached) * BigInt(cachedRate ?? 0);
    }
  }
  return inputCost + BigInt(output) * BigInt(outputRate ?? 0);
}

function validateManifest(manifest) {
  fields(manifest, ['schemaVersion', 'datasetId', 'datasetSha256', 'browserRevision',
    'policyRevision', 'budgetRevision', 'cases', 'repeats'], 'manifest');
  requireThat(manifest.schemaVersion === 1, 'unsupported schema');
  for (const key of ['datasetId', 'browserRevision', 'policyRevision', 'budgetRevision']) token(manifest[key], key);
  requireThat(typeof manifest.datasetSha256 === 'string' &&
    /^[a-f0-9]{64}$/.test(manifest.datasetSha256), 'invalid dataset digest');
  requireThat(Number.isInteger(manifest.repeats) && manifest.repeats > 0 &&
    manifest.repeats <= 100, 'invalid repeats');
  requireThat(Array.isArray(manifest.cases) && manifest.cases.length > 0 &&
    manifest.cases.length <= 10000, 'invalid case manifest');
  const cases = new Map();
  for (const item of manifest.cases) {
    fields(item, ['caseId', 'fixtureSha256'], 'case');
    token(item.caseId, 'caseId');
    requireThat(typeof item.fixtureSha256 === 'string' &&
      /^[a-f0-9]{64}$/.test(item.fixtureSha256) && !cases.has(item.caseId), 'invalid or duplicate case');
    cases.set(item.caseId, item.fixtureSha256);
  }
  return cases;
}

function validateRecord(record, manifest, cases) {
  fields(record, ['taskId', 'caseId', 'fixtureSha256', 'repeat', 'arm', 'status',
    'correct', 'latencyMs', 'fallbackUsed', 'attempts'], 'record');
  token(record.taskId, 'taskId');
  requireThat(cases.has(record.caseId) && cases.get(record.caseId) === record.fixtureSha256,
    'case not in frozen manifest or fixture changed');
  requireThat(Number.isInteger(record.repeat) && record.repeat >= 0 &&
    record.repeat < manifest.repeats, 'invalid repeat');
  requireThat(ARMS.includes(record.arm), 'invalid arm');
  requireThat(['completed', 'failed', 'cancelled'].includes(record.status), 'invalid status');
  requireThat(record.correct === null || typeof record.correct === 'boolean', 'independent verdict required');
  requireThat(record.correct !== true || record.status === 'completed', 'unsuccessful task cannot be correct');
  count(record.latencyMs, 'latencyMs', false);
  requireThat(typeof record.fallbackUsed === 'boolean', 'fallbackUsed must be boolean');
  requireThat(Array.isArray(record.attempts) && record.attempts.length <= 1000, 'invalid attempts');
  record.attempts.forEach(validateAttempt);
  requireThat(!record.fallbackUsed || record.attempts.filter(a => a.kind === 'generation').length >= 2,
    'fallback requires primary and fallback attempts');
}

function percentile(sorted, p) {
  return sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)] ?? null;
}

function summarize(records) {
  let costUnits = 0n;
  let unknownCostTasks = 0;
  const attempts = records.flatMap(row => row.attempts);
  for (const row of records) {
    const costs = row.attempts.map(attemptCostUnits);
    if (costs.includes(null)) unknownCostTasks++;
    for (const cost of costs) if (cost !== null) costUnits += cost;
  }
  const tokens = {};
  for (const name of ['inputTokens', 'cachedInputTokens', 'outputTokens', 'reasoningTokens']) {
    const known = attempts.reduce((sum, a) => sum + BigInt(a[name] ?? 0), 0n);
    requireThat(known <= BigInt(Number.MAX_SAFE_INTEGER), `${name}: aggregate exceeds safe integer`);
    tokens[name] = {known: Number(known),
      unknownAttempts: attempts.filter(a => a[name] === null).length};
  }
  const judged = records.filter(row => row.correct !== null).length;
  const correct = records.filter(row => row.correct === true).length;
  const requested = records.filter(row => row.attempts.some(a => a.kind === 'generation')).length;
  const latencies = records.map(row => row.latencyMs).sort((a, b) => a - b);
  const knownCostUsd = Number(costUnits) / 1e12;
  return {tasks: records.length, judged, correct, unjudged: records.length - judged,
    correctness: judged ? correct / judged : null,
    generationTasks: requested, fallbackTasks: records.filter(row => row.fallbackUsed).length,
    fallbackRate: requested ? records.filter(row => row.fallbackUsed).length / requested : null,
    latencyMs: {p50: percentile(latencies, 0.5), p95: percentile(latencies, 0.95), p99: percentile(latencies, 0.99)},
    attempts: attempts.length, typesafeAttempts: attempts.filter(a => a.kind === 'typesafe').length,
    tokens, knownCostUsd, unknownCostTasks, totalCostUsd: unknownCostTasks ? null : knownCostUsd,
    costPerCorrectTaskUsd: unknownCostTasks || judged !== records.length || !correct ? null : knownCostUsd / correct};
}

function relative(candidate, baseline) {
  return candidate === null || baseline === null || baseline === 0 ? null : candidate / baseline - 1;
}

export function evaluateRouting(input) {
  fields(input, ['manifest', 'records'], 'input');
  const cases = validateManifest(input.manifest);
  requireThat(Array.isArray(input.records), 'records must be an array');
  const keys = new Set();
  const tasks = new Set();
  for (const row of input.records) {
    validateRecord(row, input.manifest, cases);
    const key = JSON.stringify([row.arm, row.caseId, row.repeat]);
    requireThat(!keys.has(key) && !tasks.has(row.taskId), 'duplicate task or paired record');
    keys.add(key);
    tasks.add(row.taskId);
  }
  const expected = cases.size * input.manifest.repeats * ARMS.length;
  requireThat(keys.size === expected, `incomplete paired cohort: expected ${expected}, got ${keys.size}`);
  const arms = Object.fromEntries(ARMS.map(arm => [arm, summarize(input.records.filter(row => row.arm === arm))]));
  const candidate = arms.auto;
  const comparisons = Object.fromEntries(ARMS.filter(arm => arm !== 'auto').map(arm => {
    const baseline = arms[arm];
    return [arm, {
      correctnessDelta: candidate.unjudged || baseline.unjudged ? null : candidate.correctness - baseline.correctness,
      costPerCorrectTaskChange: relative(candidate.costPerCorrectTaskUsd, baseline.costPerCorrectTaskUsd),
      totalCostChange: relative(candidate.totalCostUsd, baseline.totalCostUsd),
      p95LatencyChange: relative(candidate.latencyMs.p95, baseline.latencyMs.p95),
    }];
  }));
  return {schemaVersion: 1, kind: 'aegis-agent-routing-paired-evaluation',
    manifest: input.manifest, arms, comparisons,
    evidenceComplete: ARMS.every(arm => arms[arm].unjudged === 0 && arms[arm].unknownCostTasks === 0),
    releaseEligible: false,
    note: 'Offline paired accounting only; independent labels and real browser/API evidence remain required. No statistical significance or deployment approval is inferred.'};
}

function main(args) {
  requireThat(args.length === 2, 'Usage: node evaluate-agent-model-routing.mjs INPUT.json REPORT.json (report must not exist)');
  const report = evaluateRouting(JSON.parse(readFileSync(args[0], 'utf8')));
  writeFileSync(args[1], JSON.stringify(report, null, 2) + '\n', {flag: 'wx', mode: 0o600});
  console.log(JSON.stringify({kind: report.kind, evidenceComplete: report.evidenceComplete,
    releaseEligible: false, report: args[1]}));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { main(process.argv.slice(2)); } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
