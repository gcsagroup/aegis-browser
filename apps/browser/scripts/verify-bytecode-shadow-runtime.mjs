#!/usr/bin/env node

import {execFile, spawn} from 'node:child_process';
import {createHash, randomUUID} from 'node:crypto';
import {createReadStream, constants as fsConstants} from 'node:fs';
import {
  access,
  link,
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  rmdir,
  stat,
  unlink,
  writeFile,
} from 'node:fs/promises';
import {createServer as createHttpServer} from 'node:http';
import {homedir, tmpdir} from 'node:os';
import {basename, dirname, join, relative, resolve, sep} from 'node:path';
import process from 'node:process';
import {fileURLToPath} from 'node:url';

const BROWSER_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPO_ROOT = resolve(BROWSER_ROOT, '..', '..');
const BUILD_IDENTITY_SCRIPT = join(
  BROWSER_ROOT,
  'scripts',
  'write-build-identity.mjs',
);
const DEFAULT_TIMEOUT_MS = 30_000;
const POLL_INTERVAL_MS = 100;
const CRASH_OBSERVATION_MS = 3_000;
const LOG_LIMIT_BYTES = 16 * 1024 * 1024;
const TRACE_CATEGORY = 'disabled-by-default-v8.aegis.bytecode_shadow';
const TRACE_EVENT_NAME = 'V8.AegisBytecodeShadow';
const TRACE_BUFFER_SIZE_KIB = 32 * 1024;
const TRACE_RECORD_LIMIT = 8_192;
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
const NORMAL_DONE_BODY = 'ready';
const STRESS_PRESSURE_FUNCTIONS = 1_400;
const STRESS_POST_PRESSURE_FUNCTIONS = 256;
const STDERR_CALIBRATION_RECORDS = 1_000;
const STDERR_CALIBRATION_LINE_BYTES = 126;
const STDERR_CALIBRATION_OBSERVATION_MS = 500;
const STDERR_HOLDER_SCRIPT = `
printf 'ready\\n' >&4 || exit 69
exec 4>&-
IFS= read -r release <&3 || exit 70
[ "$release" = "release" ] || exit 71
exec /bin/cat
`;
const CRASH_EXTENSION_PATTERN = /\.(?:crash|dmp|ips)$/iu;
let approvedReportPath = null;

class VerificationError extends Error {}

function fail(message) {
  throw new VerificationError(message);
}

function assert(condition, message) {
  if (!condition) {
    fail(message);
  }
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function canonical(value) {
  return JSON.stringify(value);
}

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

function printUsage() {
  process.stdout.write(`用法：
  node apps/browser/scripts/verify-bytecode-shadow-runtime.mjs [选项]

选项：
  --app PATH          被测 Chromium.app
  --binary PATH       被测 Chromium 可执行文件；与 --app 二选一
  --report PATH       JSON 报告路径；拒绝覆盖已有文件
  --timeout-ms N      每个 OFF/ON/CANARY/STRESS fixture 的单一超时预算，默认 ${DEFAULT_TIMEOUT_MS}
  --build-identity PATH
                      可选的 schema v3 构建身份清单
  --build-identity-sha256 SHA256
                      调用方固定摘要；必须与 --build-identity 成对提供
  --self-test         测试严格 trace、fixture 协议、清理退出和 canary 规则
  --help              显示帮助

真实模式只加载 127.0.0.1 上的良性 JavaScript fixture，并在导航前通过
loopback CDP 启动 32 MiB record-until-full 专用 trace。OFF 必须为 0 条；ON
必须产生 observed 记录；CANARY 以 max-bytes=1 证明 renderer 收到合并后的
V8 flags；STRESS 通过独立 pipe-holder 在不读取 stderr 的条件下编译 1,656
个唯一函数，并要求页面在释放 holder 前完成。验证器还会先用固定 126,000
字节合成同步 stderr 写入校准同一管道确实形成反压。报告只保存归一化计数和
opcode 签名，
不保存 trace metadata、页面源码、URL、函数名或原始 Chromium 日志。进程清理
使用独立有界门，不计入 fixture 预算。该验证器固定为 research-only；行为
通过也不产生 Release 资格。
`);
}

function parseArgs(argv) {
  const options = {
    app: null,
    binary: null,
    buildIdentity: null,
    buildIdentitySha256: null,
    help: false,
    report: null,
    selfTest: false,
    timeoutMs: DEFAULT_TIMEOUT_MS,
  };
  const valueAfter = (index, option) => {
    const value = argv[index + 1];
    assert(value && !value.startsWith('--'), `${option} 缺少值`);
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
    } else if (argument === '--report') {
      options.report = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--timeout-ms') {
      options.timeoutMs = Number(valueAfter(index, argument));
      index += 1;
      assert(
        Number.isSafeInteger(options.timeoutMs) && options.timeoutMs >= 5_000,
        '--timeout-ms 必须是至少 5000 的整数',
      );
    } else if (argument === '--build-identity') {
      options.buildIdentity = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--build-identity-sha256') {
      options.buildIdentitySha256 = valueAfter(index, argument);
      index += 1;
    } else if (argument === '--self-test') {
      options.selfTest = true;
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else if (argument === '--') {
      continue;
    } else {
      fail(`未知参数：${argument}`);
    }
  }

  assert(!(options.app && options.binary), '--app 与 --binary 只能提供一个');
  assert(
    Boolean(options.buildIdentity) === Boolean(options.buildIdentitySha256),
    '--build-identity 与 --build-identity-sha256 必须同时提供',
  );
  if (options.buildIdentitySha256) {
    assert(
      /^[0-9a-f]{64}$/u.test(options.buildIdentitySha256),
      '--build-identity-sha256 必须是 64 位小写十六进制',
    );
  }
  return options;
}

function appAncestor(path) {
  let cursor = resolve(path);
  while (true) {
    if (basename(cursor).endsWith('.app')) {
      return cursor;
    }
    const parent = dirname(cursor);
    if (parent === cursor) {
      return null;
    }
    cursor = parent;
  }
}

async function resolveTarget(options) {
  assert(Boolean(options.app) !== Boolean(options.binary), '真实模式必须指定 --app 或 --binary');
  let appPath = options.app;
  let executable = options.binary;
  if (appPath) {
    const appMetadata = await stat(appPath).catch(() => null);
    assert(appMetadata?.isDirectory(), `Chromium.app 不存在：${appPath}`);
    appPath = await realpath(appPath);
    executable = join(appPath, 'Contents', 'MacOS', 'Chromium');
  }
  const executableMetadata = await stat(executable).catch(() => null);
  assert(executableMetadata?.isFile(), `Chromium 可执行文件不存在：${executable}`);
  await access(executable, fsConstants.X_OK).catch(() => {
    fail(`Chromium 不可执行：${executable}`);
  });
  executable = await realpath(executable);
  appPath = appPath ?? appAncestor(executable);
  if (appPath) {
    appPath = await realpath(appPath);
  }
  return {
    appPath,
    executable,
    inputKind: options.app ? 'app' : 'binary',
  };
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

function sha256Text(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

async function fileEvidence(path) {
  const resolvedPath = await realpath(path);
  const before = await stat(resolvedPath);
  assert(before.isFile(), `证据文件不存在：${resolvedPath}`);
  const sha256 = await sha256File(resolvedPath);
  const after = await stat(resolvedPath);
  assert(
    before.ino === after.ino &&
      before.size === after.size &&
      before.mtimeMs === after.mtimeMs,
    `证据文件在计算 SHA-256 期间发生变化：${resolvedPath}`,
  );
  return {path: resolvedPath, size: after.size, sha256};
}

function execFileOutcome(file, args, options = {}) {
  return new Promise((resolveCommand) => {
    execFile(
      file,
      args,
      {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...options},
      (error, stdout, stderr) => {
        resolveCommand({
          passed: !error,
          exitCode: error?.code ?? 0,
          stdout,
          stderr,
        });
      },
    );
  });
}

async function execFileText(file, args, options = {}) {
  const outcome = await execFileOutcome(file, args, options);
  if (!outcome.passed) {
    fail(`${basename(file)} 执行失败：${outcome.stderr.trim() || outcome.exitCode}`);
  }
  return outcome.stdout;
}

function pathIsWithin(root, candidate) {
  const suffix = relative(root, candidate);
  return suffix === '' || (!suffix.startsWith(`..${sep}`) && suffix !== '..');
}

async function canonicalPotentialPath(path) {
  const missing = [];
  let cursor = resolve(path);
  while (true) {
    try {
      const canonicalParent = await realpath(cursor);
      return resolve(canonicalParent, ...missing.reverse());
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        throw error;
      }
      const parent = dirname(cursor);
      assert(parent !== cursor, `无法解析报告路径：${path}`);
      missing.push(basename(cursor));
      cursor = parent;
    }
  }
}

async function gitRootFor(path) {
  const outcome = await execFileOutcome('/usr/bin/git', [
    '-C',
    path,
    'rev-parse',
    '--show-toplevel',
  ]);
  return outcome.passed ? realpath(outcome.stdout.trim()) : null;
}

async function validateReportPath(options, target) {
  if (!options.report) {
    return null;
  }
  const existing = await lstat(options.report).catch((error) => {
    if (error?.code === 'ENOENT') return null;
    throw error;
  });
  assert(existing === null, '--report 已存在；拒绝覆盖既有证据');
  const reportPath = await canonicalPotentialPath(options.report);
  assert(reportPath !== target.executable, '--report 不得覆盖被测可执行文件');
  if (target.appPath) {
    assert(!pathIsWithin(target.appPath, reportPath), '--report 不得位于被测 App 内');
  }
  if (options.buildIdentity) {
    const manifestPath = await canonicalPotentialPath(options.buildIdentity);
    assert(reportPath !== manifestPath, '--report 不得覆盖构建身份清单');
    assert(reportPath !== `${manifestPath}.sha256`, '--report 不得覆盖构建身份 sidecar');
  }

  const roots = new Set();
  for (const candidate of [REPO_ROOT, dirname(target.executable)]) {
    const root = await gitRootFor(candidate);
    if (root) roots.add(root);
  }
  for (const root of roots) {
    const gitDir = (
      await execFileText('/usr/bin/git', [
        '-C',
        root,
        'rev-parse',
        '--absolute-git-dir',
      ])
    ).trim();
    assert(!pathIsWithin(await realpath(gitDir), reportPath), '--report 不得位于 Git 元数据中');
    if (pathIsWithin(root, reportPath)) {
      const tracked = await execFileOutcome('/usr/bin/git', [
        '-C',
        root,
        'ls-files',
        '--error-unmatch',
        '--',
        relative(root, reportPath),
      ]);
      assert(!tracked.passed, '--report 不得覆盖已跟踪源码');
    }
  }
  return reportPath;
}

async function writeJsonExclusive(path, value) {
  if (!path) {
    return;
  }
  await mkdir(dirname(path), {recursive: true});
  const temporary = join(
    dirname(path),
    `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`,
  );
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
    mode: 0o644,
  });
  try {
    await link(temporary, path);
  } catch (error) {
    if (error?.code === 'EEXIST') {
      fail(`拒绝覆盖既有证据：${path}`);
    }
    throw error;
  } finally {
    await unlink(temporary).catch(() => {});
  }
}

function printReport(report, reportPath, stream = process.stdout) {
  if (!reportPath) {
    stream.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }
  stream.write(
    `${JSON.stringify({
      kind: report.kind,
      passed: report.passed,
      qualification: report.qualification,
      runtime_pass: report.runtime_pass,
      release_eligible: report.release_eligible,
      assertionSummary: report.assertionSummary ?? null,
      report: reportPath,
      ...(report.error ? {error: report.error} : {}),
    })}\n`,
  );
}

