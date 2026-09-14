import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {chmodSync, cpSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, unlinkSync, utimesSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, relative, resolve, sep} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
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

function coverageRecord(path) {
  return `TN:\nSF:${path}\nFNF:1\nFNH:1\nDA:1,1\nLF:1\nLH:1\nBRF:0\nBRH:0\nend_of_record\n`;
}

function createCoverageFixture() {
  const directory = mkdtempSync(join(root, '.artifacts', 'coverage-validator-'));
  const sourceDirectory = join(directory, 'source');
  const coverageDirectory = join(directory, 'coverage');
  mkdirSync(sourceDirectory, {recursive: true});
  mkdirSync(coverageDirectory, {recursive: true});
  writeFileSync(join(sourceDirectory, 'covered.ts'), 'export const covered = true;\n');
  writeFileSync(join(sourceDirectory, 'uncovered.ts'), 'export const uncovered = true;\n');
  const sourcePaths = ['covered.ts', 'uncovered.ts'].map((name) => relative(root, join(sourceDirectory, name)).split(sep).join('/'));
  writeFileSync(join(coverageDirectory, 'lcov.info'), sourcePaths.map(coverageRecord).join(''));
  writeFileSync(join(coverageDirectory, 'coverage-summary.json'), `${JSON.stringify({
    total: Object.fromEntries(['lines', 'statements', 'functions', 'branches'].map((name) => [
      name,
      name === 'branches' ? {total: 0, covered: 0, pct: 100} : {total: 2, covered: 2, pct: 100},
    ])),
  })}\n`);
  return {directory, sourceDirectory, coverageDirectory, sourcePaths};
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

test('fixed ripgrep installer selects pinned releases and rejects unknown platforms', () => {
  const result = run('bash', ['-n', join(scripts, 'install-ripgrep.sh')]);
  assert.equal(result.status, 0, result.stderr);

  for (const [operatingSystem, architecture, expected] of [
    ['Darwin', 'arm64', 'aarch64-apple-darwin 3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4'],
    ['Darwin', 'x86_64', 'x86_64-apple-darwin af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1'],
    ['Linux', 'x86_64', 'x86_64-unknown-linux-musl 33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c'],
  ]) {
    const selected = run('bash', ['-c', 'source "$1"; select_ripgrep_release "$2" "$3"', 'bash', join(scripts, 'install-ripgrep.sh'), operatingSystem, architecture]);
    assert.equal(selected.status, 0, selected.stderr);
    assert.equal(selected.stdout.trim(), expected);
  }

  const unsupported = run('bash', ['-c', 'source "$1"; select_ripgrep_release "$2" "$3"', 'bash', join(scripts, 'install-ripgrep.sh'), 'Linux', 'riscv64']);
  assert.notEqual(unsupported.status, 0);
  assert.match(unsupported.stderr, /Unsupported ripgrep platform: Linux\/riscv64/u);
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

test('workflow validator accepts every required coverage job and rejects weakened behavior', () => {
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
  const missing = join(cwd, 'missing-required-job.yml');
  writeFileSync(missing, source.replace('      - shell-coverage\n', ''));
  result = run(process.execPath, [join(scripts, 'validate-workflow.mjs'), missing]);
  assert.notEqual(result.status, 0);
  const missingResult = join(cwd, 'missing-required-result.yml');
  writeFileSync(missingResult, source.replace(',"shell-coverage":"${{ needs.shell-coverage.result }}"', ''));
  result = run(process.execPath, [join(scripts, 'validate-workflow.mjs'), missingResult]);
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

test('ESLint flat configuration accepts valid CI code and rejects a correctness error', () => {
  const directory = mkdtempSync(join(scripts, 'lint-fixture-'));
  try {
    const valid = join(directory, 'valid.mjs');
    const invalid = join(directory, 'invalid.mjs');
    writeFileSync(valid, 'export const answer = 42;\n');
    writeFileSync(invalid, 'export const answer = missingIdentifier;\n');
    let result = run(join(root, 'node_modules/.bin/eslint'), ['--config', join(root, 'eslint.config.mjs'), valid]);
    assert.equal(result.status, 0, result.stderr);
    result = run(join(root, 'node_modules/.bin/eslint'), ['--config', join(root, 'eslint.config.mjs'), invalid]);
    assert.notEqual(result.status, 0, 'ESLint accepted an undefined identifier');
    assert.match(result.stdout, /no-undef/u);
  } finally {
    rmSync(directory, {recursive: true, force: true});
  }
});

test('coverage validator accepts current complete production LCOV', () => {
  const fixture = createCoverageFixture();
  try {
    const result = run(process.execPath, [
      join(scripts, 'validate-coverage.mjs'),
      '--coverage-dir', fixture.coverageDirectory,
      '--source-root', fixture.sourceDirectory,
    ]);
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.productionFiles, 2);
    assert.equal(report.reportedFiles, 2);
  } finally {
    rmSync(fixture.directory, {recursive: true, force: true});
  }
});

test('coverage validator rejects missing, empty, corrupt, unsafe, stale, and incomplete reports', () => {
  const cases = [
    ['missing', (fixture) => unlinkSync(join(fixture.coverageDirectory, 'lcov.info'))],
    ['empty', (fixture) => writeFileSync(join(fixture.coverageDirectory, 'lcov.info'), '')],
    ['corrupt', (fixture) => writeFileSync(join(fixture.coverageDirectory, 'lcov.info'), 'not-lcov\n')],
    ['unterminated', (fixture) => writeFileSync(join(fixture.coverageDirectory, 'lcov.info'), fixture.sourcePaths.map(coverageRecord).join('').replace(/end_of_record\n$/u, ''))],
    ['duplicate DA', (fixture) => writeFileSync(join(fixture.coverageDirectory, 'lcov.info'), fixture.sourcePaths.map((path) => coverageRecord(path).replace('LF:1', 'DA:1,1\nLF:2')).join(''))],
    ['contradictory line totals', (fixture) => writeFileSync(join(fixture.coverageDirectory, 'lcov.info'), fixture.sourcePaths.map((path) => coverageRecord(path).replace('LH:1', 'LH:0')).join(''))],
    ['absolute source', (fixture) => writeFileSync(join(fixture.coverageDirectory, 'lcov.info'), coverageRecord(join(fixture.sourceDirectory, 'covered.ts')))],
    ['escaping source', (fixture) => writeFileSync(join(fixture.coverageDirectory, 'lcov.info'), coverageRecord('../outside.ts'))],
    ['nonexistent source', (fixture) => writeFileSync(join(fixture.coverageDirectory, 'lcov.info'), coverageRecord(`${relative(root, fixture.sourceDirectory).split(sep).join('/')}/missing.ts`))],
    ['missing untested production file', (fixture) => writeFileSync(join(fixture.coverageDirectory, 'lcov.info'), coverageRecord(fixture.sourcePaths[0]))],
    ['extra test source', (fixture) => {
      const testPath = join(fixture.sourceDirectory, 'covered.test.ts');
      writeFileSync(testPath, 'export const fixture = true;\n');
      writeFileSync(
        join(fixture.coverageDirectory, 'lcov.info'),
        `${fixture.sourcePaths.map(coverageRecord).join('')}${coverageRecord(relative(root, testPath).split(sep).join('/'))}`,
      );
    }],
    ['stale', (fixture) => {
      const old = new Date('2020-01-01T00:00:00Z');
      utimesSync(join(fixture.coverageDirectory, 'lcov.info'), old, old);
      utimesSync(join(fixture.coverageDirectory, 'coverage-summary.json'), old, old);
    }],
    ['impossible JSON totals', (fixture) => {
      const path = join(fixture.coverageDirectory, 'coverage-summary.json');
      const summary = JSON.parse(readFileSync(path, 'utf8'));
      summary.total.lines.covered = 3;
      writeFileSync(path, `${JSON.stringify(summary)}\n`);
    }],
    ['JSON and LCOV disagree', (fixture) => {
      const path = join(fixture.coverageDirectory, 'coverage-summary.json');
      const summary = JSON.parse(readFileSync(path, 'utf8'));
      summary.total.lines = {total: 3, covered: 2, pct: 66.66};
      writeFileSync(path, `${JSON.stringify(summary)}\n`);
    }],
  ];
  for (const [name, mutate] of cases) {
    const fixture = createCoverageFixture();
    try {
      mutate(fixture);
      const args = [
        join(scripts, 'validate-coverage.mjs'),
        '--coverage-dir', fixture.coverageDirectory,
        '--source-root', fixture.sourceDirectory,
      ];
      if (name === 'stale') args.push('--not-before', '2026-01-01T00:00:00Z');
      const result = run(process.execPath, args);
      assert.notEqual(result.status, 0, `${name} coverage unexpectedly passed`);
    } finally {
      rmSync(fixture.directory, {recursive: true, force: true});
    }
  }
});

test('V8 raw validator requires real production Node subprocess evidence', () => {
  const directory = mkdtempSync(join(root, '.artifacts', 'v8-raw-validator-'));
  try {
    const urls = [
      'apps/browser/scripts/verify-agent-runtime.mjs',
      'scripts/check-repo-contracts.mjs',
    ].map((path) => pathToFileURL(join(root, path)).href);
    writeFileSync(join(directory, 'coverage-valid.json'), `${JSON.stringify({result: urls.map((url) => ({url}))})}\n`);
    let result = run(process.execPath, [join(scripts, 'validate-v8-raw.mjs'), '--raw-dir', directory]);
    assert.equal(result.status, 0, result.stderr);
    writeFileSync(join(directory, 'coverage-valid.json'), `${JSON.stringify({result: [{url: urls[0]}]})}\n`);
    result = run(process.execPath, [join(scripts, 'validate-v8-raw.mjs'), '--raw-dir', directory]);
    assert.notEqual(result.status, 0, 'V8 report missing an executed production subprocess unexpectedly passed');
    writeFileSync(join(directory, 'coverage-valid.json'), '{broken\n');
    result = run(process.execPath, [join(scripts, 'validate-v8-raw.mjs'), '--raw-dir', directory]);
    assert.notEqual(result.status, 0, 'Corrupt V8 raw coverage unexpectedly passed');
  } finally {
    rmSync(directory, {recursive: true, force: true});
  }
});

test('quality entrypoint refuses existing or symlinked report paths without deleting sentinels', () => {
  const cwd = initRepo();
  mkdirSync(join(cwd, 'scripts/ci'), {recursive: true});
  cpSync(join(scripts, 'run-quality.mjs'), join(cwd, 'scripts/ci/run-quality.mjs'));
  cpSync(join(scripts, 'common.mjs'), join(cwd, 'scripts/ci/common.mjs'));
  writeFileSync(join(cwd, '.gitignore'), '.artifacts/\n');
  const base = commitAll(cwd, 'fixture');
  const existing = join(cwd, '.artifacts/ci/existing');
  mkdirSync(existing, {recursive: true});
  const existingSentinel = join(existing, 'sentinel.txt');
  writeFileSync(existingSentinel, 'preserve existing report\n');
  let result = run(process.execPath, [
    join(cwd, 'scripts/ci/run-quality.mjs'), '--scope', 'full', '--base', base,
    '--report-dir', '.artifacts/ci/existing',
  ], {cwd});
  assert.notEqual(result.status, 0, 'Existing report directory unexpectedly passed');
  assert.equal(readFileSync(existingSentinel, 'utf8'), 'preserve existing report\n');

  const outside = mkdtempSync(join(tmpdir(), 'aegis-report-outside-'));
  try {
    const outsideSentinel = join(outside, 'sentinel.txt');
    writeFileSync(outsideSentinel, 'preserve outside report\n');
    symlinkSync(outside, join(cwd, '.artifacts/ci/escape'));
    result = run(process.execPath, [
      join(cwd, 'scripts/ci/run-quality.mjs'), '--scope', 'full', '--base', base,
      '--report-dir', '.artifacts/ci/escape/new-report',
    ], {cwd});
    assert.notEqual(result.status, 0, 'Symlinked report ancestor unexpectedly passed');
    assert.equal(readFileSync(outsideSentinel, 'utf8'), 'preserve outside report\n');
    assert.equal(existsSync(join(outside, 'new-report')), false);
  } finally {
    rmSync(outside, {recursive: true, force: true});
  }
});

test('quality entrypoint returns nonzero and writes FAIL when the test command fails', () => {
  const cwd = initRepo();
  mkdirSync(join(cwd, 'scripts/ci'), {recursive: true});
  mkdirSync(join(cwd, 'fake-bin'), {recursive: true});
  mkdirSync(join(cwd, 'packages/core'), {recursive: true});
  mkdirSync(join(cwd, 'apps/browser'), {recursive: true});
  cpSync(join(scripts, 'run-quality.mjs'), join(cwd, 'scripts/ci/run-quality.mjs'));
  cpSync(join(scripts, 'common.mjs'), join(cwd, 'scripts/ci/common.mjs'));
  cpSync(join(scripts, 'check-license-metadata.mjs'), join(cwd, 'scripts/ci/check-license-metadata.mjs'));
  cpSync(join(root, 'LICENSE'), join(cwd, 'LICENSE'));
  cpSync(join(root, 'THIRD_PARTY_NOTICES.md'), join(cwd, 'THIRD_PARTY_NOTICES.md'));
  for (const path of ['package.json', 'packages/core/package.json', 'apps/browser/package.json']) {
    writeFileSync(join(cwd, path), '{"license":"Apache-2.0"}\n');
  }
  symlinkSync(join(root, 'node_modules'), join(cwd, 'node_modules'));
  writeFileSync(join(cwd, '.gitignore'), '.artifacts/\n');
  const fake = (name, source) => {
    const path = join(cwd, 'fake-bin', name);
    writeFileSync(path, `#!/bin/sh\n${source}\n`);
    chmodSync(path, 0o755);
  };
  fake('pnpm', 'if [ "$1" = "--version" ]; then echo 9.15.0; exit 0; fi\nif [ "$1" = "install" ]; then exit 0; fi\nexit 0');
  fake('corepack', 'if [ "$1" = "pnpm" ] && [ "$2" = "--version" ]; then echo 9.15.0; exit 0; fi\nif [ "$1" = "pnpm" ] && [ "$2" = "run" ] && [ "$3" = "quality:fast" ]; then exit 23; fi\nexit 0');
  fake('python3', 'if [ "$1" = "--version" ]; then echo "Python 3.11.9"; exit 0; fi\nif [ "$1" = "-m" ] && [ "$2" = "venv" ]; then mkdir -p "$3/bin"; printf "#!/bin/sh\\nexit 0\\n" > "$3/bin/python"; printf "#!/bin/sh\\necho \\"Coverage.py, version 7.16.1\\"\\nexit 0\\n" > "$3/bin/coverage"; chmod +x "$3/bin/python" "$3/bin/coverage"; exit 0; fi\nexit 0');
  fake('rg', 'echo "ripgrep 14.1.1"');
  fake('clang++', 'echo "clang version 21.0.0"');
  const base = commitAll(cwd, 'fixture');
  const reportDirectory = join(cwd, '.artifacts/ci/failure');
  const result = run(process.execPath, [
    join(cwd, 'scripts/ci/run-quality.mjs'), '--scope', 'full', '--base', base,
    '--report-dir', '.artifacts/ci/failure',
  ], {cwd, env: {
    GITHUB_ACTIONS: 'false',
    PATH: `${join(cwd, 'fake-bin')}:${process.env.PATH}`,
  }});
  assert.notEqual(result.status, 0);
  assert.equal(existsSync(join(reportDirectory, 'report.json')), true, `${result.stdout}\n${result.stderr}`);
  const report = JSON.parse(readFileSync(join(reportDirectory, 'report.json'), 'utf8'));
  assert.equal(report.result, 'FAIL');
  assert.equal(report.checks.find((check) => check.name === 'quality:fast')?.result, 'FAIL');
});
