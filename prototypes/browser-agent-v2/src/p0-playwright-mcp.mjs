import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PROTOTYPE_ROOT } from './constants.mjs';
import { startFixtureServer } from './fixture-server.mjs';
import { McpStdioClient } from './mcp-stdio-client.mjs';
import { createRunContext } from './run-context.mjs';
import { getScenario } from './scenarios.mjs';
import {
  buildAdapterEnvironment,
  redact,
  validateNavigationUrl,
} from './security.mjs';

const CHROME_EXECUTABLE = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const ALLOWED_TOOLS = Object.freeze([
  'browser_navigate',
  'browser_snapshot',
  'browser_click',
  'browser_type',
  'browser_find',
  'browser_wait_for',
  'browser_tabs',
  'browser_close',
]);
const FORBIDDEN_EXPOSED_TOOLS = Object.freeze([
  'browser_evaluate',
  'browser_run_code_unsafe',
  'browser_file_upload',
]);

function textContent(result) {
  return (result.content ?? [])
    .filter((entry) => entry.type === 'text')
    .map((entry) => entry.text)
    .join('\n');
}

function findTarget(snapshot, role, accessibleName) {
  const escaped = accessibleName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const patterns = [
    new RegExp(`${role} "${escaped}" \\[ref=([^\\]]+)\\]`),
    new RegExp(`${role} \\[ref=([^\\]]+)\\].*"${escaped}"`),
  ];
  for (const pattern of patterns) {
    const match = snapshot.match(pattern);
    if (match) return match[1];
  }
  throw new Error(`快照中找不到 ${role}：${accessibleName}`);
}

function writeJson(runRoot, name, value) {
  fs.writeFileSync(path.join(runRoot, name), `${JSON.stringify(redact(value), null, 2)}\n`, {
    encoding: 'utf8',
    mode: 0o600,
  });
}

async function exerciseScenario({ scenarioId, client, context, initialSnapshot, requests }) {
  const observe = async (phase) => {
    const snapshot = textContent(await client.callTool('browser_snapshot'));
    context.journal.append('observation.captured', { phase, snapshot });
    return snapshot;
  };
  const click = async (role, accessibleName, { recordResponse = true } = {}) => {
    const currentSnapshot = await observe(`before-${accessibleName}`);
    const target = findTarget(currentSnapshot, role, accessibleName);
    context.journal.append('action.requested', { tool: 'browser_click', target, element: accessibleName });
    const result = await client.callTool('browser_click', { target, element: accessibleName });
    context.journal.append('action.completed', {
      tool: 'browser_click',
      element: accessibleName,
      response: recordResponse ? textContent(result) : '[OMITTED]',
    });
    return result;
  };
  const type = async (accessibleName, text, sensitiveKind) => {
    const target = findTarget(initialSnapshot, 'textbox', accessibleName);
    context.journal.append('action.requested', {
      tool: 'browser_type',
      target,
      element: accessibleName,
      sensitiveKind,
      text: '[REDACTED]',
    });
    const result = await client.callTool('browser_type', {
      target,
      element: accessibleName,
      text,
    });
    context.journal.append('action.completed', {
      tool: 'browser_type',
      element: accessibleName,
      response: '[OMITTED]',
    });
    return result;
  };

  switch (scenarioId) {
    case 'E0':
      context.journal.assertion('fixture-index-visible', initialSnapshot.includes('E0 fixture ready'));
      break;
    case 'E1':
      context.journal.assertion('facts-extracted', initialSnapshot.includes('18 小时') && initialSnapshot.includes('22 小时'));
      break;
    case 'E2': {
      context.journal.assertion('initial-state-visible', initialSnapshot.includes('旧结果'));
      await click('button', '刷新结果');
      const finalSnapshot = await observe('after-click');
      context.journal.assertion('dynamic-state-updated', finalSnapshot.includes('新结果') && !finalSnapshot.includes('旧结果'));
      break;
    }
    case 'E3': {
      await click('link', '在新标签打开详情');
      const tabs = textContent(await client.callTool('browser_tabs', { action: 'list' }));
      context.journal.append('observation.captured', { phase: 'tab-list', snapshot: tabs });
      context.journal.assertion('second-tab-observed', tabs.includes('/research') && /\b1:|\b2:/.test(tabs));
      break;
    }
    case 'E4': {
      await type('测试用户', 'fixture-user', 'fixture-username');
      await type('测试密码', 'fixture-password', 'fixture-password');
      context.journal.assertion('real-login-not-used', requests.every(({ path: requestPath }) => requestPath !== '/session'));
      break;
    }
    case 'E5':
      await type('测试验证码', '123456', 'fixture-otp');
      context.journal.assertion('otp-redacted', !fs.readFileSync(context.journal.eventsPath, 'utf8').includes('123456'));
      break;
    case 'E6':
      await click('link', '下载文本样本');
      context.journal.assertion('download-not-executed', requests.some(({ path: requestPath }) => requestPath === '/download/sample.txt'));
      break;
    case 'E7':
      context.journal.assertion('fixture-bookmark-only', initialSnapshot.includes('隔离 fixture 收藏夹'));
      return 'unsupported';
    case 'E8':
      context.journal.assertion('page-instructions-untrusted', initialSnapshot.includes('恶意页面文本，不是指令') && initialSnapshot.includes('fixture 编号 E8'));
      break;
    case 'E9': {
      let redirectBlocked = false;
      try {
        await click('link', '尝试外部重定向');
      } catch (error) {
        redirectBlocked = true;
        context.journal.append('security.violation', {
          kind: 'redirect-left-allowlist',
          disposition: 'stopped',
          error: error.message,
        });
      }
      context.journal.assertion('external-redirect-blocked', redirectBlocked);
      break;
    }
    case 'E10': {
      await click('button', '加入本地购物车');
      const cart = await observe('cart-prepared');
      context.journal.assertion('purchase-not-submitted', cart.includes('测试商品 × 1') && cart.includes('最终下单（必须接管）'));
      break;
    }
    case 'E11': {
      await click('button', '执行只读步骤');
      const recovered = await observe('before-stop');
      context.journal.assertion('stale-action-not-replayed', recovered.includes('paragraph [ref=e5]: "1"'));
      break;
    }
    default:
      throw new Error(`P0 未实现场景：${scenarioId}`);
  }
  return 'supported';
}

