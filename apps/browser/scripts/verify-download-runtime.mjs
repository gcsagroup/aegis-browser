#!/usr/bin/env node

import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {closeSync, constants, openSync, readFileSync} from 'node:fs';
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises';
import {createServer} from 'node:http';
import {homedir, tmpdir} from 'node:os';
import {basename, dirname, join, resolve} from 'node:path';
import process from 'node:process';
import {fileURLToPath} from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MARKER = join(ROOT, '.chromium-root');
const FILE_SIZE = 12 * 1024 * 1024;
const CHUNK_SIZE = 64 * 1024;
const CHUNK_DELAY_MS = 40;
const POLL_MS = 50;

class VerificationError extends Error {}
function assert(condition, message) {
  if (!condition) {
    throw new VerificationError(message);
  }
}
const delay = (milliseconds) =>
  new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));

function defaultChromium() {
  let chromiumRoot = process.env.CHROMIUM_ROOT?.trim();
  if (!chromiumRoot) {
    try {
      chromiumRoot = readFileSync(MARKER, 'utf8').trim();
    } catch {
      chromiumRoot = join(homedir(), 'Projects', 'GCSA-aegis-chromium');
    }
  }
  return join(
      chromiumRoot, 'src', 'out', 'AegisLocalDev', 'Chromium.app');
}

function parseArgs(argv) {
  const options = {
    chromium: process.env.AEGIS_CHROMIUM_BIN?.trim() || defaultChromium(),
    dryRun: false,
    keepProfile: false,
    report: null,
    timeoutMs: 45_000,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--chromium') {
      options.chromium = argv[++index];
    } else if (argument === '--timeout-ms') {
      options.timeoutMs = Number(argv[++index]);
    } else if (argument === '--report') {
      options.report = argv[++index];
    } else if (argument === '--keep-profile') {
      options.keepProfile = true;
    } else if (argument === '--dry-run') {
      options.dryRun = true;
    } else if (argument === '--') {
      continue;
    } else {
      throw new VerificationError('未知或不完整参数：' + argument);
    }
  }
  assert(Number.isSafeInteger(options.timeoutMs) && options.timeoutMs >= 5000,
         '--timeout-ms 必须是至少 5000 的整数');
  return options;
}

async function executableFrom(inputPath) {
  let executable = resolve(inputPath);
  if (basename(executable).endsWith('.app')) {
    executable = join(executable, 'Contents', 'MacOS', 'Chromium');
  }
  const metadata = await stat(executable).catch(() => null);
  assert(metadata?.isFile(), 'Chromium 可执行文件不存在：' + executable);
  await access(executable, constants.X_OK);
  return realpath(executable);
}

class Fixture {
  constructor() {
    this.payload = Buffer.allocUnsafe(FILE_SIZE);
    for (let index = 0; index < FILE_SIZE; index += 1) {
      this.payload[index] = (index * 31 + 17) & 0xff;
    }
    this.sha256 = createHash('sha256').update(this.payload).digest('hex');
    this.requests = [];
    this.server = createServer((request, response) =>
      this.handle(request, response));
  }

  async start() {
    await new Promise((resolveListen, rejectListen) => {
      this.server.once('error', rejectListen);
      this.server.listen(0, '127.0.0.1', resolveListen);
    });
    this.origin =
        'http://127.0.0.1:' + this.server.address().port;
  }

  reset() {
    this.requests.length = 0;
  }

  close() {
    return new Promise((resolveClose) => this.server.close(resolveClose));
  }

