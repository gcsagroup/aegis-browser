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
  rename,
  rm,
  rmdir,
  stat,
  symlink,
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
const DEFAULT_TIMEOUT_MS = 30_000;
const POLL_INTERVAL_MS = 50;
const PROFILE_SECRET_BYTES = 32;
const PROCESS_STABILITY_OBSERVATION_MS = 750;
const CRASH_STABILITY_OBSERVATION_MS = 3_000;
const TEST_HOSTS = Object.freeze({
  active: 'active.localhost',
  embedAlpha: 'alpha.localhost',
  embedBeta: 'beta.localhost',
  frame: 'fingerprinter.localhost',
  paused: 'paused.localhost',
  probe: 'probe.localhost',
});
const WEBGPU_BUCKETS = Object.freeze({
  maxBufferSize: new Set([
    '268435456',
    '536870912',
    '1073741824',
    '2147483648',
    '4294967296',
  ]),
  maxComputeWorkgroupStorageSize: new Set(['16384', '32768', '65536']),
  maxTextureDimension3D: new Set(['2048', '4096', '8192']),
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
  node apps/browser/scripts/verify-fingerprint-runtime.mjs [选项]

选项：
  --chromium PATH     Chromium.app 或 Chromium 可执行文件
                      默认：${defaultChromiumPath()}
  --timeout-ms N      单步超时，默认 ${DEFAULT_TIMEOUT_MS}
  --headed            使用可见窗口；默认 --headless=new
  --require-webgpu    当前设备没有可用 WebGPU adapter 时失败；Release 门必需
  --build-identity PATH
                      显式指定两阶段构建身份清单
  --build-identity-sha256 SHA256
                      调用方固定的清单摘要；必须与 --build-identity 成对出现
  --report PATH       将完整 JSON 报告写入指定路径
  --keep-profile      成功后也保留临时 Profile 与逐模式日志
  --dry-run           只校验参数、可执行文件和 SHA-256
  --self-test         运行参数、断言和 loopback fixture 自测
  --help              显示帮助

验证器只访问本机 loopback fixture，并用主/对照临时 Profile 受控重启。
最终 JSON 会写到标准输出；--report 只用于额外保存证据文件。
正式产物行为失败返回 1；行为通过但不具发布资格返回 2。
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
    requireWebGPU: false,
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
      const value = valueAfter(index, argument);
      index += 1;
      options.chromium = value;
    } else if (argument === '--timeout-ms') {
      const value = Number(valueAfter(index, argument));
      index += 1;
      assert(
        Number.isSafeInteger(value) && value >= 1_000,
        '--timeout-ms 必须是至少 1000 的整数',
      );
      options.timeoutMs = value;
    } else if (argument === '--headed') {
      options.headed = true;
    } else if (argument === '--require-webgpu') {
      options.requireWebGPU = true;
    } else if (argument === '--build-identity') {
      options.buildIdentity = resolve(valueAfter(index, argument));
      index += 1;
    } else if (argument === '--build-identity-sha256') {
      options.buildIdentitySha256 = valueAfter(index, argument);
      index += 1;
    } else if (argument === '--report') {
      const value = valueAfter(index, argument);
      index += 1;
      options.report = resolve(value);
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
  const canonicalRepoRoot = await realpath(REPO_ROOT);
  const repoGitDir = await execFileText('/usr/bin/git', [
    '-C',
    canonicalRepoRoot,
    'rev-parse',
    '--absolute-git-dir',
  ]);
  assert(
    !pathIsWithin(await realpath(repoGitDir.trim()), canonicalReport),
    '--report 不得位于根仓库 Git 元数据中',
  );
  if (pathIsWithin(canonicalRepoRoot, canonicalReport)) {
    const relativeReport = relative(canonicalRepoRoot, canonicalReport);
    const tracked = await execFileOutcome('/usr/bin/git', [
      '-C',
      REPO_ROOT,
      'ls-files',
      '--error-unmatch',
      '--',
      relativeReport,
    ]);
    assert(!tracked.passed, '--report 不得覆盖根仓库已跟踪源码');
  }
  const chromiumSource = await realpath(join(resolveDefaultChromiumRoot(), 'src'));
  const chromiumGitDir = await execFileText('/usr/bin/git', [
    '-C',
    chromiumSource,
    'rev-parse',
    '--absolute-git-dir',
  ]);
  assert(
    !pathIsWithin(await realpath(chromiumGitDir.trim()), canonicalReport),
    '--report 不得位于 Chromium Git 元数据中',
  );
  if (pathIsWithin(chromiumSource, canonicalReport)) {
    const relativeReport = relative(chromiumSource, canonicalReport);
    const tracked = await execFileOutcome('/usr/bin/git', [
      '-C',
      chromiumSource,
      'ls-files',
      '--error-unmatch',
      '--',
      relativeReport,
    ]);
    assert(!tracked.passed, '--report 不得覆盖 Chromium 已跟踪源码');
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
    verifier: await fileEvidence(BUILD_IDENTITY_SCRIPT),
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
  const gatekeeper = await execFileOutcome('/usr/sbin/spctl', [
    '--assess',
    '--type',
    'execute',
    '--verbose=4',
    appPath,
  ]);
  const detailText = `${details.stdout}\n${details.stderr}`;
  const value = (name) =>
    detailText.match(new RegExp(`^${name}=(.*)$`, 'mu'))?.[1]?.trim() ?? null;
  const flags = detailText.match(/^CodeDirectory .* flags=[^\n]+$/mu)?.[0] ?? null;
  return {
    supported: true,
    strictDeepValid: strict.passed,
    gatekeeperAccepted: gatekeeper.passed,
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
    gatekeeperError: gatekeeper.passed
      ? null
      : gatekeeper.stderr.trim() || gatekeeper.error,
  };
}

function sha256Command(file, args, options = {}) {
  return new Promise((resolveCommand, rejectCommand) => {
    const hash = createHash('sha256');
    let stderr = '';
    const child = spawn(file, args, {
      cwd: options.cwd,
      env: options.env ?? process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.on('data', (chunk) => hash.update(chunk));
    child.stderr.on('data', (chunk) => {
      if (stderr.length < 64 * 1024) {
        stderr += chunk.toString('utf8');
      }
    });
    child.once('error', rejectCommand);
    child.once('exit', (code, signal) => {
      if (code === 0) {
        resolveCommand(hash.digest('hex'));
        return;
      }
      rejectCommand(
        new VerificationError(
          `${basename(file)} ${args.join(' ')} 失败：${
            stderr.trim() || code || signal || 'unknown'
          }`,
        ),
      );
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
  return {
    path: resolvedPath,
    size: after.size,
    sha256,
  };
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
    assert(
      basename(name) === name,
      `patch series 含非单文件路径：${name}`,
    );
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
    await execFileText(
      '/usr/bin/plutil',
      ['-extract', key, 'raw', '-o', '-', plistPath],
    )
  ).trim();
}

async function collectUntrackedEvidence(checkoutPath) {
  const output = await execFileText(
    '/usr/bin/git',
    ['-C', checkoutPath, 'ls-files', '--others', '--exclude-standard', '-z'],
  );
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
  return {
    count: paths.length,
    manifestSha256: hash.digest('hex'),
  };
}

async function collectBrowserEvidence(chromiumExecutable) {
  const executable = await fileEvidence(chromiumExecutable);
  const appPath = resolve(dirname(chromiumExecutable), '..', '..');
  const isMacApp =
    process.platform === 'darwin' &&
    basename(appPath).endsWith('.app') &&
    basename(dirname(chromiumExecutable)) === 'MacOS';
  assert(isMacApp, '正式指纹验证要求 macOS Chromium.app 产物');

  const infoPlistPath = join(appPath, 'Contents', 'Info.plist');
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
  const gnArgs = await fileEvidence(join(dirname(appPath), 'args.gn'));
  const patchSeries = await collectPatchSeriesEvidence();
  const verifier = await fileEvidence(fileURLToPath(import.meta.url));
  const checkoutPath = await realpath(
    join(resolveDefaultChromiumRoot(), 'src'),
  );
  const gitText = (args) =>
    execFileText('/usr/bin/git', ['-C', checkoutPath, ...args]);
  const diffHash = () =>
    sha256Command(
      '/usr/bin/git',
      ['diff', '--binary', '--no-ext-diff', 'HEAD', '--'],
      {cwd: checkoutPath},
    );
  const head = (await gitText(['rev-parse', 'HEAD'])).trim();
  const headTree = (await gitText(['rev-parse', 'HEAD^{tree}'])).trim();
  const status = await gitText([
    'status',
    '--porcelain=v1',
    '--untracked-files=all',
  ]);
  const diffSha256 = await diffHash();
  const untracked = await collectUntrackedEvidence(checkoutPath);
  const [headAfter, statusAfter, diffSha256After, untrackedAfter] =
    await Promise.all([
      gitText(['rev-parse', 'HEAD']).then((value) => value.trim()),
      gitText([
        'status',
        '--porcelain=v1',
        '--untracked-files=all',
      ]),
      diffHash(),
      collectUntrackedEvidence(checkoutPath),
    ]);
  assert(
    head === headAfter &&
      status === statusAfter &&
      diffSha256 === diffSha256After &&
      canonical(untracked) === canonical(untrackedAfter),
    '外部 Chromium checkout 在身份采集期间发生变化，请稳定后重试',
  );
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
  const bundleDisplayName = await optionalPlistValue(
    infoPlistPath,
    'CFBundleDisplayName',
  ).catch(() => null);
  assert(
    Boolean(
      chromiumVersion &&
        bundleIdentifier &&
        bundleShortVersion &&
        bundleVersion,
    ),
    'Chromium.app 或可执行文件版本身份不完整',
  );
  const outputDir = dirname(appPath);
  const codeSignature = await collectCodeSignatureEvidence(appPath);
  return {
    app: {
      path: appPath,
      bundleIdentifier,
      bundleDisplayName,
      bundleShortVersion,
      bundleVersion,
      chromiumVersion,
    },
    executable,
    framework,
    checkout: {
      path: checkoutPath,
      head,
      headTree,
      dirty: status.length > 0,
      statusEntryCount: status.split(/\r?\n/u).filter(Boolean).length,
      statusSha256: sha256Text(status),
      diffSha256,
      untracked,
    },
    patchSeries,
    gnArgs,
    verifier,
    codeSignature,
    productIdentity: {
      configured: false,
      verified: false,
      currentBundleIdentifier: bundleIdentifier,
      currentDisplayName: bundleDisplayName,
      reason: '尚未由产品方确认正式 Bundle ID、显示名与签名团队',
    },
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

const WORKER_PROBE_SOURCE = String.raw`
const workerKind = new URL(self.location.href).searchParams.get('kind');

function workerHash(bytes) {
  let hash = 0x811c9dc5;
  for (const byte of bytes) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return 'fnv1a32-' + hash.toString(16).padStart(8, '0');
}

function offscreenCanvasProbe() {
  if (typeof OffscreenCanvas !== 'function') {
    return {
      supported: false,
      coverage: 'not-covered',
      reasonCode: 'offscreen-canvas-unavailable',
      errorName: 'NotSupportedError',
      error: 'OffscreenCanvas unavailable',
    };
  }
  try {
    const width = 32;
    const height = 32;
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext('2d', {willReadFrequently: true});
    if (!context) {
      return {
        supported: false,
        coverage: 'not-covered',
        reasonCode: 'offscreen-2d-context-unavailable',
        errorName: 'NotSupportedError',
        error: 'OffscreenCanvas 2d context unavailable',
      };
    }
    const image = context.createImageData(width, height);
    for (let index = 0; index < image.data.length; index += 4) {
      const pixel = index / 4;
      image.data[index] = (pixel * 11 + 17) & 255;
      image.data[index + 1] = (pixel * 23 + 41) & 255;
      image.data[index + 2] = (pixel * 37 + 89) & 255;
      image.data[index + 3] = 255;
    }
    context.putImageData(image, 0, 0);
    const first = context.getImageData(0, 0, width, height).data;
    const second = context.getImageData(0, 0, width, height).data;
    return {
      supported: true,
      coverage: 'covered',
      inputHash: workerHash(image.data),
      firstReadHash: workerHash(first),
      secondReadHash: workerHash(second),
    };
  } catch (error) {
    return {
      supported: false,
      coverage: 'failed',
      reasonCode: 'offscreen-canvas-probe-error',
      errorName: String(error?.name || ''),
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

function reply(port, id) {
  port.postMessage({id, report: offscreenCanvasProbe()});
}

if (workerKind === 'shared') {
  self.onconnect = (event) => {
    const port = event.ports[0];
    port.onmessage = (message) => reply(port, message.data?.id);
    port.start();
  };
} else if (workerKind === 'service') {
  self.addEventListener('install', () => self.skipWaiting());
  self.addEventListener('activate', (event) => {
    event.waitUntil(self.clients.claim());
  });
  self.addEventListener('message', (event) => {
    if (event.ports[0]) reply(event.ports[0], event.data?.id);
  });
} else {
  self.onmessage = (event) => reply(self, event.data?.id);
}
`;

const PROBE_CLIENT_SOURCE = String.raw`
const AEGIS_PROBE_TIMEOUT_MS = 10000;

function withProbeTimeout(promise, label) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(label + ' timeout')),
                         AEGIS_PROBE_TIMEOUT_MS);
    }),
  ]).finally(() => clearTimeout(timer));
}

async function hashBytes(value) {
  const bytes = value instanceof Uint8Array
    ? value
    : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  if (globalThis.crypto && globalThis.crypto.subtle) {
    const digest = await crypto.subtle.digest(
      'SHA-256',
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
    );
    return Array.from(new Uint8Array(digest), (byte) =>
      byte.toString(16).padStart(2, '0')).join('');
  }
  let hash = 0x811c9dc5;
  for (const byte of bytes) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return 'fnv1a32-' + hash.toString(16).padStart(8, '0');
}

async function hashText(value) {
  return hashBytes(new TextEncoder().encode(value));
}

function errorText(error) {
  return error instanceof Error ? error.message : String(error);
}

function waitForWorkerReply(send, cleanup) {
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error('worker fingerprint probe timeout'));
    }, AEGIS_PROBE_TIMEOUT_MS);
    send(id, (message) => {
      clearTimeout(timer);
      cleanup();
      if (message?.id !== id || !message.report) {
        reject(new Error('worker fingerprint probe returned invalid data'));
        return;
      }
      resolve(message.report);
    });
  });
}

async function probeDedicatedWorker() {
  if (typeof Worker !== 'function') {
    return {
      supported: false,
      coverage: 'not-covered',
      reasonCode: 'dedicated-worker-unavailable',
      errorName: 'NotSupportedError',
      error: 'Worker unavailable',
    };
  }
  const worker = new Worker('/fingerprint-worker.js?kind=dedicated');
  return waitForWorkerReply(
    (id, receive) => {
      worker.onmessage = (event) => receive(event.data);
      worker.onerror = (event) => receive({id, report: {
        supported: false,
        coverage: 'failed',
        reasonCode: 'dedicated-worker-error',
        errorName: 'Error',
        error: event.message || 'DedicatedWorker error',
      }});
      worker.postMessage({id});
    },
    () => worker.terminate(),
  );
}

async function probeSharedWorker() {
  if (typeof SharedWorker !== 'function') {
    return {
      supported: false,
      coverage: 'not-covered',
      reasonCode: 'shared-worker-unavailable',
      errorName: 'NotSupportedError',
      error: 'SharedWorker unavailable',
    };
  }
  const worker = new SharedWorker(
    '/fingerprint-worker.js?kind=shared',
    {name: 'aegis-fingerprint-shared'},
  );
  worker.port.start();
  return waitForWorkerReply(
    (id, receive) => {
      worker.port.onmessage = (event) => receive(event.data);
      worker.port.onmessageerror = () => receive({id, report: {
        supported: false,
        coverage: 'failed',
        reasonCode: 'shared-worker-message-error',
        errorName: 'DataError',
        error: 'SharedWorker message error',
      }});
      worker.port.postMessage({id});
    },
    () => worker.port.close(),
  );
}

async function probeServiceWorker() {
  if (!navigator.serviceWorker) {
    return {
      supported: false,
      coverage: 'not-covered',
      reasonCode: 'service-worker-api-unavailable',
      errorName: 'NotSupportedError',
      error: 'ServiceWorker unavailable',
    };
  }
  try {
    const registration = await navigator.serviceWorker.register(
      '/fingerprint-worker.js?kind=service',
      {scope: '/'},
    );
    await navigator.serviceWorker.ready;
    const active = registration.active || registration.waiting;
    if (!active) {
      return {
        supported: false,
        coverage: 'failed',
        reasonCode: 'service-worker-not-active',
        errorName: 'InvalidStateError',
        error: 'ServiceWorker not active',
      };
    }
    const channel = new MessageChannel();
    return await waitForWorkerReply(
      (id, receive) => {
        channel.port1.onmessage = (event) => receive(event.data);
        active.postMessage({id}, [channel.port2]);
      },
      () => channel.port1.close(),
    );
  } catch (error) {
    return {
      supported: false,
      coverage: 'failed',
      reasonCode: 'service-worker-probe-error',
      errorName: String(error?.name || ''),
      error: errorText(error),
    };
  }
}

async function probeWorkerSurfaces() {
  if (window.parent === window) {
    return {
      tested: false,
      reason: '仅在第三方 iframe 分区探针中执行',
    };
  }
  const [dedicated, shared, service] = await Promise.all([
    probeDedicatedWorker(),
    probeSharedWorker(),
    probeServiceWorker(),
  ]);
  return {tested: true, dedicated, shared, service};
}

async function probeCanvas() {
  try {
    const width = 64;
    const height = 64;
    const input = new Uint8ClampedArray(width * height * 4);
    for (let index = 0; index < input.length; index += 4) {
      const pixel = index / 4;
      input[index] = (pixel * 17 + 31) & 255;
      input[index + 1] = (pixel * 29 + 73) & 255;
      input[index + 2] = (pixel * 43 + 101) & 255;
      input[index + 3] = 255;
    }
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext('2d', {willReadFrequently: true});
    if (!context) {
      return {supported: false, error: '2d context unavailable'};
    }
    context.putImageData(new ImageData(input, width, height), 0, 0);
    const first = context.getImageData(0, 0, width, height).data;
    const second = context.getImageData(0, 0, width, height).data;
    const firstDataUrl = canvas.toDataURL('image/png');
    const secondDataUrl = canvas.toDataURL('image/png');
    const firstBlob = await new Promise((resolve, reject) => {
      canvas.toBlob((blob) => blob ? resolve(blob) : reject(
        new Error('toBlob returned null')), 'image/png');
    });
    const secondBlob = await new Promise((resolve, reject) => {
      canvas.toBlob((blob) => blob ? resolve(blob) : reject(
        new Error('toBlob returned null')), 'image/png');
    });
    let rgbaFloat16;
    try {
      const firstFloat16 = context.getImageData(
        0,
        0,
        width,
        height,
        {colorSpace: 'srgb', pixelFormat: 'rgba-float16'},
      );
      const secondFloat16 = context.getImageData(
        0,
        0,
        width,
        height,
        {colorSpace: 'srgb', pixelFormat: 'rgba-float16'},
      );
      const dataType = firstFloat16.data?.constructor?.name ?? 'unknown';
      if (dataType !== 'Float16Array') {
        rgbaFloat16 = {
          supported: false,
          error: 'rgba-float16 returned ' + dataType,
        };
      } else {
        rgbaFloat16 = {
          supported: true,
          dataType,
          length: firstFloat16.data.length,
          firstReadHash: await hashBytes(firstFloat16.data),
          secondReadHash: await hashBytes(secondFloat16.data),
        };
      }
    } catch (error) {
      rgbaFloat16 = {
        supported: false,
        error: errorText(error) || 'rgba-float16 unavailable',
      };
    }
    return {
      supported: true,
      inputHash: await hashBytes(input),
      firstReadHash: await hashBytes(first),
      secondReadHash: await hashBytes(second),
      firstDataUrlHash: await hashText(firstDataUrl),
      secondDataUrlHash: await hashText(secondDataUrl),
      firstBlobHash: await hashBytes(new Uint8Array(await firstBlob.arrayBuffer())),
      secondBlobHash: await hashBytes(new Uint8Array(await secondBlob.arrayBuffer())),
      rgbaFloat16,
    };
  } catch (error) {
    return {supported: false, error: errorText(error)};
  }
}

function makeOffscreenCanvasInput(width, height) {
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext('2d', {willReadFrequently: true});
  if (!context) throw new Error('OffscreenCanvas 2d context unavailable');
  const image = context.createImageData(width, height);
  for (let index = 0; index < image.data.length; index += 4) {
    const pixel = index / 4;
    image.data[index] = (pixel * 13 + 19) & 255;
    image.data[index + 1] = (pixel * 31 + 47) & 255;
    image.data[index + 2] = (pixel * 53 + 83) & 255;
    image.data[index + 3] = 255;
  }
  context.putImageData(image, 0, 0);
  return {canvas, input: image.data};
}

function readImageBitmapWithWebGL(bitmap, width, height) {
  const canvas = new OffscreenCanvas(width, height);
  const gl = canvas.getContext('webgl', {
    antialias: false,
    premultipliedAlpha: false,
    preserveDrawingBuffer: true,
  });
  if (!gl) throw new Error('OffscreenCanvas WebGL readback unavailable');
  const texture = gl.createTexture();
  const framebuffer = gl.createFramebuffer();
  if (!texture || !framebuffer) {
    throw new Error('WebGL readback allocation failed');
  }
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texImage2D(
    gl.TEXTURE_2D,
    0,
    gl.RGBA,
    gl.RGBA,
    gl.UNSIGNED_BYTE,
    bitmap,
  );
  gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
  gl.framebufferTexture2D(
    gl.FRAMEBUFFER,
    gl.COLOR_ATTACHMENT0,
    gl.TEXTURE_2D,
    texture,
    0,
  );
  if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
    throw new Error('WebGL readback framebuffer incomplete');
  }
  const pixels = new Uint8Array(width * height * 4);
  gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
  if (gl.getError() !== gl.NO_ERROR) {
    throw new Error('WebGL readback failed');
  }
  gl.deleteFramebuffer(framebuffer);
  gl.deleteTexture(texture);
  return pixels;
}

async function probeOffscreenCanvasExports() {
  if (typeof OffscreenCanvas !== 'function') {
    return {
      supported: false,
      coverage: 'not-covered',
      reasonCode: 'offscreen-canvas-unavailable',
      error: 'OffscreenCanvas unavailable',
    };
  }
  const width = 32;
  const height = 32;
  let inputHash = null;
  let convertToBlob;
  try {
    const prepared = makeOffscreenCanvasInput(width, height);
    inputHash = await hashBytes(prepared.input);
    if (typeof prepared.canvas.convertToBlob !== 'function') {
      convertToBlob = {
        supported: false,
        coverage: 'not-covered',
        reasonCode: 'convert-to-blob-unavailable',
        error: 'OffscreenCanvas.convertToBlob unavailable',
      };
    } else {
      const first = await prepared.canvas.convertToBlob({type: 'image/png'});
      const second = await prepared.canvas.convertToBlob({type: 'image/png'});
      convertToBlob = {
        supported: true,
        coverage: 'covered',
        firstHash: await hashBytes(new Uint8Array(await first.arrayBuffer())),
        secondHash: await hashBytes(new Uint8Array(await second.arrayBuffer())),
      };
    }
  } catch (error) {
    convertToBlob = {
      supported: false,
      coverage: 'failed',
      reasonCode: 'convert-to-blob-error',
      errorName: String(error?.name || ''),
      error: errorText(error),
    };
  }

  let transferToImageBitmap;
  try {
    const firstPrepared = makeOffscreenCanvasInput(width, height);
    const secondPrepared = makeOffscreenCanvasInput(width, height);
    if (typeof firstPrepared.canvas.transferToImageBitmap !== 'function') {
      transferToImageBitmap = {
        supported: false,
        coverage: 'not-covered',
        reasonCode: 'transfer-to-image-bitmap-unavailable',
        error: 'OffscreenCanvas.transferToImageBitmap unavailable',
      };
    } else {
      const firstBitmap = firstPrepared.canvas.transferToImageBitmap();
      const secondBitmap = secondPrepared.canvas.transferToImageBitmap();
      const firstPixels = readImageBitmapWithWebGL(firstBitmap, width, height);
      const secondPixels = readImageBitmapWithWebGL(secondBitmap, width, height);
      firstBitmap.close();
      secondBitmap.close();
      transferToImageBitmap = {
        supported: true,
        coverage: 'covered',
        readback: 'ImageBitmap-to-WebGL-readPixels',
        firstHash: await hashBytes(firstPixels),
        secondHash: await hashBytes(secondPixels),
      };
    }
  } catch (error) {
    transferToImageBitmap = {
      supported: false,
      coverage: 'failed',
      reasonCode: 'transfer-to-image-bitmap-error',
      errorName: String(error?.name || ''),
      error: errorText(error),
    };
  }
  return {
    supported: true,
    coverage: 'covered',
    inputHash,
    convertToBlob,
    transferToImageBitmap,
  };
}

function audioInput(length, phase) {
  const input = new Float32Array(length);
  for (let index = 0; index < input.length; index += 1) {
    input[index] = Math.sin((index + phase) * 0.073) * 0.75 +
      Math.cos((index + phase) * 0.019) * 0.125;
  }
  return input;
}

async function probeAudio() {
  try {
    if (typeof AudioBuffer !== 'function') {
      return {supported: false, error: 'AudioBuffer unavailable'};
    }
    const length = 2048;
    const buffer = new AudioBuffer({
      length,
      numberOfChannels: 1,
      sampleRate: 44100,
    });
    const firstInput = audioInput(length, 0);
    buffer.copyToChannel(firstInput, 0);
    const firstRead = new Float32Array(buffer.getChannelData(0));
    const secondRead = new Float32Array(buffer.getChannelData(0));

    // 写入值由脚本自己提供，不携带硬件指纹；保护模式也必须精确保留。
    const secondInput = audioInput(length, 97);
    buffer.copyToChannel(secondInput, 0);
    const afterWrite = new Float32Array(buffer.getChannelData(0));

    return {
      supported: true,
      firstInputHash: await hashBytes(firstInput),
      firstReadHash: await hashBytes(firstRead),
      secondReadHash: await hashBytes(secondRead),
      secondInputHash: await hashBytes(secondInput),
      afterWriteHash: await hashBytes(afterWrite),
    };
  } catch (error) {
    return {supported: false, error: errorText(error)};
  }
}

async function probeWebGL() {
  try {
    const canvas = document.createElement('canvas');
    const gl = canvas.getContext('webgl2', {
      antialias: false,
      preserveDrawingBuffer: true,
    }) || canvas.getContext('webgl', {
      antialias: false,
      preserveDrawingBuffer: true,
    });
    if (!gl) {
      return {supported: false, error: 'WebGL context unavailable'};
    }
    const debugExtensionAdvertised =
      gl.getSupportedExtensions()?.includes('WEBGL_debug_renderer_info') ??
      false;
    const debug = gl.getExtension('WEBGL_debug_renderer_info');
    let vendor = '';
    let renderer = '';
    if (debug) {
      vendor = String(gl.getParameter(debug.UNMASKED_VENDOR_WEBGL) || '');
      renderer = String(gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) || '');
    }
    return {
      supported: true,
      version: String(gl.getParameter(gl.VERSION) || ''),
      shadingLanguageVersion: String(
        gl.getParameter(gl.SHADING_LANGUAGE_VERSION) || '',
      ),
      debugExtensionAdvertised,
      debugInfoAvailable: Boolean(debug),
      vendor,
      renderer,
    };
  } catch (error) {
    return {supported: false, error: errorText(error)};
  }
}

const WEBGPU_PROBE_BUCKETS = {
  maxBufferSize: [
    268435456,
    536870912,
    1073741824,
    2147483648,
    4294967296,
  ],
  maxComputeWorkgroupStorageSize: [16384, 32768, 65536],
  maxTextureDimension3D: [2048, 4096, 8192],
};

function floorWebGpuBucket(name, actual) {
  let selected = null;
  for (const bucket of WEBGPU_PROBE_BUCKETS[name] || []) {
    if (bucket <= actual) selected = bucket;
  }
  return selected;
}

function webGpuErrorDetails(error) {
  const isDomException =
    typeof DOMException === 'function' && error instanceof DOMException;
  const message = errorText(error);
  const describesLimitRejection =
    /limit/iu.test(message) &&
    /exceed|greater|supported|unsupported|maximum/iu.test(message);
  return {
    error: message,
    errorName: String(error?.name || ''),
    errorConstructor: String(error?.constructor?.name || ''),
    isDomException,
    expectedRejection:
      isDomException &&
      error?.name === 'OperationError' &&
      describesLimitRejection,
  };
}

async function observeEarlyWebGpuDeviceLoss(device) {
  let timer;
  try {
    return await Promise.race([
      device.lost.then((info) => ({
        reason: String(info?.reason || ''),
        message: String(info?.message || ''),
      })),
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(null), 50);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function probeWebGPU() {
  try {
    if (!navigator.gpu) {
      return {
        supported: false,
        secureContext: globalThis.isSecureContext,
        error: 'navigator.gpu unavailable',
      };
    }
    const adapter = await withProbeTimeout(
      navigator.gpu.requestAdapter({powerPreference: 'low-power'}),
      'WebGPU requestAdapter',
    );
    if (!adapter) {
      return {
        supported: false,
        secureContext: globalThis.isSecureContext,
        error: 'WebGPU adapter unavailable',
      };
    }
    const info = adapter.info || {};
    const limits = adapter.limits || {};
    const features = Array.from(adapter.features || [], String).sort();
    const publicLimits = {
      maxBufferSize: Number(limits.maxBufferSize),
      maxComputeWorkgroupStorageSize: Number(
        limits.maxComputeWorkgroupStorageSize,
      ),
      maxTextureDimension3D: Number(limits.maxTextureDimension3D),
    };
    let deviceReport;
    try {
      const device = await withProbeTimeout(
        adapter.requestDevice({requiredLimits: publicLimits}),
        'WebGPU requestDevice',
      );
      const earlyLoss = await observeEarlyWebGpuDeviceLoss(device);
      deviceReport = earlyLoss
        ? {
            supported: false,
            coverage: 'failed',
            reasonCode: 'device-lost',
            deviceLost: earlyLoss,
          }
        : {
            supported: true,
            requestedLimits: Object.fromEntries(
              Object.entries(publicLimits).map(([name, value]) => [
                name,
                String(value),
              ]),
            ),
            limits: {
              maxBufferSize: String(device.limits.maxBufferSize ?? ''),
              maxComputeWorkgroupStorageSize: String(
                device.limits.maxComputeWorkgroupStorageSize ?? '',
              ),
              maxTextureDimension3D: String(
                device.limits.maxTextureDimension3D ?? '',
              ),
            },
          };
      device.destroy();
    } catch (error) {
      deviceReport = {supported: false, ...webGpuErrorDetails(error)};
    }

    const requiredLimitRejections = {};
    for (const name of Object.keys(publicLimits)) {
      const requested = publicLimits[name] + 1;
      try {
        const unexpectedDevice = await withProbeTimeout(
          adapter.requestDevice({requiredLimits: {[name]: requested}}),
          'WebGPU requiredLimits ' + name,
        );
        unexpectedDevice.destroy();
        requiredLimitRejections[name] = {
          requested,
          rejected: false,
          expectedRejection: false,
        };
      } catch (error) {
        requiredLimitRejections[name] = {
          requested,
          rejected: true,
          ...webGpuErrorDetails(error),
        };
      }
    }

    const rawBucketControls = {};
    for (const name of Object.keys(publicLimits)) {
      const bucket = floorWebGpuBucket(name, publicLimits[name]);
      const requested = bucket === null ? null : bucket + 1;
      if (requested === null || requested > publicLimits[name]) {
        rawBucketControls[name] = {
          tested: false,
          reasonCode: 'no-hardware-headroom-above-protected-bucket',
          actual: publicLimits[name],
          bucket,
          requested,
        };
        continue;
      }
      try {
        const controlAdapter = await withProbeTimeout(
          navigator.gpu.requestAdapter({powerPreference: 'low-power'}),
          'WebGPU raw bucket control adapter ' + name,
        );
        if (!controlAdapter) {
          throw new Error('WebGPU raw bucket control adapter unavailable');
        }
        const controlDevice = await withProbeTimeout(
          controlAdapter.requestDevice({requiredLimits: {[name]: requested}}),
          'WebGPU raw bucket control ' + name,
        );
        const earlyLoss = await observeEarlyWebGpuDeviceLoss(controlDevice);
        rawBucketControls[name] = earlyLoss
          ? {
              tested: true,
              accepted: false,
              reasonCode: 'device-lost',
              actual: publicLimits[name],
              bucket,
              requested,
              deviceLost: earlyLoss,
            }
          : {
              tested: true,
              accepted: true,
              actual: publicLimits[name],
              bucket,
              requested,
              deviceLimit: String(controlDevice.limits[name] ?? ''),
            };
        controlDevice.destroy();
      } catch (error) {
        rawBucketControls[name] = {
          tested: true,
          accepted: false,
          actual: publicLimits[name],
          bucket,
          requested,
          ...webGpuErrorDetails(error),
        };
      }
    }
    return {
      supported: true,
      secureContext: globalThis.isSecureContext,
      info: {
        vendor: String(info.vendor || ''),
        architecture: String(info.architecture || ''),
        device: String(info.device || ''),
        description: String(info.description || ''),
        driver: String(info.driver || ''),
        subgroupMinSize: String(info.subgroupMinSize ?? ''),
        subgroupMaxSize: String(info.subgroupMaxSize ?? ''),
      },
      features,
      limits: {
        maxBufferSize: String(limits.maxBufferSize ?? ''),
        maxComputeWorkgroupStorageSize: String(
          limits.maxComputeWorkgroupStorageSize ?? '',
        ),
        maxTextureDimension3D: String(limits.maxTextureDimension3D ?? ''),
        minSubgroupSize: String(info.subgroupMinSize ?? ''),
        maxSubgroupSize: String(info.subgroupMaxSize ?? ''),
      },
      device: deviceReport,
      requiredLimitRejections,
      rawBucketControls,
    };
  } catch (error) {
    return {
      supported: false,
      secureContext: globalThis.isSecureContext,
      error: errorText(error),
    };
  }
}

async function runAegisFingerprintProbe() {
  const [canvas, offscreenCanvas, audio, webgl, webgpu, workers] =
    await Promise.all([
    withProbeTimeout(probeCanvas(), 'Canvas probe'),
    withProbeTimeout(probeOffscreenCanvasExports(), 'OffscreenCanvas probe'),
    withProbeTimeout(probeAudio(), 'Audio probe'),
    withProbeTimeout(probeWebGL(), 'WebGL probe'),
    withProbeTimeout(probeWebGPU(), 'WebGPU probe'),
    withProbeTimeout(probeWorkerSurfaces(), 'Worker probe'),
  ]);
  return {
    href: location.href,
    hostname: location.hostname,
    secureContext: globalThis.isSecureContext,
    canvas,
    offscreenCanvas,
    audio,
    webgl,
    webgpu,
    workers,
  };
}

globalThis.__aegisFingerprintPromise = runAegisFingerprintProbe();
if (window.parent !== window) {
  globalThis.__aegisFingerprintPromise.then(
    (report) => parent.postMessage({
      type: 'aegis-fingerprint-report',
      report,
    }, '*'),
    (error) => parent.postMessage({
      type: 'aegis-fingerprint-error',
      error: errorText(error),
    }, '*'),
  );
} else {
  const params = new URLSearchParams(location.search);
  const run = params.get('run');
  const key = params.get('key');
  if (run && key) {
    globalThis.__aegisFingerprintPromise.then(
      (report) => fetch('/result?run=' + encodeURIComponent(run) +
        '&key=' + encodeURIComponent(key), {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({report}),
      }),
      (error) => fetch('/result?run=' + encodeURIComponent(run) +
        '&key=' + encodeURIComponent(key), {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({error: errorText(error)}),
      }),
    );
  }
}
`;

class FingerprintFixtureServer {
  constructor() {
    this.server = createHttpServer((request, response) => {
      this.handleRequest(request, response);
    });
    this.port = null;
    this.pendingResults = new Map();
  }

  async start() {
    await new Promise((resolveListen, rejectListen) => {
      this.server.once('error', rejectListen);
      this.server.listen(0, '127.0.0.1', () => {
        this.server.off('error', rejectListen);
        resolveListen();
      });
    });
    const address = this.server.address();
    assert(
      address && typeof address === 'object' && address.address === '127.0.0.1',
      '指纹 fixture 未绑定到 127.0.0.1',
    );
    this.port = address.port;
  }

  url(host, pathname = '/probe') {
    assert(this.port, '指纹 fixture 尚未启动');
    return `http://${host}:${this.port}${pathname}`;
  }

  loopbackUrl(pathname = '/health') {
    assert(this.port, '指纹 fixture 尚未启动');
    return `http://127.0.0.1:${this.port}${pathname}`;
  }

  headers(contentType) {
    return {
      'cache-control': 'no-store',
      'content-security-policy':
        "default-src 'none'; script-src 'unsafe-inline'; " +
        "frame-src http:; connect-src 'self'; img-src data: blob:; " +
        "worker-src 'self'; style-src 'unsafe-inline'",
      'content-type': contentType,
      'cross-origin-resource-policy': 'cross-origin',
      'x-content-type-options': 'nosniff',
    };
  }

  handleRequest(request, response) {
    const requestUrl = new URL(
      request.url ?? '/',
      `http://${request.headers.host ?? '127.0.0.1'}`,
    );
    if (requestUrl.pathname === '/health') {
      response.writeHead(200, this.headers('application/json; charset=utf-8'));
      response.end(JSON.stringify({ok: true}));
      return;
    }
    if (requestUrl.pathname === '/result' && request.method === 'POST') {
      this.handleResult(requestUrl, request, response);
      return;
    }
    if (requestUrl.pathname === '/probe') {
      response.writeHead(200, this.headers('text/html; charset=utf-8'));
      response.end(`<!doctype html>
<meta charset="utf-8">
<title>Aegis fingerprint probe</title>
<script>${PROBE_CLIENT_SOURCE}</script>`);
      return;
    }
    if (requestUrl.pathname === '/fingerprint-worker.js') {
      response.writeHead(200, {
        ...this.headers('text/javascript; charset=utf-8'),
        'service-worker-allowed': '/',
      });
      response.end(WORKER_PROBE_SOURCE);
      return;
    }
    if (requestUrl.pathname === '/embed') {
      const run = requestUrl.searchParams.get('run') ?? '';
      const key = requestUrl.searchParams.get('key') ?? '';
      const frameUrl = this.url(TEST_HOSTS.frame, '/probe?embedded=1');
      response.writeHead(200, this.headers('text/html; charset=utf-8'));
      response.end(`<!doctype html>
<meta charset="utf-8">
<title>Aegis top-level partition probe</title>
<iframe id="probe" allow="webgpu" src=${JSON.stringify(frameUrl)}></iframe>
<script>
globalThis.__aegisFingerprintPromise = new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('iframe probe timeout')), 15000);
  addEventListener('message', (event) => {
    if (event.origin !== ${JSON.stringify(new URL(frameUrl).origin)}) return;
    if (event.data?.type === 'aegis-fingerprint-error') {
      clearTimeout(timer);
      reject(new Error(event.data.error || 'iframe probe failed'));
      return;
    }
    if (event.data?.type === 'aegis-fingerprint-report') {
      clearTimeout(timer);
      resolve(Object.assign({}, event.data.report, {
        topLevelHostname: location.hostname,
        iframeHostname: event.data.report.hostname,
      }));
    }
  });
});
globalThis.__aegisFingerprintPromise.then(
  (report) => fetch('/result?run=' + encodeURIComponent(${JSON.stringify(run)}) +
    '&key=' + encodeURIComponent(${JSON.stringify(key)}), {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({report}),
  }),
  (error) => fetch('/result?run=' + encodeURIComponent(${JSON.stringify(run)}) +
    '&key=' + encodeURIComponent(${JSON.stringify(key)}), {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({error: error instanceof Error ? error.message : String(error)}),
  }),
);
</script>`);
      return;
    }
    response.writeHead(404, this.headers('text/plain; charset=utf-8'));
    response.end('not found');
  }

  handleResult(requestUrl, request, response) {
    const run = requestUrl.searchParams.get('run') ?? '';
    const key = requestUrl.searchParams.get('key') ?? '';
    const pendingKey = `${run}:${key}`;
    const pending = this.pendingResults.get(pendingKey);
    let bytes = 0;
    const chunks = [];
    request.on('data', (chunk) => {
      bytes += chunk.length;
      if (bytes > 2 * 1024 * 1024) {
        request.destroy(new Error('fingerprint result exceeds 2 MiB'));
        return;
      }
      chunks.push(chunk);
    });
    request.on('error', (error) => {
      pending?.reject(error);
    });
    request.on('end', () => {
      if (!pending) {
        response.writeHead(404, this.headers('text/plain; charset=utf-8'));
        response.end('unknown result key');
        return;
      }
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (value?.error) {
          pending.reject(new VerificationError(
            `页面探针 ${key} 失败：${String(value.error)}`,
          ));
        } else {
          assert(value?.report && typeof value.report === 'object',
                 `页面探针 ${key} 缺少 report`);
          pending.resolve(value.report);
        }
        response.writeHead(204, {'cache-control': 'no-store'});
        response.end();
      } catch (error) {
        pending.reject(error);
        response.writeHead(400, this.headers('text/plain; charset=utf-8'));
        response.end('invalid result');
      }
    });
  }

  createBatch(probes, timeoutMs) {
    const run = randomUUID();
    const entries = probes.map((probe) => {
      const pendingKey = `${run}:${probe.key}`;
      let resolveResult;
      let rejectResult;
      const result = new Promise((resolveValue, rejectValue) => {
        resolveResult = resolveValue;
        rejectResult = rejectValue;
      });
      this.pendingResults.set(pendingKey, {
        resolve: resolveResult,
        reject: rejectResult,
      });
      const separator = probe.pathname.includes('?') ? '&' : '?';
      const pathname = `${probe.pathname}${separator}run=${encodeURIComponent(run)}` +
        `&key=${encodeURIComponent(probe.key)}`;
      return {
        key: probe.key,
        url: this.url(probe.host, pathname),
        result,
        pendingKey,
      };
    });
    return {
      urls: entries.map(({url}) => url),
      wait: async () => {
        let timer;
        try {
          return await Promise.race([
            Promise.all(entries.map(async ({key, url, result}) => ({
              key,
              url,
              report: await result,
            }))),
            new Promise((_, reject) => {
              timer = setTimeout(
                () => reject(new VerificationError('等待页面指纹结果超时')),
                timeoutMs,
              );
            }),
          ]);
        } finally {
          clearTimeout(timer);
          for (const {pendingKey} of entries) {
            this.pendingResults.delete(pendingKey);
          }
        }
      },
    };
  }

  async close() {
    if (!this.server.listening) {
      return;
    }
    await new Promise((resolveClose) => this.server.close(resolveClose));
  }
}

async function fetchJson(url, options = {}, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {...options, signal: controller.signal});
    assert(response.ok, `${url} 返回 HTTP ${response.status}`);
    return await response.json();
  } catch (error) {
    if (error?.name === 'AbortError') {
      fail(`访问 ${url} 超时`);
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

class DevToolsEndpoint {
  constructor(port, timeoutMs) {
    this.origin = `http://127.0.0.1:${port}`;
    this.timeoutMs = timeoutMs;
  }

  async version() {
    return fetchJson(`${this.origin}/json/version`, {}, this.timeoutMs);
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

  command(method, params = {}) {
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
      this.socket.send(JSON.stringify({id, method, params}));
    });
  }

  async close() {
    if (this.socket.readyState >= WebSocket.CLOSING) {
      return;
    }
    this.socket.close(1000, 'fingerprint verification complete');
    await delay(50);
  }
}

async function waitForDevToolsPort(
  profileDir,
  browserProcess,
  timeoutMs,
) {
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
    const firstLine = text.split(/\r?\n/u)[0]?.trim();
    const port = Number(firstLine);
    if (Number.isSafeInteger(port) && port > 0 && port <= 65535) {
      return port;
    }
    await delay(POLL_INTERVAL_MS);
  } while (performance.now() < deadline);
  fail('等待 DevToolsActivePort 超时');
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
    return Boolean(
      record && current && record.startedAt === current.startedAt,
    );
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
    return {
      rootPid: this.rootPid,
      rootPgid: this.rootPgid,
      sampled: this.samples,
      discovered: [...this.known.values()].map((record) => ({
        pid: record.pid,
        ppid: record.ppid,
        pgid: record.pgid,
        startedAt: record.startedAt,
        command: record.command,
      })),
      signals: this.signals,
      monitorErrors: this.monitorErrors,
      survivors: survivors.map((record) => ({
        pid: record.pid,
        ppid: record.ppid,
        pgid: record.pgid,
        state: record.state,
        startedAt: record.startedAt,
        command: record.command,
      })),
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
  if (!chromiumExecutable || !profileDir) {
    return {
      performed: false,
      reason: '未提供 executable/profile 绑定',
      survivors: [],
    };
  }
  const profileArgument = `--user-data-dir=${profileDir}`;
  const temporaryRoot = dirname(profileDir);
  const table = await readProcessTable();
  const scopeMatches = [...table.values()].filter(
    (record) =>
      commandHasArgument(record.command, profileArgument) ||
      record.command.includes(profileDir) ||
      record.command.includes(temporaryRoot),
  );
  const exactExecutableMatches = scopeMatches.filter(
    (record) =>
      (record.command === chromiumExecutable ||
        record.command.startsWith(`${chromiumExecutable} `)),
  );
  return {
    performed: true,
    chromiumExecutable,
    profileDir,
    profileArgument,
    temporaryRoot,
    exactExecutableMatches,
    survivors: scopeMatches,
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
  return {
    exitCode: child.exitCode ?? null,
    signalCode: child.signalCode ?? null,
  };
}

async function terminateOwnedProcess(
  child,
  endpoint,
  tracker,
  timing = {},
  ownership = {},
) {
  if (!child || !tracker) {
    return null;
  }
  const gracefulTimeoutMs = timing.gracefulTimeoutMs ?? 8_000;
  const termTimeoutMs = timing.termTimeoutMs ?? 3_000;
  const killTimeoutMs = timing.killTimeoutMs ?? 2_000;
  const observationMs =
    timing.observationMs ?? PROCESS_STABILITY_OBSERVATION_MS;
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
        const client = await CdpClient.connect(
          version.webSocketDebuggerUrl,
          3_000,
        );
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
      // Browser.close 失败时仅终止已跟踪的精确 PID。
    }

    let survivors = await tracker.waitUntilEmpty(
      browserClose.requested ? gracefulTimeoutMs : 0,
    );
    if (survivors.length > 0) {
      await tracker.signalAlive('SIGTERM');
      survivors = await tracker.waitUntilEmpty(termTimeoutMs);
    }
    if (survivors.length > 0) {
      await tracker.signalAlive('SIGKILL');
      survivors = await tracker.waitUntilEmpty(killTimeoutMs);
    }
    if (survivors.length === 0) {
      await delay(observationMs);
      survivors = await tracker.alive();
    }
    const childExit = await waitForChildExitState(child);
    survivors = await tracker.alive();
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
    evidence.browserCloseRequested = browserClose.requested;
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
    evidence.stableObservationMs = observationMs;
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
    /\bFATAL\b|CHECK failed|DCHECK failed|Received signal|Aw, Snap|GPU process (?:crashed|exited unexpectedly)|Render(?:er)? process (?:gone|crashed|exited|terminated)(?: unexpectedly)?|RenderProcessHost.*(?:crash|exited unexpectedly)|Child process .*exited unexpectedly/iu;
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
        continue;
      }
      if (!entry.isFile() || !filenameFilter(entry.name)) {
        continue;
      }
      const metadata = await stat(path);
      artifacts.push({
        path,
        size: metadata.size,
        mtimeMs: Math.trunc(metadata.mtimeMs),
      });
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
  const crashpadRoot = join(
    homedir(),
    'Library',
    'Application Support',
    'Chromium',
    'Crashpad',
  );
  const diagnosticRoots = [
    join(homedir(), 'Library', 'Logs', 'DiagnosticReports'),
    join('/Library', 'Logs', 'DiagnosticReports'),
  ];
  const roots = [
    await listCrashArtifacts(
      crashpadRoot,
      (name) => name.endsWith('.dmp'),
    ),
  ];
  for (const root of diagnosticRoots) {
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

async function readPreferences(profileDir) {
  const path = join(profileDir, 'Default', 'Preferences');
  const text = await readFile(path, 'utf8').catch(() => '');
  if (!text.trim()) {
    return {};
  }
  try {
    return JSON.parse(text);
  } catch {
    fail(`临时 Profile Preferences 不是合法 JSON：${path}`);
  }
}

async function updateAegisPreferences(profileDir, enabled, pausedSites) {
  const defaultDir = join(profileDir, 'Default');
  const path = join(defaultDir, 'Preferences');
  const temporaryPath = `${path}.aegis-fingerprint.tmp`;
  await mkdir(defaultDir, {recursive: true, mode: 0o700});
  const preferences = await readPreferences(profileDir);
  if (!preferences.aegis || typeof preferences.aegis !== 'object') {
    preferences.aegis = {};
  }
  preferences.aegis.fingerprint_guard_enabled = enabled;
  preferences.aegis.paused_sites = pausedSites;
  await writeFile(
    temporaryPath,
    `${JSON.stringify(preferences)}\n`,
    {encoding: 'utf8', mode: 0o600},
  );
  await rename(temporaryPath, path);
}

async function inspectAegisPreferences(profileDir) {
  const preferences = await readPreferences(profileDir);
  const secret = preferences.aegis?.fingerprint_farbling_secret;
  let decodedBytes = 0;
  let secretSha256 = null;
  let secretCanonicalBase64 = false;
  if (typeof secret === 'string' && secret.length > 0) {
    const canonicalBase64Pattern =
      /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u;
    if (secret.length % 4 === 0 && canonicalBase64Pattern.test(secret)) {
      const decoded = Buffer.from(secret, 'base64');
      if (decoded.toString('base64') === secret) {
        decodedBytes = decoded.length;
        secretSha256 = createHash('sha256').update(decoded).digest('hex');
        secretCanonicalBase64 = true;
      }
    }
  }
  return {
    fingerprintGuardEnabled:
      preferences.aegis?.fingerprint_guard_enabled ?? null,
    pausedSites: preferences.aegis?.paused_sites ?? '',
    secretPresent: typeof secret === 'string' && secret.length > 0,
    secretCanonicalBase64,
    secretDecodedBytes: decodedBytes,
    secretSha256,
    secretExpectedBytes: PROFILE_SECRET_BYTES,
  };
}

function modeDefinitions(expiryUnixSeconds) {
  return [
    {
      name: 'enabled-first',
      profileScope: 'primary',
      expectedProtection: true,
      prefEnabled: true,
      pausedSites: '',
      disabledFeatures: [],
      probes: [
        {key: 'probe', host: TEST_HOSTS.probe, pathname: '/probe'},
        {key: 'embed-alpha', host: TEST_HOSTS.embedAlpha, pathname: '/embed'},
        {key: 'embed-beta', host: TEST_HOSTS.embedBeta, pathname: '/embed'},
      ],
    },
    {
      name: 'master-off',
      profileScope: 'primary',
      expectedProtection: false,
      prefEnabled: true,
      pausedSites: '',
      disabledFeatures: ['AegisEnabled'],
      probes: [{key: 'probe', host: TEST_HOSTS.probe, pathname: '/probe'}],
    },
    {
      name: 'subfeature-off',
      profileScope: 'primary',
      expectedProtection: false,
      prefEnabled: true,
      pausedSites: '',
      disabledFeatures: ['AegisFingerprintGuard'],
      probes: [{key: 'probe', host: TEST_HOSTS.probe, pathname: '/probe'}],
    },
    {
      name: 'pref-off',
      profileScope: 'primary',
      expectedProtection: false,
      prefEnabled: false,
      pausedSites: '',
      disabledFeatures: [],
      probes: [{key: 'probe', host: TEST_HOSTS.probe, pathname: '/probe'}],
    },
    {
      name: 'site-pause',
      profileScope: 'primary',
      expectedProtection: 'per-site',
      prefEnabled: true,
      pausedSites: `${TEST_HOSTS.paused}|${expiryUnixSeconds}`,
      disabledFeatures: [],
      probes: [
        {key: 'paused', host: TEST_HOSTS.paused, pathname: '/probe'},
        {key: 'active', host: TEST_HOSTS.active, pathname: '/probe'},
      ],
    },
    {
      name: 'enabled-restart',
      profileScope: 'primary',
      expectedProtection: true,
      prefEnabled: true,
      pausedSites: '',
      disabledFeatures: [],
      probes: [
        {key: 'probe', host: TEST_HOSTS.probe, pathname: '/probe'},
        {key: 'embed-alpha', host: TEST_HOSTS.embedAlpha, pathname: '/embed'},
      ],
    },
    {
      name: 'enabled-other-profile',
      profileScope: 'secondary',
      expectedProtection: true,
      prefEnabled: true,
      pausedSites: '',
      disabledFeatures: [],
      probes: [{key: 'probe', host: TEST_HOSTS.probe, pathname: '/probe'}],
    },
  ];
}

async function runProbeInBrowser(
  mode,
  probe,
  options,
  chromiumExecutable,
  profileDir,
  fixture,
  logsDir,
) {
  await rm(join(profileDir, 'DevToolsActivePort'), {force: true});
  const batch = fixture.createBatch([probe], options.timeoutMs);
  const logPath = join(logsDir, `${mode.name}-${probe.key}.log`);
  const logFd = openSync(logPath, 'w', 0o600);
  const chromiumArgs = [
    `--user-data-dir=${profileDir}`,
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=0',
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
    batch.urls[0],
  ];

  let browserProcess;
  let processTracker;
  let processTermination = null;
  let endpoint;
  let result = null;
  let runError = null;
  try {
    browserProcess = spawn(chromiumExecutable, chromiumArgs, {
      detached: true,
      env: {...process.env},
      stdio: ['ignore', logFd, logFd],
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
    await endpoint.version();

    [result] = await batch.wait();
  } catch (error) {
    runError = error instanceof Error ? error.message : String(error);
  } finally {
    try {
      processTermination = await terminateOwnedProcess(
        browserProcess,
        endpoint,
        processTracker,
        {},
        {chromiumExecutable, profileDir},
      );
    } finally {
      closeSync(logFd);
    }
  }

  const logBytes = await readFile(logPath);
  const logText = logBytes.toString('utf8');
  return {
    key: probe.key,
    result,
    error: runError,
    fatalSignals: findFatalSignals(logText),
    browserExitCode: browserProcess?.exitCode ?? null,
    browserSignal: browserProcess?.signalCode ?? null,
    processTermination,
    log: {
      name: basename(logPath),
      size: logBytes.length,
      sha256: createHash('sha256').update(logBytes).digest('hex'),
    },
  };
}

async function runMode(
  mode,
  options,
  chromiumExecutable,
  profileDir,
  fixture,
  logsDir,
) {
  await updateAegisPreferences(
    profileDir,
    mode.prefEnabled,
    mode.pausedSites,
  );
  const probes = {};
  const browserRuns = [];
  const fatalSignals = [];
  const startedAt = new Date().toISOString();
  let runError = null;
  for (const probe of mode.probes) {
    const browserRun = await runProbeInBrowser(
      mode,
      probe,
      options,
      chromiumExecutable,
      profileDir,
      fixture,
      logsDir,
    );
    browserRuns.push(browserRun);
    fatalSignals.push(...browserRun.fatalSignals);
    if (browserRun.result) {
      probes[browserRun.result.key] = browserRun.result;
    }
    if (browserRun.error) {
      runError = `${probe.key}: ${browserRun.error}`;
      break;
    }
  }

  const preferences = await inspectAegisPreferences(profileDir);
  return {
    name: mode.name,
    profileScope: mode.profileScope,
    expectedProtection: mode.expectedProtection,
    prefEnabled: mode.prefEnabled,
    pausedSites: mode.pausedSites,
    disabledFeatures: mode.disabledFeatures,
    startedAt,
    finishedAt: new Date().toISOString(),
    browserRuns,
    fatalSignals,
    error: runError,
    preferences,
    probes,
  };
}

function canonical(value) {
  return JSON.stringify(value);
}

function webglIdentity(report) {
  return {
    supported: report?.supported ?? false,
    debugExtensionAdvertised: report?.debugExtensionAdvertised ?? false,
    debugInfoAvailable: report?.debugInfoAvailable ?? false,
    vendor: report?.vendor ?? '',
    renderer: report?.renderer ?? '',
  };
}

function webgpuIdentity(report) {
  return {
    supported: report?.supported ?? false,
    info: report?.info ?? null,
    limits: report?.limits ?? null,
    features: report?.features ?? null,
    device: report?.device?.supported
      ? {supported: true, limits: report.device.limits}
      : report?.device ?? null,
    requiredLimitRejections: Object.fromEntries(
      Object.entries(report?.requiredLimitRejections ?? {}).map(
        ([name, attempt]) => [
          name,
          {
            requested: attempt.requested,
            rejected: attempt.rejected,
            expectedRejection: attempt.expectedRejection,
            errorName: attempt.errorName ?? '',
          },
        ],
      ),
    ),
  };
}

function offscreenCanvasIdentity(report) {
  return {
    supported: report?.supported ?? false,
    coverage: report?.coverage ?? 'not-run',
    convertToBlob: report?.convertToBlob?.supported
      ? {
          supported: true,
          firstHash: report.convertToBlob.firstHash,
        }
      : report?.convertToBlob ?? null,
    transferToImageBitmap: report?.transferToImageBitmap?.supported
      ? {
          supported: true,
          firstHash: report.transferToImageBitmap.firstHash,
        }
      : report?.transferToImageBitmap ?? null,
  };
}

function stableFingerprint(report) {
  return {
    canvas: report?.canvas?.supported
      ? {
          firstReadHash: report.canvas.firstReadHash,
          firstDataUrlHash: report.canvas.firstDataUrlHash,
          firstBlobHash: report.canvas.firstBlobHash,
          rgbaFloat16: report.canvas.rgbaFloat16?.supported
            ? {
                supported: true,
                firstReadHash: report.canvas.rgbaFloat16.firstReadHash,
              }
            : report.canvas.rgbaFloat16,
        }
      : report?.canvas,
    audio: report?.audio?.supported
      ? {
          firstReadHash: report.audio.firstReadHash,
          afterWriteHash: report.audio.afterWriteHash,
        }
      : report?.audio,
    offscreenCanvas: offscreenCanvasIdentity(report?.offscreenCanvas),
    webgl: webglIdentity(report?.webgl),
    webgpu: webgpuIdentity(report?.webgpu),
  };
}

function addAssertion(assertions, name, passed, details = null) {
  assertions.push({
    name,
    passed: Boolean(passed),
    ...(details === null ? {} : {details}),
  });
}

function containsProductMarker(value) {
  return /aegis/iu.test(canonical(value));
}

function numericLimitAtMost(value, actual) {
  try {
    return BigInt(value) <= BigInt(actual);
  } catch {
    return false;
  }
}

function numericLimitAtLeast(value, required) {
  try {
    return BigInt(value) >= BigInt(required);
  } catch {
    return false;
  }
}

function expectedWebGpuLimitRejection(attempt) {
  return Boolean(
    attempt?.rejected === true &&
      attempt.expectedRejection === true &&
      attempt.isDomException === true &&
      attempt.errorName === 'OperationError' &&
      attempt.errorConstructor === 'DOMException' &&
      /limit/iu.test(attempt.error ?? '') &&
      /exceed|greater|supported|unsupported|maximum/iu.test(
        attempt.error ?? '',
      ),
  );
}

function workerCanvasProtected(report) {
  return Boolean(
    report?.supported === true &&
      report.coverage === 'covered' &&
      report.firstReadHash &&
      report.firstReadHash === report.secondReadHash &&
      report.firstReadHash !== report.inputHash,
  );
}

function addPartitionedWorkerAssertions(
  assertions,
  workerLabel,
  alpha,
  beta,
  alphaRestart,
) {
  addAssertion(
    assertions,
    `${workerLabel}: alpha/beta/重启 OffscreenCanvas 均受保护`,
    workerCanvasProtected(alpha) &&
      workerCanvasProtected(beta) &&
      workerCanvasProtected(alphaRestart),
    {alpha, beta, alphaRestart},
  );
  addAssertion(
    assertions,
    `${workerLabel}: 同一 alpha 顶层分区跨重启稳定`,
    Boolean(alpha?.firstReadHash) &&
      alpha.firstReadHash === alphaRestart?.firstReadHash,
  );
  addAssertion(
    assertions,
    `${workerLabel}: 不同顶层分区隔离`,
    Boolean(alpha?.firstReadHash) &&
      Boolean(beta?.firstReadHash) &&
      alpha.firstReadHash !== beta.firstReadHash,
  );
}

function addCommonSurfaceAssertions(assertions, label, report, requireWebGPU) {
  addAssertion(
    assertions,
    `${label}: Canvas 可用`,
    report?.canvas?.supported === true,
    report?.canvas?.error ?? null,
  );
  addAssertion(
    assertions,
    `${label}: Canvas 同页重复稳定`,
    report?.canvas?.supported === true &&
      report.canvas.firstReadHash === report.canvas.secondReadHash &&
      report.canvas.firstDataUrlHash === report.canvas.secondDataUrlHash &&
      report.canvas.firstBlobHash === report.canvas.secondBlobHash,
  );
  addAssertion(
    assertions,
    `${label}: Canvas rgba-float16 能力已显式记录`,
    typeof report?.canvas?.rgbaFloat16?.supported === 'boolean' &&
      (report.canvas.rgbaFloat16.supported ||
        Boolean(report.canvas.rgbaFloat16.error)),
    report?.canvas?.rgbaFloat16 ?? null,
  );
  if (report?.canvas?.rgbaFloat16?.supported) {
    addAssertion(
      assertions,
      `${label}: Canvas rgba-float16 同页重复稳定`,
      report.canvas.rgbaFloat16.firstReadHash ===
        report.canvas.rgbaFloat16.secondReadHash,
    );
  }
  addAssertion(
    assertions,
    `${label}: OffscreenCanvas 导出能力已显式记录`,
    typeof report?.offscreenCanvas?.supported === 'boolean' &&
      (report.offscreenCanvas.supported ||
        (report.offscreenCanvas.coverage === 'not-covered' &&
          Boolean(report.offscreenCanvas.reasonCode))),
    report?.offscreenCanvas ?? null,
  );
  if (report?.offscreenCanvas?.supported) {
    for (const name of ['convertToBlob', 'transferToImageBitmap']) {
      const surface = report.offscreenCanvas[name];
      addAssertion(
        assertions,
        `${label}: OffscreenCanvas.${name} 能力已显式记录`,
        typeof surface?.supported === 'boolean' &&
          (surface.supported ||
            (surface.coverage === 'not-covered' &&
              Boolean(surface.reasonCode))),
        surface ?? null,
      );
      if (surface?.supported) {
        addAssertion(
          assertions,
          `${label}: OffscreenCanvas.${name} 同页重复稳定`,
          surface.firstHash === surface.secondHash,
        );
      }
    }
  }
  addAssertion(
    assertions,
    `${label}: Audio 可用`,
    report?.audio?.supported === true,
    report?.audio?.error ?? null,
  );
  addAssertion(
    assertions,
    `${label}: Audio 同页重复稳定`,
    report?.audio?.supported === true &&
      report.audio.firstReadHash === report.audio.secondReadHash,
  );
  addAssertion(
    assertions,
    `${label}: WebGL 可用`,
    report?.webgl?.supported === true,
    report?.webgl?.error ?? null,
  );
  addAssertion(
    assertions,
    `${label}: WebGL 无产品标记`,
    report?.webgl?.supported === true && !containsProductMarker(report.webgl),
  );
  addAssertion(
    assertions,
    `${label}: WebGPU 能力已记录`,
    report?.webgpu && typeof report.webgpu.supported === 'boolean',
  );
  if (requireWebGPU) {
    addAssertion(
      assertions,
      `${label}: WebGPU 可用`,
      report?.webgpu?.supported === true,
      report?.webgpu?.error ?? null,
    );
  }
  if (report?.webgpu?.supported) {
    addAssertion(
      assertions,
      `${label}: WebGPU 无产品标记`,
      !containsProductMarker(report.webgpu),
    );
    addAssertion(
      assertions,
      `${label}: WebGPU device 可创建且 limits 已记录`,
      report.webgpu.device?.supported === true &&
        typeof report.webgpu.device.limits?.maxBufferSize === 'string',
      report.webgpu.device ?? null,
    );
    for (const name of Object.keys(WEBGPU_BUCKETS)) {
      const attempt = report.webgpu.requiredLimitRejections?.[name];
      addAssertion(
        assertions,
        `${label}: WebGPU ${name} 超公开值 requiredLimits 被拒绝`,
        expectedWebGpuLimitRejection(attempt) &&
          Number.isSafeInteger(attempt.requested) &&
          String(attempt.requested - 1) === report.webgpu.limits?.[name],
        attempt ?? null,
      );
    }
  }
}

function addRawAssertions(
  assertions,
  label,
  report,
  baseline,
  requireWebGPU,
) {
  addCommonSurfaceAssertions(assertions, label, report, requireWebGPU);
  addAssertion(
    assertions,
    `${label}: Canvas 返回原始输入`,
    report?.canvas?.supported === true &&
      report.canvas.firstReadHash === report.canvas.inputHash,
  );
  addAssertion(
    assertions,
    `${label}: Audio 返回原始输入`,
    report?.audio?.supported === true &&
      report.audio.firstReadHash === report.audio.firstInputHash &&
      report.audio.afterWriteHash === report.audio.secondInputHash,
  );
  if (report?.canvas?.rgbaFloat16?.supported) {
    addAssertion(
      assertions,
      `${label}: Canvas rgba-float16 返回 raw 基线`,
      !baseline ||
        report.canvas.rgbaFloat16.firstReadHash ===
          baseline?.canvas?.rgbaFloat16?.firstReadHash,
    );
  }
  if (report?.webgpu?.supported) {
    for (const name of Object.keys(WEBGPU_BUCKETS)) {
      const actual = Number(report.webgpu.limits?.[name]);
      const bucketValues = [...WEBGPU_BUCKETS[name]].map(Number).sort(
        (left, right) => left - right,
      );
      const bucket = bucketValues.filter((value) => value <= actual).at(-1);
      const shouldTest = Number.isSafeInteger(bucket) && bucket + 1 <= actual;
      const control = report.webgpu.rawBucketControls?.[name];
      addAssertion(
        assertions,
        `${label}: WebGPU ${name} raw 硬件控制已记录`,
        shouldTest
          ? control?.tested === true &&
            control.accepted === true &&
            control.requested === bucket + 1 &&
            numericLimitAtLeast(control.deviceLimit, control.requested) &&
            numericLimitAtMost(control.deviceLimit, actual)
          : control?.tested === false &&
            control.reasonCode ===
              'no-hardware-headroom-above-protected-bucket',
        control ?? null,
      );
    }
  }
  if (baseline) {
    addAssertion(
      assertions,
      `${label}: Canvas 与 raw 基线一致`,
      report?.canvas?.firstReadHash === baseline?.canvas?.firstReadHash &&
        report?.canvas?.firstDataUrlHash === baseline?.canvas?.firstDataUrlHash &&
        report?.canvas?.firstBlobHash === baseline?.canvas?.firstBlobHash,
    );
    addAssertion(
      assertions,
      `${label}: Audio 与 raw 基线一致`,
      report?.audio?.firstReadHash === baseline?.audio?.firstReadHash &&
        report?.audio?.afterWriteHash === baseline?.audio?.afterWriteHash,
    );
    addAssertion(
      assertions,
      `${label}: OffscreenCanvas 导出与 raw 基线一致`,
      canonical(offscreenCanvasIdentity(report?.offscreenCanvas)) ===
        canonical(offscreenCanvasIdentity(baseline?.offscreenCanvas)),
    );
    addAssertion(
      assertions,
      `${label}: WebGL 与 raw 基线一致`,
      canonical(webglIdentity(report?.webgl)) ===
        canonical(webglIdentity(baseline?.webgl)),
    );
    if (baseline?.webgpu?.supported) {
      addAssertion(
        assertions,
        `${label}: WebGPU 与 raw 基线一致`,
        canonical(webgpuIdentity(report?.webgpu)) ===
          canonical(webgpuIdentity(baseline?.webgpu)),
      );
    }
  }
}

function addProtectedAssertions(
  assertions,
  label,
  report,
  rawBaseline,
  requireWebGPU,
) {
  addCommonSurfaceAssertions(assertions, label, report, requireWebGPU);
  addAssertion(
    assertions,
    `${label}: Canvas 已扰动`,
    report?.canvas?.supported === true &&
      report.canvas.firstReadHash !== report.canvas.inputHash &&
      report.canvas.firstDataUrlHash !== rawBaseline?.canvas?.firstDataUrlHash &&
      report.canvas.firstBlobHash !== rawBaseline?.canvas?.firstBlobHash,
  );
  addAssertion(
    assertions,
    `${label}: Audio 已扰动`,
    report?.audio?.supported === true &&
      report.audio.firstReadHash !== report.audio.firstInputHash,
  );
  addAssertion(
    assertions,
    `${label}: Audio 写后精确保留脚本输入`,
    report?.audio?.supported === true &&
      report.audio.afterWriteHash === report.audio.secondInputHash,
  );
  if (rawBaseline?.canvas?.rgbaFloat16?.supported) {
    addAssertion(
      assertions,
      `${label}: Canvas rgba-float16 已扰动`,
      report?.canvas?.rgbaFloat16?.supported === true &&
        report.canvas.rgbaFloat16.firstReadHash !==
          rawBaseline.canvas.rgbaFloat16.firstReadHash,
      report?.canvas?.rgbaFloat16 ?? null,
    );
  }

  for (const name of ['convertToBlob', 'transferToImageBitmap']) {
    if (rawBaseline?.offscreenCanvas?.[name]?.supported) {
      addAssertion(
        assertions,
        `${label}: OffscreenCanvas.${name} 已扰动`,
        report?.offscreenCanvas?.[name]?.supported === true &&
          report.offscreenCanvas[name].firstHash !==
            rawBaseline.offscreenCanvas[name].firstHash,
        {
          raw: rawBaseline.offscreenCanvas[name],
          protected: report?.offscreenCanvas?.[name] ?? null,
        },
      );
    }
  }

  if (rawBaseline?.webgl?.supported && rawBaseline.webgl.debugInfoAvailable) {
    addAssertion(
      assertions,
      `${label}: WebGL debug renderer 扩展已隐藏`,
      report?.webgl?.supported === true &&
        report.webgl.debugExtensionAdvertised === false &&
        report.webgl.debugInfoAvailable === false &&
        report.webgl.vendor === '' &&
        report.webgl.renderer === '',
      webglIdentity(report?.webgl),
    );
  }

  if (report?.webgpu?.supported) {
    const limits = report.webgpu.limits ?? {};
    addAssertion(
      assertions,
      `${label}: WebGPU maxBufferSize 属于固定桶`,
      WEBGPU_BUCKETS.maxBufferSize.has(limits.maxBufferSize) &&
        numericLimitAtMost(
          limits.maxBufferSize,
          rawBaseline?.webgpu?.limits?.maxBufferSize,
        ),
      {
        actual: rawBaseline?.webgpu?.limits?.maxBufferSize,
        exposed: limits.maxBufferSize,
      },
    );
    addAssertion(
      assertions,
      `${label}: WebGPU workgroup storage 属于固定桶`,
      WEBGPU_BUCKETS.maxComputeWorkgroupStorageSize.has(
        limits.maxComputeWorkgroupStorageSize,
      ) &&
        numericLimitAtMost(
          limits.maxComputeWorkgroupStorageSize,
          rawBaseline?.webgpu?.limits?.maxComputeWorkgroupStorageSize,
        ),
      {
        actual:
          rawBaseline?.webgpu?.limits?.maxComputeWorkgroupStorageSize,
        exposed: limits.maxComputeWorkgroupStorageSize,
      },
    );
    addAssertion(
      assertions,
      `${label}: WebGPU texture3D 属于固定桶`,
      WEBGPU_BUCKETS.maxTextureDimension3D.has(
        limits.maxTextureDimension3D,
      ) &&
        numericLimitAtMost(
          limits.maxTextureDimension3D,
          rawBaseline?.webgpu?.limits?.maxTextureDimension3D,
        ),
      {
        actual: rawBaseline?.webgpu?.limits?.maxTextureDimension3D,
        exposed: limits.maxTextureDimension3D,
      },
    );
    const info = report.webgpu.info ?? {};
    const identifyingInfoValues = [
      info.vendor,
      info.architecture,
      info.device,
      info.description,
      info.driver,
    ];
    addAssertion(
      assertions,
      `${label}: WebGPU adapter 字符串已隐藏`,
      identifyingInfoValues.every((value) => value === ''),
      info,
    );
    addAssertion(
      assertions,
      `${label}: WebGPU subgroup 能力已隐藏`,
      [
        'subgroups',
        'subgroup-size-control',
        'chromium-experimental-subgroup-matrix',
        'subgroup-matrix',
      ].every((feature) =>
        !(report.webgpu.features ?? []).includes(feature),
      ),
      report.webgpu.features ?? null,
    );
    addAssertion(
      assertions,
      `${label}: WebGPU subgroup 范围固定为合规人口值`,
      info.subgroupMinSize === '4' &&
        info.subgroupMaxSize === '128' &&
        limits.minSubgroupSize === '4' &&
        limits.maxSubgroupSize === '128',
      {
        info,
        limits,
      },
    );
    const deviceLimits = report.webgpu.device?.limits ?? {};
    const requestedLimits = report.webgpu.device?.requestedLimits ?? {};
    addAssertion(
      assertions,
      `${label}: WebGPU device.limits 不越过公开上限且满足请求`,
      report.webgpu.device?.supported === true &&
        Object.keys(WEBGPU_BUCKETS).every(
          (name) =>
            numericLimitAtLeast(deviceLimits[name], requestedLimits[name]) &&
            numericLimitAtMost(deviceLimits[name], limits[name]),
        ),
      {adapter: limits, requested: requestedLimits, device: deviceLimits},
    );
  }
}

function expectedTerminationEvidence(termination) {
  if (
    !termination ||
    termination.browserClose?.attempted !== true ||
    termination.browserClose?.requested !== true
  ) {
    return false;
  }
  if (termination.terminationMethod === 'browser-close') {
    return (
      termination.exitCode === 0 || termination.signalCode === 'SIGTERM'
    );
  }
  if (termination.terminationMethod === 'controlled-sigterm') {
    return (
      termination.signals?.some(
        (entry) =>
          entry.signal === 'SIGTERM' &&
          entry.sent?.includes(termination.rootPid),
      ) &&
      (termination.signalCode === 'SIGTERM' || termination.exitCode === 0)
    );
  }
  if (termination.terminationMethod === 'controlled-sigkill') {
    return (
      termination.signalCode === 'SIGKILL' &&
      termination.signals?.some(
        (entry) =>
          entry.signal === 'SIGKILL' &&
          entry.sent?.includes(termination.rootPid),
      )
    );
  }
  return false;
}

function validateMatrix(modes, options) {
  const assertions = [];
  const byName = new Map(modes.map((mode) => [mode.name, mode]));
  const requiredProbePaths = [
    ['master-off', 'probe'],
    ['subfeature-off', 'probe'],
    ['pref-off', 'probe'],
    ['site-pause', 'paused'],
  ];
  for (const [modeName, probeName] of requiredProbePaths) {
    addAssertion(
      assertions,
      `${modeName}/${probeName}: 必需探针存在`,
      Boolean(byName.get(modeName)?.probes?.[probeName]?.report),
    );
  }
  for (const mode of modes) {
    addAssertion(
      assertions,
      `${mode.name}: 浏览器运行完成`,
      !mode.error,
      mode.error,
    );
    addAssertion(
      assertions,
      `${mode.name}: 无 FATAL/CHECK/进程异常退出日志`,
      mode.fatalSignals.length === 0,
      mode.fatalSignals,
    );
    addAssertion(
      assertions,
      `${mode.name}: 每个探针都有浏览器运行证据`,
      Object.keys(mode.probes ?? {}).length > 0 &&
        Object.keys(mode.probes ?? {}).every((key) =>
          (mode.browserRuns ?? []).some((run) => run.key === key),
        ),
      {probeKeys: Object.keys(mode.probes ?? {}), browserRuns: mode.browserRuns},
    );
    for (const browserRun of mode.browserRuns ?? []) {
      const termination = browserRun.processTermination;
      addAssertion(
        assertions,
        `${mode.name}/${browserRun.key}: 进程树退出证据完整`,
        Boolean(termination) &&
          termination.rootPgid === termination.rootPid &&
          Array.isArray(termination.discovered) &&
          termination.discovered.some(
            (record) => record.pid === termination.rootPid,
          ) &&
          termination.survivors?.length === 0 &&
          termination.monitorErrors?.length === 0 &&
          termination.ownershipScan?.performed === true &&
          termination.ownershipScan.survivors?.length === 0 &&
          termination.stableObservationMs > 0,
        termination ?? null,
      );
      addAssertion(
        assertions,
        `${mode.name}/${browserRun.key}: Browser.close 与退出状态受控`,
        expectedTerminationEvidence(termination) &&
          browserRun.browserExitCode === termination.exitCode &&
          browserRun.browserSignal === termination.signalCode,
        termination ?? null,
      );
      addAssertion(
        assertions,
        `${mode.name}/${browserRun.key}: 日志摘要已固化`,
        Number.isSafeInteger(browserRun.log?.size) &&
          browserRun.log.size >= 0 &&
          /^[a-f0-9]{64}$/u.test(browserRun.log?.sha256 ?? '') &&
          typeof browserRun.log?.name === 'string' &&
          !('logPath' in browserRun),
        browserRun.log ?? null,
      );
    }
  }

  const rawBaseline = byName.get('pref-off')?.probes?.probe?.report;
  addAssertion(assertions, '存在 pref-off raw 基线', Boolean(rawBaseline));
  if (!rawBaseline) {
    return assertions;
  }

  addRawAssertions(
    assertions,
    'pref-off',
    rawBaseline,
    null,
    options.requireWebGPU,
  );
  for (const name of ['master-off', 'subfeature-off']) {
    const report = byName.get(name)?.probes?.probe?.report;
    if (report) {
      addRawAssertions(
        assertions,
        name,
        report,
        rawBaseline,
        options.requireWebGPU,
      );
    }
  }

  const pausedReport = byName.get('site-pause')?.probes?.paused?.report;
  if (pausedReport) {
    addRawAssertions(
      assertions,
      'site-pause/paused',
      pausedReport,
      rawBaseline,
      options.requireWebGPU,
    );
  }

  const enabledFirst = byName.get('enabled-first')?.probes?.probe?.report;
  const enabledRestart = byName.get('enabled-restart')?.probes?.probe?.report;
  const otherProfile =
    byName.get('enabled-other-profile')?.probes?.probe?.report;
  const activeReport = byName.get('site-pause')?.probes?.active?.report;
  if (enabledFirst) {
    addProtectedAssertions(
      assertions,
      'enabled-first',
      enabledFirst,
      rawBaseline,
      options.requireWebGPU,
    );
  }
  if (enabledRestart) {
    addProtectedAssertions(
      assertions,
      'enabled-restart',
      enabledRestart,
      rawBaseline,
      options.requireWebGPU,
    );
  }
  if (activeReport) {
    addProtectedAssertions(
      assertions,
      'site-pause/active',
      activeReport,
      rawBaseline,
      options.requireWebGPU,
    );
  }
  if (otherProfile) {
    addProtectedAssertions(
      assertions,
      'enabled-other-profile',
      otherProfile,
      rawBaseline,
      options.requireWebGPU,
    );
  }

  addAssertion(
    assertions,
    '同一 Profile 重启后的完整指纹稳定',
    Boolean(enabledFirst) &&
      Boolean(enabledRestart) &&
      canonical(stableFingerprint(enabledFirst)) ===
        canonical(stableFingerprint(enabledRestart)),
  );
  addAssertion(
    assertions,
    '不同顶层站点的 Canvas token 隔离',
    Boolean(enabledFirst?.canvas?.firstReadHash) &&
      Boolean(activeReport?.canvas?.firstReadHash) &&
      enabledFirst.canvas.firstReadHash !== activeReport.canvas.firstReadHash,
  );
  addAssertion(
    assertions,
    '不同顶层站点的 Audio token 隔离',
    Boolean(enabledFirst?.audio?.firstReadHash) &&
      Boolean(activeReport?.audio?.firstReadHash) &&
      enabledFirst.audio.firstReadHash !== activeReport.audio.firstReadHash,
  );

  const alphaFrame = byName.get('enabled-first')?.probes?.['embed-alpha']?.report;
  const betaFrame = byName.get('enabled-first')?.probes?.['embed-beta']?.report;
  const alphaFrameRestart =
    byName.get('enabled-restart')?.probes?.['embed-alpha']?.report;
  addAssertion(
    assertions,
    'alpha 分区显式记录顶层与 iframe hostname',
    alphaFrame?.topLevelHostname === TEST_HOSTS.embedAlpha &&
      alphaFrame?.iframeHostname === TEST_HOSTS.frame &&
      alphaFrame?.hostname === TEST_HOSTS.frame,
    alphaFrame
      ? {
          topLevelHostname: alphaFrame.topLevelHostname,
          iframeHostname: alphaFrame.iframeHostname,
          reportHostname: alphaFrame.hostname,
        }
      : null,
  );
  addAssertion(
    assertions,
    'beta 分区显式记录顶层与 iframe hostname',
    betaFrame?.topLevelHostname === TEST_HOSTS.embedBeta &&
      betaFrame?.iframeHostname === TEST_HOSTS.frame &&
      betaFrame?.hostname === TEST_HOSTS.frame,
    betaFrame
      ? {
          topLevelHostname: betaFrame.topLevelHostname,
          iframeHostname: betaFrame.iframeHostname,
          reportHostname: betaFrame.hostname,
        }
      : null,
  );
  addAssertion(
    assertions,
    '同一第三方 frame 按不同顶层站点隔离 Canvas',
    Boolean(alphaFrame?.canvas?.firstReadHash) &&
      Boolean(betaFrame?.canvas?.firstReadHash) &&
      alphaFrame.canvas.firstReadHash !== betaFrame.canvas.firstReadHash,
  );
  addAssertion(
    assertions,
    '同一第三方 frame 按不同顶层站点隔离 Audio',
    Boolean(alphaFrame?.audio?.firstReadHash) &&
      Boolean(betaFrame?.audio?.firstReadHash) &&
      alphaFrame.audio.firstReadHash !== betaFrame.audio.firstReadHash,
  );
  for (const name of ['convertToBlob', 'transferToImageBitmap']) {
    if (rawBaseline?.offscreenCanvas?.[name]?.supported) {
      addAssertion(
        assertions,
        `同一第三方 frame 按不同顶层站点隔离 OffscreenCanvas.${name}`,
        Boolean(alphaFrame?.offscreenCanvas?.[name]?.firstHash) &&
          Boolean(betaFrame?.offscreenCanvas?.[name]?.firstHash) &&
          alphaFrame.offscreenCanvas[name].firstHash !==
            betaFrame.offscreenCanvas[name].firstHash,
      );
    }
  }
  addAssertion(
    assertions,
    '同一 alpha 顶层分区跨重启稳定',
    Boolean(alphaFrame) &&
      Boolean(alphaFrameRestart) &&
      alphaFrameRestart.topLevelHostname === TEST_HOSTS.embedAlpha &&
      alphaFrameRestart.iframeHostname === TEST_HOSTS.frame &&
      canonical(stableFingerprint(alphaFrame)) ===
        canonical(stableFingerprint(alphaFrameRestart)),
  );
  addAssertion(
    assertions,
    'iframe Worker 探针已执行',
    alphaFrame?.workers?.tested === true &&
      betaFrame?.workers?.tested === true &&
      alphaFrameRestart?.workers?.tested === true,
    {
      alpha: alphaFrame?.workers,
      beta: betaFrame?.workers,
      alphaRestart: alphaFrameRestart?.workers,
    },
  );
  addPartitionedWorkerAssertions(
    assertions,
    'DedicatedWorker',
    alphaFrame?.workers?.dedicated,
    betaFrame?.workers?.dedicated,
    alphaFrameRestart?.workers?.dedicated,
  );
  addPartitionedWorkerAssertions(
    assertions,
    'SharedWorker',
    alphaFrame?.workers?.shared,
    betaFrame?.workers?.shared,
    alphaFrameRestart?.workers?.shared,
  );
  const serviceWorkerReports = [
    alphaFrame?.workers?.service,
    betaFrame?.workers?.service,
    alphaFrameRestart?.workers?.service,
  ];
  addAssertion(
    assertions,
    'ServiceWorker OffscreenCanvas 覆盖状态已显式记录',
    serviceWorkerReports.every(
      (entry) =>
        typeof entry?.supported === 'boolean' &&
        (entry.coverage === 'covered' || entry.coverage === 'not-covered'),
    ),
    serviceWorkerReports,
  );
  if (serviceWorkerReports[0]?.supported) {
    addPartitionedWorkerAssertions(
      assertions,
      'ServiceWorker',
      serviceWorkerReports[0],
      serviceWorkerReports[1],
      serviceWorkerReports[2],
    );
  } else {
    const allowedReasonCodes = new Set([
      'offscreen-canvas-unavailable',
      'offscreen-2d-context-unavailable',
    ]);
    const signatures = serviceWorkerReports.map((entry) =>
      canonical({
        reasonCode: entry?.reasonCode ?? '',
        errorName: entry?.errorName ?? '',
        error: entry?.error ?? '',
      }),
    );
    addAssertion(
      assertions,
      'ServiceWorker OffscreenCanvas 仅因明确能力缺失而未覆盖',
      serviceWorkerReports.every(
        (entry) =>
          entry?.supported === false &&
          entry.coverage === 'not-covered' &&
          allowedReasonCodes.has(entry.reasonCode) &&
          entry.errorName === 'NotSupportedError' &&
          Boolean(entry.error),
      ),
      serviceWorkerReports,
    );
    addAssertion(
      assertions,
      'ServiceWorker OffscreenCanvas 未覆盖错误类型与原因一致',
      signatures.length === 3 &&
        signatures.every((signature) => signature === signatures[0]),
      serviceWorkerReports,
    );
  }
  if (rawBaseline?.canvas?.rgbaFloat16?.supported) {
    addAssertion(
      assertions,
      '同一第三方 frame 按不同顶层站点隔离 rgba-float16',
      Boolean(alphaFrame?.canvas?.rgbaFloat16?.firstReadHash) &&
        Boolean(betaFrame?.canvas?.rgbaFloat16?.firstReadHash) &&
        alphaFrame.canvas.rgbaFloat16.firstReadHash !==
          betaFrame.canvas.rgbaFloat16.firstReadHash,
    );
  }

  addAssertion(
    assertions,
    '不同 Profile 隔离 Canvas 与 Audio token',
    Boolean(enabledFirst?.canvas?.firstReadHash) &&
      Boolean(otherProfile?.canvas?.firstReadHash) &&
      enabledFirst.canvas.firstReadHash !== otherProfile.canvas.firstReadHash &&
      enabledFirst.audio.firstReadHash !== otherProfile.audio.firstReadHash,
  );
  if (rawBaseline?.canvas?.rgbaFloat16?.supported) {
    addAssertion(
      assertions,
      '不同 Profile 隔离 Canvas rgba-float16 token',
      Boolean(enabledFirst?.canvas?.rgbaFloat16?.firstReadHash) &&
        Boolean(otherProfile?.canvas?.rgbaFloat16?.firstReadHash) &&
        enabledFirst.canvas.rgbaFloat16.firstReadHash !==
          otherProfile.canvas.rgbaFloat16.firstReadHash,
    );
  }
  for (const name of ['convertToBlob', 'transferToImageBitmap']) {
    if (rawBaseline?.offscreenCanvas?.[name]?.supported) {
      addAssertion(
        assertions,
        `不同 Profile 隔离 OffscreenCanvas.${name} token`,
        Boolean(enabledFirst?.offscreenCanvas?.[name]?.firstHash) &&
          Boolean(otherProfile?.offscreenCanvas?.[name]?.firstHash) &&
          enabledFirst.offscreenCanvas[name].firstHash !==
            otherProfile.offscreenCanvas[name].firstHash,
      );
    }
  }

  const firstPrefs = byName.get('enabled-first')?.preferences;
  const restartPrefs = byName.get('enabled-restart')?.preferences;
  const otherProfilePrefs = byName.get('enabled-other-profile')?.preferences;
  addAssertion(
    assertions,
    'Profile farbling secret 已持久化且长度正确',
    firstPrefs?.secretPresent === true &&
      restartPrefs?.secretPresent === true &&
      otherProfilePrefs?.secretPresent === true &&
      firstPrefs.secretCanonicalBase64 === true &&
      restartPrefs.secretCanonicalBase64 === true &&
      otherProfilePrefs.secretCanonicalBase64 === true &&
      firstPrefs.secretDecodedBytes === PROFILE_SECRET_BYTES &&
      restartPrefs.secretDecodedBytes === PROFILE_SECRET_BYTES &&
      otherProfilePrefs.secretDecodedBytes === PROFILE_SECRET_BYTES &&
      firstPrefs.secretSha256 === restartPrefs.secretSha256 &&
      firstPrefs.secretSha256 !== otherProfilePrefs.secretSha256,
    {
      first: firstPrefs,
      restart: restartPrefs,
      otherProfile: otherProfilePrefs,
    },
  );
  return assertions;
}

async function runVerification(
  options,
  browserEvidence,
  crashBefore,
  sourceArtifactBindingBefore,
) {
  assert(typeof WebSocket === 'function', '当前 Node 不提供原生 WebSocket');
  const startedAt = new Date().toISOString();
  const startedEpoch = Math.floor(Date.now() / 1000 / (7 * 24 * 60 * 60));
  const tempRoot = await mkdtemp(join(tmpdir(), 'aegis-fingerprint-runtime-'));
  const primaryProfileDir = join(tempRoot, 'profile-primary');
  const secondaryProfileDir = join(tempRoot, 'profile-secondary');
  const logsDir = join(tempRoot, 'logs');
  await mkdir(primaryProfileDir, {recursive: true, mode: 0o700});
  await mkdir(secondaryProfileDir, {recursive: true, mode: 0o700});
  await mkdir(logsDir, {recursive: true, mode: 0o700});
  const fixture = new FingerprintFixtureServer();
  const modes = [];
  let unexpectedError = null;
  try {
    await fixture.start();
    const health = await fetchJson(fixture.loopbackUrl('/health'));
    assert(health?.ok === true, '指纹 fixture health 失败');
    const expiry = Math.floor(Date.now() / 1000) + 3_600;
    for (const mode of modeDefinitions(expiry)) {
      const profileDir =
        mode.profileScope === 'secondary'
          ? secondaryProfileDir
          : primaryProfileDir;
      const result = await runMode(
        mode,
        options,
        browserEvidence.executable.path,
        profileDir,
        fixture,
        logsDir,
      );
      modes.push(result);
      if (result.error) {
        break;
      }
    }
  } catch (error) {
    unexpectedError = serializeError(error);
  } finally {
    await fixture.close();
  }
  let browserEvidenceAfter = null;
  let identityCollectionError = null;
  try {
    browserEvidenceAfter = await collectBrowserEvidence(
      browserEvidence.executable.path,
    );
  } catch (error) {
    identityCollectionError = serializeError(error);
  }
  let sourceArtifactBindingAfter = null;
  let sourceArtifactBindingError = null;
  if (sourceArtifactBindingBefore.available) {
    try {
      sourceArtifactBindingAfter = await verifySourceArtifactBinding(
        options,
        browserEvidence.executable.path,
      );
    } catch (error) {
      sourceArtifactBindingError = serializeError(error);
    }
  }
  await delay(CRASH_STABILITY_OBSERVATION_MS);
  const crashAfter = await snapshotMacCrashArtifacts();
  const globalCrashDelta = diffCrashSnapshots(crashBefore, crashAfter);

  const finishedEpoch = Math.floor(Date.now() / 1000 / (7 * 24 * 60 * 60));
  const assertions = validateMatrix(modes, options);
  const browserIdentityUnchanged =
    browserEvidenceAfter !== null &&
    canonical(browserEvidence) === canonical(browserEvidenceAfter);
  addAssertion(
    assertions,
    '浏览器产物、源码、补丁、GN 与验证器运行前后完全一致',
    browserIdentityUnchanged,
    identityCollectionError ?? {
      before: browserEvidence,
      after: browserEvidenceAfter,
    },
  );
  const formalReleaseTarget =
    sourceArtifactBindingBefore.available === true &&
    sourceArtifactBindingBefore.build?.formalRelease === true;
  const releaseWebGpuGateSatisfied =
    !formalReleaseTarget || options.requireWebGPU;
  addAssertion(
    assertions,
    '验证期间未跨 UTC farbling epoch',
    startedEpoch === finishedEpoch,
    {startedEpoch, finishedEpoch},
  );
  const profileDumps = await listDumpFiles(tempRoot);
  addAssertion(
    assertions,
    '临时验证目录无 crash dump',
    profileDumps.length === 0,
    profileDumps,
  );
  addAssertion(
    assertions,
    'macOS Crashpad/DiagnosticReports 各目录状态可读',
    crashBefore.supported === true && crashAfter.supported === true,
    {before: crashBefore.roots, after: crashAfter.roots},
  );
  addAssertion(
    assertions,
    'macOS 全局 Crashpad/DiagnosticReports 无新增转储',
    globalCrashDelta.length === 0,
    globalCrashDelta,
  );
  if (unexpectedError) {
    addAssertion(
      assertions,
      '验证器未发生未处理错误',
      false,
      unexpectedError,
    );
  }
  const failedAssertions = assertions.filter((entry) => !entry.passed);
  const runtimePass = failedAssertions.length === 0;
  const rawBaseline = modes.find(
    (mode) => mode.name === 'pref-off',
  )?.probes?.probe?.report;
  const alphaWorkers = modes.find(
    (mode) => mode.name === 'enabled-first',
  )?.probes?.['embed-alpha']?.report?.workers;
  const coverageGates = {
    webglDebugRendererInfo:
      rawBaseline?.webgl?.supported === true &&
      rawBaseline.webgl.debugExtensionAdvertised === true &&
      rawBaseline.webgl.debugInfoAvailable === true,
    canvasRgbaFloat16:
      rawBaseline?.canvas?.rgbaFloat16?.supported === true,
    offscreenCanvasConvertToBlob:
      rawBaseline?.offscreenCanvas?.convertToBlob?.supported === true,
    offscreenCanvasTransferToImageBitmap:
      rawBaseline?.offscreenCanvas?.transferToImageBitmap?.supported === true,
    serviceWorkerOffscreenCanvas:
      alphaWorkers?.service?.supported === true,
  };
  const coverageComplete = Object.values(coverageGates).every(Boolean);
  const sourceArtifactBindingUnchanged =
    sourceArtifactBindingBefore.available === true &&
    sourceArtifactBindingAfter !== null &&
    canonical(sourceArtifactBindingBefore) ===
      canonical(sourceArtifactBindingAfter);
  const sourceArtifactBinding = sourceArtifactBindingBefore.available
    ? {
        ...sourceArtifactBindingBefore,
        verified:
          sourceArtifactBindingBefore.verified === true &&
          sourceArtifactBindingUnchanged,
        prePostUnchanged: sourceArtifactBindingUnchanged,
        after: sourceArtifactBindingAfter,
        collectionError: sourceArtifactBindingError,
      }
    : sourceArtifactBindingBefore;
  const signature = browserEvidence.codeSignature;
  const teamIdentifierValid = /^[A-Z0-9]{10}$/u.test(
    signature.teamIdentifier ?? '',
  );
  const developerIdSignature =
    teamIdentifierValid &&
    (signature.authority ?? []).some((value) =>
      value.startsWith('Developer ID Application:'),
    );
  const releaseGates = {
    formalReleaseTarget,
    runtimePass,
    browserIdentityUnchanged,
    rootCheckoutClean:
      sourceArtifactBinding.checks?.rootCheckoutClean === true,
    chromiumCheckoutClean:
      browserEvidence.checkout.dirty === false &&
      sourceArtifactBinding.checks?.chromiumCheckoutClean === true,
    sourceQualificationCandidate:
      sourceArtifactBinding.qualification === 'candidate',
    localArtifactIntegrity: sourceArtifactBinding.verified,
    localWorkflowConstructionObserved:
      sourceArtifactBinding.checks?.localWorkflowConstructionObserved === true,
    trustedBuildAttestation:
      sourceArtifactBinding.trustedBuildAttestation === true,
    coverageComplete,
    webGpuReleaseCoverageRequired: releaseWebGpuGateSatisfied,
    codeSignatureStructureValid: signature.strictDeepValid === true,
    hardenedRuntime: signature.hardenedRuntime === true,
    developerIdSignature,
    gatekeeperAccepted: signature.gatekeeperAccepted === true,
    productBundleIdentity: browserEvidence.productIdentity.verified === true,
  };
  const releaseEligible = Object.values(releaseGates).every(Boolean);
  const passed = runtimePass;
  const qualification = releaseEligible
    ? 'pass'
    : runtimePass
      ? 'partial'
      : 'fail';
  const report = {
    schemaVersion: 1,
    kind: 'aegis-fingerprint-runtime',
    passed,
    qualification,
    runtime_pass: runtimePass,
    release_eligible: releaseEligible,
    coverage_complete: coverageComplete,
    startedAt,
    finishedAt: new Date().toISOString(),
    browser: browserEvidence,
    browserEvidence: {
      before: browserEvidence,
      after: browserEvidenceAfter,
      unchanged: browserIdentityUnchanged,
      collectionError: identityCollectionError,
    },
    sourceArtifactBinding,
    releaseGates,
    environment: {
      platform: process.platform,
      architecture: process.arch,
      node: process.version,
      headed: options.headed,
      requireWebGPU: options.requireWebGPU,
      fixtureHosts: TEST_HOSTS,
      profiles: {
        primary: primaryProfileDir,
        secondary: secondaryProfileDir,
      },
      profileRetained: options.keepProfile || !passed,
      processStabilityObservationMs: PROCESS_STABILITY_OBSERVATION_MS,
      crashStabilityObservationMs: CRASH_STABILITY_OBSERVATION_MS,
    },
    epochs: {started: startedEpoch, finished: finishedEpoch},
    assertionSummary: {
      passed: assertions.filter((entry) => entry.passed).length,
      failed: assertions.filter((entry) => !entry.passed).length,
      total: assertions.length,
    },
    coverage: {
      complete: coverageComplete,
      gates: coverageGates,
      dedicatedWorkerOffscreenCanvas:
        alphaWorkers?.dedicated?.coverage ?? 'not-run',
      sharedWorkerOffscreenCanvas:
        alphaWorkers?.shared?.coverage ?? 'not-run',
      serviceWorkerOffscreenCanvas:
        alphaWorkers?.service?.coverage ?? 'not-run',
    },
    assertions,
    unexpectedError,
    profileDumps,
    crashEvidence: {
      supported: crashBefore.supported && crashAfter.supported,
      roots: {before: crashBefore.roots, after: crashAfter.roots},
      beforeCount: crashBefore.artifacts.length,
      afterCount: crashAfter.artifacts.length,
      beforeSha256: sha256Text(canonical(crashBefore.artifacts)),
      afterSha256: sha256Text(canonical(crashAfter.artifacts)),
      newOrModified: globalCrashDelta,
      observationMs: CRASH_STABILITY_OBSERVATION_MS,
    },
    modes,
  };

  if (passed && !options.keepProfile) {
    const expectedPrefix = join(tmpdir(), 'aegis-fingerprint-runtime-');
    assert(tempRoot.startsWith(expectedPrefix), '拒绝清理非预期临时目录');
    await rm(tempRoot, {force: true, recursive: true});
  }
  return report;
}

function syntheticLimitRejection(requested) {
  return {
    requested,
    rejected: true,
    expectedRejection: true,
    error: 'Required limit exceeds supported maximum',
    errorName: 'OperationError',
    errorConstructor: 'DOMException',
    isDomException: true,
  };
}

function syntheticRawReport() {
  return {
    canvas: {
      supported: true,
      inputHash: 'canvas-raw',
      firstReadHash: 'canvas-raw',
      secondReadHash: 'canvas-raw',
      firstDataUrlHash: 'url-raw',
      secondDataUrlHash: 'url-raw',
      firstBlobHash: 'blob-raw',
      secondBlobHash: 'blob-raw',
      rgbaFloat16: {
        supported: true,
        dataType: 'Float16Array',
        firstReadHash: 'float16-raw',
        secondReadHash: 'float16-raw',
      },
    },
    offscreenCanvas: {
      supported: true,
      coverage: 'covered',
      inputHash: 'offscreen-input',
      convertToBlob: {
        supported: true,
        coverage: 'covered',
        firstHash: 'offscreen-blob-raw',
        secondHash: 'offscreen-blob-raw',
      },
      transferToImageBitmap: {
        supported: true,
        coverage: 'covered',
        firstHash: 'offscreen-bitmap-raw',
        secondHash: 'offscreen-bitmap-raw',
      },
    },
    audio: {
      supported: true,
      firstInputHash: 'audio-raw',
      firstReadHash: 'audio-raw',
      secondReadHash: 'audio-raw',
      secondInputHash: 'audio-raw-2',
      afterWriteHash: 'audio-raw-2',
    },
    webgl: {
      supported: true,
      debugExtensionAdvertised: true,
      debugInfoAvailable: true,
      vendor: 'Raw Vendor',
      renderer: 'Raw Renderer',
    },
    webgpu: {
      supported: true,
      info: {
        vendor: 'raw',
        architecture: 'raw',
        device: 'raw',
        description: 'raw',
        driver: 'raw',
        subgroupMinSize: '32',
        subgroupMaxSize: '32',
      },
      features: ['subgroups'],
      limits: {
        maxBufferSize: '1073741826',
        maxComputeWorkgroupStorageSize: '32768',
        maxTextureDimension3D: '4096',
        minSubgroupSize: '32',
        maxSubgroupSize: '32',
      },
      device: {
        supported: true,
        requestedLimits: {
          maxBufferSize: '1073741826',
          maxComputeWorkgroupStorageSize: '32768',
          maxTextureDimension3D: '4096',
        },
        limits: {
          maxBufferSize: '1073741826',
          maxComputeWorkgroupStorageSize: '32768',
          maxTextureDimension3D: '4096',
        },
      },
      requiredLimitRejections: {
        maxBufferSize: syntheticLimitRejection(1073741827),
        maxComputeWorkgroupStorageSize: syntheticLimitRejection(32769),
        maxTextureDimension3D: syntheticLimitRejection(4097),
      },
      rawBucketControls: {
        maxBufferSize: {
          tested: true,
          accepted: true,
          actual: 1073741826,
          bucket: 1073741824,
          requested: 1073741825,
          deviceLimit: '1073741825',
        },
        maxComputeWorkgroupStorageSize: {
          tested: false,
          reasonCode: 'no-hardware-headroom-above-protected-bucket',
          actual: 32768,
          bucket: 32768,
          requested: 32769,
        },
        maxTextureDimension3D: {
          tested: false,
          reasonCode: 'no-hardware-headroom-above-protected-bucket',
          actual: 4096,
          bucket: 4096,
          requested: 4097,
        },
      },
    },
  };
}

function syntheticProtectedReport(site) {
  const suffix = site.replace(/[^a-z]/giu, '');
  return {
    canvas: {
      supported: true,
      inputHash: 'canvas-raw',
      firstReadHash: `canvas-${suffix}`,
      secondReadHash: `canvas-${suffix}`,
      firstDataUrlHash: `url-${suffix}`,
      secondDataUrlHash: `url-${suffix}`,
      firstBlobHash: `blob-${suffix}`,
      secondBlobHash: `blob-${suffix}`,
      rgbaFloat16: {
        supported: true,
        dataType: 'Float16Array',
        firstReadHash: `float16-${suffix}`,
        secondReadHash: `float16-${suffix}`,
      },
    },
    offscreenCanvas: {
      supported: true,
      coverage: 'covered',
      inputHash: 'offscreen-input',
      convertToBlob: {
        supported: true,
        coverage: 'covered',
        firstHash: `offscreen-blob-${suffix}`,
        secondHash: `offscreen-blob-${suffix}`,
      },
      transferToImageBitmap: {
        supported: true,
        coverage: 'covered',
        firstHash: `offscreen-bitmap-${suffix}`,
        secondHash: `offscreen-bitmap-${suffix}`,
      },
    },
    audio: {
      supported: true,
      firstInputHash: 'audio-raw',
      firstReadHash: `audio-${suffix}`,
      secondReadHash: `audio-${suffix}`,
      secondInputHash: 'audio-raw-2',
      afterWriteHash: 'audio-raw-2',
    },
    webgl: {
      supported: true,
      debugExtensionAdvertised: false,
      debugInfoAvailable: false,
      vendor: '',
      renderer: '',
    },
    webgpu: {
      supported: true,
      info: {
        vendor: '',
        architecture: '',
        device: '',
        description: '',
        driver: '',
        subgroupMinSize: '4',
        subgroupMaxSize: '128',
      },
      features: [],
      limits: {
        maxBufferSize: '1073741824',
        maxComputeWorkgroupStorageSize: '32768',
        maxTextureDimension3D: '4096',
        minSubgroupSize: '4',
        maxSubgroupSize: '128',
      },
      device: {
        supported: true,
        requestedLimits: {
          maxBufferSize: '1073741824',
          maxComputeWorkgroupStorageSize: '32768',
          maxTextureDimension3D: '4096',
        },
        limits: {
          maxBufferSize: '1073741824',
          maxComputeWorkgroupStorageSize: '32768',
          maxTextureDimension3D: '4096',
        },
      },
      requiredLimitRejections: {
        maxBufferSize: syntheticLimitRejection(1073741825),
        maxComputeWorkgroupStorageSize: syntheticLimitRejection(32769),
        maxTextureDimension3D: syntheticLimitRejection(4097),
      },
      rawBucketControls: {
        maxBufferSize: {
          tested: false,
          reasonCode: 'no-hardware-headroom-above-protected-bucket',
        },
        maxComputeWorkgroupStorageSize: {
          tested: false,
          reasonCode: 'no-hardware-headroom-above-protected-bucket',
        },
        maxTextureDimension3D: {
          tested: false,
          reasonCode: 'no-hardware-headroom-above-protected-bucket',
        },
      },
    },
  };
}

function syntheticWorkerSurfaces(site) {
  const suffix = site.replace(/[^a-z]/giu, '');
  const surface = (kind) => ({
    supported: true,
    coverage: 'covered',
    inputHash: 'worker-raw',
    firstReadHash: `${kind}-${suffix}`,
    secondReadHash: `${kind}-${suffix}`,
  });
  return {
    tested: true,
    dedicated: surface('dedicated'),
    shared: surface('shared'),
    service: surface('service'),
  };
}

function syntheticMode(name, probes, preferences = {}) {
  const syntheticTermination = (key) => ({
    rootPid: 10_000 + key.length,
    rootPgid: 10_000 + key.length,
    sampled: 2,
    discovered: [
      {
        pid: 10_000 + key.length,
        ppid: 1,
        pgid: 10_000 + key.length,
        startedAt: 'synthetic',
        command: 'synthetic Chromium',
      },
    ],
    signals: [],
    monitorErrors: [],
    survivors: [],
    stableObservationMs: PROCESS_STABILITY_OBSERVATION_MS,
    browserClose: {
      attempted: true,
      requested: true,
      acknowledged: true,
      error: null,
    },
    exitCode: 0,
    signalCode: null,
    terminationMethod: 'browser-close',
    ownershipScan: {performed: true, survivors: []},
  });
  const browserRuns = Object.keys(probes).map((key) => ({
    key,
    browserExitCode: 0,
    browserSignal: null,
    processTermination: syntheticTermination(key),
    log: {
      name: `${name}-${key}.log`,
      size: 0,
      sha256: sha256Text(''),
    },
  }));
  return {
    name,
    error: null,
    fatalSignals: [],
    browserRuns,
    preferences: {
      secretPresent: true,
      secretCanonicalBase64: true,
      secretDecodedBytes: PROFILE_SECRET_BYTES,
      secretSha256: 'synthetic-primary-secret',
      ...preferences,
    },
    probes: Object.fromEntries(
      Object.entries(probes).map(([key, report]) => [key, {report}]),
    ),
  };
}

async function runSelfTest() {
  const tests = [];
  const record = async (name, callback) => {
    try {
      await callback();
      tests.push({name, passed: true});
    } catch (error) {
      tests.push({
        name,
        passed: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  };

  await record('参数解析接受代表性选项', () => {
    const parsed = parseArgs([
      '--timeout-ms',
      '2000',
      '--headed',
      '--require-webgpu',
      '--report',
      join(tmpdir(), 'fingerprint-report.json'),
    ]);
    assert(parsed.timeoutMs === 2000, 'timeout 解析错误');
    assert(parsed.headed, 'headed 解析错误');
    assert(parsed.requireWebGPU, 'require-webgpu 解析错误');
  });

  await record('未知参数会被拒绝', () => {
    let rejected = false;
    try {
      parseArgs(['--unknown']);
    } catch (error) {
      rejected = error instanceof VerificationError;
    }
    assert(rejected, '未知参数未被拒绝');
  });

  await record('构建身份清单与固定摘要必须成对且格式严格', () => {
    const digest = 'a'.repeat(64);
    const parsed = parseArgs([
      '--build-identity',
      join(tmpdir(), 'build-manifest.json'),
      '--build-identity-sha256',
      digest,
    ]);
    assert(parsed.buildIdentitySha256 === digest, '固定摘要解析错误');
    for (const invalid of [
      ['--build-identity', join(tmpdir(), 'build-manifest.json')],
      ['--build-identity-sha256', digest],
      [
        '--build-identity',
        join(tmpdir(), 'build-manifest.json'),
        '--build-identity-sha256',
        'ABC',
      ],
      ['--build-identity', '--headed'],
    ]) {
      let rejected = false;
      try {
        parseArgs(invalid);
      } catch (error) {
        rejected = error instanceof VerificationError;
      }
      assert(rejected, `非法构建身份参数未被拒绝：${canonical(invalid)}`);
    }
  });

  await record('报告路径不得覆盖 App 或身份清单', async () => {
    const root = await mkdtemp(join(tmpdir(), 'aegis-output-path-test-'));
    try {
      const app = join(root, 'Chromium.app');
      const manifest = join(root, 'build-manifest.json');
      await mkdir(app, {recursive: true});
      for (const report of [join(app, 'report.json'), manifest]) {
        let rejected = false;
        try {
          await validateEvidenceOutputPaths(
            {
              report,
              buildIdentity: manifest,
            },
            app,
          );
        } catch (error) {
          rejected = error instanceof VerificationError;
        }
        assert(rejected, `重叠报告路径未被拒绝：${report}`);
      }
    } finally {
      await rm(root, {force: true, recursive: true});
    }
  });

  await record('报告父目录符号链接不得逃逸到 App', async () => {
    const root = await mkdtemp(join(tmpdir(), 'aegis-output-symlink-test-'));
    try {
      const app = join(root, 'Chromium.app');
      const linkedParent = join(root, 'linked-parent');
      await mkdir(app, {recursive: true});
      await symlink(app, linkedParent, 'dir');
      let rejected = false;
      try {
        await validateEvidenceOutputPaths(
          {report: join(linkedParent, 'report.json'), buildIdentity: null},
          app,
        );
      } catch (error) {
        rejected = error instanceof VerificationError;
      }
      assert(rejected, '父目录符号链接逃逸未被拒绝');
    } finally {
      await rm(root, {force: true, recursive: true});
    }
  });

  await record('报告原子发布不得覆盖既有证据', async () => {
    const root = await mkdtemp(join(tmpdir(), 'aegis-report-publish-test-'));
    try {
      const existing = join(root, 'existing.json');
      await writeFile(existing, 'preserved\n', {encoding: 'utf8'});
      let rejected = false;
      try {
        await writeJson(existing, {shouldNotReplace: true});
      } catch (error) {
        rejected = error instanceof VerificationError;
      }
      assert(rejected, '既有报告被覆盖');
      assert(
        (await readFile(existing, 'utf8')) === 'preserved\n',
        '拒绝覆盖后既有内容发生变化',
      );

      const fresh = join(root, 'fresh.json');
      await writeJson(fresh, {published: true});
      assert(
        JSON.parse(await readFile(fresh, 'utf8')).published === true,
        '新报告未成功发布',
      );
    } finally {
      await rm(root, {force: true, recursive: true});
    }
  });

  await record('五状态合成矩阵全部通过', () => {
    const raw = syntheticRawReport();
    const probe = syntheticProtectedReport('probe');
    const active = syntheticProtectedReport('active');
    const alpha = syntheticProtectedReport('alpha');
    const beta = syntheticProtectedReport('beta');
    const otherProfile = syntheticProtectedReport('other-profile');
    Object.assign(alpha, {
      hostname: TEST_HOSTS.frame,
      iframeHostname: TEST_HOSTS.frame,
      topLevelHostname: TEST_HOSTS.embedAlpha,
      workers: syntheticWorkerSurfaces('alpha'),
    });
    Object.assign(beta, {
      hostname: TEST_HOSTS.frame,
      iframeHostname: TEST_HOSTS.frame,
      topLevelHostname: TEST_HOSTS.embedBeta,
      workers: syntheticWorkerSurfaces('beta'),
    });
    const modes = [
      syntheticMode('enabled-first', {
        probe,
        'embed-alpha': alpha,
        'embed-beta': beta,
      }),
      syntheticMode('master-off', {probe: raw}),
      syntheticMode('subfeature-off', {probe: raw}),
      syntheticMode('pref-off', {probe: raw}),
      syntheticMode('site-pause', {paused: raw, active}),
      syntheticMode('enabled-restart', {
        probe,
        'embed-alpha': structuredClone(alpha),
      }),
      syntheticMode(
        'enabled-other-profile',
        {probe: otherProfile},
        {secretSha256: 'synthetic-secondary-secret'},
      ),
    ];
    const assertions = validateMatrix(modes, {requireWebGPU: true});
    const failed = assertions.filter((entry) => !entry.passed);
    assert(failed.length === 0, `合成矩阵失败：${canonical(failed)}`);
    const missingModeAssertions = validateMatrix(
      modes.filter((mode) => mode.name !== 'master-off'),
      {requireWebGPU: true},
    );
    assert(
      missingModeAssertions.some(
        (entry) =>
          !entry.passed && entry.name === 'master-off/probe: 必需探针存在',
      ),
      '缺失必需探针未触发失败',
    );
    const missingTerminationModes = structuredClone(modes);
    missingTerminationModes[0].browserRuns[0].processTermination = null;
    const missingTerminationAssertions = validateMatrix(
      missingTerminationModes,
      {requireWebGPU: true},
    );
    assert(
      missingTerminationAssertions.some(
        (entry) =>
          !entry.passed && entry.name.includes('进程树退出证据完整'),
      ),
      '缺失进程退出证据未触发失败',
    );
  });

  await record('Profile secret 仅接受规范 Base64', async () => {
    const root = await mkdtemp(join(tmpdir(), 'aegis-secret-self-test-'));
    try {
      const defaultDir = join(root, 'Default');
      await mkdir(defaultDir, {recursive: true});
      const valid = Buffer.alloc(PROFILE_SECRET_BYTES, 0x5a).toString('base64');
      await writeFile(
        join(defaultDir, 'Preferences'),
        JSON.stringify({aegis: {fingerprint_farbling_secret: valid}}),
      );
      const validEvidence = await inspectAegisPreferences(root);
      assert(
        validEvidence.secretCanonicalBase64 === true &&
          validEvidence.secretDecodedBytes === PROFILE_SECRET_BYTES,
        '规范 Base64 未被接受',
      );
      await writeFile(
        join(defaultDir, 'Preferences'),
        JSON.stringify({
          aegis: {fingerprint_farbling_secret: `!${valid.slice(1)}`},
        }),
      );
      const invalidEvidence = await inspectAegisPreferences(root);
      assert(
        invalidEvidence.secretCanonicalBase64 === false &&
          invalidEvidence.secretDecodedBytes === 0,
        '非规范 Base64 未被拒绝',
      );
    } finally {
      await rm(root, {force: true, recursive: true});
    }
  });

  await record('显式产品标记会被拒绝', () => {
    const raw = syntheticRawReport();
    const protectedReport = syntheticProtectedReport('probe');
    protectedReport.webgl.vendor = 'Aegis Marker';
    const assertions = [];
    addProtectedAssertions(
      assertions,
      'marker-test',
      protectedReport,
      raw,
      true,
    );
    assert(
      assertions.some(
        (entry) => !entry.passed && entry.name.includes('WebGL 无产品标记'),
      ),
      '产品标记未触发失败',
    );
  });

  await record('WebGPU 内部错误不能冒充 limit 拒绝', () => {
    const report = syntheticProtectedReport('webgpu-error');
    report.webgpu.requiredLimitRejections.maxBufferSize = {
      requested: 1073741825,
      rejected: true,
      expectedRejection: false,
      error: 'Internal device creation failure',
      errorName: 'OperationError',
      errorConstructor: 'DOMException',
      isDomException: true,
    };
    const assertions = [];
    addCommonSurfaceAssertions(assertions, 'webgpu-error', report, true);
    assert(
      assertions.some(
        (entry) =>
          !entry.passed &&
          entry.name.includes('maxBufferSize 超公开值 requiredLimits'),
      ),
      'WebGPU 内部错误被误判为预期拒绝',
    );
  });

  await record('最终进程扫描不依赖 Chromium Helper 名称', async () => {
    const root = await mkdtemp(join(tmpdir(), 'aegis-process-scan-test-'));
    const profileDir = join(root, 'profile');
    const child = spawn(
      process.execPath,
      ['-e', 'setInterval(() => {}, 1000)', profileDir],
      {detached: true, stdio: 'ignore'},
    );
    try {
      await delay(100);
      const evidence = await scanOwnedCommandProcesses(
        '/nonexistent/Chromium',
        profileDir,
      );
      assert(
        evidence.survivors.some((record) => record.pid === child.pid) &&
          evidence.exactExecutableMatches.length === 0,
        '唯一临时目录进程未被最终扫描捕获',
      );
    } finally {
      try {
        process.kill(child.pid, 'SIGKILL');
      } catch {
        // 测试进程可能已提前退出。
      }
      await waitForChildExitState(child, 1_000);
      await rm(root, {force: true, recursive: true});
    }
  });

  await record('精确终止主 PID 与启动后代', async () => {
    const nestedSource =
      "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);";
    const parentSource =
      "const {spawn}=require('node:child_process');" +
      `spawn(process.execPath,['-e',${JSON.stringify(nestedSource)}],` +
      "{stdio:'ignore'});setInterval(() => {}, 1000);";
    const child = spawn(process.execPath, ['-e', parentSource], {
      detached: true,
      stdio: 'ignore',
    });
    const tracker = new OwnedProcessTree(child.pid);
    try {
      const deadline = performance.now() + 2_000;
      do {
        await tracker.sample();
        if (tracker.known.size >= 2) {
          break;
        }
        await delay(50);
      } while (performance.now() < deadline);
      assert(tracker.known.size >= 2, '未发现测试后代进程');
      const evidence = await terminateOwnedProcess(
        child,
        null,
        tracker,
        {
          gracefulTimeoutMs: 0,
          termTimeoutMs: 300,
          killTimeoutMs: 1_000,
          observationMs: 100,
        },
      );
      assert(evidence.survivors.length === 0, '测试进程树仍有残留');
      assert(
        evidence.rootPgid === evidence.rootPid,
        '测试进程未建立独立进程组',
      );
      assert(
        evidence.signals.some((entry) => entry.signal === 'SIGKILL'),
        '忽略 TERM 的后代未进入精确 KILL 路径',
      );
    } finally {
      const survivors = await tracker.alive().catch(() => []);
      for (const record of survivors) {
        try {
          process.kill(record.pid, 'SIGKILL');
        } catch {
          // 测试进程可能已在检查与信号之间退出。
        }
      }
    }
  });

  await record('Crashpad 快照差分识别新增与修改', () => {
    const before = {
      artifacts: [{path: '/tmp/a.dmp', size: 1, mtimeMs: 1}],
    };
    const after = {
      artifacts: [
        {path: '/tmp/a.dmp', size: 2, mtimeMs: 2},
        {path: '/tmp/b.dmp', size: 1, mtimeMs: 1},
      ],
    };
    assert(diffCrashSnapshots(before, after).length === 2, '转储差分错误');
  });

  await record('loopback fixture 返回真实探针页面', async () => {
    const fixture = new FingerprintFixtureServer();
    try {
      new Function(PROBE_CLIENT_SOURCE);
      new Function(WORKER_PROBE_SOURCE);
      await fixture.start();
      const health = await fetchJson(fixture.loopbackUrl('/health'));
      assert(health?.ok === true, 'fixture health 失败');
      const response = await fetch(fixture.loopbackUrl('/probe'));
      const html = await response.text();
      assert(response.ok, 'fixture probe HTTP 失败');
      assert(
        html.includes('__aegisFingerprintPromise') &&
          html.includes('probeWebGPU'),
        'fixture 未包含代表性探针',
      );
      const workerResponse = await fetch(
        fixture.loopbackUrl('/fingerprint-worker.js?kind=dedicated'),
      );
      const workerSource = await workerResponse.text();
      assert(
        workerResponse.ok && workerSource.includes('offscreenCanvasProbe'),
        'fixture 未返回 Worker OffscreenCanvas 探针',
      );
    } finally {
      await fixture.close();
    }
  });

  return {
    schemaVersion: 1,
    kind: 'aegis-fingerprint-runtime-self-test',
    passed: tests.every((entry) => entry.passed),
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
    // 严格顺序：先静态验证整包与两阶段清单，再允许执行被测 Chromium。
    const sourceArtifactBinding = await verifySourceArtifactBinding(
      options,
      chromiumExecutable,
    );
    const crashBefore = options.dryRun
      ? null
      : await snapshotMacCrashArtifacts();
    const browserEvidence = await collectBrowserEvidence(chromiumExecutable);
    if (options.dryRun) {
      const report = {
        schemaVersion: 1,
        kind: 'aegis-fingerprint-runtime-dry-run',
        passed: true,
        qualification: false,
        runtime_pass: false,
        release_eligible: false,
        browser: browserEvidence,
        sourceArtifactBinding,
        headed: options.headed,
        requireWebGPU: options.requireWebGPU,
        report: options.report,
      };
      await writeJson(options.report, report);
      process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
      return;
    }

    const report = await runVerification(
      options,
      browserEvidence,
      crashBefore,
      sourceArtifactBinding,
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
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
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
    kind: 'aegis-fingerprint-runtime-error',
    passed: false,
    qualification: false,
    runtime_pass: false,
    release_eligible: false,
    error: error instanceof Error ? error.message : String(error),
  };
  await writeJson(approvedReportPath, report).catch(() => {});
  process.stderr.write(`${JSON.stringify(report, null, 2)}\n`);
  process.exitCode = 1;
});
