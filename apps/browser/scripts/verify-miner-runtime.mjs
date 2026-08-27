#!/usr/bin/env node

import {execFile, spawn} from 'node:child_process';
import {createHash, randomUUID} from 'node:crypto';
import {
  closeSync,
  constants as fsConstants,
  createReadStream,
  openSync,
  readFileSync,
} from 'node:fs';
import {
  access,
  link,
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  readlink,
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
const CHROMIUM_ROOT_MARKER = join(BROWSER_ROOT, '.chromium-root');
const BUILD_IDENTITY_SCRIPT = join(
  BROWSER_ROOT,
  'scripts',
  'write-build-identity.mjs',
);
const DEFAULT_TIMEOUT_MS = 45_000;
const POLL_INTERVAL_MS = 100;
const PROCESS_STABILITY_OBSERVATION_MS = 750;
const CRASH_STABILITY_OBSERVATION_MS = 3_000;
const COMPUTE_WORKLOAD_MS = 12_000;
const CPU_ONLY_WORKLOAD_MS = 5_000;
const MINER_ALERT_PREFIX = '[AegisMinerGuard] schema=1 mode=observe_only';
const MINER_ALERT_PATTERN =
  /\[\d+:\d+:(?:\d{4}\/\d{6}\.\d+:)?INFO:chrome\/browser\/aegis\/aegis_service\.cc(?::\d+|\(\d+\))\]\s+\[AegisMinerGuard\] schema=1 mode=observe_only verdict=likely_mining score_bucket=high\s*$/u;
const TEST_HOSTS = Object.freeze({
  chat: 'chat.localhost',
  compute: 'compute.localhost',
  cpu: 'cpu.localhost',
  positive: 'miner.localhost',
});
let approvedReportPath = null;

class VerificationError extends Error {}

class ProcessLeakError extends VerificationError {
  constructor(message, evidence) {
    super(message);
    this.name = 'ProcessLeakError';
    this.evidence = evidence;
  }
}

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

function serializeError(error) {
  return {
    name: error instanceof Error ? error.name : 'Error',
    message: errorMessage(error),
    ...(error?.evidence ? {evidence: error.evidence} : {}),
  };
}

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

function canonical(value) {
  return JSON.stringify(value);
}

function resolveDefaultChromiumRoot() {
  const configuredRoot = process.env.CHROMIUM_ROOT?.trim();
  if (configuredRoot) {
    return resolve(configuredRoot);
  }
  try {
    const markerRoot = readFileSync(CHROMIUM_ROOT_MARKER, 'utf8').trim();
    if (markerRoot) {
      return resolve(markerRoot);
    }
  } catch {
    // 标记文件可选；默认路径与其他浏览器运行时验证器一致。
  }
  return join(homedir(), 'Projects', 'GCSA-aegis-chromium');
}

function defaultChromiumPath() {
  const outDir = process.env.OUT_DIR?.trim()
    ? resolve(process.env.OUT_DIR.trim())
    : join(resolveDefaultChromiumRoot(), 'src', 'out', 'AegisRelease');
  return join(outDir, 'Chromium.app');
}

function printUsage() {
  process.stdout.write(`用法：
  node apps/browser/scripts/verify-miner-runtime.mjs [选项]

选项：
  --chromium PATH     Chromium.app 或 Chromium 可执行文件
                      默认：${defaultChromiumPath()}
  --timeout-ms N      每个场景的硬超时，默认 ${DEFAULT_TIMEOUT_MS}
  --headed            使用可见窗口；默认 --headless=new
  --build-identity PATH
                      显式指定两阶段构建身份清单
  --build-identity-sha256 SHA256
                      调用方固定的清单摘要；必须与 --build-identity 成对出现
  --report PATH       将完整 JSON 报告写入显式路径（拒绝覆盖）
  --keep-profile      成功后也保留临时 Profile 与逐场景日志
  --dry-run           只校验参数、可执行文件和构建身份
  --self-test         运行参数、断言和 loopback fixture 自测
  --help              显示帮助

验证矩阵只访问 127.0.0.1：正例为有界 Worker + Wasm + CPU + 本机
/stratum WebSocket 组合；负例覆盖 CPU-only、Worker/Wasm 高负载、普通
/chat WebSocket、Profile pref off 和 Aegis master feature off。fixture 不含
钱包、矿池、share 或真实挖矿协议。行为通过但不具发布资格返回 2。
告警只从 Chromium stderr 的固定隐私行取证，不枚举或附着受保护 WebUI。
`);
}

function parseArgs(argv) {
  const options = {
    buildIdentity: null,
    buildIdentitySha256: null,
    chromium:
      process.env.AEGIS_CHROMIUM_BIN?.trim() || defaultChromiumPath(),
    dryRun: false,
    headed: false,
    help: false,
    keepProfile: false,
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
    if (argument === '--chromium') {
      options.chromium = valueAfter(index, argument);
      index += 1;
    } else if (argument === '--timeout-ms') {
      options.timeoutMs = Number(valueAfter(index, argument));
      index += 1;
      assert(
        Number.isSafeInteger(options.timeoutMs) && options.timeoutMs >= 15_000,
        '--timeout-ms 必须是至少 15000 的整数',
      );
    } else if (argument === '--headed') {
      options.headed = true;
    } else if (argument === '--build-identity') {
      options.buildIdentity = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--build-identity-sha256') {
      options.buildIdentitySha256 = valueAfter(index, argument);
      index += 1;
    } else if (argument === '--report') {
      options.report = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--keep-profile') {
      options.keepProfile = true;
    } else if (argument === '--dry-run') {
      options.dryRun = true;
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
  assert(
    !(options.selfTest && options.dryRun),
    '--self-test 与 --dry-run 不能同时使用',
  );
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

async function resolveChromiumExecutable(inputPath) {
  let executable = resolve(inputPath);
  if (basename(executable).endsWith('.app')) {
    executable = join(executable, 'Contents', 'MacOS', 'Chromium');
  }
  const metadata = await stat(executable).catch(() => null);
  assert(metadata?.isFile(), `Chromium 可执行文件不存在：${executable}`);
  await access(executable, fsConstants.X_OK).catch(() => {
    fail(`Chromium 不可执行：${executable}`);
  });
  return realpath(executable);
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
  return createHash('sha256').update(value).digest('hex');
}

function execFileText(file, args, options = {}) {
  return new Promise((resolveCommand, rejectCommand) => {
    execFile(
      file,
      args,
      {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...options},
      (error, stdout, stderr) => {
        if (error) {
          rejectCommand(
            new VerificationError(
              `${basename(file)} ${args.join(' ')} 失败：${
                stderr.trim() || error.message
              }`,
            ),
          );
          return;
        }
        resolveCommand(stdout);
      },
    );
  });
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
          exitCode: typeof error?.code === 'number' ? error.code : error ? 1 : 0,
          stdout,
          stderr,
          error: error ? error.message : null,
        });
      },
    );
  });
}

function pathIsWithin(root, candidate) {
  const value = relative(resolve(root), resolve(candidate));
  return value === '' || (value !== '..' && !value.startsWith(`..${sep}`));
}

async function canonicalPotentialPath(path) {
  let cursor = resolve(path);
  const missing = [];
  while (true) {
    try {
      const canonicalParent = await realpath(cursor);
      return resolve(canonicalParent, ...missing.reverse());
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        throw error;
      }
      const parent = dirname(cursor);
      assert(parent !== cursor, `无法解析输出路径：${path}`);
      missing.push(basename(cursor));
      cursor = parent;
    }
  }
}

async function validateEvidenceOutputPaths(options, appPath) {
  if (!options.report) {
    return null;
  }
  const existingReport = await lstat(options.report).catch((error) => {
    if (error?.code === 'ENOENT') return null;
    throw error;
  });
  assert(existingReport === null, '--report 已存在；拒绝覆盖既有证据');
  const canonicalReport = await canonicalPotentialPath(options.report);
  const canonicalApp = await realpath(appPath);
  assert(!pathIsWithin(canonicalApp, canonicalReport), '--report 不得位于被测 App 内');
  if (options.buildIdentity) {
    const canonicalManifest = await canonicalPotentialPath(options.buildIdentity);
    const canonicalSidecar = await canonicalPotentialPath(
      `${options.buildIdentity}.sha256`,
    );
    assert(
      canonicalReport !== canonicalManifest && canonicalReport !== canonicalSidecar,
      '--report 不得覆盖构建身份清单或 sidecar',
    );
  }
  for (const root of [REPO_ROOT, join(resolveDefaultChromiumRoot(), 'src')]) {
    const canonicalRoot = await realpath(root);
    const gitDir = (
      await execFileText('/usr/bin/git', [
        '-C',
        canonicalRoot,
        'rev-parse',
        '--absolute-git-dir',
      ])
    ).trim();
    assert(
      !pathIsWithin(await realpath(gitDir), canonicalReport),
      '--report 不得位于 Git 元数据中',
    );
    if (pathIsWithin(canonicalRoot, canonicalReport)) {
      const tracked = await execFileOutcome('/usr/bin/git', [
        '-C',
        canonicalRoot,
        'ls-files',
        '--error-unmatch',
        '--',
        relative(canonicalRoot, canonicalReport),
      ]);
      assert(!tracked.passed, '--report 不得覆盖已跟踪源码');
    }
  }
  return canonicalReport;
}

async function acquireBuildOperationLock(outDir) {
  const lockPath = join(outDir, '.aegis', 'build.lock');
  try {
    await mkdir(lockPath);
  } catch (error) {
    if (error?.code === 'EEXIST') {
      fail(`构建、打包或验证锁已被占用：${lockPath}`);
    }
    throw error;
  }
  return async () => {
    await rmdir(lockPath).catch(() => {});
  };
}

