#!/usr/bin/env node

import {createHash, randomUUID} from 'node:crypto';
import {
  chmodSync,
  existsSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import {homedir, release as osRelease, tmpdir} from 'node:os';
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const scriptPath = realpathSync(fileURLToPath(import.meta.url));
const scriptDir = dirname(scriptPath);
const browserRoot = realpathSync(resolve(scriptDir, '..'));
const repoRoot = realpathSync(resolve(browserRoot, '../..'));
const sourceIdentityExcludes = realpathSync(
  join(browserRoot, 'config', 'source-identity-excludes'),
);
const releaseBoundary = 'internal-local-only';

class IdentityError extends Error {}

function fail(message) {
  throw new IdentityError(message);
}

function assert(condition, message) {
  if (!condition) {
    fail(message);
  }
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    env: {...process.env, DEPOT_TOOLS_UPDATE: '0'},
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    fail(
      `${command} ${args.join(' ')} failed: ${
        result.stderr.trim() || result.error?.message || result.status
      }`,
    );
  }
  return result.stdout.trim();
}

function runWithInput(command, args, cwd, input) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    env: {...process.env, DEPOT_TOOLS_UPDATE: '0'},
    input,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    fail(
      `${command} ${args.join(' ')} failed: ${
        result.stderr.trim() || result.error?.message || result.status
      }`,
    );
  }
  return result.stdout;
}

function canonical(value) {
  if (Array.isArray(value)) {
    return `[${value.map((entry) => canonical(entry)).join(',')}]`;
  }
  if (value && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

function sha256Buffer(value) {
  return createHash('sha256').update(value).digest('hex');
}

function sha256File(path) {
  const before = statSync(path);
  const value = readFileSync(path);
  const after = statSync(path);
  assert(
    before.ino === after.ino &&
      before.size === after.size &&
      before.mtimeMs === after.mtimeMs,
    `file changed while hashing: ${path}`,
  );
  return sha256Buffer(value);
}

function fileEvidence(path) {
  const entry = lstatSync(path);
  assert(entry.isFile(), `expected regular file: ${path}`);
  return {
    mode: entry.mode & 0o7777,
    sizeBytes: entry.size,
    sha256: sha256File(path),
  };
}

function pathIsInside(root, candidate) {
  return candidate === root || candidate.startsWith(`${root}${sep}`);
}

function lstatOrNull(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return null;
    }
    throw error;
  }
}

function safeRelativePath(root, path) {
  const realRoot = realpathSync(root);
  const realPath = realpathSync(path);
  assert(
    pathIsInside(realRoot, realPath),
    `artifact resolves outside artifact root: ${path}`,
  );
  const value = relative(realRoot, realPath);
  assert(
    value && !isAbsolute(value) && value !== '..' && !value.startsWith(`..${sep}`),
    `artifact must be a child of artifact root: ${path}`,
  );
  return value.split(sep).join('/');
}

function expectedArtifactPath(root, path) {
  const realRoot = realpathSync(root);
  const absolutePath = resolve(path);
  const realParent = realpathSync(dirname(absolutePath));
  const resolvedPath = join(realParent, basename(absolutePath));
  assert(
    pathIsInside(realRoot, resolvedPath),
    `expected artifact resolves outside out-dir: ${path}`,
  );
  assert(
    lstatOrNull(absolutePath) === null,
    `expected artifact already exists or is a dangling symlink: ${path}`,
  );
  return relative(realRoot, resolvedPath).split(sep).join('/');
}

function treeEvidence(root) {
  const requestedRoot = resolve(root);
  const rootEntry = lstatSync(requestedRoot);
  assert(rootEntry.isDirectory(), `expected directory tree: ${requestedRoot}`);
  const realRoot = realpathSync(requestedRoot);
  const hash = createHash('sha256');
  let directoryCount = 0;
  let fileCount = 0;
  let logicalSizeBytes = 0;
  let symlinkCount = 0;

  function visit(path) {
    const entry = lstatSync(path);
    const name = relative(realRoot, path).split(sep).join('/') || '.';
    const mode = entry.mode & 0o7777;
    if (entry.isSymbolicLink()) {
      const target = readlinkSync(path);
      let resolvedTarget;
      try {
        resolvedTarget = realpathSync(path);
      } catch {
        fail(`artifact contains dangling symlink: ${name}`);
      }
      assert(
        pathIsInside(realRoot, resolvedTarget),
        `artifact symlink escapes tree: ${name} -> ${target}`,
      );
      symlinkCount += 1;
      hash.update(`L\0${name}\0${mode.toString(8)}\0${target}\n`);
      return;
    }
    if (entry.isDirectory()) {
      directoryCount += 1;
      hash.update(`D\0${name}\0${mode.toString(8)}\n`);
      for (const child of readdirSync(path).sort()) {
        visit(join(path, child));
      }
      return;
    }
    assert(entry.isFile(), `unsupported artifact entry: ${path}`);
    const digest = sha256File(path);
    fileCount += 1;
    logicalSizeBytes += entry.size;
    hash.update(
      `F\0${name}\0${mode.toString(8)}\0${entry.size}\0${digest}\n`,
    );
  }

  visit(realRoot);
  return {
    kind: 'directory-tree',
    logicalSizeBytes,
    directoryCount,
    fileCount,
    symlinkCount,
    sha256: hash.digest('hex'),
  };
}

function filteredGitStatus(path, excludedPaths) {
  const statusArgs = [
    '-c',
    `core.excludesFile=${sourceIdentityExcludes}`,
    'status',
    '--porcelain=v1',
    '--untracked-files=all',
    '--ignore-submodules=none',
  ];
  statusArgs.push('--', '.');
  statusArgs.push(...excludedPaths.map((value) => `:(exclude)${value}`));
  return run('git', statusArgs, path);
}

