// Build and verify candidates using Git objects, never the shared checkout/index.
import {spawnSync} from 'node:child_process';
import {mkdtempSync, rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';

export const README_FILES = ['README.md', 'README.zh-CN.md', 'README.zh-TW.md'];
const PRODUCT_PATHS = ['.', ...README_FILES.map((path) => `:(top,exclude)${path}`)];

export function candidateGit(args, {cwd = process.cwd(), env = process.env, input, statuses = [0]} = {}) {
  const result = spawnSync('git', args, {cwd, env, input, encoding: 'utf8'});
  if (result.error) throw result.error;
  if (!statuses.includes(result.status)) throw new Error(`git ${args.join(' ')} failed: ${result.stderr}`);
  return result.stdout.trim();
}

export function sameProduct(left, right, options) {
  return candidateGit(['diff', '--name-only', left, right, '--', ...PRODUCT_PATHS], options) === '';
}

export function readmeEntries(source, options) {
  const entries = candidateGit(['ls-tree', source, '--', ...README_FILES], options).split('\n').filter(Boolean).map((line) => {
    const match = /^(\d+) (\w+) ([a-f0-9]+)\t(.+)$/u.exec(line);
    if (!match || match[2] !== 'blob' || !['100644', '100755'].includes(match[1])) {
      throw new Error('Fail closed: README must be a regular file');
    }
    return {mode: match[1], type: match[2], sha: match[3], path: match[4]};
  });
  if (entries.length !== README_FILES.length) throw new Error('Fail closed: all three README files are required');
  return entries;
}

export function treeWithReadmes(productSource, readmeSource, options = {}) {
  const directory = mkdtempSync(join(options.tempRoot ?? tmpdir(), 'aegis-promotion-index-'));
  try {
    const env = {...process.env, ...options.env, GIT_INDEX_FILE: join(directory, 'index')};
    const gitOptions = {...options, env};
    candidateGit(['read-tree', productSource], gitOptions);
    const entries = readmeEntries(readmeSource, options);
    candidateGit(['update-index', '--index-info'], {
      ...gitOptions,
      input: entries.map(({mode, sha, path}) => `${mode} ${sha}\t${path}\n`).join(''),
    });
    const tree = candidateGit(['write-tree'], gitOptions);
    if (!sameProduct(tree, productSource, options) ||
        candidateGit(['diff', '--name-only', tree, readmeSource, '--', ...README_FILES], options)) {
      throw new Error('Fail closed: candidate tree preservation failed');
    }
    return tree;
  } finally {
    rmSync(directory, {recursive: true, force: true});
  }
}

export function classifyProductRelationship(originMain, upstreamMain, options) {
  const bases = candidateGit(['merge-base', '--all', originMain, upstreamMain], {...options, statuses: [0, 1]}).split('\n').filter(Boolean);
  if (bases.length !== 1) return 'diverged';
  const base = bases[0];
  if (base === upstreamMain) return sameProduct(originMain, upstreamMain, options) ? 'same' : 'origin-ahead';
  if (base === originMain || sameProduct(originMain, base, options) || sameProduct(originMain, upstreamMain, options)) return 'origin-behind';
  if (sameProduct(upstreamMain, base, options)) return 'origin-ahead';
  return 'diverged';
}

function validateCandidateSources(kind, originMain, upstreamMain, options) {
  if (![originMain, upstreamMain].every((value) => /^[a-f0-9]{40}$/u.test(value))) throw new Error('Fail closed: full source SHAs required');
  const state = classifyProductRelationship(originMain, upstreamMain, options);
  if (kind === 'export' && state !== 'origin-ahead') throw new Error('Fail closed: empty or divergent export');
  if (kind === 'upstream-sync' && state !== 'origin-behind') throw new Error('Fail closed: unsafe upstream synchronization');
  if (!['export', 'upstream-sync'].includes(kind)) throw new Error('Unknown candidate kind');
}

function candidateParents(kind, originMain, upstreamMain, options) {
  if (kind !== 'export') return [originMain, upstreamMain];
  const base = candidateGit(['merge-base', '--all', originMain, upstreamMain], options);
  // README-only upstream advances still need ancestry in the export so the
  // GitHub three-dot PR diff uses the exact upstream README source as its base.
  return base === upstreamMain ? [originMain] : [originMain, upstreamMain];
}

export function buildCandidate(kind, originMain, upstreamMain, options) {
  validateCandidateSources(kind, originMain, upstreamMain, options);
  const productSource = kind === 'export' ? originMain : upstreamMain;
  const readmeSource = kind === 'export' ? upstreamMain : originMain;
  return {
    kind,
    branch: `automation/${kind}-${originMain}-${upstreamMain}`,
    originMain,
    upstreamMain,
    productSource,
    baseTree: candidateGit(['rev-parse', `${productSource}^{tree}`], options),
    readmeSource,
    tree: treeWithReadmes(productSource, readmeSource, options),
    parents: candidateParents(kind, originMain, upstreamMain, options),
    message: kind === 'export' ? 'chore(promotion): prepare upstream README export' : 'chore(sync): preserve personal README while merging upstream',
  };
}

export function validateCandidate(candidate, head, options) {
  const tree = candidateGit(['rev-parse', `${head}^{tree}`], options);
  const parents = candidateGit(['show', '-s', '--format=%P', head], options).split(' ');
  if (tree !== candidate.tree || parents.join(' ') !== candidate.parents.join(' ')) {
    throw new Error(`Fail closed: existing ${candidate.branch} differs from the expected tree or parents`);
  }
  return head;
}
