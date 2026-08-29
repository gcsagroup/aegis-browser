import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PROTOTYPE_ROOT } from './constants.mjs';
import { createRunContext } from './run-context.mjs';

export function runP4NativeContract() {
  const context = createRunContext({ scenarioId: 'E0-E11', candidate: 'p4-native-contract' });
  const sourceRoot = path.join(PROTOTYPE_ROOT, 'native-contract');
  const binary = path.join(context.runRoot, 'aegis-native-broker-test');
  const startedAt = performance.now();
  execFileSync('clang++', [
    '-std=c++20', '-Wall', '-Wextra', '-Werror', '-O0', '-g',
    '-I', sourceRoot,
    path.join(sourceRoot, 'aegis_native_broker.cc'),
    path.join(sourceRoot, 'aegis_native_broker_test.cc'),
    '-o', binary,
  ], { stdio: 'pipe' });
  const result = JSON.parse(execFileSync(binary, [], { encoding: 'utf8' }));
  const metrics = {
    candidate: 'P4 Native Action Broker contract',
    phase: 'standalone-cpp-contract-preflight',
    status: result.status,
    assertions: result.assertions,
    scenarios: result.scenarios,
    durationMs: Math.round(performance.now() - startedAt),
    chromiumIntegrated: false,
    modelCalls: 0,
  };
  fs.writeFileSync(path.join(context.runRoot, 'metrics.json'), `${JSON.stringify(metrics, null, 2)}\n`, { mode: 0o600 });
  context.journal.assertion('native-policy-contracts', result.status === 'passed', result);
  context.journal.append('run.finished', metrics);
  return { ...metrics, runRoot: context.runRoot };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const result = runP4NativeContract();
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