function gitIdentity(path, detailed = false, excludedPaths = []) {
  const sha = run('git', ['rev-parse', 'HEAD'], path);
  const tree = run('git', ['rev-parse', 'HEAD^{tree}'], path);
  const status = filteredGitStatus(path, excludedPaths);
  const identity = {sha, tree, dirty: status.length > 0};
  if (detailed) {
    identity.statusEntryCount = status.split(/\r?\n/u).filter(Boolean).length;
    identity.statusSha256 = sha256Buffer(status);
  }
  return identity;
}

function toolIdentity(name, path, versionArgs = ['--version']) {
  assert(existsSync(path), `missing ${name} tool: ${path}`);
  const resolvedPath = realpathSync(path);
  const version = run(resolvedPath, versionArgs, repoRoot)
    .replace(/^InstalledDir:.*$/gmu, '')
    .replace(/\n{2,}/gu, '\n')
    .trim();
  return {version, sha256: sha256File(resolvedPath)};
}

function configuredChromiumSource() {
  const marker = join(browserRoot, '.chromium-root');
  const configuredRoot =
    process.env.CHROMIUM_ROOT?.trim() ||
    (existsSync(marker) ? readFileSync(marker, 'utf8').trim() : '') ||
    join(homedir(), 'Projects/GCSA-aegis-chromium');
  return realpathSync(join(configuredRoot, 'src'));
}

function stablePatchId(value, cwd) {
  const output = runWithInput('git', ['patch-id', '--stable'], cwd, value).trim();
  const patchId = output.match(/^([0-9a-f]{40})\s/u)?.[1];
  assert(patchId, 'git patch-id did not return a stable patch identifier');
  return patchId;
}

function patchEvidence(
  checkout,
  baseCommit,
  patchRoot = join(browserRoot, 'patches'),
  label = 'Chromium',
) {
  const seriesPath = join(patchRoot, 'series');
  const names = readFileSync(seriesPath, 'utf8')
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
  const seen = new Set();
  const patches = names.map((name) => {
    assert(
      basename(name) === name && name !== '.' && name !== '..',
      `unsafe patch path: ${name}`,
    );
    assert(!seen.has(name), `duplicate patch in series: ${name}`);
    seen.add(name);
    const path = join(patchRoot, name);
    const firstLine = readFileSync(path, 'utf8').split(/\r?\n/u, 1)[0];
    const commit = firstLine.match(/^From ([0-9a-f]{40}) /u)?.[1];
    assert(commit, `patch does not contain a format-patch commit header: ${name}`);
    return {
      name,
      commit,
      stablePatchId: stablePatchId(readFileSync(path, 'utf8'), repoRoot),
      ...fileEvidence(path),
    };
  });
  run('git', ['merge-base', '--is-ancestor', baseCommit, 'HEAD'], checkout);
  const appliedCommits = run(
    'git',
    ['rev-list', '--reverse', `${baseCommit}..HEAD`],
    checkout,
  )
    .split(/\r?\n/u)
    .filter(Boolean);
  const patchCommits = patches.map((entry) => entry.commit);
  assert(
    appliedCommits.length === patchCommits.length,
    `${label} commit count does not match ${relative(browserRoot, seriesPath)}`,
  );
  for (let index = 0; index < patches.length; index += 1) {
    const patch = patches[index];
    const appliedCommit = appliedCommits[index];
    const commitDiff = run(
      'git',
      ['show', '--pretty=format:', '--no-ext-diff', '--binary', appliedCommit],
      checkout,
    );
    assert(
      stablePatchId(commitDiff, checkout) === patch.stablePatchId,
      `ordered patch content does not match ${label} commit: ${patch.name}`,
    );
  }
  const exactCommitIdsMatch = canonical(appliedCommits) === canonical(patchCommits);
  return {
    series: fileEvidence(seriesPath),
    patchCount: patches.length,
    patches,
    manifestSha256: sha256Buffer(
      patches.map((entry) => `${entry.name}\0${entry.sha256}\0`).join(''),
    ),
    lineage: {
      base: baseCommit,
      head: appliedCommits.at(-1) ?? baseCommit,
      exactSeriesMatch: exactCommitIdsMatch,
      exactCommitIdsMatch,
      orderedStablePatchIdsMatch: true,
      stablePatchIdsMatch: true,
      appliedCommits,
    },
  };
}

function mappedTreeEvidence(sourceRoot, targetRoot) {
  const realSourceRoot = realpathSync(sourceRoot);
  const realTargetRoot = realpathSync(targetRoot);
  const hash = createHash('sha256');
  let directoryCount = 0;
  let fileCount = 0;
  let logicalSizeBytes = 0;
  let symlinkCount = 0;

  function visit(sourcePath) {
    const name = relative(realSourceRoot, sourcePath).split(sep).join('/') || '.';
    const targetPath = name === '.' ? realTargetRoot : join(realTargetRoot, ...name.split('/'));
    const sourceEntry = lstatSync(sourcePath);
    const targetEntry = lstatSync(targetPath);
    let realMappedTarget;
    try {
      realMappedTarget = realpathSync(targetPath);
    } catch {
      fail(`overlay target is dangling or inaccessible: ${name}`);
    }
    assert(
      pathIsInside(realTargetRoot, realMappedTarget),
      `overlay target escapes Chromium checkout: ${name}`,
    );
    const sourceMode = sourceEntry.mode & 0o7777;
    const targetMode = targetEntry.mode & 0o7777;
    assert(sourceMode === targetMode, `overlay mode mismatch in Chromium checkout: ${name}`);
    if (sourceEntry.isSymbolicLink()) {
      assert(targetEntry.isSymbolicLink(), `overlay type mismatch in Chromium checkout: ${name}`);
      const sourceTarget = readlinkSync(sourcePath);
      const targetTarget = readlinkSync(targetPath);
      assert(sourceTarget === targetTarget, `overlay symlink mismatch in Chromium checkout: ${name}`);
      symlinkCount += 1;
      hash.update(`L\0${name}\0${targetMode.toString(8)}\0${targetTarget}\n`);
      return;
    }
    if (sourceEntry.isDirectory()) {
      assert(targetEntry.isDirectory(), `overlay type mismatch in Chromium checkout: ${name}`);
      directoryCount += 1;
      hash.update(`D\0${name}\0${targetMode.toString(8)}\n`);
      for (const child of readdirSync(sourcePath).sort()) {
        visit(join(sourcePath, child));
      }
      return;
    }
    assert(sourceEntry.isFile(), `unsupported overlay entry: ${sourcePath}`);
    assert(targetEntry.isFile(), `overlay type mismatch in Chromium checkout: ${name}`);
    const digest = sha256File(targetPath);
    fileCount += 1;
    logicalSizeBytes += targetEntry.size;
    hash.update(
      `F\0${name}\0${targetMode.toString(8)}\0${targetEntry.size}\0${digest}\n`,
    );
  }

  visit(realSourceRoot);
  return {
    kind: 'directory-tree',
    logicalSizeBytes,
    directoryCount,
    fileCount,
    symlinkCount,
    sha256: hash.digest('hex'),
  };
}

