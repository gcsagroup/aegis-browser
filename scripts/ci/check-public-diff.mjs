#!/usr/bin/env node
import {basename, resolve} from 'node:path';
import {fail, git, parseArgs, repoRoot, resolveCommit} from './common.mjs';

function isPersonalInstruction(path) {
  const name = basename(path).toLocaleLowerCase('en-US');
  return name === 'agents.md' || name === 'agent.md';
}

function changedPaths(args, cwd) {
  const output = git(args, {cwd, encoding: 'buffer'}).toString('utf8');
  return output.split('\0').filter(Boolean);
}

try {
  const {values} = parseArgs(process.argv.slice(2), ['base', 'head', 'repo']);
  const cwd = resolve(values.repo ?? repoRoot);
  const base = resolveCommit(values.base, cwd);
  const head = resolveCommit(values.head ?? 'HEAD', cwd);
  const mergeBase = git(['merge-base', base, head], {cwd}).trim();
  if (mergeBase !== base) fail(`Public export base ${base} is not an ancestor of ${head}`);

  const finalPaths = changedPaths(
    ['diff', '--name-status', '-z', '--find-renames', `${base}..${head}`],
    cwd,
  );
  const leaks = new Set(finalPaths.filter(isPersonalInstruction));
  const commits = git(['rev-list', '--reverse', `${base}..${head}`], {cwd})
    .trim()
    .split(/\s+/u)
    .filter(Boolean);
  for (const commit of commits) {
    const paths = changedPaths(
      ['diff-tree', '--root', '-m', '--no-commit-id', '--name-status', '-r', '-z', '--find-renames', commit],
      cwd,
    );
    for (const path of paths) {
      if (isPersonalInstruction(path)) leaks.add(`${commit}:${path}`);
    }
  }
  if (leaks.size > 0) {
    fail(`Personal instruction files are present in the public export diff/history: ${[...leaks].join(', ')}`);
  }
  console.log(JSON.stringify({status: 'PASS', base, head, commits: commits.length, changedPaths: finalPaths.length}));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
