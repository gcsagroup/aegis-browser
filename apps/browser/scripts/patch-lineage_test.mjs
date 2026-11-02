import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {
  chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync,
  symlinkSync, writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import {delimiter, dirname, join, sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {collectPatchEvidence, isVerifiedPatchLineage} from './patch-lineage.mjs';

const script = join(dirname(fileURLToPath(import.meta.url)), 'patch-lineage.mjs');
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'aegis-lineage-test-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const src = join(root, 'src');
  const patches = join(root, 'patches');
  mkdirSync(src);
  mkdirSync(patches);
  const git = (...args) => execFileSync('git', args, {cwd: src, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe']}).trim();
  const commit = (message, amend = false) => {
    git('add', '--all');
    git('commit', '-qm', message, ...(amend ? ['--amend'] : []));
    return git('rev-parse', 'HEAD');
  };
  git('init', '-qb', 'main');
  git('config', 'user.name', 'Aegis Fixture');
  git('config', 'user.email', 'fixture@example.invalid');
  writeFileSync(join(src, 'value.txt'), 'A\n\nB\n');
  writeFileSync(join(src, 'binary.dat'), Buffer.from([0, 1, 2, 0, 255]));
  const base = commit('base');
  writeFileSync(join(src, 'value.txt'), 'A\n\nC\n\nB\n');
  const head = commit('change');
  const patch = join(patches, '0001-change.patch');
  const exportPatch = (path = patch) => writeFileSync(path, `${git('format-patch', '-1', '--stdout', '--full-index')}\n`);
  exportPatch();
  writeFileSync(join(patches, 'series'), '0001-change.patch\n');
  return {root, src, patches, patch, base, head, git, commit, exportPatch,
    collect: (label = 'Chromium') => collectPatchEvidence(src, base, patches, label)};
}

function rawId(f, input) {
  return execFileSync('git', ['patch-id', '--stable'], {cwd: f.src, input, encoding: 'utf8'}).split(/\s/u)[0];
}

function alternatePatch(f) {
  writeFileSync(f.patch, `From ${f.head} Mon Sep 17 00:00:00 2001
From: Aegis Fixture <fixture@example.invalid>
Date: Mon, 26 Oct 2026 00:00:00 +0000
Subject: [PATCH] change

---
diff --git a/value.txt b/value.txt
--- a/value.txt
+++ b/value.txt
@@ -1,3 +1,5 @@
 A
+
+C
 
 B
`);
}

function cli(f, format = 'json', seriesPath, cwd, env) {
  return spawnSync(process.execPath, [script, '--checkout', f.src, '--base', f.base,
    '--patch-root', f.patches, '--label', 'V8', '--format', format,
    ...(seriesPath ? ['--series', seriesPath] : [])], {encoding: 'utf8', cwd, env});
}

test('original and replayed format-patches preserve exact/replay identity', (t) => {
  const f = fixture(t);
  const exact = f.collect();
  assert.equal(exact.lineage.comparisonVersion, 2);
  assert.equal(exact.lineage.exactCommitIdsMatch, true);
  assert.equal(exact.lineage.orderedRawStablePatchIdsMatch, true);
  assert.equal(isVerifiedPatchLineage(exact.lineage), true);
  f.commit('replayed message', true);
  const replay = f.collect('V8');
  assert.equal(replay.lineage.exactCommitIdsMatch, false);
  assert.equal(replay.lineage.orderedRawStablePatchIdsMatch, true);
  assert.equal(isVerifiedPatchLineage(replay.lineage), true);
});

test('different context alignment requires exact trees/canonical IDs and retains raw mismatch', (t) => {
  const f = fixture(t);
  alternatePatch(f);
  const evidence = f.collect();
  const patch = evidence.patches[0];
  assert.equal(patch.expectedTree, patch.appliedTree);
  assert.equal(patch.canonicalStablePatchId, patch.appliedCanonicalStablePatchId);
  assert.notEqual(patch.stablePatchId, patch.appliedRawStablePatchId);
  assert.equal(patch.rawStablePatchIdMatches, false);
  assert.equal(evidence.lineage.orderedRawStablePatchIdsMatch, false);
  assert.equal(evidence.lineage.orderedStablePatchIdsMatch, false);
  assert.equal(evidence.lineage.stablePatchIdsMatch, false);
  assert.equal(isVerifiedPatchLineage(evidence.lineage), true);
  assert.equal(cli(f, 'status').stdout.trim(), 'exact-normalized');
});

for (const kind of ['content', 'whitespace', 'extra file', 'mode', 'binary', 'gitlink']) {
  test(`rejects ${kind} drift in the actual commit`, (t) => {
    const f = fixture(t);
    if (kind === 'content') writeFileSync(join(f.src, 'value.txt'), 'A\n\nX\n\nB\n');
    if (kind === 'whitespace') writeFileSync(join(f.src, 'value.txt'), 'A\n\n C\n\nB\n');
    if (kind === 'extra file') writeFileSync(join(f.src, 'extra.txt'), 'extra\n');
    if (kind === 'mode') chmodSync(join(f.src, 'value.txt'), 0o755);
    if (kind === 'binary') writeFileSync(join(f.src, 'binary.dat'), Buffer.from([0, 1, 3, 0, 255]));
    if (kind === 'gitlink') f.git('update-index', '--add', '--cacheinfo', `160000,${f.base},nested`);
    if (kind === 'gitlink') f.git('commit', '-qm', 'drift', '--amend');
    else f.commit('drift', true);
    if (kind === 'whitespace') {
      assert.equal(rawId(f, readFileSync(f.patch)),
        rawId(f, f.git('show', '--pretty=format:', '--binary', 'HEAD')));
    }
    assert.throws(() => f.collect(), /ordered exact patch tree/u);
    const result = cli(f);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /ordered exact patch tree/u);
    assert.equal(result.stdout, '');
  });
}

test('accepts a genuine binary patch and rejects a later byte change', (t) => {
  const f = fixture(t);
  writeFileSync(join(f.src, 'binary.dat'), Buffer.from([0, 2, 3, 0, 255]));
  f.commit('binary change', true);
  f.exportPatch();
  assert.match(readFileSync(f.patch, 'utf8'), /GIT binary patch/u);
  assert.equal(isVerifiedPatchLineage(f.collect().lineage), true);
  writeFileSync(join(f.src, 'binary.dat'), Buffer.from([0, 2, 4, 0, 255]));
  f.commit('different binary', true);
  assert.throws(() => f.collect(), /ordered exact patch tree/u);
});

test('intermediate drift is rejected even when a later commit restores the same final tree', (t) => {
  const f = fixture(t);
  writeFileSync(join(f.src, 'value.txt'), 'A\n\nD\n\nB\n');
  f.commit('second');
  f.exportPatch(join(f.patches, '0002-second.patch'));
  writeFileSync(join(f.patches, 'series'), '0001-change.patch\n0002-second.patch\n');
  const finalTree = f.git('rev-parse', 'HEAD^{tree}');
  f.git('checkout', '-qb', 'drifted', f.base);
  writeFileSync(join(f.src, 'value.txt'), 'A\n\nX\n\nB\n');
  f.commit('wrong first');
  writeFileSync(join(f.src, 'value.txt'), 'A\n\nD\n\nB\n');
  f.commit('restore final');
  assert.equal(f.git('rev-parse', 'HEAD^{tree}'), finalTree);
  assert.throws(() => f.collect(), /ordered exact patch tree.*0001-change/u);
});

test('independent patches cannot be reordered despite an identical final tree', (t) => {
  const f = fixture(t);
  f.git('checkout', '-qb', 'ordered', f.base);
  writeFileSync(join(f.src, 'one.txt'), 'one\n');
  f.commit('one');
  f.exportPatch();
  writeFileSync(join(f.src, 'two.txt'), 'two\n');
  f.commit('two');
  f.exportPatch(join(f.patches, '0002-two.patch'));
  writeFileSync(join(f.patches, 'series'), '0001-change.patch\n0002-two.patch\n');
  const finalTree = f.git('rev-parse', 'HEAD^{tree}');
  f.git('checkout', '-qb', 'reordered', f.base);
  writeFileSync(join(f.src, 'two.txt'), 'two\n');
  f.commit('two first');
  writeFileSync(join(f.src, 'one.txt'), 'one\n');
  f.commit('one second');
  assert.equal(f.git('rev-parse', 'HEAD^{tree}'), finalTree);
  assert.throws(() => f.collect(), /ordered exact patch tree/u);
});

test('requires the fixed base, exact commit count, and one previous parent', (t) => {
  const f = fixture(t);
  assert.throws(() => collectPatchEvidence(f.src, f.head, f.patches), /commit count/u);
  assert.throws(() => collectPatchEvidence(f.src, 'bad', f.patches), /invalid full base/u);
  const unrelated = execFileSync('git', ['commit-tree', f.git('rev-parse', `${f.base}^{tree}`), '-m', 'unrelated'],
    {cwd: f.src, encoding: 'utf8'}).trim();
  assert.throws(() => collectPatchEvidence(f.src, unrelated, f.patches), /merge-base/u);
  const merge = f.git('commit-tree', f.git('rev-parse', 'HEAD^{tree}'), '-p', f.base, '-p', f.head, '-m', 'merge');
  f.git('update-ref', 'refs/heads/main', merge);
  writeFileSync(join(f.patches, '0002-merge.patch'), readFileSync(f.patch));
  writeFileSync(join(f.patches, 'series'), '0001-change.patch\n0002-merge.patch\n');
  assert.throws(() => f.collect(), /sole parent/u);
  writeFileSync(join(f.patches, 'series'), '0001-change.patch\n');
  assert.throws(() => f.collect(), /commit count/u);
});

for (const kind of ['duplicate', 'unsafe', 'missing', 'bad header', 'unapplicable']) {
  test(`rejects ${kind} patch input`, (t) => {
    const f = fixture(t);
    if (kind === 'duplicate') writeFileSync(join(f.patches, 'series'), '0001-change.patch\n0001-change.patch\n');
    if (kind === 'unsafe') writeFileSync(join(f.patches, 'series'), '../outside.patch\n');
    if (kind === 'missing') writeFileSync(join(f.patches, 'series'), '0001-missing.patch\n');
    if (kind === 'bad header') writeFileSync(f.patch, readFileSync(f.patch, 'utf8').replace(/^From [a-f0-9]{40}/u, 'From invalid'));
    if (kind === 'unapplicable') writeFileSync(f.patch, readFileSync(f.patch, 'utf8').replace('\n A\n', '\n WRONG\n'));
    assert.throws(() => f.collect(),
      {duplicate: /duplicate patch/u, unsafe: /unsafe patch path/u, missing: /ENOENT/u,
        'bad header': /commit header/u, unapplicable: /git apply.*failed/u}[kind]);
  });
}

test('success and rejection preserve the source index, dirty files, objects and HEAD', (t) => {
  const f = fixture(t);
  writeFileSync(join(f.src, 'value.txt'), 'private uncommitted work\n');
  const index = join(f.src, '.git', 'index');
  const originalIndex = digest(readFileSync(index));
  const objects = (path) => readdirSync(path, {withFileTypes: true}).flatMap((entry) => {
    const full = join(path, entry.name);
    return entry.isDirectory() ? objects(full) : [`${full}:${digest(readFileSync(full))}`];
  }).sort();
  const originalObjects = objects(join(f.src, '.git', 'objects'));
  f.collect();
  writeFileSync(f.patch, readFileSync(f.patch, 'utf8').replace('+C', '+wrong'));
  assert.throws(() => f.collect(), /ordered exact patch tree/u);
  assert.equal(f.git('rev-parse', 'HEAD'), f.head);
  assert.equal(digest(readFileSync(index)), originalIndex);
  assert.deepEqual(objects(join(f.src, '.git', 'objects')), originalObjects);
  assert.equal(readFileSync(join(f.src, 'value.txt'), 'utf8'), 'private uncommitted work\n');
});

test('a copied nested directory cannot borrow its parent Git identity', (t) => {
  const f = fixture(t);
  const child = join(f.src, 'copied-v8');
  mkdirSync(child);
  assert.throws(() => collectPatchEvidence(child, f.base, f.patches, 'V8'), /own Git identity/u);
});

test('shared final verification predicate requires every v2 gate', (t) => {
  const f = fixture(t);
  const lineage = f.collect().lineage;
  assert.equal(isVerifiedPatchLineage(lineage), true);
  for (const field of ['orderedExactTransitionsMatch', 'orderedCanonicalStablePatchIdsMatch']) {
    assert.equal(isVerifiedPatchLineage({...lineage, [field]: false}), false);
    assert.equal(isVerifiedPatchLineage({...lineage, [field]: undefined}), false);
  }
  assert.equal(isVerifiedPatchLineage({...lineage, comparisonVersion: 1}), false);
  assert.equal(isVerifiedPatchLineage({orderedStablePatchIdsMatch: true}), false);
  assert.equal(isVerifiedPatchLineage(null), false);
  const result = cli(f);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(isVerifiedPatchLineage(JSON.parse(result.stdout).lineage), true);
  assert.equal(cli(f, 'status').stdout.trim(), 'exact');
  assert.equal(existsSync(join(f.src, '.git', 'index.lock')), false);
});

test('R53 selected series is verified and its own bytes are hashed', (t) => {
  const f = fixture(t);
  const selectedPatch = join(f.patches, '0001-selected.patch');
  writeFileSync(selectedPatch, readFileSync(f.patch));
  const selectedSeries = join(f.root, 'selected-series');
  writeFileSync(selectedSeries, '0001-selected.patch\n');
  // The same-length default list is deliberately different and incorrect.
  writeFileSync(f.patch, readFileSync(f.patch, 'utf8').replace('+C', '+wrong'));
  const evidence = collectPatchEvidence(f.src, f.base, f.patches, 'Chromium', selectedSeries);
  assert.equal(evidence.patches[0].name, '0001-selected.patch');
  assert.equal(evidence.series.path, selectedSeries);
  assert.equal(evidence.series.sha256, digest(readFileSync(selectedSeries)));
  assert.notEqual(evidence.series.sha256, digest(readFileSync(join(f.patches, 'series'))));
  const result = cli(f, 'json', selectedSeries);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).series.sha256, evidence.series.sha256);
});

