#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
import {createHash} from 'node:crypto';
import {existsSync, readFileSync, readdirSync, statSync} from 'node:fs';
import {isAbsolute, join, posix, relative, resolve, sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import {fail, isInside, parseArgs, repoRoot} from './common.mjs';

function repositoryPath(absolute) {
  return relative(repoRoot, absolute).split(sep).join('/');
}

function productionSources(directory) {
  const files = [];
  for (const entry of readdirSync(directory, {withFileTypes: true})) {
    const absolute = join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...productionSources(absolute));
    } else if (
      entry.isFile() &&
      entry.name.endsWith('.ts') &&
      !entry.name.endsWith('.test.ts') &&
      !entry.name.endsWith('.d.ts') &&
      !entry.name.endsWith('.d.mts')
    ) {
      files.push(repositoryPath(absolute));
    }
  }
  return files.sort();
}

function readFreshFile(path, notBefore) {
  if (!existsSync(path) || !statSync(path).isFile()) fail(`Coverage output is missing: ${path}`);
  const stat = statSync(path);
  if (stat.size === 0) fail(`Coverage output is empty: ${path}`);
  if (notBefore != null && stat.mtimeMs < notBefore) fail(`Coverage output is stale: ${path}`);
  return readFileSync(path, 'utf8');
}

export function parseCoverageSummary(source, label = 'coverage-summary.json') {
  let summary;
  try {
    summary = JSON.parse(source);
  } catch {
    fail(`${label} is not valid JSON`);
  }
  const total = summary?.total;
  for (const metric of ['lines', 'statements', 'functions', 'branches']) {
    const item = total?.[metric];
    if (
      !item || !Number.isInteger(item.total) || item.total < 0 ||
      !Number.isInteger(item.covered) || item.covered < 0 || item.covered > item.total ||
      !Number.isFinite(item.pct) || item.pct < 0 || item.pct > 100
    ) {
      fail(`${label} has invalid total.${metric}`);
    }
    const expectedPct = item.total === 0 ? 100 : Math.floor((item.covered / item.total) * 10000) / 100;
    if (Math.abs(item.pct - expectedPct) > 0.01) fail(`${label} has inconsistent total.${metric}.pct`);
  }
  return total;
}

export function parseLcov(
  source,
  sourceRoot,
  {allowLineSummarySuperset = false} = {},
) {
  if (!source.endsWith('\n')) fail('lcov.info must end with a newline');
  const records = source.split('end_of_record\n').filter((record) => record.trim() !== '');
  const terminators = source.match(/^end_of_record$/gmu)?.length ?? 0;
  if (terminators !== records.length) fail('lcov.info contains an unterminated record');
  if (records.length === 0) fail('lcov.info contains no records');
  const files = new Set();
  const totals = {
    lines: {total: 0, covered: 0},
    functions: {total: 0, covered: 0},
    branches: {total: 0, covered: 0},
  };
  for (const record of records) {
    const lines = record.trim().split('\n');
    const sourceLines = lines.filter((line) => line.startsWith('SF:'));
    const dataLines = lines.filter((line) => line.startsWith('DA:'));
    const lfLines = lines.filter((line) => line.startsWith('LF:'));
    const lhLines = lines.filter((line) => line.startsWith('LH:'));
    if (sourceLines.length !== 1 || lfLines.length !== 1 || lhLines.length !== 1) {
      fail('lcov.info contains an invalid record');
    }
    const lf = Number(lfLines[0].slice(3));
    const lh = Number(lhLines[0].slice(3));
    if (!Number.isInteger(lf) || lf < 0 || !Number.isInteger(lh) || lh < 0 || lh > lf) fail('lcov.info contains invalid line totals');
    const seenLines = new Set();
    let coveredLines = 0;
    for (const line of dataLines) {
      const match = /^DA:(\d+),(\d+)(?:,.*)?$/u.exec(line);
      if (!match || Number(match[1]) < 1 || seenLines.has(match[1])) fail('lcov.info contains invalid or duplicate DA data');
      seenLines.add(match[1]);
      if (Number(match[2]) > 0) coveredLines += 1;
    }
    if (allowLineSummarySuperset) {
      const reportedUncovered = seenLines.size - coveredLines;
      const summaryUncovered = lf - lh;
      if (
        seenLines.size > lf ||
        coveredLines > lh ||
        reportedUncovered !== summaryUncovered
      ) {
        fail('lcov.info DA data exceeds line summary totals');
      }
    } else if (seenLines.size !== lf || coveredLines !== lh) {
      fail('lcov.info line totals do not match DA data');
    }
    totals.lines.total += lf;
    totals.lines.covered += lh;
    for (const [totalPrefix, coveredPrefix, metric] of [
      ['FNF:', 'FNH:', 'functions'],
      ['BRF:', 'BRH:', 'branches'],
    ]) {
      const totalLines = lines.filter((line) => line.startsWith(totalPrefix));
      const coveredMetricLines = lines.filter((line) => line.startsWith(coveredPrefix));
      if (totalLines.length !== 1 || coveredMetricLines.length !== 1) fail(`lcov.info contains invalid ${metric} totals`);
      const total = Number(totalLines[0].slice(totalPrefix.length));
      const covered = Number(coveredMetricLines[0].slice(coveredPrefix.length));
      if (!Number.isInteger(total) || total < 0 || !Number.isInteger(covered) || covered < 0 || covered > total) {
        fail(`lcov.info contains invalid ${metric} totals`);
      }
      totals[metric].total += total;
      totals[metric].covered += covered;
    }
    const path = sourceLines[0].slice(3);
    if (!path || isAbsolute(path) || path.includes('\\') || path.split('/').includes('..') || posix.normalize(path) !== path) {
      fail(`lcov.info contains an unsafe source path: ${path}`);
    }
    const absolute = resolve(repoRoot, path);
    if (!isInside(sourceRoot, absolute)) fail(`lcov.info source is outside the production scope: ${path}`);
    if (!existsSync(absolute) || !statSync(absolute).isFile()) fail(`lcov.info source does not exist: ${path}`);
    if (files.has(path)) fail(`lcov.info repeats source: ${path}`);
    files.add(path);
  }
  for (const metric of Object.values(totals)) {
    metric.pct = metric.total === 0 ? 100 : Math.floor((metric.covered / metric.total) * 10000) / 100;
  }
  return {files: [...files].sort(), totals};
}

