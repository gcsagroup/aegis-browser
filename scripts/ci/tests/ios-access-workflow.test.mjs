import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {copyFileSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
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

test('both Fork Access callers run exactly the default cases and still reject a skip', t => {
  const {simulator, internal} = parse(readFileSync('.github/workflows/ios-fork-access.yml', 'utf8')).jobs;
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-access-discovery-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const python = spawnSync('python3', ['-c', 'import sys; print(sys.executable)'], {encoding: 'utf8'}).stdout.trim();
  mkdirSync(join(root, 'bin'));
  symlinkSync(python, join(root, 'bin/python3'));
  mkdirSync(join(root, 'apps/ios'), {recursive: true});
  symlinkSync(realpathSync('apps/ios/Tests'), join(root, 'apps/ios/Tests'));
  const scripts = join(root, 'scripts/release');
  mkdirSync(scripts, {recursive: true});
  for (const name of ['ios-access-tests.sh', 'ios_access_test_gate.py']) {
    copyFileSync(join('scripts/release', name), join(scripts, name));
  }
  writeFileSync(join(scripts, 'prepare-ios-package-core.sh'), 'exit 0\n');
  writeFileSync(join(root, 'bin/xcodebuild'), `#!${python}
import sys
sys.path.insert(0, 'scripts/release')
from pathlib import Path
from ios_access_test_gate import expected_cases
only = [item.split('AegisTests/', 1)[1] for item in sys.argv if item.startswith('-only-testing:')]
assert only, 'each Xcode invocation must supply specific selectors'
cases = sorted(pair for pair in expected_cases([Path('apps/ios/Tests/AccessKitTests'), Path('apps/ios/Tests/AegisTests')])
               if pair[0] in only or '/'.join(pair) in only)
for index, (cls, method) in enumerate(cases):
    outcome = "skipped" if "rejected" in sys.argv[sys.argv.index('-resultBundlePath') + 1] and index == 0 else "passed"
    print(f"Test Case '-[AegisTests.{cls} {method}]' {outcome}")
`, {mode: 0o755});
  const callers = [simulator, internal].map(job => job.steps.find(step => step.run?.includes('ios-access-tests.sh')));
  const observed = callers.map((step, index) => {
    assert.equal(step.env.AEGIS_IOS_ACCESS_TEST_CLASSES, '');
    const invoke = name => {
      const runRoot = join(root, name);
      mkdirSync(runRoot);
      return spawnSync('bash', ['-e', '-o', 'pipefail', '-c', step.run], {
        cwd: root, encoding: 'utf8', env: {PATH: `${root}/bin:/usr/bin:/bin`, PYTHONDONTWRITEBYTECODE: '1',
          AEGIS_IOS_DESTINATION: 'synthetic', AEGIS_IOS_ACCESS_RUN_ROOT: runRoot, ALPHA_ROOT: runRoot,
          AEGIS_IOS_ACCESS_TEST_CLASSES: step.env.AEGIS_IOS_ACCESS_TEST_CLASSES},
      });
    };
    const success = invoke(`default-${index}`);
    assert.equal(success.status, 0, success.stderr);
    const rejected = invoke(`rejected-${index}`);
    assert.equal(rejected.status, 1, rejected.stderr);
    assert.match(rejected.stdout + rejected.stderr, /^skipped: /mu);
    const log = readFileSync(join(root, `default-${index}`, 'xcodebuild.log'), 'utf8');
    assert.doesNotMatch(log, /testPhysicalDomainCampaign|testControlledSOCKSWebKitAdmission|testAuthorizedAppPath/u);
    assert.match(log, /testEstablishedSOCKSDownloadIsFencedOnWallClockExpiry/u);
    return log;
  });
  assert.deepEqual(observed[0], observed[1]);
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
