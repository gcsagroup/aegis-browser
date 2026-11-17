import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { generateKeyPairSync } from 'node:crypto';
import { constants } from 'node:fs';
import { createServer } from 'node:http';
import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

import { createRunContext } from './run-context.mjs';

const binary = process.env.AEGIS_DEVTOOLS_CHROME;
assert.ok(binary && path.isAbsolute(binary), '请用 AEGIS_DEVTOOLS_CHROME 指定 Aegis 可执行文件的绝对路径');
await access(binary, constants.X_OK);
const { runRoot, workingDirectory: work, profilePath: profile } = createRunContext({
  scenarioId: 'DEVTOOLS-EXTENSION', candidate: 'aegis-cdp',
});
const fixture = createServer((_, response) => {
  response.setHeader('Content-Type', 'text/html');
  // eslint-disable-next-line xss/no-mixed-html -- 本机测试服务只返回固定的合成页面。
  response.end('<!doctype html><title>隔离调试</title><h1>PUBLIC</h1>');
});

async function prepare(name, marker, { version = '1.0.0', key } = {}) {
  const directory = path.join(work, name);
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于本次隔离测试目录内的合成扩展和产物。
  await mkdir(directory, { recursive: true });
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于本次隔离测试目录内的合成扩展和产物。
  await writeFile(path.join(directory, 'manifest.json'), JSON.stringify({
    manifest_version: 3, name, version, key, background: { service_worker: 'worker.js' },
  }));
  assert.match(marker, /^[A-Z0-9_]+$/, '测试标记只允许大写字母、数字和下划线');
  // eslint-disable-next-line security/detect-non-literal-fs-filename, xss/no-mixed-html -- 标记通过字符校验，页面仅写入隔离测试目录。
  await writeFile(path.join(directory, 'marker.html'), '<!doctype html><h1>' + marker + '</h1>');
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于本次隔离测试目录内的合成扩展和产物。
  await writeFile(path.join(directory, 'worker.js'), [
    "self.workerMarker = 'PIPE_SCOPE_WORKER';",
    'chrome.runtime.onInstalled.addListener(() => {});',
  ].join('\n'));
  return directory;
}

const preloaded = await prepare('preloaded-extension', 'PRELOADED');
const extension = await prepare('pipe-owned-extension', 'PIPE_SCOPE_V1');
const { publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const key = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
const fixedKey = await prepare('fixed-key-extension', 'FIXED_KEY', { key });
await new Promise((resolve, reject) => {
  fixture.once('error', reject);
  fixture.listen(0, '127.0.0.1', resolve);
});
const publicUrl = `http://127.0.0.1:${fixture.address().port}/`;
const browser = spawn(binary, [
  '--headless', '--remote-debugging-pipe', '--remote-debugging-port=0',
  '--remote-debugging-address=127.0.0.1', '--user-data-dir=' + profile,
  '--enable-unsafe-extension-debugging', '--load-extension=' + preloaded,
  '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
  '--disable-component-update', '--use-mock-keychain',
  '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', publicUrl,
], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
const exited = new Promise(resolve => browser.once('close', resolve));
let launchError;
browser.once('error', error => { launchError = error; });
const results = {};
let socket;
function transport(write) {
  let nextId = 0;
  const pending = new Map();
  return {
    receive(message) {
      pending.get(message.id)?.(message);
    },
    send(method, params = {}, sessionId) {
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(method + ' 超时'));
        }, 8000);
        pending.set(id, packet => {
          pending.delete(id);
          clearTimeout(timer);
          resolve(packet);
        });
        write(JSON.stringify({ id, method, params, ...(sessionId && { sessionId }) }));
      });
    },
  };
}

