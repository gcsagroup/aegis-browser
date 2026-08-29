#!/usr/bin/env node

import {execFile, spawn} from 'node:child_process';
import {
  createHash,
  createHmac,
  randomBytes,
  randomInt,
  randomUUID,
} from 'node:crypto';
import {Resolver as DnsResolver} from 'node:dns/promises';
import {createReadStream, constants as fsConstants} from 'node:fs';
import {
  access,
  link,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  readdir,
  rm,
  rmdir,
  stat,
  unlink,
  writeFile,
} from 'node:fs/promises';
import {createServer as createHttpServer} from 'node:http';
import {
  connect as netConnect,
  createServer as createNetServer,
  isIP,
} from 'node:net';
import {homedir, tmpdir} from 'node:os';
import {
  basename,
  dirname,
  join,
  relative,
  resolve,
  sep,
} from 'node:path';
import process from 'node:process';
import {fileURLToPath} from 'node:url';

const RUNNER_ENTRY_PATH = fileURLToPath(import.meta.url);
const BROWSER_ROOT = resolve(dirname(RUNNER_ENTRY_PATH), '..');
const DEFAULT_MANIFEST = join(
  BROWSER_ROOT,
  'config',
  'script-risk-shadow-protocol-v1.json',
);
const BUILD_IDENTITY_SCRIPT = join(
  BROWSER_ROOT,
  'scripts',
  'write-build-identity.mjs',
);
const MANIFEST_SCHEMA = 'gcsa-aegis-script-risk-shadow-protocol-v1';
const REPORT_SCHEMA = 'gcsa-aegis-script-risk-shadow-report-v1';
const TRACE_CATEGORY = 'disabled-by-default-v8.aegis.bytecode_shadow';
const TRACE_EVENT_NAME = 'V8.AegisBytecodeShadow';
const TRACE_ARGUMENT_NAMES = [
  'bytes',
  'mode_code',
  'opcodes',
  'record_schema',
  'signature_hi',
  'signature_lo',
  'signature_schema',
  'status_code',
  'would_block',
];
const PROFILE_PREFIX = 'aegis-bytecode-shadow-site-';
const POLL_INTERVAL_MS = 100;
const CLEANUP_GRACE_MS = 5_000;
const CLEANUP_KILL_MS = 3_000;
const DIAGNOSTIC_CAPTURE_LIMIT = 4 * 1024 * 1024;
const GLOBAL_CRASH_OBSERVATION_MS = 3_000;
const PLAINTEXT_REQUEST_CLASSES = [
  'absolute-http',
  'absolute-https',
  'asterisk-form',
  'authority-form',
  'origin-form',
  'other',
];
const DENIED_CONNECT_REASONS = [
  'invalid-authority',
  'resolution-failed',
  'other',
];
const REPORTABLE_CDP_METHODS = new Set([
  'Browser.setDownloadBehavior',
  'Inspector.enable',
  'Network.enable',
  'Page.enable',
  'Page.getFrameTree',
  'Runtime.enable',
  'Runtime.evaluate',
  'Runtime.runIfWaitingForDebugger',
  'SystemInfo.getProcessInfo',
  'Target.createTarget',
  'Target.detachFromTarget',
  'Target.getTargets',
  'Target.setAutoAttach',
  'Target.setDiscoverTargets',
  'Tracing.end',
  'Tracing.start',
]);
const ACTIVE_CHILDREN = new Set();
let requestedSignal = null;

class VerificationError extends Error {
  constructor(code, message, cdpMethod = null) {
    super(message);
    this.name = 'VerificationError';
    this.code = code;
    this.cdpMethod = REPORTABLE_CDP_METHODS.has(cdpMethod)
      ? cdpMethod
      : null;
  }
}

function fail(code, message) {
  throw new VerificationError(code, message);
}

function assert(condition, code, message) {
  if (!condition) {
    fail(code, message);
  }
}

function errorCode(error) {
  return error instanceof VerificationError ? error.code : 'internal-error';
}

function errorCdpMethod(error) {
  return error instanceof VerificationError ? error.cdpMethod : null;
}

function canonical(value) {
  return JSON.stringify(value);
}

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

function sha256Bytes(value) {
  return createHash('sha256').update(value).digest('hex');
}

function sha256File(path) {
  return new Promise((resolveHash, rejectHash) => {
    const hash = createHash('sha256');
    const stream = createReadStream(path);
    stream.on('error', rejectHash);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolveHash(hash.digest('hex')));
  });
}

function fileIdentity(metadata) {
  return {
    ctimeMs: metadata.ctimeMs,
    dev: metadata.dev,
    ino: metadata.ino,
    mtimeMs: metadata.mtimeMs,
    size: metadata.size,
  };
}

async function captureRunnerIdentity(path = RUNNER_ENTRY_PATH) {
  try {
    const runnerPath = await realpath(path);
    const before = await stat(runnerPath);
    assert(
      before.isFile(),
      'runner-identity-invalid',
      'runner 不是普通文件',
    );
    const runnerSha256 = await sha256File(runnerPath);
    const after = await stat(runnerPath);
    assert(
      canonical(fileIdentity(before)) ===
        canonical(fileIdentity(after)),
      'runner-identity-invalid',
      'runner 在摘要期间发生变化',
    );
    return {
      fileIdentity: fileIdentity(after),
      realPath: runnerPath,
      runnerSha256,
    };
  } catch (error) {
    if (error instanceof VerificationError) throw error;
    fail('runner-identity-invalid', '无法固定 runner 身份');
  }
}

function runnerReportEvidence(before, after) {
  const verified = Boolean(after);
  const stable =
    verified &&
    before.realPath === after.realPath &&
    before.runnerSha256 === after.runnerSha256 &&
    canonical(before.fileIdentity) === canonical(after.fileIdentity);
  return {
    runnerSha256: before.runnerSha256,
    stable,
    verified,
  };
}

async function reverifyRunnerIdentity(
  before,
  path = RUNNER_ENTRY_PATH,
  capture = captureRunnerIdentity,
) {
  try {
    return runnerReportEvidence(before, await capture(path));
  } catch {
    return runnerReportEvidence(before, null);
  }
}

function runnerEvidenceForReport(evidence) {
  assert(
    evidence &&
      typeof evidence === 'object' &&
      canonical(Object.keys(evidence).sort()) ===
        canonical(['runnerSha256', 'stable', 'verified']) &&
      /^[0-9a-f]{64}$/u.test(evidence.runnerSha256) &&
      typeof evidence.stable === 'boolean' &&
      typeof evidence.verified === 'boolean',
    'runner-evidence-invalid',
    'runner 报告证据字段无效',
  );
  return {
    runnerSha256: evidence.runnerSha256,
    stable: evidence.stable,
    verified: evidence.verified,
  };
}

function assertStableRunner(evidence) {
  const record = runnerEvidenceForReport(evidence);
  assert(
    record.verified === true && record.stable === true,
    'runner-mutated',
    'runner 在批次期间发生变化或无法复核',
  );
}

function printUsage() {
  process.stdout.write(
    [
      '用法：',
      '  node apps/browser/scripts/verify-bytecode-shadow-sites-runtime.mjs [选项]',
      '',
      '离线选项：',
      '  --manifest PATH              显式站点 manifest；默认使用仓库 protocol v1',
      '  --print-manifest-sha256      只校验 manifest 并打印确认所需摘要',
      '  --self-test                  运行参数、隐私、trace、归类和清理自测',
      '  --help                       显示帮助',
      '',
      '真实研究选项：',
      '  --app PATH                   被测 Chromium.app',
      '  --binary PATH                被测可执行文件；与 --app 二选一',
      '  --report PATH                JSON 报告；必须不存在，拒绝覆盖',
      '  --hmac-key-file PATH         恰好 32 字节且权限不宽于 0600 的批次密钥',
      '  --confirm-live-network SHA   必须等于 manifest SHA-256',
      '  --build-identity PATH        schema v3 构建身份清单；真实模式必填',
      '  --build-identity-sha256 SHA  调用方固定的构建身份摘要；真实模式必填',
      '  --pilot                      使用 manifest pilot 范围',
      '  --full                       使用全部站点和 fullRounds',
      '',
      'A=关闭 AegisBytecodeShadow，B=开启；每个站点、模式和轮次都启动独立',
      '临时 Profile 与浏览器进程。A/B 都采集同一默认关闭的 Perfetto 分类。',
      '报告只保留批次内 HMAC 标识和聚合，不保存站点、页面标题、进程标识、',
      'bytecode 签名、原始 trace 或原始诊断输出。该工具固定为 research-only，',
      '真实批次通过时向 stdout 返回退出码 2；不通过时向 stderr 返回退出码 1。',
      '两者都不能作为发布资格。',
      '',
    ].join('\n'),
  );
}

function parseArgs(argv) {
  const options = {
    app: null,
    binary: null,
    buildIdentity: null,
    buildIdentitySha256: null,
    confirmLiveNetwork: null,
    help: false,
    hmacKeyFile: null,
    manifest: DEFAULT_MANIFEST,
    pilot: null,
    printManifestSha256: false,
    report: null,
    selfTest: false,
  };
  const valueAfter = (index, option) => {
    const value = argv[index + 1];
    assert(
      value && !value.startsWith('--'),
      'invalid-arguments',
      option + ' 缺少值',
    );
    return value;
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--app') {
      options.app = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--binary') {
      options.binary = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--manifest') {
      options.manifest = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--build-identity') {
      options.buildIdentity = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--build-identity-sha256') {
      options.buildIdentitySha256 = valueAfter(index, argument);
      index += 1;
      assert(
        /^[0-9a-f]{64}$/u.test(options.buildIdentitySha256),
        'invalid-arguments',
        '--build-identity-sha256 必须是 64 位小写 SHA-256',
      );
    } else if (argument === '--report') {
      options.report = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--hmac-key-file') {
      options.hmacKeyFile = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--confirm-live-network') {
      options.confirmLiveNetwork = valueAfter(index, argument);
      index += 1;
      assert(
        /^[0-9a-f]{64}$/u.test(options.confirmLiveNetwork),
        'invalid-arguments',
        '--confirm-live-network 必须是 64 位小写 SHA-256',
      );
    } else if (argument === '--pilot') {
      assert(
        options.pilot !== false,
        'invalid-arguments',
        '--pilot 与 --full 不能同时使用',
      );
      options.pilot = true;
    } else if (argument === '--full') {
      assert(
        options.pilot !== true,
        'invalid-arguments',
        '--pilot 与 --full 不能同时使用',
      );
      options.pilot = false;
    } else if (argument === '--print-manifest-sha256') {
      options.printManifestSha256 = true;
    } else if (argument === '--self-test') {
      options.selfTest = true;
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else if (argument === '--') {
      continue;
    } else {
      fail('invalid-arguments', '未知参数：' + argument);
    }
  }

  assert(
    !(options.app && options.binary),
    'invalid-arguments',
    '--app 与 --binary 只能提供一个',
  );
  assert(
    Boolean(options.buildIdentity) ===
      Boolean(options.buildIdentitySha256),
    'invalid-arguments',
    '--build-identity 与 --build-identity-sha256 必须同时提供',
  );
  assert(
    !(options.selfTest && options.printManifestSha256),
    'invalid-arguments',
    '--self-test 与 --print-manifest-sha256 不能同时使用',
  );
  return options;
}

function assertExactKeys(value, expected, label) {
  assert(
    value && typeof value === 'object' && !Array.isArray(value),
    'manifest-invalid',
    label + ' 必须是对象',
  );
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  assert(
    canonical(actual) === canonical(wanted),
    'manifest-invalid',
    label + ' 字段集合不符合 protocol v1',
  );
}

function isPublicIpv4(address) {
  const parts = address.split('.').map(Number);
  if (
    parts.length !== 4 ||
    parts.some(
      (part) => !Number.isSafeInteger(part) || part < 0 || part > 255,
    )
  ) {
    return false;
  }
  const [a, b, c] = parts;
  if (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 192 && b === 88 && c === 99) ||
    (a === 198 && (b === 18 || b === 19))
  ) {
    return false;
  }
  if (
    (a === 192 && b === 0 && (c === 0 || c === 2)) ||
    (a === 198 && b === 51 && c === 100) ||
    (a === 203 && b === 0 && c === 113)
  ) {
    return false;
  }
  return true;
}

function ipv6Words(address) {
  let normalized = address.toLowerCase().split('%')[0];
  const dotted = normalized.match(/(\d+\.\d+\.\d+\.\d+)$/u);
  if (dotted) {
    if (!isPublicIpv4(dotted[1]) && isIP(dotted[1]) !== 4) return null;
    const parts = dotted[1].split('.').map(Number);
    const replacement =
      ((parts[0] << 8) | parts[1]).toString(16) +
      ':' +
      ((parts[2] << 8) | parts[3]).toString(16);
    normalized = normalized.slice(0, -dotted[1].length) + replacement;
  }
  const halves = normalized.split('::');
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const fill = halves.length === 2 ? 8 - left.length - right.length : 0;
  if (
    fill < (halves.length === 2 ? 1 : 0) ||
    left.length + right.length + fill !== 8
  ) {
    return null;
  }
  const words = [
    ...left,
    ...Array(fill).fill('0'),
    ...right,
  ].map((word) =>
    /^[0-9a-f]{1,4}$/u.test(word) ? Number.parseInt(word, 16) : Number.NaN,
  );
  return words.every((word) => Number.isSafeInteger(word)) ? words : null;
}

function mappedIpv4(words) {
  if (
    words.slice(0, 5).every((word) => word === 0) &&
    words[5] === 0xffff
  ) {
    return [
      words[6] >>> 8,
      words[6] & 0xff,
      words[7] >>> 8,
      words[7] & 0xff,
    ].join('.');
  }
  return null;
}

function isPublicIpv6(address) {
  const words = ipv6Words(address);
  if (!words) return false;
  const mapped = mappedIpv4(words);
  if (mapped) return isPublicIpv4(mapped);
  const allZero = words.every((word) => word === 0);
  const loopback =
    words.slice(0, 7).every((word) => word === 0) && words[7] === 1;
  const globalUnicast = words[0] >= 0x2000 && words[0] <= 0x3fff;
  const transitionOrSpecial =
    (words[0] === 0x2001 && words[1] < 0x0200) ||
    words[0] === 0x2002;
  const documentation = words[0] === 0x2001 && words[1] === 0x0db8;
  const documentationV2 =
    words[0] === 0x3fff && (words[1] & 0xf000) === 0;
  return (
    globalUnicast &&
    !transitionOrSpecial &&
    !documentation &&
    !documentationV2 &&
    !allZero &&
    !loopback
  );
}

function isPublicAddress(address) {
  const version = isIP(address);
  if (version === 4) return isPublicIpv4(address);
  if (version === 6) return isPublicIpv6(address);
  return false;
}

function validPublicDnsHostname(hostname) {
  return (
    typeof hostname === 'string' &&
    hostname.length >= 3 &&
    hostname.length <= 253 &&
    isIP(hostname) === 0 &&
    hostname.includes('.') &&
    /^[a-z0-9.-]+$/u.test(hostname) &&
    !hostname.startsWith('.') &&
    !hostname.endsWith('.') &&
    !hostname.includes('..') &&
    !hostname.endsWith('.local') &&
    hostname !== 'localhost' &&
    hostname.split('.').every(
      (label) =>
        label.length >= 1 &&
        label.length <= 63 &&
        !label.startsWith('-') &&
        !label.endsWith('-'),
    )
  );
}

function validatePublicRootUrl(value) {
  assert(
    typeof value === 'string' && value.length <= 2048,
    'manifest-invalid',
    '站点地址必须是有限长度字符串',
  );
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    fail('manifest-invalid', '站点地址不是有效 URL');
  }
  assert(
    parsed.protocol === 'https:' &&
      parsed.username === '' &&
      parsed.password === '' &&
      parsed.port === '' &&
      parsed.pathname === '/' &&
      parsed.search === '' &&
      parsed.hash === '',
    'manifest-invalid',
    '站点只允许无凭据、无端口、无 query/fragment 的 HTTPS 根页',
  );
  assert(
    parsed.href === value,
    'manifest-invalid',
    '站点地址必须使用 URL 规范形式并保留结尾斜杠',
  );
  assert(
    validPublicDnsHostname(parsed.hostname),
    'manifest-invalid',
    '站点必须使用公开 DNS 主机名',
  );
  return parsed;
}

