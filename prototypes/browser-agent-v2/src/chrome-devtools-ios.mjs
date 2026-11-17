import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, open, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { McpServer, StdioServerTransport } from 'chrome-devtools-mcp/out/Default/gen/src/third_party/index.js';
import { z } from 'zod';

const device = process.env.AEGIS_IOS_SIMULATOR_ID;
const fixture = new URL(process.env.AEGIS_IOS_DEVTOOLS_ORIGIN ?? 'http://127.0.0.1');
if (!device || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(device)) {
  throw new Error('请用 AEGIS_IOS_SIMULATOR_ID 指定已启动的验收模拟器');
}
if (fixture.protocol !== 'http:' || fixture.hostname !== '127.0.0.1' || !fixture.port ||
    fixture.username || fixture.password || fixture.href !== fixture.origin + '/') {
  throw new Error('AEGIS_IOS_DEVTOOLS_ORIGIN 必须是包含端口的本机 HTTP origin');
}

const appID = 'com.gcsa.aegis';
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8', timeout: 8000 }).trim();
const appData = simctl('get_app_container', device, appID, 'data');
const temp = path.join(appData, 'tmp');
// eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于指定验收 App 的模拟器缓存与诊断会话。
const lease = await open(path.join(temp, 'mobile-devtools.lock'), 'a+', 0o600);
try {
  // lockf 在继承的文件描述符上取锁。Node 崩溃时内核自动释放。
  execFileSync('/usr/bin/lockf', ['-s', '-t', '0', '3'], {
    stdio: ['ignore', 'ignore', 'pipe', lease.fd],
  });
} catch (error) {
  await lease.close();
  if (error.status === 75) throw new Error('该模拟器已有诊断会话');
  throw error;
}
const token = randomUUID().toUpperCase();
const directory = path.join(temp, 'mobile-devtools-' + token);
let launched = false;
let stopped = false;
const lifecycle = new AbortController();
const stop = () => lifecycle.abort();
process.once('SIGTERM', stop);
process.once('SIGINT', stop);

async function cleanup() {
  if (stopped) return;
  stopped = true;
  if (launched) {
    try { simctl('terminate', device, appID); } catch { /* 模拟器可能已退出。 */ }
  }
  await rm(directory, { recursive: true, force: true });
}

const server = new McpServer({ name: 'aegis-ios-development-diagnostics', version: '1.0.0' });
const transport = new StdioServerTransport();
let pending = Promise.resolve();
async function request(method, url) {
  if (stopped) throw new Error('诊断会话已关闭');
  if (url) {
    const target = new URL(url);
    if (target.origin !== fixture.origin || target.username || target.password) {
      throw new Error('只允许访问本次诊断的测试站点');
    }
  }
  const id = randomUUID();
  const file = path.join(directory, 'request.json');
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于指定验收 App 的模拟器缓存与诊断会话。
  await writeFile(file + '.tmp', JSON.stringify({ id, method, url }), { mode: 0o600 });
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于指定验收 App 的模拟器缓存与诊断会话。
  await rename(file + '.tmp', file);
  const reply = path.join(directory, 'reply.json');
  const deadline = Date.now() + 32_000;
  while (!stopped && Date.now() < deadline) {
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于指定验收 App 的模拟器缓存与诊断会话。
    const response = await readFile(reply, 'utf8').then(JSON.parse).catch(error => {
      if (error.code === 'ENOENT') return null;
      throw error;
    });
    if (response?.id?.toLowerCase() === id) {
      if (response.result.error) throw new Error(response.result.error);
      return response.result;
    }
    await delay(50);
  }
  // 失去响应时关闭诊断进程，避免迟到请求覆盖后续指令。
  await cleanup();
  throw new Error('等待 iOS 诊断响应超时');
}

function tool(method, description, inputSchema = {}) {
  server.registerTool(method, { description, inputSchema }, ({ url } = {}) => {
    const job = pending.then(() => request(method, url));
    pending = job.catch(() => {});
    return job.then(result => result.png
      ? { content: [{ type: 'image', mimeType: 'image/png', data: result.png }] }
      : { content: [{ type: 'text', text: JSON.stringify(result) }] })
      .catch(error => ({ isError: true, content: [{ type: 'text', text: error.message }] }));
  });
}
tool('navigate_page', '在 iOS Aegis 的隔离标签打开本机测试网页。', { url: z.string().max(2048).url() });
tool('take_snapshot', '读取当前测试网页的可见 DOM 文本。');
tool('take_screenshot', '截图当前测试网页可视区域。');
tool('inspect_web_app', '读取当前 iOS 测试网页声明的同源 Web App Manifest。');

try {
  // 已接管独占锁后，只回收前版协议明确标记为本工具创建的目录。
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于指定验收 App 的模拟器缓存与诊断会话。
  for (const name of await readdir(temp)) {
    if (!/^mobile-devtools-[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$/.test(name)) continue;
    const previous = path.join(temp, name);
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于指定验收 App 的模拟器缓存与诊断会话。
    if (await stat(path.join(previous, 'owned-session')).catch(() => null)) {
      await rm(previous, { recursive: true, force: true });
    }
  }
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于指定验收 App 的模拟器缓存与诊断会话。
  await mkdir(directory, { mode: 0o700 });
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于指定验收 App 的模拟器缓存与诊断会话。
  await writeFile(path.join(directory, 'owned-session'), String(process.pid), { mode: 0o600 });
  simctl('launch', '--terminate-running-process', device, appID, '--ui-testing', '--mobile-devtools', token, fixture.port);
  launched = true;
  const deadline = Date.now() + 15_000;
  const ready = path.join(directory, 'ready');
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于指定验收 App 的模拟器缓存与诊断会话。
  while (!(await stat(ready).catch(() => null))) {
    if (Date.now() >= deadline) throw new Error('iOS 诊断页未就绪，请安装包含此功能的 Debug 构建');
    await delay(100, undefined, { signal: lifecycle.signal });
  }
  lifecycle.signal.throwIfAborted();
  await server.connect(transport);
  if (!process.stdin.readableEnded && !lifecycle.signal.aborted) {
    await new Promise(resolve => {
      process.stdin.once('end', resolve);
      lifecycle.signal.addEventListener('abort', resolve, { once: true });
    });
  }
} finally {
  process.removeListener('SIGTERM', stop);
  process.removeListener('SIGINT', stop);
  try {
    await server.close();
  } finally {
    try { await cleanup(); } finally { await lease.close(); }
  }
}
