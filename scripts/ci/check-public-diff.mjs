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

function validateRepositoryPath(path, context) {
  if (
    posix.isAbsolute(path) ||
    /^[A-Za-z]:[\\/]/u.test(path) ||
    path.startsWith('\\\\') ||
    path === '..' ||
    path.startsWith('../')
  ) {
    fail(`Public export symlink escapes the repository at ${context}: ${path}`);
  }
  for (const component of path.split(/[\\/]/u)) {
    if (isPersonalInstruction(component)) {
      fail(`Public export symlink resolves through a personal instruction at ${context}: ${path}`);
    }
  }
}

function resolveSymlinkChain(ref, linkPath, target, cwd) {
  if (posix.isAbsolute(target) || /^[A-Za-z]:[\\/]/u.test(target) || target.startsWith('\\\\')) {
    fail(`Public export symlink has an absolute/external target at ${linkPath}: ${target}`);
  }
  let pending = posix.normalize(posix.join(posix.dirname(linkPath), target.replaceAll('\\', '/')));
  const seen = new Set();
  for (let depth = 0; depth < 32; depth += 1) {
    validateRepositoryPath(pending, linkPath);
    const components = pending.split('/').filter(Boolean);
    let followed = false;
    for (let index = 0; index < components.length; index += 1) {
      const prefix = components.slice(0, index + 1).join('/');
      const entry = treeEntry(ref, prefix, cwd);
      if (entry?.mode !== '120000') continue;
      const suffix = components.slice(index + 1).join('/');
      const nestedTarget = symlinkTarget(entry, cwd);
      const key = `${prefix}\0${nestedTarget}\0${suffix}`;
      if (seen.has(key)) fail(`Public export symlink chain cycles at ${prefix}`);
      seen.add(key);
      if (posix.isAbsolute(nestedTarget) || /^[A-Za-z]:[\\/]/u.test(nestedTarget) || nestedTarget.startsWith('\\\\')) {
        fail(`Public export symlink chain escapes the repository at ${prefix}: ${nestedTarget}`);
      }
      pending = posix.normalize(
        posix.join(posix.dirname(prefix), nestedTarget.replaceAll('\\', '/'), suffix),
      );
      followed = true;
      break;
    }
    if (!followed) return;
  }
  fail(`Public export symlink chain exceeds 32 hops at ${linkPath}`);
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
