import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtempSync, mkdirSync, readFileSync, symlinkSync, unlinkSync, writeFileSync} from 'node:fs';
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

function initRepo(directory = mkdtempSync(join(tmpdir(), 'aegis-ci-test-'))) {
  mkdirSync(directory, {recursive: true});
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

test('fixed ripgrep installer is syntactically valid', () => {
  const result = run('bash', ['-n', join(scripts, 'install-ripgrep.sh')]);
  assert.equal(result.status, 0, result.stderr);
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

test('source snapshot binds dangling symlink target bytes', () => {
  const cwd = initRepo();
  writeFileSync(join(cwd, '.gitignore'), '.artifacts/\n');
  commitAll(cwd, 'base');
  symlinkSync('missing-first', join(cwd, 'dangling-link'));
  let result = run(process.execPath, [join(scripts, 'source-snapshot.mjs'), '--repo', cwd], {cwd});
  assert.equal(result.status, 0, result.stderr);
  const first = JSON.parse(result.stdout);
  unlinkSync(join(cwd, 'dangling-link'));
  symlinkSync('missing-second', join(cwd, 'dangling-link'));
  result = run(process.execPath, [join(scripts, 'source-snapshot.mjs'), '--repo', cwd], {cwd});
  assert.equal(result.status, 0, result.stderr);
  const second = JSON.parse(result.stdout);
  assert.notEqual(first.digest, second.digest);
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

test('public export rejects external, personal, chained, and history-only symlink targets', () => {
  const cwd = initRepo();
  mkdirSync(join(cwd, 'docs'), {recursive: true});
  mkdirSync(join(cwd, 'links'), {recursive: true});
  writeFileSync(join(cwd, 'docs', 'guide.md'), 'guide\n');
  writeFileSync(join(cwd, 'AGENTS.md'), 'upstream personal file\n');
  symlinkSync('guide.md', join(cwd, 'docs', 'legal-link.md'));
  symlinkSync('../AGENTS.md', join(cwd, 'links', 'private-alias'));
  const base = commitAll(cwd, 'base with untouched links');
  writeFileSync(join(cwd, 'public.txt'), 'safe\n');
  const safeHead = commitAll(cwd, 'safe public change');
  let result = run(process.execPath, [join(scripts, 'check-public-diff.mjs'), '--base', base, '--head', safeHead, '--repo', cwd]);
  assert.equal(result.status, 0, result.stderr);

  symlinkSync('/definitely-missing/AGENTS.md', join(cwd, 'public-guide.md'));
  const absoluteHead = commitAll(cwd, 'absolute personal symlink');
  result = run(process.execPath, [join(scripts, 'check-public-diff.mjs'), '--base', base, '--head', absoluteHead, '--repo', cwd]);
  assert.notEqual(result.status, 0);

  const chainRepo = initRepo();
  mkdirSync(join(chainRepo, 'links'), {recursive: true});
  writeFileSync(join(chainRepo, 'AGENTS.md'), 'upstream personal file\n');
  symlinkSync('../AGENTS.md', join(chainRepo, 'links', 'private-alias'));
  const chainBase = commitAll(chainRepo, 'base alias');
  symlinkSync('links/private-alias', join(chainRepo, 'public-guide.md'));
  const chainHead = commitAll(chainRepo, 'chained alias');
  result = run(process.execPath, [join(scripts, 'check-public-diff.mjs'), '--base', chainBase, '--head', chainHead, '--repo', chainRepo]);
  assert.notEqual(result.status, 0);

  const escapeRepo = initRepo();
  writeFileSync(join(escapeRepo, 'base.txt'), 'base\n');
  const escapeBase = commitAll(escapeRepo, 'base');
  mkdirSync(join(escapeRepo, 'docs'), {recursive: true});
  symlinkSync('../../outside.txt', join(escapeRepo, 'docs', 'escape-link'));
  commitAll(escapeRepo, 'add escaping link');
  git(escapeRepo, 'rm', 'docs/escape-link');
  const escapeHead = commitAll(escapeRepo, 'remove escaping link');
  result = run(process.execPath, [join(scripts, 'check-public-diff.mjs'), '--base', escapeBase, '--head', escapeHead, '--repo', escapeRepo]);
  assert.notEqual(result.status, 0, 'history-only escaping symlink unexpectedly passed');

  const componentContainer = mkdtempSync(join(tmpdir(), 'aegis-rereview-'));
  const componentRepo = initRepo(join(componentContainer, 'repo'));
  mkdirSync(join(componentContainer, 'private', 'subdir'), {recursive: true});
  writeFileSync(join(componentContainer, 'private', 'secret.txt'), 'outside\n');
  writeFileSync(join(componentRepo, 'base.txt'), 'base\n');
  symlinkSync('../private/subdir', join(componentRepo, 'existing-link'));
  const componentBase = commitAll(componentRepo, 'base with external predecessor link');
  symlinkSync('existing-link/../secret.txt', join(componentRepo, 'public-guide.md'));
  const componentHead = commitAll(componentRepo, 'link through predecessor and parent');
  result = run(process.execPath, [join(scripts, 'check-public-diff.mjs'), '--base', componentBase, '--head', componentHead, '--repo', componentRepo]);
  assert.notEqual(result.status, 0, 'component-wise escape through an existing symlink unexpectedly passed');

  const internalRepo = initRepo();
  mkdirSync(join(internalRepo, 'docs'), {recursive: true});
  mkdirSync(join(internalRepo, 'links'), {recursive: true});
  writeFileSync(join(internalRepo, 'docs', 'guide.md'), 'guide\n');
  const internalBase = commitAll(internalRepo, 'base with internal target');
  symlinkSync('../docs/guide.md', join(internalRepo, 'links', 'public-guide.md'));
  const internalHead = commitAll(internalRepo, 'safe parent-relative link');
  result = run(process.execPath, [join(scripts, 'check-public-diff.mjs'), '--base', internalBase, '--head', internalHead, '--repo', internalRepo]);
  assert.equal(result.status, 0, result.stderr);
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
  writeFileSync(mutable, source.replace('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1', 'actions/checkout@v7'));
  result = run(process.execPath, [join(scripts, 'validate-workflow.mjs'), mutable]);
  assert.notEqual(result.status, 0);
  const skipped = join(cwd, 'skipped.yml');
  writeFileSync(skipped, source.replace('if: ${{ always() }}\n    needs:', 'if: ${{ success() }}\n    needs:'));
  result = run(process.execPath, [join(scripts, 'validate-workflow.mjs'), skipped]);
  assert.notEqual(result.status, 0);
});

test('native classification is NUL-safe, rename-safe, and conservative for unknown production paths', () => {
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

  const unicodeRepo = initRepo();
  writeFileSync(join(unicodeRepo, 'README.md'), 'base\n');
  const unicodeBase = commitAll(unicodeRepo, 'base');
  mkdirSync(join(unicodeRepo, 'apps/browser/overlay/components/aegis'), {recursive: true});
  writeFileSync(join(unicodeRepo, 'apps/browser/overlay/components/aegis/中文.cc'), 'native\n');
  result = run(process.execPath, [join(scripts, 'classify-native-changes.mjs'), '--base', unicodeBase, '--head', 'HEAD', '--repo', unicodeRepo, '--include-worktree'], {cwd: unicodeRepo});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).status, 'REQUIRED');

  const renameRepo = initRepo();
  mkdirSync(join(renameRepo, 'apps/browser/overlay/components/aegis'), {recursive: true});
  writeFileSync(join(renameRepo, 'apps/browser/overlay/components/aegis/original.cc'), 'native\n');
  const renameBase = commitAll(renameRepo, 'base native file');
  mkdirSync(join(renameRepo, 'docs'), {recursive: true});
  git(renameRepo, 'mv', 'apps/browser/overlay/components/aegis/original.cc', 'docs/guide.md');
  const renameHead = commitAll(renameRepo, 'rename native into docs');
  result = run(process.execPath, [join(scripts, 'classify-native-changes.mjs'), '--base', renameBase, '--head', renameHead, '--repo', renameRepo]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).status, 'REQUIRED');

  const iosRepo = initRepo();
  writeFileSync(join(iosRepo, 'README.md'), 'base\n');
  const iosBase = commitAll(iosRepo, 'base');
  mkdirSync(join(iosRepo, 'apps/ios/AgentKit'), {recursive: true});
  writeFileSync(join(iosRepo, 'apps/ios/AgentKit/AgentBroker.swift'), 'production\n');
  const iosHead = commitAll(iosRepo, 'ios production');
  result = run(process.execPath, [join(scripts, 'classify-native-changes.mjs'), '--base', iosBase, '--head', iosHead, '--repo', iosRepo]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).status, 'REVIEW_REQUIRED');
});
