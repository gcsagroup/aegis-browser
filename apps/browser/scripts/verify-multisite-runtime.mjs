#!/usr/bin/env node

import {execFile, spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {closeSync, constants as fsConstants, openSync, readFileSync} from 'node:fs';
import {
  access,
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  realpath,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises';
import {homedir, tmpdir} from 'node:os';
import {createServer as createHttpServer} from 'node:http';
import {basename, dirname, join, resolve} from 'node:path';
import process from 'node:process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';

const BROWSER_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CHROMIUM_ROOT_MARKER = join(BROWSER_ROOT, '.chromium-root');
const DEFAULT_TIMEOUT_MS = 45_000;
const DEFAULT_SETTLE_MS = 2_000;
const POLL_INTERVAL_MS = 100;
const execFileAsync = promisify(execFile);
const DEFAULT_URLS = [
  'https://ip.gcsa.org/',
  'https://example.com/',
  'https://www.wikipedia.org/',
  'https://browserleaks.com/canvas',
  'https://www.cloudflare.com/',
  'https://www.youtube.com/',
];
const FEATURE_MODES = new Map([
  ['default', null],
  ['aegis-off', 'AegisEnabled'],
  ['tracker-off', 'AegisTrackerBlocking'],
  ['filter-off', 'AegisFilterListUpdater'],
  ['link-off', 'AegisLinkSanitize'],
  [
    'core-off',
    'AegisTrackerBlocking,AegisFilterListUpdater,AegisLinkSanitize',
  ],
]);

class VerificationError extends Error {}

function fail(message) {
  throw new VerificationError(message);
}

function assert(condition, message) {
  if (!condition) {
    fail(message);
  }
}

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

function resolveDefaultChromiumRoot() {
  const configuredRoot = process.env.CHROMIUM_ROOT?.trim();
  if (configuredRoot) {
    return configuredRoot;
  }
  try {
    const markerRoot = readFileSync(CHROMIUM_ROOT_MARKER, 'utf8').trim();
    if (markerRoot) {
      return markerRoot;
    }
  } catch {
    // 与 scripts/common.sh 保持相同的可选 marker 语义。
  }
  return join(homedir(), 'Projects', 'GCSA-aegis-chromium');
}

const DEFAULT_RELEASE_APP = join(
  resolveDefaultChromiumRoot(),
  'src',
  'out',
  'AegisRelease',
  'Chromium.app',
);

function printUsage() {
  process.stdout.write(`用法：
  node apps/browser/scripts/verify-multisite-runtime.mjs [选项]

选项：
  --chromium PATH      Release Chromium.app 或 Chromium 可执行文件
                       默认：${DEFAULT_RELEASE_APP}
  --url URL            覆盖默认站点；可重复指定
  --feature-mode MODE  default、aegis-off、tracker-off、filter-off、
                       link-off 或 core-off；默认 default
  --timeout-ms N       每站点超时，默认 ${DEFAULT_TIMEOUT_MS}
  --settle-ms N        页面完成后的稳定观察时间，默认 ${DEFAULT_SETTLE_MS}
  --headless           使用 --headless=new；默认显示真实窗口
  --audit-outbound     用临时 NetLog 汇总实际观察到的目标主机
  --background-quiet   诊断对照：关闭 Chromium 常见后台网络，不改变产品默认
  --threat-index PATH  启动前将本地威胁索引注入临时 Profile
  --expect-text TEXT   要求每个页面正文包含指定文本
  --expect-aegis-interstitial
                       要求每个站点进入 Aegis 安全拦截页
  --cpu-observe-ms N   页面稳定后统计 Chromium 进程树 CPU 增量
  --credential-fixture 启动 loopback 跨站密码表单 fixture
  --startup-only       不访问测试站点，只观察启动稳定性与后台出站
  --observe-ms N       startup-only 观察时长，默认 15000
  --keep-profile       成功后也保留临时 Profile 与日志
  --report PATH        写入 JSON 证据
  --dry-run            只校验参数和 Release 可执行文件
  --help               显示帮助

脚本始终使用 mkdtemp 创建独立 Profile，并只终止自己启动的 Chromium。
默认会访问列出的真实外部站点；页面可能自行请求其他服务（包括 GitHub
连通性探测），但脚本不执行 GitHub 仓库/API 操作，也不修改系统代理。
`);
}

function parseArgs(argv) {
  const options = {
    chromium: process.env.AEGIS_CHROMIUM_BIN?.trim() || DEFAULT_RELEASE_APP,
    auditOutbound: false,
    backgroundQuiet: false,
    cpuObserveMs: 0,
    credentialFixture: false,
    dryRun: false,
    expectAegisInterstitial: false,
    expectText: null,
    featureMode: 'default',
    headless: false,
    help: false,
    keepProfile: false,
    observeMs: 15_000,
    report: null,
    settleMs: DEFAULT_SETTLE_MS,
    startupOnly: false,
    threatIndex: null,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    urls: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--chromium') {
      options.chromium = argv[++index];
      assert(options.chromium, '--chromium 缺少路径');
    } else if (argument === '--url') {
      const value = argv[++index];
      assert(value, '--url 缺少 URL');
      options.urls.push(value);
    } else if (argument === '--feature-mode') {
      options.featureMode = argv[++index];
      assert(
        FEATURE_MODES.has(options.featureMode),
        `未知 feature mode：${options.featureMode ?? '缺失'}`,
      );
    } else if (argument === '--timeout-ms') {
      options.timeoutMs = Number(argv[++index]);
      assert(
        Number.isSafeInteger(options.timeoutMs) && options.timeoutMs >= 5_000,
        '--timeout-ms 必须是至少 5000 的整数',
      );
    } else if (argument === '--settle-ms') {
      options.settleMs = Number(argv[++index]);
      assert(
        Number.isSafeInteger(options.settleMs) && options.settleMs >= 0,
        '--settle-ms 必须是非负整数',
      );
    } else if (argument === '--report') {
      options.report = argv[++index];
      assert(options.report, '--report 缺少路径');
    } else if (argument === '--headless') {
      options.headless = true;
    } else if (argument === '--audit-outbound') {
      options.auditOutbound = true;
    } else if (argument === '--background-quiet') {
      options.backgroundQuiet = true;
    } else if (argument === '--threat-index') {
      options.threatIndex = argv[++index];
      assert(options.threatIndex, '--threat-index 缺少路径');
    } else if (argument === '--expect-text') {
      options.expectText = argv[++index];
      assert(options.expectText, '--expect-text 缺少文本');
    } else if (argument === '--expect-aegis-interstitial') {
      options.expectAegisInterstitial = true;
    } else if (argument === '--cpu-observe-ms') {
      options.cpuObserveMs = Number(argv[++index]);
      assert(
        Number.isSafeInteger(options.cpuObserveMs) &&
          options.cpuObserveMs >= 5_000,
        '--cpu-observe-ms 必须是至少 5000 的整数',
      );
    } else if (argument === '--credential-fixture') {
      options.credentialFixture = true;
    } else if (argument === '--startup-only') {
      options.startupOnly = true;
    } else if (argument === '--observe-ms') {
      options.observeMs = Number(argv[++index]);
      assert(
        Number.isSafeInteger(options.observeMs) && options.observeMs >= 1_000,
        '--observe-ms 必须是至少 1000 的整数',
      );
    } else if (argument === '--keep-profile') {
      options.keepProfile = true;
    } else if (argument === '--dry-run') {
      options.dryRun = true;
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else if (argument === '--') {
      continue;
    } else {
      fail(`未知参数：${argument}`);
    }
  }

  assert(
    !options.startupOnly || options.urls.length === 0,
    '--startup-only 不能与 --url 同时使用',
  );
  assert(
    !options.startupOnly || !options.expectText,
    '--startup-only 不能与 --expect-text 同时使用',
  );
  assert(
    !options.startupOnly || !options.expectAegisInterstitial,
    '--startup-only 不能与 --expect-aegis-interstitial 同时使用',
  );
  assert(
    !options.credentialFixture || options.urls.length === 0,
    '--credential-fixture 不能与 --url 同时使用',
  );
  assert(
    !options.credentialFixture || !options.startupOnly,
    '--credential-fixture 不能与 --startup-only 同时使用',
  );
  if (
    !options.startupOnly &&
    !options.credentialFixture &&
    options.urls.length === 0
  ) {
    options.urls = [...DEFAULT_URLS];
  }
  options.urls = options.urls.map((value) => {
    let parsed;
    try {
      parsed = new URL(value);
    } catch {
      fail(`URL 无效：${value}`);
    }
    assert(
      parsed.protocol === 'https:' || parsed.protocol === 'http:',
      `只允许 HTTP(S) 站点：${value}`,
    );
    return parsed.href;
  });
  return options;
}

async function resolveChromiumExecutable(inputPath) {
  let executable = resolve(inputPath);
  if (basename(executable).endsWith('.app')) {
    executable = join(executable, 'Contents', 'MacOS', 'Chromium');
  }
  const metadata = await stat(executable).catch(() => null);
  assert(metadata?.isFile(), `Chromium 可执行文件不存在：${executable}`);
  await access(executable, fsConstants.X_OK).catch(() => {
    fail(`Chromium 不可执行：${executable}`);
  });
  return realpath(executable);
}

async function resolveThreatIndex(inputPath) {
  if (!inputPath) {
    return null;
  }
  const resolved = resolve(inputPath);
  const metadata = await stat(resolved).catch(() => null);
  assert(metadata?.isFile(), `威胁索引不是普通文件：${resolved}`);
  assert(
    metadata.size >= 36 && metadata.size <= 40 * 1024 * 1024,
    `威胁索引大小异常：${metadata.size}`,
  );
  const bytes = await readFile(resolved);
  assert(
    bytes.subarray(0, 8).toString('ascii') === 'AEGISTI1',
    `威胁索引 magic 不匹配：${resolved}`,
  );
  return {
    bytes: metadata.size,
    path: await realpath(resolved),
    sha256: createHash('sha256').update(bytes).digest('hex'),
  };
}

async function waitForLogText(logPath, expected, browserProcess, timeoutMs) {
  const deadline = performance.now() + timeoutMs;
  do {
    if (browserProcess.exitCode !== null || browserProcess.signalCode !== null) {
      fail(
        `Chromium 在等待日志信号时退出：` +
          `${browserProcess.exitCode ?? browserProcess.signalCode}`,
      );
    }
    const content = await readFile(logPath, 'utf8').catch(() => '');
    if (content.includes(expected)) {
      return;
    }
    await delay(POLL_INTERVAL_MS);
  } while (performance.now() < deadline);
  fail(`等待日志信号超时：${expected}`);
}

function parseCpuTime(value) {
  const [dayText, clockText] = value.includes('-')
    ? value.split('-', 2)
    : ['0', value];
  const fields = clockText.split(':').map(Number);
  assert(fields.every(Number.isFinite), `无法解析 CPU 时间：${value}`);
  let seconds = Number(dayText) * 24 * 60 * 60;
  let multiplier = 1;
  for (const field of fields.toReversed()) {
    seconds += field * multiplier;
    multiplier *= 60;
  }
  return seconds;
}

function processKind(pid, rootPid, command) {
  if (pid === rootPid) return 'browser';
  if (/--type=gpu-process|Helper \(GPU\)/u.test(command)) return 'gpu';
  if (/--type=renderer|Helper \(Renderer\)/u.test(command)) return 'renderer';
  return 'other';
}

async function sampleProcessTreeCpu(rootPid) {
  const {stdout} = await execFileAsync('/bin/ps', [
    '-axo',
    'pid=,ppid=,time=,command=',
  ]);
  const rows = stdout.split(/\r?\n/u).flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/u);
    return match
      ? [{
          command: match[4],
          cpuSeconds: parseCpuTime(match[3]),
          pid: Number(match[1]),
          ppid: Number(match[2]),
        }]
      : [];
  });
  const owned = new Set([rootPid]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const row of rows) {
      if (!owned.has(row.pid) && owned.has(row.ppid)) {
        owned.add(row.pid);
        changed = true;
      }
    }
  }
  return new Map(
    rows
      .filter(({pid}) => owned.has(pid))
      .map((row) => [
        row.pid,
        {...row, kind: processKind(row.pid, rootPid, row.command)},
      ]),
  );
}

