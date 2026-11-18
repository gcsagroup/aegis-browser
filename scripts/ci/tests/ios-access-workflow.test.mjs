import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {parse} from 'yaml';

test('iOS Access delivery keeps its self-hosted, internal-only workflow contract', () => {
  const delivery = readFileSync('.github/workflows/ios-delivery.yml', 'utf8');
  const fork = readFileSync('.github/workflows/ios-fork-access.yml', 'utf8');
  assert(delivery.includes('AEGIS_IOS_RUNNER_LABEL'));
  assert(fork.includes('AEGIS_IOS_RUNNER_LABEL'));
  assert(!delivery.includes('macos-26'));
  assert(!fork.includes('macos-26'));
  assert(!fork.includes('DISTRIBUTION_P12'));
  assert(!fork.includes('altool'));
  const commands = Object.values(parse(fork).jobs).flatMap(job => job.steps ?? [])
    .map(step => step.run ?? '').join('\n');
  assert(commands.includes('ios-access-tests.sh'));
  assert(commands.includes('ios-internal-archive.sh'));
});


test('Alpha archive rejects invalid inputs before invoking the release script', () => {
  const {internal} = parse(readFileSync('.github/workflows/ios-fork-access.yml', 'utf8')).jobs;
  const step = internal.steps.find(item => item.name === 'Archive the alpha iOS app');
  assert(!step.run.includes('${{ inputs.'));
  assert.equal(step.env.ALPHA_VERSION, '${{ inputs.version }}');
  assert.equal(step.env.ALPHA_BUILD, '${{ inputs.build }}');
  const root = mkdtempSync(join(tmpdir(), 'ios-alpha-contract-'));
  try {
    const trace = join(root, 'args');
    const scripts = join(root, 'scripts/release');
    mkdirSync(scripts, {recursive: true});
    writeFileSync(join(scripts, 'ios-internal-archive.sh'), 'printf "%s\\n" "$@" > "$ALPHA_TRACE"\n');
    const invoke = (version, build) => spawnSync('bash', ['-e', '-o', 'pipefail', '-c', step.run], {
      cwd: root, encoding: 'utf8', env: {...process.env, ALPHA_VERSION: version, ALPHA_BUILD: build,
        ALPHA_TRACE: trace, ALPHA_ROOT: join(root, 'run'), GITHUB_OUTPUT: join(root, 'outputs')},
    });
    for (const [version, build] of [
      ['0', '1'], ['0.8.0', '01a'], ['0.8.0', '0'], ['0.8.0\n', '2'], ['0.8.0', '10000000000'],
    ]) {
      const result = invoke(version, build);
      assert.notEqual(result.status, 0, result.stdout);
      assert.throws(() => readFileSync(trace), {code: 'ENOENT'});
    }
    for (const [version, build] of [['0.8.0', '42'], ['0.8', '9999999999']]) {
      const result = invoke(version, build);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(readFileSync(trace, 'utf8'), `${version}\n${build}\nalpha\n`);
      rmSync(join(root, 'run'), {recursive: true});
    }
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});

test('Alpha self-test artifact requires a successful archive and AccessKit tests', () => {
  const {internal} = parse(readFileSync('.github/workflows/ios-fork-access.yml', 'utf8')).jobs;
  const uploads = internal.steps.filter(step => step.uses?.startsWith('actions/upload-artifact@'));
  const [release, diagnostics] = uploads;
  assert.equal(uploads.length, 2);
  assert.match(release.if, /success\(\)/u);
  assert.match(release.if, /steps\.archive\.outcome == 'success'/u);
  assert.match(release.if, /steps\.access_tests\.outcome == 'success'/u);
  assert.match(release.with.path, /\.xcarchive/u);
  assert.match(diagnostics.if, /failure\(\)/u);
  assert.match(diagnostics.if, /steps\.archive\.outputs\.root != ''/u);
  assert.match(diagnostics.with.path, /\.log/u);
  assert.doesNotMatch(diagnostics.with.path, /\.xcarchive|receipt/u);
});