test('R53 selected series rejects a same-count alternative that does not match', (t) => {
  const f = fixture(t);
  writeFileSync(join(f.patches, '0001-selected.patch'), readFileSync(f.patch, 'utf8').replace('+C', '+wrong'));
  const selectedSeries = join(f.root, 'selected-series');
  writeFileSync(selectedSeries, '0001-selected.patch\n');
  assert.equal(isVerifiedPatchLineage(f.collect().lineage), true);
  assert.throws(() => collectPatchEvidence(f.src, f.base, f.patches, 'V8', selectedSeries),
    /ordered exact patch tree.*0001-selected/u);
  const result = cli(f, 'json', selectedSeries);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /ordered exact patch tree/u);
  assert.equal(result.stdout, '');
});

test('R53 canonical diffs share attributes across an intermediate attribute commit', (t) => {
  const f = fixture(t);
  f.git('checkout', '-qb', 'attributes', f.base);
  writeFileSync(join(f.src, '.gitattributes'), 'value.txt -diff\n');
  writeFileSync(join(f.src, 'value.txt'), 'A\n\nC\n\nB\n');
  const intermediate = f.commit('intermediate attributes and value');
  rmSync(join(f.src, '.gitattributes'));
  f.commit('remove attributes');
  // Export at final HEAD, where neither the working tree nor checkout index
  // contains .gitattributes. During replay the first scratch index does.
  writeFileSync(f.patch, `${f.git('format-patch', '-1', '--stdout', '--full-index', intermediate)}\n`);
  f.exportPatch(join(f.patches, '0002-remove-attributes.patch'));
  writeFileSync(join(f.patches, 'series'), '0001-change.patch\n0002-remove-attributes.patch\n');
  assert.equal(existsSync(join(f.src, '.gitattributes')), false);
  assert.equal(f.git('ls-files', '.gitattributes'), '');
  assert.equal(rawId(f, readFileSync(f.patch)), rawId(f, f.git('show', '--pretty=format:', '--binary', intermediate)));
  const evidence = f.collect();
  assert.equal(evidence.patchCount, 2);
  assert.equal(evidence.lineage.orderedRawStablePatchIdsMatch, true);
  assert.equal(isVerifiedPatchLineage(evidence.lineage), true);
  for (const patch of evidence.patches) {
    assert.equal(patch.expectedTree, patch.appliedTree);
    assert.equal(patch.canonicalStablePatchId, patch.appliedCanonicalStablePatchId);
  }
});

