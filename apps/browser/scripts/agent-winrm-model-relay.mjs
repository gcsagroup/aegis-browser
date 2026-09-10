#!/usr/bin/env node
// 仅供隔离验收：Windows 回环服务经既有 WinRM 控制面转交给 Mac 本地 Qwen。
// 不实现通用代理，不读取凭据，不把提示词、响应或认证信息写入文件。
import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createInterface} from 'node:readline';
import {pathToFileURL} from 'node:url';

const MODEL = 'Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit';
const UPSTREAM = 'http://127.0.0.1:8000';
const LIMIT = 512 * 1024;
const CONTROL_HEADER = 'x-aegis-winrm-controller';
const CONTROL_VALUE = 'local-acceptance';
const hash = value => createHash('sha256').update(value).digest('hex');

function json(response, status, value) {
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
  });
  response.end(JSON.stringify(value));
}

async function readBody(stream) {
  const chunks = [];
  let size = 0;
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > LIMIT) throw new Error('body_limit');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function decodeBase64(value) {
  assert.equal(typeof value, 'string');
  assert(value.length <= Math.ceil(LIMIT / 3) * 4);
  assert(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(value));
  const result = Buffer.from(value, 'base64');
  assert.equal(result.toString('base64'), value);
  assert(result.length <= LIMIT);
  return result;
}

function validateJob(job) {
  assert.match(job.id, /^[0-9a-f-]{36}$/u);
  assert((job.method === 'GET' && job.path === '/v1/models') ||
      (job.method === 'POST' && job.path === '/v1/responses'));
  const body = decodeBase64(job.body_base64);
  if (job.method === 'GET') {
    assert.equal(body.length, 0);
  } else {
    const payload = JSON.parse(body);
    assert.equal(payload.model, MODEL);
    assert(payload.stream === false || payload.stream === undefined);
    assert(!/fixture-password|fixture-otp|fixture-cookie|4111111111111111/iu.test(body.toString('utf8')));
  }
  return body;
}

export class RelayServer {
  constructor({port = 0, deadlineMs = 150000, ttlMs = 900000, report = null} = {}) {
    this.port = port;
    this.deadlineMs = deadlineMs;
    this.ttlMs = ttlMs;
    this.report = report;
    this.jobs = new Map();
    this.records = [];
    this.started = new Date().toISOString();
    this.rejected = 0;
    this.server = createServer((request, response) => {
      this.handle(request, response).catch(() => {
        this.rejected += 1;
        if (!response.headersSent) json(response, 400, {error: 'invalid_test_request'});
        else response.destroy();
      });
    });
  }

  snapshot() {
    return {
      kind: 'aegis-winrm-local-model-relay',
      started_utc: this.started,
      model: MODEL,
      bind: '127.0.0.1',
      port: this.port,
      pending: this.jobs.size,
      rejected: this.rejected,
      raw_prompts_stored: false,
      raw_responses_stored: false,
      credentials_supported: false,
      records: this.records,
    };
  }

  async start() {
    await new Promise((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(this.port, '127.0.0.1', resolve);
    });
    this.port = this.server.address().port;
    this.origin = `http://127.0.0.1:${this.port}`;
    this.ttl = setTimeout(() => { void this.close(); }, this.ttlMs);
    this.ttl.unref();
    return this.origin;
  }

  finish(job, status, bytes, reason) {
    if (!this.jobs.delete(job.id)) return;
    clearTimeout(job.timer);
    this.records.push({
      id: job.id, method: job.method, path: job.path,
      request_bytes: job.body.length, request_sha256: hash(job.body),
      status, response_bytes: bytes.length, response_sha256: hash(bytes),
      elapsed_ms: Date.now() - job.started, reason,
    });
    this.records = this.records.slice(-100);
    if (!job.response.destroyed && !job.response.writableEnded) {
      job.response.writeHead(status, {
        'content-type': 'application/json', 'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
      });
      job.response.end(bytes);
    }
  }

  async handle(request, response) {
    const path = request.url;
    if (request.headers.host !== `127.0.0.1:${this.port}` ||
        request.headers.authorization || request.headers.cookie ||
        request.headers['x-api-key'] || request.headers.origin || request.headers.referer) {
      this.rejected += 1;
      json(response, 403, {error: 'isolated_keyless_loopback_only'});
      return;
    }
    if (path === '/health' && request.method === 'GET') {
      json(response, 200, {ok: true, model: MODEL, pending: this.jobs.size});
      return;
    }
    if (path.startsWith('/bridge/')) {
      if (request.method !== 'POST' || request.headers[CONTROL_HEADER] !== CONTROL_VALUE ||
          request.headers['sec-fetch-site'] ||
          !String(request.headers['content-type']).startsWith('application/json')) {
        this.rejected += 1;
        json(response, 403, {error: 'controller_required'});
        return;
      }
      const value = JSON.parse(await readBody(request));
      if (path === '/bridge/poll') {
        const job = this.jobs.values().next().value;
        json(response, 200, {job: job ? {
          id: job.id, method: job.method, path: job.path,
          body_base64: job.body.toString('base64'),
        } : null});
      } else if (path === '/bridge/reply') {
        const job = this.jobs.get(value.id);
        if (!job) { json(response, 409, {error: 'job_expired'}); return; }
        assert(Number.isInteger(value.status) && value.status >= 200 && value.status <= 599);
        const bytes = decodeBase64(value.body_base64);
        JSON.parse(bytes);
        this.finish(job, value.status, bytes, 'upstream_completed');
        json(response, 200, {ok: true, id: value.id});
      } else if (path === '/bridge/status') {
        json(response, 200, this.snapshot());
      } else if (path === '/bridge/stop') {
        json(response, 200, {ok: true});
        setImmediate(() => { void this.close(); });
      } else json(response, 404, {error: 'unsupported_control'});
      return;
    }
    if (!((request.method === 'GET' && path === '/v1/models') ||
          (request.method === 'POST' && path === '/v1/responses'))) {
      json(response, 404, {error: 'unsupported_model_endpoint'});
      return;
    }
    if (this.jobs.size >= 4) { json(response, 429, {error: 'test_queue_full'}); return; }
    const body = await readBody(request);
    const id = randomUUID();
    validateJob({id, method: request.method, path, body_base64: body.toString('base64')});
    const job = {id, method: request.method, path, body, response, started: Date.now()};
    job.timer = setTimeout(() => this.finish(job, 504,
        Buffer.from('{"error":"test_relay_deadline"}'), 'deadline'), this.deadlineMs);
    this.jobs.set(id, job);
    response.once('close', () => {
      if (!response.writableEnded) this.finish(job, 499, Buffer.from('{}'), 'client_closed');
    });
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.ttl);
    for (const job of [...this.jobs.values()]) {
      this.finish(job, 503, Buffer.from('{"error":"test_relay_stopped"}'), 'stopped');
    }
    await new Promise(resolve => this.server.close(resolve));
    if (this.report) await writeFile(this.report, JSON.stringify(this.snapshot(), null, 2) + '\n', {flag: 'wx'});
  }
}

