#!/usr/bin/env node
import {spawn} from 'node:child_process';
import {mkdirSync, cpSync, renameSync, rmSync, writeFileSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {
  fail,
  git,
  isInside,
  parseArgs,
  repoRoot,
  repositorySlug,
  resolveCommit,
  sourceSnapshot,
} from './common.mjs';

const requiredVersions = {
  node: '22.23.1',
  pnpm: '9.15.0',
  python: '3.11.9',
};

const {values} = parseArgs(process.argv.slice(2), ['scope', 'base', 'report-dir', 'public-base']);
if ((values.scope ?? 'full') !== 'full') fail('Only --scope full is supported');
if (!values.base) fail('--base is required');

const startedAt = new Date().toISOString();
const defaultDirectory = `.artifacts/ci/local-${startedAt.replace(/[:.]/gu, '-')}`;
const reportDirectory = resolve(repoRoot, values['report-dir'] ?? defaultDirectory);
const evidenceRoot = resolve(repoRoot, '.artifacts/ci');
if (!isInside(evidenceRoot, reportDirectory)) fail(`Report directory must stay under ${evidenceRoot}`);
mkdirSync(reportDirectory, {recursive: true});
const logPath = join(reportDirectory, 'run-quality.log');
const reportPath = join(reportDirectory, 'report.json');
const checks = [];
const versions = {};
let initialSource;
let finalSource;
let nativeIntegration = 'UNKNOWN';
let coverage = null;
let failure;

function appendLog(message) {
  writeFileSync(logPath, message, {flag: 'a'});
}

function commandLabel(command, args) {
  return [command, ...args].map((part) => (/^[A-Za-z0-9_./:=@+-]+$/u.test(part) ? part : JSON.stringify(part))).join(' ');
}

async function command(name, executable, args, options = {}) {
  const check = {name, startedAt: new Date().toISOString(), result: 'RUNNING'};
  checks.push(check);
  const label = commandLabel(executable, args);
  appendLog(`\n$ ${label}\n`);
  process.stdout.write(`\n[${name}] ${label}\n`);
  let stdout = '';
  let stderr = '';
  const exitCode = await new Promise((resolveExit, reject) => {
    const child = spawn(executable, args, {
      cwd: options.cwd ?? repoRoot,
      env: options.env ?? process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.on('error', reject);
    child.stdout.on('data', (chunk) => {
      const text = chunk.toString();
      stdout += text;
      appendLog(text);
      process.stdout.write(text);
    });
    child.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      stderr += text;
      appendLog(text);
      process.stderr.write(text);
    });
    child.on('close', resolveExit);
  });
  check.exitCode = exitCode;
  check.finishedAt = new Date().toISOString();
  check.result = exitCode === 0 ? 'PASS' : 'FAIL';
  if (exitCode !== 0) throw new Error(`${name} failed with exit code ${exitCode}`);
  return {stdout, stderr};
}

async function captureVersion(name, executable, args, expected, pattern = /([0-9]+(?:\.[0-9]+){1,2})/u) {
  const result = await command(`preflight:${name}`, executable, args);
  const match = pattern.exec(`${result.stdout}\n${result.stderr}`);
  if (!match) throw new Error(`Could not parse ${name} version`);
  versions[name] = match[1];
  if (expected && versions[name] !== expected) {
    const check = checks.at(-1);
    check.result = 'FAIL';
    check.detail = `expected ${expected}, got ${versions[name]}`;
    throw new Error(`${name} must be ${expected}, got ${versions[name]}`);
  }
}

function writeReport(result) {
  const currentCommit = (() => {
    try { return resolveCommit('HEAD'); } catch { return null; }
  })();
  const base = (() => {
    try { return resolveCommit(values.base); } catch { return values.base; }
  })();
  const event = process.env.GITHUB_ACTIONS === 'true' ? process.env.CI_EVENT : 'local';
  const report = {
    schemaVersion: 1,
    repository: process.env.GITHUB_REPOSITORY ?? repositorySlug(),
    event,
    pullRequest: process.env.CI_PR_NUMBER ? Number(process.env.CI_PR_NUMBER) : null,
    headSha: process.env.CI_HEAD_SHA ?? currentCommit,
    baseSha: process.env.CI_BASE_SHA ?? base,
    testedSha: process.env.CI_TESTED_SHA ?? currentCommit,
    testedTree: currentCommit ? git(['rev-parse', `${currentCommit}^{tree}`]).trim() : null,
    runId: process.env.GITHUB_RUN_ID ?? null,
    runAttempt: process.env.GITHUB_RUN_ATTEMPT ? Number(process.env.GITHUB_RUN_ATTEMPT) : null,
    scope: 'full',
    result,
    startedAt,
    finishedAt: new Date().toISOString(),
    tools: versions,
    inputSource: initialSource ?? null,
    finalSource: finalSource ?? null,
    sourceStable: Boolean(initialSource && finalSource && initialSource.digest === finalSource.digest && initialSource.files === finalSource.files),
    nativeIntegration,
    coverage,
    checks,
    failure: failure ? {message: failure.message} : null,
  };
  const temporary = `${reportPath}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(report, null, 2)}\n`);
  renameSync(temporary, reportPath);
}

