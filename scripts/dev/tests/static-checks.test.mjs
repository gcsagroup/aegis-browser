import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {
  collectStaticInventory,
  staticCheckDefinitions,
} from '../run-static-checks.mjs';

test('collectStaticInventory is tracked-only and NUL-safe', () => {
  const root = mkdtempSync(join(tmpdir(), 'aegis-static-checks-'));
  try {
    mkdirSync(join(root, '.github', 'workflows'), {recursive: true});
    writeFileSync(join(root, 'plain.js'), 'const value = 1;\n');
    writeFileSync(join(root, 'tool.py'), 'value = 1\n');
    writeFileSync(join(root, 'script with space.sh'), '#!/usr/bin/env bash\ntrue\n');
    writeFileSync(join(root, 'line\nbreak.sh'), '#!/usr/bin/env bash\ntrue\n');
    writeFileSync(join(root, '.github', 'workflows', 'quality.yml'), 'name: quality\n');
    writeFileSync(join(root, '.github', 'workflows', 'manual.yaml'), 'name: manual\n');
    writeFileSync(join(root, 'untracked.mjs'), 'const ignored = true;\n');

    execFileSync('git', ['init', '-q'], {cwd: root});
    execFileSync('git', [
      'add',
      'plain.js',
      'tool.py',
      'script with space.sh',
      'line\nbreak.sh',
      '.github/workflows/quality.yml',
      '.github/workflows/manual.yaml',
    ], {cwd: root});

    const inventory = collectStaticInventory(root);
    assert.deepEqual(inventory.javascript, ['plain.js']);
    assert.deepEqual(inventory.python, ['tool.py']);
    assert.equal(inventory.shell.length, 2);
    assert.ok(inventory.shell.includes('script with space.sh'));
    assert.ok(inventory.shell.includes('line\nbreak.sh'));
    assert.deepEqual(inventory.workflows, [
      '.github/workflows/manual.yaml',
      '.github/workflows/quality.yml',
    ]);
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});

test('static check definitions preserve order and explicit lint scope', () => {
  const inventory = {
    javascript: ['one.mjs'],
    python: ['one.py'],
    shell: ['one.sh'],
    workflows: ['.github/workflows/quality.yml'],
  };
  const definitions = staticCheckDefinitions(inventory);

  assert.deepEqual(
    definitions.map(({name}) => name),
    [
      'static-runner-tests',
      'javascript-syntax',
      'python-syntax',
      'shell-syntax',
      'actionlint',
      'shellcheck-warning',
      'eslint-static-scope',
      'typescript-typecheck',
    ],
  );
  assert.deepEqual(
    definitions.find(({name}) => name === 'eslint-static-scope')?.args,
    ['pnpm', 'run', 'lint:static'],
  );
  assert.equal(definitions[1].files, inventory.javascript);
  assert.equal(definitions[4].files, inventory.workflows);
});
