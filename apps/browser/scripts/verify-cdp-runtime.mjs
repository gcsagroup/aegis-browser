#!/usr/bin/env node

import {spawn} from 'node:child_process';
import {randomBytes, randomUUID} from 'node:crypto';
import {
  closeSync,
  constants as fsConstants,
  openSync,
  readFileSync,
} from 'node:fs';
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
} from 'node:fs/promises';
import {createServer as createHttpServer} from 'node:http';
import {connect as connectTcp} from 'node:net';
import {homedir, tmpdir} from 'node:os';
import {basename, dirname, join, resolve} from 'node:path';
import process from 'node:process';
import {fileURLToPath} from 'node:url';

const BROWSER_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CHROMIUM_ROOT_MARKER = join(BROWSER_ROOT, '.chromium-root');

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
    // The marker is optional; match scripts/common.sh when it is absent.
  }
  return join(homedir(), 'Projects', 'GCSA-aegis-chromium');
}

const DEFAULT_DEV_OUT = process.env.OUT_DIR?.trim()
  ? resolve(process.env.OUT_DIR.trim())
  : join(resolveDefaultChromiumRoot(), 'src', 'out', 'AegisLocalDev');
const DEFAULT_CHROMIUM = join(DEFAULT_DEV_OUT, 'Chromium.app');
const DEFAULT_TIMEOUT_MS = 30_000;
const POLL_INTERVAL_MS = 50;

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

