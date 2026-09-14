#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
import {existsSync, readFileSync, readdirSync, statSync} from 'node:fs';
import {isAbsolute, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {fail, isInside, parseArgs, repoRoot} from './common.mjs';

try {
  const {values} = parseArgs(process.argv.slice(2), ['raw-dir']);
  if (!values['raw-dir']) fail('--raw-dir is required');
  const directory = resolve(values['raw-dir']);
  if (!isAbsolute(values['raw-dir']) || !isInside(repoRoot, directory)) fail('V8 raw directory must be absolute and inside the repository');
  if (!existsSync(directory) || !statSync(directory).isDirectory()) fail('V8 raw coverage directory is missing');
  const reports = readdirSync(directory).filter((name) => /^coverage-.*\.json$/u.test(name));
  if (reports.length === 0) fail('V8 raw coverage contains no reports');
  const sources = new Set();
  for (const name of reports) {
    let report;
    try { report = JSON.parse(readFileSync(resolve(directory, name), 'utf8')); } catch { fail(`V8 raw coverage is invalid JSON: ${name}`); }
    if (!Array.isArray(report?.result)) fail(`V8 raw coverage has no result array: ${name}`);
    for (const entry of report.result) {
      if (typeof entry.url !== 'string' || !entry.url.startsWith('file:')) continue;
      let path;
      try { path = fileURLToPath(entry.url); } catch { continue; }
      if (isInside(repoRoot, path)) sources.add(path);
    }
  }
  const required = [
    resolve(repoRoot, 'apps/browser/scripts/verify-agent-runtime.mjs'),
    resolve(repoRoot, 'scripts/check-repo-contracts.mjs'),
  ];
  const missing = required.filter((path) => !sources.has(path));
  if (missing.length > 0) fail(`V8 raw coverage misses executed production subprocesses: ${missing.join(', ')}`);
  console.log(JSON.stringify({status: 'PASS', rawFiles: reports.length, repositorySources: sources.size}));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
