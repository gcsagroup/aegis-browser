import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';

const root = resolve(import.meta.dirname, '../../..');
const scripts = join(root, 'scripts/ci');

test('Bash coverage keeps only real production shell sources and retains zero-hit files', () => {
  const runnerPath = join(scripts, 'run-shell-coverage.sh');
  const runnerSource = readFileSync(runnerPath, 'utf8');
  const normalizer = runnerSource.match(
    /# BEGIN_SHELL_COVERAGE_REPORT_PYTHON[\s\S]*?<<'PY'\n([\s\S]*?)\nPY\n# END_SHELL_COVERAGE_REPORT_PYTHON/u,
  );
  assert.ok(normalizer, 'shell coverage report normalizer must remain testable');

  const directory = mkdtempSync(join(tmpdir(), 'shell-coverage-filter-'));
  try {
    const browserScripts = join(root, 'apps/browser/scripts');
    const production = readdirSync(browserScripts, {withFileTypes: true})
      .filter((entry) => entry.isFile() && entry.name.endsWith('.sh') && !entry.name.endsWith('_test.sh'))
      .map((entry) => `apps/browser/scripts/${entry.name}`)
      .sort();
    const required = new Set([
      'apps/browser/scripts/common.sh',
      'apps/browser/scripts/run.sh',
      'apps/browser/scripts/status.sh',
    ]);
    const classes = production.map((path) =>
      `<class filename="${path}"><lines><line number="1" hits="${required.has(path) ? 1 : 0}"/></lines></class>`,
    );
    classes.push(
      '<class filename="apps/browser/scripts/verify-agent-runtime.mjs"><lines><line number="1" hits="999"/></lines></class>',
    );
    const input = join(directory, 'polluted-cobertura.xml');
    const output = join(directory, 'output');
    const results = join(directory, 'test-results.txt');
    mkdirSync(output);
    writeFileSync(input, `<coverage><packages><package><classes>${classes.join('')}</classes></package></packages></coverage>\n`);
    writeFileSync(results, 'run_test.sh\tPASS\n');

    const normalize = (source, target) => spawnSync('python3', ['-', root, browserScripts, source, target, results], {
      encoding: 'utf8',
      input: normalizer[1],
      env: {
        ...process.env,
        KCOV_VERSION_OUTPUT: 'kcov 43',
        KCOV_BINARY_SHA256: '1'.repeat(64),
        KCOV_SOURCE_URL: 'https://example.invalid/kcov.tar.gz',
        KCOV_SOURCE_SHA256: '2'.repeat(64),
        KCOV_SOURCE_COMMIT: 'a39874f938ce13f7a65f253120d1ec946b349ffe',
        KCOV_SOURCE_TAG: 'v43',
        TESTED_SHA: execFileSync('git', ['rev-parse', 'HEAD'], {cwd: root, encoding: 'utf8'}).trim(),
      },
    });
    const result = normalize(input, output);
    assert.equal(result.status, 0, result.stderr);

    const metadata = JSON.parse(readFileSync(join(output, 'metadata.json'), 'utf8'));
    assert.deepEqual(metadata.scope.reportedProductionFiles, production);
    assert.deepEqual(metadata.scope.unmeasuredProductionFiles, []);
    assert.equal(metadata.totals.lines.covered, required.size);
    assert.equal(metadata.totals.lines.total, production.length);
    const lcov = readFileSync(join(output, 'lcov.info'), 'utf8');
    const cobertura = readFileSync(join(output, 'cobertura.xml'), 'utf8');
    assert.doesNotMatch(lcov, /\.mjs/u);
    assert.doesNotMatch(cobertura, /\.mjs/u);
    assert.match(lcov, /SF:apps\/browser\/scripts\/build-release\.sh\nDA:1,0/u);

    const incompleteInput = join(directory, 'incomplete-cobertura.xml');
    const incompleteOutput = join(directory, 'incomplete-output');
    mkdirSync(incompleteOutput);
    writeFileSync(incompleteInput, `<coverage><packages><package><classes>${classes.filter((entry) => !entry.includes('build-release.sh')).join('')}</classes></package></packages></coverage>\n`);
    const incomplete = normalize(incompleteInput, incompleteOutput);
    assert.notEqual(incomplete.status, 0);
    assert.match(incomplete.stderr, /omits production Bash sources: apps\/browser\/scripts\/build-release\.sh/u);
  } finally {
    rmSync(directory, {recursive: true, force: true});
  }
});