function buildDriverEvidence() {
  return [
    'config/source-identity-excludes',
    'scripts/apply-patches.sh',
    'scripts/build-release.sh',
    'scripts/common.sh',
    'scripts/status.sh',
    'scripts/write-build-identity.mjs',
  ].map((name) => ({name, ...fileEvidence(join(browserRoot, name))}));
}

function gnToolPath(chromiumSrc) {
  const gnPlatform = {
    darwin: 'mac',
    linux: process.arch === 'arm64' ? 'linux_arm64' : 'linux64',
    win32: 'win',
  }[process.platform];
  assert(gnPlatform, `unsupported host platform for GN identity: ${process.platform}`);
  return join(chromiumSrc, 'buildtools', gnPlatform, 'gn');
}

function normalizedGnArgs(gnPath, value) {
  return runWithInput(gnPath, ['format', '--stdin'], repoRoot, value);
}

function collectSourceSnapshot(outDir) {
  const resolvedOutDir = realpathSync(outDir);
  const chromiumSrc = configuredChromiumSource();
  assert(
    pathIsInside(chromiumSrc, resolvedOutDir),
    `out-dir must be inside Chromium source: ${resolvedOutDir}`,
  );
  const chromiumBase = readFileSync(join(browserRoot, 'CHROMIUM_COMMIT'), 'utf8').trim();
  assert(/^[0-9a-f]{40}$/u.test(chromiumBase), 'CHROMIUM_COMMIT is invalid');
  const v8Source = realpathSync(join(chromiumSrc, 'v8'));
  const v8Base = run('git', ['rev-parse', `${chromiumBase}:v8`], chromiumSrc);
  assert(/^[0-9a-f]{40}$/u.test(v8Base), 'pinned Chromium commit has no V8 gitlink');
  const gnPath = gnToolPath(chromiumSrc);
  const releaseArgsPath = join(browserRoot, 'args', 'aegis-release.gn');
  const releaseArgs = readFileSync(releaseArgsPath, 'utf8');
  const expectedGnArgs = normalizedGnArgs(gnPath, releaseArgs);
  const overlayRepository = treeEvidence(join(browserRoot, 'overlay'));
  const overlayApplied = mappedTreeEvidence(join(browserRoot, 'overlay'), chromiumSrc);
  assert(
    canonical(overlayRepository) === canonical(overlayApplied),
    'Chromium checkout does not exactly contain the repository overlay',
  );
  const source = {
    root: gitIdentity(repoRoot),
    // Chromium's V8 gitlink is intentionally advanced by a separately
    // evidenced nested patch series; do not count it twice as top-level dirt.
    chromium: gitIdentity(chromiumSrc, true, ['v8']),
    v8: {
      base: v8Base,
      checkout: gitIdentity(v8Source, true),
      patches: patchEvidence(
        v8Source,
        v8Base,
        join(browserRoot, 'patches', 'v8'),
        'V8',
      ),
    },
    chromiumBase,
    chromiumVersion: readFileSync(join(browserRoot, 'CHROMIUM_VERSION'), 'utf8').trim(),
    patches: patchEvidence(chromiumSrc, chromiumBase),
    overlay: {
      repository: overlayRepository,
      applied: overlayApplied,
      exactCheckoutMatch: true,
    },
    releaseArgsTemplate: fileEvidence(releaseArgsPath),
    buildDrivers: buildDriverEvidence(),
  };
  const build = {
    target: 'chrome',
    outDir: relative(chromiumSrc, resolvedOutDir).split(sep).join('/'),
    expectedGnArgsSha256: sha256Buffer(expectedGnArgs),
    host: {
      platform: process.platform,
      architecture: process.arch,
      osRelease: osRelease(),
      node: process.version,
    },
    toolchain: {
      git: run('git', ['--version'], repoRoot),
      clang: toolIdentity(
        'Chromium clang',
        join(chromiumSrc, 'third_party/llvm-build/Release+Asserts/bin/clang'),
      ),
      gn: toolIdentity(
        'Chromium GN',
        gnPath,
      ),
      ninja: toolIdentity(
        'Chromium Ninja',
        join(chromiumSrc, 'third_party/ninja/ninja'),
      ),
    },
  };
  return {
    source,
    build,
    inputSha256: sha256Buffer(canonical({source, build})),
  };
}

function buildLogEvidence(outDir) {
  const path = join(realpathSync(outDir), '.ninja_log');
  return existsSync(path) ? fileEvidence(path) : null;
}

