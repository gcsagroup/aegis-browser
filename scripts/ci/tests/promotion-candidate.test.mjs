import assert from 'node:assert/strict';
import {mkdtempSync, writeFileSync, rmSync, readFileSync, chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {README_FILES, buildCandidate, candidateGit, classifyProductRelationship, sameProduct, validateCandidate} from '../promotion-candidate.mjs';
import {validateActivePull} from '../promotion-orchestrator.mjs';

function fixture(t) {
  const cwd = mkdtempSync(join(tmpdir(), 'aegis-candidate-test-'));
  t.after(() => rmSync(cwd, {recursive: true, force: true}));
  const options = {cwd};
  const git = (...args) => candidateGit(args, options);
  git('init', '-q');
  git('config', 'user.name', 'Fixture');
  git('config', 'user.email', 'fixture@example.invalid');
  const write = (path, text) => writeFileSync(join(cwd, path), text);
  const commit = (message) => { git('add', '.'); git('commit', '-qm', message); return git('rev-parse', 'HEAD'); };
  for (const path of README_FILES) write(path, `Upstream ${path}\n`);
  write('product.txt', 'original\n');
  write('deleted.txt', 'to delete\n');
  const upstream = commit('chore: initial');
  for (const path of README_FILES) write(path, `Personal main+develop badges ${path}\n`);
  const badges = commit('docs: personal badges');
  const makeCommit = (candidate, parents = candidate.parents) => git('commit-tree', candidate.tree, ...parents.flatMap((parent) => ['-p', parent]), '-m', candidate.message);
  return {cwd, options, git, write, commit, upstream, badges, makeCommit};
}

test('badge-only personal differences are product parity, not an empty export', (t) => {
  const f = fixture(t);
  assert.equal(classifyProductRelationship(f.badges, f.upstream, f.options), 'same');
  assert.throws(() => buildCandidate('export', f.badges, f.upstream, f.options), /empty or divergent export/u);
});

test('export preserves every non-README change and exactly upstream README including modes, without touching checkout/index', (t) => {
  const f = fixture(t);
  f.write('product.txt', 'new product\n');
  f.write('added.txt', 'new file\n');
  f.git('rm', 'deleted.txt');
  chmodSync(join(f.cwd, 'product.txt'), 0o755);
  const main = f.commit('feat: product change');
  f.write('README.md', 'concurrent user edit\n');
  f.git('add', 'README.md');
  f.write('README.zh-CN.md', 'unstaged user edit\n');
  const before = f.git('status', '--porcelain=v1');
  const index = f.git('write-tree');
  const candidate = buildCandidate('export', main, f.upstream, f.options);
  const head = f.makeCommit(candidate);
  assert.equal(validateCandidate(candidate, head, f.options), head);
  assert.equal(sameProduct(main, head, f.options), true);
  assert.equal(f.git('diff', '--name-only', f.upstream, head, '--', ...README_FILES), '');
  assert.equal(f.git('show', `${head}:added.txt`), 'new file');
  assert.match(f.git('ls-tree', head, 'product.txt'), /^100755/u);
  assert.equal(f.git('ls-tree', head, 'deleted.txt'), '');
  assert.equal(f.git('write-tree'), index);
  assert.equal(f.git('status', '--porcelain=v1'), before);
  assert.equal(readFileSync(join(f.cwd, 'README.md'), 'utf8'), 'concurrent user edit\n');
});

test('immutable reuse checks parents/source identity as well as the full tree', (t) => {
  const f = fixture(t);
  f.write('product.txt', 'new\n');
  const main = f.commit('feat: new');
  const candidate = buildCandidate('export', main, f.upstream, f.options);
  const head = f.makeCommit(candidate);
  assert.equal(validateCandidate(candidate, head, f.options), head);
  const wrongParent = f.makeCommit(candidate, [f.upstream]);
  assert.throws(() => validateCandidate(candidate, wrongParent, f.options), /expected tree or parents/u);
  const extraParent = f.makeCommit(candidate, [main, f.upstream]);
  assert.throws(() => validateCandidate(candidate, extraParent, f.options), /expected tree or parents/u);
  const wrongTree = f.makeCommit({...candidate, tree: f.git('rev-parse', `${main}^{tree}`)});
  assert.throws(() => validateCandidate(candidate, wrongTree, f.options), /expected tree or parents/u);
  const newMain = f.git('commit-tree', f.git('rev-parse', `${main}^{tree}`), '-p', main, '-m', 'chore: new source');
  assert.throws(() => validateCandidate(buildCandidate('export', newMain, f.upstream, f.options), head, f.options), /expected tree or parents/u);
});

for (const mergeMethod of ['merge', 'squash']) {
  test(`upstream ${mergeMethod} integration sync retains personal README and reaches stable product parity`, (t) => {
    const f = fixture(t);
    f.write('product.txt', 'published product\n');
    const main = f.commit('feat: published product');
    const exported = buildCandidate('export', main, f.upstream, f.options);
    const exportHead = f.makeCommit(exported);
    const upstream = f.git('commit-tree', exported.tree, '-p', f.upstream, ...(mergeMethod === 'merge' ? ['-p', exportHead] : []), '-m', 'feat: integrate upstream');
    assert.equal(classifyProductRelationship(main, upstream, f.options), 'origin-behind');
    const sync = buildCandidate('upstream-sync', main, upstream, f.options);
    assert.equal(f.git('diff', '--name-only', main, sync.tree, '--', ...README_FILES), '');
    assert.equal(sameProduct(upstream, sync.tree, f.options), true);
    const restored = f.makeCommit(sync);
    assert.equal(f.git('show', '-s', '--format=%P', restored), `${main} ${upstream}`);
    assert.equal(classifyProductRelationship(restored, upstream, f.options), 'same');
    assert.throws(() => buildCandidate('export', restored, upstream, f.options), /empty or divergent export/u);
    // A subsequent upstream-only product change remains safe despite the README divergence.
    f.git('switch', '--detach', upstream);
    f.write('product.txt', 'next upstream change\n');
    const next = f.commit('fix: next upstream change');
    assert.equal(classifyProductRelationship(restored, next, f.options), 'origin-behind');
    const nextSync = buildCandidate('upstream-sync', restored, next, f.options);
    assert.equal(sameProduct(next, nextSync.tree, f.options), true);
    assert.equal(f.git('diff', '--name-only', main, nextSync.tree, '--', ...README_FILES), '');
  });
}

test('unpublished product divergence fails closed without generating a sync or export', (t) => {
  const f = fixture(t);
  f.write('personal.txt', 'unpublished\n');
  const main = f.commit('feat: unpublished');
  f.git('switch', '--detach', f.upstream);
  f.write('upstream.txt', 'upstream\n');
  const upstream = f.commit('feat: upstream');
  assert.equal(classifyProductRelationship(main, upstream, f.options), 'diverged');
  assert.throws(() => buildCandidate('upstream-sync', main, upstream, f.options), /unsafe upstream/u);
  assert.throws(() => buildCandidate('export', main, upstream, f.options), /divergent export/u);
});

test('missing README fails closed instead of exporting personal content', (t) => {
  const f = fixture(t);
  f.git('switch', '--detach', f.upstream);
  f.git('rm', 'README.zh-TW.md');
  const upstream = f.commit('docs: remove README');
  f.write('product.txt', 'product\n');
  const main = f.commit('feat: product');
  assert.throws(() => buildCandidate('export', main, upstream, f.options), /all three README/u);
});

test('legacy personal:main upstream PR with personal badges is rejected before review', async (t) => {
  const f = fixture(t);
  const config = {personalRepo: 'personal/repo', upstreamRepo: 'upstream/repo'};
  const active = {kind: 'upstream', pr: {base: {sha: f.upstream}, head: {ref: 'main', sha: f.badges}}};
  const deps = {git: f.git, sha: (ref) => ref === 'origin/main' ? f.badges : f.upstream, assertHeads: async () => { throw new Error('must reject before API action'); }};
  await assert.rejects(validateActivePull(active, config, deps), /legacy personal:main/u);
});

test('immutable branch reuse validates a real fetched remote ref and rejects same-tree replacement', async (t) => {
  const f = fixture(t);
  f.write('product.txt', 'published\n');
  const main = f.commit('feat: published');
  const candidate = buildCandidate('export', main, f.upstream, f.options);
  const head = f.makeCommit(candidate);
  const remote = join(f.cwd, 'remote.git');
  f.git('init', '--bare', '-q', remote);
  f.git('remote', 'add', 'origin', remote);
  f.git('push', '-q', 'origin', `${head}:refs/heads/${candidate.branch}`);
  const config = {personalRepo: 'personal/repo', upstreamRepo: 'upstream/repo'};
  const {publishCandidate} = await import('../promotion-orchestrator.mjs');
  const deps = {
    remoteSha: (branch) => f.git('ls-remote', 'origin', `refs/heads/${branch}`).split(/\s/u)[0],
    fetchBranch: (branch) => f.git('fetch', '-q', 'origin', `refs/heads/${branch}:refs/remotes/origin/${branch}`),
    sha: (ref) => f.git('rev-parse', ref),
    validate: (plan, actual) => validateCandidate(plan, actual, f.options),
    api: async (repo, path, request) => {
      assert.notEqual(request.method, 'POST', 'reuse must not write any remote object/ref');
      return {object: {sha: path === '/git/ref/heads/main' ? (repo === config.personalRepo ? main : f.upstream) : head}};
    },
  };
  assert.equal(await publishCandidate(config, candidate, deps), head);
  const replacement = f.makeCommit(candidate, [head]);
  f.git('push', '-q', 'origin', `${replacement}:refs/heads/${candidate.branch}`);
  await assert.rejects(publishCandidate(config, candidate, deps), /expected tree or parents/u);
});

for (const mergeMethod of ['merge', 'squash']) {
  test(`README-only upstream divergence exports with upstream ancestry and survives a ${mergeMethod} roundtrip`, (t) => {
    const f = fixture(t);
    f.write('product.txt', 'personal product change\n');
    const main = f.commit('feat: personal product');
    f.git('switch', '--detach', f.upstream);
    for (const path of README_FILES) f.write(path, `Updated upstream ${path}\n`);
    const upstream = f.commit('docs: update upstream README');
    assert.equal(f.git('merge-base', main, upstream), f.upstream);
    assert.equal(sameProduct(upstream, f.upstream, f.options), true);
    assert.equal(classifyProductRelationship(main, upstream, f.options), 'origin-ahead');
    const exported = buildCandidate('export', main, upstream, f.options);
    assert.deepEqual(exported.parents, [main, upstream]);
    const head = f.makeCommit(exported);
    assert.equal(f.git('show', '-s', '--format=%P', head), `${main} ${upstream}`);
    assert.equal(f.git('merge-base', upstream, head), upstream);
    assert.equal(f.git('diff', '--name-only', `${upstream}...${head}`, '--', ...README_FILES), '');
    assert.equal(f.git('diff', '--name-only', `${upstream}...${head}`), 'product.txt');
    assert.equal(sameProduct(main, head, f.options), true);
    const branch = `refs/heads/${exported.branch}`;
    f.git('update-ref', branch, head);
    assert.equal(validateCandidate(exported, branch, f.options), branch);
    for (const parents of [[main], [upstream, main]]) {
      f.git('update-ref', branch, f.makeCommit(exported, parents));
      assert.throws(() => validateCandidate(exported, branch, f.options), /expected tree or parents/u);
    }
    f.git('update-ref', branch, head);
    assert.equal(validateCandidate(exported, branch, f.options), branch);

    const integrated = f.git('commit-tree', exported.tree, '-p', upstream, ...(mergeMethod === 'merge' ? ['-p', head] : []), '-m', 'feat: integrate export');
    assert.equal(classifyProductRelationship(main, integrated, f.options), 'origin-behind');
    const sync = buildCandidate('upstream-sync', main, integrated, f.options);
    assert.deepEqual(sync.parents, [main, integrated]);
    assert.equal(sameProduct(integrated, sync.tree, f.options), true);
    assert.equal(f.git('diff', '--name-only', main, sync.tree, '--', ...README_FILES), '');
    const restored = f.makeCommit(sync);
    assert.equal(classifyProductRelationship(restored, integrated, f.options), 'same');
    assert.throws(() => buildCandidate('export', restored, integrated, f.options), /empty or divergent export/u);

    f.git('switch', '--detach', restored);
    f.write('product.txt', 'next personal product change\n');
    const nextMain = f.commit('feat: next personal product');
    const nextExport = buildCandidate('export', nextMain, integrated, f.options);
    assert.deepEqual(nextExport.parents, [nextMain]);
    const nextHead = f.makeCommit(nextExport);
    assert.equal(f.git('merge-base', integrated, nextHead), integrated);
    assert.equal(f.git('diff', '--name-only', `${integrated}...${nextHead}`, '--', ...README_FILES), '');
  });
}