async function observeProcessTreeCpu(rootPid, durationMs) {
  const before = await sampleProcessTreeCpu(rootPid);
  const started = performance.now();
  await delay(durationMs);
  const elapsedMs = performance.now() - started;
  const after = await sampleProcessTreeCpu(rootPid);
  const cpuSecondsByKind = {browser: 0, gpu: 0, other: 0, renderer: 0};
  for (const [pid, record] of after) {
    const previous = before.get(pid)?.cpuSeconds ?? 0;
    cpuSecondsByKind[record.kind] += Math.max(0, record.cpuSeconds - previous);
  }
  const percentByKind = Object.fromEntries(
    Object.entries(cpuSecondsByKind).map(([kind, seconds]) => [
      kind,
      Number(((seconds * 100_000) / elapsedMs).toFixed(2)),
    ]),
  );
  return {
    elapsedMs: Math.round(elapsedMs),
    percentByKind,
    processCountAfter: after.size,
    totalPercent: Number(
      Object.values(percentByKind)
        .reduce((sum, value) => sum + value, 0)
        .toFixed(2),
    ),
  };
}

async function startCredentialFixture() {
  const server = createHttpServer((request, response) => {
    if (request.url !== '/form') {
      response.writeHead(404, {'content-type': 'text/plain; charset=utf-8'});
      response.end('not found');
      return;
    }
    setTimeout(() => {
      response.writeHead(200, {
        'cache-control': 'no-store',
        'content-type': 'text/html; charset=utf-8',
      });
      response.end(`<!doctype html>
        <html><head><title>Account sign in</title></head>
        <body><main><h1>Sign in</h1>
          <form action="https://collector.invalid/session" method="post">
            <label>Password <input type="password" name="password"></label>
            <button type="submit">Continue</button>
          </form>
        </main></body></html>`);
    }, 1_000);
  });
  await new Promise((resolveListen, rejectListen) => {
    server.once('error', rejectListen);
    server.listen(0, '127.0.0.1', () => {
      server.off('error', rejectListen);
      resolveListen();
    });
  });
  const address = server.address();
  assert(
    address && typeof address === 'object' && address.address === '127.0.0.1',
    '凭据 fixture 未绑定 loopback',
  );
  return {
    close: () => new Promise((resolveClose) => server.close(resolveClose)),
    url: `http://127.0.0.1:${address.port}/form`,
  };
}

