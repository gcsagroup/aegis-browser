import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runP1BrowserUseAgent } from './p1-browser-use-agent.mjs';
import { runP2StagehandAgent } from './p2-stagehand-agent.mjs';
import { resolveModelSelection } from './model-config.mjs';
import { createRunContext } from './run-context.mjs';
import { redact, redactEnvironmentSecrets } from './security.mjs';

const SUITES = Object.freeze({
  smoke: Object.freeze({ repeats: 3, scenarios: ['E0', 'E1', 'E2', 'E8'] }),
  matrix: Object.freeze({ repeats: 10, scenarios: ['E0', 'E1', 'E2', 'E8'] }),
});

export function resolveCandidateSet(value = process.env.AEGIS_M2_CANDIDATES ?? 'p1,p2') {
  const candidates = new Set(value.split(',').map((item) => item.trim().toLowerCase()).filter(Boolean));
  if (candidates.size === 0 || [...candidates].some((item) => !['p1', 'p2'].includes(item))) {
    throw new Error('AEGIS_M2_CANDIDATES 只允许逗号分隔的 p1、p2');
  }
  return candidates;
}

async function capture(candidate, scenarioId, repeat, run) {
  const startedAt = performance.now();
  try {
    const result = await run(scenarioId);
    return { candidate, scenarioId, repeat, status: result.status, durationMs: result.durationMs, runRoot: result.runRoot };
  } catch (error) {
    return {
      candidate,
      scenarioId,
      repeat,
      status: 'error',
      durationMs: Math.round(performance.now() - startedAt),
      error: error.message,
    };
  }
}

export async function runM2ModelMatrix(mode = 'smoke') {
  const suite = SUITES[mode];
  if (!suite) throw new Error(`未知 M2 模式：${mode}`);
  const modelSelection = resolveModelSelection({ requireCredential: true });
  const activeCandidates = resolveCandidateSet();
  const context = createRunContext({
    scenarioId: 'M2',
    candidate: 'm2-model-matrix',
    modelSelection,
  });
  const results = [];
  const startedAt = performance.now();
  for (let repeat = 1; repeat <= suite.repeats; repeat += 1) {
    for (const scenarioId of suite.scenarios) {
      if (activeCandidates.has('p1')) {
        results.push(await capture('P1 Browser Use', scenarioId, repeat, runP1BrowserUseAgent));
      }
      if (activeCandidates.has('p2') && scenarioId !== 'E0') {
        results.push(await capture('P2 Stagehand', scenarioId, repeat, runP2StagehandAgent));
      }
    }
  }
  const candidateNames = [
    ...(activeCandidates.has('p1') ? ['P1 Browser Use'] : []),
    ...(activeCandidates.has('p2') ? ['P2 Stagehand'] : []),
  ];
  const byCandidate = Object.fromEntries(candidateNames.map((candidate) => {
    const candidateResults = results.filter((result) => result.candidate === candidate);
    const passed = candidateResults.filter((result) => result.status === 'passed').length;
    return [candidate, {
      passed,
      total: candidateResults.length,
      successRate: candidateResults.length ? passed / candidateResults.length : 0,
    }];
  }));
  const summary = {
    mode,
    status: results.every((result) => result.status === 'passed') ? 'passed' : 'completed-with-failures',
    modelSelection,
    repeats: suite.repeats,
    scenarios: suite.scenarios,
    activeCandidates: [...activeCandidates],
    byCandidate,
    durationMs: Math.round(performance.now() - startedAt),
    results,
  };
  fs.writeFileSync(path.join(context.runRoot, 'metrics.json'), `${JSON.stringify(redact(summary), null, 2)}\n`, { mode: 0o600 });
  const runsPerRepeat = (activeCandidates.has('p1') ? 4 : 0) + (activeCandidates.has('p2') ? 3 : 0);
  context.journal.assertion('matrix-complete', results.length === suite.repeats * runsPerRepeat, {
    count: results.length,
    expected: suite.repeats * runsPerRepeat,
  });
  context.journal.append('run.finished', summary);
  return { ...summary, runRoot: context.runRoot };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  runM2ModelMatrix(process.argv[2] ?? 'smoke').then((result) => {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (result.status !== 'passed') process.exitCode = 1;
  }).catch((error) => {
    process.stderr.write(`${redactEnvironmentSecrets(error.message)}\n`);
    process.exitCode = 1;
  });
}
