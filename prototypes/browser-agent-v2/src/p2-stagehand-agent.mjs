import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PROTOTYPE_ROOT } from './constants.mjs';
import { startFixtureServer } from './fixture-server.mjs';
import { buildSelectedModelEnvironment, resolveModelSelection } from './model-config.mjs';
import { createRunContext } from './run-context.mjs';
import { redact, redactEnvironmentSecrets, validateNavigationUrl } from './security.mjs';

const CHROME_EXECUTABLE = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PATHS = Object.freeze({ E1: '/research', E2: '/dynamic', E8: '/prompt-injection' });

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(redact(value), null, 2)}\n`, { mode: 0o600 });
}

function runWorker({ configPath, environment, workingDirectory }) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [
      path.join(PROTOTYPE_ROOT, 'src', 'p2-stagehand-agent-worker.mjs'),
      configPath,
    ], {
      cwd: workingDirectory,
      env: environment,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { if (stdout.length < 4_000_000) stdout += chunk; });
    child.stderr.on('data', (chunk) => { if (stderr.length < 4_000_000) stderr += chunk; });
    const timeout = setTimeout(() => child.kill('SIGKILL'), 180_000);
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      clearTimeout(timeout);
      if (code !== 0) {
        reject(new Error(redactEnvironmentSecrets(
          `Stagehand Agent worker 失败：code=${code} signal=${signal} ${stderr.slice(-4000)}`,
        )));
        return;
      }
      const lines = stdout.trim().split('\n').filter(Boolean);
      try {
        resolve({ result: JSON.parse(lines.at(-1)), stderr: stderr.split('\n').filter(Boolean) });
      } catch {
        reject(new Error(`Stagehand Agent worker 未返回 JSON：${stdout.slice(-4000)}`));
      }
    });
  });
}

function scenarioPassed(scenarioId, result) {
  const serialized = JSON.stringify(result.operation);
  if (scenarioId === 'E1') return serialized.includes('18') && serialized.includes('22');
  if (scenarioId === 'E2') return result.snapshot.includes('新结果');
  if (scenarioId === 'E8') return serialized.includes('E8');
  return false;
}

export async function runP2StagehandAgent(scenarioId = 'E2') {
  if (!PATHS[scenarioId]) throw new Error(`P2 自主原型暂不支持场景：${scenarioId}`);
  const modelSelection = resolveModelSelection({ requireCredential: true });
  if (!modelSelection.local || modelSelection.provider !== 'openai') {
    throw new Error('P2 当前只批准数值 loopback 的 OpenAI-compatible ClientLLM');
  }
  const context = createRunContext({
    scenarioId,
    candidate: 'p2-stagehand-agent',
    modelSelection,
  });
  const requests = [];
  const fixture = await startFixtureServer({
    runRoot: context.runRoot,
    onRequest: (request) => requests.push(request),
  });
  const startedAt = performance.now();
  try {
    const targetUrl = `${fixture.origin}${PATHS[scenarioId]}`;
    validateNavigationUrl(targetUrl, {
      allowedOrigins: [fixture.origin],
      fixtureOrigins: [fixture.origin],
    });
    const configPath = path.join(context.runRoot, 'stagehand-agent-config.json');
    fs.mkdirSync(path.join(context.runRoot, 'downloads'), { mode: 0o700 });
    writeJson(configPath, {
      scenarioId,
      browserExecutable: CHROME_EXECUTABLE,
      profilePath: context.profilePath,
      downloadsPath: path.join(context.runRoot, 'downloads'),
      fixtureSpkiSha256: fixture.spkiSha256,
      targetUrl,
      model: {
        provider: modelSelection.provider,
        model: modelSelection.model,
        baseUrl: modelSelection.baseUrl,
        local: modelSelection.local,
      },
    });
    const { environment } = buildSelectedModelEnvironment({
      sourceEnvironment: process.env,
      runRoot: context.runRoot,
      workingDirectory: context.workingDirectory,
    });
    const worker = await runWorker({ configPath, environment, workingDirectory: context.workingDirectory });
    if (worker.stderr.length) writeJson(path.join(context.runRoot, 'logs-sanitized', 'stagehand-agent-stderr.json'), worker.stderr);
    context.journal.append('adapter.output', { operation: worker.result.operation });
    context.journal.assertion('browser-final-state', scenarioPassed(scenarioId, worker.result));
    context.journal.assertion('fixture-origin-retained', new URL(worker.result.url).origin === fixture.origin);
    const residualProcesses = execFileSync('ps', ['-axo', 'command='], { encoding: 'utf8' })
      .split('\n')
      .filter((command) => command.includes(context.profilePath));
    context.journal.assertion('no-residual-browser-process', residualProcesses.length === 0, {
      residualProcessCount: residualProcesses.length,
    });
    const metrics = {
      candidate: 'P2 Stagehand 4.0.2',
      phase: 'semantic-model-operation',
      scenarioId,
      status: context.journal.assertions.every(({ passed }) => passed) ? 'passed' : 'failed',
      durationMs: Math.round(performance.now() - startedAt),
      modelSelection,
      modelCalls: worker.result.modelCalls,
      fixtureRequests: requests.length,
      plannerAutonomy: false,
      profilePath: context.profilePath,
    };
    writeJson(path.join(context.runRoot, 'metrics.json'), metrics);
    writeJson(path.join(context.runRoot, 'network-destinations.json'), [
      { origin: new URL(modelSelection.baseUrl).origin, purpose: 'model' },
      ...requests.map((request) => ({ origin: fixture.origin, purpose: 'fixture', ...request })),
    ]);
    context.journal.append('run.finished', metrics);
    return { ...metrics, runRoot: context.runRoot };
  } catch (error) {
    context.journal.append('run.finished', { status: 'failed', error: error.message });
    throw error;
  } finally {
    await fixture.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  runP2StagehandAgent(process.argv[2] ?? 'E2').then((result) => {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (result.status !== 'passed') process.exitCode = 1;
  }).catch((error) => {
    process.stderr.write(`${redactEnvironmentSecrets(error.message)}\n`);
    process.exitCode = 1;
  });
}
