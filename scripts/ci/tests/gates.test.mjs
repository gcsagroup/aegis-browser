import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import test from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const scripts = join(root, 'scripts/ci');

function run(command, args, options = {}) {
  return spawnSync(command, args, {
    cwd: options.cwd ?? root,
    env: {...process.env, ...(options.env ?? {})},
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
}

function git(cwd, ...args) {
  const result = run('git', args, {cwd});
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function initRepo() {
  const directory = mkdtempSync(join(tmpdir(), 'aegis-ci-test-'));
  git(directory, 'init', '-b', 'main');
  git(directory, 'config', 'user.name', 'CI Test');
  git(directory, 'config', 'user.email', 'ci@example.invalid');
  return directory;
}

function commitAll(cwd, message) {
  git(cwd, 'add', '-A');
  git(cwd, 'commit', '-m', message);
  return git(cwd, 'rev-parse', 'HEAD');
}

test('required result gate fails closed for every non-success state', () => {
  for (const state of ['failure', 'cancelled', 'skipped', '', 'timed_out']) {
    const result = run(process.execPath, [join(scripts, 'check-required-results.mjs')], {
      env: {REQUIRED_RESULTS: JSON.stringify({quality: state})},
    });
    assert.notEqual(result.status, 0, `state ${state || 'missing'} unexpectedly passed`);
  }
  const absent = run(process.execPath, [join(scripts, 'check-required-results.mjs')], {
    env: {REQUIRED_RESULTS: ''},
  });
  assert.notEqual(absent.status, 0);
  const success = run(process.execPath, [join(scripts, 'check-required-results.mjs')], {
    env: {REQUIRED_RESULTS: JSON.stringify({quality: 'success'})},
  });
  assert.equal(success.status, 0, success.stderr);
});

test('source snapshot detects tracked and untracked source changes but excludes ignored evidence', () => {
  const cwd = initRepo();
  writeFileSync(join(cwd, '.gitignore'), '.artifacts/\n');
  writeFileSync(join(cwd, 'tracked.txt'), 'one\n');
  commitAll(cwd, 'base');
  writeFileSync(join(cwd, 'untracked.txt'), 'two\n');
  mkdirSync(join(cwd, '.artifacts'), {recursive: true});
  const snapshot = join(cwd, '.artifacts', 'snapshot.json');
  let result = run(process.execPath, [join(scripts, 'source-snapshot.mjs'), '--repo', cwd, '--write', snapshot], {cwd});
  assert.equal(result.status, 0, result.stderr);
  writeFileSync(join(cwd, '.artifacts', 'evidence.json'), '{}\n');
  result = run(process.execPath, [join(scripts, 'source-snapshot.mjs'), '--repo', cwd, '--verify', snapshot], {cwd});
  assert.equal(result.status, 0, result.stderr);
  writeFileSync(join(cwd, 'tracked.txt'), 'changed\n');
  result = run(process.execPath, [join(scripts, 'source-snapshot.mjs'), '--repo', cwd, '--verify', snapshot], {cwd});
  assert.notEqual(result.status, 0);
});

test('freeze gate uses the trusted base and rejects file or self-consistent manifest mutation', () => {
  const cwd = initRepo();
  const directory = join(cwd, 'docs/plans/access-service-v1.0');
  mkdirSync(directory, {recursive: true});
  const specification = Buffer.from('frozen specification\n');
  writeFileSync(join(directory, 'spec.zh-CN.md'), specification);
  const manifest = {
    specVersion: 'V1.0',
    specRevision: 4,
    specificationStatus: 'FROZEN',
    authority: 'spec.zh-CN.md',
    counts: {functionalAndDeliveryCases: 118, performanceMetrics: 13, deliveryGates: 4},
    documentChecks: {previewScenarioCount: 13, previewScript: 'verify-preview.cjs'},
    files: {
      'spec.zh-CN.md': {
        sha256: createHash('sha256').update(specification).digest('hex'),
        bytes: specification.length,
      },
    },
  };
  writeFileSync(join(directory, 'freeze.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  const base = commitAll(cwd, 'frozen base');
  let result = run(process.execPath, [join(scripts, 'check-access-freeze.mjs'), '--base', base, '--repo', cwd]);
  assert.equal(result.status, 0, result.stderr);

  writeFileSync(join(directory, 'spec.zh-CN.md'), 'mutated\n');
  result = run(process.execPath, [join(scripts, 'check-access-freeze.mjs'), '--base', base, '--repo', cwd]);
  assert.notEqual(result.status, 0);

  const mutated = Buffer.from('mutated\n');
  manifest.files['spec.zh-CN.md'] = {
    sha256: createHash('sha256').update(mutated).digest('hex'),
    bytes: mutated.length,
  };
  writeFileSync(join(directory, 'freeze.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  result = run(process.execPath, [join(scripts, 'check-access-freeze.mjs'), '--base', base, '--repo', cwd]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /freeze\.json differs from trusted baseline/u);
});

test('public export preserves existing upstream instructions and rejects case variants and hidden history', () => {
  const cwd = initRepo();
  mkdirSync(join(cwd, 'docs'), {recursive: true});
  writeFileSync(join(cwd, 'docs', 'AGENTS.md'), 'upstream-owned\n');
  writeFileSync(join(cwd, 'public.txt'), 'base\n');
  const base = commitAll(cwd, 'upstream base');
  writeFileSync(join(cwd, 'public.txt'), 'public change\n');
  const cleanHead = commitAll(cwd, 'public change');
  let result = run(process.execPath, [join(scripts, 'check-public-diff.mjs'), '--base', base, '--head', cleanHead, '--repo', cwd]);
  assert.equal(result.status, 0, result.stderr);

  writeFileSync(join(cwd, 'agent.MD'), 'personal\n');
  const leakHead = commitAll(cwd, 'personal leak');
  result = run(process.execPath, [join(scripts, 'check-public-diff.mjs'), '--base', base, '--head', leakHead, '--repo', cwd]);
  assert.notEqual(result.status, 0);

  const historyRepo = initRepo();
  writeFileSync(join(historyRepo, 'public.txt'), 'base\n');
  const historyBase = commitAll(historyRepo, 'base');
  writeFileSync(join(historyRepo, 'AGENT.md'), 'temporary personal file\n');
  commitAll(historyRepo, 'add personal file');
  git(historyRepo, 'rm', 'AGENT.md');
  const historyHead = commitAll(historyRepo, 'remove personal file');
  result = run(process.execPath, [join(scripts, 'check-public-diff.mjs'), '--base', historyBase, '--head', historyHead, '--repo', historyRepo]);
  assert.notEqual(result.status, 0, 'history-only personal file unexpectedly passed');
});

test('CI identity binds a pull request to the exact B/H/M graph', () => {
  const cwd = initRepo();
  writeFileSync(join(cwd, 'file.txt'), 'base\n');
  const base = commitAll(cwd, 'base');
  git(cwd, 'checkout', '-b', 'feature');
  writeFileSync(join(cwd, 'file.txt'), 'head\n');
  const head = commitAll(cwd, 'head');
  git(cwd, 'checkout', 'main');
  git(cwd, 'merge', '--no-ff', 'feature', '-m', 'merge candidate');
  const tested = git(cwd, 'rev-parse', 'HEAD');
  let result = run(process.execPath, [
    join(scripts, 'verify-ci-identity.mjs'), '--event', 'pull_request',
    '--base', base, '--head', head, '--tested', tested, '--repo', cwd,
  ]);
  assert.equal(result.status, 0, result.stderr);
  result = run(process.execPath, [
    join(scripts, 'verify-ci-identity.mjs'), '--event', 'pull_request',
    '--base', base, '--head', base, '--tested', tested, '--repo', cwd,
  ]);
  assert.notEqual(result.status, 0);
});

test('workflow validator accepts the gate and rejects mutable action refs or weakened summary behavior', () => {
  const workflow = join(root, '.github/workflows/quality.yml');
  let result = run(process.execPath, [join(scripts, 'validate-workflow.mjs'), workflow]);
  assert.equal(result.status, 0, result.stderr);
  const cwd = mkdtempSync(join(tmpdir(), 'aegis-workflow-test-'));
  const source = readFileSync(workflow, 'utf8');
  const mutable = join(cwd, 'mutable.yml');
  writeFileSync(mutable, source.replace('actions/checkout@11d5960a326750d5838078e36cf38b85af677262', 'actions/checkout@v4'));
  result = run(process.execPath, [join(scripts, 'validate-workflow.mjs'), mutable]);
  assert.notEqual(result.status, 0);
  const skipped = join(cwd, 'skipped.yml');
  writeFileSync(skipped, source.replace('if: ${{ always() }}\n    needs:', 'if: ${{ success() }}\n    needs:'));
  result = run(process.execPath, [join(scripts, 'validate-workflow.mjs'), skipped]);
  assert.notEqual(result.status, 0);
});

test('native classification is conservative for Chromium paths', () => {
  const cwd = initRepo();
  writeFileSync(join(cwd, 'README.md'), 'base\n');
  const base = commitAll(cwd, 'base');
  mkdirSync(join(cwd, 'docs'), {recursive: true});
  writeFileSync(join(cwd, 'docs', 'guide.md'), 'docs\n');
  const docsHead = commitAll(cwd, 'docs');
  let result = run(process.execPath, [join(scripts, 'classify-native-changes.mjs'), '--base', base, '--head', docsHead, '--repo', cwd]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).status, 'NOT_APPLICABLE');
  mkdirSync(join(cwd, 'apps/browser/overlay/components/aegis'), {recursive: true});
  writeFileSync(join(cwd, 'apps/browser/overlay/components/aegis/change.cc'), 'native\n');
  const nativeHead = commitAll(cwd, 'native');
  result = run(process.execPath, [join(scripts, 'classify-native-changes.mjs'), '--base', base, '--head', nativeHead, '--repo', cwd]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).status, 'REQUIRED');
});