function validateManifest(document) {
  assertExactKeys(
    document,
    [
      'schema',
      'qualification',
      'releaseEligible',
      'networkPolicy',
      'telemetry',
      'execution',
      'pilot',
      'sites',
    ],
    'manifest',
  );
  assert(
    document.schema === MANIFEST_SCHEMA &&
      document.qualification === 'research-only' &&
      document.releaseEligible === false,
    'manifest-invalid',
    'manifest 研究边界无效',
  );
  assertExactKeys(
    document.networkPolicy,
    [
      'publicHttpsRootOnly',
      'confirmationBinding',
      'derivedRequests',
      'resolver',
    ],
    'networkPolicy',
  );
  assert(
    document.networkPolicy.publicHttpsRootOnly === true &&
      document.networkPolicy.confirmationBinding === 'manifest-sha256' &&
      document.networkPolicy.derivedRequests ===
        'public-https-via-pinned-connect-proxy',
    'manifest-invalid',
    'manifest 网络策略无效',
  );
  assertExactKeys(
    document.networkPolicy.resolver,
    ['mode', 'servers', 'recordTypes'],
    'networkPolicy.resolver',
  );
  assert(
    document.networkPolicy.resolver.mode === 'validated-direct-dns' &&
      canonical(document.networkPolicy.resolver.servers) ===
        canonical(['1.1.1.1']) &&
      canonical(document.networkPolicy.resolver.recordTypes) ===
        canonical(['A']),
    'manifest-invalid',
    'manifest DNS resolver 策略无效',
  );
  assertExactKeys(
    document.telemetry,
    [
      'category',
      'eventName',
      'recordMode',
      'bufferSizeKiB',
      'maxRecordsPerProcess',
      'candidateRecordLimit',
    ],
    'telemetry',
  );
  assert(
    document.telemetry.category === TRACE_CATEGORY &&
      document.telemetry.eventName === TRACE_EVENT_NAME &&
      document.telemetry.recordMode === 'record-until-full',
    'manifest-invalid',
    'manifest trace 协议无效',
  );
  assert(
    Number.isSafeInteger(document.telemetry.bufferSizeKiB) &&
      document.telemetry.bufferSizeKiB >= 32 * 1024 &&
      document.telemetry.bufferSizeKiB <= 128 * 1024,
    'manifest-invalid',
    'trace buffer 必须在 32 至 128 MiB',
  );
  assert(
    Number.isSafeInteger(document.telemetry.maxRecordsPerProcess) &&
      document.telemetry.maxRecordsPerProcess >= 1 &&
      document.telemetry.maxRecordsPerProcess <= 1_000,
    'manifest-invalid',
    'maxRecordsPerProcess 必须在 1 至 V8 硬上限 1000',
  );
  assert(
    Number.isSafeInteger(document.telemetry.candidateRecordLimit) &&
      document.telemetry.candidateRecordLimit >=
        document.telemetry.maxRecordsPerProcess &&
      document.telemetry.candidateRecordLimit <= 100_000,
    'manifest-invalid',
    'candidateRecordLimit 无效',
  );
  assertExactKeys(
    document.execution,
    [
      'defaultPilot',
      'pairOrders',
      'fullRounds',
      'timeoutMs',
      'settleMs',
    ],
    'execution',
  );
  assert(
    typeof document.execution.defaultPilot === 'boolean' &&
      canonical(document.execution.pairOrders) === canonical(['AB', 'BA']),
    'manifest-invalid',
    'protocol v1 固定使用 AB/BA 配对',
  );
  assert(
    Number.isSafeInteger(document.execution.fullRounds) &&
      document.execution.fullRounds >= 1 &&
      document.execution.fullRounds <= 10,
    'manifest-invalid',
    'fullRounds 必须在 1 至 10',
  );
  assert(
    Number.isSafeInteger(document.execution.timeoutMs) &&
      document.execution.timeoutMs >= 10_000 &&
      document.execution.timeoutMs <= 180_000,
    'manifest-invalid',
    'timeoutMs 必须在 10000 至 180000',
  );
  assert(
    Number.isSafeInteger(document.execution.settleMs) &&
      document.execution.settleMs >= 0 &&
      document.execution.settleMs <= 30_000,
    'manifest-invalid',
    'settleMs 必须在 0 至 30000',
  );
  assertExactKeys(document.pilot, ['maxSites', 'rounds'], 'pilot');
  assert(
    Number.isSafeInteger(document.pilot.maxSites) &&
      document.pilot.maxSites >= 1 &&
      document.pilot.maxSites <= 10 &&
      Number.isSafeInteger(document.pilot.rounds) &&
      document.pilot.rounds >= 1 &&
      document.pilot.rounds <= 3,
    'manifest-invalid',
    'pilot 范围无效',
  );
  assert(
    Array.isArray(document.sites) &&
      document.sites.length >= 1 &&
      document.sites.length <= 50,
    'manifest-invalid',
    'sites 数量必须在 1 至 50',
  );
  const canonicalSites = [];
  for (const [index, site] of document.sites.entries()) {
    assertExactKeys(site, ['url'], 'sites[' + index + ']');
    canonicalSites.push(validatePublicRootUrl(site.url).href);
  }
  assert(
    new Set(canonicalSites).size === canonicalSites.length,
    'manifest-invalid',
    'sites 不得重复',
  );
  assert(
    document.pilot.maxSites <= canonicalSites.length,
    'manifest-invalid',
    'pilot.maxSites 不得超过站点数',
  );
  return document;
}

async function loadManifest(path) {
  const metadata = await stat(path).catch(() => null);
  assert(
    metadata && metadata.isFile(),
    'manifest-invalid',
    'manifest 文件不存在',
  );
  const bytes = await readFile(path);
  let document;
  try {
    document = JSON.parse(bytes.toString('utf8'));
  } catch {
    fail('manifest-invalid', 'manifest 不是有效 JSON');
  }
  validateManifest(document);
  return {
    bytes,
    document,
    sha256: sha256Bytes(bytes),
  };
}

function validateLiveOptions(options, manifestSha256) {
  assert(
    Boolean(options.app) !== Boolean(options.binary),
    'invalid-arguments',
    '真实模式必须指定 --app 或 --binary',
  );
  assert(
    Boolean(options.report),
    'invalid-arguments',
    '真实模式必须指定 --report',
  );
  assert(
    Boolean(options.hmacKeyFile),
    'invalid-arguments',
    '真实模式必须指定 --hmac-key-file',
  );
  assert(
    Boolean(options.buildIdentity) &&
      Boolean(options.buildIdentitySha256),
    'invalid-arguments',
    '真实模式必须固定 --build-identity 与摘要',
  );
  assert(
    options.confirmLiveNetwork === manifestSha256,
    'network-confirmation-required',
    '--confirm-live-network 必须精确等于当前 manifest SHA-256',
  );
}

function appAncestor(path) {
  let cursor = resolve(path);
  while (true) {
    if (basename(cursor).endsWith('.app')) return cursor;
    const parent = dirname(cursor);
    if (parent === cursor) return null;
    cursor = parent;
  }
}

async function resolveTarget(options) {
  let appPath = options.app;
  let executable = options.binary;
  if (appPath) {
    const metadata = await stat(appPath).catch(() => null);
    assert(
      metadata && metadata.isDirectory(),
      'target-invalid',
      'Chromium.app 不存在',
    );
    appPath = await realpath(appPath);
    executable = join(appPath, 'Contents', 'MacOS', 'Chromium');
  }
  const metadata = await stat(executable).catch(() => null);
  assert(
    metadata && metadata.isFile(),
    'target-invalid',
    'Chromium 可执行文件不存在',
  );
  await access(executable, fsConstants.X_OK).catch(() => {
    fail('target-invalid', 'Chromium 不可执行');
  });
  executable = await realpath(executable);
  appPath = appPath || appAncestor(executable);
  if (appPath) appPath = await realpath(appPath);
  return {
    appPath,
    executable,
    inputKind: options.app ? 'app' : 'binary',
  };
}

function pathIsWithin(root, candidate) {
  const suffix = relative(root, candidate);
  return suffix === '' || (!suffix.startsWith('..' + sep) && suffix !== '..');
}

async function canonicalPotentialPath(path) {
  const missing = [];
  let cursor = resolve(path);
  while (true) {
    try {
      const existing = await realpath(cursor);
      return resolve(existing, ...missing.reverse());
    } catch (error) {
      if (error && error.code !== 'ENOENT') throw error;
      const parent = dirname(cursor);
      assert(
        parent !== cursor,
        'report-invalid',
        '无法解析报告路径',
      );
      missing.push(basename(cursor));
      cursor = parent;
    }
  }
}

async function validateReportPath(options, target, runnerPath) {
  const existing = await lstat(options.report).catch((error) => {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  });
  assert(
    existing === null,
    'report-exists',
    '--report 已存在；拒绝覆盖既有证据',
  );
  const reportPath = await canonicalPotentialPath(options.report);
  const protectedPaths = [
    target.executable,
    options.manifest,
    options.hmacKeyFile,
    options.buildIdentity,
    options.buildIdentity + '.sha256',
    runnerPath,
  ];
  for (const path of protectedPaths) {
    const canonicalPath = await canonicalPotentialPath(path);
    assert(
      reportPath !== canonicalPath,
      'report-invalid',
      '--report 不得覆盖输入或被测文件',
    );
  }
  if (target.appPath) {
    assert(
      !pathIsWithin(target.appPath, reportPath),
      'report-invalid',
      '--report 不得位于被测 App 内',
    );
    const buildLockPath = await canonicalPotentialPath(
      join(dirname(target.appPath), '.aegis', 'build.lock'),
    );
    assert(
      reportPath !== buildLockPath &&
        !pathIsWithin(buildLockPath, reportPath) &&
        !pathIsWithin(reportPath, buildLockPath),
      'report-invalid',
      '--report 不得与构建身份锁路径重叠',
    );
  }
  return reportPath;
}

async function writeJsonExclusive(path, value, commitGuard) {
  await mkdir(dirname(path), {recursive: true});
  const temporary = join(
    dirname(path),
    '.' + basename(path) + '.' + process.pid + '.' + randomUUID() + '.tmp',
  );
  await writeFile(temporary, JSON.stringify(value, null, 2) + '\n', {
    encoding: 'utf8',
    flag: 'wx',
    mode: 0o600,
  });
  try {
    if (commitGuard) commitGuard();
    await link(temporary, path);
  } catch (error) {
    if (error && error.code === 'EEXIST') {
      fail('report-exists', '拒绝覆盖既有证据');
    }
    throw error;
  } finally {
    await unlink(temporary).catch(() => {});
  }
}

async function readHmacKey(path) {
  const linkMetadata = await lstat(path).catch(() => null);
  assert(
    linkMetadata && linkMetadata.isFile() && !linkMetadata.isSymbolicLink(),
    'hmac-key-invalid',
    'HMAC 密钥必须是普通文件且不能是符号链接',
  );
  assert(
    (linkMetadata.mode & 0o077) === 0,
    'hmac-key-invalid',
    'HMAC 密钥权限不得向组或其他用户开放',
  );
  const key = await readFile(path);
  assert(
    key.length === 32,
    'hmac-key-invalid',
    'HMAC 密钥必须恰好 32 字节',
  );
  return key;
}

async function runBuildIdentityVerifier(args) {
  const outcome = await execFileOutcome(process.execPath, [
    BUILD_IDENTITY_SCRIPT,
    ...args,
  ]);
  assert(
    outcome.passed,
    'build-identity-invalid',
    '构建身份验证器执行失败',
  );
  return outcome.stdout;
}

async function verifyBuildIdentity(options, target, runner) {
  assert(
    target.appPath,
    'build-identity-invalid',
    '被测 binary 必须位于 Chromium.app 内',
  );
  const output = await (runner || runBuildIdentityVerifier)([
    '--phase',
    'verify',
    '--manifest',
    options.buildIdentity,
    '--expected-sha256',
    options.buildIdentitySha256,
    '--out-dir',
    dirname(target.appPath),
    '--artifact',
    target.appPath,
  ]);
  let verification;
  try {
    verification = JSON.parse(output);
  } catch {
    fail('build-identity-invalid', '构建身份验证器返回无效 JSON');
  }
  assert(
    verification &&
      verification.verified === true &&
      verification.manifest &&
      verification.manifest.sha256 === options.buildIdentitySha256 &&
      verification.checks &&
      verification.checks.pinnedManifestDigest === true &&
      (verification.qualification === 'candidate' ||
        verification.qualification === 'diagnostic-only'),
    'build-identity-invalid',
    '构建身份未绑定调用方固定摘要',
  );
  return {
    manifestSha256: verification.manifest.sha256,
    qualification: verification.qualification,
    verified: true,
  };
}

async function acquireBuildOperationLock(target) {
  assert(
    target.appPath,
    'build-identity-invalid',
    '构建身份锁要求 Chromium.app 目标',
  );
  const lockParent = join(dirname(target.appPath), '.aegis');
  await mkdir(lockParent, {recursive: true});
  const lockPath = join(lockParent, 'build.lock');
  try {
    await mkdir(lockPath);
  } catch (error) {
    if (error && error.code === 'EEXIST') {
      fail('build-lock-busy', '构建、打包或验证锁已被占用');
    }
    throw error;
  }
  let released = false;
  return async () => {
    if (released) return;
    await rmdir(lockPath);
    released = true;
  };
}

function batchHmacId(key, salt, domain, value) {
  return createHmac('sha256', key)
    .update(domain, 'utf8')
    .update(Buffer.from([0]))
    .update(salt)
    .update(Buffer.from([0]))
    .update(value, 'utf8')
    .digest('hex')
    .slice(0, 32);
}

async function resolvePublicHostname(hostname, resolver) {
  assert(
    validPublicDnsHostname(hostname),
    'egress-denied',
    '代理目标不是公开 DNS 主机名',
  );
  assert(
    typeof resolver === 'function',
    'public-resolution-failed',
    '未配置显式 DNS resolver',
  );
  const results = await resolver(hostname).catch(() => {
    fail('public-resolution-failed', '公开站点 DNS 解析失败');
  });
  assert(
    Array.isArray(results) && results.length > 0,
    'public-resolution-failed',
    '公开站点 DNS 没有返回地址',
  );
  for (const result of results) {
    assert(
      result &&
        result.family === 4 &&
        isPublicIpv4(result.address),
      'public-resolution-failed',
      '站点解析到了非公开 IPv4 地址',
    );
  }
  return [...new Map(results.map((entry) => [entry.address, entry])).values()];
}

function createValidatedDirectDnsResolver(
  resolverPolicy,
  createResolver = () => new DnsResolver(),
) {
  let directResolver;
  try {
    directResolver = createResolver();
    directResolver.setServers([...resolverPolicy.servers]);
  } catch {
    fail('public-resolution-failed', '无法配置显式 DNS resolver');
  }
  assert(
    directResolver && typeof directResolver.resolve4 === 'function',
    'public-resolution-failed',
    '显式 DNS resolver 不支持 A 记录解析',
  );
  return async (hostname) => {
    let addresses;
    try {
      addresses = await directResolver.resolve4(hostname);
    } catch {
      fail('public-resolution-failed', '公开站点 DNS 解析失败');
    }
    assert(
      Array.isArray(addresses) && addresses.length > 0,
      'public-resolution-failed',
      '公开站点 DNS 没有返回地址',
    );
    return addresses.map((address) => ({address, family: 4}));
  };
}

async function resolvePublicSite(value, resolver) {
  const parsed = validatePublicRootUrl(value);
  const results = await resolvePublicHostname(parsed.hostname, resolver);
  return {addressCount: results.length};
}

async function resolveProxyDestination(authority, resolver) {
  const match =
    typeof authority === 'string'
      ? authority.match(/^([a-z0-9.-]+):443$/iu)
      : null;
  assert(
    match && validPublicDnsHostname(match[1].toLowerCase()),
    'egress-denied',
    'CONNECT 只允许公开 DNS 主机名的 443 端口',
  );
  const hostname = match[1].toLowerCase();
  const addresses = await resolvePublicHostname(hostname, resolver);
  const selected = addresses[0];
  return {
    address: selected.address,
    family: selected.family,
    hostname,
    port: 443,
  };
}

function emptyPlaintextRequestClassCounts() {
  return Object.fromEntries(
    PLAINTEXT_REQUEST_CLASSES.map((requestClass) => [requestClass, 0]),
  );
}

function emptyDeniedConnectReasonCounts() {
  return Object.fromEntries(
    DENIED_CONNECT_REASONS.map((reason) => [reason, 0]),
  );
}

function classifyDeniedConnectReason(error) {
  if (errorCode(error) === 'egress-denied') return 'invalid-authority';
  if (errorCode(error) === 'public-resolution-failed') {
    return 'resolution-failed';
  }
  return 'other';
}

function classifyPlaintextRequestTarget(value) {
  if (typeof value !== 'string') return 'other';
  if (/^http:\/\//iu.test(value)) return 'absolute-http';
  if (/^https:\/\//iu.test(value)) return 'absolute-https';
  if (value === '*') return 'asterisk-form';
  if (/^[a-z0-9.-]+:\d+$/iu.test(value)) return 'authority-form';
  if (value.startsWith('/')) return 'origin-form';
  return 'other';
}

async function startPublicHttpsProxy(resolver, connector) {
  const connectSocket = connector || netConnect;
  const pendingConnectTasks = new Set();
  const sockets = new Set();
  let closing = false;
  const evidence = {
    allowedConnectCount: 0,
    deniedConnectCount: 0,
    deniedConnectReasonCounts: emptyDeniedConnectReasonCounts(),
    deniedPlaintextRequestCount: 0,
    pinnedResolutionCount: 0,
    plaintextRequestClassCounts: emptyPlaintextRequestClassCounts(),
    plaintextRequestCount: 0,
    upstreamErrorCount: 0,
  };
  const server = createHttpServer((request, response) => {
    const requestClass = classifyPlaintextRequestTarget(request.url);
    evidence.plaintextRequestCount += 1;
    evidence.deniedPlaintextRequestCount += 1;
    evidence.plaintextRequestClassCounts[requestClass] += 1;
    response.writeHead(403, {'Content-Type': 'text/plain'});
    response.end('HTTPS CONNECT required');
  });
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('error', () => {
      // 对端可在代理清理或 TLS 隧道关闭时提前断开；统一清理仍审计残留。
    });
    socket.once('close', () => sockets.delete(socket));
  });
  server.on('connect', (request, clientSocket, head) => {
    const deny = (reason) => {
      evidence.deniedConnectCount += 1;
      evidence.deniedConnectReasonCounts[reason] += 1;
      if (!clientSocket.destroyed) {
        clientSocket.end(
          'HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n',
        );
      }
    };
    let task;
    task = (async () => {
      const destination = await resolveProxyDestination(
        request.url,
        resolver,
      );
      if (closing) {
        clientSocket.destroy();
        return;
      }
      evidence.pinnedResolutionCount += 1;
      const upstream = connectSocket({
        family: destination.family,
        host: destination.address,
        port: destination.port,
      });
      sockets.add(upstream);
      upstream.once('close', () => sockets.delete(upstream));
      upstream.setTimeout(60_000, () => upstream.destroy());
      upstream.on('error', () => {
        evidence.upstreamErrorCount += 1;
        if (!clientSocket.destroyed) {
          clientSocket.end(
            'HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n',
          );
        }
      });
      upstream.once('connect', () => {
        evidence.allowedConnectCount += 1;
        clientSocket.write(
          'HTTP/1.1 200 Connection Established\r\n' +
            'Proxy-Agent: GCSA-aegis-shadow-research\r\n\r\n',
        );
        if (head.length > 0) upstream.write(head);
        upstream.pipe(clientSocket);
        clientSocket.pipe(upstream);
      });
    })()
      .catch((error) => {
        if (closing) clientSocket.destroy();
        else deny(classifyDeniedConnectReason(error));
      })
      .finally(() => pendingConnectTasks.delete(task));
    pendingConnectTasks.add(task);
  });
  await new Promise((resolveListen, rejectListen) => {
    const handleError = () => {
      server.removeListener('listening', handleListening);
      rejectListen(
        new VerificationError('proxy-start-failed', '本地研究代理启动失败'),
      );
    };
    const handleListening = () => {
      server.removeListener('error', handleError);
      resolveListen();
    };
    server.once('error', handleError);
    server.once('listening', handleListening);
    server.listen(0, '127.0.0.1');
  });
  const address = server.address();
  assert(
    address &&
      typeof address === 'object' &&
      address.address === '127.0.0.1' &&
      Number.isSafeInteger(address.port),
    'proxy-start-failed',
    '本地研究代理未绑定 loopback',
  );
  let closed = false;
  return {
    evidence,
    port: address.port,
    async close() {
      if (closed) return;
      closing = true;
      const serverClosed = new Promise((resolveClose, rejectClose) => {
        server.close((error) => {
          if (error) rejectClose(error);
          else resolveClose();
        });
      });
      for (const socket of sockets) socket.destroy();
      const pendingSettled = Promise.allSettled([...pendingConnectTasks]);
      const pendingResult = await Promise.race([
        pendingSettled.then(() => 'settled'),
        delay(5_000).then(() => 'timeout'),
      ]);
      assert(
        pendingResult === 'settled',
        'proxy-cleanup-failed',
        '等待代理 DNS/CONNECT 任务清理超时',
      );
      for (const socket of sockets) socket.destroy();
      await serverClosed;
      closed = true;
    },
  };
}