function linkedSeries(f, physicalMatches, lexicalMatches) {
  const logical = join(f.root, 'selector-logical');
  const physical = join(f.root, 'selector-physical');
  mkdirSync(logical);
  mkdirSync(join(physical, 'inner'), {recursive: true});
  symlinkSync(join(physical, 'inner'), join(logical, 'alias'), 'dir');
  const original = readFileSync(f.patch, 'utf8');
  writeFileSync(join(f.patches, '0001-physical.patch'), physicalMatches ? original : original.replace('+C', '+physical-wrong'));
  writeFileSync(join(f.patches, '0001-lexical.patch'), lexicalMatches ? original : original.replace('+C', '+lexical-wrong'));
  const physicalSeries = join(physical, 'series');
  const lexicalSeries = join(logical, 'series');
  writeFileSync(physicalSeries, '0001-physical.patch\n');
  writeFileSync(lexicalSeries, '0001-lexical.patch\n');
  // Do not use path.join here: native traversal must see alias before '..'.
  const relative = `selector-logical${sep}alias${sep}..${sep}series`;
  const absolute = `${f.root}${sep}${relative}`;
  assert.equal(readFileSync(absolute, 'utf8'), '0001-physical.patch\n');
  assert.notEqual(digest(readFileSync(absolute)), digest(readFileSync(lexicalSeries)));
  return {absolute, relative, physicalSeries, lexicalSeries};
}

