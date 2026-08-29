import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  assertIsolatedProfile,
  assertPathWithin,
  buildAdapterEnvironment,
  redact,
  validateNavigationUrl,
} from '../src/security.mjs';

test('run 和 Profile 不能逃出隔离目录', () => {
  const root = path.join(os.tmpdir(), 'aegis-run');
  assert.equal(assertPathWithin(root, path.join(root, 'child')), path.join(root, 'child'));
  assert.throws(() => assertPathWithin(root, root), /隔离目录/);
  assert.throws(() => assertPathWithin(root, path.join(root, '..', 'daily-profile')), /隔离目录/);
  assert.equal(assertIsolatedProfile(root, path.join(root, 'profile')), path.join(root, 'profile'));
  assert.throws(() => assertIsolatedProfile(root, path.join(root, 'other-profile')), /专用目录/);
});

test('URL 策略只允许登记的 HTTPS origin 和 fixture 私网', () => {
  const fixture = 'https://127.0.0.1:9443';
  assert.equal(validateNavigationUrl('about:blank', { allowedOrigins: [] }).href, 'about:blank');
  assert.equal(validateNavigationUrl(`${fixture}/research`, {
    allowedOrigins: [fixture],
    fixtureOrigins: [fixture],
  }).pathname, '/research');
  assert.throws(() => validateNavigationUrl('http://example.com', { allowedOrigins: ['http://example.com'] }), /HTTPS/);
  assert.throws(() => validateNavigationUrl('https://example.org', { allowedOrigins: ['https://example.com'] }), /allowlist/);
  assert.throws(() => validateNavigationUrl(fixture, { allowedOrigins: [fixture] }), /私网/);
  assert.throws(() => validateNavigationUrl('https://user:pass@example.com', { allowedOrigins: ['https://example.com'] }), /凭据/);
});

test('日志递归脱敏密钥、密码、OTP 和 Authorization', () => {
  const fakeKey = ['sk', 'examplevalue123456789'].join('-');
  assert.deepEqual(redact({
    apiKey: fakeKey,
    nested: { password: 'fixture-password', note: 'Bearer abcdefghijklmnop' },
    otp: 123456,
  }), {
    apiKey: '[REDACTED]',
    nested: { password: '[REDACTED]', note: '[REDACTED]' },
    otp: '[REDACTED]',
  });
});

test('adapter 只继承显式模型密钥并强制关闭外联能力', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-adapter-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const runRoot = path.join(directory, 'run');
  const workingDirectory = path.join(runRoot, 'work');
  fs.mkdirSync(workingDirectory, { recursive: true });
  const fakeKey = ['sk', 'examplevalue123456789'].join('-');
  const environment = buildAdapterEnvironment({
    sourceEnvironment: {
      PATH: '/usr/bin',
      OPENAI_API_KEY: fakeKey,
      BROWSERBASE_API_KEY: 'must-not-pass',
      UNRELATED_SECRET: 'must-not-pass',
    },
    runRoot,
    workingDirectory,
    modelKeyName: 'OPENAI_API_KEY',
  });
  assert.equal(environment.OPENAI_API_KEY, fakeKey);
  assert.equal(environment.BROWSERBASE_API_KEY, undefined);
  assert.equal(environment.UNRELATED_SECRET, undefined);
  assert.equal(environment.ANONYMIZED_TELEMETRY, 'false');
  assert.equal(environment.BROWSER_USE_CLOUD_SYNC, 'false');
  assert.equal(environment.SKYVERN_TELEMETRY, 'false');
  assert.equal(environment.ENABLE_CODE_BLOCK, 'false');
  assert.equal(environment.DISABLE_CODE_BLOCK_EXECUTION, 'true');
  assert.equal(environment.OTEL_SDK_DISABLED, 'true');
});