async function waitForDevToolsPort(profileDir, browserProcess, timeoutMs) {
  const activePortPath = join(profileDir, 'DevToolsActivePort');
  const deadline = performance.now() + timeoutMs;
  do {
    if (browserProcess.aegisSpawnError) {
      fail(`Chromium 进程启动失败：${browserProcess.aegisSpawnError.message}`);
    }
    if (browserProcess.exitCode !== null || browserProcess.signalCode !== null) {
      fail(
        `Chromium 在 DevTools 启动前退出：` +
          `${browserProcess.exitCode ?? browserProcess.signalCode}`,
      );
    }
    const content = await readFile(activePortPath, 'utf8').catch(() => '');
    const [portText] = content.trim().split(/\r?\n/u);
    const port = Number(portText);
    if (Number.isSafeInteger(port) && port > 0 && port <= 65_535) {
      return port;
    }
    await delay(POLL_INTERVAL_MS);
  } while (performance.now() < deadline);
  fail(`等待 ${activePortPath} 超时`);
}

class DevToolsEndpoint {
  constructor(port, timeoutMs) {
    this.baseUrl = `http://127.0.0.1:${port}`;
    this.port = port;
    this.timeoutMs = timeoutMs;
  }

  async fetch(path, init = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      return await fetch(`${this.baseUrl}${path}`, {
        ...init,
        cache: 'no-store',
        redirect: 'error',
        signal: controller.signal,
      });
    } catch (error) {
      fail(`请求 ${path} 失败：${error.message}`);
    } finally {
      clearTimeout(timer);
    }
  }

  async fetchJson(path, init = {}) {
    const response = await this.fetch(path, init);
    const body = await response.text();
    assert(response.ok, `请求 ${path} 返回 HTTP ${response.status}`);
    try {
      return JSON.parse(body);
    } catch {
      fail(`请求 ${path} 返回了非 JSON 内容`);
    }
  }

  async createTarget(url) {
    const descriptor = await this.fetchJson(`/json/new?${encodeURIComponent(url)}`, {
      method: 'PUT',
    });
    assert(typeof descriptor?.id === 'string', '新标签页缺少 target id');
    return descriptor.id;
  }

  async listTargets() {
    const targets = await this.fetchJson('/json/list');
    assert(Array.isArray(targets), '/json/list 未返回数组');
    return targets;
  }

  async waitForPublicTarget(targetId) {
    const deadline = performance.now() + this.timeoutMs;
    do {
      const target = (await this.listTargets()).find(({id}) => id === targetId);
      if (
        target?.url &&
        !target.url.startsWith('about:') &&
        !target.url.startsWith('chrome-error:') &&
        typeof target.webSocketDebuggerUrl === 'string'
      ) {
        return target;
      }
      await delay(POLL_INTERVAL_MS);
    } while (performance.now() < deadline);
    fail(`等待公开页面 target 超时：${targetId}`);
  }

  async waitForUrlTarget(url) {
    const deadline = performance.now() + this.timeoutMs;
    do {
      const target = (await this.listTargets()).find(
        (candidate) => candidate.url === url,
      );
      if (target?.id) {
        return target.id;
      }
      await delay(POLL_INTERVAL_MS);
    } while (performance.now() < deadline);
    fail(`等待启动页 target 超时：${url}`);
  }

}