async function verifySourceArtifactBinding(options, chromiumExecutable) {
  if (!options.buildIdentity) {
    return {
      available: false,
      verified: false,
      reason:
        '未显式提供两阶段构建身份清单及调用方固定 SHA-256；行为验证不能自行生成来源证明',
    };
  }
  const appPath = resolve(dirname(chromiumExecutable), '..', '..');
  const output = await execFileText(process.execPath, [
    BUILD_IDENTITY_SCRIPT,
    '--phase',
    'verify',
    '--manifest',
    options.buildIdentity,
    '--expected-sha256',
    options.buildIdentitySha256,
    '--out-dir',
    dirname(appPath),
    '--artifact',
    appPath,
  ]);
  let verification;
  try {
    verification = JSON.parse(output);
  } catch (error) {
    fail(`构建身份验证器返回无效 JSON：${error.message}`);
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
    qualification: verification.qualification,
    releaseBoundary: verification.releaseBoundary,
    localCandidate: verification.localCandidate,
    releaseCandidate: verification.releaseCandidate,
    trustLevel: verification.trustLevel,
    trustedBuildAttestation: verification.trustedBuildAttestation,
    manifest: verification.manifest,
    source: verification.source,
    build: verification.build,
    artifacts: verification.artifacts,
    checks: verification.checks,
  };
}

async function collectCodeSignatureEvidence(appPath) {
  if (process.platform !== 'darwin') {
    return {supported: false, strictDeepValid: false};
  }
  const details = await execFileOutcome('/usr/bin/codesign', [
    '-dv',
    '--verbose=4',
    appPath,
  ]);
  const strict = await execFileOutcome('/usr/bin/codesign', [
    '--verify',
    '--deep',
    '--strict',
    '--verbose=2',
    appPath,
  ]);
  const detailText = `${details.stdout}\n${details.stderr}`;
  const value = (name) =>
    detailText.match(new RegExp(`^${name}=(.*)$`, 'mu'))?.[1]?.trim() ?? null;
  const flags = detailText.match(/^CodeDirectory .* flags=[^\n]+$/mu)?.[0] ?? null;
  return {
    supported: true,
    strictDeepValid: strict.passed,
    identifier: value('Identifier'),
    teamIdentifier: value('TeamIdentifier'),
    authority: detailText
      .split(/\r?\n/u)
      .filter((line) => line.startsWith('Authority='))
      .map((line) => line.slice('Authority='.length)),
    flags,
    hardenedRuntime: /\bruntime\b/u.test(flags ?? ''),
    adHoc: /\badhoc\b/u.test(flags ?? ''),
    strictError: strict.passed ? null : strict.stderr.trim() || strict.error,
  };
}

