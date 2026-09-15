#!/usr/bin/env node
import {resolve} from 'node:path';
import {fail, git, parseArgs, repoRoot, resolveCommit} from './common.mjs';

function parentShas(commit, cwd) {
  return git(['rev-list', '--parents', '-n', '1', commit], {cwd}).trim().split(/\s+/u).slice(1);
}

function requireAncestor(ancestor, descendant, cwd) {
  try {
    git(['merge-base', '--is-ancestor', ancestor, descendant], {cwd});
  } catch {
    fail(`${ancestor} is not an ancestor of ${descendant}`);
  }
}

try {
  const {values} = parseArgs(process.argv.slice(2), ['event', 'base', 'head', 'tested', 'ref', 'repo']);
  const cwd = resolve(values.repo ?? repoRoot);
  const event = values.event;
  if (!['pull_request', 'push', 'workflow_dispatch'].includes(event)) fail(`Unsupported CI event: ${event}`);
  const base = resolveCommit(values.base, cwd);
  const head = resolveCommit(values.head, cwd);
  const tested = resolveCommit(values.tested, cwd);
  const checkout = resolveCommit('HEAD', cwd);
  if (checkout !== tested) fail(`Checked out ${checkout}, but metadata says tested SHA is ${tested}`);

  if (event === 'pull_request') {
    const parents = parentShas(tested, cwd);
    if (parents.length !== 2 || parents[0] !== base || parents[1] !== head) {
      fail(`PR tested SHA must be the exact GitHub merge candidate with parents B=${base}, H=${head}`);
    }
  } else {
    if (head !== tested) fail(`${event} must test its exact head SHA`);
    requireAncestor(base, head, cwd);
    if (!['refs/heads/main', 'refs/heads/develop'].includes(values.ref)) {
      fail(`${event} is restricted to refs/heads/main or refs/heads/develop, got ${values.ref ?? 'missing'}`);
    }
  }
  const trees = Object.fromEntries(
    Object.entries({base, head, tested}).map(([name, sha]) => [name, git(['rev-parse', `${sha}^{tree}`], {cwd}).trim()]),
  );
  console.log(JSON.stringify({status: 'PASS', event, base, head, tested, trees}));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