function parseTraceRecords(traceEvents) {
  assert(Array.isArray(traceEvents), 'trace 事件集合不是数组');
  const records = [];
  for (const [eventIndex, event] of traceEvents.entries()) {
    assert(event && typeof event === 'object', `第 ${eventIndex + 1} 个 trace 事件无效`);
    const categories =
      typeof event.cat === 'string' ? event.cat.split(',') : [];
    const categoryMatches = categories.includes(TRACE_CATEGORY);
    const nameMatches = event.name === TRACE_EVENT_NAME;
    if (!categoryMatches && !nameMatches) {
      continue;
    }
    assert(
      categoryMatches && nameMatches,
      `第 ${eventIndex + 1} 个 Aegis trace 的分类或名称不匹配`,
    );
    assert(event.ph === 'I', `第 ${eventIndex + 1} 个 Aegis trace 不是 instant event`);
    assert(
      event.args && typeof event.args === 'object' && !Array.isArray(event.args),
      `第 ${eventIndex + 1} 个 Aegis trace 缺少参数`,
    );
    const argumentNames = Object.keys(event.args).sort();
    assert(
      canonical(argumentNames) === canonical(TRACE_ARGUMENT_NAMES),
      `第 ${eventIndex + 1} 个 Aegis trace 参数集合不符合 schema=2`,
    );
    for (const name of TRACE_ARGUMENT_NAMES) {
      assert(
        Number.isSafeInteger(event.args[name]) && event.args[name] >= 0,
        `第 ${eventIndex + 1} 个 Aegis trace 的 ${name} 不是非负安全整数`,
      );
    }
    assert(
      event.args.bytes <= 0xffff_ffff &&
        event.args.opcodes <= 0xffff_ffff,
      `第 ${eventIndex + 1} 个 Aegis trace 的长度字段超出 uint32`,
    );
    assert(
      event.args.record_schema === 2 &&
        event.args.signature_schema === 1 &&
        event.args.mode_code === 0 &&
        event.args.would_block === 0,
      `第 ${eventIndex + 1} 个 Aegis trace 的固定协议字段无效`,
    );
    assert(
      event.args.status_code === 0 || event.args.status_code === 1,
      `第 ${eventIndex + 1} 个 Aegis trace 的状态码无效`,
    );
    assert(
      event.args.signature_hi <= 0xffff_ffff &&
        event.args.signature_lo <= 0xffff_ffff,
      `第 ${eventIndex + 1} 个 Aegis trace 的签名分片超出 uint32`,
    );
    assert(
      Number.isSafeInteger(event.pid) && event.pid > 0,
      `第 ${eventIndex + 1} 个 Aegis trace 缺少有效进程标识`,
    );
    const signature =
      event.args.signature_hi.toString(16).padStart(8, '0') +
      event.args.signature_lo.toString(16).padStart(8, '0');
    const record = {
      pid: event.pid,
      schema: 2,
      signatureSchema: 1,
      mode: 'observe-only',
      status: event.args.status_code === 1 ? 'skipped-too-large' : 'observed',
      bytes: event.args.bytes,
      opcodes: event.args.opcodes,
      signature,
      wouldBlock: 0,
    };
    if (record.status === 'skipped-too-large') {
      assert(
        record.bytes > 0 &&
          record.opcodes === 0 &&
          record.signature === '0000000000000000',
        `第 ${eventIndex + 1} 个 skipped-too-large 记录包含不允许的摘要值`,
      );
    } else {
      assert(
        record.bytes > 0 &&
          record.opcodes > 0 &&
          record.signature !== '0000000000000000',
        `第 ${eventIndex + 1} 个 observed 记录缺少有效摘要`,
      );
    }
    records.push(record);
    assert(records.length <= TRACE_RECORD_LIMIT, 'Aegis trace 记录超过验证器硬上限');
  }
  return records;
}

function numericRange(values) {
  if (values.length === 0) {
    return {min: null, max: null};
  }
  return {min: Math.min(...values), max: Math.max(...values)};
}

function summarizeRecords(records) {
  const signatureCounts = new Map();
  const processCounts = new Map();
  for (const record of records) {
    signatureCounts.set(
      record.signature,
      (signatureCounts.get(record.signature) ?? 0) + 1,
    );
    processCounts.set(record.pid, (processCounts.get(record.pid) ?? 0) + 1);
  }
  const signatureEntries = [...signatureCounts.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([signature, count]) => ({signature, count}));
  const normalizedRecords = records.map(({pid: _pid, ...record}) => record);
  const perProcessRecordCounts = [...processCounts.values()].sort(
    (left, right) => left - right,
  );
  return {
    recordCount: records.length,
    schema: records.length === 0 ? null : 2,
    signatureSchema: records.length === 0 ? null : 1,
    mode: records.length === 0 ? null : 'observe-only',
    wouldBlock: records.length === 0 ? null : 0,
    statusCounts: {
      observed: records.filter((record) => record.status === 'observed').length,
      skippedTooLarge: records.filter(
        (record) => record.status === 'skipped-too-large',
      ).length,
    },
    byteRange: numericRange(records.map((record) => record.bytes)),
    opcodeRange: numericRange(records.map((record) => record.opcodes)),
    processCount: processCounts.size,
    perProcessRecordCounts,
    maxRecordsInSingleProcess:
      perProcessRecordCounts.length === 0
        ? 0
        : perProcessRecordCounts.at(-1),
    distinctSignatureCount: signatureEntries.length,
    signatureSetSha256: sha256Text(canonical(signatureEntries)),
    normalizedRecordSha256: sha256Text(canonical(normalizedRecords)),
    signatures: signatureEntries.length <= 32 ? signatureEntries : [],
    signaturesTruncated: signatureEntries.length > 32,
  };
}

function summarizeEmitterProcessRoles(records, processInfo) {
  assert(Array.isArray(processInfo), 'SystemInfo.getProcessInfo 缺少进程列表');
  const typeByPid = new Map();
  for (const [index, entry] of processInfo.entries()) {
    assert(
      entry &&
        Number.isSafeInteger(entry.id) &&
        entry.id > 0 &&
        typeof entry.type === 'string' &&
        entry.type.length > 0,
      `第 ${index + 1} 个 Chromium 进程信息无效`,
    );
    assert(!typeByPid.has(entry.id), `Chromium 进程信息包含重复 id：${entry.id}`);
    typeByPid.set(entry.id, entry.type);
  }

  const countsByPid = new Map();
  for (const record of records) {
    countsByPid.set(record.pid, (countsByPid.get(record.pid) ?? 0) + 1);
  }
  const recordCountsByType = new Map();
  const rendererRecordCounts = [];
  let unknownEmitterProcessCount = 0;
  for (const [pid, count] of countsByPid) {
    const type = typeByPid.get(pid);
    if (!type) {
      unknownEmitterProcessCount += 1;
      continue;
    }
    recordCountsByType.set(type, (recordCountsByType.get(type) ?? 0) + count);
    if (type === 'renderer') {
      rendererRecordCounts.push(count);
    }
  }
  rendererRecordCounts.sort((left, right) => left - right);
  const typeEntries = [...recordCountsByType.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([type, recordCount]) => ({type, recordCount}));
  return {
    emitterProcessCount: countsByPid.size,
    emitterProcessTypes: typeEntries.map((entry) => entry.type),
    recordCountsByType: typeEntries,
    unknownEmitterProcessCount,
    rendererProcessCount: rendererRecordCounts.length,
    perRendererRecordCounts: rendererRecordCounts,
    maxRecordsInSingleRenderer:
      rendererRecordCounts.length === 0 ? 0 : rendererRecordCounts.at(-1),
  };
}

function mergeProcessInfoSnapshots(snapshots) {
  assert(
    Array.isArray(snapshots) && snapshots.length >= 2,
    'Chromium 进程角色快照不足',
  );
  const merged = new Map();
  for (const snapshot of snapshots) {
    assert(Array.isArray(snapshot), 'Chromium 进程角色快照无效');
    for (const entry of snapshot) {
      assert(
        entry &&
          Number.isSafeInteger(entry.id) &&
          entry.id > 0 &&
          typeof entry.type === 'string' &&
          entry.type.length > 0,
        'Chromium 进程角色快照包含无效条目',
      );
      const existingType = merged.get(entry.id);
      assert(
        existingType === undefined || existingType === entry.type,
        `Chromium 进程 ${entry.id} 的角色在快照间冲突`,
      );
      merged.set(entry.id, entry.type);
    }
  }
  return [...merged.entries()].map(([id, type]) => ({id, type}));
}

function stressPhaseChecksum(count, offset) {
  let checksum = 2_166_136_261 >>> 0;
  for (let index = 0; index < count; index += 1) {
    const salt = offset + index + 1;
    const value =
      (Math.imul((index ^ salt) >>> 0, 2_654_435_761) + salt) >>> 0;
    checksum = Math.imul((checksum ^ value) >>> 0, 16_777_619) >>> 0;
  }
  return checksum;
}

function stressPhaseSource(prefix, count, offset, checksumName) {
  const definitions = [];
  const calls = [];
  for (let index = 0; index < count; index += 1) {
    const salt = offset + index + 1;
    const functionName = `${prefix}${index}`;
    definitions.push(
      `function ${functionName}(value) { return (Math.imul((value ^ ${salt}) >>> 0, 2654435761) + ${salt}) >>> 0; }`,
    );
    calls.push(
      `${checksumName} = Math.imul((${checksumName} ^ ${functionName}(${index})) >>> 0, 16777619) >>> 0;`,
    );
  }
  return `${definitions.join('\n')}\nlet ${checksumName} = 2166136261 >>> 0;\n${calls.join('\n')}`;
}

function stressProtocol() {
  return {
    pressure: {
      phase: 'pressure',
      count: STRESS_PRESSURE_FUNCTIONS,
      checksum: stressPhaseChecksum(STRESS_PRESSURE_FUNCTIONS, 0),
    },
    done: {
      phase: 'done',
      count: STRESS_POST_PRESSURE_FUNCTIONS,
      checksum: stressPhaseChecksum(
        STRESS_POST_PRESSURE_FUNCTIONS,
        STRESS_PRESSURE_FUNCTIONS,
      ),
    },
  };
}

function fixtureHtml(token, mode = 'normal') {
  const tokenLiteral = JSON.stringify(token);
  if (mode === 'stress') {
    const protocol = stressProtocol();
    const pressurePhase = stressPhaseSource(
      'aegisPressureFunction',
      STRESS_PRESSURE_FUNCTIONS,
      0,
      'pressureChecksum',
    );
    const postPressurePhase = stressPhaseSource(
      'aegisPostPressureFunction',
      STRESS_POST_PRESSURE_FUNCTIONS,
      STRESS_PRESSURE_FUNCTIONS,
      'doneChecksum',
    );
    return `<!doctype html>
<meta charset="utf-8">
<title>Bytecode shadow benign liveness fixture</title>
<body>pending</body>
<script>
(() => {
  'use strict';
  async function post(path, payload) {
    const response = await fetch(path, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(payload),
    });
    if (!response.ok) throw new Error('fixture protocol rejected');
  }
  async function complete() {
    ${pressurePhase}
    const pressurePayload = ${JSON.stringify(protocol.pressure)};
    if (pressureChecksum !== pressurePayload.checksum) throw new Error('pressure checksum mismatch');
    await post('/pressure/' + ${tokenLiteral}, pressurePayload);
    ${postPressurePhase}
    const donePayload = ${JSON.stringify(protocol.done)};
    if (doneChecksum !== donePayload.checksum) throw new Error('done checksum mismatch');
    document.body.textContent = 'ready';
    await post('/done/' + ${tokenLiteral}, donePayload);
  }
  complete().catch(() => { document.body.textContent = 'failed'; });
})();
</script>`;
  }
  return `<!doctype html>
<meta charset="utf-8">
<title>Bytecode shadow benign fixture</title>
<body>pending</body>
<script>
(() => {
  'use strict';
  class Accumulator {
    constructor(seed) { this.value = seed; }
    add(value) { this.value = (this.value + value) >>> 0; return this.value; }
  }
  function checksum(values) {
    return values.reduce((sum, value, index) => (sum + value * (index + 1)) >>> 0, 0);
  }
  function transform(value) {
    const accumulator = new Accumulator(value);
    for (let index = 0; index < 64; index += 1) accumulator.add(index * 3);
    return accumulator.value;
  }
  async function complete() {
    const values = Array.from({length: 128}, (_, index) => transform(index));
    const result = checksum(values);
    document.body.textContent = result > 0 ? 'ready' : 'unexpected';
    const response = await fetch('/done/' + ${tokenLiteral}, {
      method: 'POST',
      body: ${JSON.stringify(NORMAL_DONE_BODY)},
    });
    if (!response.ok) throw new Error('fixture protocol rejected');
  }
  complete().catch(() => { document.body.textContent = 'failed'; });
})();
</script>`;
}

async function readBoundedRequestBody(request, maximumBytes = 512) {
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    assert(total <= maximumBytes, 'fixture 协议请求体超过上限');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, total).toString('utf8');
}