function sha256Command(file, args, options = {}) {
  return new Promise((resolveCommand, rejectCommand) => {
    const hash = createHash('sha256');
    let stderr = '';
    const child = spawn(file, args, {
      ...options,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.on('data', (chunk) => hash.update(chunk));
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString('utf8');
    });
    child.once('error', rejectCommand);
    child.once('close', (code) => {
      if (code !== 0) {
        rejectCommand(new VerificationError(`${basename(file)} 失败：${stderr.trim()}`));
        return;
      }
      resolveCommand(hash.digest('hex'));
    });
  });
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

async function collectPatchSeriesEvidence() {
  const seriesPath = join(BROWSER_ROOT, 'patches', 'series');
  const series = await fileEvidence(seriesPath);
  const entries = (await readFile(seriesPath, 'utf8'))
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
  const patches = [];
  const manifestHash = createHash('sha256');
  for (const name of entries) {
    assert(basename(name) === name, `patch series 含非单文件路径：${name}`);
    const evidence = await fileEvidence(join(BROWSER_ROOT, 'patches', name));
    patches.push({name, size: evidence.size, sha256: evidence.sha256});
    manifestHash.update(name);
    manifestHash.update('\0');
    manifestHash.update(evidence.sha256);
    manifestHash.update('\0');
  }
  return {
    ...series,
    patchCount: patches.length,
    manifestSha256: manifestHash.digest('hex'),
    patches,
  };
}

async function optionalPlistValue(plistPath, key) {
  if (process.platform !== 'darwin') {
    return null;
  }
  return (
    await execFileText('/usr/bin/plutil', [
      '-extract',
      key,
      'raw',
      '-o',
      '-',
      plistPath,
    ])
  ).trim();
}

async function collectUntrackedEvidence(checkoutPath) {
  const output = await execFileText('/usr/bin/git', [
    '-C',
    checkoutPath,
    'ls-files',
    '--others',
    '--exclude-standard',
    '-z',
  ]);
  const paths = output.split('\0').filter(Boolean).sort();
  const hash = createHash('sha256');
  for (const relativePath of paths) {
    const path = join(checkoutPath, relativePath);
    const metadata = await lstat(path).catch(() => null);
    hash.update(relativePath);
    hash.update('\0');
    if (metadata?.isFile()) {
      hash.update(await sha256File(path));
    } else if (metadata?.isSymbolicLink()) {
      hash.update(await readlink(path));
    } else {
      hash.update('missing-or-unsupported');
    }
    hash.update('\0');
  }
  return {count: paths.length, manifestSha256: hash.digest('hex')};
}

async function collectBrowserEvidence(chromiumExecutable) {
  const executable = await fileEvidence(chromiumExecutable);
  const appPath = resolve(dirname(chromiumExecutable), '..', '..');
  const isMacApp =
    process.platform === 'darwin' &&
    basename(appPath).endsWith('.app') &&
    basename(dirname(chromiumExecutable)) === 'MacOS';
  assert(isMacApp, '正式 MinerGuard 验证要求 macOS Chromium.app 产物');
  const framework = await fileEvidence(
    join(
      appPath,
      'Contents',
      'Frameworks',
      'Chromium Framework.framework',
      'Versions',
      'Current',
      'Chromium Framework',
    ),
  );
  const outputDir = dirname(appPath);
  const checkoutPath = await realpath(join(resolveDefaultChromiumRoot(), 'src'));
  const gitText = (args) =>
    execFileText('/usr/bin/git', ['-C', checkoutPath, ...args]);
  const diffHash = () =>
    sha256Command(
      '/usr/bin/git',
      ['diff', '--binary', '--no-ext-diff', 'HEAD', '--'],
      {cwd: checkoutPath},
    );
  const head = (await gitText(['rev-parse', 'HEAD'])).trim();
  const statusText = await gitText([
    'status',
    '--porcelain=v1',
    '--untracked-files=all',
  ]);
  const diffSha256 = await diffHash();
  const untracked = await collectUntrackedEvidence(checkoutPath);
  const [headAfter, statusAfter, diffAfter, untrackedAfter] = await Promise.all([
    gitText(['rev-parse', 'HEAD']).then((value) => value.trim()),
    gitText(['status', '--porcelain=v1', '--untracked-files=all']),
    diffHash(),
    collectUntrackedEvidence(checkoutPath),
  ]);
  assert(
    head === headAfter &&
      statusText === statusAfter &&
      diffSha256 === diffAfter &&
      canonical(untracked) === canonical(untrackedAfter),
    '外部 Chromium checkout 在身份采集期间发生变化，请稳定后重试',
  );
  const infoPlistPath = join(appPath, 'Contents', 'Info.plist');
  const chromiumVersion = (
    await execFileText(chromiumExecutable, ['--version'])
  ).trim();
  const bundleIdentifier = await optionalPlistValue(
    infoPlistPath,
    'CFBundleIdentifier',
  );
  const bundleShortVersion = await optionalPlistValue(
    infoPlistPath,
    'CFBundleShortVersionString',
  );
  const bundleVersion = await optionalPlistValue(
    infoPlistPath,
    'CFBundleVersion',
  );
  assert(
    Boolean(chromiumVersion && bundleIdentifier && bundleShortVersion && bundleVersion),
    'Chromium.app 或可执行文件版本身份不完整',
  );
  return {
    app: {
      path: appPath,
      bundleIdentifier,
      bundleShortVersion,
      bundleVersion,
      chromiumVersion,
    },
    executable,
    framework,
    gnArgs: await fileEvidence(join(outputDir, 'args.gn')),
    patchSeries: await collectPatchSeriesEvidence(),
    verifier: await fileEvidence(fileURLToPath(import.meta.url)),
    checkout: {
      path: checkoutPath,
      head,
      dirty: statusText.length > 0,
      statusEntryCount: statusText.split(/\r?\n/u).filter(Boolean).length,
      statusSha256: sha256Text(statusText),
      diffSha256,
      untracked,
    },
    codeSignature: await collectCodeSignatureEvidence(appPath),
    buildTarget: basename(outputDir),
    formalRelease: basename(outputDir) === 'AegisRelease',
  };
}

async function writeJson(path, value) {
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

const WORKER_SOURCE = String.raw`
let running = false;
let hash = 2166136261 >>> 0;

function computeChunk() {
  const end = performance.now() + 80;
  while (performance.now() < end) {
    for (let index = 0; index < 20000; index += 1) {
      hash ^= (index + hash) & 255;
      hash = Math.imul(hash, 16777619) >>> 0;
    }
  }
  if (running) {
    setTimeout(computeChunk, 0);
  }
}

self.onmessage = (event) => {
  if (event.data === 'start' && !running) {
    running = true;
    self.postMessage({kind: 'ready'});
    computeChunk();
  } else if (event.data === 'stop') {
    running = false;
    self.postMessage({kind: 'stopped', hash});
  }
};
`;

const FIXTURE_CLIENT_SOURCE = String.raw`
const WASM_BYTES = new Uint8Array([
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127,
  3, 2, 1, 0, 7, 7, 1, 3, 114, 117, 110, 0, 0,
  10, 6, 1, 4, 0, 65, 42, 11,
]);

function withTimeout(promise, label, milliseconds = 12000) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(
        () => reject(new Error(label + ' timeout')), milliseconds)),
  ]);
}

async function instantiateWasm() {
  const {instance} = await WebAssembly.instantiate(WASM_BYTES);
  return instance.exports.run();
}

function connectEcho(path) {
  return withTimeout(new Promise((resolve, reject) => {
    const socket = new WebSocket(
        'ws://' + location.hostname + ':' + location.port + path);
    const payload = 'aegis-loopback-echo-v1';
    socket.onerror = () => reject(new Error('websocket error'));
    socket.onopen = () => socket.send(payload);
    socket.onmessage = (event) => {
      const echoed = String(event.data);
      socket.close(1000, 'fixture complete');
      resolve({echoed, payload, unchanged: echoed === payload});
    };
  }), 'websocket echo');
}

function startWorker() {
  return withTimeout(new Promise((resolve, reject) => {
    const worker = new Worker('/worker.js');
    const state = {worker, ready: false, stopped: false, hash: null};
    worker.onerror = () => reject(new Error('worker error'));
    worker.onmessage = (event) => {
      if (event.data?.kind === 'ready') {
        state.ready = true;
        resolve(state);
      } else if (event.data?.kind === 'stopped') {
        state.stopped = true;
        state.hash = event.data.hash;
        state.resolveStopped?.(state);
      }
    };
    worker.postMessage('start');
  }), 'worker ready');
}

function stopWorker(state) {
  return withTimeout(new Promise((resolve) => {
    state.resolveStopped = (next) => {
      next.worker.terminate();
      resolve(next);
    };
    state.worker.postMessage('stop');
  }), 'worker stop');
}

async function burnMainThread(milliseconds) {
  const deadline = performance.now() + milliseconds;
  let hash = 2166136261 >>> 0;
  while (performance.now() < deadline) {
    const chunkEnd = Math.min(deadline, performance.now() + 65);
    while (performance.now() < chunkEnd) {
      for (let index = 0; index < 16000; index += 1) {
        hash ^= (index + hash) & 255;
        hash = Math.imul(hash, 16777619) >>> 0;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  return hash;
}

async function runFixture() {
  const mode = location.pathname.slice(1);
  const result = {
    done: false,
    mode,
    mainCpuHash: null,
    wasmResult: null,
    workerReady: false,
    workerStopped: false,
    workerHash: null,
    websocket: null,
  };
  try {
    if (mode === 'chat') {
      result.websocket = await connectEcho('/chat');
    } else if (mode === 'cpu-only') {
      result.mainCpuHash = await burnMainThread(${CPU_ONLY_WORKLOAD_MS});
    } else if (mode === 'positive' || mode === 'worker-wasm') {
      result.wasmResult = await instantiateWasm();
      const worker = await startWorker();
      result.workerReady = worker.ready;
      const echoPromise = mode === 'positive' ? connectEcho('/stratum') : null;
      result.mainCpuHash = await burnMainThread(${COMPUTE_WORKLOAD_MS});
      const stopped = await stopWorker(worker);
      result.workerStopped = stopped.stopped;
      result.workerHash = stopped.hash;
      result.websocket = echoPromise ? await echoPromise : null;
    } else {
      throw new Error('unknown fixture mode');
    }
    result.done = true;
  } catch (error) {
    result.error = error instanceof Error ? error.message : String(error);
    result.done = true;
  }
  window.__aegisResult = result;
  document.querySelector('#result').textContent = JSON.stringify(result);
}

void runFixture();
`;

function fixtureHtml(mode) {
  return `<!doctype html>
<meta charset="utf-8">
<title>Aegis MinerGuard ${mode} fixture</title>
<h1>Bounded loopback MinerGuard fixture</h1>
<pre id="result">running</pre>
<script src="/fixture.js"></script>`;
}

function websocketAccept(key) {
  return createHash('sha1')
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest('base64');
}

function websocketFrame(payload) {
  const bytes = Buffer.from(payload);
  assert(bytes.length <= 125, 'fixture WebSocket payload 过长');
  return Buffer.concat([Buffer.from([0x81, bytes.length]), bytes]);
}

function decodeClientFrame(buffer) {
  if (buffer.length < 2) {
    return null;
  }
  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) !== 0;
  let length = buffer[1] & 0x7f;
  assert(masked, '浏览器 WebSocket 帧必须被掩码');
  assert(length < 126, 'fixture 只接受 125 字节以内的单帧');
  const headerLength = 6;
  if (buffer.length < headerLength + length) {
    return null;
  }
  const mask = buffer.subarray(2, 6);
  const payload = Buffer.alloc(length);
  for (let index = 0; index < length; index += 1) {
    payload[index] = buffer[headerLength + index] ^ mask[index % 4];
  }
  return {
    consumed: headerLength + length,
    opcode,
    payload: payload.toString('utf8'),
  };
}

class MinerFixtureServer {
  constructor() {
    this.connections = new Set();
    this.httpRequests = [];
    this.websocketExchanges = [];
    this.server = createHttpServer((request, response) =>
      this.handleHttp(request, response),
    );
    this.server.on('upgrade', (request, socket, head) =>
      this.handleUpgrade(request, socket, head),
    );
    this.port = null;
  }

  async start() {
    await new Promise((resolveListen, rejectListen) => {
      this.server.once('error', rejectListen);
      this.server.listen(0, '127.0.0.1', resolveListen);
    });
    const address = this.server.address();
    assert(address && typeof address === 'object', 'fixture 地址无效');
    assert(address.address === '127.0.0.1', 'fixture 未绑定到 127.0.0.1');
    this.port = address.port;
  }

  loopbackUrl(pathname = '/') {
    assert(this.port, 'fixture 尚未启动');
    return `http://127.0.0.1:${this.port}${pathname}`;
  }

  url(host, pathname) {
    assert(this.port, 'fixture 尚未启动');
    return `http://${host}:${this.port}${pathname}`;
  }

  handleHttp(request, response) {
    const url = new URL(request.url || '/', this.loopbackUrl());
    this.httpRequests.push({
      host: String(request.headers.host || '').split(':')[0],
      method: request.method,
      path: url.pathname,
    });
    const headers = {
      'cache-control': 'no-store',
      'content-security-policy':
      "default-src 'self'; connect-src ws://*.localhost:* ws://127.0.0.1:*; worker-src 'self'; script-src 'self' 'wasm-unsafe-eval'",
      'x-content-type-options': 'nosniff',
    };
    if (url.pathname === '/health') {
      response.writeHead(200, {...headers, 'content-type': 'application/json'});
      response.end(JSON.stringify({ok: true, loopbackOnly: true}));
      return;
    }
    if (url.pathname === '/fixture.js') {
      response.writeHead(200, {
        ...headers,
        'content-type': 'text/javascript; charset=utf-8',
      });
      response.end(FIXTURE_CLIENT_SOURCE);
      return;
    }
    if (url.pathname === '/worker.js') {
      response.writeHead(200, {
        ...headers,
        'content-type': 'text/javascript; charset=utf-8',
      });
      response.end(WORKER_SOURCE);
      return;
    }
    if (['/positive', '/cpu-only', '/worker-wasm', '/chat'].includes(url.pathname)) {
      response.writeHead(200, {
        ...headers,
        'content-type': 'text/html; charset=utf-8',
      });
      response.end(fixtureHtml(url.pathname.slice(1)));
      return;
    }
    response.writeHead(404, {...headers, 'content-type': 'text/plain'});
    response.end('not found');
  }

  handleUpgrade(request, socket, head) {
    const remoteAddress = socket.remoteAddress;
    const path = new URL(request.url || '/', this.loopbackUrl()).pathname;
    if (
      !['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remoteAddress) ||
      !['/stratum', '/chat'].includes(path) ||
      request.headers.upgrade?.toLowerCase() !== 'websocket' ||
      typeof request.headers['sec-websocket-key'] !== 'string'
    ) {
      socket.destroy();
      return;
    }
    this.connections.add(socket);
    socket.once('close', () => this.connections.delete(socket));
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Accept: ${websocketAccept(
          request.headers['sec-websocket-key'],
        )}\r\n\r\n`,
    );
    let pending = Buffer.from(head);
    const consume = (chunk) => {
      pending = Buffer.concat([pending, chunk]);
      while (pending.length > 0) {
        const frame = decodeClientFrame(pending);
        if (!frame) {
          return;
        }
        pending = pending.subarray(frame.consumed);
        if (frame.opcode === 0x8) {
          socket.end(Buffer.from([0x88, 0x00]));
          return;
        }
        if (frame.opcode !== 0x1) {
          socket.destroy();
          return;
        }
        const exchange = {
          path,
          payloadSha256: sha256Text(frame.payload),
          size: Buffer.byteLength(frame.payload),
          echoed: true,
        };
        this.websocketExchanges.push(exchange);
        socket.write(websocketFrame(frame.payload));
      }
    };
    socket.on('data', consume);
    if (pending.length > 0) {
      consume(Buffer.alloc(0));
    }
  }

  async close() {
    for (const connection of this.connections) {
      connection.destroy();
    }
    await new Promise((resolveClose) => this.server.close(resolveClose));
  }

  evidence() {
    return {
      bind: '127.0.0.1',
      port: this.port,
      httpRequests: [...this.httpRequests],
      websocketExchanges: [...this.websocketExchanges],
    };
  }
}

async function fetchJson(url, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const response = await fetch(url, {signal: AbortSignal.timeout(timeoutMs)});
  assert(response.ok, `${url} 返回 HTTP ${response.status}`);
  return response.json();
}

class DevToolsEndpoint {
  constructor(port, timeoutMs) {
    this.origin = `http://127.0.0.1:${port}`;
    this.timeoutMs = timeoutMs;
  }

  version() {
    return fetchJson(`${this.origin}/json/version`, this.timeoutMs);
  }
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
    assert(parsed.hostname === '127.0.0.1', 'CDP WebSocket 不是 loopback');
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
      this.rejectPending('CDP 返回了非 JSON 消息');
      return;
    }
    if (!Number.isSafeInteger(message.id)) {
      return;
    }
    const pending = this.pending.get(message.id);
    if (!pending) {
      return;
    }
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
  }

  rejectPending(message) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new VerificationError(message));
    }
    this.pending.clear();
  }

  command(method, params = {}, sessionId = null) {
    assert(this.socket.readyState === WebSocket.OPEN, 'CDP WebSocket 未打开');
    const id = this.nextId++;
    return new Promise((resolveCommand, rejectCommand) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectCommand(new VerificationError(`CDP ${method} 超时`));
      }, this.timeoutMs);
      this.pending.set(id, {
        method,
        reject: rejectCommand,
        resolve: resolveCommand,
        timer,
      });
      this.socket.send(
        JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}),
      );
    });
  }

  async close() {
    if (this.socket.readyState >= WebSocket.CLOSING) {
      return;
    }
    this.socket.close(1000, 'miner verification complete');
    await delay(50);
  }
}