function collectBuildGraphSnapshot(outDir) {
  const input = collectSourceSnapshot(outDir);
  const resolvedOutDir = realpathSync(outDir);
  const chromiumSrc = configuredChromiumSource();
  const gnArgsPath = join(resolvedOutDir, 'args.gn');
  const buildNinjaPath = join(resolvedOutDir, 'build.ninja');
  assert(existsSync(gnArgsPath), `missing GN args: ${gnArgsPath}`);
  assert(existsSync(buildNinjaPath), `missing build graph: ${buildNinjaPath}`);
  const gnArgs = readFileSync(gnArgsPath, 'utf8');
  const normalized = normalizedGnArgs(gnToolPath(chromiumSrc), gnArgs);
  const normalizedSha256 = sha256Buffer(normalized);
  assert(
    normalizedSha256 === input.build.expectedGnArgsSha256,
    'generated args.gn does not semantically match aegis-release.gn',
  );
  const graph = {
    gnArgsSha256: sha256Buffer(gnArgs),
    normalizedGnArgsSha256: normalizedSha256,
    expectedGnArgsMatch: true,
    isComponentBuild: /(?:^|\n)\s*is_component_build\s*=\s*true\s*(?:\n|$)/u.test(
      normalized,
    ),
    buildNinja: fileEvidence(buildNinjaPath),
  };
  return {
    ...input,
    graph,
    graphSha256: sha256Buffer(
      canonical({inputSha256: input.inputSha256, graph}),
    ),
  };
}

function artifactEvidence(artifactRoot, path) {
  const absolutePath = realpathSync(path);
  const relativePath = safeRelativePath(artifactRoot, absolutePath);
  const entry = lstatSync(absolutePath);
  const evidence = entry.isDirectory()
    ? treeEvidence(absolutePath)
    : entry.isFile()
      ? {kind: 'file', ...fileEvidence(absolutePath)}
      : fail(`artifact is not a file or directory: ${absolutePath}`);
  const result = {name: basename(absolutePath), relativePath, ...evidence};
  if (entry.isDirectory() && basename(absolutePath).endsWith('.app')) {
    const criticalFiles = [
      'Contents/Info.plist',
      'Contents/MacOS/Chromium',
      'Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework',
    ];
    result.criticalFiles = criticalFiles.map((name) => ({
      name,
      ...fileEvidence(join(absolutePath, ...name.split('/'))),
    }));
  }
  return result;
}

function sealDocument(value) {
  const document = structuredClone(value);
  document.payloadSha256 = sha256Buffer(canonical(document));
  return document;
}

function validateSealedDocument(document) {
  assert(document && typeof document === 'object', 'manifest must be an object');
  assert(
    typeof document.payloadSha256 === 'string' &&
      /^[0-9a-f]{64}$/u.test(document.payloadSha256),
    'manifest payloadSha256 is invalid',
  );
  const payloadSha256 = document.payloadSha256;
  const payload = structuredClone(document);
  delete payload.payloadSha256;
  assert(
    sha256Buffer(canonical(payload)) === payloadSha256,
    'manifest payload digest mismatch',
  );
}

function atomicPublish(path, content, replaceExisting) {
  mkdirSync(dirname(path), {recursive: true});
  const temporary = join(
    dirname(path),
    `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`,
  );
  writeFileSync(temporary, content, {encoding: 'utf8', flag: 'wx', mode: 0o644});
  try {
    if (replaceExisting) {
      renameSync(temporary, path);
    } else {
      linkSync(temporary, path);
      unlinkSync(temporary);
    }
  } catch (error) {
    rmSync(temporary, {force: true});
    if (!replaceExisting && existsSync(path)) {
      fail(`refusing to overwrite existing identity file: ${path}`);
    }
    throw error;
  }
}

function writeDocument(path, value, replaceExisting) {
  const document = sealDocument(value);
  const bytes = `${JSON.stringify(document, null, 2)}\n`;
  const fileSha256 = sha256Buffer(bytes);
  const sidecarPath = `${path}.sha256`;
  if (!replaceExisting) {
    assert(!existsSync(path), `refusing to overwrite existing identity file: ${path}`);
    assert(
      !existsSync(sidecarPath),
      `refusing to overwrite existing identity sidecar: ${sidecarPath}`,
    );
  }
  atomicPublish(path, bytes, replaceExisting);
  atomicPublish(
    sidecarPath,
    `${fileSha256}  ${basename(path)}\n`,
    replaceExisting,
  );
  return {document, fileSha256, sidecarPath};
}

function readDocument(path, expectedSha256 = null) {
  const absolutePath = realpathSync(path);
  const before = statSync(absolutePath);
  const bytes = readFileSync(absolutePath);
  const after = statSync(absolutePath);
  assert(
    before.ino === after.ino &&
      before.size === after.size &&
      before.mtimeMs === after.mtimeMs,
    `manifest changed while reading: ${absolutePath}`,
  );
  const fileSha256 = sha256Buffer(bytes);
  if (expectedSha256) {
    assert(fileSha256 === expectedSha256, 'manifest pinned SHA-256 mismatch');
  }
  const sidecar = readFileSync(`${absolutePath}.sha256`, 'utf8').trim();
  const sidecarMatch = sidecar.match(/^([0-9a-f]{64})\s{2}([^/]+)$/u);
  assert(sidecarMatch, 'manifest sidecar format is invalid');
  assert(sidecarMatch[1] === fileSha256, 'manifest sidecar SHA-256 mismatch');
  assert(sidecarMatch[2] === basename(absolutePath), 'manifest sidecar name mismatch');
  let document;
  try {
    document = JSON.parse(bytes.toString('utf8'));
  } catch (error) {
    fail(`manifest JSON is invalid: ${error.message}`);
  }
  validateSealedDocument(document);
  return {path: absolutePath, fileSha256, document};
}

function nextValue(argv, index, option) {
  const value = argv[index + 1];
  assert(value && !value.startsWith('--'), `${option} is missing a value`);
  return value;
}