async function worker() {
  process.stdout.write(JSON.stringify({ready: true, upstream: UPSTREAM, model: MODEL}) + '\n');
  for await (const line of createInterface({input: process.stdin, crlfDelay: Infinity})) {
    let job;
    try {
      job = JSON.parse(line);
      const body = validateJob(job);
      const response = await fetch(UPSTREAM + job.path, {
        method: job.method,
        headers: job.method === 'POST' ? {'content-type': 'application/json'} : {},
        body: job.method === 'POST' ? body : undefined,
        redirect: 'error', signal: AbortSignal.timeout(120000),
      });
      const bytes = await readBody(response.body);
      JSON.parse(bytes);
      process.stdout.write(JSON.stringify({id: job.id, status: response.status,
        body_base64: bytes.toString('base64')}) + '\n');
    } catch {
      process.stdout.write(JSON.stringify({id: job?.id ?? null, status: 502,
        body_base64: Buffer.from('{"error":"local_model_forwarding_failed"}').toString('base64')}) + '\n');
    }
  }
}

async function selfTest() {
  const relay = new RelayServer({deadlineMs: 500, ttlMs: 10000});
  const origin = await relay.start();
  const control = (path, value = {}) => fetch(origin + '/bridge/' + path, {
    method: 'POST', headers: {[CONTROL_HEADER]: CONTROL_VALUE, 'content-type': 'application/json'},
    body: JSON.stringify(value),
  });
  try {
    assert.equal((await fetch(origin + '/health')).status, 200);
    assert.equal((await fetch(origin + '/bridge/poll')).status, 403);
    assert.equal((await fetch(origin + '/health', {headers: {origin: 'https://example.com'}})).status, 403);
    assert.equal((await fetch(origin + '/health', {headers: {cookie: 'fixture-cookie'}})).status, 403);
    assert.equal((await fetch(origin + '/v1/other')).status, 404);
    assert.throws(() => validateJob({id: randomUUID(), method: 'GET', path: 'https://example.com', body_base64: ''}));
    assert.throws(() => validateJob({id: randomUUID(), method: 'POST', path: '/v1/responses',
      body_base64: Buffer.from(JSON.stringify({model: MODEL, input: 'fixture-password'})).toString('base64')}));
    const request = fetch(origin + '/v1/models');
    let job;
    for (let i = 0; i < 20 && !job; i++) {
      job = (await (await control('poll')).json()).job;
      if (!job) await new Promise(resolve => setTimeout(resolve, 5));
    }
    assert(job);
    const responseBody = JSON.stringify({data: [{id: MODEL}]});
    assert.equal((await control('reply', {id: job.id, status: 200,
      body_base64: Buffer.from(responseBody).toString('base64')})).status, 200);
    assert.equal(await (await request).text(), responseBody);
    const expired = await fetch(origin + '/v1/models');
    assert.equal(expired.status, 504);
    const report = (await (await control('status')).json());
    assert.equal(report.records.length, 2);
    assert.equal(report.pending, 0);
    assert(!JSON.stringify(report).includes('body_base64'));
    assert(!JSON.stringify(report).includes(responseBody));
    process.stdout.write('PASS: WinRM 模型回环中转、来源限制、敏感值拒绝、超时和无正文日志\n');
  } finally { await relay.close(); }
}

async function main() {
  const [mode, portText, report] = process.argv.slice(2);
  if (mode === '--self-test') return selfTest();
  if (mode === 'worker') return worker();
  assert.equal(mode, 'server');
  const port = Number(portText);
  assert(Number.isInteger(port) && port >= 1024 && port <= 65535);
  const relay = new RelayServer({port, report});
  await relay.start();
  process.stdout.write(JSON.stringify({ready: true, origin: relay.origin, pid: process.pid}) + '\n');
  process.once('SIGINT', () => { void relay.close(); });
  process.once('SIGTERM', () => { void relay.close(); });
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => { process.stderr.write('ERROR: 模型测试中转已停止\n'); process.exitCode = 1; });
}
