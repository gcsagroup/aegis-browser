import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {lstatSync, readFileSync, readlinkSync} from 'node:fs';
import {dirname, relative, resolve, sep} from 'node:path';
import {fileURLToPath} from 'node:url';

export const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

export function fail(message) {
  const error = new Error(message);
  error.isExpected = true;
  throw error;
}

export function parseArgs(argv, valueNames = []) {
  const values = {};
  const flags = new Set();
  const allowedValues = new Set(valueNames);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) {
      fail(`Unexpected positional argument: ${argument}`);
    }
    const name = argument.slice(2);
    if (allowedValues.has(name)) {
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) {
        fail(`--${name} requires a value`);
      }
      values[name] = value;
      index += 1;
    } else {
      flags.add(name);
    }
  }
  return {values, flags};
}

export function git(args, options = {}) {
  return execFileSync('git', args, {
    cwd: options.cwd ?? repoRoot,
    encoding: options.encoding ?? 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    stdio: options.stdio,
  });
}

export function resolveCommit(value, cwd = repoRoot) {
  if (!value) fail('A commit is required');
  try {
    return git(['rev-parse', '--verify', `${value}^{commit}`], {cwd}).trim();
  } catch {
    fail(`Commit is unavailable: ${value}`);
  }
}

export function ensureRelativePath(path) {
  if (!path || path.startsWith('/') || path.split(/[\\/]/u).includes('..')) {
    fail(`Unsafe relative path: ${path}`);
  }
  return path;
}

export function isInside(parent, candidate) {
  const delta = relative(resolve(parent), resolve(candidate));
  return delta === '' || (!delta.startsWith(`..${sep}`) && delta !== '..');
}

export function sha256(content) {
  return createHash('sha256').update(content).digest('hex');
}

export function sourceSnapshot(cwd = repoRoot) {
  const raw = git(
    ['ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    {cwd, encoding: 'buffer'},
  );
  const paths = raw
    .toString('utf8')
    .split('\0')
    .filter(Boolean)
    .sort((left, right) => Buffer.from(left).compare(Buffer.from(right)));
  const aggregate = createHash('sha256');
  for (const path of paths) {
    const absolute = resolve(cwd, path);
    let mode = 'missing';
    let content = Buffer.alloc(0);
    let stat;
    try {
      stat = lstatSync(absolute);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (stat) {
      if (stat.isSymbolicLink()) {
        mode = 'symlink';
        content = Buffer.from(readlinkSync(absolute));
      } else if (stat.isFile()) {
        mode = stat.mode & 0o111 ? '100755' : '100644';
        content = readFileSync(absolute);
      } else {
        mode = 'unsupported';
      }
    }
    aggregate.update(mode);
    aggregate.update('\0');
    aggregate.update(path);
    aggregate.update('\0');
    aggregate.update(String(content.length));
    aggregate.update('\0');
    aggregate.update(content);
    aggregate.update('\0');
  }
  return {algorithm: 'sha256', digest: aggregate.digest('hex'), files: paths.length};
}

export function repositorySlug(cwd = repoRoot) {
  try {
    const url = git(['config', '--get', 'remote.origin.url'], {cwd}).trim();
    const match = /github\.com[/:]([^/]+)\/([^/]+?)(?:\.git)?$/u.exec(url);
    return match ? `${match[1]}/${match[2]}` : 'unknown';
  } catch {
    return 'unknown';
  }
}
