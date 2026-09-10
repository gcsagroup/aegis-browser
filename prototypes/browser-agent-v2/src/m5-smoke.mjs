import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRunContext } from './run-context.mjs';
import { runM5AegisAgent } from './m5-aegis-agent.mjs';
import { resolveModelSelection } from './model-config.mjs';
import { redact, redactEnvironmentSecrets } from './security.mjs';

export async function runM5Smoke(scenarios = Array.from({ length: 12 }, (_, index) => `E${index}`)) {
  const modelSelection = resolveModelSelection({ requireCredential: true });
  const context = createRunContext({ scenarioId: 'M5', candidate: 'm5-smoke', modelSelection });
  const results = [];
  const startedAt = performance.now();
  for (const scenarioId of scenarios) {
    try {
      results.push(await runM5AegisAgent(scenarioId));
    } catch (error) {
      results.push({ scenarioId, status: 'error', error: redactEnvironmentSecrets(error.message) });
    }
  }
  const summary = {
    status: results.every(({ status }) => status === 'passed') ? 'passed' : 'completed-with-failures',
    modelSelection,
    passed: results.filter(({ status }) => status === 'passed').length,
    total: results.length,
    durationMs: Math.round(performance.now() - startedAt),
    results,
  };
  fs.writeFileSync(path.join(context.runRoot, 'metrics.json'), `${JSON.stringify(redact(summary), null, 2)}\n`, {
    mode: 0o600,
  });
  context.journal.assertion('smoke-complete', results.length === scenarios.length);
  context.journal.append('run.finished', summary);
  return { ...summary, runRoot: context.runRoot };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const scenarios = process.argv.slice(2);
  runM5Smoke(scenarios.length ? scenarios : undefined).then((result) => {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (result.status !== 'passed') process.exitCode = 1;
  }).catch((error) => {
    process.stderr.write(`${redactEnvironmentSecrets(error.message)}\n`);
    process.exitCode = 1;
  });
}