const pipe = transport(message => browser.stdio[3].write(message + '\0'));
let data = '';
browser.stdio[4].setEncoding('utf8').on('data', chunk => {
  data += chunk;
  for (;;) {
    const end = data.indexOf('\0');
    if (end < 0) return;
    pipe.receive(JSON.parse(data.slice(0, end)));
    data = data.slice(end + 1);
  }
});
const targetInfo = async (client, target) => client.send('Target.getTargetInfo', target);
const attach = async (client, target) => client.send('Target.attachToTarget', { ...target, flatten: true });
const pageNavigate = async (client, sessionId, url) => client.send('Page.navigate', { url }, sessionId);
const result = response => {
  assert.ok(response.result, JSON.stringify(response));
  return response.result;
};
const waitFor = async (callback, test) => {
  let value;
  for (let attempt = 0; attempt < 60; attempt++) {
    value = await callback();
    if (test(value)) return value;
    await delay(100);
  }
  assert.fail(JSON.stringify(value));
};
const marker = async (client, sessionId) => client.send('Runtime.evaluate', {
  expression: 'document.querySelector("h1")?.textContent', returnByValue: true,
}, sessionId);
async function open(client, url) {
  const target = result(await client.send('Target.createTarget', { url: 'about:blank' }));
  const { sessionId } = result(await attach(client, target));
  const reply = await pageNavigate(client, sessionId, url);
  return { target, sessionId, reply };
}
try {
  const portFile = await waitFor(async () => {
    if (launchError) throw launchError;
    assert.equal(browser.exitCode, null, 'Aegis 在启动调试连接前退出');
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于本次隔离测试目录内的合成扩展和产物。
    return readFile(path.join(profile, 'DevToolsActivePort'), 'utf8').catch(error => {
      if (error.code === 'ENOENT') return '';
      throw error;
    });
  }, Boolean);
  const [port, resource] = portFile.trim().split('\n');
  socket = new WebSocket('ws://127.0.0.1:' + port + resource);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  const peer = transport(message => socket.send(message));
  socket.addEventListener('message', event => peer.receive(JSON.parse(event.data)));

  const info = result(await pipe.send('Browser.getVersion'));
  results.version = info.product;
  const preExisting = await waitFor(
    async () => result(await pipe.send('Extensions.getExtensions')).extensions,
    extensions => extensions.some(item => item.name === 'preloaded-extension'),
  );
  const preloadedRecord = preExisting.find(item => item.name === 'preloaded-extension');
  const preloadedUrl = 'chrome-extension://' + preloadedRecord.id + '/marker.html';
  const { id } = result(await pipe.send('Extensions.loadUnpacked', { path: extension }));
  const ownUrl = 'chrome-extension://' + id + '/marker.html';
  const own = await open(pipe, publicUrl + 'shared');
  assert.ok(!result(own.reply).errorText, JSON.stringify(own.reply));
  await waitFor(() => marker(pipe, own.sessionId), value => value.result?.result?.value === 'PUBLIC');
  // 附加普通网页后由管道切换到扩展来源，第二个连接也必须从旧会话退出。
  const peerPreviouslyAttached = result(await attach(peer, own.target)).sessionId;
  await waitFor(() => marker(peer, peerPreviouslyAttached), value => value.result?.result?.value === 'PUBLIC');
  own.reply = await pageNavigate(pipe, own.sessionId, ownUrl);
  assert.ok(!result(own.reply).errorText, JSON.stringify(own.reply));
  await waitFor(() => marker(pipe, own.sessionId), value => value.result?.result?.value === 'PIPE_SCOPE_V1');
  assert.equal(result(await targetInfo(pipe, own.target)).targetInfo.url, ownUrl);
  const targets = { filter: [{ type: 'page' }, { type: 'tab' }, { type: 'service_worker' }] };
  assert.ok(result(await pipe.send('Target.getTargets', targets)).targetInfos.some(info => info.url === ownUrl));
  results.pipeReadsOwnExtension = true;
  const registeredWorker = await waitFor(
    async () => result(await pipe.send('Target.getTargets', targets)).targetInfos.find(
      info => info.type === 'service_worker' && info.url === `chrome-extension://${id}/worker.js`,
    ),
    Boolean,
  );
  const worker = { targetId: registeredWorker.targetId };
  const workerSession = result(await attach(pipe, worker)).sessionId;
  const workerResult = result(await pipe.send('Runtime.evaluate', {
    expression: 'self.workerMarker', returnByValue: true,
  }, workerSession));
  assert.equal(workerResult.result.value, 'PIPE_SCOPE_WORKER');
  assert.ok((await attach(peer, worker)).error);
  results.onlyPipeCanReadOwnExtensionWorker = true;

  assert.ok((await targetInfo(peer, own.target)).error);
  assert.ok((await attach(peer, own.target)).error);
  assert.ok(result(await peer.send('Target.getTargets', targets)).targetInfos.every(info => !info.url.includes(id)));
  assert.match((await open(peer, ownUrl)).reply.error?.message ?? '', /Navigation is not allowed/);
  assert.ok((await marker(peer, peerPreviouslyAttached)).error);
  results.websocketCannotDiscoverAttachOrNavigate = true;
  results.previouslyAttachedPeerIsDetached = true;
  assert.match((await open(pipe, preloadedUrl)).reply.error?.message ?? '', /Navigation is not allowed/);
  result(await pipe.send('Extensions.loadUnpacked', { path: preloaded }));
  assert.match((await open(pipe, preloadedUrl)).reply.error?.message ?? '', /Navigation is not allowed/);
  results.pipeCannotReadOrClaimPreloadedExtension = true;
  const keyed = result(await pipe.send('Extensions.loadUnpacked', { path: fixedKey }));
  const keyedUrl = `chrome-extension://${keyed.id}/marker.html`;
  assert.match((await open(pipe, keyedUrl)).reply.error?.message ?? '', /Navigation is not allowed/);
  result(await pipe.send('Extensions.uninstall', keyed));
  results.fixedKeyDoesNotGrantPageAccess = true;

  const privateContext = result(await pipe.send('Target.createBrowserContext')).browserContextId;
  const other = result(await pipe.send('Target.createTarget', { url: 'about:blank', browserContextId: privateContext }));
  const otherSession = result(await attach(pipe, other)).sessionId;
  assert.match((await pageNavigate(pipe, otherSession, ownUrl)).error?.message ?? '', /Navigation is not allowed/);
  result(await pipe.send('Target.disposeBrowserContext', { browserContextId: privateContext }));
  results.pipeCannotUseGrantInOtherBrowserContext = true;

  await prepare('pipe-owned-extension', 'PIPE_SCOPE_V2', { version: '1.0.1' });
  assert.equal(result(await pipe.send('Extensions.loadUnpacked', { path: extension })).id, id);
  const reloaded = await open(pipe, ownUrl);
  assert.ok(!result(reloaded.reply).errorText, JSON.stringify(reloaded.reply));
  await waitFor(() => marker(pipe, reloaded.sessionId), value => value.result?.result?.value === 'PIPE_SCOPE_V2');
  results.reloadPreservesGrant = true;
  result(await pipe.send('Extensions.uninstall', { id }));
  assert.match((await open(pipe, ownUrl)).reply.error?.message ?? '', /Navigation is not allowed/);
  results.uninstallRevokesGrant = true;
  const publicPage = result(await pipe.send('Target.getTargets', targets)).targetInfos.find(info => info.url === publicUrl);
  assert.ok(publicPage);
  for (const method of ['Target.openDevTools', 'Target.exposeDevToolsProtocol']) {
    assert.ok((await pipe.send(method, { targetId: publicPage.targetId })).error);
  }
  results.privilegedDevToolsRemainsUnavailable = true;
} catch (error) {
  results.error = String(error.stack ?? error);
  process.exitCode = 1;
} finally {
  socket?.close();
  browser.kill('SIGTERM');
  if (!await Promise.race([exited.then(() => true), delay(2000, false)])) {
    browser.kill('SIGKILL');
    await Promise.race([exited, delay(2000)]);
  }
  fixture.closeAllConnections();
  await new Promise(resolve => fixture.close(resolve));
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- 路径限于本次隔离测试目录内的合成扩展和产物。
  await writeFile(path.join(runRoot, 'results.json'), JSON.stringify(results, null, 2) + '\n', { mode: 0o600 });
  console.log(`扩展调试验证证据 ${runRoot}`);
}
