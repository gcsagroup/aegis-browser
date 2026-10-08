import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {once} from 'node:events';
import {createInterface} from 'node:readline';
import test from 'node:test';
import {runInNewContext} from 'node:vm';
import {fileURLToPath} from 'node:url';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {integrationManifest, renderSecurityCase} from './integration-benchmark-fixtures.mjs';
import {readinessCatalog, renderReadinessForm} from './acceptance-readiness-fixtures.mjs';

test('第二版500条链接保留HTTP分类和独立范围拒绝负例', () => {
  const catalog = readinessCatalog('https://fixture.example.org');
  assert.equal(catalog.links.length, 500);
  assert.equal(new Set(catalog.links.map(item => item.url)).size, 500);
  assert.deepEqual(catalog.expectedCounts, {live: 100, redirect: 50,
    auth_required: 50, rate_limited: 50, permanent_http_error: 100,
    temporary_http_error: 50, timeout: 50, scope_blocked: 50});
  assert.equal(catalog.browserExecuted, false);
  assert.equal(catalog.publicDeploymentVerified, false);
  assert.equal(catalog.links.filter(item => item.url.startsWith('file:')).length, 50);
  for (const origin of ['file:///tmp', 'https://user:secret@example.org', 'https://example.org/path']) {
    assert.throws(() => readinessCatalog(origin));
  }
  const html = renderReadinessForm();
  for (const marker of ['type="password"', 'one-time-code', 'cc-number',
    'fixture-password', 'fixture-otp', '4111111111111111']) assert.ok(html.includes(marker));
  assert.doesNotMatch(html, /<script|<form|<button|https?:\/\//u);
});

test('准备包导出不启动浏览器、不覆盖旧包且未部署不能标为通过', async () => {
  const root = await mkdtemp(join(tmpdir(), 'aegis-readiness-'));
  const script = fileURLToPath(new URL('./verify-agent-runtime.mjs', import.meta.url));
  const run = args => spawnSync(process.execPath, [script, ...args], {encoding: 'utf8'});
  try {
    const output = join(root, 'template');
    assert.equal(run(['--export-readiness', output]).status, 0);
    const catalog = JSON.parse(await readFile(join(output, 'readiness-v2.json'), 'utf8'));
    assert.equal(catalog.originProvided, false);
    assert.equal(catalog.origin, 'https://aegis-fixture.invalid');
    const bookmarks = JSON.parse(await readFile(join(output, 'bookmarks-500-v2.json'), 'utf8'));
    assert.deepEqual(bookmarks.roots.bookmark_bar.children.map(node => node.url),
      catalog.links.map(item => item.url));
    const before = await readFile(join(output, 'readiness-v2.json'), 'utf8');
    assert.notEqual(run(['--export-readiness', output]).status, 0);
    assert.equal(await readFile(join(output, 'readiness-v2.json'), 'utf8'), before);
    const bound = join(root, 'bound');
    assert.equal(run(['--export-readiness', bound, '--public-origin', 'https://fixture.example.org']).status, 0);
    const configured = JSON.parse(await readFile(join(bound, 'readiness-v2.json'), 'utf8'));
    assert.equal(configured.originProvided, true);
    assert.equal(configured.publicDeploymentVerified, false);
    for (const origin of ['http://example.org', 'https://127.0.0.1', 'https://[::1]',
      'https://localhost', 'https://user:secret@example.org', 'https://example.org/path']) {
      assert.notEqual(run(['--export-readiness', join(root, 'invalid'), '--public-origin', origin]).status, 0);
    }
    assert.notEqual(run(['--export-readiness']).status, 0);
    assert.notEqual(run(['--serve', '--public-origin', 'https://fixture.example.org']).status, 0);
  } finally {
    await rm(root, {recursive: true, force: true});
  }
});

test('冻结清单明确区分任务、重复运行与未执行的安全场景', () => {
  const manifest = integrationManifest();
  assert.equal(manifest.tasks.length, 30);
  assert.equal(manifest.securityCases.length, 100);
  assert.equal(new Set(manifest.tasks.map(item => item.id)).size, 30);
  assert.equal(new Set(manifest.securityCases.map(item => item.id)).size, 100);
  assert.deepEqual(Object.fromEntries(['research', 'steward', 'download', 'monitor', 'recovery']
      .map(group => [group, manifest.tasks.filter(item => item.group === group).length])),
  {research: 8, steward: 6, download: 5, monitor: 5, recovery: 6});
  assert.equal(manifest.tasks.reduce((total, item) => total + item.repetitions, 0), 90);
  for (const item of manifest.tasks) {
    for (const key of ['setup', 'prompt', 'oracle', 'cleanup']) assert.ok(item[key], item.id);
    assert.equal(item.status, 'not_run');
  }
  assert.equal(manifest.browserExecuted, false);
  assert.equal(manifest.agentExecuted, false);
  const {catalogSha256, ...data} = manifest;
  assert.equal(catalogSha256, createHash('sha256').update(JSON.stringify(data)).digest('hex'));
  assert.equal(integrationManifest().catalogSha256, catalogSha256);
});

test('安全载体包含真实指令且不执行脚本或网络请求', () => {
  const manifest = integrationManifest();
  assert.equal(new Set(manifest.securityCases.map(item => item.surface)).size, 10);
  assert.equal(new Set(manifest.securityCases.map(item => item.attack)).size, 10);
  for (const item of manifest.securityCases) {
    const html = renderSecurityCase(item.id);
    assert.match(html, /稳定指标为 <strong>42<\/strong>/u);
    assert.doesNotMatch(html, /<script|<iframe|<img|\bon\w+=|https?:\/\//iu);
    if (item.surface === 'unicode') {
      const decoded = [...html].filter(char => char.codePointAt(0) >= 0xE0020 &&
        char.codePointAt(0) <= 0xE007E).map(char =>
        String.fromCodePoint(char.codePointAt(0) - 0xE0000)).join('');
      assert.equal(decoded, item.payload);
      assert.ok(decoded.length > 30, item.id);
    } else {
      assert.ok(html.includes(item.payload), item.id);
    }
    assert.equal(item.exposureRequired, true);
    assert.equal(item.status, 'not_run');
  }
  for (const id of ['S000', 'S101', '<script>alert(1)</script>', '../S001', '']) {
    assert.equal(renderSecurityCase(id), null);
  }
});

test('真实 HTTP 服务交付清单、100 个独立页面和严格未知编号响应',
    {timeout: 30_000}, async () => {
      const script = fileURLToPath(new URL('./verify-agent-runtime.mjs', import.meta.url));
      const child = spawn(process.execPath, [script, '--serve', '--port', '0'],
          {stdio: ['ignore', 'pipe', 'pipe']});
      const exited = once(child, 'exit');
      let stderr = '';
      child.stderr.setEncoding('utf8').on('data', text => { stderr += text; });
      const lines = createInterface({input: child.stdout});
      try {
        const ready = await Promise.race([
          once(lines, 'line', {signal: AbortSignal.timeout(5000)})
              .then(([line]) => JSON.parse(line)),
          exited.then(([code]) => { throw new Error(`夹具提前退出 ${code}: ${stderr}`); }),
        ]);
        assert.match(ready.origin, /^http:\/\/127\.0\.0\.1:\d+$/u);
        const response = await fetch(`${ready.origin}/integration/manifest`);
        assert.equal(response.status, 200);
        const manifest = await response.json();
        assert.deepEqual(manifest, integrationManifest());
        const readyCatalog = await (await fetch(`${ready.origin}/fixtures/readiness-v2.json`)).json();
        assert.equal(readyCatalog.links.length, 500);
        assert.equal(readyCatalog.agentExecuted, false);
        const form = await fetch(`${ready.origin}/lab/input-sample`);
        assert.equal(form.status, 200);
        assert.match(form.headers.get('set-cookie'), /fixture-cookie; HttpOnly/u);
        assert.ok((await form.text()).includes(renderReadinessForm()));
        for (const [kind, code] of [['live', 200], ['redirect', 302], ['auth', 403],
          ['rate', 429], ['gone', 410], ['missing', 404], ['temporary', 503]]) {
          assert.equal((await fetch(`${ready.origin}/status/${kind}`, {redirect: 'manual'})).status, code);
        }
        assert.equal((await fetch(`${ready.origin}/status/head-unsupported`, {method: 'HEAD'})).status, 405);
        assert.equal((await fetch(`${ready.origin}/status/head-unsupported`)).status, 200);
        await assert.rejects(fetch(`${ready.origin}/status/timeout`, {signal: AbortSignal.timeout(100)}));
        for (const item of manifest.securityCases) {
          const page = await fetch(`${ready.origin}/integration/security/${item.id}`);
          assert.equal(page.status, 200, item.id);
          const html = await page.text();
          assert.ok(html.includes(renderSecurityCase(item.id)), item.id);
          assert.match(page.headers.get('content-type'), /text\/html/u);
        }
        for (const id of ['S000', 'S101', '%3Cscript%3E', 'S001/extra']) {
          const page = await fetch(`${ready.origin}/integration/security/${id}`);
          assert.equal(page.status, 404);
          assert.doesNotMatch(await page.text(), /<script>/u);
        }
        for (const [mode, changes] of [['noop', false], ['change', true]]) {
          const page = await fetch(`${ready.origin}/interaction/${mode}`);
          assert.equal(page.status, 200);
          const content = await page.text();
          assert.match(content, /尚未执行/u);
          assert.equal(content.includes('src="/interaction/action.js"'), changes);
          assert.doesNotMatch(page.headers.get('content-security-policy'), /script-src.*unsafe-inline/u);
        }
        const actionResponse = await fetch(`${ready.origin}/interaction/action.js`);
        assert.equal(actionResponse.status, 200);
        assert.match(actionResponse.headers.get('content-type'), /javascript/u);
        const state = {textContent: '尚未执行'};
        let click;
        runInNewContext(await actionResponse.text(), {document: {getElementById(id) {
          if (id === 'result') return state;
          assert.equal(id, 'execute');
          return {addEventListener(event, callback) {assert.equal(event, 'click'); click = callback;}};
        }}});
        assert.equal(state.textContent, '尚未执行');
        assert.equal(typeof click, 'function');
        click();
        assert.equal(state.textContent, '操作已生效');
        const reloadUrl = `${ready.origin}/interaction/reload?run=script-test`;
        assert.equal((await fetch(reloadUrl)).status, 200);
        const redirected = await fetch(reloadUrl, {redirect: 'manual'});
        assert.equal(redirected.status, 302);
        assert.equal(redirected.headers.get('location'), '/research/source-04');
        assert.equal((await fetch(`${ready.origin}/interaction/reload?run=independent`)).status, 200);
        for (const mode of ['navigation', 'reload']) {
          let listener;
          const location = {href: '', reload() {this.reloadCount = (this.reloadCount || 0) + 1;}};
          const script = await (await fetch(`${ready.origin}/interaction/${mode}.js`)).text();
          runInNewContext(script, {window: {location}, document: {getElementById(id) {
            assert.equal(id, 'execute');
            return {addEventListener(event, callback) {assert.equal(event, 'click'); listener = callback;}};
          }}});
          listener();
          if (mode === 'navigation') assert.equal(location.href, '/research/source-04');
          else assert.equal(location.reloadCount, 1);
        }
        for (const payload of ['fixture-cookie', 'fixture%2Dpassword',
          'fixture%252Dotp', '4111111111111111']) {
          await fetch(`${ready.origin}/status/live?payload=${payload}`);
        }
        const urlEvidence = await (await fetch(`${ready.origin}/evidence/requests`)).json();
        const rows = urlEvidence.requests ?? urlEvidence;
        for (const marker of ['fixture-cookie', 'fixture-password',
          'fixture-otp', '4111111111111111']) {
          assert.ok(rows.some(row => row.forbidden_markers.includes(marker)), marker);
        }
        assert.ok(rows.every(row => /^[0-9a-f]{64}$/u.test(row.request_url_sha256)));
        assert.equal((await fetch(`${ready.origin}/health`)).status, 200);
        const requests = await (await fetch(`${ready.origin}/evidence/requests`)).json();
        assert.ok(JSON.stringify(requests).includes('/integration/security/S100'));
        // GET 页面只是夹具可用性，不能改写为 Agent 的安全通过记录。
        const after = await (await fetch(`${ready.origin}/integration/manifest`)).json();
        assert.equal(after.agentExecuted, false);
        assert.ok(after.securityCases.every(item => item.status === 'not_run'));
        const sourceUrl = `${ready.origin}/research/source-01`;
        const controlUrl = `${ready.origin}/control/integration/source-01`;
        const original = await (await fetch(sourceUrl)).text();
        const headers = {'x-aegis-fixture-control': ready.integration_control_token,
          'content-type': 'application/json'};
        assert.equal((await fetch(controlUrl)).status, 405);
        assert.equal((await fetch(controlUrl, {method: 'POST', body: '{"value":47}'})).status, 403);
        assert.equal(await (await fetch(sourceUrl)).text(), original);
        for (const body of ['{', '{"value":"47"}', '{"value":101}',
          '{"value":47,"extra":true}', '{}']) {
          assert.equal((await fetch(controlUrl, {method: 'POST', headers, body})).status, 400);
        }
        const changed = await fetch(controlUrl, {method: 'POST', headers, body: '{"value":47}'});
        assert.equal(changed.status, 200);
        const modified = await (await fetch(sourceUrl)).text();
        assert.notEqual(modified, original);
        assert.match(modified, /data-claim-value="47"/u);
        assert.equal(await (await fetch(sourceUrl)).text(), modified);
        assert.match(await (await fetch(`${ready.origin}/research/source-02`)).text(),
            /data-claim-value="42"/u);
        assert.equal((await fetch(controlUrl, {method: 'POST', headers,
          body: '{"value":null}'})).status, 200);
        assert.equal(await (await fetch(sourceUrl)).text(), original);
        assert.ok(!JSON.stringify(manifest).includes(ready.integration_control_token));
        const recorded = await (await fetch(`${ready.origin}/evidence/requests`)).text();
        assert.ok(!recorded.includes(ready.integration_control_token));

        const downloadUrl = `${ready.origin}/download/aegis-fixture-macos-arm64.bin`;
        const transfersUrl = `${ready.origin}/evidence/download-transfers`;
        assert.match(await (await fetch(`${ready.origin}/download/slow`)).text(),
            /chunk_delay_ms=1000/u);
        for (const query of ['0', '-1', '1001', '1.5', 'abc', '']) {
          assert.equal((await fetch(`${downloadUrl}?chunk_delay_ms=${query}`)).status, 400);
        }
        assert.equal((await fetch(`${downloadUrl}?chunk_delay_ms=1&chunk_delay_ms=2`)).status, 400);
        assert.equal((await fetch(downloadUrl, {method: 'POST'})).status, 405);
        const head = await fetch(`${downloadUrl}?chunk_delay_ms=1`, {method: 'HEAD'});
        assert.equal(head.status, 200);
        assert.equal(await head.text(), '');
        assert.deepEqual((await (await fetch(transfersUrl)).json()).transfers, []);

        const cancellation = new AbortController();
        const slow = await fetch(`${downloadUrl}?chunk_delay_ms=1000`,
            {signal: cancellation.signal});
        const reader = slow.body.getReader();
        const firstChunk = await reader.read();
        assert.equal(firstChunk.done, false);
        assert.ok(firstChunk.value.length > 0);
        assert.ok(firstChunk.value.length < Number(slow.headers.get('content-length')));
        const active = (await (await fetch(transfersUrl)).json()).transfers[0];
        assert.equal(active.server_state, 'sending');
        cancellation.abort();
        await reader.cancel().catch(() => {});
        let stopped;
        const deadline = Date.now() + 2000;
        do {
          stopped = (await (await fetch(transfersUrl)).json()).transfers[0];
          if (stopped.server_state === 'connection_closed') break;
          await new Promise(resolveWait => setTimeout(resolveWait, 20));
        } while (Date.now() < deadline);
        assert.equal(stopped.server_state, 'connection_closed');
        assert.equal(stopped.id, active.id);
        assert.ok(stopped.sent_bytes > 0 && stopped.sent_bytes < stopped.total_bytes);

        // 完整重传必须与普通下载逐字节相同，取消连接不能损坏下一次响应。
        const normalBytes = Buffer.from(await (await fetch(downloadUrl)).arrayBuffer());
        const resumedBytes = Buffer.from(await (await fetch(
            `${downloadUrl}?chunk_delay_ms=1`)).arrayBuffer());
        assert.deepEqual(resumedBytes, normalBytes);
        assert.equal(createHash('sha256').update(resumedBytes).digest('hex'),
            ready.download_hashes['macos-arm64']);
        const complete = (await (await fetch(transfersUrl)).json()).transfers[1];
        assert.equal(complete.server_state, 'finished');
        assert.equal(complete.sent_bytes, complete.total_bytes);
      } finally {
        lines.close();
        child.kill('SIGTERM');
        const forceStop = setTimeout(() => child.kill('SIGKILL'), 3000);
        try { await exited; } finally { clearTimeout(forceStop); }
      }
    });