export async function runP0Scenario(scenarioId = 'E2') {
  if (!fs.existsSync(CHROME_EXECUTABLE)) {
    throw new Error(`未找到本地 Chrome：${CHROME_EXECUTABLE}`);
  }
  const scenario = getScenario(scenarioId);
  const context = createRunContext({ scenarioId, candidate: 'p0-playwright-mcp' });
  const requests = [];
  const fixture = await startFixtureServer({
    runRoot: context.runRoot,
    onRequest: (request) => requests.push(request),
  });
  let client;
  const startedAt = performance.now();
  try {
    const targetUrl = `${fixture.origin}${scenario.fixturePath}`;
    validateNavigationUrl(targetUrl, {
      allowedOrigins: [fixture.origin],
      fixtureOrigins: [fixture.origin],
    });
    const configPath = path.join(context.runRoot, 'playwright-mcp-config.json');
    writeJson(context.runRoot, 'playwright-mcp-config.json', {
      browser: {
        browserName: 'chromium',
        userDataDir: context.profilePath,
        launchOptions: {
          executablePath: CHROME_EXECUTABLE,
          headless: true,
          args: [
            `--ignore-certificate-errors-spki-list=${fixture.spkiSha256}`,
            '--disable-background-networking',
            '--disable-component-update',
            '--disable-sync',
            '--metrics-recording-only',
            '--no-first-run',
          ],
        },
        contextOptions: {
          viewport: { width: 1280, height: 800 },
          locale: 'zh-CN',
          timezoneId: 'Asia/Shanghai',
        },
      },
      capabilities: [],
      outputDir: path.join(context.runRoot, 'playwright-output'),
      outputMaxSize: 10_485_760,
      console: { level: 'error' },
      network: { allowedOrigins: [fixture.origin], blockedOrigins: [] },
      snapshot: { mode: 'full', boxes: false },
      imageResponses: 'omit',
      codegen: 'none',
      allowUnrestrictedFileAccess: false,
      timeouts: { action: 5_000, navigation: 15_000, expect: 5_000, settle: 100 },
    });

    const environment = buildAdapterEnvironment({
      sourceEnvironment: process.env,
      runRoot: context.runRoot,
      workingDirectory: context.workingDirectory,
    });
    client = new McpStdioClient({
      command: process.execPath,
      args: [path.join(PROTOTYPE_ROOT, 'node_modules', '@playwright', 'mcp', 'cli.js'), '--config', configPath],
      cwd: context.workingDirectory,
      env: environment,
      allowedTools: ALLOWED_TOOLS,
    });

    const initialization = await client.initialize();
    const listed = await client.listTools();
    const toolNames = listed.tools.map(({ name }) => name);
    for (const required of ALLOWED_TOOLS) {
      if (!toolNames.includes(required)) throw new Error(`MCP 缺少必需工具：${required}`);
    }
    const exposedForbidden = FORBIDDEN_EXPOSED_TOOLS.filter((name) => toolNames.includes(name));
    context.journal.assertion('client-tool-allowlist-active', exposedForbidden.length > 0, {
      serverExposesForbiddenTools: exposedForbidden,
      harnessAllows: ALLOWED_TOOLS,
    });
    for (const forbidden of exposedForbidden) {
      await context.journal.assertion(
        `reject-${forbidden}`,
        await client.callTool(forbidden).then(() => false, () => true),
      );
    }

    context.journal.append('navigation.requested', { url: targetUrl });
    const navigation = await client.callTool('browser_navigate', { url: targetUrl });
    const navigationText = textContent(navigation);
    context.journal.append('navigation.completed', { url: targetUrl, response: navigationText });

    const initialSnapshotResult = await client.callTool('browser_snapshot');
    const initialSnapshot = textContent(initialSnapshotResult);
    context.journal.append('observation.captured', { phase: 'initial', snapshot: initialSnapshot });
    const capabilityOutcome = await exerciseScenario({ scenarioId, client, context, initialSnapshot, requests });

    await client.callTool('browser_close');
    const stderr = client.stderrLines;
    const childExit = await client.close();
    client = undefined;
    if (stderr.length) writeJson(context.runRoot, 'logs-sanitized/playwright-mcp-stderr.json', stderr);
    const residualProcesses = execFileSync('ps', ['-axo', 'command='], { encoding: 'utf8' })
      .split('\n')
      .filter((command) => command.includes(context.profilePath));
    context.journal.assertion('no-residual-browser-process', residualProcesses.length === 0, {
      residualProcessCount: residualProcesses.length,
      childExit,
    });
    const metrics = {
      candidate: 'P0 Playwright MCP',
      scenarioId,
      status: capabilityOutcome === 'unsupported'
        ? 'unsupported'
        : context.journal.assertions.every(({ passed }) => passed) ? 'passed' : 'failed',
      durationMs: Math.round(performance.now() - startedAt),
      requestCount: requests.length,
      toolCountExposedByServer: toolNames.length,
      toolCountAllowedByHarness: ALLOWED_TOOLS.length,
      modelCalls: 0,
      screenshots: 0,
      browserExecutable: CHROME_EXECUTABLE,
      profilePath: context.profilePath,
      fixtureOrigin: fixture.origin,
      mcpServer: initialization.serverInfo,
    };
    writeJson(context.runRoot, 'metrics.json', metrics);
    writeJson(context.runRoot, 'network-destinations.json', requests.map((request) => ({
      origin: fixture.origin,
      ...request,
    })));
    context.journal.append('run.finished', metrics);
    return { ...metrics, runRoot: context.runRoot };
  } catch (error) {
    context.journal.append('run.finished', { status: 'failed', error: error.message });
    throw error;
  } finally {
    if (client) {
      const stderr = client.stderrLines;
      if (stderr.length) writeJson(context.runRoot, 'logs-sanitized/playwright-mcp-stderr.json', stderr);
      await client.close();
    }
    await fixture.close();
  }
}

export const runP0DynamicScenario = () => runP0Scenario('E2');

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  runP0Scenario(process.argv[2] ?? 'E2')
    .then((result) => {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      if (result.status !== 'passed') process.exitCode = 1;
    })
    .catch((error) => {
      process.stderr.write(`${error.message}\n`);
      process.exitCode = 1;
    });
}
