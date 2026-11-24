import assert from 'node:assert/strict';
import {execFileSync, spawn, spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';
import {setTimeout as delay} from 'node:timers/promises';

const archiveScript = 'scripts/ci/run-ios-unsigned-archive.sh';
const supervisorScript = 'scripts/ci/ios-archive-supervisor.py';
const supervisorFixture = resolve('scripts/ci/tests/ios-archive-supervisor-fixture.py');
const proxyUser = 'fixture-proxy-user';
const proxyToken = 'fixture-proxy-token%21';
const authenticatedProxy = `http://${proxyUser}:${proxyToken}@proxy.example.invalid:8080`;
const withheld = 'archive diagnostics withheld';

function running(pid) {
  try {
    process.kill(pid, 0);
  } catch (error) {
    if (error.code === 'ESRCH') return false;
    if (error.code !== 'EPERM') throw error;
  }
  // A reparented zombie cannot read the next checkout, even if its PID
  // survives briefly after the wrapper exits.
  const state = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'stat='], {encoding: 'utf8'});
  if (state.error) throw state.error;
  if (state.status === 1 && !state.stdout.trim()) return false;
  assert.equal(state.status, 0, state.stderr);
  return !state.stdout.trim().startsWith('Z');
}

async function waitFor(predicate, label) {
  for (let index = 0; index < 160; index += 1) {
    if (predicate()) return;
    await delay(50);
  }
  throw new Error(`timed out waiting for ${label}`);
}

const compiler = String.raw`#!/bin/bash
exec "$ARCHIVE_TEST_PYTHON" -c '
import json, os, signal, time
from pathlib import Path

root = Path(os.environ["IOS_CI_ROOT"])
probe = root / "next-checkout"
deadline = time.monotonic() + 15
assert os.environ["RUNNER_TRACKING_ID"] == "archive-fixture"

def mark(role):
    status = [os.getpid(), os.getppid(), os.getpgrp(), os.getsid(0)]
    ready = root / (role + ".ready")
    ready.write_text(json.dumps(status))
    ready.rename(root / role)

def watch():
    while root.is_dir() and time.monotonic() < deadline:
        if probe.exists():
            (root / "saw-next-checkout").touch()
            return
        time.sleep(0.01)

if os.fork() == 0:
    if os.fork() == 0:
        os.setpgid(0, 0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        os.write(2, b"separate-group grandchild diagnostic\n")
        if "HTTPS_PROXY" in os.environ:
            os.write(2, os.environ["HTTPS_PROXY"].encode())
        mark("grandchild")
    else:
        mark("helper")
    watch()
    os._exit(0)

mark("compiler")
if os.environ["ARCHIVE_TEST_FAIL"] == "1":
    while not (root / "helper").exists() or not (root / "grandchild").exists():
        if time.monotonic() >= deadline:
            raise SystemExit(1)
        time.sleep(0.01)
    raise SystemExit(65)
watch()
'
`;