function parseArgs(argv) {
  const parsed = {
    allowDirty: false,
    artifacts: [],
    phase: 'snapshot',
    replace: false,
    selfTest: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--phase') {
      parsed.phase = nextValue(argv, index, arg);
      index += 1;
    } else if (arg === '--artifact') {
      parsed.artifacts.push(resolve(nextValue(argv, index, arg)));
      index += 1;
    } else if (arg === '--output') {
      parsed.output = resolve(nextValue(argv, index, arg));
      index += 1;
    } else if (arg === '--input') {
      parsed.input = resolve(nextValue(argv, index, arg));
      index += 1;
    } else if (arg === '--manifest') {
      parsed.manifest = resolve(nextValue(argv, index, arg));
      index += 1;
    } else if (arg === '--parent-manifest') {
      parsed.parentManifest = resolve(nextValue(argv, index, arg));
      index += 1;
    } else if (arg === '--parent-manifest-sha256') {
      parsed.parentManifestSha256 = nextValue(argv, index, arg);
      index += 1;
    } else if (arg === '--expected-sha256') {
      parsed.expectedSha256 = nextValue(argv, index, arg);
      index += 1;
    } else if (arg === '--out-dir') {
      parsed.outDir = resolve(nextValue(argv, index, arg));
      index += 1;
    } else if (arg === '--artifact-root') {
      parsed.artifactRoot = resolve(nextValue(argv, index, arg));
      index += 1;
    } else if (arg === '--lock') {
      parsed.lock = resolve(nextValue(argv, index, arg));
      index += 1;
    } else if (arg === '--allow-dirty') {
      parsed.allowDirty = true;
    } else if (arg === '--replace') {
      parsed.replace = true;
    } else if (arg === '--self-test') {
      parsed.selfTest = true;
    } else {
      fail(`unknown argument: ${arg}`);
    }
  }
  if (parsed.expectedSha256) {
    assert(
      /^[0-9a-f]{64}$/u.test(parsed.expectedSha256),
      '--expected-sha256 must be 64 lowercase hexadecimal characters',
    );
  }
  assert(
    Boolean(parsed.parentManifest) === Boolean(parsed.parentManifestSha256),
    '--parent-manifest and --parent-manifest-sha256 must be provided together',
  );
  if (parsed.parentManifestSha256) {
    assert(
      /^[0-9a-f]{64}$/u.test(parsed.parentManifestSha256),
      '--parent-manifest-sha256 must be 64 lowercase hexadecimal characters',
    );
  }
  return parsed;
}

function qualificationFor(snapshot, allowDirty) {
  const dirty =
    snapshot.source.root.dirty ||
    snapshot.source.chromium.dirty ||
    snapshot.source.v8.checkout.dirty;
  if (dirty && !allowDirty) {
    fail(
      `refusing dirty source (root=${snapshot.source.root.dirty}, ` +
        `chromium=${snapshot.source.chromium.dirty}, ` +
        `v8=${snapshot.source.v8.checkout.dirty}); pass --allow-dirty only ` +
        'for a diagnostic-only build',
    );
  }
  return dirty ? 'diagnostic-only' : 'candidate';
}

function ensureUniqueArtifacts(artifacts) {
  const names = new Set();
  const paths = new Set();
  for (const artifact of artifacts) {
    assert(!names.has(artifact.name), `duplicate artifact name: ${artifact.name}`);
    assert(
      !paths.has(artifact.relativePath),
      `duplicate artifact path: ${artifact.relativePath}`,
    );
    names.add(artifact.name);
    paths.add(artifact.relativePath);
  }
}

function beginBuild(args) {
  assert(
    args.output && args.outDir && args.lock && args.artifacts.length > 0,
    'begin requires --output, --out-dir, --lock and --artifact',
  );
  const lockEntry = lstatSync(args.lock);
  assert(lockEntry.isDirectory(), `build lock is not a directory: ${args.lock}`);
  const lockPath = safeRelativePath(args.outDir, args.lock);
  const expectedArtifacts = args.artifacts.map((path) =>
    expectedArtifactPath(args.outDir, path),
  );
  assert(
    new Set(expectedArtifacts).size === expectedArtifacts.length,
    'duplicate expected artifact path',
  );
  const snapshot = collectBuildGraphSnapshot(args.outDir);
  const qualification = qualificationFor(snapshot, args.allowDirty);
  const startedAtEpochMs = Date.now();
  const buildLogBefore = buildLogEvidence(args.outDir);
  const result = writeDocument(
    args.output,
    {
      schemaVersion: 3,
      kind: 'aegis-build-input',
      phase: 'begin',
      manifestId: randomUUID(),
      generatedAt: new Date().toISOString(),
      startedAtEpochMs,
      releaseBoundary,
      qualification,
      source: snapshot.source,
      build: {...snapshot.build, ...snapshot.graph},
      expectedArtifacts,
      binding: {
        inputSha256: snapshot.inputSha256,
        graphSha256: snapshot.graphSha256,
        artifactAbsentAtBegin: true,
        buildLogBefore,
        lockPath,
        trustLevel: 'cooperative-local-workflow',
        trustedBuildAttestation: false,
      },
    },
    args.replace,
  );
  return {
    operation: 'begin',
    path: realpathSync(args.output),
    sha256: result.fileSha256,
    qualification,
    inputSha256: snapshot.inputSha256,
    graphSha256: snapshot.graphSha256,
    expectedArtifacts,
  };
}

