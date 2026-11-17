import { execFileSync, spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const serial = process.env.AEGIS_ADB_SERIAL;
if (!serial || !/^[\w.:\-[\]]+$/.test(serial)) throw new Error('请用 AEGIS_ADB_SERIAL 指定已连接的验收设备');
const adb = (...args) => execFileSync('adb', ['-s', serial, ...args], { encoding: 'utf8', timeout: 5000 }).trim();
const socket = process.env.AEGIS_ANDROID_CDP_SOCKET ?? 'chrome_devtools_remote';
if (!/^[\w.-]+_devtools_remote$/.test(socket)) throw new Error('Android CDP socket 名称无效');
const lifecycle = new AbortController();
let child;
function stop() {
  lifecycle.abort();
  child?.kill('SIGTERM');
}
process.once('SIGINT', stop);
process.once('SIGTERM', stop);
const port = adb('forward', 'tcp:0', 'localabstract:' + socket);
if (!/^\d+$/.test(port)) throw new Error('ADB 未返回可用的本地端口');

try {
  const base = `http://127.0.0.1:${port}`;
  let response;
  let lastError;
  for (let attempt = 0; attempt < 8; attempt += 1) {
    lifecycle.signal.throwIfAborted();
    try {
      response = await fetch(base + '/json/version', {
        redirect: 'error', signal: AbortSignal.any([lifecycle.signal, AbortSignal.timeout(1000)]),
      });
      break;
    } catch (error) {
      lastError = error;
      await delay(250, undefined, { signal: lifecycle.signal });
    }
  }
  if (!response) {
    throw new Error('无法读取 Android CDP，请确认验收设备上的 Aegis 已打开并完成启动。', { cause: lastError });
  }
  if (!response.ok) throw new Error(`Android CDP 版本查询失败（${response.status}）`);
  const version = await response.json();
  if (version['Android-Package'] !== 'app.gcsa.aegis') throw new Error('CDP 目标不是 Aegis Android');
  // Android Chromium 的浏览器 socket 可使用固定路径，部分版本会提供具体 target ID。
  const endpoint = new URL(version.webSocketDebuggerUrl ?? `ws://127.0.0.1:${port}/devtools/browser/`);
  if (endpoint.protocol !== 'ws:' || endpoint.hostname !== '127.0.0.1' || endpoint.port !== port ||
      endpoint.username || endpoint.password ||
      !(endpoint.pathname === '/devtools/browser' || endpoint.pathname.startsWith('/devtools/browser/'))) {
    throw new Error('Android CDP 返回了未知的浏览器地址');
  }
  const args = process.argv.slice(2);
  lifecycle.signal.throwIfAborted();
  if (args.includes('--web-app-inspection')) {
    if (args.length !== 1) throw new Error('网页应用检查模式只接收 --web-app-inspection。');
    const { serveAndroidWebAppInspection } = await import('./android-web-app-mcp.mjs');
    await serveAndroidWebAppInspection(endpoint.href, lifecycle.signal);
  } else {
    const launcher = fileURLToPath(new URL('./devtools-mcp.mjs', import.meta.url));
    child = spawn(process.execPath, [launcher, ...args, `--ws-endpoint=${endpoint.href}`], { stdio: 'inherit' });
    process.exitCode = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', code => resolve(code ?? 1));
    });
  }
} finally {
  process.removeListener('SIGINT', stop);
  process.removeListener('SIGTERM', stop);
  try {
    adb('forward', '--remove', 'tcp:' + port);
  } catch {
    process.stderr.write('ADB 未确认调试转发已移除。\n');
  }
}