async function startFixtureServer() {
  const registeredModes = new Map();
  const completedTokens = new Set();
  const completedAt = new Map();
  const pendingFixtureResponses = new Map();
  const pendingPressureResponses = new Map();
  const pressureReachedAt = new Map();
  const pressureReleasedAt = new Map();
  const protocolErrors = new Map();
  const releasedFixtureEvidence = new Map();
  const rejectProtocol = (token, response, message, status = 400) => {
    protocolErrors.set(token, message);
    response.writeHead(status, {'Cache-Control': 'no-store'});
    response.end('rejected');
  };
  const server = createHttpServer(async (request, response) => {
    const requestPath = request.url ?? '/';
    const fixtureMatch = requestPath.match(/^\/fixture\/([0-9a-f-]+)$/u);
    const pressureMatch = requestPath.match(/^\/pressure\/([0-9a-f-]+)$/u);
    const doneMatch = requestPath.match(/^\/done\/([0-9a-f-]+)$/u);
    if (
      request.method === 'GET' &&
      fixtureMatch &&
      registeredModes.has(fixtureMatch[1])
    ) {
      const token = fixtureMatch[1];
      if (pendingFixtureResponses.has(token)) {
        response.writeHead(409, {'Cache-Control': 'no-store'});
        response.end('duplicate');
        return;
      }
      pendingFixtureResponses.set(token, response);
      response.once('close', () => {
        if (pendingFixtureResponses.get(token) === response) {
          pendingFixtureResponses.delete(token);
        }
      });
      return;
    }
    if (
      request.method === 'POST' &&
      pressureMatch &&
      registeredModes.get(pressureMatch[1]) === 'stress'
    ) {
      const token = pressureMatch[1];
      if (
        pendingPressureResponses.has(token) ||
        pressureReachedAt.has(token) ||
        completedTokens.has(token) ||
        !releasedFixtureEvidence.has(token)
      ) {
        request.resume();
        rejectProtocol(token, response, '重复或乱序 pressure 请求', 409);
        return;
      }
      try {
        const body = await readBoundedRequestBody(request);
        const expected = JSON.stringify(stressProtocol().pressure);
        if (body !== expected) {
          rejectProtocol(token, response, 'pressure 请求体不匹配');
          return;
        }
      } catch (error) {
        rejectProtocol(token, response, errorMessage(error));
        return;
      }
      pressureReachedAt.set(token, performance.now());
      pendingPressureResponses.set(token, response);
      response.once('close', () => {
        if (pendingPressureResponses.get(token) === response) {
          pendingPressureResponses.delete(token);
          protocolErrors.set(token, 'pressure 响应在释放前关闭');
        }
      });
      return;
    }
    if (
      request.method === 'POST' &&
      doneMatch &&
      registeredModes.has(doneMatch[1])
    ) {
      const token = doneMatch[1];
      const mode = registeredModes.get(token);
      if (
        completedTokens.has(token) ||
        !releasedFixtureEvidence.has(token) ||
        (mode === 'stress' && !pressureReleasedAt.has(token))
      ) {
        request.resume();
        rejectProtocol(token, response, '重复或乱序 done 请求', 409);
        return;
      }
      try {
        const body = await readBoundedRequestBody(request);
        const expected =
          mode === 'stress'
            ? JSON.stringify(stressProtocol().done)
            : NORMAL_DONE_BODY;
        if (body !== expected) {
          rejectProtocol(token, response, 'done 请求体不匹配');
          return;
        }
      } catch (error) {
        rejectProtocol(token, response, errorMessage(error));
        return;
      }
      completedTokens.add(token);
      completedAt.set(token, performance.now());
      response.writeHead(204, {'Cache-Control': 'no-store'});
      response.end();
      return;
    }
    request.resume();
    response.writeHead(404, {'Cache-Control': 'no-store'});
    response.end('not found');
  });
  await new Promise((resolveListening, rejectListening) => {
    server.once('error', rejectListening);
    server.listen(0, '127.0.0.1', resolveListening);
  });
  const address = server.address();
  assert(address && typeof address === 'object', '无法取得 loopback fixture 端口');
  return {
    port: address.port,
    register(token, mode = 'normal') {
      assert(!registeredModes.has(token), 'fixture token 重复注册');
      assert(mode === 'normal' || mode === 'stress', 'fixture 模式无效');
      registeredModes.set(token, mode);
    },
    completed(token) {
      return completedTokens.has(token);
    },
    pressure(token) {
      return pressureReachedAt.has(token);
    },
    error(token) {
      return protocolErrors.get(token) ?? null;
    },
    pending(token) {
      return pendingFixtureResponses.has(token);
    },
    release(token) {
      const response = pendingFixtureResponses.get(token);
      assert(response, 'fixture 控制响应尚未就绪');
      pendingFixtureResponses.delete(token);
      const mode = registeredModes.get(token);
      assert(mode, 'fixture token 未注册');
      const body = fixtureHtml(token, mode);
      releasedFixtureEvidence.set(token, {
        size: Buffer.byteLength(body, 'utf8'),
        sha256: sha256Text(body),
        kind: mode,
        ...(mode === 'stress'
          ? {
              pressureFunctionCount: STRESS_PRESSURE_FUNCTIONS,
              postPressureFunctionCount: STRESS_POST_PRESSURE_FUNCTIONS,
              protocolSha256: sha256Text(canonical(stressProtocol())),
            }
          : {}),
      });
      response.writeHead(200, {
        'Cache-Control': 'no-store',
        'Content-Security-Policy': "default-src 'self'; script-src 'unsafe-inline'; connect-src 'self'",
        'Content-Type': 'text/html; charset=utf-8',
      });
      response.end(body);
    },
    releasePressure(token) {
      const response = pendingPressureResponses.get(token);
      assert(response, 'pressure 控制响应尚未就绪');
      pendingPressureResponses.delete(token);
      pressureReleasedAt.set(token, performance.now());
      response.writeHead(204, {'Cache-Control': 'no-store'});
      response.end();
    },
    timing(token) {
      return {
        pressureReachedAt: pressureReachedAt.get(token) ?? null,
        pressureReleasedAt: pressureReleasedAt.get(token) ?? null,
        completedAt: completedAt.get(token) ?? null,
      };
    },
    evidence(token) {
      return releasedFixtureEvidence.get(token) ?? null;
    },
    async close() {
      for (const response of pendingFixtureResponses.values()) {
        response.writeHead(503, {'Cache-Control': 'no-store'});
        response.end('closing');
      }
      pendingFixtureResponses.clear();
      for (const response of pendingPressureResponses.values()) {
        response.writeHead(503, {'Cache-Control': 'no-store'});
        response.end('closing');
      }
      pendingPressureResponses.clear();
      await new Promise((resolveClose) => {
        server.close(resolveClose);
        server.closeAllConnections?.();
      });
    },
  };
}

async function waitForFixtureState(
  fixture,
  token,
  child,
  spawnState,
  deadline,
  state,
  timeoutMessage,
) {
  while (performance.now() < deadline) {
    const protocolError = fixture.error(token);
    if (protocolError) {
      fail(`fixture 协议失败：${protocolError}`);
    }
    if (spawnState.error) {
      fail(`Chromium 启动失败：${errorMessage(spawnState.error)}`);
    }
    if (fixture[state](token)) {
      return;
    }
    if (child.exitCode !== null || child.signalCode !== null) {
      fail(`Chromium 在 fixture 完成前退出：${child.exitCode ?? child.signalCode}`);
    }
    await delay(POLL_INTERVAL_MS);
  }
  fail(timeoutMessage);
}

async function delayWithinDeadline(milliseconds, deadline, timeoutMessage) {
  assert(
    performance.now() + milliseconds <= deadline,
    timeoutMessage,
  );
  await delay(milliseconds);
}

function remainingWithinDeadline(deadline, timeoutMessage) {
  const remaining = Math.floor(deadline - performance.now());
  assert(remaining > 0, timeoutMessage);
  return remaining;
}

function combinePrimaryAndCleanupError(primaryError, cleanupErrors) {
  if (!primaryError && cleanupErrors.length === 0) return null;
  if (!primaryError) {
    return new VerificationError(
      `清理失败：${cleanupErrors.map(errorMessage).join('；')}`,
    );
  }
  if (cleanupErrors.length === 0) return primaryError;
  return new VerificationError(
    `${errorMessage(primaryError)}；清理失败：${cleanupErrors
      .map(errorMessage)
      .join('；')}`,
  );
}

async function withinTimeout(promise, timeoutMs, timeoutMessage) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, rejectTimeout) => {
        timer = setTimeout(
          () => rejectTimeout(new VerificationError(timeoutMessage)),
          timeoutMs,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function captureCleanupError(cleanupErrors, callback) {
  try {
    await callback();
  } catch (error) {
    cleanupErrors.push(error);
  }
}

function startStderrPipeHolder(onData = () => {}) {
  const child = spawn('/bin/sh', ['-c', STDERR_HOLDER_SCRIPT], {
    env: {...process.env},
    stdio: ['pipe', 'pipe', 'ignore', 'pipe', 'pipe'],
  });
  const state = {
    child,
    closePromise: null,
    error: null,
    forwardedBytes: 0,
    ready: false,
    readyError: null,
    readyOutput: '',
    releaseRequested: false,
    releaseRequestedAt: null,
    released: false,
    releasedAt: null,
    streamErrors: [],
  };
  child.once('error', (error) => {
    state.error = error;
  });
  state.closePromise = new Promise((resolveClose) => {
    child.once('close', (exitCode, signalCode) =>
      resolveClose({exitCode, signalCode}),
    );
  });
  assert(
    child.stdin && child.stdout && child.stdio[3] && child.stdio[4],
    '无法建立 stderr pipe-holder',
  );
  child.stdin.on('error', (error) => state.streamErrors.push(error));
  child.stdout.on('error', (error) => state.streamErrors.push(error));
  child.stdio[3].on('error', (error) => state.streamErrors.push(error));
  child.stdio[4].on('error', (error) => state.streamErrors.push(error));
  child.stdio[4].on('data', (chunk) => {
    state.readyOutput += chunk.toString('utf8');
    if (state.readyOutput.length > 'ready\n'.length) {
      state.readyError = new VerificationError('stderr pipe-holder ready 响应超长');
    }
  });
  child.stdout.on('data', (chunk) => {
    state.forwardedBytes += chunk.length;
    onData(chunk);
  });
  return state;
}

async function waitForStderrPipeHolderReady(holder) {
  const deadline = performance.now() + 1_000;
  while (performance.now() < deadline) {
    if (holder.error) {
      fail(`stderr pipe-holder 启动失败：${errorMessage(holder.error)}`);
    }
    if (holder.readyError) throw holder.readyError;
    if (holder.readyOutput === 'ready\n') {
      holder.ready = true;
      return;
    }
    if (
      holder.child.exitCode !== null ||
      holder.child.signalCode !== null
    ) {
      fail('stderr pipe-holder 在 ready 前退出');
    }
    await delay(10);
  }
  fail('等待 stderr pipe-holder ready 超时');
}

async function releaseStderrPipeHolder(holder) {
  if (holder.released) return;
  assert(!holder.releaseRequested, 'stderr pipe-holder 上一次释放未完成');
  assert(!holder.error, `stderr pipe-holder 启动失败：${errorMessage(holder.error)}`);
  assert(
    holder.child.exitCode === null && holder.child.signalCode === null,
    'stderr pipe-holder 在释放前退出',
  );
  holder.releaseRequested = true;
  holder.releaseRequestedAt = performance.now();
  const release = new Promise((resolveRelease, rejectRelease) => {
    const control = holder.child.stdio[3];
    const handleError = (error) => rejectRelease(error);
    control.once('error', handleError);
    control.end('release\n', () => {
      control.off('error', handleError);
      resolveRelease();
    });
  });
  await withinTimeout(release, 1_000, '释放 stderr pipe-holder 超时');
  holder.released = true;
  holder.releasedAt = performance.now();
}

async function finishStderrPipeHolder(holder) {
  if (!holder.child.stdin.destroyed && !holder.child.stdin.writableEnded) {
    holder.child.stdin.end();
  }
  let forced = false;
  let closeResult = await waitForClose(holder.closePromise, 2_000);
  if (!closeResult) {
    holder.child.kill('SIGTERM');
    closeResult = await waitForClose(holder.closePromise, 1_000);
  }
  if (!closeResult) {
    forced = true;
    holder.child.kill('SIGKILL');
    closeResult = await waitForClose(holder.closePromise, 1_000);
  }
  assert(closeResult, 'stderr pipe-holder 未能结束');
  assert(!holder.error, `stderr pipe-holder 启动失败：${errorMessage(holder.error)}`);
  assert(
    holder.streamErrors.length === 0,
    `stderr pipe-holder 流错误：${holder.streamErrors.map(errorMessage).join('；')}`,
  );
  return {
    ready: holder.ready,
    released: holder.released,
    releaseRequestedAt: holder.releaseRequestedAt,
    releaseCompletedAt: holder.releasedAt,
    forwardedBytes: holder.forwardedBytes,
    forced,
    closeObserved: true,
    exitCode: closeResult.exitCode ?? null,
    signalCode: closeResult.signalCode ?? null,
  };
}

async function waitForChildMarker(
  child,
  spawnState,
  output,
  marker,
  timeoutMs,
  timeoutMessage,
) {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    if (spawnState.error) {
      fail(`校准进程启动失败：${errorMessage(spawnState.error)}`);
    }
    if (output().includes(marker)) return;
    if (child.exitCode !== null || child.signalCode !== null) {
      fail(`校准进程在输出 ${marker.trim()} 前退出`);
    }
    await delay(10);
  }
  fail(timeoutMessage);
}

async function calibrateStderrBackpressure() {
  let forwardedBytesBeforeRelease = null;
  let writerOutput = '';
  let writerCloseResult = null;
  let holderTermination = null;
  let primaryError = null;
  const cleanupErrors = [];
  const holder = startStderrPipeHolder();
  try {
    await waitForStderrPipeHolderReady(holder);
  } catch (error) {
    await captureCleanupError(cleanupErrors, () =>
      releaseStderrPipeHolder(holder),
    );
    await captureCleanupError(cleanupErrors, () =>
      finishStderrPipeHolder(holder),
    );
    throw combinePrimaryAndCleanupError(error, cleanupErrors);
  }
  const writerSource = `
const fs = require('node:fs');
const count = Number(process.argv[1]);
const width = Number(process.argv[2]);
const line = Buffer.alloc(width, 0x58);
line[width - 1] = 0x0a;
process.stdout.write('started\\n');
for (let index = 0; index < count; index += 1) fs.writeSync(2, line);
process.stdout.write('done\\n');
`;
  let writer;
  try {
    writer = spawn(
      process.execPath,
      [
        '-e',
        writerSource,
        String(STDERR_CALIBRATION_RECORDS),
        String(STDERR_CALIBRATION_LINE_BYTES),
      ],
      {env: {...process.env}, stdio: ['ignore', 'pipe', holder.child.stdin]},
    );
  } catch (error) {
    await captureCleanupError(cleanupErrors, () =>
      releaseStderrPipeHolder(holder),
    );
    await captureCleanupError(cleanupErrors, () =>
      finishStderrPipeHolder(holder),
    );
    throw combinePrimaryAndCleanupError(error, cleanupErrors);
  }
  const writerState = {error: null};
  writer.once('error', (error) => {
    writerState.error = error;
  });
  writer.stdout.on('data', (chunk) => {
    writerOutput += chunk.toString('utf8');
  });
  const writerClosePromise = new Promise((resolveClose) => {
    writer.once('close', (exitCode, signalCode) =>
      resolveClose({exitCode, signalCode}),
    );
  });

  try {
    await waitForChildMarker(
      writer,
      writerState,
      () => writerOutput,
      'started\n',
      2_000,
      '等待 stderr 反压校准启动超时',
    );
    await delay(STDERR_CALIBRATION_OBSERVATION_MS);
    forwardedBytesBeforeRelease = holder.forwardedBytes;
    assert(
      writer.exitCode === null &&
        writer.signalCode === null &&
        writerOutput === 'started\n' &&
        forwardedBytesBeforeRelease === 0 &&
        holder.released === false,
      '独立 pipe-holder 未在固定合成同步写入量下形成反压',
    );
    await releaseStderrPipeHolder(holder);
    writerCloseResult = await waitForClose(writerClosePromise, 5_000);
    assert(writerCloseResult, '释放 pipe-holder 后校准进程未结束');
    assert(
      writerCloseResult.exitCode === 0 &&
        writerCloseResult.signalCode === null &&
        writerOutput === 'started\ndone\n',
      '释放 pipe-holder 后校准进程未正常完成',
    );
  } catch (error) {
    primaryError = error;
  } finally {
    if (!holder.released) {
      await captureCleanupError(cleanupErrors, () =>
        releaseStderrPipeHolder(holder),
      );
    }
    if (writer.exitCode === null && writer.signalCode === null) {
      writer.kill('SIGTERM');
      writerCloseResult ??= await waitForClose(writerClosePromise, 1_000);
    }
    if (
      !writerCloseResult &&
      writer.exitCode === null &&
      writer.signalCode === null
    ) {
      writer.kill('SIGKILL');
      writerCloseResult = await waitForClose(writerClosePromise, 1_000);
    }
    writerCloseResult ??= await waitForClose(writerClosePromise, 1_000);
    if (!writerCloseResult) {
      cleanupErrors.push(
        new VerificationError('stderr 反压校准进程未收到 close'),
      );
    }
    await captureCleanupError(cleanupErrors, async () => {
      holderTermination = await finishStderrPipeHolder(holder);
    });
  }

  const combinedError = combinePrimaryAndCleanupError(
    primaryError,
    cleanupErrors,
  );
  if (combinedError) throw combinedError;
  const expectedBytes =
    STDERR_CALIBRATION_RECORDS * STDERR_CALIBRATION_LINE_BYTES;
  assert(
    holderTermination?.ready === true &&
      holderTermination.exitCode === 0 &&
      holderTermination.signalCode === null &&
      holderTermination.forced === false &&
      holderTermination.forwardedBytes === expectedBytes,
    'stderr pipe-holder 校准未完整转发固定字节数',
  );
  return {
    protocol: 'independent-pipe-holder-calibration-v1',
    recordCount: STDERR_CALIBRATION_RECORDS,
    recordBytes: STDERR_CALIBRATION_LINE_BYTES,
    totalBytes: expectedBytes,
    observationMs: STDERR_CALIBRATION_OBSERVATION_MS,
    writerBlockedBeforeRelease: true,
    forwardedBytesBeforeRelease,
    writerCompletedAfterRelease: true,
    holder: holderTermination,
    rawLogStored: false,
  };
}

async function processTable() {
  const output = await execFileText(
    '/bin/ps',
    ['-axo', 'pid=,pgid=,command='],
    {timeout: 2_000, killSignal: 'SIGKILL'},
  );
  const rows = [];
  for (const line of output.split(/\r?\n/u)) {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/u);
    if (match) {
      rows.push({pid: Number(match[1]), pgid: Number(match[2]), command: match[3]});
    }
  }
  return rows;
}