test('R54 directory symlink plus dotdot rejects the actual selected manifest', (t) => {
  const f = fixture(t);
  const selected = linkedSeries(f, false, true);
  assert.throws(() => collectPatchEvidence(f.src, f.base, f.patches, 'Chromium', selected.absolute),
    /ordered exact patch tree.*0001-physical/u);
  const result = cli(f, 'json', selected.relative, f.root);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /ordered exact patch tree.*0001-physical/u);
  assert.equal(result.stdout, '');
});

test('R54 absolute and relative selectors retain native traversal and hash provenance', (t) => {
  const f = fixture(t);
  const selected = linkedSeries(f, true, false);
  const evidence = collectPatchEvidence(f.src, f.base, f.patches, 'V8', selected.absolute);
  assert.equal(evidence.series.path, selected.absolute);
  assert.equal(evidence.series.sha256, digest(readFileSync(selected.physicalSeries)));
  assert.equal(evidence.patches[0].name, '0001-physical.patch');
  const result = cli(f, 'json', selected.relative, f.root);
  assert.equal(result.status, 0, result.stderr);
  const relative = JSON.parse(result.stdout);
  assert.equal(relative.series.path, selected.relative);
  assert.equal(relative.series.cwd, realpathSync.native(f.root));
  assert.equal(relative.series.sha256, evidence.series.sha256);
  assert.equal(relative.patches[0].name, '0001-physical.patch');
});

