import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ARTIFACT_ROOT } from './constants.mjs';
import { runP0Scenario } from './p0-playwright-mcp.mjs';
import { SCENARIOS } from './scenarios.mjs';

export async function runP0Matrix() {
  const results = [];
  for (const { id } of SCENARIOS) {
    try {
      results.push(await runP0Scenario(id));
    } catch (error) {
      results.push({ scenarioId: id, status: 'failed', error: error.message });
    }
  }
  const summary = {
    schemaVersion: 1,
    candidate: 'P0 Playwright MCP',
    createdAt: new Date().toISOString(),
    runs: results.length,
    passed: results.filter(({ status }) => status === 'passed').length,
    failed: results.filter(({ status }) => status === 'failed').length,
    unsupported: results.filter(({ status }) => status === 'unsupported').length,
    modelCalls: 0,
    results,
  };
  fs.mkdirSync(ARTIFACT_ROOT, { recursive: true, mode: 0o700 });
  const reportPath = path.join(ARTIFACT_ROOT, 'p0-matrix-summary.json');
  fs.writeFileSync(reportPath, `${JSON.stringify(summary, null, 2)}\n`, { mode: 0o600 });
  return { ...summary, reportPath };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  runP0Matrix().then((summary) => {
    process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
    if (summary.failed > 0) process.exitCode = 1;
  });
}
