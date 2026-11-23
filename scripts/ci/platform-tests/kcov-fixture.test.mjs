import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {copyFileSync, lstatSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

test('shell coverage runner parses and its Bash parent and child enforce the fixture contract', (t) => {
  execFileSync('bash', ['-n', join(import.meta.dirname, '../run-shell-coverage.sh')]);
  const parent = join(import.meta.dirname, 'kcov-parent-fixture.sh');
  const child = join(import.meta.dirname, 'kcov-child-fixture.sh');
  const entry = lstatSync(parent);
  assert.ok(entry.isFile());
  assert.equal(entry.mode & 0o111, 0);
  assert.equal(execFileSync('bash', [parent], {encoding: 'utf8'}), 'parent-and-child-covered\n');
  assert.equal(spawnSync('bash', [child, 'wrong-value']).status, 1);

  const directory = mkdtempSync(join(tmpdir(), 'kcov-fixture-'));
  t.after(() => rmSync(directory, {recursive: true, force: true}));
  const copiedParent = join(directory, 'kcov-parent-fixture.sh');
  copyFileSync(parent, copiedParent);
  writeFileSync(join(directory, 'kcov-child-fixture.sh'), [
    'printf "child invoked with %s\\n" "$1" >&2',
    'printf "child-process-covered\\n"',
    'exit 23',
  ].join('\n'));

  const result = spawnSync('bash', [copiedParent], {encoding: 'utf8'});
  assert.equal(result.stderr, 'child invoked with child-process-covered\n');
  assert.equal(result.status, 23, 'the parent propagates the child exit code');
  assert.equal(result.stdout, '', 'the parent stops before printing success');
});