try {
  await captureVersion('node', process.execPath, ['--version'], requiredVersions.node, /v([0-9]+(?:\.[0-9]+){2})/u);
  await captureVersion('pnpm', 'pnpm', ['--version'], requiredVersions.pnpm);
  await captureVersion('python', 'python3', ['--version'], requiredVersions.python);
  await captureVersion('git', 'git', ['--version'], null);
  await captureVersion('ripgrep', 'rg', ['--version'], null);
  await captureVersion('clang', 'clang++', ['--version'], null);
  const base = resolveCommit(values.base);

  if (process.env.GITHUB_ACTIONS === 'true') {
    const required = ['CI_EVENT', 'CI_BASE_SHA', 'CI_HEAD_SHA', 'CI_TESTED_SHA', 'CI_REF'];
    for (const name of required) if (!process.env[name]) throw new Error(`CI metadata is missing ${name}`);
    await command('ci-identity', process.execPath, [
      'scripts/ci/verify-ci-identity.mjs',
      '--event', process.env.CI_EVENT,
      '--base', process.env.CI_BASE_SHA,
      '--head', process.env.CI_HEAD_SHA,
      '--tested', process.env.CI_TESTED_SHA,
      '--ref', process.env.CI_REF,
    ]);
    if (base !== resolveCommit(process.env.CI_BASE_SHA)) throw new Error('--base does not match trusted CI metadata');
  }

  initialSource = sourceSnapshot();
  appendLog(`input-source ${JSON.stringify(initialSource)}\n`);
  await command('install', 'pnpm', ['install', '--frozen-lockfile']);
  await captureVersion('coverage-pnpm', 'corepack', ['pnpm', '--version'], requiredVersions.pnpm);
  const coverageRoot = join(reportDirectory, 'coverage');
  const coverageDirectory = join(coverageRoot, 'core');
  const javascriptRawDirectory = join(coverageRoot, 'javascript-raw');
  const javascriptDirectory = join(coverageRoot, 'javascript');
  const nativeCoverageDirectory = join(coverageRoot, 'cpp-access-standalone');
  const pythonCoverageDirectory = join(coverageRoot, 'python');
  const pythonVenv = join(reportDirectory, '.python-coverage-venv');
  rmSync(coverageRoot, {recursive: true, force: true});
  rmSync(pythonVenv, {recursive: true, force: true});
  mkdirSync(javascriptRawDirectory, {recursive: true});
  mkdirSync(pythonCoverageDirectory, {recursive: true});
  await command('python-coverage-venv', 'python3', ['-m', 'venv', pythonVenv]);
  const coverageExecutable = join(pythonVenv, 'bin/coverage');
  await command('python-coverage-install', join(pythonVenv, 'bin/python'), [
    '-m', 'pip', 'install', '--disable-pip-version-check',
    '-r', 'scripts/ci/python-coverage-requirements.txt',
  ]);
  await captureVersion('coverage.py', coverageExecutable, ['--version'], '7.16.1');
  await command('license-metadata', process.execPath, [
    'scripts/ci/check-license-metadata.mjs',
    '--output', join(reportDirectory, 'license-metadata.json'),
  ]);
  const instrumentedEnvironment = {
    ...process.env,
    AEGIS_NATIVE_COVERAGE_DIR: nativeCoverageDirectory,
    AEGIS_PYTHON_COVERAGE_BIN: coverageExecutable,
    AEGIS_PYTHON_COVERAGE_SOURCE: [
      join(repoRoot, 'apps/browser/scripts'),
      join(repoRoot, 'apps/browser/overlay/components/aegis_access'),
    ].join(','),
    CORE_COVERAGE_DIR: coverageDirectory,
    COVERAGE_FILE: join(pythonCoverageDirectory, '.coverage'),
    COVERAGE_RCFILE: join(repoRoot, '.coveragerc'),
    NODE_V8_COVERAGE: javascriptRawDirectory,
  };
  const coverageStartedAt = new Date().toISOString();
  await command('quality:fast', 'corepack', ['pnpm', 'run', 'quality:fast'], {
    env: instrumentedEnvironment,
  });
  await command('javascript-coverage-raw-validation', process.execPath, [
    'scripts/ci/validate-v8-raw.mjs', '--raw-dir', javascriptRawDirectory,
  ]);
  await command('python-coverage-combine', coverageExecutable, [
    'combine', pythonCoverageDirectory,
  ], {env: instrumentedEnvironment});
  await command('python-coverage-xml', coverageExecutable, [
    'xml', '-o', join(pythonCoverageDirectory, 'coverage.xml'),
  ], {env: instrumentedEnvironment});
  await command('python-coverage-json', coverageExecutable, [
    'json', '-o', join(pythonCoverageDirectory, 'coverage.json'),
  ], {env: instrumentedEnvironment});
  await command('python-coverage-lcov', coverageExecutable, [
    'lcov', '-o', join(pythonCoverageDirectory, 'lcov.info'),
  ], {env: instrumentedEnvironment});
  const pythonText = await command('python-coverage-text', coverageExecutable, [
    'report', '--show-missing',
  ], {env: instrumentedEnvironment});
  writeFileSync(join(pythonCoverageDirectory, 'coverage.txt'), pythonText.stdout);
  const coverageCheck = await command('coverage-validation', process.execPath, [
    'scripts/ci/validate-coverage.mjs',
    '--coverage-dir', coverageDirectory,
    '--source-root', 'packages/core/src',
    '--not-before', coverageStartedAt,
  ]);
  coverage = JSON.parse(coverageCheck.stdout);
  await command('access-freeze', process.execPath, ['scripts/ci/check-access-freeze.mjs', '--base', base], {
    env: instrumentedEnvironment,
  });

  const previewDirectory = join(reportDirectory, 'preview-work');
  rmSync(previewDirectory, {recursive: true, force: true});
  mkdirSync(previewDirectory, {recursive: true});
  for (const name of ['interaction-example.html', 'verify-preview.cjs']) {
    cpSync(join(repoRoot, 'docs/plans/access-service-v1.0', name), join(previewDirectory, name));
  }
  const preview = await command('preview', process.execPath, [join(previewDirectory, 'verify-preview.cjs')], {
    env: instrumentedEnvironment,
  });
  const previewResult = JSON.parse(preview.stdout);
  if (previewResult.status !== 'PASS' || previewResult.checks?.length !== 13) {
    throw new Error('Preview verification must report PASS with exactly 13 scenarios');
  }
  writeFileSync(join(reportDirectory, 'preview-result.json'), `${JSON.stringify(previewResult, null, 2)}\n`);

  await command('ci-tests', 'corepack', ['pnpm', 'run', 'ci:test'], {env: instrumentedEnvironment});
  await command('workflow-validation', 'corepack', ['pnpm', 'run', 'ci:validate-workflow'], {env: instrumentedEnvironment});
  if (values['public-base']) {
    await command('public-export', process.execPath, [
      'scripts/ci/check-public-diff.mjs', '--base', values['public-base'], '--head', 'HEAD',
    ]);
  }
  const classification = await command('native-classification', process.execPath, [
    'scripts/ci/classify-native-changes.mjs', '--base', base, '--head', 'HEAD', '--include-worktree',
  ]);
  nativeIntegration = JSON.parse(classification.stdout).status;
  const reportEnvironment = {...process.env};
  delete reportEnvironment.NODE_V8_COVERAGE;
  const javascriptText = await command('javascript-coverage-report', 'pnpm', [
    'exec', 'c8', 'report',
    '--temp-directory', javascriptRawDirectory,
    '--report-dir', javascriptDirectory,
    '--reporter', 'text',
    '--reporter', 'json-summary',
    '--reporter', 'lcovonly',
    '--all',
    '--extension', '.js',
    '--extension', '.cjs',
    '--extension', '.mjs',
    '--include', 'scripts/**/*.mjs',
    '--include', 'packages/core/scripts/**/*.mjs',
    '--include', 'packages/core/src/**/*.mjs',
    '--include', 'apps/browser/scripts/**/*.js',
    '--include', 'apps/browser/scripts/**/*.mjs',
    '--include', 'apps/browser/scripts/**/*.cjs',
    '--exclude', '**/*_test.mjs',
    '--exclude', '**/*.test.mjs',
    '--exclude', '**/fixtures/**',
    '--exclude', 'scripts/ci/tests/**',
  ], {env: reportEnvironment});
  writeFileSync(join(javascriptDirectory, 'coverage.txt'), javascriptText.stdout);
  rmSync(javascriptRawDirectory, {recursive: true, force: true});
  rmSync(pythonVenv, {recursive: true, force: true});
  const coverageManifestPath = join(reportDirectory, 'coverage-manifest.json');
  const coverageManifest = await command('coverage-manifest', process.execPath, [
    'scripts/ci/build-coverage-manifest.mjs',
    '--coverage-root', coverageRoot,
    '--output', coverageManifestPath,
    '--tested-sha', process.env.CI_TESTED_SHA ?? 'HEAD',
    '--not-before', coverageStartedAt,
  ]);
  coverage = JSON.parse(coverageManifest.stdout);
  finalSource = sourceSnapshot();
  if (initialSource.digest !== finalSource.digest || initialSource.files !== finalSource.files) {
    throw new Error(`Source changed during quality run: ${initialSource.digest}/${initialSource.files} -> ${finalSource.digest}/${finalSource.files}`);
  }
  checks.push({name: 'source-stability', result: 'PASS', startedAt: new Date().toISOString(), finishedAt: new Date().toISOString(), exitCode: 0});
  writeReport('PASS');
  console.log(`Quality gate PASS; report: ${reportPath}`);
} catch (error) {
  failure = error;
  try { finalSource = sourceSnapshot(); } catch { finalSource = null; }
  writeReport('FAIL');
  console.error(`Quality gate FAIL: ${error.message}`);
  console.error(`Failure report: ${reportPath}`);
  process.exitCode = 1;
}
