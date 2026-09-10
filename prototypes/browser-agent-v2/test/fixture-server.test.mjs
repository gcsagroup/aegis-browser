import assert from 'node:assert/strict';
import fs from 'node:fs';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { startFixtureServer } from '../src/fixture-server.mjs';

function request(url) {
  return new Promise((resolve, reject) => {
    https.get(url, { rejectUnauthorized: false }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body }));
    }).on('error', reject);
  });
}

test('HTTPS fixture 覆盖 E0–E11 所需页面且证书只在 run 内生成', async (t) => {
  const runRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-fixture-'));
  t.after(() => fs.rmSync(runRoot, { recursive: true, force: true }));
  const requests = [];
  const fixture = await startFixtureServer({ runRoot, onRequest: (entry) => requests.push(entry) });
  t.after(() => fixture.close());
  assert.match(fixture.origin, /^https:\/\/127\.0\.0\.1:\d+$/);
  assert.match(fixture.spkiSha256, /^[A-Za-z0-9+/]+={0,2}$/);

  for (const route of ['/', '/research', '/dynamic', '/tabs', '/login', '/otp', '/download', '/bookmarks', '/prompt-injection', '/redirect', '/shop', '/recovery']) {
    const response = await request(`${fixture.origin}${route}`);
    assert.equal(response.status, 200, route);
    assert.match(response.headers['content-type'], /text\/html/);
  }
  const download = await request(`${fixture.origin}/download/sample.txt`);
  assert.equal(download.status, 200);
  assert.match(download.headers['content-disposition'], /attachment/);
  assert.match(download.body, /safe fixture/);
  assert.equal(requests.length, 13);
  assert.ok(fs.existsSync(path.join(runRoot, 'fixture-tls', 'fixture-key.pem')));
  assert.equal(fs.statSync(path.join(runRoot, 'fixture-tls', 'fixture-key.pem')).mode & 0o777, 0o600);
});