class CdpSession {
  constructor(browserClient, sessionId) {
    assert(sessionId, 'CDP target session id 为空');
    this.browserClient = browserClient;
    this.sessionId = sessionId;
  }

  command(method, params = {}) {
    return this.browserClient.command(method, params, this.sessionId);
  }

  async close() {
    if (!this.sessionId) {
      return;
    }
    const sessionId = this.sessionId;
    this.sessionId = null;
    await this.browserClient.command('Target.detachFromTarget', {sessionId});
  }
}

async function waitForDevToolsPort(profileDir, browserProcess, timeoutMs) {
  const path = join(profileDir, 'DevToolsActivePort');
  const deadline = performance.now() + timeoutMs;
  do {
    if (browserProcess.exitCode !== null || browserProcess.signalCode !== null) {
      fail(
        `Chromium 在 DevTools 启动前退出：${
          browserProcess.exitCode ?? browserProcess.signalCode
        }`,
      );
    }
    const text = await readFile(path, 'utf8').catch(() => '');
    const port = Number(text.split(/\r?\n/u)[0]?.trim());
    if (Number.isSafeInteger(port) && port > 0 && port <= 65535) {
      return port;
    }
    await delay(POLL_INTERVAL_MS);
  } while (performance.now() < deadline);
  fail('等待 DevToolsActivePort 超时');
}

async function evaluateValue(client, expression) {
  const result = await client.command('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true,
  });
  if (result.exceptionDetails) {
    fail(
      `页面脚本异常：${
        result.exceptionDetails.exception?.description ||
        result.exceptionDetails.text ||
        'unknown'
      }`,
    );
  }
  return result.result?.value;
}

async function waitForFixtureResult(client, timeoutMs) {
  const deadline = performance.now() + timeoutMs;
  do {
    const result = await evaluateValue(
      client,
      'window.__aegisResult?.done ? window.__aegisResult : null',
    );
    if (result) {
      return result;
    }
    await delay(POLL_INTERVAL_MS);
  } while (performance.now() < deadline);
  fail('等待 fixture 结果超时');
}

async function readProcessTable() {
  const output = await execFileText('/bin/ps', [
    '-axo',
    'pid=,ppid=,pgid=,state=,lstart=,command=',
  ]);
  const table = new Map();
  for (const line of output.split(/\r?\n/u)) {
    const match = line.match(
      /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+\s+\S+\s+\d+\s+\d+:\d+:\d+\s+\d+)\s+(.*)$/u,
    );
    if (!match) {
      continue;
    }
    const pid = Number(match[1]);
    table.set(pid, {
      pid,
      ppid: Number(match[2]),
      pgid: Number(match[3]),
      state: match[4],
      startedAt: match[5],
      command: match[6],
    });
  }
  return table;
}

class OwnedProcessTree {
  constructor(rootPid) {
    assert(Number.isSafeInteger(rootPid) && rootPid > 0, '浏览器主 PID 无效');
    this.rootPid = rootPid;
    this.rootPgid = null;
    this.known = new Map();
    this.monitorErrors = [];
    this.monitoring = false;
    this.monitorPromise = null;
    this.samplePromise = null;
    this.samples = 0;
    this.signals = [];
  }

  identityMatches(record, current) {
    return Boolean(record && current && record.startedAt === current.startedAt);
  }

  async sample() {
    if (this.samplePromise) {
      return this.samplePromise;
    }
    this.samplePromise = this.sampleUnlocked();
    try {
      return await this.samplePromise;
    } finally {
      this.samplePromise = null;
    }
  }

  async sampleUnlocked() {
    const table = await readProcessTable();
    this.samples += 1;
    if (!this.known.has(this.rootPid)) {
      const root = table.get(this.rootPid);
      if (root) {
        this.known.set(root.pid, root);
        this.rootPgid = root.pgid;
      }
    }
    let changed = true;
    while (changed) {
      changed = false;
      const activeParents = new Set(
        [...this.known.values()]
          .filter((record) => this.identityMatches(record, table.get(record.pid)))
          .map((record) => record.pid),
      );
      for (const current of table.values()) {
        const inOwnedProcessGroup =
          this.rootPgid !== null && current.pgid === this.rootPgid;
        if (
          this.known.has(current.pid) ||
          (!activeParents.has(current.ppid) && !inOwnedProcessGroup)
        ) {
          continue;
        }
        this.known.set(current.pid, current);
        changed = true;
      }
    }
    return table;
  }

  aliveFrom(table) {
    return [...this.known.values()].filter((record) =>
      this.identityMatches(record, table.get(record.pid)),
    );
  }

  depth(record) {
    let depth = 0;
    let current = record;
    const visited = new Set();
    while (this.known.has(current.ppid) && !visited.has(current.ppid)) {
      visited.add(current.ppid);
      current = this.known.get(current.ppid);
      depth += 1;
    }
    return depth;
  }

  async alive() {
    return this.aliveFrom(await this.sample());
  }

  startMonitoring(intervalMs = 100) {
    if (this.monitoring) {
      return;
    }
    this.monitoring = true;
    this.monitorPromise = (async () => {
      while (this.monitoring) {
        try {
          await this.sample();
        } catch (error) {
          this.monitorErrors.push(errorMessage(error));
        }
        await delay(intervalMs);
      }
    })();
  }

  async stopMonitoring() {
    this.monitoring = false;
    await this.monitorPromise;
    this.monitorPromise = null;
  }

  async signalAlive(signal) {
    const table = await this.sample();
    const alive = this.aliveFrom(table).sort(
      (left, right) => this.depth(right) - this.depth(left),
    );
    const sent = [];
    const errors = [];
    for (const record of alive) {
      try {
        process.kill(record.pid, signal);
        sent.push(record.pid);
      } catch (error) {
        if (error?.code !== 'ESRCH') {
          errors.push({pid: record.pid, error: errorMessage(error)});
        }
      }
    }
    this.signals.push({signal, sent, errors});
    if (errors.length > 0) {
      throw new ProcessLeakError(
        `无法向已跟踪浏览器进程发送 ${signal}`,
        this.evidence(alive),
      );
    }
    return alive;
  }

  async waitUntilEmpty(timeoutMs) {
    const deadline = performance.now() + timeoutMs;
    do {
      const alive = await this.alive();
      if (alive.length === 0) {
        return [];
      }
      if (performance.now() >= deadline) {
        return alive;
      }
      await delay(POLL_INTERVAL_MS);
    } while (true);
  }

  evidence(survivors = []) {
    const compact = (record) => ({
      pid: record.pid,
      ppid: record.ppid,
      pgid: record.pgid,
      state: record.state,
      startedAt: record.startedAt,
      command: record.command,
    });
    return {
      rootPid: this.rootPid,
      rootPgid: this.rootPgid,
      sampled: this.samples,
      discovered: [...this.known.values()].map(compact),
      signals: this.signals,
      monitorErrors: this.monitorErrors,
      survivors: survivors.map(compact),
      stableObservationMs: PROCESS_STABILITY_OBSERVATION_MS,
    };
  }
}

function commandHasArgument(command, argument) {
  return (
    command === argument ||
    command.startsWith(`${argument} `) ||
    command.endsWith(` ${argument}`) ||
    command.includes(` ${argument} `)
  );
}

async function scanOwnedCommandProcesses(chromiumExecutable, profileDir) {
  const profileArgument = `--user-data-dir=${profileDir}`;
  const temporaryRoot = dirname(profileDir);
  const table = await readProcessTable();
  const survivors = [...table.values()].filter(
    (record) =>
      commandHasArgument(record.command, profileArgument) ||
      record.command.includes(profileDir) ||
      record.command.includes(temporaryRoot),
  );
  return {
    performed: true,
    chromiumExecutable,
    profileDir,
    profileArgument,
    temporaryRoot,
    survivors,
  };
}

async function waitForChildExitState(child, timeoutMs = 1_000) {
  const deadline = performance.now() + timeoutMs;
  while (
    child.exitCode === null &&
    child.signalCode === null &&
    performance.now() < deadline
  ) {
    await delay(POLL_INTERVAL_MS);
  }
  return {exitCode: child.exitCode ?? null, signalCode: child.signalCode ?? null};
}

