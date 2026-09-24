import assert from 'node:assert/strict';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
import {buildCandidate, parseCandidate, validateCandidate} from '../promotion-candidate.mjs';

function repository() {
  const dir = mkdtempSync(join(tmpdir(), 'aegis-candidate-'));
  const git = (...args) => {
    const r = spawnSync('git', args, {cwd: dir, encoding: 'utf8'});
    assert.equal(r.status, 0, r.stderr); return r.stdout.trim();
  };
  git('init', '-b', 'main'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid');
  const commit = (content) => {writeFileSync(join(dir, 'product'), content); git('add', '.'); git('commit', '-m', content); return git('rev-parse', 'HEAD');};
  const ancestor = (base, head) => spawnSync('git', ['merge-base','--is-ancestor',base,head], {cwd: dir}).status === 0;
  return {dir, git, commit, ancestor};
}

test('real Git history freezes source but permits review fixes and later backflow', () => {
  const r = repository();
  try {
    const base = r.commit('upstream'); const source = r.commit('feature');
    const candidate = buildCandidate('promotion', source, base, r.ancestor);
    assert.deepEqual(parseCandidate(candidate.branch), candidate);
    const fix = r.commit('review-fix');
    assert.equal(validateCandidate(candidate, fix, r.ancestor), fix);
    assert.throws(() => validateCandidate(candidate, base, r.ancestor), /frozen source/u);
    r.git('checkout', '-b', 'develop', source); const newer = r.commit('next-feature');
    assert.equal(candidate.source, source); assert.notEqual(candidate.source, newer);
    r.git('checkout', '-b', 'upstream', fix);
    const merged = r.commit('upstream-followup');
    const backflow = buildCandidate('backflow', merged, newer, r.ancestor);
    assert.equal(validateCandidate(backflow, merged, r.ancestor), merged);
    assert.throws(() => buildCandidate('promotion', newer, merged, r.ancestor), /Backflow/u);
  } finally {rmSync(r.dir, {recursive:true,force:true});}
});

test('candidate identity rejects abbreviated sources and legacy names', () => {
  assert.throws(() => buildCandidate('promotion', 'short', 'also-short', () => true), /Full/u);
  assert.equal(parseCandidate('automation/export-old'), null);
  assert.equal(parseCandidate(`codex/promote-${'a'.repeat(40)}-${'b'.repeat(40)}-extra`), null);
  assert.throws(() => buildCandidate('unknown', 'a'.repeat(40), 'b'.repeat(40), () => true), /Unknown/u);
});
