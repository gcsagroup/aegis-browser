#!/usr/bin/env node

import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {
  lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import {basename, isAbsolute, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const comparison = 'ordered-exact-trees-and-canonical-patch-ids';
const canonicalDiffOptions = [
  '--no-commit-id', '-r', '-p', '--no-ext-diff', '--no-textconv', '--binary',
  '--full-index', '--no-renames', '--no-color', '--src-prefix=a/', '--dst-prefix=b/',
  '--diff-algorithm=myers', '--no-indent-heuristic', '--unified=3',
];

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function git(checkout, args, input, extraEnv = {}) {
  const result = spawnSync('git', [
    '--no-replace-objects', '-c', 'core.splitIndex=false', '-c', 'diff.relative=false',
    ...args,
  ], {
    cwd: checkout, input, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
    env: {...process.env, GIT_OPTIONAL_LOCKS: '0', ...extraEnv},
  });
  requireCondition(result.status === 0,
    `git ${args.join(' ')} failed: ${result.stderr?.trim() || result.error?.message || result.status}`);
  return result.stdout;
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function fileInput(path) {
  const before = lstatSync(path);
  requireCondition(before.isFile(), `expected regular patch input: ${path}`);
  const bytes = readFileSync(path);
  const after = lstatSync(path);
  requireCondition(before.ino === after.ino && before.size === after.size &&
    before.mtimeMs === after.mtimeMs && before.mode === after.mode,
  `patch input changed while reading: ${path}`);
  return {bytes, evidence: {mode: before.mode & 0o7777, sizeBytes: bytes.length, sha256: sha256(bytes)}};
}

function stablePatchId(value, checkout) {
  const output = git(checkout, ['patch-id', '--stable'], value).trim();
  const id = output.match(/^([0-9a-f]{40})\s/u)?.[1];
  requireCondition(id, 'git patch-id did not return a stable patch identifier');
  return id;
}

export function isVerifiedPatchLineage(lineage) {
  return lineage?.comparisonVersion === 2 && lineage.comparison === comparison &&
    lineage.orderedExactTransitionsMatch === true &&
    lineage.orderedCanonicalStablePatchIdsMatch === true;
}

export function collectPatchEvidence(checkout, baseCommit, patchRoot, label = 'Chromium', seriesPath) {
  checkout = realpathSync(checkout);
  patchRoot = realpathSync(patchRoot);
  // Preserve native traversal of a directory symlink followed by '..' for
  // reading, hashing and postchecking the caller's selected manifest.
  seriesPath = seriesPath ?? join(patchRoot, 'series');
  requireCondition(realpathSync(git(checkout, ['rev-parse', '--show-toplevel']).trim()) === checkout,
    `${label} checkout must have its own Git identity`);
  requireCondition(/^[0-9a-f]{40}$/u.test(baseCommit), 'invalid full base commit');
  const head = git(checkout, ['rev-parse', 'HEAD']).trim();
  git(checkout, ['merge-base', '--is-ancestor', baseCommit, head]);
  const series = fileInput(seriesPath);
  const names = series.bytes.toString('utf8').split(/\r?\n/u)
    .map((line) => line.trim()).filter((line) => line && !line.startsWith('#'));
  const seen = new Set();
  const inputs = names.map((name) => {
    requireCondition(basename(name) === name && name !== '.' && name !== '..',
      `unsafe patch path: ${name}`);
    requireCondition(!seen.has(name), `duplicate patch in series: ${name}`);
    seen.add(name);
    const input = fileInput(join(patchRoot, name));
    const commit = input.bytes.toString('utf8').split(/\r?\n/u, 1)[0]
      .match(/^From ([0-9a-f]{40}) /u)?.[1];
    requireCondition(commit, `patch does not contain a format-patch commit header: ${name}`);
    return {name, commit, ...input};
  });
  const commits = git(checkout, ['log', '--reverse', '--format=%H%x09%P%x09%T', `${baseCommit}..${head}`])
    .trim().split(/\r?\n/u).filter(Boolean).map((line) => line.split('\t'));
  requireCondition(commits.length === inputs.length,
    `${label} commit count does not match patch series`);

  // Only this newly created scratch store is writable. The checkout's index,
  // working tree and object store remain unchanged, including on rejection.
  const scratch = mkdtempSync(join(tmpdir(), 'aegis-patch-lineage-'));
  const patches = [];
  try {
    const objects = join(scratch, 'objects');
    mkdirSync(join(objects, 'info'), {recursive: true});
    const originalObjects = git(checkout,
      ['rev-parse', '--path-format=absolute', '--git-path', 'objects']).trim();
    requireCondition(!/[\r\n]/u.test(originalObjects), 'object directory cannot contain a newline');
    writeFileSync(join(objects, 'info', 'alternates'), `${originalObjects}\n`);
    const env = {GIT_INDEX_FILE: join(scratch, 'index'), GIT_OBJECT_DIRECTORY: objects,
      GIT_ALTERNATE_OBJECT_DIRECTORIES: '', GIT_INDEX_VERSION: '2'};
    git(checkout, ['read-tree', baseCommit], undefined, env);
    let parent = baseCommit;
    let beforeTree = git(checkout, ['rev-parse', `${baseCommit}^{tree}`]).trim();
    for (let index = 0; index < inputs.length; index += 1) {
      const input = inputs[index];
      const [appliedCommit, parents, appliedTree] = commits[index];
      requireCondition(parents === parent,
        `ordered ${label} commit must have exactly the previous commit as its sole parent: ${input.name}`);
      git(checkout, ['apply', '--cached', '--binary', '--whitespace=nowarn', '-'], input.bytes, env);
      const expectedTree = git(checkout, ['write-tree'], undefined, env).trim();
      requireCondition(expectedTree === appliedTree,
        `ordered exact patch tree does not match ${label} commit: ${input.name}`);
      const expectedDiff = git(checkout,
        ['diff-tree', ...canonicalDiffOptions, beforeTree, expectedTree], undefined, env);
      // Pin both diffs to the replay index, including attribute fallback when
      // a later commit has removed .gitattributes from the checkout.
      const appliedDiff = git(checkout,
        ['diff-tree', ...canonicalDiffOptions, beforeTree, appliedTree], undefined, env);
      const canonicalStablePatchId = stablePatchId(expectedDiff, checkout);
      const appliedCanonicalStablePatchId = stablePatchId(appliedDiff, checkout);
      requireCondition(canonicalStablePatchId === appliedCanonicalStablePatchId,
        `ordered canonical patch-ID does not match ${label} commit: ${input.name}`);
      const rawStablePatchId = stablePatchId(input.bytes, checkout);
      const appliedRawStablePatchId = stablePatchId(git(checkout,
        ['show', '--pretty=format:', '--no-ext-diff', '--no-textconv', '--binary', '--no-color', appliedCommit]), checkout);
      patches.push({name: input.name, commit: input.commit, ...input.evidence,
        // The legacy field retains its original raw-ID meaning.
        stablePatchId: rawStablePatchId, appliedRawStablePatchId,
        rawStablePatchIdMatches: rawStablePatchId === appliedRawStablePatchId,
        canonicalStablePatchId, appliedCanonicalStablePatchId,
        appliedCommit, parent, beforeTree, expectedTree, appliedTree});
      parent = appliedCommit;
      beforeTree = expectedTree;
    }
    requireCondition(git(checkout, ['rev-parse', 'HEAD']).trim() === head,
      `${label} HEAD changed during patch verification`);
    requireCondition(fileInput(seriesPath).evidence.sha256 === series.evidence.sha256,
      'patch series changed during verification');
    for (const input of inputs) {
      const current = fileInput(join(patchRoot, input.name)).evidence;
      requireCondition(current.sha256 === input.evidence.sha256 && current.mode === input.evidence.mode,
        `patch changed during verification: ${input.name}`);
    }
  } finally {
    rmSync(scratch, {recursive: true, force: true});
  }
  const appliedCommits = commits.map(([commit]) => commit);
  const exactCommitIdsMatch = appliedCommits.every((commit, index) => commit === patches[index].commit);
  const rawMatch = patches.every((patch) => patch.rawStablePatchIdMatches);
  return {series: {path: seriesPath, ...(isAbsolute(seriesPath) ? {} : {cwd: process.cwd()}),
    ...series.evidence}, patchCount: patches.length, patches,
    manifestSha256: sha256(patches.map((patch) => `${patch.name}\0${patch.sha256}\0`).join('')),
    lineage: {comparisonVersion: 2, comparison, canonicalDiffOptions,
      base: baseCommit, head, exactSeriesMatch: exactCommitIdsMatch, exactCommitIdsMatch,
      orderedExactTransitionsMatch: true, orderedCanonicalStablePatchIdsMatch: true,
      orderedRawStablePatchIdsMatch: rawMatch,
      orderedStablePatchIdsMatch: rawMatch, stablePatchIdsMatch: rawMatch, appliedCommits}};
}

function main() {
  const args = new Map();
  const allowed = new Set(['--checkout', '--base', '--patch-root', '--label', '--format', '--series']);
  for (let index = 2; index < process.argv.length; index += 2) {
    const name = process.argv[index];
    const value = process.argv[index + 1];
    requireCondition(allowed.has(name) && !args.has(name) && value,
      `invalid or duplicate patch lineage argument: ${name}`);
    args.set(name, value);
  }
  for (const name of ['--checkout', '--base', '--patch-root']) {
    requireCondition(args.has(name), `missing patch lineage argument: ${name}`);
  }
  const format = args.get('--format') || 'json';
  requireCondition(['json', 'status'].includes(format), 'invalid patch lineage output format');
  const evidence = collectPatchEvidence(args.get('--checkout'), args.get('--base'),
    args.get('--patch-root'), args.get('--label'), args.get('--series'));
  requireCondition(isVerifiedPatchLineage(evidence.lineage), 'unverified patch lineage');
  if (format === 'status') {
    const kind = evidence.lineage.exactCommitIdsMatch ? 'exact' : 'replay';
    process.stdout.write(`${kind}${evidence.lineage.orderedRawStablePatchIdsMatch ? '' : '-normalized'}\n`);
  } else {
    process.stdout.write(`${JSON.stringify(evidence, null, 2)}\n`);
  }
}

if (process.argv[1] && realpathSync(resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`patch lineage: ${error.message}\n`);
    process.exitCode = 1;
  }
}