async function ownedProcesses(rootPid, profileDir) {
  return (await processTable()).filter(
    (row) =>
      row.pid !== process.pid &&
      (row.pgid === rootPid || row.command.includes(profileDir)),
  );
}

function signalProcess(pid, signal) {
  try {
    process.kill(pid, signal);
    return true;
  } catch (error) {
    if (error?.code === 'ESRCH') return false;
    throw error;
  }
}

async function waitForNoOwnedProcesses(rootPid, profileDir, timeoutMs) {
  const deadline = performance.now() + timeoutMs;
  while (true) {
    const survivors = await ownedProcesses(rootPid, profileDir);
    if (survivors.length === 0 || performance.now() >= deadline) {
      return survivors;
    }
    await delay(POLL_INTERVAL_MS);
  }
}

function waitForClose(closePromise, timeoutMs) {
  return new Promise((resolveClose) => {
    const timeout = setTimeout(() => resolveClose(null), timeoutMs);
    closePromise.then((result) => {
      clearTimeout(timeout);
      resolveClose(result);
    });
  });
}

async function terminateOwnedBrowser(child, profileDir, closePromise) {
  const rootPid = child.pid;
  if (!Number.isSafeInteger(rootPid) || rootPid <= 0) {
    const closeResult = await waitForClose(closePromise, 2_000);
    assert(closeResult, '启动失败后未收到 close，无法确认没有残留进程');
    return {
      forced: false,
      controlledTerminationRequested: false,
      unexpectedExitBeforeCleanup: {
        exitCode: closeResult.exitCode ?? null,
        signalCode: closeResult.signalCode ?? null,
      },
      residualProcessCount: 0,
      closeObserved: true,
      exitCode: closeResult.exitCode ?? null,
      signalCode: closeResult.signalCode ?? null,
    };
  }
  let unexpectedExitBeforeCleanup =
    child.exitCode !== null || child.signalCode !== null
      ? {
          exitCode: child.exitCode ?? null,
          signalCode: child.signalCode ?? null,
        }
      : null;
  let forced = false;
  let controlledTerminationRequested = false;
  if (child.exitCode === null && child.signalCode === null) {
    controlledTerminationRequested = signalProcess(-rootPid, 'SIGTERM');
    if (!controlledTerminationRequested) {
      await Promise.race([closePromise, delay(POLL_INTERVAL_MS)]);
      unexpectedExitBeforeCleanup = {
        exitCode: child.exitCode ?? null,
        signalCode: child.signalCode ?? null,
      };
    }
  }
  let survivors = await waitForNoOwnedProcesses(rootPid, profileDir, 5_000);
  if (survivors.length > 0) {
    forced = true;
    signalProcess(-rootPid, 'SIGKILL');
    for (const survivor of survivors) {
      signalProcess(survivor.pid, 'SIGKILL');
    }
    survivors = await waitForNoOwnedProcesses(rootPid, profileDir, 3_000);
  }
  const closeResult = await waitForClose(closePromise, 2_000);
  assert(closeResult, '浏览器进程结束后未收到 close，stderr 证据可能不完整');
  survivors = await ownedProcesses(rootPid, profileDir);
  assert(
    survivors.length === 0,
    `浏览器存在 ${survivors.length} 个残留进程（PID：${survivors
      .map((row) => row.pid)
      .join(',')}）`,
  );
  return {
    forced,
    controlledTerminationRequested,
    unexpectedExitBeforeCleanup,
    residualProcessCount: 0,
    closeObserved: true,
    exitCode: closeResult.exitCode ?? null,
    signalCode: closeResult.signalCode ?? null,
  };
}

function expectedSigtermCleanupLine(line) {
  if (/\bFATAL\b|CHECK failed|DCHECK failed|Aw, Snap/iu.test(line)) {
    return false;
  }
  return /^(?:\[[^\r\n]*\]\s*)?(?:Received signal 15\b.*|GPU process exited unexpectedly: exit_code=15)\s*$/iu.test(
    line.trim(),
  );
}

function fatalSignalCount(
  logText,
  {cleanup = false, controlledTerminationRequested = false} = {},
) {
  const pattern =
    /\bFATAL\b|CHECK failed|DCHECK failed|Received signal(?: \d+)?|Aw, Snap|GPU process (?:crashed|exited unexpectedly)|Render(?:er)? process (?:gone|crashed|exited|terminated)(?: unexpectedly)?|RenderProcessHost.*(?:crash|exited unexpectedly)|Child process .*exited unexpectedly|process (?:crashed|exited unexpectedly)/iu;
  return logText.split(/\r?\n/u).filter((line) => {
    if (
      cleanup &&
      controlledTerminationRequested &&
      expectedSigtermCleanupLine(line)
    ) {
      return false;
    }
    return pattern.test(line);
  }).length;
}

function expectedControlledTermination(termination) {
  if (
    !termination.controlledTerminationRequested ||
    !termination.closeObserved
  ) {
    return false;
  }
  return (
    (termination.exitCode === 0 && termination.signalCode === null) ||
    (termination.exitCode === null && termination.signalCode === 'SIGTERM')
  );
}

async function listCrashArtifacts(root, filterName = false, depth = 3) {
  const results = [];
  async function visit(path, remainingDepth) {
    const entries = await readdir(path, {withFileTypes: true}).catch((error) => {
      if (error?.code === 'ENOENT') return [];
      throw error;
    });
    for (const entry of entries) {
      const child = join(path, entry.name);
      if (entry.isDirectory() && remainingDepth > 0) {
        await visit(child, remainingDepth - 1);
      } else if (
        entry.isFile() &&
        CRASH_EXTENSION_PATTERN.test(entry.name) &&
        (!filterName || /aegis|chrome|chromium/iu.test(entry.name))
      ) {
        const metadata = await stat(child);
        results.push({path: child, size: metadata.size, mtimeMs: metadata.mtimeMs});
      }
    }
  }
  await visit(root, depth);
  return results;
}

async function snapshotGlobalCrashes() {
  const roots = [
    {path: join(homedir(), 'Library', 'Logs', 'DiagnosticReports'), filterName: true},
    {
      path: join(
        homedir(),
        'Library',
        'Application Support',
        'Chromium',
        'Crashpad',
        'completed',
      ),
      filterName: false,
    },
    {
      path: join(
        homedir(),
        'Library',
        'Application Support',
        'Chromium',
        'Crashpad',
        'reports',
      ),
      filterName: false,
    },
  ];
  const records = new Map();
  for (const root of roots) {
    for (const artifact of await listCrashArtifacts(root.path, root.filterName)) {
      records.set(artifact.path, `${artifact.size}:${artifact.mtimeMs}`);
    }
  }
  return records;
}

function crashDelta(before, after) {
  return [...after.entries()].filter(
    ([path, identity]) => before.get(path) !== identity,
  ).length;
}

function waitForWebSocketOpen(socket, timeoutMs) {
  return new Promise((resolveOpen, rejectOpen) => {
    const timer = setTimeout(() => {
      cleanup();
      rejectOpen(new VerificationError('等待 CDP WebSocket 超时'));
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
      rejectOpen(new VerificationError('CDP WebSocket 握手失败'));
    };
    const handleClose = () => {
      cleanup();
      rejectOpen(new VerificationError('CDP WebSocket 在握手前关闭'));
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

  static async connect(url, timeoutMs) {
    const parsed = new URL(url);
    assert(
      parsed.protocol === 'ws:' && parsed.hostname === '127.0.0.1',
      'CDP WebSocket 不是 loopback',
    );
    const socket = new WebSocket(url);
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
      this.eventError = new VerificationError('CDP 返回了非 JSON 消息');
      this.rejectPending(this.eventError.message);
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
            `CDP ${pending.method} 失败：${message.error.message ?? '未知错误'}`,
          ),
        );
      } else {
        pending.resolve(message.result ?? {});
      }
      return;
    }
    if (typeof message.method !== 'string') return;
    if (message.method === 'Inspector.targetCrashed') {
      this.eventError = new VerificationError('Renderer 报告 Inspector.targetCrashed');
    }
    for (const listener of this.listeners.get(message.method) ?? []) {
      try {
        listener(message.params ?? {});
      } catch (error) {
        this.eventError =
          error instanceof Error ? error : new VerificationError(String(error));
      }
    }
  }

  rejectPending(message) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new VerificationError(message));
    }
    this.pending.clear();
  }

  on(method, listener) {
    const listeners = this.listeners.get(method) ?? new Set();
    listeners.add(listener);
    this.listeners.set(method, listeners);
    return () => listeners.delete(listener);
  }

  waitForEvent(method, timeoutMs = this.timeoutMs) {
    return new Promise((resolveEvent, rejectEvent) => {
      const timer = setTimeout(() => {
        remove();
        rejectEvent(new VerificationError(`等待 CDP ${method} 超时`));
      }, timeoutMs);
      const remove = this.on(method, (params) => {
        clearTimeout(timer);
        remove();
        resolveEvent(params);
      });
    });
  }

  command(method, params = {}, timeoutMs = this.timeoutMs) {
    assert(this.socket.readyState === WebSocket.OPEN, 'CDP WebSocket 未打开');
    const id = this.nextId++;
    return new Promise((resolveCommand, rejectCommand) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectCommand(new VerificationError(`CDP ${method} 超时`));
      }, timeoutMs);
      this.pending.set(id, {
        method,
        reject: rejectCommand,
        resolve: resolveCommand,
        timer,
      });
      this.socket.send(JSON.stringify({id, method, params}));
    });
  }

  async close() {
    if (this.socket.readyState >= WebSocket.CLOSING) return;
    this.socket.close(1000, 'verification complete');
    await delay(100);
  }
}

