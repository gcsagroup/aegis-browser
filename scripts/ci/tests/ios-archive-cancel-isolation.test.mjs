import assert from 'node:assert/strict';
import {execFileSync, spawn, spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {setTimeout as delay} from 'node:timers/promises';

const archiveScript = 'scripts/ci/run-ios-unsigned-archive.sh';
const supervisorScript = 'scripts/ci/ios-archive-supervisor.py';

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
        os.write(2, b"separate-group grandchild holds compiler output\n")
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
  for (const path of [archiveScript, supervisorScript, 'apps/browser/scripts/common.sh']) {
    mkdirSync(join(source, path, '..'), {recursive: true});
    copyFileSync(path, join(source, path));
  }
  mkdirSync(join(source, 'apps/ios/Aegis.xcodeproj'), {recursive: true});
  writeFileSync(join(source, 'apps/ios/Aegis.xcodeproj/project.pbxproj'), '// fixture\n');
  writeFileSync(join(bin, 'python3'), `#!/bin/bash
case "$3" in */ios-archive-supervisor.py) exec "$ARCHIVE_TEST_PYTHON" "$@" ;; esac
if [[ "$2" == */ios_embedded_core.py ]]; then printf 'embedded core verified\\n' || exit 98; fi
${verifierScript}
exit 0
`, {mode: 0o755});
  writeFileSync(join(bin, 'scutil'), '#!/bin/bash\nexit 0\n', {mode: 0o755});
  writeFileSync(join(bin, 'xcodebuild'), compilerScript, {mode: 0o755});
  const env = {...process.env, PATH: `${bin}:${process.env.PATH}`, IOS_CI_ROOT: root, IOS_CI_SOURCE: source,
    RUNNER_TRACKING_ID: 'archive-fixture', ARCHIVE_TEST_PYTHON: python};
  return {source, python, env, wrapper: join(source, archiveScript)};
}

for (const [signal, exitCode] of [['SIGTERM', 143], ['SIGINT', 130], [null, 65]]) {
  test(`archive ${signal ?? 'compiler failure'} stops owned descendants before wrapper exit`, async () => {
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
      env: {...env, ARCHIVE_TEST_FAIL: signal ? '0' : '1'},
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
    const marker = 'separate-group grandchild holds compiler output';

    try {
      await waitFor(() => nextCheckoutStarted || (ready() && stdout.includes(marker)), 'process markers and live diagnostic');
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
        assert(stdout.includes(marker), diagnostic);
        assert.equal(child.kill(signal), true);
      }
      await waitFor(() => nextCheckoutStarted, 'wrapper exit and next-checkout probe');
      assert.equal(child.exitCode, exitCode, diagnostic);
      assert(readFileSync(log, 'utf8').includes(marker));
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

test('a stalled Actions console cannot throttle the compiler log or cancellation', async () => {
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
    assert.match(readFileSync(join(root, 'xcodebuild.log'), 'utf8'), /end of flood\n$/u);
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
      assert.equal(readFileSync(join(root, 'xcodebuild.log'), 'utf8'), 'compiler stdout\ncompiler stderr\n');
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
  ['verification', '[[ "$1" == */verify-ios-archive.py ]]'],
  ['sealing', '[[ "$3" == */ios-ci-storage.py && "$4" == seal ]]'],
]) {
  test(`cancel during ${phase} drains the stage session and its separate group`, async () => {
    const root = mkdtempSync(join(realpathSync(tmpdir()), `ios-archive-${phase}-`));
    const {env, wrapper} = prepareFixture(root, '#!/bin/bash\necho compiler complete\n',
      `if ${selector}; then\n${stageProcess}\nfi`);
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
      assert.equal(readFileSync(join(root, 'xcodebuild.log'), 'utf8'), 'compiler complete\n');
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