function finalizeBuild(args) {
  assert(
    args.input &&
      args.output &&
      args.outDir &&
      args.lock &&
      args.artifacts.length > 0,
    'finalize requires --input, --output, --out-dir, --lock and --artifact',
  );
  assert(lstatSync(args.lock).isDirectory(), `build lock is not a directory: ${args.lock}`);
  const begin = readDocument(args.input);
  assert(begin.document.schemaVersion === 3, 'unsupported build input schema');
  assert(begin.document.kind === 'aegis-build-input', 'input is not a build input');
  assert(begin.document.phase === 'begin', 'input phase is not begin');
  assert(
    begin.document.releaseBoundary === releaseBoundary,
    'build input release boundary mismatch',
  );
  assert(
    safeRelativePath(args.outDir, args.lock) === begin.document.binding.lockPath,
    'build lock does not match begin phase',
  );
  const current = collectBuildGraphSnapshot(args.outDir);
  assert(
    current.inputSha256 === begin.document.binding.inputSha256,
    'build inputs changed after begin; refusing to bind the artifact',
  );
  assert(
    current.graphSha256 === begin.document.binding.graphSha256,
    'build graph changed after begin; refusing to bind the artifact',
  );
  const artifacts = args.artifacts.map((path) => artifactEvidence(args.outDir, path));
  ensureUniqueArtifacts(artifacts);
  assert(
    canonical(artifacts.map((entry) => entry.relativePath).sort()) ===
      canonical([...begin.document.expectedArtifacts].sort()),
    'final artifacts do not match the artifact set declared at begin',
  );
  for (const path of args.artifacts) {
    const entry = lstatSync(path);
    assert(
      entry.ctimeMs >= begin.document.startedAtEpochMs - 1_000,
      `artifact was not created during this build attempt: ${path}`,
    );
  }
  const buildLogAfter = buildLogEvidence(args.outDir);
  assert(
    buildLogAfter !== null &&
      canonical(buildLogAfter) !== canonical(begin.document.binding.buildLogBefore),
    'build log did not change after begin; refusing construction observation',
  );
  const result = writeDocument(
    args.output,
    {
      schemaVersion: 3,
      kind: 'aegis-build-identity',
      phase: 'finalize',
      manifestId: begin.document.manifestId,
      generatedAt: new Date().toISOString(),
      releaseBoundary,
      qualification: begin.document.qualification,
      source: current.source,
      build: {...current.build, ...current.graph},
      artifacts,
      binding: {
        method: 'locked-two-phase-local-build-with-graph-and-artifact-tree-hash',
        beginManifestSha256: begin.fileSha256,
        enumeratedInputBeforeSha256: begin.document.binding.inputSha256,
        enumeratedInputAfterSha256: current.inputSha256,
        graphBeforeSha256: begin.document.binding.graphSha256,
        graphAfterSha256: current.graphSha256,
        enumeratedInputsUnchanged: true,
        graphUnchanged: true,
        artifactAbsentAtBegin: true,
        artifactAppearedAfterBegin: true,
        lockPath: begin.document.binding.lockPath,
        buildLogBefore: begin.document.binding.buildLogBefore,
        buildLogAfter,
        buildActivityObserved: true,
        trustLevel: 'cooperative-local-workflow',
        localWorkflowConstructionObserved: true,
        trustedBuildAttestation: false,
      },
    },
    args.replace,
  );
  return {
    operation: 'finalize',
    path: realpathSync(args.output),
    sha256: result.fileSha256,
    qualification: begin.document.qualification,
    localSourceArtifactBinding: true,
    trustLevel: 'cooperative-local-workflow',
    trustedBuildAttestation: false,
    artifacts: artifacts.map((entry) => ({
      relativePath: entry.relativePath,
      sha256: entry.sha256,
    })),
  };
}

function verifyBuild(args) {
  assert(
    args.manifest && args.outDir && args.artifacts.length > 0,
    'verify requires --manifest, --out-dir and --artifact',
  );
  const loaded = readDocument(args.manifest, args.expectedSha256);
  const manifest = loaded.document;
  assert(manifest.schemaVersion === 3, 'unsupported build manifest schema');
  assert(manifest.kind === 'aegis-build-identity', 'not a build identity');
  assert(manifest.phase === 'finalize', 'build identity is not finalized');
  assert(manifest.releaseBoundary === releaseBoundary, 'release boundary mismatch');
  assert(
    manifest.binding?.enumeratedInputsUnchanged === true &&
      manifest.binding.graphUnchanged === true &&
      manifest.binding.artifactAbsentAtBegin === true &&
      manifest.binding.artifactAppearedAfterBegin === true &&
      manifest.binding.buildActivityObserved === true &&
      manifest.binding.buildLogBefore !== null &&
      manifest.binding.buildLogAfter !== null &&
      canonical(manifest.binding.buildLogBefore) !==
        canonical(manifest.binding.buildLogAfter) &&
      manifest.binding.localWorkflowConstructionObserved === true &&
      manifest.binding.trustedBuildAttestation === false &&
      manifest.binding.enumeratedInputBeforeSha256 ===
        manifest.binding.enumeratedInputAfterSha256 &&
      manifest.binding.graphBeforeSha256 === manifest.binding.graphAfterSha256,
    'manifest does not contain a complete local two-phase construction record',
  );
  const current = collectBuildGraphSnapshot(args.outDir);
  assert(
    current.inputSha256 === manifest.binding.enumeratedInputAfterSha256,
    'current build inputs do not match the finalized manifest',
  );
  assert(
    current.graphSha256 === manifest.binding.graphAfterSha256,
    'current build graph does not match the finalized manifest',
  );
  assert(canonical(current.source) === canonical(manifest.source), 'source evidence mismatch');
  assert(
    canonical({...current.build, ...current.graph}) === canonical(manifest.build),
    'build evidence mismatch',
  );
  const artifacts = args.artifacts.map((path) => artifactEvidence(args.outDir, path));
  ensureUniqueArtifacts(artifacts);
  assert(
    artifacts.length === manifest.artifacts?.length,
    'explicit artifact set does not match manifest artifact count',
  );
  for (const actual of artifacts) {
    const matches = manifest.artifacts.filter(
      (expected) => expected.relativePath === actual.relativePath,
    );
    assert(matches.length === 1, `artifact is not uniquely bound: ${actual.relativePath}`);
    assert(
      canonical(matches[0]) === canonical(actual),
      `artifact evidence mismatch: ${actual.relativePath}`,
    );
  }
  const formalRelease =
    manifest.build.outDir === 'out/AegisRelease' &&
    manifest.build.target === 'chrome' &&
    manifest.build.isComponentBuild === false;
  const localCandidate =
    manifest.qualification === 'candidate' &&
    manifest.source.root.dirty === false &&
    manifest.source.chromium.dirty === false &&
    manifest.source.v8.checkout.dirty === false;
  return {
    schemaVersion: 1,
    kind: 'aegis-build-identity-verification',
    verified: true,
    releaseBoundary: manifest.releaseBoundary,
    qualification: manifest.qualification,
    localCandidate: localCandidate && formalRelease,
    releaseCandidate: false,
    trustLevel: manifest.binding.trustLevel,
    trustedBuildAttestation: false,
    manifest: {
      path: loaded.path,
      sha256: loaded.fileSha256,
      expectedSha256: args.expectedSha256 ?? null,
      manifestId: manifest.manifestId,
      payloadSha256: manifest.payloadSha256,
    },
    source: {
      root: manifest.source.root,
      chromium: manifest.source.chromium,
      v8: manifest.source.v8,
      inputSha256: current.inputSha256,
    },
    build: {
      target: manifest.build.target,
      outDir: manifest.build.outDir,
      gnArgsSha256: manifest.build.gnArgsSha256,
      isComponentBuild: manifest.build.isComponentBuild,
      formalRelease,
    },
    artifacts: artifacts.map((entry) => ({
      name: entry.name,
      relativePath: entry.relativePath,
      kind: entry.kind,
      sha256: entry.sha256,
    })),
    checks: {
      pinnedManifestDigest: Boolean(args.expectedSha256),
      sidecarDigest: true,
      payloadDigest: true,
      enumeratedInputsBeforeAfterUnchanged: true,
      buildGraphBeforeAfterUnchanged: true,
      currentSourceMatches: true,
      currentBuildGraphMatches: true,
      artifactTreeMatches: true,
      patchLineageMatches:
        manifest.source.patches.lineage.orderedStablePatchIdsMatch === true &&
        manifest.source.v8.patches.lineage.orderedStablePatchIdsMatch === true,
      overlayMatches: manifest.source.overlay.exactCheckoutMatch === true,
      gnArgsMatch: manifest.build.expectedGnArgsMatch === true,
      localWorkflowConstructionObserved: true,
      trustedBuildAttestation: false,
      rootCheckoutClean: manifest.source.root.dirty === false,
      chromiumCheckoutClean: manifest.source.chromium.dirty === false,
      v8CheckoutClean: manifest.source.v8.checkout.dirty === false,
    },
  };
}