export function validateCoverage({coverageDirectory, sourceDirectory, notBefore}) {
  if (!isAbsolute(coverageDirectory)) fail('--coverage-dir must be absolute');
  if (!isInside(repoRoot, coverageDirectory)) fail('Coverage directory must stay inside the repository');
  if (!isInside(repoRoot, sourceDirectory) || !existsSync(sourceDirectory) || !statSync(sourceDirectory).isDirectory()) {
    fail('Source root must be an existing repository directory');
  }
  const lcovPath = join(coverageDirectory, 'lcov.info');
  const summaryPath = join(coverageDirectory, 'coverage-summary.json');
  const lcov = readFreshFile(lcovPath, notBefore);
  const summary = parseCoverageSummary(readFreshFile(summaryPath, notBefore));
  const lcovResult = parseLcov(lcov, sourceDirectory);
  const coveredSources = lcovResult.files;
  const expectedSources = productionSources(sourceDirectory);
  const missing = expectedSources.filter((path) => !coveredSources.includes(path));
  if (missing.length > 0) fail(`lcov.info omits production source files: ${missing.join(', ')}`);
  const unexpected = coveredSources.filter((path) => !expectedSources.includes(path));
  if (unexpected.length > 0) fail(`lcov.info includes non-production source files: ${unexpected.join(', ')}`);
  for (const metric of ['lines', 'functions', 'branches']) {
    if (
      summary[metric].total !== lcovResult.totals[metric].total ||
      summary[metric].covered !== lcovResult.totals[metric].covered
    ) fail(`coverage-summary.json ${metric} totals do not match lcov.info`);
  }
  return {
    status: 'PASS',
    scope: repositoryPath(sourceDirectory),
    scopeKind: 'packages-core-typescript-production',
    lcovPath: repositoryPath(lcovPath),
    summaryPath: repositoryPath(summaryPath),
    lcovSha256: createHash('sha256').update(lcov).digest('hex'),
    productionFiles: expectedSources.length,
    reportedFiles: coveredSources.length,
    totals: summary,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const {values} = parseArgs(process.argv.slice(2), ['coverage-dir', 'source-root', 'not-before']);
    if (!values['coverage-dir'] || !values['source-root']) fail('--coverage-dir and --source-root are required');
    const notBefore = values['not-before'] ? Date.parse(values['not-before']) : null;
    if (values['not-before'] && !Number.isFinite(notBefore)) fail('--not-before must be an ISO timestamp');
    const result = validateCoverage({
      coverageDirectory: resolve(values['coverage-dir']),
      sourceDirectory: resolve(repoRoot, values['source-root']),
      notBefore,
    });
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}