function remaining(deadline, code, message) {
  const milliseconds = Math.floor(deadline - performance.now());
  assert(milliseconds > 0, code, message);
  return milliseconds;
}

function waitForWebSocketOpen(socket, timeoutMs) {
  return new Promise((resolveOpen, rejectOpen) => {
    const timer = setTimeout(() => {
      cleanup();
      rejectOpen(new VerificationError('cdp-timeout', 'CDP WebSocket 超时'));
    }, timeoutMs);
    const cleanup = () => {
      clearTimeout(timer);
      socket.removeEventListener('open', handleOpen);
      socket.removeEventListener('error', handleError);
      socket.removeEventListener('close', handleClose);
    };
    const handleOpen = () => {
      cleanup();
      resolveOpen();
    };
    const handleError = () => {
      cleanup();
      rejectOpen(new VerificationError('cdp-error', 'CDP WebSocket 握手失败'));
    };
    const handleClose = () => {
      cleanup();
      rejectOpen(
        new VerificationError('cdp-error', 'CDP WebSocket 在握手前关闭'),
      );
    };
    socket.addEventListener('open', handleOpen);
    socket.addEventListener('error', handleError);
    socket.addEventListener('close', handleClose);
  });
}

class CdpClient {
  constructor(socket, timeoutMs) {
    this.eventError = null;
    this.listeners = new Map();
    this.nextId = 1;
    this.pending = new Map();
    this.socket = socket;
    this.timeoutMs = timeoutMs;
    socket.addEventListener('message', (event) => this.handleMessage(event));
    socket.addEventListener('close', () => this.rejectPending('CDP 连接已关闭'));
    socket.addEventListener('error', () => this.rejectPending('CDP 连接错误'));
  }

  static async connect(value, timeoutMs) {
    const parsed = new URL(value);
    assert(
      parsed.protocol === 'ws:' &&
        parsed.hostname === '127.0.0.1' &&
        parsed.username === '' &&
        parsed.password === '',
      'cdp-error',
      'CDP WebSocket 不是无凭据 loopback',
    );
    const socket = new WebSocket(value);
    await waitForWebSocketOpen(socket, timeoutMs);
    return new CdpClient(socket, timeoutMs);
  }

  async handleMessage(event) {
    const text =
      typeof event.data === 'string'
        ? event.data
        : event.data instanceof Blob
          ? await event.data.text()
          : Buffer.from(event.data).toString('utf8');
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      this.eventError = new VerificationError(
        'cdp-error',
        'CDP 返回非 JSON 消息',
      );
      this.rejectPending('CDP 返回非 JSON 消息');
      return;
    }
    if (Number.isSafeInteger(message.id)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(
          new VerificationError(
            'cdp-error',
            'CDP ' + pending.method + ' 调用失败',
            pending.method,
          ),
        );
      } else {
        pending.resolve(message.result || {});
      }
      return;
    }
    if (typeof message.method !== 'string') return;
    if (message.method === 'Inspector.targetCrashed') {
      this.eventError = new VerificationError(
        'renderer-crash',
        'Renderer 报告崩溃',
      );
    }
    const sessionId =
      typeof message.sessionId === 'string' ? message.sessionId : null;
    for (const listener of
      this.listeners.get(this.eventKey(message.method, sessionId)) || []) {
      try {
        listener(message.params || {});
      } catch (error) {
        this.eventError =
          error instanceof VerificationError
            ? error
            : new VerificationError('cdp-error', 'CDP 事件处理失败');
      }
    }
  }

  rejectPending(message) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(
        new VerificationError('cdp-error', message, pending.method),
      );
    }
    this.pending.clear();
  }

  eventKey(method, sessionId = null) {
    return (sessionId || '') + '\u0000' + method;
  }

  on(method, listener, sessionId = null) {
    const key = this.eventKey(method, sessionId);
    const listeners = this.listeners.get(key) || new Set();
    listeners.add(listener);
    this.listeners.set(key, listeners);
    return () => listeners.delete(listener);
  }

  waitForEvent(method, timeoutMs, predicate = () => true, sessionId = null) {
    return new Promise((resolveEvent, rejectEvent) => {
      const timer = setTimeout(() => {
        cleanup();
        rejectEvent(
          new VerificationError('timeout', '等待 ' + method + ' 超时'),
        );
      }, timeoutMs);
      const remove = this.on(method, (params) => {
        if (!predicate(params)) return;
        cleanup();
        resolveEvent(params);
      }, sessionId);
      const handleClose = () => {
        cleanup();
        rejectEvent(
          new VerificationError('cdp-error', '等待事件时 CDP 连接关闭'),
        );
      };
      const cleanup = () => {
        clearTimeout(timer);
        remove();
        this.socket.removeEventListener('close', handleClose);
      };
      this.socket.addEventListener('close', handleClose);
    });
  }

  command(method, params, timeoutMs, sessionId = null) {
    assert(
      this.socket.readyState === WebSocket.OPEN,
      'cdp-error',
      'CDP WebSocket 未打开',
    );
    const id = this.nextId++;
    return new Promise((resolveCommand, rejectCommand) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectCommand(
          new VerificationError(
            'cdp-timeout',
            'CDP ' + method + ' 超时',
            method,
          ),
        );
      }, timeoutMs || this.timeoutMs);
      this.pending.set(id, {
        method,
        reject: rejectCommand,
        resolve: resolveCommand,
        timer,
      });
      const payload = {id, method, params: params || {}};
      if (sessionId) payload.sessionId = sessionId;
      this.socket.send(JSON.stringify(payload));
    });
  }

  async close() {
    if (this.socket.readyState >= WebSocket.CLOSING) return;
    this.socket.close(1000, 'research run complete');
    await delay(50);
  }
}

class CdpSession {
  constructor(client, sessionId) {
    assert(
      client instanceof CdpClient && /^[0-9a-f-]+$/iu.test(sessionId || ''),
      'cdp-error',
      'CDP session 身份无效',
    );
    this.client = client;
    this.sessionId = sessionId;
  }

  get eventError() {
    return this.client.eventError;
  }

  command(method, params, timeoutMs) {
    return this.client.command(method, params, timeoutMs, this.sessionId);
  }

  on(method, listener) {
    return this.client.on(method, listener, this.sessionId);
  }

  waitForEvent(method, timeoutMs, predicate = () => true) {
    return this.client.waitForEvent(
      method,
      timeoutMs,
      predicate,
      this.sessionId,
    );
  }

  async close() {
    await this.client.command(
      'Target.detachFromTarget',
      {sessionId: this.sessionId},
      1_000,
    );
  }
}

async function enableTargetCrashObservation(client, timeoutMs) {
  await client.command(
    'Target.setDiscoverTargets',
    {discover: true},
    timeoutMs,
  );
}

function installTargetCrashListener(client) {
  return client.on('Target.targetCrashed', (params) => {
    if (params && typeof params.targetId === 'string') {
      client.eventError = new VerificationError(
        'renderer-crash',
        '专用研究浏览器内有 target 报告崩溃',
      );
    }
  });
}

async function installTargetCrashObservation(client, timeoutMs) {
  const remove = installTargetCrashListener(client);
  try {
    await enableTargetCrashObservation(client, timeoutMs);
    return remove;
  } catch (error) {
    remove();
    throw error;
  }
}

function assertClientEventsHealthy(clients, message) {
  const eventError = clients
    .filter(Boolean)
    .map((client) => client.eventError)
    .find(Boolean);
  assert(!eventError, errorCode(eventError), message);
}

async function enablePageObservation(client, timeoutMs) {
  await client.command('Inspector.enable', {}, timeoutMs);
  await client.command('Page.enable', {}, timeoutMs);
  await client.command('Network.enable', {}, timeoutMs);
  await client.command('Runtime.enable', {}, timeoutMs);
}

async function enableAndResumePausedPage(client, timeoutMs) {
  const commands = [
    'Inspector.enable',
    'Page.enable',
    'Network.enable',
    'Runtime.enable',
  ].map((method) => client.command(method, {}, timeoutMs));
  commands.push(
    client.command('Runtime.runIfWaitingForDebugger', {}, timeoutMs),
  );
  await Promise.all(commands);
}

async function waitForDevToolsEndpoint(profileDir, child, closePromise, deadline) {
  const activePortPath = join(profileDir, 'DevToolsActivePort');
  while (performance.now() < deadline) {
    assert(
      !requestedSignal,
      'interrupted',
      '收到终止信号',
    );
    if (child.exitCode !== null || child.signalCode !== null) {
      fail('browser-exit', 'Chromium 在 DevTools 就绪前退出');
    }
    const content = await readFile(activePortPath, 'utf8').catch(() => '');
    const parts = content.trim().split(/\r?\n/u);
    const port = Number(parts[0]);
    const browserPath = parts[1];
    if (
      Number.isSafeInteger(port) &&
      port > 0 &&
      port <= 65_535 &&
      /^\/devtools\/browser\/[0-9a-f-]+$/iu.test(browserPath || '')
    ) {
      return {browserPath, port};
    }
    const closed = await Promise.race([
      delay(POLL_INTERVAL_MS).then(() => false),
      closePromise.then(() => true),
    ]);
    if (closed) fail('browser-exit', 'Chromium 在 DevTools 就绪前退出');
  }
  fail('timeout', '等待 DevTools endpoint 超时');
}

async function waitWithBrowser(promise, closePromise, deadline, code, message) {
  const timeoutMs = remaining(deadline, code, message);
  let timer;
  try {
    const result = await Promise.race([
      promise.then((value) => ({kind: 'value', value})),
      closePromise.then(() => ({kind: 'closed'})),
      new Promise((resolveTimeout) => {
        timer = setTimeout(
          () => resolveTimeout({kind: 'timeout'}),
          timeoutMs,
        );
      }),
    ]);
    if (result.kind === 'closed') {
      fail('browser-exit', 'Chromium 在研究窗口内退出');
    }
    if (result.kind === 'timeout') fail(code, message);
    return result.value;
  } finally {
    clearTimeout(timer);
  }
}

async function monitoredDelay(
  milliseconds,
  child,
  clients,
  closePromise,
  deadline,
) {
  const end = Math.min(deadline, performance.now() + milliseconds);
  while (performance.now() < end) {
    assert(!requestedSignal, 'interrupted', '收到终止信号');
    assert(
      child.exitCode === null && child.signalCode === null,
      'browser-exit',
      'Chromium 在稳定观察期退出',
    );
    for (const client of clients) {
      if (client && client.eventError) throw client.eventError;
    }
    await waitWithBrowser(
      delay(
        Math.max(
          0,
          Math.min(POLL_INTERVAL_MS, end - performance.now()),
        ),
      ),
      closePromise,
      deadline,
      'timeout',
      '稳定观察超时',
    );
  }
}

function parseTraceRecords(traceEvents, candidateRecordLimit) {
  assert(
    Array.isArray(traceEvents),
    'trace-invalid',
    'trace 事件集合不是数组',
  );
  const records = [];
  for (const [eventIndex, event] of traceEvents.entries()) {
    assert(
      event && typeof event === 'object' && !Array.isArray(event),
      'trace-invalid',
      'trace 事件无效',
    );
    const categories =
      typeof event.cat === 'string' ? event.cat.split(',') : [];
    const categoryMatches = categories.includes(TRACE_CATEGORY);
    const nameMatches = event.name === TRACE_EVENT_NAME;
    if (!categoryMatches && !nameMatches) continue;
    assert(
      categoryMatches && nameMatches,
      'trace-invalid',
      'Aegis trace 分类或名称不匹配',
    );
    assert(
      event.ph === 'I',
      'trace-invalid',
      'Aegis trace 不是 instant event',
    );
    assert(
      event.args &&
        typeof event.args === 'object' &&
        !Array.isArray(event.args),
      'trace-invalid',
      'Aegis trace 缺少参数',
    );
    const argumentNames = Object.keys(event.args).sort();
    assert(
      canonical(argumentNames) === canonical(TRACE_ARGUMENT_NAMES),
      'trace-invalid',
      'Aegis trace 参数集合不符合 schema=2',
    );
    for (const name of TRACE_ARGUMENT_NAMES) {
      assert(
        Number.isSafeInteger(event.args[name]) && event.args[name] >= 0,
        'trace-invalid',
        'Aegis trace 参数不是非负安全整数',
      );
    }
    assert(
      event.args.bytes <= 0xffff_ffff &&
        event.args.opcodes <= 0xffff_ffff &&
        event.args.signature_hi <= 0xffff_ffff &&
        event.args.signature_lo <= 0xffff_ffff,
      'trace-invalid',
      'Aegis trace 字段超出 uint32',
    );
    assert(
      event.args.record_schema === 2 &&
        event.args.signature_schema === 1 &&
        event.args.mode_code === 0 &&
        event.args.would_block === 0 &&
        (event.args.status_code === 0 || event.args.status_code === 1),
      'trace-invalid',
      'Aegis trace 固定协议字段无效',
    );
    assert(
      Number.isSafeInteger(event.pid) && event.pid > 0,
      'trace-invalid',
      'Aegis trace 缺少进程标识',
    );
    const signatureIsZero =
      event.args.signature_hi === 0 && event.args.signature_lo === 0;
    if (event.args.status_code === 1) {
      assert(
        event.args.bytes > 0 &&
          event.args.opcodes === 0 &&
          signatureIsZero,
        'trace-invalid',
        'skipped-too-large 记录包含非法摘要',
      );
    } else {
      assert(
        event.args.bytes > 0 &&
          event.args.opcodes > 0 &&
          !signatureIsZero,
        'trace-invalid',
        'observed 记录缺少有效摘要',
      );
    }
    records.push({
      bytes: event.args.bytes,
      opcodes: event.args.opcodes,
      pid: event.pid,
      skipped: event.args.status_code === 1,
    });
    assert(
      records.length <= candidateRecordLimit,
      'trace-invalid',
      'Aegis trace 候选事件超过协议硬上限',
    );
  }
  return records;
}

class TraceCollector {
  constructor(candidateRecordLimit) {
    this.candidateEvents = [];
    this.candidateRecordLimit = candidateRecordLimit;
    this.dataBatchCount = 0;
  }

  collect(params) {
    assert(
      Array.isArray(params.value),
      'trace-invalid',
      'Tracing.dataCollected 缺少事件数组',
    );
    this.dataBatchCount += 1;
    for (const event of params.value) {
      const categories =
        typeof event?.cat === 'string' ? event.cat.split(',') : [];
      if (
        categories.includes(TRACE_CATEGORY) ||
        event?.name === TRACE_EVENT_NAME
      ) {
        this.candidateEvents.push(event);
        assert(
          this.candidateEvents.length <= this.candidateRecordLimit,
          'trace-invalid',
          '专用 trace 候选事件超过协议硬上限',
        );
      }
    }
  }

  finish(params) {
    assert(
      params && typeof params.dataLossOccurred === 'boolean',
      'trace-invalid',
      'Tracing.tracingComplete 缺少 dataLossOccurred',
    );
    assert(
      params.dataLossOccurred === false,
      'trace-invalid',
      'Perfetto 报告数据丢失',
    );
    return {
      dataBatchCount: this.dataBatchCount,
      records: parseTraceRecords(
        this.candidateEvents,
        this.candidateRecordLimit,
      ),
    };
  }
}

function mergeProcessInfoSnapshots(snapshots) {
  assert(
    Array.isArray(snapshots) && snapshots.length >= 2,
    'attribution-invalid',
    'Chromium 进程角色快照不足',
  );
  const merged = new Map();
  for (const snapshot of snapshots) {
    assert(
      Array.isArray(snapshot),
      'attribution-invalid',
      'Chromium 进程角色快照无效',
    );
    for (const entry of snapshot) {
      assert(
        entry &&
          Number.isSafeInteger(entry.id) &&
          entry.id > 0 &&
          typeof entry.type === 'string' &&
          entry.type.length > 0,
        'attribution-invalid',
        'Chromium 进程角色条目无效',
      );
      const current = merged.get(entry.id);
      assert(
        current === undefined || current === entry.type,
        'attribution-invalid',
        'Chromium 进程角色冲突',
      );
      merged.set(entry.id, entry.type);
    }
  }
  return merged;
}

function numericRange(values) {
  if (values.length === 0) return {max: null, min: null};
  return {max: Math.max(...values), min: Math.min(...values)};
}

function summarizeTrace(records, snapshots, maxRecordsPerProcess) {
  const roles = mergeProcessInfoSnapshots(snapshots);
  const counts = new Map();
  let observedCount = 0;
  let skippedCount = 0;
  for (const record of records) {
    const role = roles.get(record.pid);
    assert(
      role === 'renderer',
      'attribution-invalid',
      'Aegis trace 发射者不是已知 renderer',
    );
    counts.set(record.pid, (counts.get(record.pid) || 0) + 1);
    if (record.skipped) skippedCount += 1;
    else observedCount += 1;
  }
  const perRendererCounts = [...counts.values()].sort(
    (left, right) => left - right,
  );
  assert(
    perRendererCounts.every((count) => count <= maxRecordsPerProcess),
    'trace-invalid',
    'renderer process 记录数超过 V8 进程全局硬上限',
  );
  return {
    byteRange: numericRange(records.map((record) => record.bytes)),
    capReached: perRendererCounts.some(
      (count) => count === maxRecordsPerProcess,
    ),
    dataLossOccurred: false,
    emitterRole: records.length === 0 ? null : 'renderer',
    observedCount,
    opcodeRange: numericRange(records.map((record) => record.opcodes)),
    recordCount: records.length,
    rendererEmitterCount: counts.size,
    skippedTooLargeCount: skippedCount,
  };
}

