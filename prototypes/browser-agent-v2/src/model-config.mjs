import { MODEL_PROVIDER_DEFINITIONS } from './constants.mjs';
import { buildAdapterEnvironment } from './security.mjs';

const MAX_MODEL_NAME_BYTES = 256;

function validateModelName(value) {
  const model = value?.trim();
  if (!model) throw new Error('必须由用户选择模型：AEGIS_V2_MODEL');
  if (Buffer.byteLength(model, 'utf8') > MAX_MODEL_NAME_BYTES || /[\u0000-\u001f\u007f]/u.test(model)) {
    throw new Error('AEGIS_V2_MODEL 格式无效');
  }
  return model;
}

function normalizeBaseUrl(value) {
  const raw = value?.trim();
  if (!raw) return null;

  const url = new URL(raw);
  if (url.username || url.password || url.search || url.hash) {
    throw new Error('AEGIS_V2_BASE_URL 不得包含凭据、query 或 fragment');
  }
  const numericLoopback = url.hostname === '127.0.0.1' || url.hostname === '[::1]';
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && numericLoopback)) {
    throw new Error('模型服务必须使用 HTTPS；HTTP 只允许数值 loopback');
  }
  return raw;
}

export function resolveModelSelection({
  sourceEnvironment = process.env,
  requireCredential = false,
} = {}) {
  const rawProvider = sourceEnvironment.AEGIS_V2_PROVIDER?.trim();
  const rawModel = sourceEnvironment.AEGIS_V2_MODEL?.trim();
  const rawBaseUrl = sourceEnvironment.AEGIS_V2_BASE_URL?.trim();

  if (!rawProvider && !rawModel && !rawBaseUrl) {
    return Object.freeze({
      configured: false,
      provider: null,
      model: null,
      baseUrl: null,
      credentialAvailable: false,
    });
  }

  if (!rawProvider) throw new Error('必须由用户选择 provider：AEGIS_V2_PROVIDER');
  const provider = rawProvider.toLowerCase();
  const definition = MODEL_PROVIDER_DEFINITIONS[provider];
  if (!definition) throw new Error(`不支持的 provider API 格式：${rawProvider}`);

  const model = validateModelName(rawModel);
  const baseUrl = normalizeBaseUrl(rawBaseUrl);
  const credentialAvailable = Boolean(sourceEnvironment[definition.environmentVariable]);
  if (requireCredential && !credentialAvailable) {
    throw new Error(`当前进程未提供所选 provider 的开发凭据：${definition.environmentVariable}`);
  }

  return Object.freeze({
    configured: true,
    provider,
    model,
    baseUrl,
    credentialAvailable,
  });
}

export function buildSelectedModelEnvironment({
  sourceEnvironment = process.env,
  runRoot,
  workingDirectory,
}) {
  const selection = resolveModelSelection({ sourceEnvironment, requireCredential: true });
  const definition = MODEL_PROVIDER_DEFINITIONS[selection.provider];
  const environment = buildAdapterEnvironment({
    sourceEnvironment,
    runRoot,
    workingDirectory,
    modelKeyName: definition.environmentVariable,
  });

  environment.AEGIS_V2_PROVIDER = selection.provider;
  environment.AEGIS_V2_MODEL = selection.model;
  if (selection.baseUrl) environment.AEGIS_V2_BASE_URL = selection.baseUrl;
  return { selection, environment };
}

export function assertSameBenchmarkModel(selections) {
  const configured = selections.filter((selection) => selection?.configured);
  if (configured.length !== selections.length || configured.length === 0) {
    throw new Error('对比组中的每个 adapter 都必须有用户选择的 provider/model');
  }
  const expected = configured[0];
  const mismatch = configured.find((selection) => (
    selection.provider !== expected.provider
    || selection.model !== expected.model
    || selection.baseUrl !== expected.baseUrl
  ));
  if (mismatch) throw new Error('同一对比组必须锁定相同的 provider/model/base URL');
  return Object.freeze({
    provider: expected.provider,
    model: expected.model,
    baseUrl: expected.baseUrl,
  });
}