function snapshotArtifacts(args) {
  assert(
    args.output && args.outDir && args.artifacts.length > 0,
    'snapshot requires --output, --out-dir and --artifact',
  );
  const snapshot = collectBuildGraphSnapshot(args.outDir);
  qualificationFor(snapshot, args.allowDirty);
  const artifactRoot = args.artifactRoot ?? args.outDir;
  const artifacts = args.artifacts.map((path) => artifactEvidence(artifactRoot, path));
  ensureUniqueArtifacts(artifacts);
  let parentBuild = null;
  if (args.parentManifest) {
    const parent = readDocument(args.parentManifest, args.parentManifestSha256);
    assert(
      parent.document.schemaVersion === 3 &&
        parent.document.kind === 'aegis-build-identity' &&
        parent.document.phase === 'finalize',
      'parent manifest is not a finalized schema v3 build identity',
    );
    parentBuild = {
      path: parent.path,
      sha256: parent.fileSha256,
      manifestId: parent.document.manifestId,
      sourceArtifactSha256: parent.document.artifacts?.[0]?.sha256 ?? null,
      transform: 'local-copy-plist-and-sign-post-processing',
    };
  }
  const result = writeDocument(
    args.output,
    {
      schemaVersion: 3,
      kind: 'aegis-artifact-snapshot',
      phase: 'snapshot',
      manifestId: randomUUID(),
      generatedAt: new Date().toISOString(),
      releaseBoundary,
      qualification: 'diagnostic-only',
      source: snapshot.source,
      build: {...snapshot.build, ...snapshot.graph},
      artifactRoot: basename(realpathSync(artifactRoot)),
      parentBuild,
      artifacts,
      binding: {
        method: 'post-hoc-snapshot-only',
        sourceArtifactBinding: false,
        trustLevel: 'post-hoc-local-snapshot',
        trustedBuildAttestation: false,
        reason: 'No build-begin input freeze was supplied.',
      },
    },
    args.replace,
  );
  return {
    operation: 'snapshot',
    path: realpathSync(args.output),
    sha256: result.fileSha256,
    qualification: 'diagnostic-only',
    sourceArtifactBinding: false,
  };
}