function modeArguments(mode, maxRecordsPerProcess) {
  assert(
    mode === 'off' || mode === 'on',
    'internal-error',
    '未知研究模式',
  );
  return [
    mode === 'off'
      ? '--disable-features=AegisBytecodeShadow,NetworkTimeServiceQuerying'
      : '--enable-features=AegisBytecodeShadow',
    ...(mode === 'on'
      ? ['--disable-features=NetworkTimeServiceQuerying']
      : []),
    '--js-flags=--aegis-bytecode-shadow-max-records=' +
      maxRecordsPerProcess,
  ];
}

function fatalSignalCount(value) {
  const pattern =
    /\bFATAL\b|CHECK failed|DCHECK failed|Received signal(?: \d+)?|Aw, Snap|Renderer process (?:gone|crashed|exited)|process crashed/iu;
  return value
    .split(/\r?\n/u)
    .filter((line) => pattern.test(line)).length;
}

class DiagnosticAccumulator {
  constructor(limitBytes) {
    this.capture = Buffer.alloc(0);
    this.limitBytes = limitBytes;
    this.totalBytes = 0;
  }

  observe(chunk) {
    const value = Buffer.from(chunk);
    this.totalBytes += value.length;
    if (this.capture.length < this.limitBytes) {
      this.capture = Buffer.concat([
        this.capture,
        value.subarray(0, this.limitBytes - this.capture.length),
      ]);
    }
  }

  evidence() {
    return {
      bytesObserved: this.totalBytes,
      outputTruncated: this.totalBytes > this.limitBytes,
      signalCount: fatalSignalCount(this.capture.toString('utf8')),
    };
  }

  clear() {
    this.capture.fill(0);
    this.capture = Buffer.alloc(0);
  }
}

function diagnosticFailureCode(diagnostics) {
  if (diagnostics.outputTruncated) return 'diagnostic-truncated';
  if (
    diagnostics.signalCount > 0 ||
    diagnostics.profileCrashArtifactCount > 0 ||
    diagnostics.globalCrashDeltaCount > 0
  ) {
    return 'runtime-crash-signal';
  }
  return null;
}

async function countCrashArtifacts(root) {
  let count = 0;
  async function visit(path, depth) {
    if (depth < 0) return;
    const entries = await readdir(path, {withFileTypes: true}).catch((error) => {
      if (error && error.code === 'ENOENT') return [];
      throw error;
    });
    for (const entry of entries) {
      const child = join(path, entry.name);
      if (entry.isDirectory()) await visit(child, depth - 1);
      else if (entry.isFile() && /\.(?:crash|dmp|ips)$/iu.test(entry.name)) {
        count += 1;
      }
    }
  }
  await visit(root, 6);
  return count;
}

function isChromiumDiagnosticCrashName(value) {
  return (
    typeof value === 'string' &&
    /(?:^|[^a-z0-9])chromium(?:[^a-z0-9]|$)/iu.test(value)
  );
}

async function globalCrashArtifacts(root, filterName, depth) {
  const records = new Map();
  async function visit(path, remainingDepth) {
    const entries = await readdir(path, {withFileTypes: true}).catch((error) => {
      if (error && error.code === 'ENOENT') return [];
      throw error;
    });
    for (const entry of entries) {
      const child = join(path, entry.name);
      if (entry.isDirectory() && remainingDepth > 0) {
        await visit(child, remainingDepth - 1);
      } else if (
        entry.isFile() &&
        /\.(?:crash|dmp|ips)$/iu.test(entry.name) &&
        (!filterName || isChromiumDiagnosticCrashName(entry.name))
      ) {
        const metadata = await stat(child);
        records.set(child, metadata.size + ':' + metadata.mtimeMs);
      }
    }
  }
  await visit(root, depth);
  return records;
}

async function snapshotGlobalCrashes() {
  const roots = [
    {
      depth: 2,
      filterName: true,
      path: join(homedir(), 'Library', 'Logs', 'DiagnosticReports'),
    },
    {
      depth: 2,
      filterName: false,
      path: join(
        homedir(),
        'Library',
        'Application Support',
        'Chromium',
        'Crashpad',
        'pending',
      ),
    },
    {
      depth: 2,
      filterName: false,
      path: join(
        homedir(),
        'Library',
        'Application Support',
        'Chromium',
        'Crashpad',
        'completed',
      ),
    },
    {
      depth: 2,
      filterName: false,
      path: join(
        homedir(),
        'Library',
        'Application Support',
        'Chromium',
        'Crashpad',
        'reports',
      ),
    },
  ];
  const snapshot = new Map();
  for (const root of roots) {
    for (const [path, identity] of await globalCrashArtifacts(
      root.path,
      root.filterName,
      root.depth,
    )) {
      snapshot.set(path, identity);
    }
  }
  return snapshot;
}

function globalCrashDelta(before, after) {
  return [...after.entries()].filter(
    ([path, identity]) => before.get(path) !== identity,
  ).length;
}

async function initializeResearchProfile(profileDir) {
  const defaultProfileDir = join(profileDir, 'Default');
  await mkdir(defaultProfileDir, {recursive: true, mode: 0o700});
  await writeFile(
    join(profileDir, 'Local State'),
    JSON.stringify({
      network_time: {network_time_queries_enabled: false},
    }) + '\n',
    {encoding: 'utf8', flag: 'wx', mode: 0o600},
  );
  await writeFile(
    join(defaultProfileDir, 'Preferences'),
    JSON.stringify({alternate_error_pages: {enabled: false}}) + '\n',
    {encoding: 'utf8', flag: 'wx', mode: 0o600},
  );
}

function execFileOutcome(file, args) {
  return new Promise((resolveOutcome) => {
    execFile(
      file,
      args,
      {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024},
      (error, stdout, stderr) => {
        resolveOutcome({
          passed: !error,
          stderr,
          stdout,
        });
      },
    );
  });
}

async function profileProcessIds(profileDir) {
  const outcome = await execFileOutcome('/bin/ps', ['-axo', 'pid=,command=']);
  if (!outcome.passed) {
    fail('cleanup-failure', '无法审计残留进程');
  }
  const marker = '--user-data-dir=' + profileDir;
  const identifiers = [];
  for (const line of outcome.stdout.split(/\r?\n/u)) {
    if (!line.includes(marker)) continue;
    const match = line.trim().match(/^(\d+)\s/u);
    if (match) identifiers.push(Number(match[1]));
  }
  return identifiers;
}

function signalProcessGroup(child, signal) {
  if (!child || !Number.isSafeInteger(child.pid) || child.pid <= 1) return;
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if (!error || error.code !== 'ESRCH') throw error;
  }
}

async function waitForNoOwnedProcesses(profileDir, deadline) {
  while (performance.now() < deadline) {
    const identifiers = await profileProcessIds(profileDir);
    if (identifiers.length === 0) return;
    await delay(POLL_INTERVAL_MS);
  }
  fail('cleanup-failure', '等待自有浏览器进程退出超时');
}

async function terminateOwnedBrowser(child, profileDir, closePromise) {
  if (child && child.exitCode === null && child.signalCode === null) {
    signalProcessGroup(child, 'SIGTERM');
  }
  try {
    await waitForNoOwnedProcesses(
      profileDir,
      performance.now() + CLEANUP_GRACE_MS,
    );
  } catch {
    signalProcessGroup(child, 'SIGKILL');
    for (const identifier of await profileProcessIds(profileDir)) {
      try {
        process.kill(identifier, 'SIGKILL');
      } catch (error) {
        if (!error || error.code !== 'ESRCH') throw error;
      }
    }
    await waitForNoOwnedProcesses(
      profileDir,
      performance.now() + CLEANUP_KILL_MS,
    );
  }
  if (closePromise) {
    await Promise.race([closePromise, delay(1_000)]);
  }
}

function assertDisposableRoot(root) {
  const parent = resolve(tmpdir());
  const candidate = resolve(root);
  assert(
    pathIsWithin(parent, candidate) &&
      candidate !== parent &&
      basename(candidate).startsWith(PROFILE_PREFIX),
    'cleanup-failure',
    '拒绝清理非验证器临时目录',
  );
}

async function cleanupRunArtifacts(root, profileDir, child, closePromise) {
  const failures = [];
  let crashArtifactCount = 0;
  try {
    if (profileDir) {
      await terminateOwnedBrowser(child, profileDir, closePromise);
    }
  } catch {
    failures.push('process-termination');
  }
  try {
    crashArtifactCount = await countCrashArtifacts(root);
  } catch {
    failures.push('crash-audit');
  }
  try {
    assertDisposableRoot(root);
    await rm(root, {force: true, recursive: true, maxRetries: 3});
  } catch {
    failures.push('artifact-removal');
  }
  const rootExists = await lstat(root)
    .then(() => true)
    .catch((error) => {
      if (error && error.code === 'ENOENT') return false;
      failures.push('artifact-verification');
      return true;
    });
  let residualOwnedProcessCount = 0;
  if (profileDir) {
    try {
      residualOwnedProcessCount = (await profileProcessIds(profileDir)).length;
    } catch {
      failures.push('residual-audit');
      residualOwnedProcessCount = -1;
    }
  }
  const verified =
    failures.length === 0 &&
    rootExists === false &&
    residualOwnedProcessCount === 0;
  return {
    artifactsRetained: rootExists,
    crashArtifactCount,
    residualOwnedProcessCount,
    temporaryRootRemoved: rootExists === false,
    verified,
  };
}

function handleTerminationSignal(signal) {
  requestedSignal = requestedSignal || signal;
  for (const child of ACTIVE_CHILDREN) {
    try {
      signalProcessGroup(child, 'SIGTERM');
    } catch {
      // 正常清理路径会继续进行残留审计和强制终止。
    }
  }
}

function assertNotInterrupted() {
  assert(!requestedSignal, 'interrupted', '批次已收到终止信号');
}

function installSignalHandlers() {
  requestedSignal = null;
  const handlers = new Map(
    ['SIGINT', 'SIGTERM', 'SIGHUP'].map((signal) => [
      signal,
      () => handleTerminationSignal(signal),
    ]),
  );
  for (const [signal, handler] of handlers) process.on(signal, handler);
  return () => {
    for (const [signal, handler] of handlers) {
      process.removeListener(signal, handler);
    }
  };
}