async function terminateOwnedProcess(child, endpoint, tracker, ownership) {
  if (!child || !tracker) {
    return null;
  }
  try {
    await tracker.sample();
    const browserClose = {
      attempted: false,
      requested: false,
      acknowledged: false,
      error: null,
    };
    try {
      const version = await endpoint?.version();
      if (version?.webSocketDebuggerUrl) {
        browserClose.attempted = true;
        const client = await CdpClient.connect(version.webSocketDebuggerUrl, 3_000);
        try {
          browserClose.requested = true;
          await client.command('Browser.close');
          browserClose.acknowledged = true;
        } finally {
          await client.close().catch(() => {});
        }
      }
    } catch (error) {
      browserClose.error = errorMessage(error);
    }
    let survivors = await tracker.waitUntilEmpty(
      browserClose.requested ? 8_000 : 0,
    );
    if (survivors.length > 0) {
      await tracker.signalAlive('SIGTERM');
      survivors = await tracker.waitUntilEmpty(3_000);
    }
    if (survivors.length > 0) {
      await tracker.signalAlive('SIGKILL');
      survivors = await tracker.waitUntilEmpty(2_000);
    }
    if (survivors.length === 0) {
      await delay(PROCESS_STABILITY_OBSERVATION_MS);
      survivors = await tracker.alive();
    }
    const childExit = await waitForChildExitState(child);
    const ownershipScan = await scanOwnedCommandProcesses(
      ownership.chromiumExecutable,
      ownership.profileDir,
    );
    if (ownershipScan.survivors.length > 0) {
      survivors = ownershipScan.survivors;
    }
    await tracker.stopMonitoring();
    const evidence = tracker.evidence(survivors);
    const rootSignals = tracker.signals.filter((entry) =>
      entry.sent.includes(tracker.rootPid),
    );
    const lastRootSignal = rootSignals.at(-1)?.signal ?? null;
    evidence.browserClose = browserClose;
    evidence.exitCode = childExit.exitCode;
    evidence.signalCode = childExit.signalCode;
    evidence.terminationMethod =
      lastRootSignal === 'SIGKILL'
        ? 'controlled-sigkill'
        : lastRootSignal === 'SIGTERM'
          ? 'controlled-sigterm'
          : browserClose.requested
            ? 'browser-close'
            : 'uncontrolled-exit';
    evidence.ownershipScan = {
      ...ownershipScan,
      survivors: ownershipScan.survivors.map((record) => ({
        pid: record.pid,
        ppid: record.ppid,
        pgid: record.pgid,
        state: record.state,
        startedAt: record.startedAt,
        command: record.command,
      })),
    };
    if (survivors.length > 0) {
      throw new ProcessLeakError(
        `浏览器主 PID 或启动后代未退出：${survivors
          .map((record) => record.pid)
          .join(', ')}`,
        evidence,
      );
    }
    if (tracker.monitorErrors.length > 0) {
      throw new ProcessLeakError(
        '进程树持续采样失败，无法证明所有启动后代均已退出',
        evidence,
      );
    }
    return evidence;
  } finally {
    await tracker.stopMonitoring();
  }
}

function findFatalSignals(logText) {
  const pattern =
    /\bFATAL\b|CHECK failed|DCHECK failed|Received signal|Aw, Snap|GPU process (?:crashed|exited unexpectedly)|Render(?:er)? process (?:gone|crashed|exited|terminated)(?: unexpectedly)?|Child process .*exited unexpectedly/iu;
  return logText.split(/\r?\n/u).filter((line) => pattern.test(line));
}

async function listDumpFiles(root) {
  const files = [];
  async function visit(directory) {
    const entries = await readdir(directory, {withFileTypes: true});
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        await visit(path);
      } else if (entry.isFile() && entry.name.endsWith('.dmp')) {
        files.push(path);
      }
    }
  }
  await visit(root);
  return files.sort();
}

async function listCrashArtifacts(root, filenameFilter) {
  const artifacts = [];
  let rootMetadata;
  try {
    rootMetadata = await stat(root);
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return {
        path: root,
        exists: false,
        readable: true,
        absenceVerified: true,
        error: null,
        artifacts,
      };
    }
    return {
      path: root,
      exists: null,
      readable: false,
      absenceVerified: false,
      error: serializeError(error),
      artifacts,
    };
  }
  if (!rootMetadata.isDirectory()) {
    return {
      path: root,
      exists: true,
      readable: false,
      absenceVerified: false,
      error: {name: 'NotDirectory', message: 'Crash 根路径不是目录'},
      artifacts,
    };
  }
  async function visit(directory) {
    const entries = await readdir(directory, {withFileTypes: true});
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        await visit(path);
      } else if (entry.isFile() && filenameFilter(entry.name)) {
        const metadata = await stat(path);
        artifacts.push({
          path,
          size: metadata.size,
          mtimeMs: Math.trunc(metadata.mtimeMs),
        });
      }
    }
  }
  try {
    await visit(root);
    return {
      path: root,
      exists: true,
      readable: true,
      absenceVerified: false,
      error: null,
      artifacts,
    };
  } catch (error) {
    return {
      path: root,
      exists: true,
      readable: false,
      absenceVerified: false,
      error: serializeError(error),
      artifacts,
    };
  }
}

async function snapshotMacCrashArtifacts() {
  if (process.platform !== 'darwin') {
    return {supported: false, roots: [], artifacts: []};
  }
  const roots = [
    await listCrashArtifacts(
      join(homedir(), 'Library', 'Application Support', 'Chromium', 'Crashpad'),
      (name) => name.endsWith('.dmp'),
    ),
  ];
  for (const root of [
    join(homedir(), 'Library', 'Logs', 'DiagnosticReports'),
    join('/Library', 'Logs', 'DiagnosticReports'),
  ]) {
    roots.push(
      await listCrashArtifacts(
        root,
        (name) =>
          /^Chromium(?: Helper)?/u.test(name) &&
          /\.(?:crash|ips)$/u.test(name),
      ),
    );
  }
  const artifacts = roots.flatMap((root) => root.artifacts);
  artifacts.sort((left, right) => left.path.localeCompare(right.path));
  return {
    supported: roots.every((root) => root.readable),
    roots: roots.map((root) => ({
      path: root.path,
      exists: root.exists,
      readable: root.readable,
      absenceVerified: root.absenceVerified,
      error: root.error,
    })),
    artifacts,
  };
}

function diffCrashSnapshots(before, after) {
  const beforeByPath = new Map(
    before.artifacts.map((artifact) => [artifact.path, artifact]),
  );
  return after.artifacts.filter((artifact) => {
    const prior = beforeByPath.get(artifact.path);
    return (
      !prior ||
      prior.size !== artifact.size ||
      prior.mtimeMs !== artifact.mtimeMs
    );
  });
}

function parseMinerGuardAlerts(logText) {
  const alerts = [];
  const malformed = [];
  for (const line of logText.split(/\r?\n/u)) {
    if (!line.includes(MINER_ALERT_PREFIX)) {
      continue;
    }
    const match = line.match(MINER_ALERT_PATTERN);
    if (!match) {
      malformed.push({sha256: sha256Text(line)});
      continue;
    }
    alerts.push({
      verdict: 'likely_mining',
      scoreBucket: 'high',
    });
  }
  return {alerts, malformed};
}

async function readMinerGuardPreference(profileDir) {
  const path = join(profileDir, 'Default', 'Preferences');
  const text = await readFile(path, 'utf8').catch((error) => {
    if (error?.code === 'ENOENT') {
      return null;
    }
    throw error;
  });
  if (text === null) {
    return {path, exists: false, minerGuardEnabled: null, sha256: null};
  }
  let preferences;
  try {
    preferences = JSON.parse(text);
  } catch (error) {
    fail(`临时 Profile Preferences 不是有效 JSON：${error.message}`);
  }
  const value = preferences?.aegis?.miner_guard_enabled;
  return {
    path,
    exists: true,
    minerGuardEnabled: typeof value === 'boolean' ? value : null,
    sha256: sha256Text(text),
  };
}

async function prepareModeProfile(mode, profileDir) {
  await mkdir(profileDir, {recursive: true, mode: 0o700});
  const defaultDir = join(profileDir, 'Default');
  await mkdir(defaultDir, {recursive: true, mode: 0o700});
  const path = join(defaultDir, 'Preferences');
  await writeFile(
    path,
    `${JSON.stringify({aegis: {miner_guard_enabled: mode.prefEnabled}})}\n`,
    {encoding: 'utf8', flag: 'wx', mode: 0o600},
  );
  return readMinerGuardPreference(profileDir);
}

async function waitForMinerAlert(logPath, timeoutMs) {
  const deadline = performance.now() + timeoutMs;
  do {
    const logText = await readFile(logPath, 'utf8').catch(() => '');
    const evidence = parseMinerGuardAlerts(logText);
    if (evidence.alerts.length > 0) {
      return;
    }
    await delay(POLL_INTERVAL_MS);
  } while (performance.now() < deadline);
}

function modeDefinitions() {
  return [
    {
      name: 'positive-combined',
      host: TEST_HOSTS.positive,
      pathname: '/positive',
      expectMinerEvent: true,
      prefEnabled: true,
      disabledFeatures: [],
    },
    {
      name: 'negative-cpu-only',
      host: TEST_HOSTS.cpu,
      pathname: '/cpu-only',
      expectMinerEvent: false,
      prefEnabled: true,
      disabledFeatures: [],
    },
    {
      name: 'negative-worker-wasm-load',
      host: TEST_HOSTS.compute,
      pathname: '/worker-wasm',
      expectMinerEvent: false,
      prefEnabled: true,
      disabledFeatures: [],
    },
    {
      name: 'negative-chat-websocket',
      host: TEST_HOSTS.chat,
      pathname: '/chat',
      expectMinerEvent: false,
      prefEnabled: true,
      disabledFeatures: [],
    },
    {
      name: 'control-pref-off',
      host: TEST_HOSTS.positive,
      pathname: '/positive',
      expectMinerEvent: false,
      prefEnabled: false,
      disabledFeatures: [],
    },
    {
      name: 'control-master-off',
      host: TEST_HOSTS.positive,
      pathname: '/positive',
      expectMinerEvent: false,
      prefEnabled: true,
      disabledFeatures: ['AegisEnabled'],
    },
  ];
}