function runSelfTest() {
  const root = mkdtempSync(join(tmpdir(), 'aegis-build-identity-test-'));
  const tests = [];
  const record = (name, callback) => {
    try {
      callback();
      tests.push({name, passed: true});
    } catch (error) {
      tests.push({name, passed: false, error: error.message});
    }
  };
  try {
    const tree = join(root, 'tree');
    mkdirSync(join(tree, 'nested'), {recursive: true});
    writeFileSync(join(tree, 'nested', 'value.txt'), 'alpha');
    symlinkSync('nested/value.txt', join(tree, 'value-link'));
    const original = treeEvidence(tree);
    record('目录树哈希具有确定性', () => {
      assert(canonical(treeEvidence(tree)) === canonical(original), 'tree hash drifted');
    });
    record('内容变化会改变目录树哈希', () => {
      writeFileSync(join(tree, 'nested', 'value.txt'), 'beta');
      assert(treeEvidence(tree).sha256 !== original.sha256, 'content tamper missed');
      writeFileSync(join(tree, 'nested', 'value.txt'), 'alpha');
    });
    record('权限变化会改变目录树哈希', () => {
      const path = join(tree, 'nested', 'value.txt');
      chmodSync(path, 0o744);
      assert(treeEvidence(tree).sha256 !== original.sha256, 'mode tamper missed');
      chmodSync(path, 0o644);
    });
    record('逃逸符号链接会被拒绝', () => {
      const path = join(tree, 'escape-link');
      symlinkSync('../outside', path);
      writeFileSync(join(root, 'outside'), 'outside');
      let rejected = false;
      try {
        treeEvidence(tree);
      } catch (error) {
        rejected = error instanceof IdentityError;
      }
      unlinkSync(path);
      assert(rejected, 'escaping symlink was accepted');
    });
    record('现有清单不会被静默覆盖', () => {
      const path = join(root, 'atomic.json');
      atomicPublish(path, 'first\n', false);
      let rejected = false;
      try {
        atomicPublish(path, 'second\n', false);
      } catch (error) {
        rejected = error instanceof IdentityError;
      }
      assert(rejected, 'existing file was overwritten');
      assert(readFileSync(path, 'utf8') === 'first\n', 'existing content changed');
    });
    record('payload 篡改会被拒绝', () => {
      const sealed = sealDocument({schemaVersion: 3, value: 'before'});
      sealed.value = 'after';
      let rejected = false;
      try {
        validateSealedDocument(sealed);
      } catch (error) {
        rejected = error instanceof IdentityError;
      }
      assert(rejected, 'payload tamper was accepted');
    });
    record('仅排除独立校验的 V8 gitlink 脏状态', () => {
      const repository = join(root, 'gitlink-status');
      mkdirSync(repository);
      run('git', ['init', '-q'], repository);
      run('git', ['config', 'user.name', 'Aegis Test'], repository);
      run('git', ['config', 'user.email', 'aegis@example.invalid'], repository);
      writeFileSync(join(repository, 'root.txt'), 'root\n');
      run('git', ['add', 'root.txt'], repository);
      run('git', ['commit', '-q', '-m', 'root'], repository);

      for (const path of ['v8', 'third_party/dependency']) {
        const checkout = join(repository, path);
        mkdirSync(checkout, {recursive: true});
        run('git', ['init', '-q'], checkout);
        run('git', ['config', 'user.name', 'Aegis Test'], checkout);
        run('git', ['config', 'user.email', 'aegis@example.invalid'], checkout);
        writeFileSync(join(checkout, 'value.txt'), 'clean\n');
        run('git', ['add', 'value.txt'], checkout);
        run('git', ['commit', '-q', '-m', 'base'], checkout);
        const sha = run('git', ['rev-parse', 'HEAD'], checkout);
        run(
          'git',
          ['update-index', '--add', '--cacheinfo', `160000,${sha},${path}`],
          repository,
        );
      }
      run('git', ['commit', '-q', '-m', 'gitlinks'], repository);
      run('git', ['config', 'diff.ignoreSubmodules', 'dirty'], repository);

      writeFileSync(join(repository, 'v8', 'value.txt'), 'dirty v8\n');
      writeFileSync(
        join(repository, 'third_party/dependency', '.DS_Store'),
        'local metadata\n',
      );
      assert(
        gitIdentity(repository, true, ['v8']).dirty === false,
        'V8-only dirt and untracked dependency metadata should be ignored',
      );
      writeFileSync(
        join(repository, 'third_party/dependency', 'untracked-header.h'),
        'build input\n',
      );
      assert(
        gitIdentity(repository, true, ['v8']).dirty === true,
        'untracked dependency source was hidden',
      );
      unlinkSync(join(repository, 'third_party/dependency', 'untracked-header.h'));
      writeFileSync(
        join(repository, 'third_party/dependency', 'value.txt'),
        'dirty dependency\n',
      );
      assert(
        gitIdentity(repository, true, ['v8']).dirty === true,
        'non-V8 gitlink dirt was hidden',
      );
    });
    record('artifact 路径穿越会被拒绝', () => {
      let rejected = false;
      try {
        safeRelativePath(tree, join(root, 'outside'));
      } catch (error) {
        rejected = error instanceof IdentityError;
      }
      assert(rejected, 'path traversal was accepted');
    });
    record('artifact 父目录符号链接逃逸会被拒绝', () => {
      const artifactRoot = join(root, 'artifact-root');
      const outsideRoot = join(root, 'artifact-outside');
      mkdirSync(artifactRoot);
      mkdirSync(outsideRoot);
      writeFileSync(join(outsideRoot, 'payload.bin'), 'outside');
      symlinkSync(outsideRoot, join(artifactRoot, 'escaped-parent'));
      let rejected = false;
      try {
        safeRelativePath(
          artifactRoot,
          join(artifactRoot, 'escaped-parent', 'payload.bin'),
        );
      } catch (error) {
        rejected = error instanceof IdentityError;
      }
      assert(rejected, 'parent symlink escape was accepted');
    });
    record('overlay 父目录符号链接逃逸会被拒绝', () => {
      const overlay = join(root, 'mapped-overlay');
      const checkout = join(root, 'mapped-checkout');
      const outside = join(root, 'mapped-outside');
      mkdirSync(join(overlay, 'nested'), {recursive: true});
      mkdirSync(checkout);
      mkdirSync(outside);
      writeFileSync(join(overlay, 'nested', 'value.txt'), 'same');
      writeFileSync(join(outside, 'value.txt'), 'same');
      symlinkSync(outside, join(checkout, 'nested'));
      let rejected = false;
      try {
        mappedTreeEvidence(overlay, checkout);
      } catch (error) {
        rejected = error instanceof IdentityError;
      }
      assert(rejected, 'overlay parent symlink escape was accepted');
    });
  } finally {
    rmSync(root, {force: true, recursive: true});
  }
  return {
    schemaVersion: 1,
    kind: 'aegis-build-identity-self-test',
    passed: tests.every((entry) => entry.passed),
    tests,
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.selfTest) {
    const report = runSelfTest();
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    if (!report.passed) {
      process.exitCode = 1;
    }
    return;
  }
  const operation = {
    begin: beginBuild,
    finalize: finalizeBuild,
    verify: verifyBuild,
    snapshot: snapshotArtifacts,
  }[args.phase];
  assert(operation, `unsupported phase: ${args.phase}`);
  const result = operation(args);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`build identity: ${error.message}\n`);
  process.exitCode = 1;
}
