import fs from 'node:fs';
import path from 'node:path';
import {
  DEVELOPMENT_MODEL_KEY_NAMES,
  FORCED_ADAPTER_ENVIRONMENT,
} from './constants.mjs';

const SECRET_FIELD = /(?:api[_-]?key|authorization|cookie|password|passwd|secret|token|otp|credential)/i;
const SECRET_VALUE_PATTERNS = [
  /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi,
  /\bsk-ant-[A-Za-z0-9_-]{8,}/g,
  /\bsk-[A-Za-z0-9_-]{12,}/g,
  /\bAIza[A-Za-z0-9_-]{20,}/g,
];

export function assertPathWithin(basePath, targetPath, label = '路径') {
  const base = path.resolve(basePath);
  const target = path.resolve(targetPath);
  if (target === base || !target.startsWith(`${base}${path.sep}`)) {
    throw new Error(`${label}必须位于隔离目录内：${target}`);
  }
  return target;
}

export function assertIsolatedProfile(runRoot, profilePath) {
  const expectedRoot = path.join(path.resolve(runRoot), 'profile');
  const resolved = path.resolve(profilePath);
  if (resolved !== expectedRoot) {
    throw new Error(`Profile 必须是本次 run 的专用目录：${expectedRoot}`);
  }

  let cursor = resolved;
  while (cursor.startsWith(path.resolve(runRoot))) {
    if (fs.existsSync(cursor) && fs.lstatSync(cursor).isSymbolicLink()) {
      throw new Error(`Profile 路径不能包含符号链接：${cursor}`);
    }
    if (cursor === path.resolve(runRoot)) break;
    cursor = path.dirname(cursor);
  }
  return resolved;
}

function isPrivateIpv4(hostname) {
  const parts = hostname.split('.').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false;
  }
  return parts[0] === 10
    || parts[0] === 127
    || (parts[0] === 169 && parts[1] === 254)
    || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31)
    || (parts[0] === 192 && parts[1] === 168);
}

export function validateNavigationUrl(rawUrl, { allowedOrigins, fixtureOrigins = [] }) {
  if (rawUrl === 'about:blank') return new URL(rawUrl);

  const url = new URL(rawUrl);
  if (url.username || url.password) {
    throw new Error('URL 不得包含凭据');
  }
  if (url.protocol !== 'https:') {
    throw new Error(`只允许 HTTPS 或 about:blank：${url.protocol}`);
  }

  const allowed = new Set(allowedOrigins);
  if (!allowed.has(url.origin)) {
    throw new Error(`origin 不在 allowlist：${url.origin}`);
  }

  const fixture = new Set(fixtureOrigins);
  if ((url.hostname === 'localhost' || isPrivateIpv4(url.hostname)) && !fixture.has(url.origin)) {
    throw new Error(`私网地址只允许已登记 fixture：${url.origin}`);
  }
  return url;
}

export function redact(value, fieldName = '') {
  if (SECRET_FIELD.test(fieldName)) return '[REDACTED]';
  if (typeof value === 'string') {
    return SECRET_VALUE_PATTERNS.reduce(
      (result, pattern) => result.replace(pattern, '[REDACTED]'),
      value,
    );
  }
  if (Array.isArray(value)) return value.map((item) => redact(item));
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, child]) => [key, redact(child, key)]),
    );
  }
  return value;
}

export function assertNoEnvironmentFile(workingDirectory) {
  const entries = fs.readdirSync(workingDirectory);
  const environmentFile = entries.find((entry) => entry === '.env' || entry.startsWith('.env.'));
  if (environmentFile) {
    throw new Error(`隔离工作目录不得包含环境文件：${environmentFile}`);
  }
}

export function buildAdapterEnvironment({
  sourceEnvironment,
  runRoot,
  workingDirectory,
  modelKeyName,
}) {
  assertNoEnvironmentFile(workingDirectory);
  if (modelKeyName && !DEVELOPMENT_MODEL_KEY_NAMES.has(modelKeyName)) {
    throw new Error(`未批准的模型密钥变量：${modelKeyName}`);
  }

  const environment = {
    PATH: sourceEnvironment.PATH ?? '',
    LANG: sourceEnvironment.LANG ?? 'C.UTF-8',
    TMPDIR: sourceEnvironment.TMPDIR ?? '/tmp',
    NO_PROXY: '127.0.0.1,localhost',
    BROWSER_USE_CONFIG_DIR: path.join(runRoot, 'browser-use-config'),
    ...FORCED_ADAPTER_ENVIRONMENT,
  };

  if (modelKeyName) {
    const key = sourceEnvironment[modelKeyName];
    if (!key) throw new Error(`当前进程未提供 ${modelKeyName}`);
    environment[modelKeyName] = key;
  }
  return environment;
}
