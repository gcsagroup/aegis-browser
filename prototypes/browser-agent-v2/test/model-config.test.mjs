import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  assertSameBenchmarkModel,
  buildSelectedModelEnvironment,
  resolveModelSelection,
} from '../src/model-config.mjs';

test('未配置时不偷偷选择默认 provider 或模型', () => {
  assert.deepEqual(resolveModelSelection({ sourceEnvironment: {} }), {
    configured: false,
    provider: null,
    model: null,
    baseUrl: null,
    local: false,
    credentialRequired: false,
    credentialAvailable: false,
  });
  assert.throws(
    () => resolveModelSelection({ sourceEnvironment: { AEGIS_V2_PROVIDER: 'openai' } }),
    /用户选择模型/,
  );
});

test('provider API 格式受支持列表约束，但模型名由用户指定', () => {
  assert.throws(() => resolveModelSelection({
    sourceEnvironment: { AEGIS_V2_PROVIDER: 'unknown', AEGIS_V2_MODEL: 'user-model' },
  }), /不支持的 provider/);

  const selection = resolveModelSelection({
    sourceEnvironment: {
      AEGIS_V2_PROVIDER: 'Anthropic',
      AEGIS_V2_MODEL: 'user-selected/model:2026-08-30',
    },
  });
  assert.equal(selection.provider, 'anthropic');
  assert.equal(selection.model, 'user-selected/model:2026-08-30');
});

test('只向 adapter 传所选 provider 的密钥，不返回或继承其他秘密', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-model-config-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const runRoot = path.join(directory, 'run');
  const workingDirectory = path.join(runRoot, 'work');
  fs.mkdirSync(workingDirectory, { recursive: true });
  const selectedSecret = ['sk', 'selected-example-value'].join('-');

  const { selection, environment } = buildSelectedModelEnvironment({
    sourceEnvironment: {
      PATH: '/usr/bin',
      AEGIS_V2_PROVIDER: 'openai',
      AEGIS_V2_MODEL: 'user-model',
      AEGIS_V2_BASE_URL: 'https://models.example.test/v1',
      OPENAI_API_KEY: selectedSecret,
      ANTHROPIC_API_KEY: 'must-not-pass',
      GOOGLE_API_KEY: 'must-not-pass',
      UNRELATED_SECRET: 'must-not-pass',
    },
    runRoot,
    workingDirectory,
  });

  assert.equal(environment.OPENAI_API_KEY, selectedSecret);
  assert.equal(environment.ANTHROPIC_API_KEY, undefined);
  assert.equal(environment.GOOGLE_API_KEY, undefined);
  assert.equal(environment.UNRELATED_SECRET, undefined);
  assert.equal(environment.AEGIS_V2_MODEL, 'user-model');
  assert.equal(environment.AEGIS_V2_BASE_URL, 'https://models.example.test/v1');
  assert.equal(JSON.stringify(selection).includes(selectedSecret), false);
});

test('远端模型只允许 HTTPS，本机 HTTP 只允许数值 loopback', () => {
  const common = { AEGIS_V2_PROVIDER: 'gemini', AEGIS_V2_MODEL: 'user-model' };
  assert.throws(() => resolveModelSelection({
    sourceEnvironment: { ...common, AEGIS_V2_BASE_URL: 'http://models.example.test/v1' },
  }), /HTTPS/);
  assert.throws(() => resolveModelSelection({
    sourceEnvironment: { ...common, AEGIS_V2_BASE_URL: 'http://localhost:11434/v1' },
  }), /HTTPS/);
  assert.equal(resolveModelSelection({
    sourceEnvironment: { ...common, AEGIS_V2_BASE_URL: 'http://127.0.0.1:11434/v1' },
  }).baseUrl, 'http://127.0.0.1:11434/v1');
});

test('数值 loopback 本地 provider 不强制云密钥', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-local-model-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const runRoot = path.join(directory, 'run');
  const workingDirectory = path.join(runRoot, 'work');
  fs.mkdirSync(workingDirectory, { recursive: true });

  const { selection, environment } = buildSelectedModelEnvironment({
    sourceEnvironment: {
      PATH: '/usr/bin',
      AEGIS_V2_PROVIDER: 'openai',
      AEGIS_V2_MODEL: 'local-user-model',
      AEGIS_V2_BASE_URL: 'http://127.0.0.1:8080/v1',
    },
    runRoot,
    workingDirectory,
  });
  assert.equal(selection.local, true);
  assert.equal(selection.credentialRequired, false);
  assert.equal(environment.OPENAI_API_KEY, undefined);
});

test('同一评测组锁定当次用户选择，不限制下一组更换模型', () => {
  const first = resolveModelSelection({
    sourceEnvironment: { AEGIS_V2_PROVIDER: 'openai', AEGIS_V2_MODEL: 'model-a' },
  });
  const same = resolveModelSelection({
    sourceEnvironment: { AEGIS_V2_PROVIDER: 'openai', AEGIS_V2_MODEL: 'model-a' },
  });
  const other = resolveModelSelection({
    sourceEnvironment: { AEGIS_V2_PROVIDER: 'openai', AEGIS_V2_MODEL: 'model-b' },
  });

  assert.deepEqual(assertSameBenchmarkModel([first, same]), {
    provider: 'openai',
    model: 'model-a',
    baseUrl: null,
  });
  assert.throws(() => assertSameBenchmarkModel([first, other]), /相同的 provider\/model/);
});