function waitForWebSocketOpen(socket, timeoutMs) {
  return new Promise((resolveOpen, rejectOpen) => {
    const timer = setTimeout(() => {
      cleanup();
      rejectOpen(new VerificationError('等待 CDP WebSocket 超时'));
    }, timeoutMs);
    const cleanup = () => {
      clearTimeout(timer);
      socket.removeEventListener('open', handleOpen);
      socket.removeEventListener('error', handleError);
      socket.removeEventListener('close', handleClose);
    };
    const handleOpen = () => {
      cleanup();
      resolveOpen();
    };
    const handleError = () => {
      cleanup();
      rejectOpen(new VerificationError('CDP WebSocket 握手失败'));
    };
    const handleClose = () => {
      cleanup();
      rejectOpen(new VerificationError('CDP WebSocket 在握手前关闭'));
    };
    socket.addEventListener('open', handleOpen);
    socket.addEventListener('error', handleError);
    socket.addEventListener('close', handleClose);
  });
}

class CdpClient {
  constructor(socket, timeoutMs) {
    this.crashed = false;
    this.nextId = 1;
    this.pending = new Map();
    this.socket = socket;
    this.timeoutMs = timeoutMs;
    socket.addEventListener('message', (event) => this.handleMessage(event));
    socket.addEventListener('close', () => this.rejectPending('CDP 连接已关闭'));
    socket.addEventListener('error', () => this.rejectPending('CDP 连接错误'));
  }