async function waitForDevToolsEndpoint(profileDir, child, spawnState, deadline) {
  const activePortPath = join(profileDir, 'DevToolsActivePort');
  while (performance.now() < deadline) {
    if (spawnState.error) {
      fail(`Chromium 启动失败：${errorMessage(spawnState.error)}`);
    }
    if (child.exitCode !== null || child.signalCode !== null) {
      fail(`Chromium 在 DevTools 就绪前退出：${child.exitCode ?? child.signalCode}`);
    }
    const content = await readFile(activePortPath, 'utf8').catch(() => '');
    const [portText, browserPath] = content.trim().split(/\r?\n/u);
    const port = Number(portText);
    if (
      Number.isSafeInteger(port) &&
      port > 0 &&
      port <= 65_535 &&
      /^\/devtools\/browser\/[0-9a-f-]+$/iu.test(browserPath ?? '')
    ) {
      return {port, browserPath};
    }
    await delay(POLL_INTERVAL_MS);
  }
  fail('等待 loopback DevTools endpoint 超时');
}

async function createPageTarget(browserClient, fixtureUrl, deadline) {
  const parsedUrl = new URL(fixtureUrl);
  assert(
    parsedUrl.protocol === 'http:' &&
      parsedUrl.hostname === '127.0.0.1' &&
      parsedUrl.username === '' &&
      parsedUrl.password === '' &&
      parsedUrl.search === '' &&
      parsedUrl.hash === '' &&
      /^\/fixture\/[0-9a-f-]+$/iu.test(parsedUrl.pathname),
    '页面 target 只允许内部生成的 loopback fixture URL',
  );
  const result = await browserClient.command(
    'Target.createTarget',
    {url: fixtureUrl, newWindow: false, background: false},
    remainingWithinDeadline(deadline, '创建 loopback fixture 页面 target 超时'),
  );
  assert(
    typeof result.targetId === 'string' &&
      /^[0-9a-f-]+$/iu.test(result.targetId),
    'Target.createTarget 未返回有效页面标识',
  );
  return result.targetId;
}

class TraceCollector {
  constructor() {
    this.candidateEvents = [];
    this.dataBatchCount = 0;
    this.rawEventCount = 0;
  }

  collect(params) {
    assert(Array.isArray(params.value), 'Tracing.dataCollected 缺少事件数组');
    this.dataBatchCount += 1;
    this.rawEventCount += params.value.length;
    for (const event of params.value) {
      const categories =
        typeof event?.cat === 'string' ? event.cat.split(',') : [];
      if (
        categories.includes(TRACE_CATEGORY) ||
        event?.name === TRACE_EVENT_NAME
      ) {
        this.candidateEvents.push(event);
        assert(
          this.candidateEvents.length <= TRACE_RECORD_LIMIT,
          '专用 trace 候选事件超过验证器硬上限',
        );
      }
    }
  }

  finish(params) {
    assert(
      typeof params.dataLossOccurred === 'boolean',
      'Tracing.tracingComplete 缺少 dataLossOccurred',
    );
    const records = parseTraceRecords(this.candidateEvents);
    return {
      dataLossOccurred: params.dataLossOccurred,
      dataBatchCount: this.dataBatchCount,
      rawEventCount: this.rawEventCount,
      records,
    };
  }
}

function modeConfiguration(mode) {
  if (mode === 'off') {
    return {
      featureArgument: '--disable-features=AegisBytecodeShadow',
      javascriptFlagsArgument: null,
    };
  }
  if (mode === 'on') {
    return {
      featureArgument: '--enable-features=AegisBytecodeShadow',
      javascriptFlagsArgument:
        '--js-flags=--aegis-bytecode-shadow-max-records=5',
    };
  }
  if (mode === 'canary') {
    return {
      featureArgument: '--enable-features=AegisBytecodeShadow',
      javascriptFlagsArgument:
        '--js-flags=--aegis-bytecode-shadow-max-records=5,--aegis-bytecode-shadow-max-bytes=1',
    };
  }
  assert(mode === 'stress', `未知运行模式：${mode}`);
  return {
    featureArgument: '--enable-features=AegisBytecodeShadow',
    javascriptFlagsArgument:
      '--js-flags=--aegis-bytecode-shadow-max-records=1000',
  };
}

async function runMode(mode, target, fixture, temporaryRoot, timeoutMs) {
  const token = randomUUID();
  const stress = mode === 'stress';
  fixture.register(token, stress ? 'stress' : 'normal');
  const profileDir = join(temporaryRoot, `profile-${mode}`);
  await mkdir(profileDir, {recursive: true});
  const {featureArgument, javascriptFlagsArgument} = modeConfiguration(mode);
  const args = [
    '--headless=new',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-default-apps',
    '--disable-extensions',
    '--disable-sync',
    '--metrics-recording-only',
    '--no-pings',
    '--proxy-server=direct://',
    '--proxy-bypass-list=*',
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
    '--remote-debugging-port=0',
    '--enable-logging=stderr',
    '--v=0',
    ...(process.platform === 'darwin' ? ['--use-mock-keychain'] : []),
    `--user-data-dir=${profileDir}`,
    featureArgument,
    ...(javascriptFlagsArgument ? [javascriptFlagsArgument] : []),
    'about:blank',
  ];

  let stderr = '';
  let stderrBytes = 0;
  let logOverflow = false;
  let stderrConsumerAttached = false;
  let stderrConsumerAttachedAt = null;
  const consumeStderrChunk = (chunk) => {
    stderrBytes += chunk.length;
    if (stderrBytes <= LOG_LIMIT_BYTES) {
      stderr += chunk.toString('utf8');
    } else {
      logOverflow = true;
    }
  };
  const stderrHolder = stress
    ? startStderrPipeHolder(consumeStderrChunk)
    : null;
  if (stderrHolder) {
    try {
      await waitForStderrPipeHolderReady(stderrHolder);
    } catch (error) {
      const holderCleanupErrors = [];
      await captureCleanupError(holderCleanupErrors, () =>
        releaseStderrPipeHolder(stderrHolder),
      );
      await captureCleanupError(holderCleanupErrors, () =>
        finishStderrPipeHolder(stderrHolder),
      );
      throw combinePrimaryAndCleanupError(error, holderCleanupErrors);
    }
  }
  const spawnState = {error: null};
  const fixtureDeadline = performance.now() + timeoutMs;
  let child;
  try {
    child = spawn(target.executable, args, {
      detached: true,
      env: {...process.env},
      stdio: ['ignore', 'ignore', stderrHolder?.child.stdin ?? 'pipe'],
    });
  } catch (error) {
    const holderCleanupErrors = [];
    if (stderrHolder) {
      await captureCleanupError(holderCleanupErrors, () =>
        releaseStderrPipeHolder(stderrHolder),
      );
      await captureCleanupError(holderCleanupErrors, () =>
        finishStderrPipeHolder(stderrHolder),
      );
    }
    throw combinePrimaryAndCleanupError(error, holderCleanupErrors);
  }
  child.once('error', (error) => {
    spawnState.error = error;
  });
  const closePromise = new Promise((resolveClose) => {
    child.once('close', (exitCode, signalCode) =>
      resolveClose({exitCode, signalCode}),
    );
  });
  const attachStderrConsumer = () => {
    if (stderrConsumerAttached) return;
    assert(child.stderr, 'Chromium stderr 不是可读取 pipe');
    stderrConsumerAttached = true;
    stderrConsumerAttachedAt = performance.now();
    child.stderr.on('data', consumeStderrChunk);
  };
  if (!stress) attachStderrConsumer();

  let termination;
  let fixtureLogEnd = null;
  let browserClient = null;
  let removeTraceListener = null;
  let tracingStarted = false;
  let traceResult = null;
  const processInfoSnapshots = [];
  let stressLiveness = null;
  let stderrHolderTermination = null;
  let primaryError = null;
  const cleanupErrors = [];
  try {
    const endpoint = await waitForDevToolsEndpoint(
      profileDir,
      child,
      spawnState,
      fixtureDeadline,
    );
    browserClient = await CdpClient.connect(
      `ws://127.0.0.1:${endpoint.port}${endpoint.browserPath}`,
      remainingWithinDeadline(fixtureDeadline, '连接 browser CDP 超时'),
    );
    const traceCollector = new TraceCollector();
    removeTraceListener = browserClient.on(
      'Tracing.dataCollected',
      (params) => traceCollector.collect(params),
    );
    await browserClient.command(
      'Tracing.start',
      {
        tracingBackend: 'chrome',
        transferMode: 'ReportEvents',
        traceConfig: {
          recordMode: 'recordUntilFull',
          traceBufferSizeInKb: TRACE_BUFFER_SIZE_KIB,
          enableSampling: false,
          enableSystrace: false,
          enableArgumentFilter: false,
          includedCategories: [TRACE_CATEGORY],
        },
      },
      remainingWithinDeadline(fixtureDeadline, '启动专用 trace 超时'),
    );
    tracingStarted = true;
    const initialProcessInfo = await browserClient.command(
      'SystemInfo.getProcessInfo',
      {},
      remainingWithinDeadline(
        fixtureDeadline,
        '读取导航前 Chromium 进程角色超时',
      ),
    );
    assert(
      Array.isArray(initialProcessInfo.processInfo),
      '导航前 SystemInfo.getProcessInfo 未返回进程列表',
    );
    processInfoSnapshots.push(initialProcessInfo.processInfo);
    await createPageTarget(
      browserClient,
      `http://127.0.0.1:${fixture.port}/fixture/${token}`,
      fixtureDeadline,
    );
    await waitForFixtureState(
      fixture,
      token,
      child,
      spawnState,
      fixtureDeadline,
      'pending',
      '等待 fixture 控制请求超时',
    );
    assert(
      child.exitCode === null && child.signalCode === null,
      'Chromium 在 fixture 触发前退出',
    );
    fixture.release(token);
    if (stress) {
      assert(stderrHolder, 'STRESS 缺少独立 stderr pipe-holder');
      await waitForFixtureState(
        fixture,
        token,
        child,
        spawnState,
        fixtureDeadline,
        'pressure',
        '等待 stress pressure barrier 超时',
      );
      const beforeRelease = {
        holderReleased: stderrHolder.released,
        holderForwardedBytes: stderrHolder.forwardedBytes,
        applicationConsumedBytes: stderrBytes,
        chromiumStderrExposedToParent: child.stderr !== null,
      };
      assert(
        beforeRelease.holderReleased === false &&
          beforeRelease.holderForwardedBytes === 0 &&
          beforeRelease.applicationConsumedBytes === 0 &&
          beforeRelease.chromiumStderrExposedToParent === false,
        'stress pressure barrier 前独立 holder 已释放或转发 stderr',
      );
      fixture.releasePressure(token);
      await waitForFixtureState(
        fixture,
        token,
        child,
        spawnState,
        fixtureDeadline,
        'completed',
        'stderr 无消费者期间 stress fixture 未能完成',
      );
      const timing = fixture.timing(token);
      const beforeDrain = {
        holderReleased: stderrHolder.released,
        holderForwardedBytes: stderrHolder.forwardedBytes,
        applicationConsumedBytes: stderrBytes,
        chromiumStderrExposedToParent: child.stderr !== null,
      };
      const unrestrictedDrainAt = performance.now();
      assert(
        Number.isFinite(timing.completedAt) &&
          timing.completedAt < unrestrictedDrainAt &&
          beforeDrain.holderReleased === false &&
          beforeDrain.holderForwardedBytes === 0 &&
          beforeDrain.applicationConsumedBytes === 0 &&
          beforeDrain.chromiumStderrExposedToParent === false,
        'stress fixture 未在独立 holder 释放前完成',
      );
      await releaseStderrPipeHolder(stderrHolder);
      stressLiveness = {
        protocol: 'two-stage-independent-pipe-holder-v2',
        pressureFunctionCount: STRESS_PRESSURE_FUNCTIONS,
        postPressureFunctionCount: STRESS_POST_PRESSURE_FUNCTIONS,
        holderReleasedAfterFixture: stderrHolder.released,
        doneBeforeUnrestrictedDrain:
          timing.completedAt < stderrHolder.releaseRequestedAt,
        unrestrictedDrainRequestedAt: stderrHolder.releaseRequestedAt,
        unrestrictedDrainCompletedAt: stderrHolder.releasedAt,
        pressureToReleaseMs:
          timing.pressureReleasedAt - timing.pressureReachedAt,
        releaseToDoneMs: timing.completedAt - timing.pressureReleasedAt,
        beforeRelease,
        beforeDrain,
      };
    } else {
      await waitForFixtureState(
        fixture,
        token,
        child,
        spawnState,
        fixtureDeadline,
        'completed',
        '等待良性 fixture 完成超时',
      );
    }
    await delayWithinDeadline(250, fixtureDeadline, 'fixture 完成后稳定观察超时');
    const processInfoResult = await browserClient.command(
      'SystemInfo.getProcessInfo',
      {},
      remainingWithinDeadline(fixtureDeadline, '读取 Chromium 进程角色超时'),
    );
    assert(
      Array.isArray(processInfoResult.processInfo),
      'SystemInfo.getProcessInfo 未返回进程列表',
    );
    processInfoSnapshots.push(processInfoResult.processInfo);
    const tracingComplete = browserClient.waitForEvent(
      'Tracing.tracingComplete',
      remainingWithinDeadline(fixtureDeadline, '等待 trace 完成超时'),
    );
    await browserClient.command(
      'Tracing.end',
      {},
      remainingWithinDeadline(fixtureDeadline, '停止专用 trace 超时'),
    );
    const tracingCompleteParams = await tracingComplete;
    tracingStarted = false;
    removeTraceListener();
    removeTraceListener = null;
    assert(!browserClient.eventError, errorMessage(browserClient.eventError));
    traceResult = traceCollector.finish(tracingCompleteParams);
    await browserClient.close();
    browserClient = null;
    await delayWithinDeadline(100, fixtureDeadline, 'fixture 日志边界稳定超时');
    fixtureLogEnd = stderr.length;
  } catch (error) {
    primaryError = error;
  } finally {
    if (stderrHolder && !stderrHolder.released) {
      await captureCleanupError(cleanupErrors, () =>
        releaseStderrPipeHolder(stderrHolder),
      );
    }
    if (tracingStarted && browserClient) {
      await captureCleanupError(cleanupErrors, () =>
        withinTimeout(
          browserClient.command('Tracing.end', {}, 1_000),
          1_000,
          '清理阶段停止专用 trace 超时',
        ),
      );
    }
    await captureCleanupError(cleanupErrors, async () => {
      removeTraceListener?.();
    });
    await captureCleanupError(cleanupErrors, async () => browserClient?.close());
    fixtureLogEnd ??= stderr.length;
    await captureCleanupError(cleanupErrors, async () => {
      termination = await terminateOwnedBrowser(child, profileDir, closePromise);
    });
    if (stderrHolder) {
      await captureCleanupError(cleanupErrors, async () => {
        stderrHolderTermination = await finishStderrPipeHolder(stderrHolder);
      });
    }
  }
  const combinedError = combinePrimaryAndCleanupError(primaryError, cleanupErrors);
  if (combinedError) throw combinedError;
  assert(!logOverflow, `Chromium stderr 超过 ${LOG_LIMIT_BYTES} 字节安全上限`);
  assert(fixtureLogEnd !== null, 'fixture 运行日志边界未建立');
  assert(traceResult, '专用 trace 结果缺失');
  const processInfo = mergeProcessInfoSnapshots(processInfoSnapshots);
  assert(termination, 'Chromium 清理证据缺失');
  if (stress) {
    assert(
      stderrHolderTermination?.released === true &&
        stderrHolderTermination.exitCode === 0 &&
        stderrHolderTermination.signalCode === null &&
        stderrHolderTermination.forced === false,
      'STRESS 独立 stderr pipe-holder 未正常结束',
    );
  }
  const fixtureLog = stderr.slice(0, fixtureLogEnd);
  const cleanupLog = stderr.slice(fixtureLogEnd);
  const summary = summarizeRecords(traceResult.records);
  const processRoles = summarizeEmitterProcessRoles(
    traceResult.records,
    processInfo,
  );
  const fixtureEvidence = fixture.evidence(token);
  assert(fixtureEvidence, 'fixture 内容证据缺失');
  const profileCrashCount = (
    await listCrashArtifacts(profileDir, false, 5)
  ).length;
  const fixtureFatalSignalCount = fatalSignalCount(fixtureLog);
  const cleanupFatalSignalCount = fatalSignalCount(cleanupLog, {
    cleanup: true,
    controlledTerminationRequested:
      termination.controlledTerminationRequested,
  });
  return {
    featureArgument,
    javascriptFlagsArgument,
    fixtureBudgetMs: timeoutMs,
    fixtureAttribution: 'bounded-trace-window-run-level',
    totalRecordCount: traceResult.records.length,
    summary,
    processRoles,
    trace: {
      transport: 'loopback-cdp-perfetto',
      category: TRACE_CATEGORY,
      eventName: TRACE_EVENT_NAME,
      recordMode: 'record-until-full',
      bufferSizeKiB: TRACE_BUFFER_SIZE_KIB,
      dataLossOccurred: traceResult.dataLossOccurred,
      dataBatchCount: traceResult.dataBatchCount,
      rawEventCount: traceResult.rawEventCount,
      processRoleSnapshotCount: processInfoSnapshots.length,
      rawTraceStored: false,
    },
    stderr: {
      applicationConsumedBytes: stderrBytes,
      consumerInitiallyAttached: !stress,
      consumerAttachedAt: stderrConsumerAttachedAt,
      holder: stderrHolderTermination,
      rawLogStored: false,
    },
    stressLiveness,
    fixtureEvidence,
    fatalSignalCount: fixtureFatalSignalCount + cleanupFatalSignalCount,
    fatalSignalEvidence: {
      fixture: fixtureFatalSignalCount,
      cleanup: cleanupFatalSignalCount,
    },
    profileCrashCount,
    termination,
  };
}

