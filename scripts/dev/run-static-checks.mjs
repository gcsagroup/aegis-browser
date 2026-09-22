#!/usr/bin/env node

import {spawnSync} from 'node:child_process';
import {mkdirSync, renameSync, writeFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {git, repoRoot} from '../ci/common.mjs';

const currentFile = fileURLToPath(import.meta.url);
const reportPath = resolve(repoRoot, '.artifacts/static-checks/report.json');
const maxBuffer = 64 * 1024 * 1024;
const pythonSyntaxProgram = [
  'import ast, pathlib, sys',
  'for name in sys.argv[1:]:',
  '    ast.parse(pathlib.Path(name).read_text(encoding="utf-8"), filename=name)',
].join('\n');

function byteSort(left, right) {
  return Buffer.from(left).compare(Buffer.from(right));
}

export function trackedFiles(patterns, cwd = repoRoot) {
  const raw = git(['ls-files', '-z', '--', ...patterns], {
    cwd,
    encoding: 'buffer',
  });
  return raw
    .toString('utf8')
    .split('\0')
    .filter(Boolean)
    .sort(byteSort);
}

export function collectStaticInventory(cwd = repoRoot) {
  return {
    javascript: trackedFiles(['*.js', '*.mjs', '*.cjs'], cwd),
    python: trackedFiles(['*.py'], cwd),
    shell: trackedFiles(['*.sh'], cwd),
    workflows: trackedFiles(
      ['.github/workflows/*.yml', '.github/workflows/*.yaml'],
      cwd,
    ),
  };
}

function commandResult(name, startedAt, result, items) {
  const finishedAt = new Date().toISOString();
  const error = result.error ? String(result.error.message ?? result.error) : null;
  const status = result.status ?? null;
  return {
    name,
    result: status === 0 && !error ? 'PASS' : 'FAIL',
    exitCode: status,
    items,
    startedAt,
    finishedAt,
    error,
  };
}

function emitOutput(result) {
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
}

function runCommand(name, executable, args, items = 1) {
  const startedAt = new Date().toISOString();
  process.stdout.write(`[static] ${name}\n`);
  const result = spawnSync(executable, args, {
    cwd: repoRoot,
    encoding: 'utf8',
    maxBuffer,
  });
  emitOutput(result);
  return commandResult(name, startedAt, result, items);
}

function runEachFile(name, executable, prefixArgs, files) {
  const startedAt = new Date().toISOString();
  process.stdout.write(`[static] ${name} (${files.length} files)\n`);
  for (const file of files) {
    const result = spawnSync(executable, [...prefixArgs, file], {
      cwd: repoRoot,
      encoding: 'utf8',
      maxBuffer,
    });
    if (result.status !== 0 || result.error) {
      process.stderr.write(`[static] ${name} failed: ${file}\n`);
      emitOutput(result);
      return commandResult(name, startedAt, result, files.length);
    }
  }
  return commandResult(
    name,
    startedAt,
    {status: 0, stdout: '', stderr: ''},
    files.length,
  );
}

function skippedCheck(name) {
  const now = new Date().toISOString();
  return {
    name,
    result: 'SKIP',
    exitCode: null,
    items: 0,
    startedAt: now,
    finishedAt: now,
    error: null,
  };
}

function runIfFiles(name, executable, args, files) {
  if (files.length === 0) return skippedCheck(name);
  return runCommand(name, executable, [...args, ...files], files.length);
}

export function staticCheckDefinitions(inventory) {
  return [
    ['command', 'static-runner-tests', process.execPath,
      ['--test', './scripts/dev/tests/*.test.mjs']],
    ['each-file', 'javascript-syntax', process.execPath, ['--check'],
      inventory.javascript],
    ['if-files', 'python-syntax', 'python3', ['-c', pythonSyntaxProgram],
      inventory.python],
    ['each-file', 'shell-syntax', 'bash', ['-n'], inventory.shell],
    ['if-files', 'actionlint', 'actionlint', [], inventory.workflows],
    ['if-files', 'shellcheck-warning', 'shellcheck', ['-S', 'warning'],
      inventory.shell],
    ['command', 'eslint-static-scope', 'corepack',
      ['pnpm', 'run', 'lint:static']],
    ['command', 'typescript-typecheck', 'corepack',
      ['pnpm', 'run', 'typecheck']],
  ].map(([mode, name, executable, args, files]) => ({
    mode,
    name,
    executable,
    args,
    files,
  }));
}

function runStaticCheck({mode, name, executable, args, files}) {
  if (mode === 'each-file') {
    return runEachFile(name, executable, args, files);
  }
  if (mode === 'if-files') {
    return runIfFiles(name, executable, args, files);
  }
  return runCommand(name, executable, args);
}

function buildReport(startedAt, inventory, checks) {
  const failed = checks.filter((check) => check.result === 'FAIL');
  return {
    schemaVersion: 1,
    result: failed.length === 0 ? 'PASS' : 'FAIL',
    startedAt,
    finishedAt: new Date().toISOString(),
    inventory: Object.fromEntries(
      Object.entries(inventory).map(([name, files]) => [name, files.length]),
    ),
    checks,
  };
}

function writeReport(report) {
  mkdirSync(dirname(reportPath), {recursive: true});
  const temporary = `${reportPath}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  renameSync(temporary, reportPath);
}

function main() {
  const startedAt = new Date().toISOString();
  const inventory = collectStaticInventory();
  const checks = staticCheckDefinitions(inventory).map(runStaticCheck);
  const report = buildReport(startedAt, inventory, checks);
  writeReport(report);
  process.stdout.write(`[static] report: ${reportPath}\n`);

  if (report.result === 'FAIL') {
    const failed = checks.filter((check) => check.result === 'FAIL');
    process.stderr.write(
      `[static] failed checks: ${failed.map((check) => check.name).join(', ')}\n`,
    );
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === currentFile) {
  main();
}