  static async connect(url, timeoutMs) {
    const parsed = new URL(url);
    assert(parsed.hostname === '127.0.0.1', 'CDP WebSocket 不是 loopback');
    const socket = new WebSocket(url);
    await waitForWebSocketOpen(socket, timeoutMs);
    return new CdpClient(socket, timeoutMs);
  }

  async handleMessage(event) {
    const text =
      typeof event.data === 'string'
        ? event.data
        : event.data instanceof Blob
          ? await event.data.text()
          : Buffer.from(event.data).toString('utf8');
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      this.rejectPending('CDP 返回了非 JSON 消息');
      return;
    }
    if (message.method === 'Inspector.targetCrashed') {
      this.crashed = true;
    }
    if (!Number.isSafeInteger(message.id)) {
      return;
    }
    const pending = this.pending.get(message.id);
    if (!pending) {
      return;
    }
    this.pending.delete(message.id);
    clearTimeout(pending.timer);
    if (message.error) {
      pending.reject(
        new VerificationError(
          `CDP ${pending.method} 失败：${message.error.message ?? '未知错误'}`,
        ),
      );
    } else {
      pending.resolve(message.result ?? {});
    }
  }

  rejectPending(message) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new VerificationError(message));
    }
    this.pending.clear();
  }

  command(method, params = {}) {
    assert(this.socket.readyState === WebSocket.OPEN, 'CDP WebSocket 未打开');
    const id = this.nextId++;
    return new Promise((resolveCommand, rejectCommand) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectCommand(new VerificationError(`CDP ${method} 超时`));
      }, this.timeoutMs);
      this.pending.set(id, {
        method,
        reject: rejectCommand,
        resolve: resolveCommand,
        timer,
      });
      this.socket.send(JSON.stringify({id, method, params}));
    });
  }

  async snapshot(expectedText = null) {
    const serializedExpected = JSON.stringify(expectedText ?? '');
    const response = await this.command('Runtime.evaluate', {
      expression: `({
        bodyLength: document.body?.innerText?.trim().length ?? 0,
        childCount: document.body?.childElementCount ?? 0,
        expectedTextFound: ${serializedExpected}.length === 0 ||
          (document.body?.innerText?.includes(${serializedExpected}) ?? false),
        href: location.href,
        readyState: document.readyState,
        title: document.title
      })`,
      returnByValue: true,
    });
    return response.result?.value;
  }

  async close() {
    if (this.socket.readyState >= WebSocket.CLOSING) {
      return;
    }
    this.socket.close(1000, 'verification complete');
    await delay(100);
  }
}

async function waitForPageReady(
  client,
  timeoutMs,
  settleMs,
  expectedText,
  expectAegisInterstitial,
) {
  const deadline = performance.now() + timeoutMs;
  let snapshot;
  do {
    assert(!client.crashed, 'Renderer 报告 Inspector.targetCrashed');
    snapshot = await client.snapshot(expectedText);
    if (
      snapshot?.readyState === 'complete' &&
      snapshot.title?.trim() &&
      snapshot.bodyLength > 0 &&
      (expectAegisInterstitial || !snapshot.href.startsWith('chrome-error:'))
    ) {
      await delay(settleMs);
      const settled = await client.snapshot(expectedText);
      assert(!client.crashed, '页面稳定观察期内 Renderer 崩溃');
      assert(settled?.bodyLength > 0, '页面稳定观察期后正文消失');
      assert(
        settled?.expectedTextFound,
        `页面未包含预期文本：${expectedText}`,
      );
      assert(
        !expectAegisInterstitial || settled.href === 'chrome-error://chromewebdata/',
        '未进入 Aegis 安全拦截文档',
      );
      return settled;
    }
    await delay(POLL_INTERVAL_MS);
  } while (performance.now() < deadline);
  fail(
    `页面未达到可渲染状态：${JSON.stringify(snapshot ?? {state: 'unknown'})}`,
  );
}

async function listDumpFiles(root) {
  const files = [];
  async function visit(directory) {
    const entries = await readdir(directory, {withFileTypes: true}).catch(() => []);
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        await visit(path);
      } else if (entry.isFile() && entry.name.endsWith('.dmp')) {
        files.push(path);
      }
    }
  }
  await visit(root);
  return files.sort();
}