async function runSingleMode(
  mode,
  value,
  target,
  manifest,
  resolver,
) {
  const startedAt = performance.now();
  const root = await mkdtemp(join(tmpdir(), PROFILE_PREFIX));
  const profileDir = join(root, 'profile');
  const deadline = performance.now() + manifest.execution.timeoutMs;
  const args = [
    '--headless=new',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-default-apps',
    '--disable-extensions',
    '--disable-sync',
    '--disable-breakpad',
    '--deny-permission-prompts',
    '--metrics-recording-only',
    '--no-pings',
    '--password-store=basic',
    '--remote-debugging-port=0',
    '--enable-logging=stderr',
    '--v=0',
    ...(process.platform === 'darwin' ? ['--use-mock-keychain'] : []),
    '--user-data-dir=' + profileDir,
    ...modeArguments(mode, manifest.telemetry.maxRecordsPerProcess),
    'about:blank',
  ];
  const diagnosticAccumulator = new DiagnosticAccumulator(
    DIAGNOSTIC_CAPTURE_LIMIT,
  );
  let child = null;
  let closePromise = null;
  let browserClient = null;
  let pageClient = null;
  let egressProxy = null;
  let tracingStarted = false;
  let removeAttachListener = null;
  let removeTraceListener = null;
  let removeResponseListener = null;
  let removeTargetCrashListener = null;
  let primaryError = null;
  let pageOutcome = 'not-completed';
  let telemetry = null;
  let telemetryBatchCount = 0;
  let processSnapshots = [];
  let documentResponses = [];
  let failureStage = 'global-crash-snapshot';
  let globalCrashBefore = null;

  try {
    globalCrashBefore = await snapshotGlobalCrashes();
    failureStage = 'proxy-start';
    egressProxy = await startPublicHttpsProxy(resolver);
    args.splice(
      args.length - 1,
      0,
      '--proxy-server=http://127.0.0.1:' + egressProxy.port,
      '--proxy-bypass-list=<-loopback>',
      '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
      '--disable-quic',
      '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
    );
    failureStage = 'profile-initialize';
    await initializeResearchProfile(profileDir);
    failureStage = 'browser-start';
    child = spawn(target.executable, args, {
      detached: true,
      env: {...process.env},
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    ACTIVE_CHILDREN.add(child);
    child.once('error', () => {
      // close 事件和统一清理路径负责分类及回收，监听用于避免未处理 error。
    });
    child.stderr.on('data', (chunk) => {
      diagnosticAccumulator.observe(chunk);
    });
    closePromise = new Promise((resolveClose) => {
      child.once('close', (exitCode, signalCode) =>
        resolveClose({exitCode, signalCode}),
      );
    });
    failureStage = 'browser-endpoint';
    const endpoint = await waitForDevToolsEndpoint(
      profileDir,
      child,
      closePromise,
      deadline,
    );
    failureStage = 'browser-cdp-connect';
    browserClient = await CdpClient.connect(
      'ws://127.0.0.1:' + endpoint.port + endpoint.browserPath,
      remaining(deadline, 'timeout', '连接 browser CDP 超时'),
    );
    failureStage = 'target-crash-observation';
    removeTargetCrashListener = await installTargetCrashObservation(
      browserClient,
      remaining(deadline, 'timeout', '启用 target 崩溃观察超时'),
    );
    failureStage = 'download-isolation';
    await browserClient.command(
      'Browser.setDownloadBehavior',
      {behavior: 'deny'},
      remaining(deadline, 'timeout', '配置下载隔离超时'),
    );
    failureStage = 'target-auto-attach';
    await browserClient.command(
      'Target.setAutoAttach',
      {
        autoAttach: true,
        filter: [
          {exclude: false, type: 'page'},
          {exclude: true},
        ],
        flatten: true,
        waitForDebuggerOnStart: true,
      },
      remaining(deadline, 'timeout', '启用暂停式页面附着超时'),
    );
    const traceCollector = new TraceCollector(
      manifest.telemetry.candidateRecordLimit,
    );
    removeTraceListener = browserClient.on(
      'Tracing.dataCollected',
      (params) => traceCollector.collect(params),
    );
    failureStage = 'trace-start';
    await browserClient.command(
      'Tracing.start',
      {
        tracingBackend: 'chrome',
        transferMode: 'ReportEvents',
        traceConfig: {
          enableArgumentFilter: false,
          enableSampling: false,
          enableSystrace: false,
          includedCategories: [TRACE_CATEGORY],
          recordMode: 'recordUntilFull',
          traceBufferSizeInKb: manifest.telemetry.bufferSizeKiB,
        },
      },
      remaining(deadline, 'timeout', '启动专用 trace 超时'),
    );
    tracingStarted = true;
    failureStage = 'target-create';
    const attachedCandidates = [];
    removeAttachListener = browserClient.on(
      'Target.attachedToTarget',
      (params) => attachedCandidates.push(params),
    );
    const targetResult = await browserClient.command(
      'Target.createTarget',
      {background: true, url: value},
      remaining(deadline, 'timeout', '创建暂停式公开页面 target 超时'),
    );
    assert(
      /^[0-9a-f-]+$/iu.test(targetResult.targetId || ''),
      'cdp-error',
      '公开页面 target 身份无效',
    );
    const matchesCreatedTarget = (params) =>
      params &&
      params.targetInfo &&
      params.targetInfo.targetId === targetResult.targetId;
    failureStage = 'target-attach';
    const attachedTarget =
      attachedCandidates.find(matchesCreatedTarget) ||
      (await browserClient.waitForEvent(
        'Target.attachedToTarget',
        remaining(deadline, 'timeout', '等待暂停式页面附着超时'),
        matchesCreatedTarget,
      ));
    removeAttachListener();
    removeAttachListener = null;
    assert(
      attachedTarget.targetInfo.type === 'page' &&
        attachedTarget.waitingForDebugger === true &&
        /^[0-9a-f-]+$/iu.test(attachedTarget.sessionId || ''),
      'cdp-error',
      '暂停式页面附着证据无效',
    );
    pageClient = new CdpSession(
      browserClient,
      attachedTarget.sessionId,
    );
    removeResponseListener = pageClient.on(
      'Network.responseReceived',
      (params) => {
        if (
          params &&
          params.type === 'Document' &&
          params.response &&
          Number.isFinite(params.response.status)
        ) {
          documentResponses.push({
            frameId: params.frameId,
            status: params.response.status,
          });
        }
      },
    );
    failureStage = 'process-attribution-before';
    const initialInfo = await browserClient.command(
      'SystemInfo.getProcessInfo',
      {},
      remaining(deadline, 'timeout', '读取导航前进程角色超时'),
    );
    processSnapshots.push(initialInfo.processInfo);
    const domContentReady = pageClient.waitForEvent(
      'Page.domContentEventFired',
      remaining(deadline, 'timeout', '等待 DOMContentLoaded 超时'),
    );
    void domContentReady.catch(() => {});
    failureStage = 'page-observation-resume';
    await enableAndResumePausedPage(
      pageClient,
      remaining(deadline, 'timeout', '启用页面观察并恢复 target 超时'),
    );
    failureStage = 'document-ready';
    await waitWithBrowser(
      domContentReady,
      closePromise,
      deadline,
      'timeout',
      '等待根页 DOMContentLoaded 超时',
    );
    failureStage = 'main-frame-attribution';
    const frameTree = await pageClient.command(
      'Page.getFrameTree',
      {},
      remaining(deadline, 'timeout', '读取根页 frame 身份超时'),
    );
    const mainFrameId = frameTree.frameTree?.frame?.id;
    assert(
      typeof mainFrameId === 'string' && mainFrameId.length > 0,
      'navigation-error',
      '根页 frame 身份无效',
    );
    failureStage = 'settle';
    await monitoredDelay(
      manifest.execution.settleMs,
      child,
      [browserClient, pageClient],
      closePromise,
      deadline,
    );
    assertClientEventsHealthy(
      [browserClient, pageClient],
      '研究窗口内 CDP 事件失败',
    );
    failureStage = 'process-attribution-after';
    const finalInfo = await browserClient.command(
      'SystemInfo.getProcessInfo',
      {},
      remaining(deadline, 'timeout', '读取导航后进程角色超时'),
    );
    processSnapshots.push(finalInfo.processInfo);
    const tracingComplete = browserClient.waitForEvent(
      'Tracing.tracingComplete',
      remaining(deadline, 'timeout', '等待 trace 完成超时'),
    );
    void tracingComplete.catch(() => {});
    failureStage = 'trace-stop';
    await browserClient.command(
      'Tracing.end',
      {},
      remaining(deadline, 'timeout', '停止专用 trace 超时'),
    );
    const completion = await waitWithBrowser(
      tracingComplete,
      closePromise,
      deadline,
      'timeout',
      '等待 trace 完成超时',
    );
    tracingStarted = false;
    removeTraceListener();
    removeTraceListener = null;
    assertClientEventsHealthy(
      [browserClient, pageClient],
      'trace 采集期间 CDP 事件失败',
    );
    failureStage = 'trace-validate';
    const traceResult = traceCollector.finish(completion);
    telemetryBatchCount = traceResult.dataBatchCount;
    telemetry = summarizeTrace(
      traceResult.records,
      processSnapshots,
      manifest.telemetry.maxRecordsPerProcess,
    );
    assert(
      mode !== 'off' || telemetry.recordCount === 0,
      'control-contamination',
      'OFF 模式出现 Aegis bytecode trace',
    );
    const statuses = documentResponses
      .filter((entry) => entry.frameId === mainFrameId)
      .map((entry) => entry.status);
    assert(
      statuses.length > 0,
      'document-response-missing',
      '未观察到根文档响应',
    );
    const finalStatus = statuses.at(-1);
    pageOutcome =
      finalStatus >= 200 && finalStatus < 400 ? 'ok' : 'http-error';
    failureStage = 'page-health';
    const health = await pageClient.command(
      'Runtime.evaluate',
      {
        expression:
          "({ready: document.readyState === 'interactive' || document.readyState === 'complete', root: Boolean(document.documentElement)})",
        returnByValue: true,
      },
      remaining(deadline, 'timeout', '读取页面健康状态超时'),
    );
    const healthValue = health.result && health.result.value;
    if (
      !healthValue ||
      healthValue.ready !== true ||
      healthValue.root !== true
    ) {
      pageOutcome = 'dom-invalid';
    }
    await monitoredDelay(
      POLL_INTERVAL_MS,
      child,
      [browserClient, pageClient],
      closePromise,
      deadline,
    );
    assertClientEventsHealthy(
      [browserClient, pageClient],
      '页面健康检查后的收尾窗口出现 CDP 事件失败',
    );
    failureStage = 'complete';
  } catch (error) {
    primaryError =
      error instanceof VerificationError
        ? error
        : new VerificationError('internal-error', '研究运行内部错误');
    if (pageOutcome === 'not-completed') {
      const code = errorCode(primaryError);
      pageOutcome = [
        'browser-exit',
        'document-response-missing',
        'dom-invalid',
        'http-error',
        'navigation-error',
        'renderer-crash',
        'timeout',
      ].includes(code)
        ? code
        : 'inconclusive';
    }
  } finally {
    if (tracingStarted && browserClient) {
      await browserClient
        .command('Tracing.end', {}, 1_000)
        .catch(() => {});
    }
    removeTraceListener?.();
    removeAttachListener?.();
    removeResponseListener?.();
    await pageClient?.close().catch(() => {});
    await browserClient?.close().catch(() => {});
    removeTargetCrashListener?.();
  }

  const diagnosticBeforeCleanup = diagnosticAccumulator.evidence();
  const cleanup = await cleanupRunArtifacts(
    root,
    profileDir,
    child,
    closePromise,
  );
  ACTIVE_CHILDREN.delete(child);
  let proxyClosed = egressProxy === null;
  if (egressProxy) {
    try {
      await egressProxy.close();
      proxyClosed = true;
    } catch {
      cleanup.verified = false;
    }
  }
  cleanup.networkProxyClosed = proxyClosed;
  const egress = egressProxy
    ? {
        allowedConnectCount: egressProxy.evidence.allowedConnectCount,
        backgroundIsolation: {
          alternateErrorPagesDisabled: true,
          networkTimeQueriesDisabled: true,
        },
        deniedConnectCount: egressProxy.evidence.deniedConnectCount,
        deniedConnectReasonCounts:
          egressProxy.evidence.deniedConnectReasonCounts,
        deniedPlaintextRequestCount:
          egressProxy.evidence.deniedPlaintextRequestCount,
        pinnedResolutionCount: egressProxy.evidence.pinnedResolutionCount,
        plaintextRequestClassCounts:
          egressProxy.evidence.plaintextRequestClassCounts,
        plaintextRequestCount: egressProxy.evidence.plaintextRequestCount,
        proxyClosed,
        upstreamErrorCount: egressProxy.evidence.upstreamErrorCount,
      }
    : {
        allowedConnectCount: 0,
        backgroundIsolation: {
          alternateErrorPagesDisabled: true,
          networkTimeQueriesDisabled: true,
        },
        deniedConnectCount: 0,
        deniedConnectReasonCounts: emptyDeniedConnectReasonCounts(),
        deniedPlaintextRequestCount: 0,
        pinnedResolutionCount: 0,
        plaintextRequestClassCounts: emptyPlaintextRequestClassCounts(),
        plaintextRequestCount: 0,
        proxyClosed,
        upstreamErrorCount: 0,
      };
  let globalCrashDeltaCount = -1;
  let globalCrashAuditVerified = false;
  try {
    assert(
      globalCrashBefore instanceof Map,
      'global-crash-audit-failed',
      '缺少运行前全局崩溃快照',
    );
    await delay(250);
    globalCrashDeltaCount = globalCrashDelta(
      globalCrashBefore,
      await snapshotGlobalCrashes(),
    );
    globalCrashAuditVerified = true;
  } catch {
    if (!primaryError) {
      failureStage = 'global-crash-audit';
      primaryError = new VerificationError(
        'global-crash-audit-failed',
        '全局崩溃增量审计失败',
      );
    }
  }
  const diagnostics = {
    bytesObserved: diagnosticBeforeCleanup.bytesObserved,
    globalCrashAuditVerified,
    globalCrashDeltaCount,
    outputTruncated: diagnosticBeforeCleanup.outputTruncated,
    profileCrashArtifactCount: cleanup.crashArtifactCount,
    signalCount: diagnosticBeforeCleanup.signalCount,
  };
  diagnosticAccumulator.clear();
  documentResponses = [];
  processSnapshots = [];

  if (!cleanup.verified) {
    failureStage = 'cleanup';
    primaryError = new VerificationError(
      'cleanup-failure',
      '临时资料或自有进程清理未通过',
    );
  } else if (
    !primaryError &&
    (egress.deniedConnectCount > 0 ||
      egress.deniedPlaintextRequestCount > 0 ||
      egress.plaintextRequestCount > 0)
  ) {
    failureStage = 'egress-policy';
    primaryError = new VerificationError(
      'egress-denied',
      '页面尝试了策略外网络请求',
    );
  } else if (!primaryError && diagnosticFailureCode(diagnostics)) {
    failureStage = 'runtime-diagnostics';
    primaryError = new VerificationError(
      diagnosticFailureCode(diagnostics),
      '观察到崩溃信号',
    );
  }
  diagnostics.cdpMethod = errorCdpMethod(primaryError);
  diagnostics.failureStage = primaryError ? failureStage : 'complete';
  return {
    cleanup,
    diagnostics,
    egress,
    elapsedMs: Math.round(performance.now() - startedAt),
    pageOutcome,
    protocolOutcome: primaryError ? errorCode(primaryError) : 'ok',
    telemetry:
      telemetry === null
        ? null
        : {
            ...telemetry,
            collectionBatchCount: telemetryBatchCount,
            categoryEnabled: true,
          },
  };
}

function classifyBreakage(offRun, onRun) {
  const offOkay = offRun.pageOutcome === 'ok';
  const onOkay = onRun.pageOutcome === 'ok';
  if (offOkay && onOkay) return 'no-observed-breakage';
  if (offOkay && !onOkay) return 'on-regression';
  if (!offOkay && onOkay) return 'control-only-failure';
  if (offRun.pageOutcome === onRun.pageOutcome) return 'shared-failure';
  return 'inconclusive-mixed-failure';
}

function reportHasForbiddenPrivacyField(value, forbiddenStrings) {
  const forbiddenKey =
    /^(?:url|host|hostname|title|pid|signature|signatures|rawtrace|rawlog)$/iu;
  const forbiddenCompoundKey = /raw.*(?:trace|log)|(?:trace|log).*raw/iu;
  function visit(current) {
    if (typeof current === 'string') {
      if (/(?:https?|wss?|file):\/\//iu.test(current)) return true;
      return forbiddenStrings.some(
        (secret) => secret.length > 0 && current.includes(secret),
      );
    }
    if (Array.isArray(current)) return current.some((entry) => visit(entry));
    if (!current || typeof current !== 'object') return false;
    for (const [key, entry] of Object.entries(current)) {
      const normalized = key.replace(/[-_]/gu, '').toLowerCase();
      if (
        forbiddenKey.test(normalized) ||
        forbiddenCompoundKey.test(normalized)
      ) {
        return true;
      }
      if (visit(entry)) return true;
    }
    return false;
  }
  return visit(value);
}

function assertPrivateReport(report, forbiddenStrings) {
  assert(
    !reportHasForbiddenPrivacyField(report, forbiddenStrings),
    'privacy-violation',
    '报告包含禁止保存的隐私或原始字段',
  );
}

function publicRunRecord(mode, position, result) {
  return {
    cleanup: result.cleanup,
    diagnostics: {
      cdpMethod: result.diagnostics.cdpMethod,
      failureStage: result.diagnostics.failureStage,
      globalCrashAuditVerified:
        result.diagnostics.globalCrashAuditVerified,
      globalCrashDeltaCount: result.diagnostics.globalCrashDeltaCount,
      profileCrashArtifactCount:
        result.diagnostics.profileCrashArtifactCount,
      signalCount: result.diagnostics.signalCount,
    },
    egress: result.egress,
    mode,
    pageOutcome: result.pageOutcome,
    position,
    protocolOutcome: result.protocolOutcome,
    telemetry: result.telemetry,
  };
}

function runObservedLiveNetwork(run) {
  return Boolean(
    run?.egress &&
      run.egress.allowedConnectCount > 0 &&
      run.egress.pinnedResolutionCount >= run.egress.allowedConnectCount,
  );
}

function buildReport({
  batchGlobalCrashDeltaCount,
  batchId,
  binarySha256,
  buildIdentity,
  completedAt,
  hmacNonce,
  manifest,
  manifestCommitment,
  pairs,
  pilot,
  plannedRuns,
  runner,
  startedAt,
}) {
  const runnerEvidence = runnerEvidenceForReport(runner);
  assertStableRunner(runnerEvidence);
  const runs = pairs.flatMap((pair) => pair.runs);
  const liveNetworkObserved = runs.some((run) =>
    runObservedLiveNetwork(run),
  );
  const cleanupVerified = runs.every((run) => run.cleanup.verified);
  const protocolPassed =
    runs.length === plannedRuns &&
    runs.every((run) => run.protocolOutcome === 'ok');
  const noObservedRegression = pairs.every(
    (pair) => pair.breakage !== 'on-regression',
  );
  const allPairsHealthy =
    pairs.length === plannedRuns / 2 &&
    pairs.every((pair) => pair.breakage === 'no-observed-breakage');
  const onSignalRunCount = runs.filter(
    (run) =>
      run.mode === 'on' &&
      run.telemetry !== null &&
      run.telemetry.recordCount > 0,
  ).length;
  const onSignalComplete = onSignalRunCount === plannedRuns / 2;
  const globalCrashEvidenceClean =
    batchGlobalCrashDeltaCount === 0 &&
    runs.every(
      (run) =>
        run.diagnostics.globalCrashAuditVerified === true &&
        run.diagnostics.globalCrashDeltaCount === 0 &&
        run.diagnostics.profileCrashArtifactCount === 0,
    );
  const egressEvidenceClean = runs.every(
    (run) =>
      run.egress &&
      run.egress.proxyClosed === true &&
      run.egress.allowedConnectCount >= 1 &&
      run.egress.pinnedResolutionCount >=
        run.egress.allowedConnectCount &&
      run.egress.deniedConnectCount === 0 &&
      run.egress.deniedPlaintextRequestCount === 0 &&
      run.egress.plaintextRequestCount === 0,
  );
  return {
    schema: REPORT_SCHEMA,
    qualification: 'research-only',
    releaseEligible: false,
    passed:
      protocolPassed &&
      cleanupVerified &&
      allPairsHealthy &&
      onSignalComplete &&
      globalCrashEvidenceClean &&
      egressEvidenceClean,
    generatedAt: completedAt,
    runner: runnerEvidence,
    batch: {
      batchId,
      globalCrashDeltaCount: batchGlobalCrashDeltaCount,
      completedRuns: runs.length,
      liveNetworkAuthorized: true,
      liveNetworkConfirmed: liveNetworkObserved,
      liveNetworkObserved,
      manifestCommitment,
      plannedRuns,
      startedAt,
    },
    target: {
      buildIdentity: {
        manifestSha256: buildIdentity.manifestSha256,
        qualification: buildIdentity.qualification,
        verified: true,
      },
      executableSha256: binarySha256,
      identityStable: true,
      lockHeldAcrossRun: true,
    },
    protocol: {
      aMode: 'off',
      bMode: 'on',
      bufferSizeKiB: manifest.telemetry.bufferSizeKiB,
      capScope: 'renderer-process-global',
      categoryEnabledInBothModes: true,
      egressPolicy: 'public-https-via-pinned-connect-proxy',
      exactDocumentAttribution: false,
      maxRecordsPerProcess: manifest.telemetry.maxRecordsPerProcess,
      pairOrders: manifest.execution.pairOrders,
      pilot,
      recordMode: 'record-until-full',
      telemetryAttribution: 'bounded-navigation-window-run-level',
      upstreamErrorsAreAvailabilityOnly: true,
    },
    privacy: {
      batchScopedHmacIds: true,
      externalKeyRetainedOutsideReport: true,
      hmacNonce,
      rawArtifactsPersisted: false,
      temporaryArtifactsRetained: !cleanupVerified,
    },
    summary: {
      cleanupVerified,
      egressEvidenceClean,
      allPairsHealthy,
      globalCrashEvidenceClean,
      noObservedRegression,
      onSignalComplete,
      onSignalRunCount,
      protocolPassed,
      sitePairCount: pairs.length,
    },
    pairs,
  };
}

function buildFailureReport(context, code) {
  const runnerEvidence = runnerEvidenceForReport(context.runner);
  const completedRuns = context.pairs.flatMap((pair) => pair.runs);
  const liveNetworkObserved = completedRuns.some((run) =>
    runObservedLiveNetwork(run),
  );
  const cleanupFullyVerified =
    completedRuns.length === context.completedRuns &&
    completedRuns.every((run) => run.cleanup.verified);
  const artifactsKnownRetained = completedRuns.some(
    (run) => run.cleanup.artifactsRetained === true,
  );
  const temporaryArtifactsRetained = artifactsKnownRetained
    ? true
    : cleanupFullyVerified
      ? false
      : null;
  const globalArtifactsKnownRetained =
    context.batchGlobalCrashDeltaCount > 0 ||
    completedRuns.some(
      (run) => run.diagnostics.globalCrashDeltaCount > 0,
    );
  const globalCrashAuditClean =
    context.batchGlobalCrashAuditVerified === true &&
    context.batchGlobalCrashDeltaCount === 0 &&
    completedRuns.every(
      (run) =>
        run.diagnostics.globalCrashAuditVerified === true &&
        run.diagnostics.globalCrashDeltaCount === 0,
    );
  const rawArtifactsPersisted =
    temporaryArtifactsRetained === true || globalArtifactsKnownRetained
      ? true
      : temporaryArtifactsRetained === false && globalCrashAuditClean
        ? false
        : null;
  return {
    schema: REPORT_SCHEMA,
    qualification: 'research-only',
    releaseEligible: false,
    passed: false,
    generatedAt: new Date().toISOString(),
    runner: runnerEvidence,
    batch: {
      batchId: context.batchId,
      completedRuns: context.completedRuns,
      globalCrashDeltaCount: context.batchGlobalCrashDeltaCount,
      liveNetworkAuthorized: true,
      liveNetworkConfirmed: liveNetworkObserved,
      liveNetworkObserved,
      manifestCommitment: context.manifestCommitment,
      plannedRuns: context.plannedRuns,
      startedAt: context.startedAt,
    },
    privacy: {
      batchScopedHmacIds: true,
      externalKeyRetainedOutsideReport: true,
      hmacNonce: context.hmacNonce,
      rawArtifactsPersisted,
      temporaryArtifactsRetained,
    },
    target: {
      buildIdentity: context.buildIdentity,
      lockHeldAcrossRun: context.buildLockHeldAcrossRun,
    },
    failureCode: code,
    pairs: context.pairs,
  };
}

async function assertRejects(code, operation) {
  let observed = null;
  try {
    await operation();
  } catch (error) {
    observed = errorCode(error);
  }
  assert(
    observed === code,
    'self-test-failed',
    '预期失败码 ' + code + '，实际为 ' + observed,
  );
}

function sampleManifest() {
  return {
    schema: MANIFEST_SCHEMA,
    qualification: 'research-only',
    releaseEligible: false,
    networkPolicy: {
      publicHttpsRootOnly: true,
      confirmationBinding: 'manifest-sha256',
      derivedRequests: 'public-https-via-pinned-connect-proxy',
      resolver: {
        mode: 'validated-direct-dns',
        servers: ['1.1.1.1'],
        recordTypes: ['A'],
      },
    },
    telemetry: {
      category: TRACE_CATEGORY,
      eventName: TRACE_EVENT_NAME,
      recordMode: 'record-until-full',
      bufferSizeKiB: 32 * 1024,
      maxRecordsPerProcess: 5,
      candidateRecordLimit: 64,
    },
    execution: {
      defaultPilot: true,
      pairOrders: ['AB', 'BA'],
      fullRounds: 2,
      timeoutMs: 10_000,
      settleMs: 0,
    },
    pilot: {
      maxSites: 1,
      rounds: 1,
    },
    sites: [{url: 'https://example.com/'}],
  };
}

function validTraceEvent(overrides) {
  const event = {
    args: {
      bytes: 8,
      mode_code: 0,
      opcodes: 4,
      record_schema: 2,
      signature_hi: 1,
      signature_lo: 2,
      signature_schema: 1,
      status_code: 0,
      would_block: 0,
    },
    cat: TRACE_CATEGORY,
    name: TRACE_EVENT_NAME,
    ph: 'I',
    pid: 42,
  };
  return {
    ...event,
    ...overrides,
    args: {...event.args, ...(overrides && overrides.args)},
  };
}

function samplePublicRun(mode, pageOutcome, recordCount) {
  return {
    cleanup: {
      artifactsRetained: false,
      crashArtifactCount: 0,
      residualOwnedProcessCount: 0,
      temporaryRootRemoved: true,
      verified: true,
      networkProxyClosed: true,
    },
    diagnostics: {
      bytesObserved: 0,
      cdpMethod: null,
      failureStage: 'complete',
      globalCrashAuditVerified: true,
      globalCrashDeltaCount: 0,
      outputTruncated: false,
      profileCrashArtifactCount: 0,
      signalCount: 0,
    },
    elapsedMs: 1,
    egress: {
      allowedConnectCount: 1,
      backgroundIsolation: {
        alternateErrorPagesDisabled: true,
        networkTimeQueriesDisabled: true,
      },
      deniedConnectCount: 0,
      deniedConnectReasonCounts: emptyDeniedConnectReasonCounts(),
      deniedPlaintextRequestCount: 0,
      pinnedResolutionCount: 1,
      plaintextRequestClassCounts: emptyPlaintextRequestClassCounts(),
      plaintextRequestCount: 0,
      proxyClosed: true,
      upstreamErrorCount: 0,
    },
    mode,
    pageOutcome,
    position: mode === 'off' ? 1 : 2,
    protocolOutcome: 'ok',
    telemetry: {
      byteRange: {max: recordCount > 0 ? 8 : null, min: recordCount > 0 ? 8 : null},
      capReached: false,
      categoryEnabled: true,
      collectionBatchCount: 1,
      dataLossOccurred: false,
      emitterRole: recordCount > 0 ? 'renderer' : null,
      observedCount: recordCount,
      opcodeRange: {
        max: recordCount > 0 ? 4 : null,
        min: recordCount > 0 ? 4 : null,
      },
      recordCount,
      rendererEmitterCount: recordCount > 0 ? 1 : 0,
      skippedTooLargeCount: 0,
    },
  };
}

function sampleBuiltReport(
  offRun,
  onRun,
  runner = {
    runnerSha256: '9'.repeat(64),
    stable: true,
    verified: true,
  },
) {
  return buildReport({
    batchGlobalCrashDeltaCount: 0,
    batchId: 'a'.repeat(32),
    binarySha256: 'b'.repeat(64),
    buildIdentity: {
      manifestSha256: 'c'.repeat(64),
      qualification: 'diagnostic-only',
      verified: true,
    },
    completedAt: '2026-01-01T00:00:01.000Z',
    hmacNonce: 'f'.repeat(64),
    manifest: sampleManifest(),
    manifestCommitment: 'd'.repeat(32),
    pairs: [
      {
        batchSiteId: 'e'.repeat(32),
        breakage: classifyBreakage(offRun, onRun),
        order: 'AB',
        round: 1,
        runs: [offRun, onRun],
      },
    ],
    pilot: true,
    plannedRuns: 2,
    runner,
    startedAt: '2026-01-01T00:00:00.000Z',
  });
}

async function runSelfTest() {
  const tests = [];
  const test = async (name, operation) => {
    await operation();
    tests.push(name);
  };

  await test('参数解析接受 pilot', async () => {
    const options = parseArgs([
      '--manifest',
      DEFAULT_MANIFEST,
      '--pilot',
      '--confirm-live-network',
      'a'.repeat(64),
    ]);
    assert(options.pilot === true, 'self-test-failed', 'pilot 未解析');
  });
  await test('参数解析拒绝 pilot/full 冲突', async () => {
    await assertRejects('invalid-arguments', async () =>
      parseArgs(['--pilot', '--full']),
    );
  });
  await test('参数解析拒绝宽松确认值', async () => {
    await assertRejects('invalid-arguments', async () =>
      parseArgs(['--confirm-live-network', 'YES']),
    );
  });
  await test('参数解析拒绝单边 build identity', async () => {
    await assertRejects('invalid-arguments', async () =>
      parseArgs(['--build-identity', '/tmp/identity.json']),
    );
  });
  await test('manifest 接受公开 HTTPS 根页', async () => {
    validateManifest(sampleManifest());
  });
  await test('manifest 拒绝 query', async () => {
    const document = sampleManifest();
    document.sites = [{url: 'https://example.com/?x=1'}];
    await assertRejects('manifest-invalid', async () =>
      validateManifest(document),
    );
  });
  await test('manifest 拒绝路径', async () => {
    const document = sampleManifest();
    document.sites = [{url: 'https://example.com/path'}];
    await assertRejects('manifest-invalid', async () =>
      validateManifest(document),
    );
  });
  await test('manifest 拒绝 IP literal', async () => {
    const document = sampleManifest();
    document.sites = [{url: 'https://127.0.0.1/'}];
    await assertRejects('manifest-invalid', async () =>
      validateManifest(document),
    );
  });
  await test('manifest 拒绝非固定顺序', async () => {
    const document = sampleManifest();
    document.execution.pairOrders = ['BA'];
    await assertRejects('manifest-invalid', async () =>
      validateManifest(document),
    );
  });
  await test('manifest 拒绝超过 V8 进程硬上限', async () => {
    const document = sampleManifest();
    document.telemetry.maxRecordsPerProcess = 1001;
    await assertRejects('manifest-invalid', async () =>
      validateManifest(document),
    );
  });
  await test('IPv4-mapped IPv6 私网形式被拒绝', async () => {
    assert(
      isPublicAddress('::ffff:7f00:1') === false &&
        isPublicAddress('::ffff:10.0.0.1') === false,
      'self-test-failed',
      'IPv4-mapped IPv6 绕过公开地址检查',
    );
  });
  await test('系统 fake-IP 结果仍被公开地址门拒绝', async () => {
    await assertRejects('public-resolution-failed', async () =>
      resolvePublicHostname(
        'example.com',
        async () => [{address: '198.18.0.1', family: 4}],
      ),
    );
  });
  await test('显式 resolver 的公开 IPv4 答案通过', async () => {
    let configuredServers = null;
    const queriedHosts = [];
    const resolver = createValidatedDirectDnsResolver(
      sampleManifest().networkPolicy.resolver,
      () => ({
        setServers(servers) {
          configuredServers = servers;
        },
        async resolve4(hostname) {
          queriedHosts.push(hostname);
          return ['93.184.216.34'];
        },
      }),
    );
    const results = await resolvePublicHostname('example.com', resolver);
    assert(
      canonical(configuredServers) === canonical(['1.1.1.1']) &&
        canonical(queriedHosts) === canonical(['example.com']) &&
        canonical(results) ===
          canonical([{address: '93.184.216.34', family: 4}]),
      'self-test-failed',
      '显式 resolver 未固定服务器或未返回公开 IPv4',
    );
  });
  await test('每次 preflight 都用显式 resolver 重查', async () => {
    let lookups = 0;
    const resolver = createValidatedDirectDnsResolver(
      sampleManifest().networkPolicy.resolver,
      () => ({
        setServers() {},
        async resolve4() {
          lookups += 1;
          return ['93.184.216.34'];
        },
      }),
    );
    await resolvePublicSite('https://example.com/', resolver);
    await resolvePublicSite('https://example.com/', resolver);
    assert(
      lookups === 2,
      'self-test-failed',
      'preflight 没有逐次调用显式 resolver',
    );
  });
  await test('显式 resolver 的非公开答案被拒绝', async () => {
    const resolver = createValidatedDirectDnsResolver(
      sampleManifest().networkPolicy.resolver,
      () => ({
        setServers() {},
        async resolve4() {
          return ['192.88.99.2'];
        },
      }),
    );
    await assertRejects('public-resolution-failed', async () =>
      resolvePublicHostname('example.com', resolver),
    );
  });
  await test('显式 resolver 错误时失败且不回退', async () => {
    const resolver = createValidatedDirectDnsResolver(
      sampleManifest().networkPolicy.resolver,
      () => ({
        setServers() {},
        async resolve4() {
          throw new Error('controlled resolver failure');
        },
      }),
    );
    await assertRejects('public-resolution-failed', async () =>
      resolvePublicHostname('example.com', resolver),
    );
  });
  await test('显式 resolver 空答案时失败', async () => {
    const resolver = createValidatedDirectDnsResolver(
      sampleManifest().networkPolicy.resolver,
      () => ({
        setServers() {},
        async resolve4() {
          return [];
        },
      }),
    );
    await assertRejects('public-resolution-failed', async () =>
      resolvePublicHostname('example.com', resolver),
    );
  });
  await test('CONNECT 仅允许公开 HTTPS 443', async () => {
    const resolver = async () => [{address: '93.184.216.34', family: 4}];
    const destination = await resolveProxyDestination(
      'example.com:443',
      resolver,
    );
    assert(
      destination.address === '93.184.216.34' &&
        destination.port === 443,
      'self-test-failed',
      '公开 CONNECT 未固定到已审计地址',
    );
    await assertRejects('egress-denied', async () =>
      resolveProxyDestination('127.0.0.1:443', resolver),
    );
    await assertRejects('egress-denied', async () =>
      resolveProxyDestination('example.com:80', resolver),
    );
    const deprecatedAnycastResolver = createValidatedDirectDnsResolver(
      sampleManifest().networkPolicy.resolver,
      () => ({
        setServers() {},
        async resolve4() {
          return ['192.88.99.2'];
        },
      }),
    );
    await assertRejects('public-resolution-failed', async () =>
      resolveProxyDestination(
        'example.com:443',
        deprecatedAnycastResolver,
      ),
    );
  });
  await test('每次 CONNECT 都用显式 resolver 重查且不回退', async () => {
    let lookups = 0;
    const resolver = createValidatedDirectDnsResolver(
      sampleManifest().networkPolicy.resolver,
      () => ({
        setServers() {},
        async resolve4() {
          lookups += 1;
          if (lookups === 1) return ['93.184.216.34'];
          throw new Error('controlled resolver failure');
        },
      }),
    );
    await resolveProxyDestination('example.com:443', resolver);
    await assertRejects('public-resolution-failed', async () =>
      resolveProxyDestination('example.com:443', resolver),
    );
    assert(
      lookups === 2,
      'self-test-failed',
      'CONNECT 没有逐次调用显式 resolver',
    );
  });
  await test('跨主机派生请求也逐一执行公开地址门', async () => {
    const seen = [];
    const resolver = async (hostname) => {
      seen.push(hostname);
      return [{address: '93.184.216.34', family: 4}];
    };
    await resolveProxyDestination('first.example:443', resolver);
    await resolveProxyDestination('redirect.example:443', resolver);
    assert(
      canonical(seen) ===
        canonical(['first.example', 'redirect.example']),
      'self-test-failed',
      '派生主机未逐一经过代理解析',
    );
  });
  await test('本地 CONNECT 代理只绑定 loopback 且可清理', async () => {
    const proxy = await startPublicHttpsProxy(
      async () => [{address: '93.184.216.34', family: 4}],
    );
    assert(
      Number.isSafeInteger(proxy.port) && proxy.port > 0,
      'self-test-failed',
      '本地代理端口无效',
    );
    await proxy.close();
  });
  await test('明文 HTTP 拒绝与 CONNECT 拒绝分开计数且只保留安全枚举', async () => {
    const proxy = await startPublicHttpsProxy(
      async () => [{address: '93.184.216.34', family: 4}],
    );
    const sensitiveHostname = 'plaintext-sensitive.invalid';
    const sensitiveToken = 'private-query-token';
    const client = netConnect({host: '127.0.0.1', port: proxy.port});
    client.on('error', () => {});
    await new Promise((resolveResponse, rejectResponse) => {
      const timer = setTimeout(() => {
        client.destroy();
        rejectResponse(
          new VerificationError('self-test-failed', '明文代理响应超时'),
        );
      }, 2_000);
      client.once('connect', () => {
        client.write(
          'GET http://' +
            sensitiveHostname +
            '/?' +
            sensitiveToken +
            ' HTTP/1.1\r\n' +
            'Host: ' +
            sensitiveHostname +
            '\r\nConnection: close\r\n\r\n',
        );
      });
      client.once('data', (chunk) => {
        clearTimeout(timer);
        client.destroy();
        if (!chunk.toString('ascii').startsWith('HTTP/1.1 403')) {
          rejectResponse(
            new VerificationError('self-test-failed', '明文代理未拒绝请求'),
          );
          return;
        }
        resolveResponse();
      });
    });
    await proxy.close();
    const evidence = proxy.evidence;
    assert(
      evidence.deniedConnectCount === 0 &&
        evidence.deniedPlaintextRequestCount === 1 &&
        evidence.plaintextRequestCount === 1 &&
        evidence.plaintextRequestClassCounts['absolute-http'] === 1 &&
        Object.values(evidence.plaintextRequestClassCounts).reduce(
          (sum, count) => sum + count,
          0,
        ) === 1,
      'self-test-failed',
      '明文 HTTP 与 CONNECT 计数未隔离',
    );
    assertPrivateReport(evidence, [sensitiveHostname, sensitiveToken]);
  });
  await test('非法 CONNECT 只记录固定拒绝原因', async () => {
    const proxy = await startPublicHttpsProxy(
      async () => [{address: '93.184.216.34', family: 4}],
    );
    const client = netConnect({host: '127.0.0.1', port: proxy.port});
    client.on('error', () => {});
    await new Promise((resolveResponse, rejectResponse) => {
      const timer = setTimeout(() => {
        client.destroy();
        rejectResponse(
          new VerificationError('self-test-failed', 'CONNECT 拒绝响应超时'),
        );
      }, 2_000);
      client.once('connect', () => {
        client.write(
          'CONNECT forbidden.example:80 HTTP/1.1\r\n' +
            'Host: forbidden.example:80\r\n\r\n',
        );
      });
      client.once('data', (chunk) => {
        clearTimeout(timer);
        client.destroy();
        if (!chunk.toString('ascii').startsWith('HTTP/1.1 403')) {
          rejectResponse(
            new VerificationError('self-test-failed', '非法 CONNECT 未拒绝'),
          );
          return;
        }
        resolveResponse();
      });
    });
    await proxy.close();
    assert(
      proxy.evidence.deniedConnectCount === 1 &&
        proxy.evidence.deniedConnectReasonCounts['invalid-authority'] === 1 &&
        Object.values(proxy.evidence.deniedConnectReasonCounts).reduce(
          (sum, count) => sum + count,
          0,
        ) === 1 &&
        proxy.evidence.deniedPlaintextRequestCount === 0,
      'self-test-failed',
      'CONNECT 拒绝原因计数错误',
    );
  });
  await test('代理关闭会等待 DNS 且禁止迟到外连', async () => {
    let connectorCalls = 0;
    let releaseResolver = null;
    let resolverStarted = false;
    const proxy = await startPublicHttpsProxy(
      async () =>
        new Promise((resolveLookup) => {
          resolverStarted = true;
          releaseResolver = resolveLookup;
        }),
      () => {
        connectorCalls += 1;
        fail('self-test-failed', '代理关闭后仍创建了外连');
      },
    );
    const client = netConnect({
      host: '127.0.0.1',
      port: proxy.port,
    });
    client.on('error', () => {});
    client.once('connect', () => {
      client.write(
        'CONNECT delayed.example:443 HTTP/1.1\r\n' +
          'Host: delayed.example:443\r\n\r\n',
      );
    });
    for (let attempt = 0; attempt < 50 && !resolverStarted; attempt += 1) {
      await delay(10);
    }
    assert(
      resolverStarted && releaseResolver,
      'self-test-failed',
      '未触发受控 DNS 任务',
    );
    const closePromise = proxy.close();
    releaseResolver([{address: '93.184.216.34', family: 4}]);
    await closePromise;
    client.destroy();
    assert(
      connectorCalls === 0,
      'self-test-failed',
      '关闭后迟到 DNS 触发了外连',
    );
  });
  await test('TLS 隧道对端提前断开不会触发未处理 EPIPE', async () => {
    const upstreamSockets = new Set();
    const upstream = createNetServer((socket) => {
      upstreamSockets.add(socket);
      socket.on('error', () => {});
      socket.once('close', () => upstreamSockets.delete(socket));
      const timer = setInterval(() => {
        if (!socket.destroyed) socket.write(Buffer.alloc(4_096));
      }, 5);
      socket.once('close', () => clearInterval(timer));
    });
    await new Promise((resolveListen, rejectListen) => {
      upstream.once('error', rejectListen);
      upstream.listen(0, '127.0.0.1', resolveListen);
    });
    const upstreamAddress = upstream.address();
    assert(
      upstreamAddress && typeof upstreamAddress === 'object',
      'self-test-failed',
      '受控上游未绑定端口',
    );
    const proxy = await startPublicHttpsProxy(
      async () => [{address: '93.184.216.34', family: 4}],
      () =>
        netConnect({
          host: '127.0.0.1',
          port: upstreamAddress.port,
        }),
    );
    const client = netConnect({host: '127.0.0.1', port: proxy.port});
    client.on('error', () => {});
    await new Promise((resolveTunnel, rejectTunnel) => {
      const timer = setTimeout(() => {
        client.destroy();
        rejectTunnel(
          new VerificationError('self-test-failed', 'TLS 隧道建立超时'),
        );
      }, 2_000);
      client.once('connect', () => {
        client.write(
          'CONNECT disconnect.example:443 HTTP/1.1\r\n' +
            'Host: disconnect.example:443\r\n\r\n',
        );
      });
      client.once('data', (chunk) => {
        clearTimeout(timer);
        if (!chunk.toString('ascii').startsWith('HTTP/1.1 200')) {
          client.destroy();
          rejectTunnel(
            new VerificationError(
              'self-test-failed',
              '受控 TLS 隧道未建立',
            ),
          );
          return;
        }
        client.destroy();
        resolveTunnel();
      });
    });
    await delay(50);
    await proxy.close();
    for (const socket of upstreamSockets) socket.destroy();
    await new Promise((resolveClose) => upstream.close(resolveClose));
  });
  await test('联网确认绑定 manifest 摘要', async () => {
    const options = {
      app: '/tmp/example.app',
      binary: null,
      buildIdentity: '/tmp/identity.json',
      buildIdentitySha256: 'a'.repeat(64),
      confirmLiveNetwork: 'b'.repeat(64),
      hmacKeyFile: '/tmp/key',
      report: '/tmp/report',
    };
    validateLiveOptions(options, 'b'.repeat(64));
    options.confirmLiveNetwork = 'c'.repeat(64);
    await assertRejects('network-confirmation-required', async () =>
      validateLiveOptions(options, 'b'.repeat(64)),
    );
  });
  await test('真实模式拒绝缺少 build identity', async () => {
    const options = {
      app: '/tmp/example.app',
      binary: null,
      buildIdentity: null,
      buildIdentitySha256: null,
      confirmLiveNetwork: 'b'.repeat(64),
      hmacKeyFile: '/tmp/key',
      report: '/tmp/report',
    };
    await assertRejects('invalid-arguments', async () =>
      validateLiveOptions(options, 'b'.repeat(64)),
    );
  });
  await test('build identity stub 绑定固定摘要', async () => {
    const digest = 'a'.repeat(64);
    const identity = await verifyBuildIdentity(
      {
        buildIdentity: '/tmp/identity.json',
        buildIdentitySha256: digest,
      },
      {appPath: '/tmp/Chromium.app'},
      async (args) => {
        assert(
          args.includes('--expected-sha256') && args.includes(digest),
          'self-test-failed',
          'build identity stub 未收到固定摘要',
        );
        return JSON.stringify({
          checks: {pinnedManifestDigest: true},
          manifest: {sha256: digest},
          qualification: 'diagnostic-only',
          verified: true,
        });
      },
    );
    assert(
      identity.verified &&
        identity.manifestSha256 === digest &&
        identity.qualification === 'diagnostic-only',
      'self-test-failed',
      'build identity 结果未收口',
    );
  });
  await test('build identity stub 拒绝摘要漂移', async () => {
    const digest = 'a'.repeat(64);
    await assertRejects('build-identity-invalid', async () =>
      verifyBuildIdentity(
        {
          buildIdentity: '/tmp/identity.json',
          buildIdentitySha256: digest,
        },
        {appPath: '/tmp/Chromium.app'},
        async () =>
          JSON.stringify({
            checks: {pinnedManifestDigest: true},
            manifest: {sha256: 'b'.repeat(64)},
            qualification: 'diagnostic-only',
            verified: true,
          }),
      ),
    );
  });
  await test('build identity stub 拒绝非白名单 qualification', async () => {
    const digest = 'a'.repeat(64);
    await assertRejects('build-identity-invalid', async () =>
      verifyBuildIdentity(
        {
          buildIdentity: '/tmp/identity.json',
          buildIdentitySha256: digest,
        },
        {appPath: '/tmp/Chromium.app'},
        async () =>
          JSON.stringify({
            checks: {pinnedManifestDigest: true},
            manifest: {sha256: digest},
            qualification: 'diagnostic-only https://secret.invalid/',
            verified: true,
          }),
      ),
    );
  });
  await test('trace 接受 schema 2 observed', async () => {
    const records = parseTraceRecords([validTraceEvent()], 8);
    assert(
      records.length === 1 && records[0].skipped === false,
      'self-test-failed',
      'observed trace 未解析',
    );
  });
  await test('trace 接受严格 skipped', async () => {
    const records = parseTraceRecords(
      [
        validTraceEvent({
          args: {
            opcodes: 0,
            signature_hi: 0,
            signature_lo: 0,
            status_code: 1,
          },
        }),
      ],
      8,
    );
    assert(records[0].skipped, 'self-test-failed', 'skipped trace 未解析');
  });
  await test('trace 拒绝未知字段', async () => {
    const event = validTraceEvent();
    event.args.extra = 1;
    await assertRejects('trace-invalid', async () =>
      parseTraceRecords([event], 8),
    );
  });
  await test('trace 拒绝 data loss', async () => {
    const collector = new TraceCollector(8);
    collector.collect({value: [validTraceEvent()]});
    await assertRejects('trace-invalid', async () =>
      collector.finish({dataLossOccurred: true}),
    );
  });
  await test('暂停页面先流水启用观察再恢复避免死锁', async () => {
    const commands = [];
    let releaseNetwork = null;
    const fakeClient = {
      command(method) {
        commands.push(method);
        if (method === 'Network.enable') {
          return new Promise((resolveNetwork) => {
            releaseNetwork = resolveNetwork;
          });
        }
        if (method === 'Runtime.runIfWaitingForDebugger') {
          releaseNetwork();
        }
        return Promise.resolve({});
      },
    };
    await enableAndResumePausedPage(fakeClient, 100);
    assert(
      canonical(commands) ===
        canonical([
          'Inspector.enable',
          'Page.enable',
          'Network.enable',
          'Runtime.enable',
          'Runtime.runIfWaitingForDebugger',
        ]),
      'self-test-failed',
      '暂停页面观察命令未在恢复前全部发送',
    );
  });
  await test('扁平 CDP session 隔离命令与页面事件', async () => {
    const sent = [];
    const socketListeners = new Map();
    const socket = {
      readyState: WebSocket.OPEN,
      addEventListener(type, listener) {
        const listeners = socketListeners.get(type) || new Set();
        listeners.add(listener);
        socketListeners.set(type, listeners);
      },
      close() {
        this.readyState = WebSocket.CLOSED;
      },
      removeEventListener(type, listener) {
        socketListeners.get(type)?.delete(listener);
      },
      send(value) {
        sent.push(JSON.parse(value));
      },
    };
    const client = new CdpClient(socket, 100);
    const sessionId = 'a'.repeat(32);
    const session = new CdpSession(client, sessionId);
    let browserEventCount = 0;
    let sessionEventCount = 0;
    client.on('Page.domContentEventFired', () => {
      browserEventCount += 1;
    });
    session.on('Page.domContentEventFired', () => {
      sessionEventCount += 1;
    });
    const command = session.command('Runtime.enable', {}, 100);
    assert(
      sent.length === 1 &&
        sent[0].method === 'Runtime.enable' &&
        sent[0].sessionId === sessionId,
      'self-test-failed',
      '扁平 session 命令未绑定 sessionId',
    );
    await client.handleMessage({
      data: JSON.stringify({
        id: sent[0].id,
        result: {},
        sessionId,
      }),
    });
    await command;
    await client.handleMessage({
      data: JSON.stringify({
        method: 'Page.domContentEventFired',
        params: {timestamp: 1},
        sessionId,
      }),
    });
    assert(
      browserEventCount === 0 && sessionEventCount === 1,
      'self-test-failed',
      '扁平 session 页面事件发生跨 session 泄漏',
    );
  });
  await test('CDP 错误只报告固定方法枚举', async () => {
    const known = new VerificationError(
      'cdp-error',
      'known',
      'Target.createTarget',
    );
    const unknown = new VerificationError(
      'cdp-error',
      'unknown',
      'Secret.rawCommand',
    );
    assert(
      errorCdpMethod(known) === 'Target.createTarget' &&
        errorCdpMethod(unknown) === null,
      'self-test-failed',
      'CDP 方法诊断未受固定枚举约束',
    );
  });
  await test('崩溃监听先于发现和枚举并覆盖次级 target', async () => {
    const commands = [];
    const listeners = new Map();
    const fakeClient = {
      eventError: null,
      async command(method) {
        commands.push(method);
        return {};
      },
      on(method, listener) {
        commands.push('listen:' + method);
        listeners.set(method, listener);
        return () => listeners.delete(method);
      },
    };
    const remove = await installTargetCrashObservation(fakeClient, 100);
    await fakeClient.command('Target.getTargets');
    await enablePageObservation(fakeClient, 100);
    listeners.get('Target.targetCrashed')({targetId: 'secondary-worker'});
    assert(
      canonical(commands) ===
        canonical([
          'listen:Target.targetCrashed',
          'Target.setDiscoverTargets',
          'Target.getTargets',
          'Inspector.enable',
          'Page.enable',
          'Network.enable',
          'Runtime.enable',
        ]) &&
        errorCode(fakeClient.eventError) === 'renderer-crash',
      'self-test-failed',
      'renderer 崩溃观察顺序或分类错误',
    );
    remove();
  });
  await test('页面健康检查后仍拒绝 browser 或 page 事件错误', async () => {
    await assertRejects('renderer-crash', async () =>
      assertClientEventsHealthy(
        [
          {eventError: null},
          {
            eventError: new VerificationError(
              'renderer-crash',
              '次级 target 收尾崩溃',
            ),
          },
        ],
        '收尾事件失败',
      ),
    );
  });
  await test('renderer 归因接受 renderer', async () => {
    const records = parseTraceRecords([validTraceEvent()], 8);
    const summary = summarizeTrace(
      records,
      [
        [{id: 42, type: 'renderer'}],
        [{id: 42, type: 'renderer'}],
      ],
      1,
    );
    assert(
      summary.capReached && summary.rendererEmitterCount === 1,
      'self-test-failed',
      'renderer 归因或 capReached 错误',
    );
  });
  await test('renderer 归因拒绝非 renderer', async () => {
    const records = parseTraceRecords([validTraceEvent()], 8);
    await assertRejects('attribution-invalid', async () =>
      summarizeTrace(
        records,
        [
          [{id: 42, type: 'browser'}],
          [{id: 42, type: 'browser'}],
        ],
        5,
      ),
    );
  });
  await test('renderer 归因拒绝超过进程硬上限', async () => {
    const records = parseTraceRecords(
      [validTraceEvent(), validTraceEvent()],
      8,
    );
    await assertRejects('trace-invalid', async () =>
      summarizeTrace(
        records,
        [
          [{id: 42, type: 'renderer'}],
          [{id: 42, type: 'renderer'}],
        ],
        1,
      ),
    );
  });
  await test('breakage 识别 ON 回归', async () => {
    assert(
      classifyBreakage(
        {pageOutcome: 'ok'},
        {pageOutcome: 'renderer-crash'},
      ) === 'on-regression',
      'self-test-failed',
      '未识别 ON 回归',
    );
  });
  await test('breakage 识别共享失败', async () => {
    assert(
      classifyBreakage(
        {pageOutcome: 'timeout'},
        {pageOutcome: 'timeout'},
      ) === 'shared-failure',
      'self-test-failed',
      '未识别共享失败',
    );
  });
  await test('live network 只由固定 CONNECT 证据派生', async () => {
    assert(
      runObservedLiveNetwork({
        egress: {allowedConnectCount: 1, pinnedResolutionCount: 1},
      }) === true &&
        runObservedLiveNetwork({
          egress: {allowedConnectCount: 0, pinnedResolutionCount: 0},
        }) === false &&
        runObservedLiveNetwork({
          egress: {allowedConnectCount: 2, pinnedResolutionCount: 1},
        }) === false &&
        runObservedLiveNetwork({}) === false,
      'self-test-failed',
      'live network 仍可能由常量或无效 CONNECT 证据声明',
    );
  });
  await test('共享页面失败不能通过报告', async () => {
    const report = sampleBuiltReport(
      samplePublicRun('off', 'http-error', 0),
      samplePublicRun('on', 'http-error', 1),
    );
    assert(report.passed === false, 'self-test-failed', '共享失败被误判通过');
  });
  await test('ON 零信号不能通过报告', async () => {
    const report = sampleBuiltReport(
      samplePublicRun('off', 'ok', 0),
      samplePublicRun('on', 'ok', 0),
    );
    assert(report.passed === false, 'self-test-failed', 'ON 零信号被误判通过');
  });
  await test('健康 AB 且 ON 有信号可通过研究门', async () => {
    const report = sampleBuiltReport(
      samplePublicRun('off', 'ok', 0),
      samplePublicRun('on', 'ok', 1),
    );
    assert(
      report.passed === true &&
        report.target.lockHeldAcrossRun === true &&
        report.runner.stable === true &&
        canonical(Object.keys(report.target.buildIdentity).sort()) ===
          canonical(['manifestSha256', 'qualification', 'verified']),
      'self-test-failed',
      '健康研究报告边界错误',
    );
  });
  await test('研究完成退出码严格区分通过和失败', async () => {
    assert(
      canonical(completedResearchDisposition({passed: true})) ===
        canonical({exitCode: 2, stream: 'stdout'}) &&
        canonical(completedResearchDisposition({passed: false})) ===
          canonical({exitCode: 1, stream: 'stderr'}),
      'self-test-failed',
      '研究完成退出码或输出流错误',
    );
  });
  await test('runner 复核只公开固定摘要和状态', async () => {
    const before = {
      fileIdentity: {size: 1},
      realPath: '/private/runner.mjs',
      runnerSha256: '1'.repeat(64),
    };
    const stable = await reverifyRunnerIdentity(
      before,
      '/entry/runner.mjs',
      async () => ({...before}),
    );
    const drifted = await reverifyRunnerIdentity(
      before,
      '/entry/runner.mjs',
      async () => ({...before, runnerSha256: '2'.repeat(64)}),
    );
    const unavailable = await reverifyRunnerIdentity(
      before,
      '/entry/runner.mjs',
      async () => {
        throw new Error('unavailable');
      },
    );
    assert(
      canonical(Object.keys(stable).sort()) ===
        canonical(['runnerSha256', 'stable', 'verified']) &&
        stable.stable === true &&
        stable.verified === true &&
        drifted.stable === false &&
        drifted.verified === true &&
        unavailable.stable === false &&
        unavailable.verified === false &&
        !canonical(stable).includes('/private/runner.mjs'),
      'self-test-failed',
      'runner 复核摘要、漂移或隐私边界错误',
    );
    await assertRejects('runner-mutated', async () =>
      assertStableRunner(drifted),
    );
  });
  await test('runner 真实文件摘要可稳定复核', async () => {
    const before = await captureRunnerIdentity();
    const evidence = await reverifyRunnerIdentity(before);
    assert(
      evidence.stable === true &&
        evidence.verified === true &&
        /^[0-9a-f]{64}$/u.test(evidence.runnerSha256),
      'self-test-failed',
      'runner 真实文件复核失败',
    );
  });
  await test('正常报告拒绝未稳定 runner', async () => {
    await assertRejects('runner-mutated', async () =>
      sampleBuiltReport(
        samplePublicRun('off', 'ok', 0),
        samplePublicRun('on', 'ok', 1),
        {
          runnerSha256: '9'.repeat(64),
          stable: false,
          verified: true,
        },
      ),
    );
  });
  await test('批次 HMAC 稳定且跨批次不可关联', async () => {
    const key = Buffer.alloc(32, 7);
    const saltA = Buffer.alloc(32, 1);
    const saltB = Buffer.alloc(32, 2);
    const first = batchHmacId(
      key,
      saltA,
      'site-v1',
      'https://example.com/',
    );
    const repeat = batchHmacId(
      key,
      saltA,
      'site-v1',
      'https://example.com/',
    );
    const other = batchHmacId(
      key,
      saltB,
      'site-v1',
      'https://example.com/',
    );
    assert(
      first === repeat && first !== other && /^[0-9a-f]{32}$/u.test(first),
      'self-test-failed',
      '批次 HMAC 语义错误',
    );
  });
  await test('站点顺序在报告前随机排列且不修改输入', async () => {
    const input = [{batchSiteId: 'a'}, {batchSiteId: 'b'}];
    const output = shuffledSites(input, () => 0);
    assert(
      output[0].batchSiteId === 'b' &&
        output[1].batchSiteId === 'a' &&
        input[0].batchSiteId === 'a',
      'self-test-failed',
      '站点随机排列未隔离 manifest 顺序',
    );
  });
  await test('全局崩溃增量只返回数量', async () => {
    const before = new Map([['private-path-a', '1:1']]);
    const after = new Map([
      ['private-path-a', '1:1'],
      ['private-path-b', '2:2'],
    ]);
    assert(
      globalCrashDelta(before, after) === 1,
      'self-test-failed',
      '全局崩溃增量错误',
    );
  });
  await test('全局崩溃筛选只归属 Chromium 并排除 AegisUITests', async () => {
    const root = await mkdtemp(join(tmpdir(), PROFILE_PREFIX));
    try {
      await writeFile(join(root, 'Chromium-2026-01-01.ips'), 'chromium');
      await writeFile(
        join(root, 'Chromium Helper (Renderer)-2026-01-01.crash'),
        'chromium-helper',
      );
      await writeFile(
        join(root, 'AegisUITests-Runner-2026-01-01.ips'),
        'ios-test',
      );
      await writeFile(join(root, 'Google Chrome-2026-01-01.ips'), 'chrome');
      await writeFile(join(root, 'Chromium-2026-01-01.txt'), 'not-crash');
      const records = await globalCrashArtifacts(root, true, 1);
      const names = [...records.keys()].map((path) => basename(path)).sort();
      assert(
        canonical(names) ===
          canonical([
            'Chromium Helper (Renderer)-2026-01-01.crash',
            'Chromium-2026-01-01.ips',
          ]),
        'self-test-failed',
        '全局崩溃筛选错误归属非 Chromium 资料',
      );
    } finally {
      await rm(root, {force: true, recursive: true});
    }
  });
  await test('专用 profile 关闭 alternate error pages 与 network time', async () => {
    const root = await mkdtemp(join(tmpdir(), PROFILE_PREFIX));
    const profileDir = join(root, 'profile');
    try {
      await initializeResearchProfile(profileDir);
      const preferencesPath = join(profileDir, 'Default', 'Preferences');
      const preferences = JSON.parse(await readFile(preferencesPath, 'utf8'));
      const localStatePath = join(profileDir, 'Local State');
      const localState = JSON.parse(await readFile(localStatePath, 'utf8'));
      const preferencesMetadata = await stat(preferencesPath);
      const localStateMetadata = await stat(localStatePath);
      assert(
        canonical(preferences) ===
            canonical({alternate_error_pages: {enabled: false}}) &&
          canonical(localState) ===
            canonical({
              network_time: {network_time_queries_enabled: false},
            }) &&
          (preferencesMetadata.mode & 0o777) === 0o600 &&
          (localStateMetadata.mode & 0o777) === 0o600,
        'self-test-failed',
        '专用 profile 未安全关闭后台诊断请求',
      );
    } finally {
      await rm(root, {force: true, recursive: true});
    }
  });
  await test('A/B 模式都禁用 network time 且只切换 shadow feature', async () => {
    const off = modeArguments('off', 7);
    const on = modeArguments('on', 7);
    assert(
      off.includes(
        '--disable-features=AegisBytecodeShadow,NetworkTimeServiceQuerying',
      ) &&
        !off.some((entry) => entry.startsWith('--enable-features=')) &&
        on.includes('--enable-features=AegisBytecodeShadow') &&
        on.includes('--disable-features=NetworkTimeServiceQuerying') &&
        off.at(-1) === '--js-flags=--aegis-bytecode-shadow-max-records=7' &&
        on.at(-1) === '--js-flags=--aegis-bytecode-shadow-max-records=7',
      'self-test-failed',
      'A/B 模式后台隔离或 shadow feature 参数错误',
    );
  });
  await test('诊断超限且尾部 FATAL 必须 fail closed', async () => {
    const accumulator = new DiagnosticAccumulator(16);
    accumulator.observe(Buffer.from('0123456789abcdef'));
    accumulator.observe(Buffer.from(' tail FATAL'));
    const evidence = {
      ...accumulator.evidence(),
      globalCrashDeltaCount: 0,
      profileCrashArtifactCount: 0,
    };
    assert(
      evidence.signalCount === 0 &&
        diagnosticFailureCode(evidence) === 'diagnostic-truncated',
      'self-test-failed',
      '诊断截断可能隐藏尾部崩溃信号',
    );
    accumulator.clear();
  });
  await test('隐私审计接受聚合报告', async () => {
    assertPrivateReport(
      {
        batch: {batchId: 'a'.repeat(32)},
        telemetry: {recordCount: 3},
      },
      [],
    );
  });
  await test('隐私审计拒绝禁止字段', async () => {
    for (const field of [
      'url',
      'host',
      'title',
      'pid',
      'signature',
      'rawTrace',
      'rawLog',
    ]) {
      await assertRejects('privacy-violation', async () =>
        assertPrivateReport({[field]: 'secret'}, []),
      );
    }
  });
  await test('隐私审计拒绝地址字符串', async () => {
    await assertRejects('privacy-violation', async () =>
      assertPrivateReport(
        {value: 'prefix https://example.com/ suffix'},
        [],
      ),
    );
    await assertRejects('privacy-violation', async () =>
      assertPrivateReport(
        {value: 'prefix example.com suffix'},
        ['example.com'],
      ),
    );
  });
  await test('报告拒绝覆盖', async () => {
    const root = await mkdtemp(join(tmpdir(), PROFILE_PREFIX));
    const path = join(root, 'report.json');
    try {
      await writeJsonExclusive(path, {passed: false});
      await assertRejects('report-exists', async () =>
        writeJsonExclusive(path, {passed: true}),
      );
    } finally {
      await rm(root, {force: true, recursive: true});
    }
  });
  await test('最终提交门在中断后拒绝写通过报告', async () => {
    const root = await mkdtemp(join(tmpdir(), PROFILE_PREFIX));
    const path = join(root, 'report.json');
    requestedSignal = null;
    handleTerminationSignal('SIGINT');
    handleTerminationSignal('SIGTERM');
    try {
      assert(
        requestedSignal === 'SIGINT',
        'self-test-failed',
        '重复信号覆盖了首次中断证据',
      );
      await assertRejects('interrupted', async () =>
        writeJsonExclusive(path, {passed: true}, assertNotInterrupted),
      );
      assert(
        (await lstat(path).catch(() => null)) === null,
        'self-test-failed',
        '中断后仍提交了通过报告',
      );
    } finally {
      requestedSignal = null;
      await rm(root, {force: true, recursive: true});
    }
  });
  await test('报告路径拒绝与 build lock 重叠', async () => {
    const root = await mkdtemp(join(tmpdir(), PROFILE_PREFIX));
    const appPath = join(root, 'out', 'Chromium.app');
    const executable = join(appPath, 'Contents', 'MacOS', 'Chromium');
    const manifestPath = join(root, 'sites.json');
    const keyPath = join(root, 'key');
    const identityPath = join(root, 'identity.json');
    await mkdir(dirname(executable), {recursive: true});
    await writeFile(executable, 'binary');
    await writeFile(manifestPath, '{}');
    await writeFile(keyPath, Buffer.alloc(32));
    await writeFile(identityPath, '{}');
    try {
      await assertRejects('report-invalid', async () =>
        validateReportPath(
          {
            buildIdentity: identityPath,
            hmacKeyFile: keyPath,
            manifest: manifestPath,
            report: join(
              root,
              'out',
              '.aegis',
              'build.lock',
              'report.json',
            ),
          },
          {appPath, executable},
          RUNNER_ENTRY_PATH,
        ),
      );
    } finally {
      await rm(root, {force: true, recursive: true});
    }
  });
  await test('失败报告按清理证据标记资料残留', async () => {
    const context = {
      batchGlobalCrashAuditVerified: false,
      batchGlobalCrashDeltaCount: null,
      batchId: 'a'.repeat(32),
      buildIdentity: null,
      buildLockHeldAcrossRun: true,
      completedRuns: 1,
      hmacNonce: 'b'.repeat(64),
      manifestCommitment: 'd'.repeat(32),
      pairs: [
        {
          batchSiteId: 'c'.repeat(32),
          breakage: 'incomplete',
          order: 'AB',
          round: 1,
          runs: [
            {
              cleanup: {
                artifactsRetained: true,
                verified: false,
              },
              diagnostics: {
                globalCrashAuditVerified: false,
                globalCrashDeltaCount: -1,
              },
            },
          ],
        },
      ],
      plannedRuns: 2,
      runner: {
        runnerSha256: 'e'.repeat(64),
        stable: true,
        verified: true,
      },
      startedAt: '2026-01-01T00:00:00.000Z',
    };
    const report = buildFailureReport(context, 'cleanup-failure');
    assert(
      report.privacy.rawArtifactsPersisted === true &&
        report.privacy.temporaryArtifactsRetained === true &&
        report.batch.liveNetworkAuthorized === true &&
        report.batch.liveNetworkConfirmed === false &&
        report.batch.liveNetworkObserved === false &&
        canonical(Object.keys(report.runner).sort()) ===
          canonical(['runnerSha256', 'stable', 'verified']),
      'self-test-failed',
      '失败报告未保守标记资料残留或 runner 字段错误',
    );
  });
  await test('失败报告区分全局 raw 与临时资料三态', async () => {
    const base = {
      batchId: 'a'.repeat(32),
      buildIdentity: null,
      buildLockHeldAcrossRun: true,
      completedRuns: 0,
      hmacNonce: 'b'.repeat(64),
      manifestCommitment: 'd'.repeat(32),
      pairs: [],
      plannedRuns: 2,
      runner: {
        runnerSha256: 'e'.repeat(64),
        stable: true,
        verified: true,
      },
      startedAt: '2026-01-01T00:00:00.000Z',
    };
    const unknown = buildFailureReport(
      {
        ...base,
        batchGlobalCrashAuditVerified: false,
        batchGlobalCrashDeltaCount: null,
      },
      'internal-error',
    );
    const clean = buildFailureReport(
      {
        ...base,
        batchGlobalCrashAuditVerified: true,
        batchGlobalCrashDeltaCount: 0,
      },
      'navigation-error',
    );
    const globalArtifact = buildFailureReport(
      {
        ...base,
        batchGlobalCrashAuditVerified: true,
        batchGlobalCrashDeltaCount: 1,
      },
      'runtime-crash-signal',
    );
    assert(
      unknown.privacy.rawArtifactsPersisted === null &&
        unknown.privacy.temporaryArtifactsRetained === false &&
        clean.privacy.rawArtifactsPersisted === false &&
        clean.privacy.temporaryArtifactsRetained === false &&
        globalArtifact.privacy.rawArtifactsPersisted === true &&
        globalArtifact.privacy.temporaryArtifactsRetained === false,
      'self-test-failed',
      '失败报告 raw/temp 三态错误',
    );
  });
  await test('build lock 覆盖运行并 fail closed', async () => {
    const root = await mkdtemp(join(tmpdir(), PROFILE_PREFIX));
    const appPath = join(root, 'out', 'Chromium.app');
    await mkdir(appPath, {recursive: true});
    let release = null;
    try {
      release = await acquireBuildOperationLock({appPath});
      await assertRejects('build-lock-busy', async () =>
        acquireBuildOperationLock({appPath}),
      );
      await release();
      release = null;
      const releaseAgain = await acquireBuildOperationLock({appPath});
      await releaseAgain();
    } finally {
      await release?.().catch(() => {});
      await rm(root, {force: true, recursive: true});
    }
  });
  await test('失败清理删除 profile 诊断和 trace 占位并终止进程', async () => {
    const root = await mkdtemp(join(tmpdir(), PROFILE_PREFIX));
    const profileDir = join(root, 'profile');
    await mkdir(profileDir, {recursive: true});
    await writeFile(join(root, 'diagnostic.log'), 'sensitive');
    await writeFile(join(root, 'capture.trace'), 'sensitive');
    await writeFile(join(root, 'renderer.dmp'), 'sensitive');
    const child = spawn(
      '/bin/sh',
      [
        '-c',
        'trap "exit 0" TERM INT; while :; do /bin/sleep 1; done',
        'aegis-shadow-cleanup-selftest',
        '--user-data-dir=' + profileDir,
      ],
      {detached: true, stdio: 'ignore'},
    );
    const closePromise = new Promise((resolveClose) => {
      child.once('close', resolveClose);
    });
    await delay(100);
    const cleanup = await cleanupRunArtifacts(
      root,
      profileDir,
      child,
      closePromise,
    );
    assert(
      cleanup.verified &&
        cleanup.temporaryRootRemoved &&
        cleanup.residualOwnedProcessCount === 0 &&
        cleanup.crashArtifactCount === 1,
      'self-test-failed',
      '失败清理验证未通过',
    );
  });

  process.stdout.write(
    JSON.stringify({
      kind: 'bytecode-shadow-sites-self-test',
      passed: true,
      tests: tests.length,
    }) + '\n',
  );
}

function selectedProtocol(manifest, pilotOverride) {
  const pilot =
    pilotOverride === null
      ? manifest.execution.defaultPilot
      : pilotOverride;
  return {
    pilot,
    rounds: pilot ? manifest.pilot.rounds : manifest.execution.fullRounds,
    sites: pilot
      ? manifest.sites.slice(0, manifest.pilot.maxSites)
      : manifest.sites,
  };
}

function shuffledSites(values, chooseIndex) {
  const result = values.map((entry) => ({...entry}));
  const choose = chooseIndex || ((limit) => randomInt(limit));
  for (let index = result.length - 1; index > 0; index -= 1) {
    const selectedIndex = choose(index + 1);
    assert(
      Number.isSafeInteger(selectedIndex) &&
        selectedIndex >= 0 &&
        selectedIndex <= index,
      'internal-error',
      '站点随机排列索引无效',
    );
    [result[index], result[selectedIndex]] = [
      result[selectedIndex],
      result[index],
    ];
  }
  return result;
}

function completedResearchDisposition(report) {
  return report.passed === true
    ? {exitCode: 2, stream: 'stdout'}
    : {exitCode: 1, stream: 'stderr'};
}

async function runLive(options, manifestEvidence) {
  validateLiveOptions(options, manifestEvidence.sha256);
  const runnerBefore = await captureRunnerIdentity();
  const manifest = manifestEvidence.document;
  const resolver = createValidatedDirectDnsResolver(
    manifest.networkPolicy.resolver,
  );
  const selected = selectedProtocol(manifest, options.pilot);
  const target = await resolveTarget(options);
  const reportPath = await validateReportPath(
    options,
    target,
    runnerBefore.realPath,
  );
  const key = await readHmacKey(options.hmacKeyFile);
  const salt = randomBytes(32);
  const batchId = batchHmacId(
    key,
    salt,
    'batch-v1',
    manifestEvidence.sha256,
  );
  const hmacNonce = salt.toString('hex');
  const manifestCommitment = batchHmacId(
    key,
    salt,
    'manifest-v1',
    manifestEvidence.sha256,
  );
  const sites = shuffledSites(
    selected.sites.map((entry) => ({
      batchSiteId: batchHmacId(key, salt, 'site-v1', entry.url),
      url: entry.url,
    })),
  );
  key.fill(0);
  salt.fill(0);
  const startedAt = new Date().toISOString();
  const plannedRuns = sites.length * selected.rounds * 2;
  const context = {
    batchGlobalCrashAuditVerified: false,
    batchGlobalCrashDeltaCount: null,
    batchId,
    buildIdentity: null,
    buildLockHeldAcrossRun: false,
    completedRuns: 0,
    hmacNonce,
    manifestCommitment,
    pairs: [],
    plannedRuns,
    runner: {
      runnerSha256: runnerBefore.runnerSha256,
      stable: false,
      verified: false,
    },
    startedAt,
  };
  const forbiddenStrings = [
    target.executable,
    target.appPath || '',
    options.manifest,
    options.hmacKeyFile,
    options.buildIdentity,
    reportPath,
    runnerBefore.realPath,
    manifestEvidence.sha256,
    ...sites.flatMap((site) => {
      const parsed = new URL(site.url);
      return [site.url, parsed.hostname];
    }),
  ];
  let reportWritten = false;
  let releaseBuildLock = null;
  let buildLockReleased = false;
  let batchGlobalCrashBefore = null;
  try {
    releaseBuildLock = await acquireBuildOperationLock(target);
    context.buildLockHeldAcrossRun = true;
    assertNotInterrupted();
    const identityBefore = await verifyBuildIdentity(options, target);
    context.buildIdentity = identityBefore;
    assertNotInterrupted();
    batchGlobalCrashBefore = await snapshotGlobalCrashes();
    for (const site of sites) {
      assertNotInterrupted();
      await resolvePublicSite(site.url, resolver);
      assertNotInterrupted();
    }
    const binarySha256 = await sha256File(target.executable);
    for (const [siteIndex, site] of sites.entries()) {
      for (let roundIndex = 0; roundIndex < selected.rounds; roundIndex += 1) {
        const order =
          manifest.execution.pairOrders[
            (siteIndex * selected.rounds + roundIndex) %
              manifest.execution.pairOrders.length
          ];
        const modes = [...order].map((label) =>
          label === 'A' ? 'off' : 'on',
        );
        const pairRecord = {
          batchSiteId: site.batchSiteId,
          breakage: 'incomplete',
          order,
          round: roundIndex + 1,
          runs: [],
        };
        context.pairs.push(pairRecord);
        for (const [positionIndex, mode] of modes.entries()) {
          assertNotInterrupted();
          const result = await runSingleMode(
            mode,
            site.url,
            target,
            manifest,
            resolver,
          );
          const publicResult = publicRunRecord(
            mode,
            positionIndex + 1,
            result,
          );
          pairRecord.runs.push(publicResult);
          context.completedRuns += 1;
          if (!result.cleanup.verified) {
            fail('cleanup-failure', '研究运行清理未通过');
          }
          assertNotInterrupted();
        }
        const offRun = pairRecord.runs.find((run) => run.mode === 'off');
        const onRun = pairRecord.runs.find((run) => run.mode === 'on');
        pairRecord.breakage = classifyBreakage(offRun, onRun);
      }
    }
    assertNotInterrupted();
    assert(
      (await sha256File(target.executable)) === binarySha256,
      'target-mutated',
      '被测可执行文件在批次期间发生变化',
    );
    assert(
      sha256Bytes(await readFile(options.manifest)) ===
        manifestEvidence.sha256,
      'manifest-mutated',
      'manifest 在批次期间发生变化',
    );
    const identityAfter = await verifyBuildIdentity(options, target);
    assertNotInterrupted();
    assert(
      canonical(identityBefore) === canonical(identityAfter),
      'build-identity-drift',
      '运行前后构建身份发生漂移',
    );
    await delay(GLOBAL_CRASH_OBSERVATION_MS);
    context.batchGlobalCrashDeltaCount = globalCrashDelta(
      batchGlobalCrashBefore,
      await snapshotGlobalCrashes(),
    );
    context.batchGlobalCrashAuditVerified = true;
    assertNotInterrupted();
    assert(
      context.batchGlobalCrashDeltaCount === 0,
      'runtime-crash-signal',
      '整批观察到新增全局崩溃资料',
    );
    context.runner = await reverifyRunnerIdentity(runnerBefore);
    assertStableRunner(context.runner);
    const report = buildReport({
      batchGlobalCrashDeltaCount: context.batchGlobalCrashDeltaCount,
      batchId,
      binarySha256,
      buildIdentity: identityAfter,
      completedAt: new Date().toISOString(),
      hmacNonce,
      manifest,
      manifestCommitment,
      pairs: context.pairs,
      pilot: selected.pilot,
      plannedRuns,
      runner: context.runner,
      startedAt,
    });
    await releaseBuildLock();
    buildLockReleased = true;
    assertNotInterrupted();
    assertPrivateReport(report, forbiddenStrings);
    await writeJsonExclusive(reportPath, report, assertNotInterrupted);
    reportWritten = true;
    const disposition = completedResearchDisposition(report);
    const summary =
      JSON.stringify({
        passed: report.passed,
        qualification: report.qualification,
        releaseEligible: report.releaseEligible,
        completedRuns: report.batch.completedRuns,
        exitCode: disposition.exitCode,
        outcome: report.passed
          ? 'research-complete'
          : 'research-failed',
        report: reportPath,
      }) + '\n';
    process[disposition.stream].write(summary);
    process.exitCode = disposition.exitCode;
  } catch (error) {
    let code = errorCode(error);
    if (
      batchGlobalCrashBefore instanceof Map &&
      context.batchGlobalCrashAuditVerified === false
    ) {
      try {
        await delay(250);
        context.batchGlobalCrashDeltaCount = globalCrashDelta(
          batchGlobalCrashBefore,
          await snapshotGlobalCrashes(),
        );
        context.batchGlobalCrashAuditVerified = true;
      } catch {
        context.batchGlobalCrashDeltaCount = null;
      }
    }
    context.runner = await reverifyRunnerIdentity(runnerBefore);
    if (!context.runner.verified || !context.runner.stable) {
      code = 'runner-mutated';
    }
    if (releaseBuildLock && !buildLockReleased) {
      try {
        await releaseBuildLock();
        buildLockReleased = true;
      } catch {
        code = 'build-lock-release-failed';
      }
    }
    if (!reportWritten) {
      const failureReport = buildFailureReport(context, code);
      assertPrivateReport(failureReport, forbiddenStrings);
      await writeJsonExclusive(reportPath, failureReport);
      reportWritten = true;
    }
    process.stderr.write(
      JSON.stringify({
        passed: false,
        qualification: 'research-only',
        releaseEligible: false,
        failureCode: code,
      }) + '\n',
    );
    process.exitCode = 1;
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printUsage();
    return;
  }
  if (options.selfTest) {
    await runSelfTest();
    return;
  }
  const manifestEvidence = await loadManifest(options.manifest);
  if (options.printManifestSha256) {
    const selected = selectedProtocol(manifestEvidence.document, options.pilot);
    process.stdout.write(
      JSON.stringify({
        manifestSha256: manifestEvidence.sha256,
        pilot: selected.pilot,
        plannedRuns: selected.sites.length * selected.rounds * 2,
      }) + '\n',
    );
    return;
  }
  const removeSignalHandlers = installSignalHandlers();
  try {
    await runLive(options, manifestEvidence);
  } finally {
    removeSignalHandlers();
  }
}

main().catch((error) => {
  process.stderr.write(
    JSON.stringify({
      passed: false,
      qualification: 'research-only',
      releaseEligible: false,
      failureCode: errorCode(error),
    }) + '\n',
  );
  process.exitCode = 1;
});
