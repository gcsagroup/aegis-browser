import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PROTOTYPE_ROOT } from './constants.mjs';
import { startFixtureServer } from './fixture-server.mjs';
import { resolveModelSelection } from './model-config.mjs';
import { createRunContext } from './run-context.mjs';
import { buildAdapterEnvironment, redact, validateNavigationUrl } from './security.mjs';

const CHROME_EXECUTABLE = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(redact(value), null, 2)}\n`, { mode: 0o600 });
}

function runWorker({ configPath, environment, workingDirectory }) {
  return new Promise((resolve, reject) => {
    const python = path.join(PROTOTYPE_ROOT, '.venv-browser-use', 'bin', 'python');
    if (!fs.existsSync(python)) {
      reject(new Error('Browser Use 独立环境不存在，请先安装 requirements-browser-use.txt'));
      return;
    }
    const child = spawn(python, [path.join(PROTOTYPE_ROOT, 'src', 'p1_browser_use_worker.py'), configPath], {
      cwd: workingDirectory,
      env: environment,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { if (stdout.length < 2_000_000) stdout += chunk; });
    child.stderr.on('data', (chunk) => { if (stderr.length < 2_000_000) stderr += chunk; });
    const timeout = setTimeout(() => child.kill('SIGKILL'), 30_000);
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      clearTimeout(timeout);
      if (code !== 0) {
        reject(new Error(`Browser Use worker 失败：code=${code} signal=${signal} ${stderr.slice(-2000)}`));
        return;
      }
      const resultLine = stdout.split('\n').findLast((line) => line.startsWith('AEGIS_RESULT='));
      if (!resultLine) {
        reject(new Error(`Browser Use worker 未返回结果：${stdout.slice(-2000)}`));
        return;
      }
      resolve({
        result: JSON.parse(resultLine.slice('AEGIS_RESULT='.length)),
        stdout: stdout.split('\n').filter((line) => line && !line.startsWith('AEGIS_RESULT=')),
        stderr: stderr.split('\n').filter(Boolean),
      });
    });
  });
}

export async function runP1BrowserUsePreflight() {
  const modelSelection = resolveModelSelection();
  const context = createRunContext({
    scenarioId: 'E1',
    candidate: 'p1-browser-use-preflight',
    modelSelection,
  });
  const requests = [];
  const fixture = await startFixtureServer({
    runRoot: context.runRoot,
    onRequest: (request) => requests.push(request),
  });
  const startedAt = performance.now();
  try {
    const targetUrl = `${fixture.origin}/research`;
    validateNavigationUrl(targetUrl, {
      allowedOrigins: [fixture.origin],
      fixtureOrigins: [fixture.origin],
    });
    const configPath = path.join(context.runRoot, 'browser-use-worker-config.json');
    fs.mkdirSync(path.join(context.runRoot, 'downloads'), { mode: 0o700 });
    writeJson(configPath, {
      browser_executable: CHROME_EXECUTABLE,
      profile_path: context.profilePath,
      downloads_path: path.join(context.runRoot, 'downloads'),
      fixture_spki_sha256: fixture.spkiSha256,
      target_url: targetUrl,
      model: null,
    });
    const environment = buildAdapterEnvironment({
      sourceEnvironment: process.env,
      runRoot: context.runRoot,
      workingDirectory: context.workingDirectory,
    });
    const worker = await runWorker({ configPath, environment, workingDirectory: context.workingDirectory });
    if (worker.stdout.length) writeJson(path.join(context.runRoot, 'logs-sanitized', 'browser-use-stdout.json'), worker.stdout);
    if (worker.stderr.length) writeJson(path.join(context.runRoot, 'logs-sanitized', 'browser-use-stderr.json'), worker.stderr);
    context.journal.append('navigation.completed', { url: worker.result.url, title: worker.result.title });
    context.journal.append('observation.captured', { phase: 'browser-state', snapshot: worker.result.state });
    context.journal.assertion('version-locked', worker.result.version === '0.13.8');
    context.journal.assertion('facts-observed', worker.result.state.includes('18 小时') && worker.result.state.includes('22 小时'));
    context.journal.assertion('local-security-enabled', worker.result.use_cloud === false && worker.result.disable_security === false);
    context.journal.assertion('default-extensions-disabled', worker.result.enable_default_extensions === false);
    context.journal.assertion('nonempty-domain-allowlist', worker.result.allowed_domains.includes('127.0.0.1'));
    const observedPaths = new Set(requests.map(({ path: requestPath }) => requestPath));
    context.journal.assertion('fixture-only-network-observed', observedPaths.has('/research') && [...observedPaths].every((requestPath) => ['/research', '/favicon.ico'].includes(requestPath)), { observedPaths: [...observedPaths] });
    const residualProcesses = execFileSync('ps', ['-axo', 'command='], { encoding: 'utf8' })
      .split('\n')
      .filter((command) => command.includes(context.profilePath));
    context.journal.assertion('no-residual-browser-process', residualProcesses.length === 0, { residualProcessCount: residualProcesses.length });
    const metrics = {
      candidate: 'P1 Browser Use 0.13.8',
      phase: 'local-observation-preflight',
      scenarioId: 'E1',
      status: context.journal.assertions.every(({ passed }) => passed) ? 'passed' : 'failed',
      durationMs: Math.round(performance.now() - startedAt),
      modelCalls: 0,
      autonomousMode: !modelSelection.configured
        ? 'not-run-model-selection-not-configured'
        : modelSelection.credentialAvailable
          ? 'not-run-preflight-only'
          : 'not-run-development-credential-unavailable',
      modelSelection,
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
  runP1BrowserUsePreflight().then((result) => {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (result.status !== 'passed') process.exitCode = 1;
  }).catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