function deferred() {
  let resolvePromise;
  let rejectPromise;
  const promise = new Promise((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  return {promise, resolve: resolvePromise, reject: rejectPromise};
}

async function withTimeout(promise, timeoutMs, description) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new VerificationError(`${description}超时`)),
          timeoutMs,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function printUsage() {
  process.stdout.write(`用法：
  node apps/browser/scripts/verify-cdp-runtime.mjs [选项]

选项：
  --chromium PATH   Chromium.app 或 Chromium 可执行文件路径
                    默认：${DEFAULT_CHROMIUM}
  --timeout-ms N    单步超时，默认 ${DEFAULT_TIMEOUT_MS}
  --headed          使用可见窗口；默认使用 --headless=new
  --keep-profile    成功后也保留临时配置和 Chromium 日志
  --dry-run         只校验参数和 Chromium 可执行文件，不启动进程
  --help            显示帮助

也可用 AEGIS_CHROMIUM_BIN 覆盖默认 Chromium 路径。
脚本控制端和 fixture 只监听、访问 127.0.0.1；被启动的 Chromium 仍可能尝试其他出站，须另行审计。
`);
}

function parseArgs(argv) {
  const options = {
    chromium: process.env.AEGIS_CHROMIUM_BIN?.trim() || DEFAULT_CHROMIUM,
    dryRun: false,
    headed: false,
    help: false,
    keepProfile: false,
    timeoutMs: DEFAULT_TIMEOUT_MS,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--chromium') {
      const value = argv[++index];
      assert(value, '--chromium 缺少路径');
      options.chromium = value;
    } else if (argument === '--timeout-ms') {
      const value = Number(argv[++index]);
      assert(
        Number.isSafeInteger(value) && value >= 1_000,
        '--timeout-ms 必须是至少 1000 的整数',
      );
      options.timeoutMs = value;
    } else if (argument === '--headed') {
      options.headed = true;
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

class LocalFixtureServer {
  constructor(timeoutMs) {
    this.timeoutMs = timeoutMs;
    this.controlledResponses = new Map();
    this.server = createHttpServer((request, response) => {
      this.handleRequest(request, response);
    });
  }

  async start() {
    await new Promise((resolveListen, rejectListen) => {
      this.server.once('error', rejectListen);
      this.server.listen(0, '127.0.0.1', () => {
        this.server.off('error', rejectListen);
        resolveListen();
      });
    });
    const address = this.server.address();
    assert(
      address && typeof address === 'object' && address.address === '127.0.0.1',
      '本地验证服务未绑定到 127.0.0.1',
    );
    this.origin = `http://127.0.0.1:${address.port}`;
  }

  handleRequest(request, response) {
    const requestUrl = new URL(request.url ?? '/', this.origin);
    if (requestUrl.pathname.startsWith('/public/')) {
      response.writeHead(200, {
        'cache-control': 'no-store',
        'content-type': 'text/html; charset=utf-8',
      });
      response.end('<!doctype html><title>Aegis CDP public fixture</title>');
      return;
    }

    const controlled = this.controlledResponses.get(requestUrl.pathname);
    if (controlled) {
      if (controlled.response) {
        response.writeHead(409, {'content-type': 'text/plain; charset=utf-8'});
        response.end('duplicate controlled request');
        return;
      }
      controlled.response = response;
      controlled.requestSeen.resolve();
      request.once('aborted', () => {
        if (!response.writableEnded) {
          controlled.requestClosed = true;
        }
      });
      response.once('close', () => {
        if (!response.writableEnded) {
          controlled.requestClosed = true;
        }
      });
      return;
    }

    response.writeHead(404, {'content-type': 'text/plain; charset=utf-8'});
    response.end('not found');
  }

  createControlledUrl(label) {
    const pathname = `/controlled/${encodeURIComponent(label)}-${randomUUID()}`;
    const record = {
      pathname,
      requestClosed: false,
      requestSeen: deferred(),
      response: null,
    };
    this.controlledResponses.set(pathname, record);
    return {
      release: (body) => this.release(record, body),
      url: `${this.origin}${pathname}`,
      waitForRequest: () =>
        withTimeout(
          record.requestSeen.promise,
          this.timeoutMs,
          `等待受控页面请求 ${pathname}`,
        ),
    };
  }

  release(record, body) {
    assert(record.response, `受控页面尚未请求：${record.pathname}`);
    assert(!record.requestClosed, `受控页面请求已关闭：${record.pathname}`);
    assert(!record.response.writableEnded, `受控页面已响应：${record.pathname}`);
    record.response.writeHead(200, {
      'cache-control': 'no-store',
      'content-type': 'text/html; charset=utf-8',
    });
    record.response.end(body);
  }

  async close() {
    for (const record of this.controlledResponses.values()) {
      if (record.response && !record.response.writableEnded) {
        record.response.writeHead(503, {
          'content-type': 'text/plain; charset=utf-8',
        });
        record.response.end('verification finished');
      }
    }
    this.server.closeAllConnections?.();
    if (!this.server.listening) {
      return;
    }
    await new Promise((resolveClose) => this.server.close(resolveClose));
  }
}

class DevToolsEndpoint {
  constructor(port, timeoutMs) {
    this.port = port;
    this.timeoutMs = timeoutMs;
    this.baseUrl = `http://127.0.0.1:${port}`;
  }

  async fetchJson(path, init = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let response;
    let body;
    try {
      response = await fetch(`${this.baseUrl}${path}`, {
        ...init,
        cache: 'no-store',
        redirect: 'error',
        signal: controller.signal,
      });
      body = await response.text();
    } catch (error) {
      fail(`请求 ${path} 失败：${error.message}`);
    } finally {
      clearTimeout(timer);
    }
    if (!response.ok) {
      fail(`请求 ${path} 返回 HTTP ${response.status}：${body.slice(0, 300)}`);
    }
    try {
      return JSON.parse(body);
    } catch {
      fail(`请求 ${path} 返回了非 JSON 内容`);
    }
  }

  async newTarget(url) {
    const query = url ? `?${encodeURIComponent(url)}` : '';
    const descriptor = await this.fetchJson(`/json/new${query}`, {
      method: 'PUT',
    });
    assert(
      descriptor && typeof descriptor === 'object' && !Array.isArray(descriptor),
      '/json/new 未返回 target 描述对象',
    );
    assert(typeof descriptor.id === 'string' && descriptor.id, 'target id 缺失');
    assert(
      typeof descriptor.webSocketDebuggerUrl === 'string',
      'target WebSocket URL 缺失',
    );
    const socketUrl = new URL(descriptor.webSocketDebuggerUrl);
    assert(socketUrl.protocol === 'ws:', 'target WebSocket 不是 ws 协议');
    assert(socketUrl.hostname === '127.0.0.1', 'target WebSocket 不是本机地址');
    assert(Number(socketUrl.port) === this.port, 'target WebSocket 端口不匹配');
    assert(
      socketUrl.pathname.endsWith(`/${descriptor.id}`),
      'target WebSocket 路径和 id 不匹配',
    );
    return descriptor;
  }

  async listTargets() {
    const targets = await this.fetchJson('/json/list');
    assert(Array.isArray(targets), '/json/list 未返回数组');
    return targets;
  }

  async waitForTarget(predicate, description) {
    const deadline = performance.now() + this.timeoutMs;
    do {
      const target = (await this.listTargets()).find(predicate);
      if (target) {
        return target;
      }
      await delay(POLL_INTERVAL_MS);
    } while (performance.now() < deadline);
    fail(`${description}超时`);
  }

  async waitForTargetAbsent(targetId, description) {
    const deadline = performance.now() + this.timeoutMs;
    do {
      const target = (await this.listTargets()).find(({id}) => id === targetId);
      if (!target) {
        return;
      }
      await delay(POLL_INTERVAL_MS);
    } while (performance.now() < deadline);
    fail(`${description}超时`);
  }
}

function waitForWebSocketOpen(socket, timeoutMs) {
  return withTimeout(
    new Promise((resolveOpen, rejectOpen) => {
      const cleanup = () => {
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
        rejectOpen(new VerificationError('WebSocket 握手失败'));
      };
      const handleClose = () => {
        cleanup();
        rejectOpen(new VerificationError('WebSocket 在握手前关闭'));
      };
      socket.addEventListener('open', handleOpen);
      socket.addEventListener('error', handleError);
      socket.addEventListener('close', handleClose);
    }),
    timeoutMs,
    '等待 WebSocket 握手',
  );
}

class CdpClient {
  constructor(socket, timeoutMs) {
    this.socket = socket;
    this.timeoutMs = timeoutMs;
    this.nextId = 1;
    this.pending = new Map();
    socket.addEventListener('message', (event) => this.handleMessage(event));
    socket.addEventListener('close', () => this.rejectPending('CDP 连接已关闭'));
    socket.addEventListener('error', () => this.rejectPending('CDP 连接错误'));
  }

  static async connect(url, timeoutMs) {
    const socket = new WebSocket(url);
    try {
      await waitForWebSocketOpen(socket, timeoutMs);
    } catch (error) {
      socket.close();
      throw error;
    }
    return new CdpClient(socket, timeoutMs);
  }

  async handleMessage(event) {
    let text;
    if (typeof event.data === 'string') {
      text = event.data;
    } else if (event.data instanceof Blob) {
      text = await event.data.text();
    } else {
      text = Buffer.from(event.data).toString('utf8');
    }

    let message;
    try {
      message = JSON.parse(text);
    } catch {
      this.rejectPending('CDP 返回了非 JSON 消息');
      return;
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
      return;
    }
    pending.resolve(message.result ?? {});
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

  async evaluateMarker(expectedHref) {
    const result = await this.command('Runtime.evaluate', {
      expression:
        "({marker: 'gcsa-aegis-cdp-runtime', href: globalThis.location.href})",
      returnByValue: true,
    });
    const value = result.result?.value;
    assert(value?.marker === 'gcsa-aegis-cdp-runtime', 'Runtime.evaluate 标记不匹配');
    if (expectedHref) {
      assert(value.href === expectedHref, `页面 URL 不匹配：${value.href}`);
    }
    return value;
  }

  async close() {
    if (
      this.socket.readyState === WebSocket.CLOSED ||
      this.socket.readyState === WebSocket.CLOSING
    ) {
      return;
    }
    const closed = new Promise((resolveClose) => {
      this.socket.addEventListener('close', resolveClose, {once: true});
    });
    this.socket.close(1000, 'verification complete');
    await Promise.race([closed, delay(1_000)]);
  }
}

async function expectWebSocketRejected(url, timeoutMs, description) {
  const socket = new WebSocket(url);
  await withTimeout(
    new Promise((resolveRejected, rejectRejected) => {
      let opened = false;
      socket.addEventListener(
        'open',
        () => {
          opened = true;
          socket.close();
          rejectRejected(new VerificationError(`${description}却成功建立连接`));
        },
        {once: true},
      );
      socket.addEventListener(
        'error',
        () => {
          if (!opened) {
            resolveRejected();
          }
        },
        {once: true},
      );
      socket.addEventListener(
        'close',
        () => {
          if (!opened) {
            resolveRejected();
          }
        },
        {once: true},
      );
    }),
    timeoutMs,
    description,
  );
}

async function sendMalformedWebSocketHandshake(url, timeoutMs) {
  const socketUrl = new URL(url);
  assert(socketUrl.hostname === '127.0.0.1', '畸形握手目标不是本机地址');
  const socket = connectTcp({
    host: '127.0.0.1',
    port: Number(socketUrl.port),
  });
  const response = await withTimeout(
    new Promise((resolveResponse, rejectResponse) => {
      let received = '';
      socket.setEncoding('utf8');
      socket.once('connect', () => {
        const key = randomBytes(16).toString('base64');
        socket.write(
          `GET ${socketUrl.pathname}${socketUrl.search} HTTP/1.1\r\n` +
            `Host: 127.0.0.1:${socketUrl.port}\r\n` +
            'Connection: Upgrade\r\n' +
            'Upgrade: websocket\r\n' +
            'Sec-WebSocket-Version: 12\r\n' +
            `Sec-WebSocket-Key: ${key}\r\n` +
            '\r\n',
        );
      });
      socket.on('data', (chunk) => {
        received += chunk;
        if (received.includes('\r\n\r\n')) {
          resolveResponse(received);
        }
      });
      socket.once('error', rejectResponse);
      socket.once('end', () => resolveResponse(received));
    }),
    timeoutMs,
    '等待畸形 WebSocket 握手响应',
  ).finally(() => socket.destroy());
  assert(
    /^HTTP\/1\.1 500\b/u.test(response),
    `畸形握手未返回预期的 HTTP 500：${response.split(/\r?\n/u)[0] || '空响应'}`,
  );
}

async function waitForDevToolsPort(profileDir, browserProcess, timeoutMs) {
  const activePortPath = join(profileDir, 'DevToolsActivePort');
  const deadline = performance.now() + timeoutMs;
  do {
    if (browserProcess.exitCode !== null) {
      fail(`Chromium 在 DevTools 启动前退出，退出码 ${browserProcess.exitCode}`);
    }
    const content = await readFile(activePortPath, 'utf8').catch(() => '');
    const [portText, browserPath] = content.trim().split(/\r?\n/u);
    const port = Number(portText);
    if (
      Number.isSafeInteger(port) &&
      port > 0 &&
      port <= 65_535 &&
      browserPath?.startsWith('/devtools/browser/')
    ) {
      return {browserPath, port};
    }
    await delay(POLL_INTERVAL_MS);
  } while (performance.now() < deadline);
  fail(`等待 ${activePortPath} 超时`);
}

async function terminateProcess(child) {
  if (!child || child.exitCode !== null) {
    return;
  }
  const exited = new Promise((resolveExit) => child.once('exit', resolveExit));
  child.kill('SIGTERM');
  await Promise.race([exited, delay(5_000)]);
  if (child.exitCode === null) {
    child.kill('SIGKILL');
    await Promise.race([exited, delay(2_000)]);
  }
}

async function runStep(results, name, operation) {
  const startedAt = performance.now();
  try {
    await operation();
    results.push({name, passed: true});
    process.stdout.write(
      `[通过] ${name} (${Math.round(performance.now() - startedAt)} ms)\n`,
    );
    return true;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    results.push({message, name, passed: false});
    process.stderr.write(
      `[失败] ${name} (${Math.round(performance.now() - startedAt)} ms)：` +
        `${message}\n`,
    );
    return false;
  }
}

async function verifyBlankGrantIsSingleUse(endpoint, timeoutMs) {
  const target = await endpoint.newTarget();
  assert(target.url === 'about:blank', `/json/new 默认 URL 异常：${target.url}`);
  const firstClient = await CdpClient.connect(target.webSocketDebuggerUrl, timeoutMs);
  try {
    await firstClient.evaluateMarker('about:blank');
    await expectWebSocketRejected(
      target.webSocketDebuggerUrl,
      timeoutMs,
      '同一空白文档的第二次 WebSocket 复用应被拒绝',
    );
  } finally {
    await firstClient.close();
  }
}

async function verifyMalformedHandshakeConsumesGrant(endpoint, timeoutMs) {
  const target = await endpoint.newTarget();
  await sendMalformedWebSocketHandshake(target.webSocketDebuggerUrl, timeoutMs);
  await expectWebSocketRejected(
    target.webSocketDebuggerUrl,
    timeoutMs,
    '畸形握手后的空白文档授权应已消耗',
  );
}

async function verifyPendingAndPublicTargets(endpoint, fixture, timeoutMs) {
  const controlled = fixture.createControlledUrl('pending-public');
  const target = await endpoint.newTarget(controlled.url);
  await controlled.waitForRequest();
  const pendingClient = await CdpClient.connect(
    target.webSocketDebuggerUrl,
    timeoutMs,
  );
  try {
    await pendingClient.evaluateMarker('about:blank');
  } finally {
    await pendingClient.close();
  }

  controlled.release(
    '<!doctype html><title>Aegis pending public fixture</title>',
  );
  await endpoint.waitForTarget(
    ({id, url}) => id === target.id && url === controlled.url,
    '等待 pending public 页面提交',
  );

  const firstPublicClient = await CdpClient.connect(
    target.webSocketDebuggerUrl,
    timeoutMs,
  );
  const secondPublicClient = await CdpClient.connect(
    target.webSocketDebuggerUrl,
    timeoutMs,
  );
  try {
    await Promise.all([
      firstPublicClient.evaluateMarker(controlled.url),
      secondPublicClient.evaluateMarker(controlled.url),
    ]);
  } finally {
    await Promise.all([firstPublicClient.close(), secondPublicClient.close()]);
  }
}

async function provePendingInitialGrantUsable(
  endpoint,
  fixture,
  timeoutMs,
  label,
) {
  const controlled = fixture.createControlledUrl(label);
  const target = await endpoint.newTarget(controlled.url);
  await controlled.waitForRequest();
  const client = await CdpClient.connect(target.webSocketDebuggerUrl, timeoutMs);
  try {
    await client.evaluateMarker('about:blank');
  } finally {
    await client.close();
    controlled.release(
      '<!doctype html><title>Aegis pending grant control</title>',
    );
  }
}

async function verifyCrossDocumentInvalidatesGrant(endpoint, fixture, timeoutMs) {
  // 先用独立 target 证明当前构建确实能使用 initial-document grant，避免
  // “所有连接本来就被拒绝”让后面的旧授权拒绝产生假阳性。
  await provePendingInitialGrantUsable(
    endpoint,
    fixture,
    timeoutMs,
    'cross-document-control',
  );

  const controlled = fixture.createControlledUrl('cross-document');
  const target = await endpoint.newTarget(controlled.url);
  await controlled.waitForRequest();
  controlled.release(`<!doctype html>
    <title>Aegis cross-document fixture</title>
    <script>setTimeout(() => location.replace('about:blank'), 2000)</script>`);

  await endpoint.waitForTarget(
    ({id, url}) => id === target.id && url === controlled.url,
    '等待跨文档用例提交公开页面',
  );
  await endpoint.waitForTargetAbsent(
    target.id,
    '等待跨文档用例导航到不可枚举的 about:blank',
  );
  await expectWebSocketRejected(
    target.webSocketDebuggerUrl,
    timeoutMs,
    '跨文档后的旧初始文档授权应失效',
  );
}

async function runVerification(options, chromiumExecutable) {
  const tempRoot = await mkdtemp(join(tmpdir(), 'gcsa-aegis-cdp-runtime-'));
  const profileDir = join(tempRoot, 'profile');
  const logPath = join(tempRoot, 'chromium.log');
  await mkdir(profileDir, {mode: 0o700});

  const fixture = new LocalFixtureServer(options.timeoutMs);
  let browserProcess;
  let succeeded = false;
  try {
    await fixture.start();
    const logFd = openSync(logPath, 'a', 0o600);
    const chromiumArgs = [
      `--user-data-dir=${profileDir}`,
      '--remote-debugging-address=127.0.0.1',
      '--remote-debugging-port=0',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-default-apps',
      '--disable-domain-reliability',
      '--disable-sync',
      '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
      '--metrics-recording-only',
      '--no-pings',
      // Chromium 的 macOS 测试启动器也使用 mock keychain，避免全新临时
      // profile 因系统权限弹窗阻塞。该参数只属于验证器，不进入产品配置。
      ...(process.platform === 'darwin' ? ['--use-mock-keychain'] : []),
      ...(options.headed ? [] : ['--headless=new']),
      'about:blank',
    ];
    try {
      browserProcess = spawn(chromiumExecutable, chromiumArgs, {
        env: {...process.env},
        stdio: ['ignore', logFd, logFd],
      });
    } finally {
      closeSync(logFd);
    }
    browserProcess.once('error', (error) => {
      process.stderr.write(`Chromium 进程错误：${error.message}\n`);
    });

    const {port} = await waitForDevToolsPort(
      profileDir,
      browserProcess,
      options.timeoutMs,
    );
    const endpoint = new DevToolsEndpoint(port, options.timeoutMs);
    await endpoint.fetchJson('/json/version');
    const results = [];

    process.stdout.write(`Chromium：${chromiumExecutable}\n`);
    process.stdout.write(`CDP：127.0.0.1:${port}\n`);
    if (process.platform === 'darwin') {
      process.stdout.write('测试隔离：使用 mock Keychain，不代表真实签名身份门禁\n');
    }
    if (!(await runStep(
      results,
      '默认 /json/new 首次连接成功，第二次复用失败',
      () => verifyBlankGrantIsSingleUse(endpoint, options.timeoutMs),
    ))) {
      fail('首个 CDP 场景失败；为避免共享异常进程产生级联误报，后续场景跳过');
    }
    if (!(await runStep(
      results,
      '畸形 WebSocket 握手消耗一次性授权',
      () => verifyMalformedHandshakeConsumesGrant(endpoint, options.timeoutMs),
    ))) {
      fail('第二个 CDP 场景失败；为避免共享异常进程产生级联误报，后续场景跳过');
    }
    if (!(await runStep(
      results,
      'pending public 首连成功，公开页面允许普通并发连接',
      () =>
        verifyPendingAndPublicTargets(
          endpoint,
          fixture,
          options.timeoutMs,
        ),
    ))) {
      fail('第三个 CDP 场景失败；为避免共享异常进程产生级联误报，后续场景跳过');
    }
    if (!(await runStep(
      results,
      '跨文档导航使旧初始文档授权失效',
      () =>
        verifyCrossDocumentInvalidatesGrant(
          endpoint,
          fixture,
          options.timeoutMs,
        ),
    ))) {
      fail('第四个 CDP 场景失败');
    }
    const failedResults = results.filter(({passed}) => !passed);
    if (failedResults.length > 0) {
      fail(`${failedResults.length}/${results.length} 个真实 CDP 场景失败`);
    }
    succeeded = true;
    process.stdout.write(
      `结论：${results.length}/${results.length} 个真实 Chromium CDP 场景通过，` +
        '一次性精确文档授权有效。\n',
    );
  } finally {
    await fixture.close();
    await terminateProcess(browserProcess);
    if (succeeded && !options.keepProfile) {
      await rm(tempRoot, {force: true, recursive: true});
    } else {
      process.stderr.write(`保留运行证据：${tempRoot}\n`);
    }
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printUsage();
    return;
  }
  assert(typeof WebSocket === 'function', '当前 Node 不提供原生 WebSocket');
  const chromiumExecutable = await resolveChromiumExecutable(options.chromium);
  if (options.dryRun) {
    process.stdout.write(`dry-run 通过：${chromiumExecutable}\n`);
    return;
  }
  await runVerification(options, chromiumExecutable);
}

main().catch((error) => {
  process.stderr.write(`验证失败：${error.message}\n`);
  process.exitCode = 1;
});