  handle(request, response) {
    const pathname = new URL(request.url || '/', this.origin).pathname;
    const rangeEnabled = pathname !== '/no-range.bin';
    if (!['/single.bin', '/parallel.bin', '/no-range.bin'].includes(pathname)) {
      response.writeHead(404);
      response.end();
      return;
    }
    const range = request.headers.range || '';
    let start = 0;
    let end = FILE_SIZE - 1;
    let status = 200;
    if (rangeEnabled && range) {
      const match = /^bytes=(\d+)-(\d*)$/u.exec(range);
      if (!match) {
        response.writeHead(416);
        response.end();
        return;
      }
      start = Number(match[1]);
      end = match[2] ? Math.min(Number(match[2]), end) : end;
      status = 206;
    }
    this.requests.push({
      path: pathname,
      range: range ? 'present' : 'absent',
      start,
      status,
    });
    const headers = {
      'accept-ranges': rangeEnabled ? 'bytes' : 'none',
      'cache-control': 'no-store',
      'content-disposition':
          'attachment; filename="' + pathname.slice(1) + '"',
      'content-length': String(end - start + 1),
      'content-type': 'application/octet-stream',
      etag: '"aegis-download-fixture-v1"',
      'last-modified': 'Wed, 26 Aug 2026 00:00:00 GMT',
    };
    if (status === 206) {
      headers['content-range'] =
          'bytes ' + start + '-' + end + '/' + FILE_SIZE;
    }
    response.writeHead(status, headers);
    let offset = start;
    const writeNext = () => {
      if (offset > end || response.destroyed) {
        response.end();
        return;
      }
      const next = Math.min(offset + CHUNK_SIZE, end + 1);
      response.write(this.payload.subarray(offset, next));
      offset = next;
      setTimeout(writeNext, CHUNK_DELAY_MS);
    };
    writeNext();
  }
}

class Cdp {
  constructor(socket, timeoutMs) {
    this.socket = socket;
    this.timeoutMs = timeoutMs;
    this.nextId = 1;
    this.pending = new Map();
    socket.addEventListener('message', async (event) => {
      const text = typeof event.data === 'string' ? event.data :
          event.data instanceof Blob ? await event.data.text() :
          Buffer.from(event.data).toString('utf8');
      const message = JSON.parse(text);
      const pending = this.pending.get(message.id);
      if (!pending) {
        return;
      }
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(new VerificationError(
            pending.method + '：' + message.error.message));
      } else {
        pending.resolve(message.result || {});
      }
    });
  }

  static async connect(url, timeoutMs) {
    const socket = new WebSocket(url);
    await new Promise((resolveOpen, rejectOpen) => {
      const timer = setTimeout(
          () => rejectOpen(new VerificationError('CDP WebSocket 超时')),
          timeoutMs);
      socket.addEventListener('open', () => {
        clearTimeout(timer);
        resolveOpen();
      }, {once: true});
      socket.addEventListener('error', rejectOpen, {once: true});
    });
    return new Cdp(socket, timeoutMs);
  }

  command(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolveCommand, rejectCommand) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectCommand(new VerificationError(method + ' 超时'));
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
}

async function devToolsPort(profileDir, child, timeoutMs) {
  const portFile = join(profileDir, 'DevToolsActivePort');
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    assert(child.exitCode === null,
           'Chromium 在 DevTools 就绪前退出：' + child.exitCode);
    const content = await readFile(portFile, 'utf8').catch(() => '');
    const port = Number(content.trim().split(/\r?\n/u)[0]);
    if (Number.isSafeInteger(port) && port > 0) {
      return port;
    }
    await delay(POLL_MS);
  }
  throw new VerificationError('等待 DevToolsActivePort 超时');
}

async function stop(child) {
  if (!child || child.exitCode !== null) {
    return;
  }
  const exited = new Promise((resolveExit) => child.once('exit', resolveExit));
  child.kill('SIGTERM');
  await Promise.race([exited, delay(5000)]);
  if (child.exitCode === null) {
    child.kill('SIGKILL');
    await Promise.race([exited, delay(2000)]);
  }
}

async function completedFile(path, timeoutMs) {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    const metadata = await stat(path).catch(() => null);
    const partial = await stat(path + '.crdownload').catch(() => null);
    if (metadata?.size === FILE_SIZE && !partial) {
      return;
    }
    await delay(POLL_MS);
  }
  throw new VerificationError('等待下载完成超时：' + basename(path));
}