async function acquireBuildOperationLock(target, enabled) {
  if (!enabled) {
    return async () => {};
  }
  assert(target.appPath, '构建身份绑定只支持 .app 目标');
  const lockParent = join(dirname(target.appPath), '.aegis');
  await mkdir(lockParent, {recursive: true});
  const lockPath = join(lockParent, 'build.lock');
  try {
    await mkdir(lockPath);
  } catch (error) {
    if (error?.code === 'EEXIST') {
      fail(`构建、打包或验证锁已被占用：${lockPath}`);
    }
    throw error;
  }
  return async () => {
    await rmdir(lockPath);
  };
}

async function verifyBuildIdentity(options, target) {
  if (!options.buildIdentity) {
    return {
      available: false,
      verified: false,
      status: 'unbound',
      reason: '未提供调用方固定的 schema v3 构建身份；结果仅为 research-only 运行证据',
    };
  }
  assert(target.appPath, '提供构建身份时，被测 binary 必须位于 Chromium.app 内');
  const output = await execFileText(process.execPath, [
    BUILD_IDENTITY_SCRIPT,
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
    fail('构建身份验证器返回无效 JSON');
  }
  assert(verification.verified === true, '构建身份验证器未返回 verified=true');
  assert(
    verification.manifest?.sha256 === options.buildIdentitySha256 &&
      verification.checks?.pinnedManifestDigest === true,
    '构建身份未绑定调用方固定摘要',
  );
  return {
    available: true,
    verified: true,
    status: 'bound',
    manifestSha256: verification.manifest.sha256,
    qualification: verification.qualification ?? null,
    trustLevel: verification.trustLevel ?? null,
    trustedBuildAttestation:
      verification.trustedBuildAttestation === true,
    localCandidate: verification.localCandidate === true,
    releaseCandidate: verification.releaseCandidate === true,
    pinnedManifestDigest: true,
  };
}

function assertion(name, passed, details = null) {
  return {name, passed, ...(details === null ? {} : {details})};
}

async function runVerification(options, target, identityBefore, verifierBefore) {
  const executableSha256Before = await sha256File(target.executable);
  const globalCrashBefore = await snapshotGlobalCrashes();
  const temporaryRoot = await mkdtemp(join(tmpdir(), 'aegis-bytecode-shadow-'));
  let fixture = null;
  let result = null;
  let primaryError = null;
  const cleanupErrors = [];
  try {
    const stderrBackpressureCalibration =
      await calibrateStderrBackpressure();
    fixture = await startFixtureServer();
    const off = await runMode(
      'off',
      target,
      fixture,
      temporaryRoot,
      options.timeoutMs,
    );
    const on = await runMode(
      'on',
      target,
      fixture,
      temporaryRoot,
      options.timeoutMs,
    );
    const canary = await runMode(
      'canary',
      target,
      fixture,
      temporaryRoot,
      options.timeoutMs,
    );
    const stress = await runMode(
      'stress',
      target,
      fixture,
      temporaryRoot,
      options.timeoutMs,
    );
    await delay(CRASH_OBSERVATION_MS);
    const globalCrashAfter = await snapshotGlobalCrashes();
    const newGlobalCrashCount = crashDelta(globalCrashBefore, globalCrashAfter);
    const executableSha256After = await sha256File(target.executable);
    const verifierAfter = await fileEvidence(fileURLToPath(import.meta.url));
    const verifierStable = canonical(verifierBefore) === canonical(verifierAfter);
    const assertions = [
      assertion(
        'OFF 全程不产生 bytecode shadow 记录',
        off.totalRecordCount === 0 &&
          off.summary.recordCount === 0 &&
          off.processRoles.emitterProcessCount === 0,
        {
          total: off.totalRecordCount,
          traceWindow: off.summary.recordCount,
        },
      ),
      assertion(
        '独立 pipe-holder 已用固定 126000 字节合成同步写入校准反压',
        stderrBackpressureCalibration.totalBytes === 126_000 &&
          stderrBackpressureCalibration.writerBlockedBeforeRelease === true &&
          stderrBackpressureCalibration.forwardedBytesBeforeRelease === 0 &&
          stderrBackpressureCalibration.writerCompletedAfterRelease === true &&
          stderrBackpressureCalibration.holder.ready === true &&
          stderrBackpressureCalibration.holder.exitCode === 0 &&
          stderrBackpressureCalibration.holder.signalCode === null &&
          stderrBackpressureCalibration.holder.forced === false &&
          stderrBackpressureCalibration.holder.forwardedBytes === 126_000,
        stderrBackpressureCalibration,
      ),
      assertion(
        'ON 在专用 trace 窗口产生记录且每进程不超过 5 条',
        on.summary.recordCount >= 1 &&
          on.summary.perProcessRecordCounts.every((count) => count <= 5),
        {
          total: on.summary.recordCount,
          perProcess: on.summary.perProcessRecordCounts,
        },
      ),
      assertion(
        'CANARY 在专用 trace 窗口产生记录且每进程不超过 5 条',
        canary.summary.recordCount >= 1 &&
          canary.summary.perProcessRecordCounts.every((count) => count <= 5),
        {
          total: canary.summary.recordCount,
          perProcess: canary.summary.perProcessRecordCounts,
        },
      ),
      assertion(
        'fixture 证据只声明有界 trace 窗口的 run-level 归因',
        [off, on, canary, stress].every(
          (entry) =>
            entry.fixtureAttribution === 'bounded-trace-window-run-level',
        ),
      ),
      assertion(
        'ON/CANARY/STRESS 按 feature 后 JS flags 的顺序传入硬上限',
        on.featureArgument === '--enable-features=AegisBytecodeShadow' &&
          on.javascriptFlagsArgument ===
            '--js-flags=--aegis-bytecode-shadow-max-records=5' &&
          canary.featureArgument === '--enable-features=AegisBytecodeShadow' &&
          canary.javascriptFlagsArgument ===
            '--js-flags=--aegis-bytecode-shadow-max-records=5,--aegis-bytecode-shadow-max-bytes=1' &&
          stress.featureArgument === '--enable-features=AegisBytecodeShadow' &&
          stress.javascriptFlagsArgument ===
            '--js-flags=--aegis-bytecode-shadow-max-records=1000',
      ),
      assertion(
        '四种模式均使用 32 MiB 有界专用 trace 且没有数据丢失',
        [off, on, canary, stress].every(
          (entry) =>
            entry.trace.transport === 'loopback-cdp-perfetto' &&
            entry.trace.bufferSizeKiB === TRACE_BUFFER_SIZE_KIB &&
            entry.trace.dataLossOccurred === false &&
            entry.trace.rawTraceStored === false,
        ),
      ),
      assertion(
        'ON/CANARY/STRESS 全部为 schema=2 / signature-schema=1 / observe-only',
        [on, canary, stress].every(
          (entry) =>
            entry.summary.schema === 2 &&
            entry.summary.signatureSchema === 1 &&
            entry.summary.mode === 'observe-only' &&
            entry.summary.wouldBlock === 0,
        ),
      ),
      assertion(
        'ON/CANARY/STRESS trace 发射进程均由 CDP 证明为 renderer',
        [on, canary, stress].every(
          (entry) =>
            entry.processRoles.unknownEmitterProcessCount === 0 &&
            canonical(entry.processRoles.emitterProcessTypes) ===
              canonical(['renderer']) &&
            entry.processRoles.rendererProcessCount >= 1,
        ),
        {
          on: on.processRoles,
          canary: canary.processRoles,
          stress: stress.processRoles,
        },
      ),
      assertion(
        'ON 至少产生一条有效 observed opcode 摘要',
        on.summary.statusCounts.observed >= 1 &&
          on.summary.opcodeRange.max > 0 &&
          on.summary.byteRange.max > 0 &&
          on.summary.signatures.some(
            (entry) => entry.signature !== '0000000000000000',
          ),
        {
          observed: on.summary.statusCounts.observed,
          opcodeMax: on.summary.opcodeRange.max,
          distinctSignatureCount: on.summary.distinctSignatureCount,
        },
      ),
      assertion(
        'CANARY 端到端证明 renderer 收到 max-bytes=1',
        canary.summary.statusCounts.skippedTooLarge ===
          canary.summary.recordCount &&
          canary.summary.statusCounts.observed === 0 &&
          canary.summary.opcodeRange.min === 0 &&
          canary.summary.opcodeRange.max === 0 &&
          canary.summary.signatures.length === 1 &&
          canary.summary.signatures[0]?.signature === '0000000000000000',
        {
          recordCount: canary.summary.recordCount,
          statusCounts: canary.summary.statusCounts,
          opcodeRange: canary.summary.opcodeRange,
          signatures: canary.summary.signatures,
        },
      ),
      assertion(
        'STRESS 至少一个已映射 renderer 达到每进程 1000 条硬上限',
        stress.processRoles.maxRecordsInSingleRenderer === 1000 &&
          stress.summary.statusCounts.observed >= 1000 &&
          stress.processRoles.perRendererRecordCounts.every(
            (count) => count <= 1000,
          ),
        {
          total: stress.summary.recordCount,
          perRenderer: stress.processRoles.perRendererRecordCounts,
          observed: stress.summary.statusCounts.observed,
        },
      ),
      assertion(
        'STRESS 两阶段页面在独立 stderr holder 释放前完成',
        stress.stderr.consumerInitiallyAttached === false &&
          stress.stressLiveness?.protocol ===
            'two-stage-independent-pipe-holder-v2' &&
          stress.stressLiveness.holderReleasedAfterFixture === true &&
          stress.stressLiveness.doneBeforeUnrestrictedDrain === true &&
          stress.stressLiveness.beforeRelease.holderReleased === false &&
          stress.stressLiveness.beforeRelease.holderForwardedBytes === 0 &&
          stress.stressLiveness.beforeRelease.applicationConsumedBytes === 0 &&
          stress.stressLiveness.beforeDrain.holderReleased === false &&
          stress.stressLiveness.beforeDrain.holderForwardedBytes === 0 &&
          stress.stressLiveness.beforeDrain.applicationConsumedBytes === 0 &&
          stress.stressLiveness.unrestrictedDrainRequestedAt <=
            stress.stressLiveness.unrestrictedDrainCompletedAt &&
          stress.stderr.holder?.ready === true &&
          stress.stderr.holder?.exitCode === 0 &&
          stress.stderr.holder?.signalCode === null &&
          stress.stderr.holder?.forced === false &&
          stress.stressLiveness.pressureFunctionCount ===
            STRESS_PRESSURE_FUNCTIONS &&
          stress.stressLiveness.postPressureFunctionCount ===
            STRESS_POST_PRESSURE_FUNCTIONS,
        stress.stressLiveness,
      ),
      assertion(
        '实际发送的 fixture 内容已绑定 SHA-256 与字节数',
        [off, on, canary, stress].every(
          (mode) =>
            Number.isSafeInteger(mode.fixtureEvidence.size) &&
            mode.fixtureEvidence.size > 0 &&
            /^[0-9a-f]{64}$/u.test(mode.fixtureEvidence.sha256),
        ) &&
          stress.fixtureEvidence.kind === 'stress' &&
          /^[0-9a-f]{64}$/u.test(stress.fixtureEvidence.protocolSha256),
      ),
      assertion(
        'OFF/ON/CANARY/STRESS 没有 Chromium fatal/crash 日志',
        off.fatalSignalCount === 0 &&
          on.fatalSignalCount === 0 &&
          canary.fatalSignalCount === 0 &&
          stress.fatalSignalCount === 0,
        {
          off: off.fatalSignalCount,
          on: on.fatalSignalCount,
          canary: canary.fatalSignalCount,
          stress: stress.fatalSignalCount,
        },
      ),
      assertion(
        '临时 Profile 没有 crash artifact',
        off.profileCrashCount === 0 &&
          on.profileCrashCount === 0 &&
          canary.profileCrashCount === 0 &&
          stress.profileCrashCount === 0,
        {
          off: off.profileCrashCount,
          on: on.profileCrashCount,
          canary: canary.profileCrashCount,
          stress: stress.profileCrashCount,
        },
      ),
      assertion('全局 crash 快照无新增', newGlobalCrashCount === 0, {
        actual: newGlobalCrashCount,
      }),
      assertion(
        '四种模式启动进程均无残留',
        off.termination.residualProcessCount === 0 &&
          on.termination.residualProcessCount === 0 &&
          canary.termination.residualProcessCount === 0 &&
          stress.termination.residualProcessCount === 0,
      ),
      assertion(
        '四种模式均无需 SIGKILL 强制清理',
        off.termination.forced === false &&
          on.termination.forced === false &&
          canary.termination.forced === false &&
          stress.termination.forced === false,
        {
          off: off.termination.forced,
          on: on.termination.forced,
          canary: canary.termination.forced,
          stress: stress.termination.forced,
        },
      ),
      assertion(
        '四种模式在主动清理前均未自行退出',
        off.termination.unexpectedExitBeforeCleanup === null &&
          on.termination.unexpectedExitBeforeCleanup === null &&
          canary.termination.unexpectedExitBeforeCleanup === null &&
          stress.termination.unexpectedExitBeforeCleanup === null,
        {
          off: off.termination.unexpectedExitBeforeCleanup,
          on: on.termination.unexpectedExitBeforeCleanup,
          canary: canary.termination.unexpectedExitBeforeCleanup,
          stress: stress.termination.unexpectedExitBeforeCleanup,
        },
      ),
      assertion(
        '四种模式 close 完整且最终退出可由主动 SIGTERM 解释',
        expectedControlledTermination(off.termination) &&
          expectedControlledTermination(on.termination) &&
          expectedControlledTermination(canary.termination) &&
          expectedControlledTermination(stress.termination),
        {
          off: off.termination,
          on: on.termination,
          canary: canary.termination,
          stress: stress.termination,
        },
      ),
      assertion('验证器源码在运行前后未漂移', verifierStable, {
        before: verifierBefore.sha256,
        after: verifierAfter.sha256,
      }),
      assertion(
        '执行期间被测可执行文件摘要未漂移',
        executableSha256Before === executableSha256After,
      ),
    ];
    const runtimePass = assertions.every((entry) => entry.passed);
    result = {
      schemaVersion: 2,
      kind: 'aegis-bytecode-shadow-runtime',
      passed: runtimePass,
      partial: runtimePass,
      qualification: 'research-only',
      runtime_pass: runtimePass,
      release_eligible: false,
      sourceArtifactBinding: {
        before: identityBefore,
        identityBound: identityBefore.verified === true,
        stable: null,
      },
      target: {
        inputKind: target.inputKind,
        executableSha256: executableSha256After,
      },
      fixture: {
        transport: 'loopback-http',
        address: '127.0.0.1',
        benignJavaScriptOnly: true,
        fixtureAttribution: 'bounded-trace-window-run-level',
        exactSignatureBound: false,
        servedBodies: {
          off: off.fixtureEvidence,
          on: on.fixtureEvidence,
          canary: canary.fixtureEvidence,
          stress: stress.fixtureEvidence,
        },
      },
      verifier: {
        before: verifierBefore,
        after: verifierAfter,
        stable: verifierStable,
      },
      privacy: {
        rawLogsStored: false,
        rawTraceStored: false,
        traceMetadataStored: false,
        pageSourceStored: false,
        pageUrlStored: false,
        functionNamesStored: false,
        bytecodeOperandsStored: false,
        retainedEvidence: ['record-counts', 'opcode-sequence-signatures'],
      },
      stderrBackpressureCalibration,
      modes: {off, on, canary, stress},
      crashEvidence: {
        newGlobalCrashCount,
        profileCrashCount:
          off.profileCrashCount +
          on.profileCrashCount +
          canary.profileCrashCount +
          stress.profileCrashCount,
        fatalSignalCount:
          off.fatalSignalCount +
          on.fatalSignalCount +
          canary.fatalSignalCount +
          stress.fatalSignalCount,
      },
      assertions,
      assertionSummary: {
        passed: assertions.filter((entry) => entry.passed).length,
        total: assertions.length,
      },
      environment: {
        platform: process.platform,
        architecture: process.arch,
        node: process.version,
      },
    };
  } catch (error) {
    primaryError = error;
  } finally {
    await captureCleanupError(cleanupErrors, async () => fixture?.close());
    await captureCleanupError(cleanupErrors, () =>
      rm(temporaryRoot, {recursive: true, force: true}),
    );
  }
  const combinedError = combinePrimaryAndCleanupError(primaryError, cleanupErrors);
  if (combinedError) throw combinedError;
  assert(result, '运行时验证结果缺失');
  return result;
}

async function runSelfTest() {
  const cases = [];
  const tests = [];
  const test = (name, callback) => {
    cases.push({name, callback});
  };
  const runCase = async ({name, callback}) => {
    try {
      await callback();
      tests.push({name, passed: true});
    } catch (error) {
      tests.push({name, passed: false, error: errorMessage(error)});
    }
  };
  const expectReject = (value) => {
    let rejected = false;
    try {
      parseTraceRecords(value);
    } catch {
      rejected = true;
    }
    assert(rejected, '严格 parser 未拒绝无效 trace');
  };
  const traceEvent = (overrides = {}) => ({
    cat: TRACE_CATEGORY,
    name: TRACE_EVENT_NAME,
    ph: 'I',
    pid: 42,
    args: {
      bytes: 42,
      mode_code: 0,
      opcodes: 7,
      record_schema: 2,
      signature_hi: 0x0123_4567,
      signature_lo: 0x89ab_cdef,
      signature_schema: 1,
      status_code: 0,
      would_block: 0,
    },
    ...overrides,
  });
  const observed = traceEvent();
  const skipped = traceEvent({
    args: {
      ...traceEvent().args,
      bytes: 70_000,
      opcodes: 0,
      signature_hi: 0,
      signature_lo: 0,
      status_code: 1,
    },
  });

  test('接受严格 observed 记录', () => {
    const records = parseTraceRecords([observed]);
    assert(records.length === 1 && records[0].signature === '0123456789abcdef', 'observed 解析失败');
  });
  test('接受严格 skipped-too-large 并支持多条', () => {
    const records = parseTraceRecords([observed, skipped]);
    assert(records.length === 2 && records[1].status === 'skipped-too-large', '多条记录解析失败');
  });
  test('拒绝错误分类、名称和 phase', () => {
    expectReject([{...observed, cat: 'disabled-by-default-v8.compile'}]);
    expectReject([{...observed, name: 'V8.AegisBytecodeShadowOther'}]);
    expectReject([{...observed, ph: 'X'}]);
  });
  test('拒绝 would_block=1', () => {
    expectReject([{...observed, args: {...observed.args, would_block: 1}}]);
  });
  test('拒绝错误 schema 和签名分片范围', () => {
    expectReject([{...observed, args: {...observed.args, record_schema: 1}}]);
    expectReject([
      {...observed, args: {...observed.args, signature_hi: 0x1_0000_0000}},
    ]);
  });
  test('拒绝 uint32 越界长度与零字节 skipped 记录', () => {
    expectReject([
      {...observed, args: {...observed.args, bytes: 0x1_0000_0000}},
    ]);
    expectReject([
      {...observed, args: {...observed.args, opcodes: 0x1_0000_0000}},
    ]);
    expectReject([{...skipped, args: {...skipped.args, bytes: 0}}]);
  });
  test('拒绝任何额外参数，包括 source、URL 和函数名', () => {
    for (const [name, value] of [
      ['candidate_match', 0],
      ['source', 'hidden'],
      ['url', 'http://invalid.test/'],
      ['function_name', 'hidden'],
    ]) {
      expectReject([{...observed, args: {...observed.args, [name]: value}}]);
    }
  });
  test('拒绝 skipped-too-large 携带摘要', () => {
    expectReject([
      {...skipped, args: {...skipped.args, signature_lo: 1}},
    ]);
  });
  test('摘要只保留计数和签名', () => {
    const summary = summarizeRecords(parseTraceRecords([observed, skipped]));
    const serialized = canonical(summary);
    assert(summary.recordCount === 2 && summary.signatures.length === 2, '摘要计数错误');
    assert(!/source|url|function_name|functionName/iu.test(serialized), '摘要泄露禁止字段');
    assert(summary.maxRecordsInSingleProcess === 2, '每进程计界摘要错误');
  });
  test('进程角色摘要不保留 PID 且能证明 renderer', () => {
    const records = parseTraceRecords([observed, skipped]);
    const roles = summarizeEmitterProcessRoles(
      records,
      mergeProcessInfoSnapshots([
        [
          {id: 42, type: 'renderer'},
          {id: 84, type: 'browser'},
        ],
        [
          {id: 42, type: 'renderer'},
          {id: 126, type: 'utility'},
        ],
      ]),
    );
    assert(
      roles.unknownEmitterProcessCount === 0 &&
        roles.maxRecordsInSingleRenderer === 2 &&
        canonical(roles.emitterProcessTypes) === canonical(['renderer']),
      'renderer 角色摘要错误',
    );
    assert(!canonical(roles).includes('42'), '进程角色摘要不得保留 PID');
  });
  test('primary 与 cleanup 双失败均被保留且 primary 在前', () => {
    const combined = combinePrimaryAndCleanupError(
      new VerificationError('primary-marker'),
      [new VerificationError('cleanup-marker')],
    );
    assert(
      combined instanceof VerificationError &&
        combined.message.indexOf('primary-marker') >= 0 &&
        combined.message.indexOf('cleanup-marker') >
          combined.message.indexOf('primary-marker'),
      '双失败错误链未保留 primary 与 cleanup',
    );
  });
  test('良性 fixture 在脚本执行前已有 body', () => {
    const html = fixtureHtml('00000000-0000-0000-0000-000000000000');
    const bodyOffset = html.indexOf('<body>');
    const scriptOffset = html.indexOf('<script>');
    assert(bodyOffset >= 0 && bodyOffset < scriptOffset, 'fixture body 顺序错误');
  });
  test('stress fixture 固定两阶段函数数和协议摘要', () => {
    const html = fixtureHtml(
      '00000000-0000-0000-0000-000000000000',
      'stress',
    );
    assert(
      (html.match(/function aegisPressureFunction\d+\(/gu) ?? []).length ===
        STRESS_PRESSURE_FUNCTIONS,
      'stress pressure 函数数量错误',
    );
    assert(
      (html.match(/function aegisPostPressureFunction\d+\(/gu) ?? []).length ===
        STRESS_POST_PRESSURE_FUNCTIONS,
      'stress post-pressure 函数数量错误',
    );
    assert(!/\beval\s*\(|new\s+Function\b/u.test(html), 'stress fixture 不得动态执行源码');
    assert(/\/pressure\//u.test(html) && /\/done\//u.test(html), 'stress barrier 缺失');
    assert(/^[0-9a-f]{64}$/u.test(sha256Text(canonical(stressProtocol()))), 'stress 协议摘要无效');
  });
  test('loopback fixture 只在完整请求体与正确阶段后完成', async () => {
    const fixture = await startFixtureServer();
    const waitFor = async (predicate, message) => {
      const deadline = performance.now() + 2_000;
      while (performance.now() < deadline) {
        if (predicate()) return;
        await delay(10);
      }
      fail(message);
    };
    const serve = async (token, mode = 'normal') => {
      fixture.register(token, mode);
      const responsePromise = fetch(
        `http://127.0.0.1:${fixture.port}/fixture/${token}`,
      );
      await waitFor(() => fixture.pending(token), 'self-test fixture 未进入 pending');
      fixture.release(token);
      const response = await responsePromise;
      assert(response.ok, 'self-test fixture GET 失败');
      await response.arrayBuffer();
    };
    try {
      const earlyToken = randomUUID();
      fixture.register(earlyToken);
      const early = await fetch(
        `http://127.0.0.1:${fixture.port}/done/${earlyToken}`,
        {method: 'POST', body: NORMAL_DONE_BODY},
      );
      assert(early.status === 409 && !fixture.completed(earlyToken), '乱序 done 未被拒绝');

      const invalidToken = randomUUID();
      await serve(invalidToken);
      const invalid = await fetch(
        `http://127.0.0.1:${fixture.port}/done/${invalidToken}`,
        {method: 'POST', body: `${NORMAL_DONE_BODY}-extra`},
      );
      assert(invalid.status === 400 && !fixture.completed(invalidToken), '错误 done body 未被拒绝');

      const normalToken = randomUUID();
      await serve(normalToken);
      const normal = await fetch(
        `http://127.0.0.1:${fixture.port}/done/${normalToken}`,
        {method: 'POST', body: NORMAL_DONE_BODY},
      );
      assert(normal.status === 204 && fixture.completed(normalToken), '完整 normal done 未通过');

      const stressToken = randomUUID();
      await serve(stressToken, 'stress');
      const pressurePromise = fetch(
        `http://127.0.0.1:${fixture.port}/pressure/${stressToken}`,
        {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify(stressProtocol().pressure),
        },
      );
      await waitFor(() => fixture.pressure(stressToken), 'self-test pressure 未到达');
      assert(!fixture.completed(stressToken), 'pressure 阶段不得提前完成');
      fixture.releasePressure(stressToken);
      const pressure = await pressurePromise;
      assert(pressure.status === 204, 'pressure barrier 释放失败');
      const done = await fetch(
        `http://127.0.0.1:${fixture.port}/done/${stressToken}`,
        {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify(stressProtocol().done),
        },
      );
      assert(done.status === 204 && fixture.completed(stressToken), 'stress done 未通过');
    } finally {
      await fixture.close();
    }
  });
  test('loopback fixture 页面由 browser CDP 在 trace 后显式创建', async () => {
    const calls = [];
    const fixtureUrl =
      'http://127.0.0.1:43210/fixture/00000000-0000-0000-0000-000000000000';
    const targetId = await createPageTarget(
      {
        command: async (...args) => {
          calls.push(args);
          return {targetId: 'ABCDEF0123456789'};
        },
      },
      fixtureUrl,
      performance.now() + 1_000,
    );
    assert(
      targetId === 'ABCDEF0123456789' &&
        calls.length === 1 &&
        calls[0][0] === 'Target.createTarget' &&
        calls[0][1].url === fixtureUrl,
      'browser CDP 页面创建协议错误',
    );
  });
  test('browser CDP 页面创建拒绝非 loopback fixture URL', async () => {
    let rejected = false;
    try {
      await createPageTarget(
        {command: async () => ({targetId: 'should-not-run'})},
        'https://example.test/fixture/00000000-0000-0000-0000-000000000000',
        performance.now() + 1_000,
      );
    } catch {
      rejected = true;
    }
    assert(rejected, '非 loopback fixture URL 未被拒绝');
  });
  test('清理日志只豁免精确可解释的 SIGTERM 15', () => {
    const gpuSigterm =
      '[1:2:ERROR:gpu_process_host.cc(1035)] GPU process exited unexpectedly: exit_code=15';
    assert(fatalSignalCount('Received signal 15') === 1, '运行窗口不应豁免 signal 15');
    assert(
      fatalSignalCount(`${gpuSigterm}\nReceived signal 15`, {
        cleanup: true,
        controlledTerminationRequested: true,
      }) === 0,
      '主动清理的精确 signal 15 应可解释',
    );
    assert(
      fatalSignalCount('Received signal 11', {
        cleanup: true,
        controlledTerminationRequested: true,
      }) === 1,
      '清理期间延迟到达的异常 signal 必须失败',
    );
    assert(
      fatalSignalCount('FATAL Received signal 15', {
        cleanup: true,
        controlledTerminationRequested: true,
      }) === 1,
      'FATAL 不得冒充正常 SIGTERM',
    );
  });
  test('覆盖 Chromium renderer、child 与 RenderProcessHost 崩溃格式', () => {
    for (const line of [
      'Render process gone.',
      'Renderer process terminated unexpectedly',
      'Renderer process exited with code 11',
      'Child process 123 exited unexpectedly',
      'RenderProcessHost reported a crash',
    ]) {
      assert(fatalSignalCount(line) === 1, `未识别崩溃日志：${line}`);
    }
  });
  test('主动清理只接受 close 后的 code=0 或 SIGTERM', () => {
    const base = {
      controlledTerminationRequested: true,
      closeObserved: true,
      exitCode: 0,
      signalCode: null,
    };
    assert(expectedControlledTermination(base), '正常 code=0 应通过');
    assert(
      expectedControlledTermination({...base, exitCode: null, signalCode: 'SIGTERM'}),
      '正常 SIGTERM 应通过',
    );
    assert(
      !expectedControlledTermination({...base, exitCode: null, signalCode: 'SIGSEGV'}),
      'SIGSEGV 不得通过',
    );
    assert(
      !expectedControlledTermination({...base, closeObserved: false}),
      '未收到 close 不得通过',
    );
  });
  test('CANARY 同时启用 feature、记录上限和 1-byte 上限', () => {
    const canary = modeConfiguration('canary');
    assert(
      canary.featureArgument === '--enable-features=AegisBytecodeShadow' &&
        canary.javascriptFlagsArgument ===
          '--js-flags=--aegis-bytecode-shadow-max-records=5,--aegis-bytecode-shadow-max-bytes=1',
      'canary 参数错误',
    );
  });
  test('STRESS 使用每进程 1000 条硬上限', () => {
    const stress = modeConfiguration('stress');
    assert(
      stress.featureArgument === '--enable-features=AegisBytecodeShadow' &&
        stress.javascriptFlagsArgument ===
          '--js-flags=--aegis-bytecode-shadow-max-records=1000',
      'stress 参数错误',
    );
  });
  test('独立 pipe-holder 在固定合成日志量下形成真实反压', async () => {
    const evidence = await calibrateStderrBackpressure();
    assert(
      evidence.totalBytes === 126_000 &&
        evidence.writerBlockedBeforeRelease === true &&
        evidence.forwardedBytesBeforeRelease === 0 &&
        evidence.writerCompletedAfterRelease === true &&
        evidence.holder.ready === true &&
        evidence.holder.forwardedBytes === 126_000 &&
        evidence.holder.exitCode === 0 &&
        evidence.holder.signalCode === null &&
        evidence.holder.forced === false,
      '独立 pipe-holder 反压校准失败',
    );
  });

  for (const testCase of cases) {
    await runCase(testCase);
  }
  const passed = tests.filter((entry) => entry.passed).length;
  return {
    schemaVersion: 2,
    kind: 'aegis-bytecode-shadow-runtime-self-test',
    passed: passed === tests.length,
    summary: {passed, total: tests.length},
    tests,
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printUsage();
    return;
  }
  if (options.selfTest) {
    const report = await runSelfTest();
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    if (!report.passed) process.exitCode = 1;
    return;
  }

  const target = await resolveTarget(options);
  approvedReportPath = await validateReportPath(options, target);
  const releaseLock = await acquireBuildOperationLock(
    target,
    Boolean(options.buildIdentity),
  );
  let primaryError = null;
  let report = null;
  const cleanupErrors = [];
  try {
    const verifierBefore = await fileEvidence(fileURLToPath(import.meta.url));
    const identityBefore = await verifyBuildIdentity(options, target);
    report = await runVerification(
      options,
      target,
      identityBefore,
      verifierBefore,
    );
    const identityAfter = await verifyBuildIdentity(options, target);
    const identityStable = identityBefore.verified
      ? canonical(identityBefore) === canonical(identityAfter)
      : null;
    if (identityBefore.verified) {
      assert(identityStable, '运行前后构建身份发生漂移');
    }
    const verifierFinal = await fileEvidence(fileURLToPath(import.meta.url));
    assert(
      canonical(verifierBefore) === canonical(verifierFinal),
      '写报告前验证器源码发生漂移',
    );
    report.verifier.after = verifierFinal;
    report.verifier.stable = true;
    report.sourceArtifactBinding.after = identityAfter;
    report.sourceArtifactBinding.stable = identityStable;
  } catch (error) {
    primaryError = error;
  } finally {
    await captureCleanupError(cleanupErrors, releaseLock);
  }
  const combinedError = combinePrimaryAndCleanupError(primaryError, cleanupErrors);
  if (combinedError) throw combinedError;
  assert(report, '锁内封存的运行时报告缺失');
  await writeJsonExclusive(approvedReportPath, report);
  printReport(report, approvedReportPath);
  process.exitCode = report.runtime_pass ? 2 : 1;
}

main().catch(async (error) => {
  const report = {
    schemaVersion: 2,
    kind: 'aegis-bytecode-shadow-runtime-error',
    passed: false,
    partial: false,
    qualification: 'research-only',
    runtime_pass: false,
    release_eligible: false,
    error: errorMessage(error),
  };
  await writeJsonExclusive(approvedReportPath, report).catch(() => {});
  printReport(report, approvedReportPath, process.stderr);
  process.exitCode = 1;
});
