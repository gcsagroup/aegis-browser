#!/usr/bin/env node
import {resolve} from 'node:path';
import {git, parseArgs, repoRoot, resolveCommit} from './common.mjs';

function classify(path) {
  if (/^apps\/browser\/(?:overlay|patches)\//u.test(path)) return 'REQUIRED';
  if (/^apps\/browser\/(?:CHROMIUM_COMMIT|CHROMIUM_VERSION)$/u.test(path)) return 'REQUIRED';
  if (/\.(?:cc|h|gn|gni)$/u.test(path)) return 'REQUIRED';
  if (/^apps\/browser\/scripts\/(?:apply-patches|build|fetch-chromium|seed-|sync-)/u.test(path)) return 'REQUIRED';
  if (/^(?:apps\/browser|packages\/core)\//u.test(path)) return 'REVIEW_REQUIRED';
  return 'NOT_APPLICABLE';
}

try {
  const {values} = parseArgs(process.argv.slice(2), ['base', 'head', 'repo']);
  const cwd = resolve(values.repo ?? repoRoot);
  const base = resolveCommit(values.base, cwd);
  const head = resolveCommit(values.head ?? 'HEAD', cwd);
  const paths = new Set(
    git(['diff', '--name-only', `${base}...${head}`], {cwd})
      .trim().split(/\r?\n/u).filter(Boolean),
  );
  if (process.argv.includes('--include-worktree')) {
    for (const path of git(['diff', '--name-only', head], {cwd}).trim().split(/\r?\n/u).filter(Boolean)) paths.add(path);
    for (const path of git(['ls-files', '--others', '--exclude-standard'], {cwd}).trim().split(/\r?\n/u).filter(Boolean)) paths.add(path);
  }
  let status = 'NOT_APPLICABLE';
  for (const path of paths) {
    const current = classify(path);
    if (current === 'REQUIRED') status = 'REQUIRED';
    else if (current === 'REVIEW_REQUIRED' && status === 'NOT_APPLICABLE') status = current;
  }
  console.log(JSON.stringify({status, base, head, paths: [...paths].filter((path) => classify(path) !== 'NOT_APPLICABLE')}));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