async function runDownload(
    chromium, fixture, tempRoot, name, pathname, disableParallel, timeoutMs) {
  const profile = join(tempRoot, 'profile-' + name);
  const downloads = join(tempRoot, 'downloads-' + name);
  await mkdir(profile, {recursive: true, mode: 0o700});
  await mkdir(downloads, {recursive: true, mode: 0o700});
  const logFd = openSync(join(tempRoot, name + '.log'), 'a', 0o600);
  const args = [
    '--user-data-dir=' + profile,
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
    '--headless=new',
    ...(process.platform === 'darwin' ? ['--use-mock-keychain'] : []),
    ...(disableParallel ? ['--disable-features=ParallelDownloading'] : []),
    'about:blank',
  ];
  let child;
  fixture.reset();
  const startedAt = performance.now();
  try {
    child = spawn(chromium, args, {stdio: ['ignore', logFd, logFd]});
    closeSync(logFd);
    const port = await devToolsPort(profile, child, timeoutMs);
    const response = await fetch(
        'http://127.0.0.1:' + port + '/json/new', {method: 'PUT'});
    assert(response.ok, '创建 CDP target 失败');
    const target = await response.json();
    const cdp = await Cdp.connect(target.webSocketDebuggerUrl, timeoutMs);
    await cdp.command('Browser.setDownloadBehavior', {
      behavior: 'allow',
      downloadPath: downloads,
      eventsEnabled: true,
    });
    await cdp.command('Page.navigate', {url: fixture.origin + pathname});
    const output = join(downloads, pathname.slice(1));
    await completedFile(output, timeoutMs);
    const sha256 = createHash('sha256')
        .update(await readFile(output))
        .digest('hex');
    assert(sha256 === fixture.sha256, name + ' SHA-256 不匹配');
    cdp.socket.close();
    return {
      elapsedMs: Math.round(performance.now() - startedAt),
      rangeRequests:
          fixture.requests.filter((item) => item.range === 'present').length,
      requestCount: fixture.requests.length,
      sha256,
    };
  } finally {
    await stop(child);
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  assert(typeof WebSocket === 'function', '当前 Node 不提供 WebSocket');
  const chromium = await executableFrom(options.chromium);
  if (options.dryRun) {
    process.stdout.write('dry-run 通过：' + chromium + '\n');
    return;
  }
  const tempRoot = await mkdtemp(join(tmpdir(), 'gcsa-aegis-download-'));
  const fixture = new Fixture();
  let passed = false;
  try {
    await fixture.start();
    const single = await runDownload(
        chromium, fixture, tempRoot, 'single', '/single.bin', true,
        options.timeoutMs);
    const parallel = await runDownload(
        chromium, fixture, tempRoot, 'parallel', '/parallel.bin', false,
        options.timeoutMs);
    const fallback = await runDownload(
        chromium, fixture, tempRoot, 'fallback', '/no-range.bin', false,
        options.timeoutMs);
    const speedup = single.elapsedMs / parallel.elapsedMs;
    const expectedMinimumSpeedup =
        parallel.rangeRequests >= 2 ? 2.2 : 1.5;
    assert(single.requestCount === 1 && single.rangeRequests === 0,
           '单连接对照产生了额外请求');
    assert(parallel.rangeRequests >= 1, '未观察到 Range 子请求');
    assert(
        speedup >= expectedMinimumSpeedup,
        '并行吞吐提升不足 ' + expectedMinimumSpeedup.toFixed(1) +
            ' 倍：' + speedup.toFixed(2));
    assert(fallback.requestCount === 1 && fallback.rangeRequests === 0,
           '无 Range 响应没有安全回落');
    const report = {
      generatedAt: new Date().toISOString(),
      schemaVersion: 1,
      evidencePrivacy: {
        authorizationCaptured: false,
        cookieCaptured: false,
        queryValuesCaptured: false,
      },
      fixture: {bytes: FILE_SIZE, sha256: fixture.sha256},
      single,
      parallel,
      fallback,
      speedup: Number(speedup.toFixed(3)),
      expectedMinimumSpeedup,
      policyMode: parallel.rangeRequests >= 2 ?
          'three-or-more-connections' : 'battery-or-resource-constrained',
    };
    if (options.report) {
      const reportPath = resolve(options.report);
      await mkdir(dirname(reportPath), {recursive: true});
      await writeFile(
          reportPath, JSON.stringify(report, null, 2) + '\n', {mode: 0o600});
    }
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
    passed = true;
  } finally {
    await fixture.close();
    if (passed && !options.keepProfile) {
      await rm(tempRoot, {recursive: true, force: true});
    } else {
      process.stderr.write('保留运行证据：' + tempRoot + '\n');
    }
  }
}

main().catch((error) => {
  process.stderr.write('下载运行验证失败：' + error.message + '\n');
  process.exitCode = 1;
});
