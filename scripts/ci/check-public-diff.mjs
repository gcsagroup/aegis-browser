#!/usr/bin/env node
import {execFileSync} from 'node:child_process';
import {posix, resolve} from 'node:path';
import {fail, git, parseArgs, repoRoot, resolveCommit} from './common.mjs';

function isPersonalInstruction(path) {
  const name = path.split(/[\\/]/u).at(-1)?.toLocaleLowerCase('en-US');
  return name === 'agents.md' || name === 'agent.md';
}

function nulPaths(args, cwd) {
  return git(args, {cwd, encoding: 'buffer'}).toString('utf8').split('\0').filter(Boolean);
}

function treeEntry(ref, path, cwd) {
  const output = git(
    ['ls-tree', '-z', ref, '--', `:(literal)${path}`],
    {cwd, encoding: 'buffer'},
  );
  if (output.length === 0) return null;
  const record = output.toString('utf8').split('\0').filter(Boolean)[0];
  const match = /^(\d+)\s+(\S+)\s+([0-9a-f]{40,64})\t/u.exec(record);
  if (!match) fail(`Cannot parse Git tree entry for ${path} at ${ref}`);
  return {mode: match[1], type: match[2], object: match[3]};
}

function symlinkTarget(entry, cwd) {
  const content = execFileSync('git', ['cat-file', 'blob', entry.object], {
    cwd,
    encoding: 'buffer',
    maxBuffer: 1024 * 1024,
  });
  if (content.includes(0)) fail(`Symlink blob ${entry.object} contains NUL`);
  const target = content.toString('utf8');
  if (!target) fail(`Symlink blob ${entry.object} has an empty target`);
  return target;
}

function symlinkComponents(target, context) {
  if (posix.isAbsolute(target) || /^[A-Za-z]:[\\/]/u.test(target) || target.startsWith('\\\\')) {
    fail(`Public export symlink has an absolute/external target at ${context}: ${target}`);
  }
  return target.replaceAll('\\', '/').split('/');
}

function resolveSymlinkChain(ref, linkPath, target, cwd) {
  const directory = posix.dirname(linkPath);
  const resolved = directory === '.' ? [] : directory.split('/').filter(Boolean);
  let pending = symlinkComponents(target, linkPath);
  const seen = new Set();
  let hops = 0;
  while (pending.length > 0) {
    const component = pending.shift();
    if (!component || component === '.') continue;
    if (component === '..') {
      if (resolved.length === 0) {
        fail(`Public export symlink escapes the repository at ${linkPath}: ${target}`);
      }
      resolved.pop();
      continue;
    }

    if (isPersonalInstruction(component)) {
      fail(`Public export symlink resolves through a personal instruction at ${linkPath}: ${component}`);
    }
    resolved.push(component);
    const prefix = resolved.join('/');
    const entry = treeEntry(ref, prefix, cwd);
    if (entry?.mode !== '120000') continue;

    hops += 1;
    if (hops > 32) fail(`Public export symlink chain exceeds 32 hops at ${linkPath}`);
    const key = `${prefix}\0${entry.object}`;
    if (seen.has(key)) fail(`Public export symlink chain cycles at ${prefix}`);
    seen.add(key);

    const nestedTarget = symlinkTarget(entry, cwd);
    resolved.pop();
    pending = [...symlinkComponents(nestedTarget, prefix), ...pending];
  }
}

function inspectChangedPath(ref, path, cwd, leaks) {
  if (isPersonalInstruction(path)) leaks.add(`${ref}:${path}`);
  const entry = treeEntry(ref, path, cwd);
  if (entry?.mode === '120000') {
    resolveSymlinkChain(ref, path, symlinkTarget(entry, cwd), cwd);
  }
}

try {
  const {values} = parseArgs(process.argv.slice(2), ['base', 'head', 'repo']);
  const cwd = resolve(values.repo ?? repoRoot);
  const base = resolveCommit(values.base, cwd);
  const head = resolveCommit(values.head ?? 'HEAD', cwd);
  const mergeBase = git(['merge-base', base, head], {cwd}).trim();
  if (mergeBase !== base) fail(`Public export base ${base} is not an ancestor of ${head}`);

  const leaks = new Set();
  const finalPaths = nulPaths(
    ['diff', '--name-only', '-z', '--no-renames', `${base}..${head}`],
    cwd,
  );
  for (const path of finalPaths) inspectChangedPath(head, path, cwd, leaks);

  const commits = git(['rev-list', '--reverse', `${base}..${head}`], {cwd})
    .trim()
    .split(/\s+/u)
    .filter(Boolean);
  for (const commit of commits) {
    const paths = nulPaths(
      ['diff-tree', '--root', '-m', '--no-commit-id', '--name-only', '-r', '-z', '--no-renames', commit],
      cwd,
    );
    for (const path of paths) inspectChangedPath(commit, path, cwd, leaks);
  }
  if (leaks.size > 0) {
    fail(`Personal instruction files are present in the public export diff/history: ${[...leaks].join(', ')}`);
  }
  console.log(JSON.stringify({status: 'PASS', base, head, commits: commits.length, changedPaths: finalPaths.length}));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
