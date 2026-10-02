import assert from 'node:assert/strict';
import {once} from 'node:events';
import {request} from 'node:http';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createInterface} from 'node:readline';
import test from 'node:test';
import {createLinkFixture} from './public-link-fixture.mjs';
import {readinessCatalog} from './acceptance-readiness-fixtures.mjs';

const script = fileURLToPath(new URL('./public-link-fixture.mjs', import.meta.url));

test('独立服务覆盖500条目录的全部HTTP分类，并保留拒绝负例', async () => {
  const server = createLinkFixture();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const catalog = readinessCatalog(origin);
    const expected = {live: 200, 'head-unsupported': 200, redirect: 302,
      auth: 403, rate: 429, gone: 410, missing: 404, temporary: 503};
    for (const [kind, status] of Object.entries(expected)) {
      const url = catalog.links.find(item => item.kind === kind).url;
      const reply = await fetch(url, {redirect: 'manual'});
      assert.equal(reply.status, status, kind);
      assert.equal(reply.headers.get('cache-control'), 'no-store');
      await reply.text();
    }
    const head = await fetch(`${origin}/status/head-unsupported`, {method: 'HEAD'});
    assert.equal(head.status, 405);
    assert.equal(head.headers.get('allow'), 'GET');
    const redirected = await fetch(`${origin}/status/redirect`);
    assert.equal(redirected.url, `${origin}/status/live`);
    assert.equal(await redirected.text(), 'live\n');
    const liveHead = await fetch(`${origin}/status/live`, {method: 'HEAD'});
    assert.equal(liveHead.headers.get('content-length'), '5');
    assert.equal(await liveHead.text(), '');
    await assert.rejects(fetch(`${origin}/status/timeout`, {signal: AbortSignal.timeout(100)}), /timeout/i);
    assert.equal(catalog.links.filter(item => item.kind === 'out-of-scope').length, 50);
    assert.equal(catalog.browserExecuted, false);
    assert.equal(catalog.publicDeploymentVerified, false);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});

test('公开服务不暴露控制、模型、证据、文件或写入入口', async () => {
  const server = createLinkFixture();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  const get = path => new Promise((resolve, reject) => {
    const req = request({host: '127.0.0.1', port, path}, response => {
      response.resume();
      response.once('end', () => resolve(response.statusCode));
    });
    req.on('error', reject);
    req.end();
  });
  try {
    for (const path of ['/control/reset', '/provider/v1/responses', '/evidence/requests',
      '/status/../control/reset', '/%73tatus/live', '/status/live/extra',
      '/etc/passwd', 'http://example.test/status/live']) assert.equal(await get(path), 404, path);
    const reply = await fetch(`http://127.0.0.1:${port}/status/live`, {method: 'POST', body: 'synthetic'});
    assert.equal(reply.status, 405);
    await reply.text();
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});

test('命令行正常启动、错误参数失败，退出不遗留服务', async () => {
  for (const args of [['--port', '-1'], ['--port', '65536'], ['--host', 'example.test'],
    ['--port'], ['--unknown'], ['--port', '1', '--port', '2']]) {
    assert.notEqual(spawnSync(process.execPath, [script, ...args], {encoding: 'utf8', timeout: 5000}).status, 0);
  }
  const child = spawn(process.execPath, [script, '--port', '0'], {stdio: ['ignore', 'pipe', 'pipe']});
  const lines = createInterface({input: child.stdout});
  const exited = once(child, 'exit');
  try {
    const [line] = await once(lines, 'line');
    const ready = JSON.parse(line);
    assert.equal(ready.host, '127.0.0.1');
    assert.equal(ready.publicDeploymentVerified, false);
    const reply = await fetch(`http://127.0.0.1:${ready.port}/healthz`);
    assert.equal(await reply.text(), 'aegis-link-fixture-v2\n');
  } finally {
    child.kill('SIGTERM');
    const [code] = await exited;
    assert.equal(code, 0);
    lines.close();
  }
});