function fixtureResultAssertions(mode, result) {
  const assertions = [
    {
      name: `${mode.name}: fixture 完成且无脚本错误`,
      passed: result?.done === true && !result?.error,
      details: result ?? null,
    },
  ];
  if (mode.pathname === '/positive' || mode.pathname === '/worker-wasm') {
    assertions.push(
      {
        name: `${mode.name}: Wasm 返回值保持 42`,
        passed: result?.wasmResult === 42,
        details: {wasmResult: result?.wasmResult ?? null},
      },
      {
        name: `${mode.name}: Dedicated Worker 启动、停止并返回有界结果`,
        passed:
          result?.workerReady === true &&
          result?.workerStopped === true &&
          Number.isSafeInteger(result?.workerHash),
        details: {
          workerReady: result?.workerReady ?? false,
          workerStopped: result?.workerStopped ?? false,
          workerHash: result?.workerHash ?? null,
        },
      },
    );
  }
  if (mode.pathname === '/positive' || mode.pathname === '/chat') {
    assertions.push({
      name: `${mode.name}: WebSocket echo 内容未被修改`,
      passed:
        result?.websocket?.unchanged === true &&
        result.websocket.echoed === result.websocket.payload,
      details: result?.websocket ?? null,
    });
  }
  if (mode.pathname !== '/chat') {
    assertions.push({
      name: `${mode.name}: CPU fixture 返回有界数值结果`,
      passed: Number.isSafeInteger(result?.mainCpuHash),
      details: {mainCpuHash: result?.mainCpuHash ?? null},
    });
  }
  return assertions;
}

async function runMode(
  mode,
  options,
  chromiumExecutable,
  fixture,
  profileDir,
  logPath,
) {
  const preferenceBefore = await prepareModeProfile(mode, profileDir);
  const logFd = openSync(logPath, 'w', 0o600);
  const chromiumArgs = [
    `--user-data-dir=${profileDir}`,
    '--profile-directory=Default',
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=0',
    '--enable-logging=stderr',
    '--log-level=0',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-default-apps',
    '--disable-domain-reliability',
    '--disable-sync',
    '--metrics-recording-only',
    '--no-pings',
    '--window-size=1280,900',
    '--host-resolver-rules=MAP *.localhost 127.0.0.1,MAP localhost 127.0.0.1,EXCLUDE 127.0.0.1',
    ...(process.platform === 'darwin' ? ['--use-mock-keychain'] : []),
    ...(options.headed ? [] : ['--headless=new']),
    ...(mode.disabledFeatures.length > 0
      ? [`--disable-features=${mode.disabledFeatures.join(',')}`]
      : []),
    'about:blank',
  ];
  const startedAt = new Date().toISOString();
  let browserProcess = null;
  let processTracker = null;
  let endpoint = null;
  let browserClient = null;
  let fixtureClient = null;
  let processTermination = null;
  let fixtureResult = null;
  let pageEvidence = null;
  let runError = null;

  const execute = async () => {
    browserProcess = spawn(chromiumExecutable, chromiumArgs, {
      detached: true,
      env: {...process.env},
      stdio: ['ignore', 'ignore', logFd],
    });
    browserProcess.once('error', (error) => {
      browserProcess.aegisSpawnError = error;
    });
    processTracker = new OwnedProcessTree(browserProcess.pid);
    await processTracker.sample();
    processTracker.startMonitoring();
    const port = await waitForDevToolsPort(
      profileDir,
      browserProcess,
      options.timeoutMs,
    );
    endpoint = new DevToolsEndpoint(port, options.timeoutMs);
    const version = await endpoint.version();
    assert(version.webSocketDebuggerUrl, '浏览器 CDP endpoint 缺少 WebSocket');
    browserClient = await CdpClient.connect(
      version.webSocketDebuggerUrl,
      options.timeoutMs,
    );
    const fixtureUrl = fixture.url(mode.host, mode.pathname);
    const created = await browserClient.command('Target.createTarget', {
      url: fixtureUrl,
    });
    assert(created.targetId, 'Target.createTarget 未返回 targetId');
    await browserClient.command('Target.activateTarget', {
      targetId: created.targetId,
    });
    const attached = await browserClient.command('Target.attachToTarget', {
      targetId: created.targetId,
      flatten: true,
    });
    fixtureClient = new CdpSession(browserClient, attached.sessionId);
    await fixtureClient.command('Runtime.enable');
    fixtureResult = await waitForFixtureResult(fixtureClient, options.timeoutMs);
    pageEvidence = await evaluateValue(
      fixtureClient,
      `({
        url: location.href,
        title: document.title,
        bodyConnected: document.body?.isConnected === true,
        resultText: document.querySelector('#result')?.textContent ?? ''
      })`,
    );
    if (mode.expectMinerEvent) {
      await waitForMinerAlert(logPath, 5_000);
    } else {
      await delay(1_000);
    }
  };

  let hardTimeout = null;
  try {
    await Promise.race([
      execute(),
      new Promise((_, reject) =>
        (hardTimeout = setTimeout(
          () => reject(new VerificationError(`${mode.name} 硬超时`)),
          options.timeoutMs,
        )),
      ),
    ]);
  } catch (error) {
    runError = serializeError(error);
  } finally {
    clearTimeout(hardTimeout);
    await fixtureClient?.close().catch(() => {});
    await browserClient?.close().catch(() => {});
    try {
      processTermination = await terminateOwnedProcess(
        browserProcess,
        endpoint,
        processTracker,
        {chromiumExecutable, profileDir},
      );
    } catch (error) {
      runError = serializeError(error);
    } finally {
      closeSync(logFd);
    }
  }

  const logBytes = await readFile(logPath);
  const logText = logBytes.toString('utf8');
  const fatalSignals = findFatalSignals(logText);
  const minerAlertEvidence = parseMinerGuardAlerts(logText);
  const preferenceAfter = await readMinerGuardPreference(profileDir).catch(
    (error) => ({error: serializeError(error)}),
  );
  const assertions = fixtureResultAssertions(mode, fixtureResult);
  assertions.push(
    {
      name: `${mode.name}: 页面保持在 loopback fixture 且 DOM 存活`,
      passed:
        pageEvidence?.url === fixture.url(mode.host, mode.pathname) &&
        pageEvidence?.bodyConnected === true,
      details: pageEvidence,
    },
    {
      name: `${mode.name}: MinerGuard 配置门符合预期`,
      passed:
        preferenceBefore.exists === true &&
        preferenceBefore.minerGuardEnabled === mode.prefEnabled &&
        preferenceAfter.exists === true &&
        preferenceAfter.minerGuardEnabled === mode.prefEnabled &&
        (mode.name === 'control-master-off') ===
          mode.disabledFeatures.includes('AegisEnabled'),
      details: {
        preferenceBefore,
        preferenceAfter,
        masterFeatureDisabled:
          mode.disabledFeatures.includes('AegisEnabled'),
      },
    },
    {
      name: `${mode.name}: MinerGuard stderr 告警格式完整`,
      passed: minerAlertEvidence.malformed.length === 0,
      details: minerAlertEvidence.malformed,
    },
    {
      name: `${mode.name}: MinerGuard observe-only 告警符合矩阵`,
      passed: mode.expectMinerEvent
        ? minerAlertEvidence.alerts.length === 1
        : minerAlertEvidence.alerts.length === 0,
      details: minerAlertEvidence.alerts,
    },
    {
      name: `${mode.name}: 浏览器无 FATAL/崩溃日志`,
      passed: fatalSignals.length === 0,
      details: fatalSignals,
    },
    {
      name: `${mode.name}: 浏览器进程树受控退出且无残留`,
      passed:
        processTermination?.browserClose?.requested === true &&
        processTermination?.survivors?.length === 0 &&
        processTermination?.ownershipScan?.survivors?.length === 0,
      details: processTermination,
    },
    {
      name: `${mode.name}: 场景执行无内部错误`,
      passed: runError === null,
      details: runError,
    },
  );
  return {
    name: mode.name,
    host: mode.host,
    pathname: mode.pathname,
    expectedMinerEvent: mode.expectMinerEvent,
    prefEnabled: mode.prefEnabled,
    disabledFeatures: mode.disabledFeatures,
    startedAt,
    finishedAt: new Date().toISOString(),
    error: runError,
    fixtureResult,
    pageEvidence,
    gate: {
      preferenceBefore,
      preferenceAfter,
      masterFeatureDisabled: mode.disabledFeatures.includes('AegisEnabled'),
    },
    minerAlerts: minerAlertEvidence,
    assertions,
    fatalSignals,
    processTermination,
    stderr: {
      name: basename(logPath),
      size: logBytes.length,
      sha256: sha256Text(logBytes),
    },
  };
}