async function terminateOwnedProcess(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  const exited = new Promise((resolveExit) => child.once('exit', resolveExit));
  child.kill('SIGINT');
  await Promise.race([exited, delay(8_000)]);
  if (child.exitCode === null && child.signalCode === null) {
    child.kill('SIGTERM');
    await Promise.race([exited, delay(3_000)]);
  }
  if (child.exitCode === null && child.signalCode === null) {
    child.kill('SIGKILL');
    await Promise.race([exited, delay(2_000)]);
  }
}

function findFatalSignals(logText) {
  const pattern =
    /\bFATAL\b|CHECK failed|DCHECK failed|Received signal|GPU process exited unexpectedly|Aw, Snap/iu;
  return logText.split(/\r?\n/u).filter((line) => pattern.test(line));
}

function isTransientInterstitialConnectionError(error) {
  const message = error instanceof Error ? error.message : String(error);
  return /CDP (?:WebSocket|连接)|WebSocket/u.test(message);
}

function normalizeHost(value) {
  const text = value.trim();
  if (!text || text.includes(' ')) {
    return null;
  }
  try {
    const parsed = new URL(text);
    if (['http:', 'https:', 'ws:', 'wss:'].includes(parsed.protocol)) {
      return parsed.hostname.toLowerCase();
    }
  } catch {
    // 继续尝试 host 或 host:port 形式。
  }
  const bracketed = text.match(/^\[([^\]]+)\](?::\d+)?$/);
  if (bracketed) {
    return bracketed[1].toLowerCase();
  }
  const hostPort = text.match(/^([a-z0-9.-]+)(?::\d+)?$/iu);
  if (!hostPort || (!hostPort[1].includes('.') && hostPort[1] !== 'localhost')) {
    return null;
  }
  return hostPort[1].toLowerCase();
}

async function summarizeNetLog(path, visitedUrls) {
  const raw = await readFile(path).catch(() => null);
  assert(raw, 'NetLog 未生成');
  let netLog;
  try {
    netLog = JSON.parse(raw.toString('utf8'));
  } catch {
    fail('NetLog 不是完整 JSON；Chromium 可能未正常刷新日志');
  }
  assert(Array.isArray(netLog.events), 'NetLog 缺少 events 数组');
  const networkEventCounts = new Map();
  const requestCounts = new Map();
  const hostKeys = /(?:^|_)(?:host|hostname|host_and_port|origin|url)$/iu;
  const add = (counts, value) => {
    const host = normalizeHost(value);
    if (host) {
      counts.set(host, (counts.get(host) ?? 0) + 1);
    }
  };
  const visit = (value, key = '') => {
    if (typeof value === 'string') {
      if (/^(?:https?|wss?):\/\//iu.test(value) || hostKeys.test(key)) {
        add(networkEventCounts, value);
      }
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) {
        visit(item, key);
      }
      return;
    }
    if (value && typeof value === 'object') {
      for (const [childKey, childValue] of Object.entries(value)) {
        visit(childValue, childKey);
      }
    }
  };
  for (const event of netLog.events) {
    visit(event?.params ?? {});
    if (
      event?.type === netLog.constants?.logEventTypes?.REQUEST_ALIVE &&
      event?.phase === netLog.constants?.logEventPhase?.PHASE_BEGIN &&
      typeof event?.params?.url === 'string'
    ) {
      add(requestCounts, event.params.url);
    }
  }

  const firstPartyHosts = new Set(visitedUrls.map((url) => new URL(url).hostname));
  const summarize = (counts) => [...counts.entries()]
    .map(([host, occurrences]) => ({host, occurrences}))
    .sort((left, right) => left.host.localeCompare(right.host));
  const networkEventHosts = summarize(networkEventCounts);
  const urlRequestHosts = summarize(requestCounts);
  return {
    captureMode: 'Default',
    firstPartyRequestHosts: urlRequestHosts.filter(({host}) => firstPartyHosts.has(host)),
    netLogSha256: createHash('sha256').update(raw).digest('hex'),
    networkEventHosts,
    otherRequestHosts: urlRequestHosts.filter(
      ({host}) => !firstPartyHosts.has(host) && host !== '127.0.0.1' && host !== 'localhost',
    ),
    rawBytes: raw.length,
    urlRequestHosts,
  };
}

