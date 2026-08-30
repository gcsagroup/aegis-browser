import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRunContext } from './run-context.mjs';
import { runM5AegisAgent } from './m5-aegis-agent.mjs';
import { resolveModelSelection } from './model-config.mjs';
import { redact, redactEnvironmentSecrets } from './security.mjs';

const SCENARIOS = Object.freeze(Array.from({ length: 12 }, (_, index) => `E${index}`));
const SUITES = Object.freeze({
  stability: Object.freeze({ repeats: 3 }),
  matrix: Object.freeze({ repeats: 10 }),
});

export async function runM5Matrix(mode = 'stability') {
  const suite = SUITES[mode];
  if (!suite) throw new Error(`未知 M5 矩阵模式：${mode}`);
  const modelSelection = resolveModelSelection({ requireCredential: true });
  const context = createRunContext({ scenarioId: 'M5', candidate: `m5-${mode}`, modelSelection });
  const results = [];
  const startedAt = performance.now();
  for (let repeat = 1; repeat <= suite.repeats; repeat += 1) {
    for (const scenarioId of SCENARIOS) {
      const runStartedAt = performance.now();
      try {
        const result = await runM5AegisAgent(scenarioId);
        results.push({
          repeat,
          scenarioId,
          status: result.status,
          terminal: result.terminal,
          plannerCalls: result.plannerCalls,
          durationMs: result.durationMs,
          runRoot: result.runRoot,
        });
      } catch (error) {
        results.push({
          repeat,
          scenarioId,
          status: 'error',
          durationMs: Math.round(performance.now() - runStartedAt),
          error: redactEnvironmentSecrets(error.message),
        });
      }
    }
  }
  const passed = results.filter((result) => result.status === 'passed').length;
  const summary = {
    mode,
    status: passed === results.length ? 'passed' : 'completed-with-failures',
    modelSelection,
    repeats: suite.repeats,
    scenarios: SCENARIOS,
    passed,
    total: results.length,
    successRate: results.length ? passed / results.length : 0,
    durationMs: Math.round(performance.now() - startedAt),
    results,
  };
  fs.writeFileSync(path.join(context.runRoot, 'metrics.json'), `${JSON.stringify(redact(summary), null, 2)}\n`, {
    mode: 0o600,
  });
  context.journal.assertion('matrix-complete', results.length === suite.repeats * SCENARIOS.length);
  context.journal.assertion('matrix-all-passed', passed === results.length, { passed, total: results.length });
  context.journal.append('run.finished', summary);
  return { ...summary, runRoot: context.runRoot };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  runM5Matrix(process.argv[2] ?? 'stability').then((result) => {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (result.status !== 'passed') process.exitCode = 1;
  }).catch((error) => {
    process.stderr.write(`${redactEnvironmentSecrets(error.message)}\n`);
    process.exitCode = 1;
  });
}