async function runVerification(
  options,
  browserEvidenceBefore,
  sourceArtifactBindingBefore,
  crashBefore,
) {
  assert(typeof WebSocket === 'function', '当前 Node 不提供原生 WebSocket');
  const startedAt = new Date().toISOString();
  const tempRoot = await mkdtemp(join(tmpdir(), 'aegis-miner-runtime-'));
  const fixture = new MinerFixtureServer();
  const modes = [];
  let unexpectedError = null;
  try {
    await fixture.start();
    const health = await fetchJson(fixture.loopbackUrl('/health'));
    assert(
      health?.ok === true && health?.loopbackOnly === true,
      'MinerGuard fixture health 失败',
    );
    for (const mode of modeDefinitions()) {
      const modeResult = await runMode(
        mode,
        options,
        browserEvidenceBefore.executable.path,
        fixture,
        join(tempRoot, `profile-${mode.name}`),
        join(tempRoot, `${mode.name}.log`),
      );
      modes.push(modeResult);
    }
  } catch (error) {
    unexpectedError = serializeError(error);
  } finally {
    await fixture.close().catch(() => {});
  }

  let browserEvidenceAfter = null;
  let browserEvidenceError = null;
  try {
    browserEvidenceAfter = await collectBrowserEvidence(
      browserEvidenceBefore.executable.path,
    );
  } catch (error) {
    browserEvidenceError = serializeError(error);
  }
  let sourceArtifactBindingAfter = null;
  let sourceArtifactBindingError = null;
  if (sourceArtifactBindingBefore.available) {
    try {
      sourceArtifactBindingAfter = await verifySourceArtifactBinding(
        options,
        browserEvidenceBefore.executable.path,
      );
    } catch (error) {
      sourceArtifactBindingError = serializeError(error);
    }
  }
  await delay(CRASH_STABILITY_OBSERVATION_MS);
  const crashAfter = await snapshotMacCrashArtifacts();
  const crashDelta = diffCrashSnapshots(crashBefore, crashAfter);
  const profileDumps = await listDumpFiles(tempRoot);
  const fixtureEvidence = fixture.evidence();
  const assertions = modes.flatMap((mode) => mode.assertions);
  const browserIdentityUnchanged =
    browserEvidenceAfter !== null &&
    canonical(browserEvidenceBefore) === canonical(browserEvidenceAfter);
  assertions.push(
    {
      name: '浏览器产物、Chromium checkout、补丁和验证器运行前后完全一致',
      passed: browserIdentityUnchanged,
      details: browserEvidenceError,
    },
    {
      name: '临时 Profile 无 crash dump',
      passed: profileDumps.length === 0,
      details: profileDumps,
    },
    {
      name: 'macOS Crashpad/DiagnosticReports 状态可读且无新增转储',
      passed:
        crashBefore.supported === true &&
        crashAfter.supported === true &&
        crashDelta.length === 0,
      details: {roots: crashAfter.roots, newOrModified: crashDelta},
    },
    {
      name: '验证器未发生未处理错误',
      passed: unexpectedError === null,
      details: unexpectedError,
    },
    {
      name: 'fixture 仅绑定 loopback 且只观察有界 echo',
      passed:
        fixtureEvidence.bind === '127.0.0.1' &&
        fixtureEvidence.websocketExchanges.length === 4 &&
        fixtureEvidence.websocketExchanges.every(
          (entry) =>
            entry.echoed === true &&
            ['/stratum', '/chat'].includes(entry.path) &&
            entry.size <= 125,
        ),
      details: fixtureEvidence.websocketExchanges,
    },
  );
  const sourceArtifactBindingUnchanged =
    !sourceArtifactBindingBefore.available ||
    (sourceArtifactBindingAfter !== null &&
      canonical(sourceArtifactBindingBefore) ===
        canonical(sourceArtifactBindingAfter));
  assertions.push({
    name: '显式构建身份运行前后未漂移',
    passed: sourceArtifactBindingUnchanged,
    details: sourceArtifactBindingError,
  });
  const failedAssertions = assertions.filter((entry) => !entry.passed);
  const runtimePass =
    modes.length === modeDefinitions().length && failedAssertions.length === 0;
  const releaseGates = {
    runtimePass,
    sourceArtifactBindingVerified:
      sourceArtifactBindingBefore.available === true &&
      sourceArtifactBindingBefore.verified === true &&
      sourceArtifactBindingUnchanged,
    browserIdentityUnchanged,
    chromiumCheckoutClean: browserEvidenceBefore.checkout.dirty === false,
    strictCodeSignature:
      browserEvidenceBefore.codeSignature.strictDeepValid === true,
    independentBenignCorpusValidated: false,
    blockingModeValidated: false,
    formalSecurityReleaseApproval: false,
  };
  const releaseEligible = Object.values(releaseGates).every(Boolean);
  const report = {
    schemaVersion: 1,
    kind: 'aegis-miner-runtime',
    passed: runtimePass,
    qualification: releaseEligible ? 'pass' : runtimePass ? 'partial' : 'fail',
    runtime_pass: runtimePass,
    release_eligible: releaseEligible,
    observe_only: true,
    startedAt,
    finishedAt: new Date().toISOString(),
    browser: browserEvidenceBefore,
    browserEvidence: {
      before: browserEvidenceBefore,
      after: browserEvidenceAfter,
      unchanged: browserIdentityUnchanged,
      collectionError: browserEvidenceError,
    },
    sourceArtifactBinding: sourceArtifactBindingBefore.available
      ? {
          ...sourceArtifactBindingBefore,
          prePostUnchanged: sourceArtifactBindingUnchanged,
          after: sourceArtifactBindingAfter,
          collectionError: sourceArtifactBindingError,
        }
      : sourceArtifactBindingBefore,
    releaseGates,
    assertionSummary: {
      passed: assertions.filter((entry) => entry.passed).length,
      failed: failedAssertions.length,
      total: assertions.length,
    },
    assertions,
    modes,
    fixture: fixtureEvidence,
    crashEvidence: {
      supported: crashBefore.supported && crashAfter.supported,
      beforeCount: crashBefore.artifacts.length,
      afterCount: crashAfter.artifacts.length,
      newOrModified: crashDelta,
      observationMs: CRASH_STABILITY_OBSERVATION_MS,
    },
    environment: {
      platform: process.platform,
      architecture: process.arch,
      node: process.version,
      headed: options.headed,
      hosts: TEST_HOSTS,
      profileRoot: tempRoot,
      profileRetained: options.keepProfile || !runtimePass,
      perModeHardTimeoutMs: options.timeoutMs,
    },
    boundaries: [
      '仅验证高置信多信号组合的 observe-only 报告，不验证阻断。',
      '通过 browser target 创建并附着 loopback fixture，不枚举或附着受保护 WebUI。',
      '所有 HTTP/WebSocket fixture 均绑定 127.0.0.1，不连接真实矿池。',
      'synthetic matrix 是回归证据，不等同大规模独立良性语料的正式误报率。',
      'fixture 不含钱包、share、真实挖矿协议或可复用恶意载荷。',
    ],
  };
  if (runtimePass && !options.keepProfile) {
    const expectedPrefix = join(tmpdir(), 'aegis-miner-runtime-');
    assert(tempRoot.startsWith(expectedPrefix), '拒绝清理非预期临时目录');
    await rm(tempRoot, {recursive: true, force: true});
  }
  return report;
}

async function websocketEchoSelfTest(url) {
  const socket = new WebSocket(url);
  const payload = 'self-test-loopback-echo';
  return new Promise((resolveEcho, rejectEcho) => {
    const timer = setTimeout(() => {
      socket.close();
      rejectEcho(new VerificationError('self-test WebSocket 超时'));
    }, 3_000);
    socket.addEventListener(
      'open',
      () => socket.send(payload),
      {once: true},
    );
    socket.addEventListener(
      'message',
      (event) => {
        clearTimeout(timer);
        const echoed = String(event.data);
        socket.close(1000, 'self-test complete');
        resolveEcho({payload, echoed});
      },
      {once: true},
    );
    socket.addEventListener(
      'error',
      () => {
        clearTimeout(timer);
        rejectEcho(new VerificationError('self-test WebSocket 失败'));
      },
      {once: true},
    );
  });
}