test('R54 postcheck observes mutation of the filesystem-selected manifest', (t) => {
  const f = fixture(t);
  const selected = linkedSeries(f, true, true);
  const realGit = execFileSync('bash', ['-c', 'command -v git'], {encoding: 'utf8'}).trim();
  const bin = join(f.root, 'git-wrapper');
  mkdirSync(bin);
  const marker = join(f.root, 'mutation-observed');
  const wrapper = [
    '#!/bin/bash',
    '"$R54_REAL_GIT" "$@"',
    'r54_exit=$?',
    'if [[ "$r54_exit" == 0 && ! -e "$R54_MUTATION_MARKER" ]]; then',
    '  for r54_arg in "$@"; do',
    '    if [[ "$r54_arg" == write-tree ]]; then',
    '      printf "#changed-during-check\\n" >> "$R54_PHYSICAL_SERIES"',
    '      : > "$R54_MUTATION_MARKER"',
    '      break',
    '    fi',
    '  done',
    'fi',
    'exit "$r54_exit"',
    '',
  ].join('\n');
  writeFileSync(join(bin, 'git'), wrapper, {mode: 0o755});
  const result = cli(f, 'json', selected.absolute, f.root, {...process.env,
    PATH: `${bin}${delimiter}${process.env.PATH}`, R54_REAL_GIT: realGit,
    R54_PHYSICAL_SERIES: selected.physicalSeries, R54_MUTATION_MARKER: marker});
  assert.equal(existsSync(marker), true, result.stderr);
  assert.match(readFileSync(selected.physicalSeries, 'utf8'), /#changed-during-check/u);
  assert.equal(result.status, 1, result.stdout);
  assert.match(result.stderr, /patch series changed during verification/u);
  assert.equal(result.stdout, '');
});