function prepareFixture(root, compilerScript = compiler, verifierScript = '') {
  const bin = join(root, 'bin');
  const source = join(root, 'Source');
  const python = execFileSync('python3', ['-c', 'import sys; print(sys.executable)'], {encoding: 'utf8'}).trim();
  mkdirSync(bin);
  for (const path of [archiveScript, supervisorScript]) {
    mkdirSync(join(source, path, '..'), {recursive: true});
    copyFileSync(path, join(source, path));
  }
  mkdirSync(join(source, 'apps/ios/Aegis.xcodeproj'), {recursive: true});
  writeFileSync(join(source, 'apps/ios/Aegis.xcodeproj/project.pbxproj'), '// fixture\n');
  writeFileSync(join(bin, 'python3'), `#!/bin/bash
case "$3" in
  */ios-archive-supervisor.py)
    shift 2
    exec "$ARCHIVE_TEST_PYTHON" -I -B "$ARCHIVE_TEST_SUPERVISOR" "$@"
    ;;
esac
if [[ "$2" == */ios_embedded_core.py ]]; then printf 'embedded core verified\\n' || exit 98; fi
${verifierScript}
exit 0
`, {mode: 0o755});
  writeFileSync(join(bin, 'xcodebuild'), compilerScript, {mode: 0o755});
  const env = {PATH: `${bin}:/usr/bin:/bin`, HOME: root, IOS_CI_ROOT: root, IOS_CI_SOURCE: source,
    GIT_CONFIG_GLOBAL: join(root, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1', GIT_ALLOW_PROTOCOL: 'file',
    RUNNER_TRACKING_ID: 'archive-fixture', ARCHIVE_TEST_PYTHON: python, ARCHIVE_TEST_SUPERVISOR: supervisorFixture};
  return {source, python, env, wrapper: join(source, archiveScript)};
}

for (const [signal, exitCode, proxy] of [['SIGTERM', 143], ['SIGINT', 130], [null, 65], ['SIGTERM', 143, authenticatedProxy]]) {
  test(`archive ${signal ?? 'compiler failure'} stops owned descendants before wrapper exit${proxy ? ' with a proxy' : ''}`, async () => {
    const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-cancel-|'));
    const {source, python, env, wrapper} = prepareFixture(root);

    // A sibling job follows the same log while the compiler is running.
    const log = join(root, 'xcodebuild.log');
    const loggerReady = join(root, 'logger-ready');
    writeFileSync(log, '');
    const otherJob = spawn(python, ['-c', `
import os, pathlib, sys, time
with open(sys.argv[1], "rb") as log:
    pathlib.Path(sys.argv[2]).write_text(str(os.getpid()))
    for _ in range(200):
        log.read()
        time.sleep(0.1)
`, log, loggerReady], {
      stdio: 'ignore',
    });
    const child = spawn('bash', [wrapper], {
      cwd: source,
      env: {...env, ARCHIVE_TEST_FAIL: signal ? '0' : '1', ...(proxy ? {HTTPS_PROXY: proxy} : {})},
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let diagnostic = '';
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { diagnostic += data; });
    let nextCheckoutStarted = false;
    child.once('exit', () => {
      writeFileSync(join(root, 'next-checkout'), 'next job checked out\n');
      nextCheckoutStarted = true;
    });
    const roles = ['compiler', 'helper', 'grandchild'];
    const ready = () => [loggerReady, ...roles.map(role => join(root, role))].every(path => existsSync(path));
    try {
      await waitFor(() => nextCheckoutStarted || (ready() && stdout.includes(withheld)), 'process markers and status notice');
      assert(ready(), diagnostic);
      const [[compilerPid, supervisorPid, group, session], [helperPid, compilerParent, helperGroup, helperSession],
        [grandchildPid, helperParent, grandchildGroup, grandchildSession]] = roles.map(role =>
        JSON.parse(readFileSync(join(root, role), 'utf8')));
      assert.equal(supervisorPid, child.pid, 'the compiler must be the entry supervisor’s direct child');
      assert.deepEqual([group, session], [compilerPid, compilerPid]);
      assert.deepEqual([compilerParent, helperParent], [compilerPid, helperPid]);
      assert.deepEqual([helperGroup, grandchildGroup], [group, grandchildPid]);
      assert.deepEqual([helperSession, grandchildSession], [session, session]);

      if (signal) {
        assert(stdout.includes(withheld), diagnostic);
        assert.equal(child.kill(signal), true);
      }
      await waitFor(() => nextCheckoutStarted, 'wrapper exit and next-checkout probe');
      assert.equal(child.exitCode, exitCode, diagnostic);
      const retained = readFileSync(log, 'utf8');
      for (const sink of [retained, stdout + diagnostic]) {
        assert(sink.includes(withheld));
        assert(sink.includes('compiler exited with status ' + (signal ? 143 : exitCode)));
        if (signal) assert(sink.includes('wrapper cancelled with status ' + exitCode));
        assert(!sink.includes('separate-group grandchild diagnostic') && !sink.includes(authenticatedProxy));
      }
      for (const pid of [compilerPid, helperPid, grandchildPid]) {
        assert.equal(running(pid), false, `archive descendant ${pid} survived wrapper exit`);
      }
      assert.equal(running(otherJob.pid), true, 'the unrelated log reader must survive');
      assert.equal(existsSync(join(root, 'saw-next-checkout')), false);
    } finally {
      child.removeAllListeners('exit');
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
      otherJob.kill('SIGTERM');
      rmSync(root, {recursive: true, force: true});
    }
  });
}

const proxyCompiler = String.raw`#!/bin/bash
case "$ARCHIVE_TEST_INPUT" in
  config|relative-config)
    if [[ "$ARCHIVE_TEST_INPUT" == relative-config ]]; then cd overrides || exit 68; fi
    proxy="$(/usr/bin/git config --get-urlmatch http.proxy https://git.example.invalid)" || exit 68
    ;;
  malformed)
    if /usr/bin/git config --get http.proxy; then exit 68; fi
    proxy="$ARCHIVE_TEST_EXPECTED_TRANSPORT"
    ;;
  env) proxy="$HTTPS_PROXY" ;;
  plain) proxy="$https_proxy" ;;
  tls) proxy="$(/usr/bin/printenv "$ARCHIVE_TEST_TLS_NAME")" || exit 68 ;;
esac
test "$proxy" = "$ARCHIVE_TEST_EXPECTED_TRANSPORT" || exit 69
test "$RUNNER_TRACKING_ID" = archive-fixture || exit 70
printf 'synthetic Git stdout: %s\n' "$proxy"
printf 'synthetic Git stderr: %s\n' "$proxy" >&2
printf '%s' 'synthetic partial line' >&2
exit "$ARCHIVE_TEST_EXIT"
`;

const proxyTlsNames = ['GIT_PROXY_SSL_CERT', 'GIT_PROXY_SSL_KEY', 'GIT_PROXY_SSL_CAINFO',
  'GIT_PROXY_SSL_CERT_PASSWORD_PROTECTED'];
for (const input of ['env', 'config', 'included-config', 'injected-config', 'relative-config', 'malformed', 'plain',
  ...proxyTlsNames]) {
  test('archive contains proxy diagnostics from ' + input, () => {
    const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-proxy-'));
    try {
      const {env, source, wrapper} = prepareFixture(root, proxyCompiler, `
if [[ "$1" == */verify-ios-archive.py ]]; then
  printf 'verifier reached\\n' > "$IOS_CI_ROOT/verified"
  printf 'synthetic verifier diagnostic: %s\\n' "$ARCHIVE_TEST_EXPECTED_TRANSPORT" >&2
fi
`);
      const success = input === 'plain';
      const proxy = success ? 'http://plain-proxy.example.invalid:8080' : authenticatedProxy;
      const tracePath = join(root, 'trace.json');
      const tls = proxyTlsNames.includes(input);
      env.ARCHIVE_TEST_LEAF_COMPILER = '1';
      env.ARCHIVE_TEST_INPUT = tls ? 'tls' : (['included-config', 'injected-config'].includes(input) ? 'config' : input);
      if (tls) {
        env.ARCHIVE_TEST_TLS_NAME = input;
        env[input] = proxy;
      }
      env.ARCHIVE_TEST_EXPECTED_TRANSPORT = proxy;
      env.ARCHIVE_TEST_EXIT = success ? '0' : '65';
      env.GIT_TRACE = '1';
      env.GIT_TRACE2_EVENT = tracePath;
      if (input === 'env') env.HTTPS_PROXY = proxy;
      if (input === 'plain') env.https_proxy = proxy;
      if (input === 'config') writeFileSync(env.GIT_CONFIG_GLOBAL, '[http "https://git.example.invalid"]\nproxy = ' + proxy + '\n');
      if (input === 'included-config') {
        writeFileSync(env.GIT_CONFIG_GLOBAL, '[include]\npath = proxy-config\n');
        writeFileSync(join(root, 'proxy-config'), '[http]\nproxy = ' + proxy + '\n');
      }
      if (input === 'relative-config') {
        env.GIT_CONFIG_GLOBAL = 'relative-config';
        mkdirSync(join(source, 'overrides'));
        writeFileSync(join(source, 'overrides', 'relative-config'), '[http]\nproxy = ' + proxy + '\n');
      }
      if (input === 'malformed') writeFileSync(env.GIT_CONFIG_GLOBAL, '[malformed ' + proxy + '\n');
      if (input === 'injected-config') Object.assign(env, {
        GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'http.proxy', GIT_CONFIG_VALUE_0: proxy,
      });
      const child = spawnSync('bash', [wrapper], {env, encoding: 'utf8', timeout: 20000});
      assert.ifError(child.error);
      assert.equal(child.status, success ? 0 : 65);
      const retained = readFileSync(join(root, 'xcodebuild.log'), 'utf8');
      const sinks = [['console', child.stdout + child.stderr], ['xcodebuild.log', retained]];
      const prohibited = [proxy, 'proxy.example.invalid', proxyUser, proxyToken, decodeURIComponent(proxyToken),
        'synthetic Git stdout', 'synthetic Git stderr', 'synthetic partial line', 'synthetic verifier diagnostic'];
      const leaks = sinks.filter(([, output]) => prohibited.some(value => output.includes(value)));
      assert.deepEqual(leaks.map(([name]) => name), [], 'sinks containing raw transport diagnostics');
      for (const [name, output] of sinks) {
        assert.equal(output.includes('archive diagnostics withheld'), true, name);
        assert.equal(output.includes('compiler exited with status ' + (success ? 0 : 65)), true, name);
      }
      assert.equal(existsSync(tracePath), false, 'Git must not retain a trace file');
      assert.equal(existsSync(join(root, 'verified')), success);
    } finally {
      rmSync(root, {recursive: true, force: true});
    }
  });
}

test('archive without transport overrides retains a status log and disables Git tracing', () => {
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-quiet-git-'));
  try {
    const {env, wrapper} = prepareFixture(root, '#!/bin/bash\n/usr/bin/git config --get fixture.diagnostic\n');
    const tracePath = join(root, 'trace.json');
    writeFileSync(env.GIT_CONFIG_GLOBAL, '[trace2]\neventTarget = ' + tracePath + '\n[fixture]\ndiagnostic = ordinary compiler output\n');
    env.GIT_TRACE = '1';
    env.GIT_CURL_VERBOSE = '1';
    env.ARCHIVE_TEST_LEAF_COMPILER = '1';
    const child = spawnSync('bash', [wrapper], {env, encoding: 'utf8', timeout: 20000});
    assert.ifError(child.error);
    assert.equal(child.status, 0);
    assert.match(child.stdout, /compiler exited with status 0/u);
    assert.doesNotMatch(child.stdout + child.stderr, /ordinary compiler output|trace:/u);
    assert.match(child.stderr, /verification exited with status 0/u);
    assert.equal(readFileSync(join(root, 'xcodebuild.log'), 'utf8'), child.stdout);
    assert.equal(existsSync(tracePath), false, 'Git must not retain a config-specified trace file');
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});

const transportCompiler = String.raw`#!/bin/bash
touch "$IOS_CI_ROOT/compiler-started"
printf 'compiler stdout: %s\n' "$ARCHIVE_TEST_DIAGNOSTIC"
printf 'compiler stderr: %s\n' "$ARCHIVE_TEST_DIAGNOSTIC" >&2
exit "$ARCHIVE_TEST_EXIT"
`;

function transportFixture(root, status) {
  const fixture = prepareFixture(root, transportCompiler, `
if [[ "$1" == */verify-ios-archive.py ]]; then
  touch "$IOS_CI_ROOT/verified"
  printf 'verifier output: %s\\n' "$ARCHIVE_TEST_DIAGNOSTIC"
fi
`);
  Object.assign(fixture.env, {ARCHIVE_TEST_LEAF_COMPILER: '1', ARCHIVE_TEST_DIAGNOSTIC: authenticatedProxy,
    ARCHIVE_TEST_EXIT: String(status)});
  return fixture;
}

function runTransportFixture(root, fixture, status) {
  const child = spawnSync('bash', [fixture.wrapper], {env: fixture.env, encoding: 'utf8', timeout: 20000});
  assert.ifError(child.error);
  assert.equal(child.status, status, child.stderr);
  return [child.stdout + child.stderr, readFileSync(join(root, 'xcodebuild.log'), 'utf8')];
}

function assertNoRawDiagnostics([console, retained], pattern) {
  const sinks = [['console', console], ['xcodebuild.log', retained]];
  assert.deepEqual(sinks.filter(([, output]) => pattern.test(output)).map(([name]) => name), [],
    'sinks containing raw transport diagnostics');
}

test('archive contains a SwiftPM mirror path token with the mirror file as the only transport override', () => {
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-mirror-'));
  try {
    const {env, wrapper} = prepareFixture(root, String.raw`#!/bin/bash
exec "$ARCHIVE_TEST_PYTHON" -I -B -c '
import json, os, sys
with open(os.environ["SWIFTPM_MIRROR_CONFIG"]) as config:
    mirror = json.load(config)["object"][0]["mirror"]
assert "fixture-mirror-path-token" in mirror
print("mirror fetch failed: " + mirror)
print("mirror fetch failed: " + mirror, file=sys.stderr)
sys.exit(65)
'
`);
    const mirror = 'https://mirror.example.invalid/packages/fixture-mirror-path-token/Firebase.git';
    env.SWIFTPM_MIRROR_CONFIG = join(root, 'mirrors.json');
    env.ARCHIVE_TEST_LEAF_COMPILER = '1';
    writeFileSync(env.SWIFTPM_MIRROR_CONFIG, JSON.stringify({
      version: 1, object: [{original: 'https://git.example.invalid/Firebase.git', mirror}],
    }));
    const sinks = runTransportFixture(root, {env, wrapper}, 65);
    assertNoRawDiagnostics(sinks, /mirror fetch failed|mirror\.example\.invalid|fixture-mirror-path-token/u);
    for (const sink of sinks) {
      assert.match(sink, /compiler exited with status 65/u);
    }
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});

for (const [compilerStatus, wrapperStatus] of [[65, 65], [0, 79]]) {
  test('archive contains transport changes first read after startup with compiler status ' + compilerStatus, () => {
    const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-late-config-'));
    try {
      const compilerScript = String.raw`#!/bin/bash
if git config --get http.proxy; then exit 68; fi
printf '[http]\nproxy = %s\n' "$ARCHIVE_TEST_DIAGNOSTIC" > "$GIT_CONFIG_GLOBAL"
proxy="$(git config --get http.proxy)" || exit 69
test "$proxy" = "$ARCHIVE_TEST_DIAGNOSTIC" || exit 70
printf 'late compiler stdout: %s\n' "$proxy"
printf 'late compiler stderr: %s\n' "$proxy" >&2
exit "$ARCHIVE_TEST_EXIT"
`;
      const verifierScript = String.raw`
if [[ "$1" == */verify-ios-archive.py ]]; then
  proxy="$(git config --get http.proxy)" || exit 71
  test "$proxy" = "$ARCHIVE_TEST_DIAGNOSTIC" || exit 72
  touch "$IOS_CI_ROOT/verified"
  printf 'late verifier stdout: %s\n' "$proxy"
  printf 'late verifier stderr: %s\n' "$proxy" >&2
  exit 79
fi
if [[ "$3" == */ios-ci-storage.py ]]; then touch "$IOS_CI_ROOT/sealed"; fi
`;
      const {env, wrapper} = prepareFixture(root, compilerScript, verifierScript);
      Object.assign(env, {ARCHIVE_TEST_LEAF_COMPILER: '1', ARCHIVE_TEST_DIAGNOSTIC: authenticatedProxy,
        ARCHIVE_TEST_EXIT: String(compilerStatus)});
      writeFileSync(env.GIT_CONFIG_GLOBAL, '');
      const sinks = runTransportFixture(root, {env, wrapper}, wrapperStatus);
      assertNoRawDiagnostics(sinks, /late (compiler|verifier)|fixture-proxy|proxy\.example\.invalid/u);
      for (const sink of sinks) {
        assert(sink.includes('compiler exited with status ' + compilerStatus));
      }
      const [console] = sinks;
      assert.equal(console.includes('verification exited with status 79'), compilerStatus === 0);
      assert.equal(existsSync(join(root, 'verified')), compilerStatus === 0);
      assert.equal(existsSync(join(root, 'sealed')), false);
    } finally {
      rmSync(root, {recursive: true, force: true});
    }
  });
}

test('archive preserves the selected Xcode Git on PATH and emits safe failure status', () => {
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-xcode-git-'));
  try {
    const compilerScript = String.raw`#!/bin/bash
test "$(command -v git)" = "$DEVELOPER_DIR/usr/bin/git" || exit 68
exec git fixture-fetch
`;
    const {env, wrapper} = prepareFixture(root, compilerScript);
    const developer = join(root, 'Synthetic Xcode', 'Developer');
    const git = join(developer, 'usr/bin/git');
    mkdirSync(join(git, '..'), {recursive: true});
    writeFileSync(git, String.raw`#!/bin/bash
test "$1" = fixture-fetch || exit 69
touch "$IOS_CI_ROOT/xcode-git-used"
printf 'synthetic Xcode Git diagnostic: %s\n' "$ARCHIVE_TEST_DIAGNOSTIC" >&2
exit 65
`, {mode: 0o755});
    Object.assign(env, {DEVELOPER_DIR: developer, PATH: join(developer, 'usr/bin') + ':' + env.PATH,
      ARCHIVE_TEST_LEAF_COMPILER: '1', ARCHIVE_TEST_DIAGNOSTIC: authenticatedProxy});
    for (const sink of runTransportFixture(root, {env, wrapper}, 65)) {
      assert.match(sink, /archive diagnostics withheld because transport settings can change/u);
      assert.match(sink, /compiler exited with status 65/u);
      assert.doesNotMatch(sink, /synthetic Xcode Git diagnostic|fixture-proxy/u);
    }
    assert.equal(existsSync(join(root, 'xcode-git-used')), true);
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});

test('pre-compile verification withholds diagnostics and gates the compiler and seal', t => {
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-precompile-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const {env, wrapper} = prepareFixture(root, '#!/bin/bash\ntouch "$IOS_CI_ROOT/compiler-started"\n', String.raw`
if [[ "$2" == */ios_embedded_core.py ]]; then
  echo "$ARCHIVE_TEST_DIAGNOSTIC"
  echo "$ARCHIVE_TEST_DIAGNOSTIC" >&2
  exit 47
fi
touch "$IOS_CI_ROOT/post-archive-started"
`);
  Object.assign(env, {ARCHIVE_TEST_LEAF_COMPILER: '1', ARCHIVE_TEST_DIAGNOSTIC: authenticatedProxy});
  const sinks = runTransportFixture(root, {env, wrapper}, 47);
  for (const sink of sinks) {
    assert.match(sink, /pre-compile EmbeddedCore verification exited with status 47/u);
    assert.doesNotMatch(sink, /fixture-proxy|compiler exited|archive verification starting/u);
  }
  assert(!existsSync(join(root, 'compiler-started')));
  assert(!existsSync(join(root, 'post-archive-started')));
});

const fileBackedCompiler = String.raw`#!/bin/bash
set -eu
while [[ $# -gt 0 ]]; do
  case "$1" in
    -resultBundlePath) result="$2"; shift ;;
    -derivedDataPath) derived="$2"; shift ;;
  esac
  shift
done
test "$TMPDIR" = "$IOS_CI_SCRATCH/tmp"
test "$result" = "$IOS_CI_SCRATCH/Aegis.xcresult"
test "$derived" = "$IOS_CI_SCRATCH/DerivedData"
if [[ "$(uname -s)" == Darwin ]]; then
  mode="$(/usr/bin/stat -f '%Lp' "$IOS_CI_SCRATCH")"
else
  mode="$(/usr/bin/stat -c '%a' "$IOS_CI_SCRATCH")"
fi
test "$mode" = 700
mkdir -p "$result" "$derived/Logs" "$TMPDIR/ResultBundle_fixture.xcresult"
for file in "$result/diagnostics" "$derived/Logs/archive.xcactivitylog" "$TMPDIR/ResultBundle_fixture.xcresult/diagnostics"; do
  printf '%s\n' "$ARCHIVE_TEST_DIAGNOSTIC" > "$file"
done
ln -s "$ARCHIVE_TEST_HISTORICAL_ROOT" "$IOS_CI_SCRATCH/unrelated-job"
printf '%s\n' "$IOS_CI_SCRATCH" > "$IOS_CI_ROOT/diagnostics-ready"
if [[ "$ARCHIVE_TEST_DIAGNOSTICS_MODE" == cancel ]]; then exec /bin/sleep 15; fi
exit "$ARCHIVE_TEST_EXIT"
`;

for (const [mode, exitCode] of [['success', 0], ['failure', 65], ['cancel', 143]]) {
  test(`archive confines file-backed Xcode diagnostics on ${mode}`, async t => {
    const parent = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-files-'));
    t.after(() => rmSync(parent, {recursive: true, force: true}));
    const root = join(parent, 'current job');
    const historical = join(parent, 'historical job');
    mkdirSync(root, {mode: 0o700});
    mkdirSync(historical, {mode: 0o700});
    const priorBundle = join(historical, 'ResultBundle_prior.xcresult');
    const priorDiagnostic = join(root, 'tmp/ResultBundle_previous.xcresult');
    mkdirSync(join(root, 'tmp'));
    for (const path of [priorBundle, priorDiagnostic]) writeFileSync(path, 'retained evidence');
    const {env, wrapper} = prepareFixture(root, fileBackedCompiler, String.raw`
if [[ "$2" == */test_ios_linked_bundle.py ]]; then
  test "$5" = "$IOS_CI_SCRATCH/DerivedData" && test -f "$5/Logs/archive.xcactivitylog" || exit 73
  touch "$IOS_CI_ROOT/linked-verified"
fi
if [[ "$3" == */ios-ci-storage.py && "$4" == seal ]]; then
  test "$7" = --derived && test "$8" = "$IOS_CI_SCRATCH/DerivedData" || exit 74
  test -f "$8/Logs/archive.xcactivitylog" || exit 75
  touch "$IOS_CI_ROOT/sealed"
fi
`);
    Object.assign(env, {ARCHIVE_TEST_LEAF_COMPILER: '1', ARCHIVE_TEST_DIAGNOSTIC: authenticatedProxy,
      ARCHIVE_TEST_DIAGNOSTICS_MODE: mode, ARCHIVE_TEST_EXIT: String(exitCode), ARCHIVE_TEST_HISTORICAL_ROOT: historical});
    const ready = join(root, 'diagnostics-ready');
    if (mode === 'cancel') {
      const child = spawn('bash', [wrapper], {env, stdio: ['ignore', 'pipe', 'pipe']});
      child.stdout.resume();
      let stderr = '';
      child.stderr.on('data', data => { stderr += data; });
      t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
      await waitFor(() => existsSync(ready) || child.exitCode !== null, 'file-backed diagnostic');
      assert(existsSync(ready), stderr);
      const scratch = readFileSync(ready, 'utf8').trim();
      assert.equal(readFileSync(join(scratch, 'Aegis.xcresult/diagnostics'), 'utf8').trim(), authenticatedProxy);
      assert(child.kill('SIGTERM'));
      await waitFor(() => child.exitCode !== null, 'file-backed cancellation cleanup');
      assert.equal(child.exitCode, exitCode, stderr);
      assert.doesNotMatch(stderr, /fixture-proxy/u);
    } else {
      for (const sink of runTransportFixture(root, {env, wrapper}, exitCode)) {
        assert.doesNotMatch(sink, /fixture-proxy/u);
      }
    }
    const scratch = readFileSync(ready, 'utf8').trim();
    assert(scratch.startsWith(join(parent, '.aegis-ios-scratch-')));
    assert(!existsSync(scratch));
    assert.equal(existsSync(join(root, 'linked-verified')), mode === 'success');
    assert.equal(existsSync(join(root, 'sealed')), mode === 'success');
    for (const path of [priorBundle, priorDiagnostic]) assert.equal(readFileSync(path, 'utf8'), 'retained evidence');
  });
}

test('archive scratch cleanup refuses a substituted directory', t => {
  const parent = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-scratch-identity-'));
  t.after(() => rmSync(parent, {recursive: true, force: true}));
  execFileSync('python3', ['-I', '-B', '-c', String.raw`
from pathlib import Path
import runpy
import sys

scratch_type = runpy.run_path(sys.argv[1])["JobScratch"]
root = Path(sys.argv[2]) / "job"
root.mkdir(mode=0o700)
scratch = scratch_type(root)
old = scratch.path.rename(scratch.path.with_name("original"))
(old / "owned").touch()
scratch.path.mkdir(mode=0o700)
(scratch.path / "unrelated").touch()
assert scratch.clean() is False
assert (scratch.path / "unrelated").exists()
assert (old / "owned").exists()
`, supervisorScript, parent]);
});

for (const [phase, wrapperStatus] of [['before-spawn', 143], ['after-waitpid', 130]]) {
  test('private archive separates cancellation from compiler status at ' + phase, () => {
    const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-wrapper-status-'));
    try {
      const fixture = transportFixture(root, 65);
      fixture.env.ARCHIVE_TEST_CANCELLATION = phase;
      const spawned = phase === 'after-waitpid';
      const sinks = runTransportFixture(root, fixture, wrapperStatus);
      assert.equal(existsSync(join(root, 'compiler-started')), spawned);
      assert.equal(existsSync(join(root, 'verified')), false);
      for (const sink of sinks) {
        assert(sink.includes('archive diagnostics withheld'));
        assert(!sink.includes(authenticatedProxy));
        assert(sink.includes('wrapper cancelled with status ' + wrapperStatus));
        assert.deepEqual(sink.match(/compiler exited with status \d+/gu) ?? [],
          spawned ? ['compiler exited with status 65'] : []);
      }
    } finally {
      rmSync(root, {recursive: true, force: true});
    }
  });
}

test('a stalled Actions console cannot throttle compiler output disposal or cancellation', async () => {
  const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-stalled-console-'));
  const {env, wrapper} = prepareFixture(root, `#!/bin/bash
exec "$ARCHIVE_TEST_PYTHON" -c '
import os, pathlib, sys, time
sys.stdout.buffer.write(b"x" * (2 * 1024 * 1024) + b"end of flood\\n")
sys.stdout.buffer.flush()
pathlib.Path(os.environ["IOS_CI_ROOT"], "flood-complete").write_text(str(os.getpid()))
time.sleep(15)
'
`);
  env.ARCHIVE_TEST_LEAF_COMPILER = '1';
  const child = spawn('bash', [wrapper], {env, stdio: ['ignore', 'pipe', 'pipe']});
  const ready = join(root, 'flood-complete');
  let diagnostic = '';
  child.stderr.on('data', data => { diagnostic += data; });
  try {
    // Leave stdout unread until the supervisor has exited.
    await waitFor(() => existsSync(ready) || child.exitCode !== null, 'compiler flood');
    assert(existsSync(ready), diagnostic);
    assert.equal(child.kill('SIGTERM'), true);
    await waitFor(() => child.exitCode !== null, 'cancellation with stdout blocked');
    assert.equal(child.exitCode, 143, diagnostic);
    const retained = readFileSync(join(root, 'xcodebuild.log'), 'utf8');
    assert.doesNotMatch(retained, /end of flood/u);
    assert.match(retained, /unsigned archive compiler exited with status 143\nunsigned archive wrapper cancelled with status 143\n$/u);
    assert.equal(running(Number(readFileSync(ready, 'utf8'))), false);
  } finally {
    child.stdout.resume();
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    rmSync(root, {recursive: true, force: true});
  }
});

for (const console of ['closed readers', 'closed descriptors']) {
  test(`archive retains a natural compiler failure with ${console}`, async () => {
    const root = mkdtempSync(join(realpathSync(tmpdir()), 'ios-archive-closed-console-'));
    const {env, wrapper} = prepareFixture(root, `#!/bin/bash
printf 'compiler stdout\\n'
printf 'compiler stderr\\n' >&2
exit 65
`);
    env.ARCHIVE_TEST_LEAF_COMPILER = '1';
    const options = {env, timeout: 10000, stdio: ['ignore', 'pipe', 'pipe']};
    try {
      if (console === 'closed descriptors') {
        const child = spawnSync('bash', ['-c', 'exec bash "$1" 1>&- 2>&-', '--', wrapper], options);
        assert.ifError(child.error);
        assert.equal(child.status, 65);
      } else {
        const child = spawn('bash', [wrapper], options);
        child.stdout.destroy();
        child.stderr.destroy();
        try {
          await waitFor(() => child.exitCode !== null, 'natural failure with no console readers');
          assert.equal(child.exitCode, 65);
        } finally {
          if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
        }
      }
      const retained = readFileSync(join(root, 'xcodebuild.log'), 'utf8');
      assert.match(retained, /compiler exited with status 65/u);
      assert.doesNotMatch(retained, /compiler stdout|compiler stderr/u);
    } finally {
      rmSync(root, {recursive: true, force: true});
    }
  });
}

const stageProcess = String.raw`exec "$ARCHIVE_TEST_PYTHON" -c '
import json, os, signal, time
from pathlib import Path

root = Path(os.environ["IOS_CI_ROOT"])
def mark(role):
    ready = root / (role + ".ready")
    ready.write_text(json.dumps([os.getpid(), os.getppid(), os.getpgrp(), os.getsid(0)]))
    ready.rename(root / role)

if os.fork() == 0:
    os.setpgid(0, 0)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    mark("stage-helper")
else:
    mark("stage-worker")
time.sleep(15)
'`;

for (const [phase, selector] of [
  ['pre-compile verification', '[[ "$2" == */ios_embedded_core.py ]]'],
  ['verification', '[[ "$1" == */verify-ios-archive.py ]]'],
  ['sealing', '[[ "$3" == */ios-ci-storage.py && "$4" == seal ]]'],
]) {
  test(`cancel during ${phase} drains the stage session and its separate group`, async () => {
    const root = mkdtempSync(join(realpathSync(tmpdir()), `ios-archive-${phase}-`));
    const {env, wrapper} = prepareFixture(root, '#!/bin/bash\necho compiler complete\n',
      `if ${selector}; then\nprintf 'synthetic stage diagnostic: %s\\n' "$ARCHIVE_TEST_DIAGNOSTIC" >&2\n${stageProcess}\nfi`);
    env.ARCHIVE_TEST_DIAGNOSTIC = authenticatedProxy;
    const child = spawn('bash', [wrapper], {env, stdio: ['ignore', 'pipe', 'pipe']});
    let diagnostic = '';
    child.stderr.on('data', data => { diagnostic += data; });
    try {
      const markers = ['stage-worker', 'stage-helper'].map(role => join(root, role));
      await waitFor(() => markers.every(existsSync) || child.exitCode !== null, `${phase} process markers`);
      assert(markers.every(existsSync), diagnostic);
      const [[worker, parent, group, session], [helper, helperParent, helperGroup, helperSession]] =
        markers.map(path => JSON.parse(readFileSync(path, 'utf8')));
      const stage = phase === 'verification' ? parent : worker;
      const stageParent = execFileSync('/bin/ps', ['-p', String(stage), '-o', 'ppid='], {encoding: 'utf8'});
      assert.equal(Number(stageParent.trim()), child.pid, 'the stage must be the entry supervisor’s direct child');
      assert.deepEqual([group, session, helperParent, helperGroup, helperSession], [stage, stage, worker, helper, stage]);
      assert.equal(child.kill('SIGTERM'), true);
      await waitFor(() => child.exitCode !== null, `${phase} cleanup`);
      assert.equal(child.exitCode, 143, diagnostic);
      for (const pid of new Set([stage, worker, helper])) assert.equal(running(pid), false, `stage process ${pid} survived`);
      const retained = readFileSync(join(root, 'xcodebuild.log'), 'utf8');
      if (phase === 'pre-compile verification') {
        assert.match(retained, /pre-compile EmbeddedCore verification exited with status 143/u);
        assert.doesNotMatch(retained, /compiler exited/u);
        assert.match(retained, /wrapper cancelled with status 143/u);
      } else {
        assert.match(retained, /compiler exited with status 0/u);
        assert.match(diagnostic, /wrapper cancelled with status 143/u);
      }
      assert.doesNotMatch(retained + diagnostic, /compiler complete|synthetic stage diagnostic|fixture-proxy/u);
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
      rmSync(root, {recursive: true, force: true});
    }
  });
}

test('cleanup escalates the reserved group during census failure and requires helper confirmation', () => {
  execFileSync('python3', ['-B', '-c', String.raw`
import importlib.util, os, signal, subprocess, sys
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("supervisor", sys.argv[1])
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

for failure in (None, "census", "identity"):
    now = 0
    calls = []
    signaled = False

    def sleep(delta):
        global now
        now += delta

    def census(session, timeout):
        calls.append(("census", now))
        if now < supervisor.TERM_GRACE or failure == "census":
            sleep(timeout)
            raise subprocess.TimeoutExpired("ps fixture", timeout)
        return [] if signaled else [202]

    def signal_worker(pid, session, signum):
        global signaled
        assert (pid, session, signum) == (202, 101, signal.SIGKILL)
        calls.append(("helper", now))
        if failure == "identity":
            raise PermissionError("fixture denied identity")
        signaled = True

    waitpid = Mock(return_value=(101, 0))
    with patch.multiple(supervisor, session_workers=census, in_session=lambda *_: True), \
         patch.object(supervisor.time, "monotonic", lambda: now), patch.object(supervisor.time, "sleep", sleep), \
         patch.object(os, "killpg", lambda pid, signum: calls.append((signum, now))), \
         patch.object(os, "getpgid", lambda pid: pid), patch.object(os, "waitpid", waitpid):
        try:
            assert supervisor.stop_and_reap(101, signal_worker) == 0
        except OSError as error:
            assert failure and "could not confirm" in str(error), error
            if failure == "identity":
                assert "fixture denied identity" in str(error)
        else:
            assert failure is None
    assert calls[:3] == [(signal.SIGTERM, 0), ("census", 0), (signal.SIGKILL, supervisor.TERM_GRACE)], calls[:3]
    if failure is None:
        assert signaled and sum(event == "census" for event, _ in calls) == 4, calls
    waitpid.assert_called_once_with(101, os.WNOHANG)
`, supervisorScript], {encoding: 'utf8'});
});

test('workflow keeps unsigned archive compilation behind the cancel-safe wrapper', () => {
  const workflow = readFileSync('.github/workflows/ios-release-validation.yml', 'utf8');
  assert.match(workflow, /exec bash "\$IOS_CI_SOURCE\/scripts\/ci\/run-ios-unsigned-archive\.sh"/u);
  assert.match(workflow, /steps\.storage\.outputs\.source/u);
  assert.doesNotMatch(workflow, /xcodebuild .*\| tee/u);
  const probe = spawnSync('bash', ['-n', archiveScript], {encoding: 'utf8'});
  assert.equal(probe.status, 0, probe.stderr);
});