async function writeReport(path, report) {
  if (!path) {
    return;
  }
  const resolved = resolve(path);
  await mkdir(dirname(resolved), {recursive: true});
  await writeFile(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  process.stdout.write(`证据：${resolved}\n`);
}

async function runVerification(options, chromiumExecutable) {
  const startedAt = new Date().toISOString();
  const profileDir = await mkdtemp(join(tmpdir(), 'aegis-multisite-'));
  const credentialFixture = options.credentialFixture
    ? await startCredentialFixture()
    : null;
  if (credentialFixture) {
    options.urls = [credentialFixture.url];
  }
  const logPath = join(profileDir, 'chromium.log');
  const netLogPath = join(profileDir, 'netlog.json');
  const globalCrashpad = join(
    homedir(),
    'Library',
    'Application Support',
    'Chromium',
    'Crashpad',
    'pending',
  );
  const dumpsBefore = new Set(await listDumpFiles(globalCrashpad));
  const logFd = openSync(logPath, 'w');
  if (options.threatIndex) {
    const threatDir = join(profileDir, 'Default', 'AegisThreatFeeds');
    const threatFile = join(threatDir, 'threat-index.bin');
    await mkdir(threatDir, {recursive: true, mode: 0o700});
    await copyFile(options.threatIndex.path, threatFile);
    await chmod(threatFile, 0o600);
  }
  const chromiumArgs = [
    `--user-data-dir=${profileDir}`,
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=0',
    '--no-first-run',
    '--no-default-browser-check',
    '--use-mock-keychain',
    '--enable-logging=stderr',
    '--v=0',
    '--window-size=1280,900',
  ];
  if (options.headless) {
    chromiumArgs.push('--headless=new');
  }
  if (options.auditOutbound) {
    chromiumArgs.push(
      `--log-net-log=${netLogPath}`,
      '--net-log-capture-mode=Default',
    );
  }
  if (options.backgroundQuiet) {
    chromiumArgs.push(
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-default-apps',
      '--disable-domain-reliability',
      '--disable-sync',
      '--metrics-recording-only',
      '--no-pings',
    );
  }
  const disabledFeatures = FEATURE_MODES.get(options.featureMode);
  if (disabledFeatures) {
    chromiumArgs.push(`--disable-features=${disabledFeatures}`);
  }
  chromiumArgs.push(credentialFixture?.url ?? 'about:blank');

  const results = [];
  let browserProcess;
  let endpoint;
  let failure;
  try {
    browserProcess = spawn(chromiumExecutable, chromiumArgs, {
      detached: false,
      stdio: ['ignore', logFd, logFd],
    });
    browserProcess.once('error', (error) => {
      browserProcess.aegisSpawnError = error;
    });
    const port = await waitForDevToolsPort(
      profileDir,
      browserProcess,
      options.timeoutMs,
    );
    endpoint = new DevToolsEndpoint(port, options.timeoutMs);
    if (options.threatIndex) {
      await waitForLogText(
        logPath,
        'Aegis: loaded threat reputation index',
        browserProcess,
        options.timeoutMs,
      );
      process.stdout.write(
        `威胁索引已加载：${options.threatIndex.bytes} bytes\n`,
      );
    }

    if (options.startupOnly) {
      const siteStarted = performance.now();
      await delay(options.observeMs);
      assert(
        browserProcess.exitCode === null && browserProcess.signalCode === null,
        'Browser 主进程在启动观察期间退出',
      );
      results.push({
        elapsedMs: Math.round(performance.now() - siteStarted),
        passed: true,
        scenario: 'startup-only',
      });
      process.stdout.write(`[通过] 启动观察 ${options.observeMs} ms\n`);
    }

    for (const url of options.urls) {
      const targetId = credentialFixture
        ? await endpoint.waitForUrlTarget(url)
        : await endpoint.createTarget(url);
      let client;
      const siteStarted = performance.now();
      try {
        const connectionDeadline = performance.now() + options.timeoutMs;
        let snapshot;
        do {
          const target = await endpoint.waitForPublicTarget(targetId);
          try {
            client = await CdpClient.connect(
              target.webSocketDebuggerUrl,
              Math.max(1_000, connectionDeadline - performance.now()),
            );
            snapshot = await waitForPageReady(
              client,
              Math.max(1_000, connectionDeadline - performance.now()),
              options.settleMs,
              options.expectText,
              options.expectAegisInterstitial,
            );
            break;
          } catch (error) {
            await client?.close().catch(() => {});
            client = null;
            if (
              !options.expectAegisInterstitial ||
              !isTransientInterstitialConnectionError(error) ||
              performance.now() >= connectionDeadline
            ) {
              throw error;
            }
            await delay(POLL_INTERVAL_MS);
          }
        } while (performance.now() < connectionDeadline);
        assert(snapshot, '未取得稳定页面快照');
        const cpu = options.cpuObserveMs
          ? await observeProcessTreeCpu(browserProcess.pid, options.cpuObserveMs)
          : null;
        assert(
          browserProcess.exitCode === null && browserProcess.signalCode === null,
          'Browser 主进程在站点验证期间退出',
        );
        results.push({
          bodyLength: snapshot.bodyLength,
          cpu,
          elapsedMs: Math.round(performance.now() - siteStarted),
          finalUrl: snapshot.href,
          passed: true,
          title: snapshot.title,
          url,
        });
        process.stdout.write(
          `[通过] ${url} → ${snapshot.title} ` +
            `(${Math.round(performance.now() - siteStarted)} ms)\n`,
        );
        if (cpu) {
          process.stdout.write(
            `CPU：${cpu.totalPercent}% 单核等价` +
              ` (Browser ${cpu.percentByKind.browser}%, ` +
              `Renderer ${cpu.percentByKind.renderer}%, ` +
              `GPU ${cpu.percentByKind.gpu}%)\n`,
          );
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        results.push({
          elapsedMs: Math.round(performance.now() - siteStarted),
          message,
          passed: false,
          url,
        });
        throw error;
      } finally {
        await client?.close().catch(() => {});
      }
    }
  } catch (error) {
    failure = error instanceof Error ? error : new VerificationError(String(error));
  } finally {
    closeSync(logFd);
  }

  if (
    !failure &&
    browserProcess &&
    (browserProcess.exitCode !== null || browserProcess.signalCode !== null)
  ) {
    failure = new VerificationError(
      `Browser 主进程在受控退出前结束：` +
        `${browserProcess.exitCode ?? browserProcess.signalCode}`,
    );
  }
  await terminateOwnedProcess(browserProcess);
  await credentialFixture?.close();
  const profileDumps = await listDumpFiles(profileDir);
  const dumpsAfter = await listDumpFiles(globalCrashpad);
  const newGlobalDumps = dumpsAfter.filter((path) => !dumpsBefore.has(path));
  const logText = await readFile(logPath, 'utf8').catch(() => '');
  const fatalSignals = findFatalSignals(logText);
  if (!failure && profileDumps.length > 0) {
    failure = new VerificationError(`临时 Profile 新增 ${profileDumps.length} 个 dump`);
  }
  if (!failure && newGlobalDumps.length > 0) {
    failure = new VerificationError(`全局 Crashpad 新增 ${newGlobalDumps.length} 个 dump`);
  }
  if (!failure && fatalSignals.length > 0) {
    failure = new VerificationError(`日志发现 ${fatalSignals.length} 条致命信号`);
  }

  let outboundAudit = null;
  if (options.auditOutbound) {
    try {
      outboundAudit = await summarizeNetLog(netLogPath, options.urls);
      process.stdout.write(
        `出站观察：${outboundAudit.urlRequestHosts.length} 个 URL 请求主机，` +
          `${outboundAudit.networkEventHosts.length} 个网络事件主机。\n`,
      );
    } catch (error) {
      if (!failure) {
        failure = error instanceof Error ? error : new VerificationError(String(error));
      }
    }
  }
  const report = {
    browser: chromiumExecutable,
    backgroundQuiet: options.backgroundQuiet,
    credentialFixture: options.credentialFixture,
    browserExitCode: browserProcess?.exitCode ?? null,
    browserSignal: browserProcess?.signalCode ?? null,
    fatalSignals,
    featureMode: options.featureMode,
    expectAegisInterstitial: options.expectAegisInterstitial,
    finishedAt: new Date().toISOString(),
    newGlobalDumps,
    outboundAudit,
    passed: !failure,
    profileDir,
    profileDumps,
    results,
    startupOnly: options.startupOnly,
    startedAt,
    threatIndex: options.threatIndex,
  };
  await writeReport(options.report, report);

  if (!failure && !options.keepProfile) {
    const expectedPrefix = join(tmpdir(), 'aegis-multisite-');
    assert(profileDir.startsWith(expectedPrefix), '拒绝清理非预期 Profile 路径');
    await rm(profileDir, {force: true, recursive: true});
  } else {
    process.stdout.write(`保留 Profile：${profileDir}\n`);
  }
  if (failure) {
    throw failure;
  }
  process.stdout.write(
    `${options.startupOnly ? '启动观察门' : '多站点门'}通过：` +
      `${results.length}/${results.length}，` +
      `feature mode=${options.featureMode}，0 dump，0 FATAL。\n`,
  );
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printUsage();
    return;
  }
  assert(typeof WebSocket === 'function', '当前 Node 不提供原生 WebSocket');
  const chromiumExecutable = await resolveChromiumExecutable(options.chromium);
  options.threatIndex = await resolveThreatIndex(options.threatIndex);
  if (options.dryRun) {
    process.stdout.write(
      `dry-run 通过：${chromiumExecutable}\n` +
        `feature mode：${options.featureMode}\n` +
        `威胁索引：${options.threatIndex?.path ?? '未指定'}\n` +
        `站点：${options.urls.join(', ')}\n`,
    );
    return;
  }
  await runVerification(options, chromiumExecutable);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`多站点门失败：${message}\n`);
  process.exitCode = 1;
});