async function runSelfTest() {
  const checks = [];
  const record = async (name, operation) => {
    try {
      const details = await operation();
      checks.push({name, passed: true, details: details ?? null});
    } catch (error) {
      checks.push({name, passed: false, details: serializeError(error)});
    }
  };

  await record('参数解析拒绝不完整构建身份与过短超时', async () => {
    let missingPairRejected = false;
    let shortTimeoutRejected = false;
    try {
      parseArgs(['--build-identity', '/tmp/manifest.json']);
    } catch {
      missingPairRejected = true;
    }
    try {
      parseArgs(['--timeout-ms', '14999']);
    } catch {
      shortTimeoutRejected = true;
    }
    assert(missingPairRejected, '未拒绝不完整构建身份参数');
    assert(shortTimeoutRejected, '未拒绝过短硬超时');
    const valid = parseArgs([
      '--timeout-ms',
      '15000',
      '--build-identity',
      '/tmp/manifest.json',
      '--build-identity-sha256',
      'a'.repeat(64),
    ]);
    assert(valid.timeoutMs === 15_000, '合法超时解析错误');
    return {missingPairRejected, shortTimeoutRejected};
  });

  await record('矩阵包含一个正例、三个负例和两个关闭控制', async () => {
    const modes = modeDefinitions();
    assert(modes.length === 6, '场景数量错误');
    assert(
      modes.filter((mode) => mode.expectMinerEvent).length === 1,
      '正例数量错误',
    );
    assert(
      modes.some((mode) => mode.name === 'control-pref-off') &&
        modes.some((mode) => mode.name === 'control-master-off'),
      '关闭控制不完整',
    );
    return modes.map((mode) => mode.name);
  });

  await record('结构化 stderr 告警只接受固定隐私格式', async () => {
    const parsed = parseMinerGuardAlerts(
      '[100:200:0827/044358.741419:INFO:chrome/browser/aegis/aegis_service.cc:747] [AegisMinerGuard] schema=1 mode=observe_only verdict=likely_mining score_bucket=high\n',
    );
    assert(parsed.alerts.length === 1, '未解析合法 MinerGuard 告警');
    assert(parsed.alerts[0].scoreBucket === 'high', 'MinerGuard 分数桶解析错误');
    assert(
      Object.keys(parsed.alerts[0]).sort().join(',') ===
        'scoreBucket,verdict',
      'MinerGuard 告警意外保留 site、URL 或其他字段',
    );
    const malformed = parseMinerGuardAlerts(
      '[100:200:INFO:fixture.js:1] [AegisMinerGuard] schema=1 mode=observe_only verdict=likely_mining score_bucket=high\n',
    );
    assert(
      malformed.alerts.length === 0 && malformed.malformed.length === 1,
      '含 site 的旧格式未被拒绝',
    );
    return parsed;
  });

  await record('browser target 的 flat CDP session 精确路由并分离', async () => {
    const commands = [];
    const browserClient = {
      command(method, params, sessionId = null) {
        commands.push({method, params, sessionId});
        return Promise.resolve({});
      },
    };
    const session = new CdpSession(browserClient, 'loopback-session');
    await session.command('Runtime.enable');
    await session.close();
    assert(
      commands[0].method === 'Runtime.enable' &&
        commands[0].sessionId === 'loopback-session',
      'fixture 命令未绑定 flat target session',
    );
    assert(
      commands[1].method === 'Target.detachFromTarget' &&
        commands[1].params.sessionId === 'loopback-session' &&
        commands[1].sessionId === null,
      'flat target session 未从 browser target 分离',
    );
    return commands;
  });

  await record('pref-off 在启动前写入 Default 并可回读', async () => {
    const root = await mkdtemp(join(tmpdir(), 'aegis-miner-pref-self-test-'));
    try {
      const mode = modeDefinitions().find(
        (entry) => entry.name === 'control-pref-off',
      );
      const before = await prepareModeProfile(mode, root);
      const after = await readMinerGuardPreference(root);
      assert(
        before.exists === true && before.minerGuardEnabled === false,
        '启动前 MinerGuard pref 不是 false',
      );
      assert(
        after.exists === true && after.minerGuardEnabled === false,
        'MinerGuard pref 回读不是 false',
      );
      return {before, after};
    } finally {
      await rm(root, {recursive: true, force: true});
    }
  });

  await record('fixture 源码有界且不含真实挖矿协议素材', async () => {
    const source = `${WORKER_SOURCE}\n${FIXTURE_CLIENT_SOURCE}`.toLowerCase();
    for (const forbidden of [
      'mining.subscribe',
      'mining.authorize',
      'wallet',
      'submit_share',
    ]) {
      assert(!source.includes(forbidden), `fixture 含禁止素材：${forbidden}`);
    }
    assert(!source.includes('aegisminerguard'), 'fixture 不得伪造告警 marker');
    assert(
      FIXTURE_CLIENT_SOURCE.includes(String(COMPUTE_WORKLOAD_MS)) &&
        WORKER_SOURCE.includes('setTimeout(computeChunk, 0)'),
      'fixture 缺少有界时长或协作让出',
    );
    return {
      workerSha256: sha256Text(WORKER_SOURCE),
      clientSha256: sha256Text(FIXTURE_CLIENT_SOURCE),
    };
  });

  await record('指定报告路径时终端仅输出简洁摘要', async () => {
    let output = '';
    printReport(
      {
        kind: 'self-test-summary',
        passed: true,
        qualification: 'partial',
        runtime_pass: true,
        release_eligible: false,
        browser: {processCommand: 'must-not-reach-terminal'},
      },
      '/tmp/aegis-report.json',
      {write: (value) => (output += value)},
    );
    assert(output.split('\n').length === 2, '终端摘要不是单行');
    assert(
      output.includes('/tmp/aegis-report.json') &&
        !output.includes('must-not-reach-terminal'),
      '终端摘要缺报告路径或泄漏完整证据',
    );
    return JSON.parse(output);
  });

  await record('报告原子发布拒绝覆盖既有证据', async () => {
    const root = await mkdtemp(join(tmpdir(), 'aegis-miner-report-self-test-'));
    const reportPath = join(root, 'report.json');
    try {
      await writeJson(reportPath, {first: true});
      let overwriteRejected = false;
      try {
        await writeJson(reportPath, {second: true});
      } catch {
        overwriteRejected = true;
      }
      assert(overwriteRejected, '既有报告被覆盖');
      assert(
        canonical(JSON.parse(await readFile(reportPath, 'utf8'))) ===
          canonical({first: true}),
        '既有报告内容发生变化',
      );
      return {overwriteRejected};
    } finally {
      await rm(root, {recursive: true, force: true});
    }
  });

  await record('精确终止自测主 PID 且无残留', async () => {
    const root = await mkdtemp(join(tmpdir(), 'aegis-miner-process-self-test-'));
    const profileDir = join(root, 'profile-marker');
    const child = spawn(
      process.execPath,
      ['-e', 'setInterval(() => {}, 1000)', profileDir],
      {detached: true, stdio: 'ignore'},
    );
    const tracker = new OwnedProcessTree(child.pid);
    try {
      await tracker.sample();
      tracker.startMonitoring();
      const termination = await terminateOwnedProcess(child, null, tracker, {
        chromiumExecutable: process.execPath,
        profileDir,
      });
      assert(termination.survivors.length === 0, '主 PID 仍存活');
      assert(
        termination.ownershipScan.survivors.length === 0,
        '最终精确命令扫描仍有残留',
      );
      return {
        terminationMethod: termination.terminationMethod,
        survivors: termination.survivors,
      };
    } finally {
      await tracker.stopMonitoring();
      if (child.exitCode === null && child.signalCode === null) {
        try {
          process.kill(child.pid, 'SIGKILL');
        } catch (error) {
          if (error?.code !== 'ESRCH') throw error;
        }
      }
      await rm(root, {recursive: true, force: true});
    }
  });

  await record('loopback HTTP 与 WebSocket echo fixture 可用', async () => {
    const fixture = new MinerFixtureServer();
    try {
      await fixture.start();
      const health = await fetchJson(fixture.loopbackUrl('/health'), 3_000);
      assert(health.ok === true && health.loopbackOnly === true, 'health 错误');
      const page = await fetch(fixture.loopbackUrl('/positive'));
      assert(page.ok, '正例页面 HTTP 失败');
      assert((await page.text()).includes('/fixture.js'), '正例页面缺脚本');
      const echo = await websocketEchoSelfTest(
        `ws://127.0.0.1:${fixture.port}/chat`,
      );
      assert(echo.echoed === echo.payload, 'WebSocket echo 被修改');
      await delay(50);
      const evidence = fixture.evidence();
      assert(
        evidence.websocketExchanges.length === 1 &&
          evidence.websocketExchanges[0].path === '/chat',
        'WebSocket echo 证据错误',
      );
      return evidence;
    } finally {
      await fixture.close();
    }
  });

  return {
    schemaVersion: 1,
    kind: 'aegis-miner-runtime-self-test',
    passed: checks.every((entry) => entry.passed),
    qualification: false,
    runtime_pass: false,
    release_eligible: false,
    checks,
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
    if (!report.passed) {
      process.exitCode = 1;
    }
    return;
  }

  const chromiumExecutable = await resolveChromiumExecutable(options.chromium);
  const appPath = resolve(dirname(chromiumExecutable), '..', '..');
  approvedReportPath = await validateEvidenceOutputPaths(options, appPath);
  options.report = approvedReportPath;
  const releaseOperationLock = options.buildIdentity
    ? await acquireBuildOperationLock(dirname(appPath))
    : async () => {};
  try {
    // 严格顺序：先验证整包与调用方固定身份，再执行被测 App。
    const sourceArtifactBinding = await verifySourceArtifactBinding(
      options,
      chromiumExecutable,
    );
    const browserEvidence = await collectBrowserEvidence(chromiumExecutable);
    if (options.dryRun) {
      const report = {
        schemaVersion: 1,
        kind: 'aegis-miner-runtime-dry-run',
        passed: true,
        qualification: false,
        runtime_pass: false,
        release_eligible: false,
        browser: browserEvidence,
        sourceArtifactBinding,
        report: options.report,
      };
      await writeJson(options.report, report);
      printReport(report, options.report);
      return;
    }

    const crashBefore = await snapshotMacCrashArtifacts();
    const report = await runVerification(
      options,
      browserEvidence,
      sourceArtifactBinding,
      crashBefore,
    );
    if (sourceArtifactBinding.available) {
      const terminalBinding = await verifySourceArtifactBinding(
        options,
        chromiumExecutable,
      );
      assert(
        canonical(terminalBinding) ===
          canonical(report.sourceArtifactBinding.after),
        '报告发布前的末次构建身份验证发生漂移',
      );
      report.sourceArtifactBinding.terminal = terminalBinding;
      report.sourceArtifactBinding.terminalVerified = true;
    }
    await writeJson(options.report, report);
    printReport(report, options.report);
    if (!report.runtime_pass) {
      process.exitCode = 1;
    } else if (!report.release_eligible) {
      process.exitCode = 2;
    }
  } finally {
    await releaseOperationLock();
  }
}

main().catch(async (error) => {
  const report = {
    schemaVersion: 1,
    kind: 'aegis-miner-runtime-error',
    passed: false,
    qualification: false,
    runtime_pass: false,
    release_eligible: false,
    error: errorMessage(error),
    ...(error?.evidence ? {evidence: error.evidence} : {}),
  };
  await writeJson(approvedReportPath, report).catch(() => {});
  printReport(report, approvedReportPath, process.stderr);
  process.exitCode = 1;
});
