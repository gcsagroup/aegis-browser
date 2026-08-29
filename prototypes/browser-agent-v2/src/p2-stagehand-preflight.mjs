import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PROTOTYPE_ROOT } from './constants.mjs';
import { startFixtureServer } from './fixture-server.mjs';
import { createRunContext } from './run-context.mjs';
import { buildAdapterEnvironment, redact, validateNavigationUrl } from './security.mjs';

const CHROME_EXECUTABLE = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(redact(value), null, 2)}\n`, { mode: 0o600 });
}

function runWorker({ configPath, environment, workingDirectory }) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [
      path.join(PROTOTYPE_ROOT, 'src', 'p2-stagehand-worker.mjs'),
      configPath,
    ], {
      cwd: workingDirectory,
      env: environment,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { if (stdout.length < 1_000_000) stdout += chunk; });
    child.stderr.on('data', (chunk) => { if (stderr.length < 1_000_000) stderr += chunk; });
    const timeout = setTimeout(() => child.kill('SIGKILL'), 25_000);
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      clearTimeout(timeout);
      if (code !== 0) {
        reject(new Error(`Stagehand worker 失败：code=${code} signal=${signal} ${stderr.trim()}`));
        return;
      }
      const lines = stdout.trim().split('\n').filter(Boolean);
      try {
        resolve({ result: JSON.parse(lines.at(-1)), stderr });
      } catch {
        reject(new Error(`Stagehand worker 未返回 JSON：${stdout.slice(-1000)}`));
      }
    });
  });
}

export async function runP2StagehandPreflight() {
  const context = createRunContext({ scenarioId: 'E2', candidate: 'p2-stagehand-preflight' });
  const requests = [];
  const fixture = await startFixtureServer({
    runRoot: context.runRoot,
    onRequest: (request) => requests.push(request),
  });
  const startedAt = performance.now();
  try {
    const targetUrl = `${fixture.origin}/dynamic`;
    validateNavigationUrl(targetUrl, {
      allowedOrigins: [fixture.origin],
      fixtureOrigins: [fixture.origin],
    });
    const configPath = path.join(context.runRoot, 'stagehand-worker-config.json');
    writeJson(configPath, {
      browserExecutable: CHROME_EXECUTABLE,
      profilePath: context.profilePath,
      downloadsPath: path.join(context.runRoot, 'downloads'),
      fixtureSpkiSha256: fixture.spkiSha256,
      targetUrl,
      environment: 'LOCAL',
      telemetryEndpoint: 'http://127.0.0.1:1/v1/traces',
      telemetry: { enabled: false, enforcedBy: 'OTEL_SDK_DISABLED', fallbackEndpoint: 'loopback-deny' },
      model: null,
    });
    fs.mkdirSync(path.join(context.runRoot, 'downloads'), { mode: 0o700 });
    const environment = buildAdapterEnvironment({
      sourceEnvironment: process.env,
      runRoot: context.runRoot,
      workingDirectory: context.workingDirectory,
    });
    const worker = await runWorker({ configPath, environment, workingDirectory: context.workingDirectory });
    if (worker.stderr.trim()) {
      writeJson(path.join(context.runRoot, 'logs-sanitized', 'stagehand-stderr.json'), worker.stderr.split('\n'));
    }
    context.journal.append('navigation.completed', { url: worker.result.url, title: worker.result.title });
    context.journal.append('observation.captured', { phase: 'before-click', snapshot: worker.result.before });
    context.journal.append('action.completed', { tool: 'stagehand-locator-click', target: '#refresh' });
    context.journal.append('observation.captured', { phase: 'after-click', snapshot: worker.result.after });
    context.journal.assertion('local-provider-only', worker.result.provider === 'local' && worker.result.origin === 'launched');
    context.journal.assertion('dynamic-state-updated', worker.result.before.includes('旧结果') && worker.result.after.includes('新结果'));
    const observedPaths = new Set(requests.map(({ path: requestPath }) => requestPath));
    context.journal.assertion(
      'fixture-only-network-observed',
      observedPaths.has('/dynamic') && [...observedPaths].every((requestPath) => ['/dynamic', '/favicon.ico'].includes(requestPath)),
      { observedPaths: [...observedPaths] },
    );
    const residualProcesses = execFileSync('ps', ['-axo', 'command='], { encoding: 'utf8' })
      .split('\n')
      .filter((command) => command.includes(context.profilePath));
    context.journal.assertion('no-residual-browser-process', residualProcesses.length === 0, {
      residualProcessCount: residualProcesses.length,
    });
    const metrics = {
      candidate: 'P2 Stagehand 4.0.2',
      phase: 'local-deterministic-preflight',
      scenarioId: 'E2',
      status: context.journal.assertions.every(({ passed }) => passed) ? 'passed' : 'failed',
      durationMs: Math.round(performance.now() - startedAt),
      modelCalls: 0,
      autonomousMode: 'not-run-no-development-key',
      screenshots: 0,
      fixtureRequests: requests.length,
      profilePath: context.profilePath,
    };
    writeJson(path.join(context.runRoot, 'metrics.json'), metrics);
    writeJson(path.join(context.runRoot, 'network-destinations.json'), requests.map((request) => ({ origin: fixture.origin, ...request })));
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
  runP2StagehandPreflight().then((result) => {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (result.status !== 'passed') process.exitCode = 1;
  }).catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
