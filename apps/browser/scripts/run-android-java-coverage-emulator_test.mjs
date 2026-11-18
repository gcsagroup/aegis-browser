import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {test} from 'node:test';

const checkout = path.resolve(import.meta.dirname, '../../..');

function readEmulatorPid(file) {
  if (!fs.existsSync(file)) return null;
  const record = fs.readFileSync(file, 'utf8');
  const match = /^([1-9]\d{0,9})\n$/u.exec(record);
  if (!match || match[0] !== record) return null;
  const pid = Number(match[1]);
  return pid > 1 && pid <= 0x7fffffff && pid !== process.pid ? pid : null;
}

function runCoverage(t, mode) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-emulator-test-'));
  const sdk = path.join(root, 'sdk');
  const bin = path.join(root, 'bin');
  const record = path.join(root, 'operations.log');
  const emulatorPid = path.join(root, 'emulator.pid');
  const bashEnv = path.join(root, 'bash-env');
  // Advance the launcher's clock without waiting for the real startup budget.
  fs.writeFileSync(bashEnv, String.raw`
timeout() {
  if [[ $3 == */avdmanager ]]; then
    case "$EMULATOR_MODE" in
      early-killed) return 137 ;;
      deadline-killed) SECONDS=$boot_deadline; return 137 ;;
      screen-stalled)
        command timeout "$@" || return $?
        SECONDS=$((boot_deadline - 30))
        return 0
        ;;
    esac
  fi
  command timeout "$@"
}
`);

  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  fs.writeFileSync(record, '');
  const script = (file, content) => {
    fs.mkdirSync(path.dirname(file), {recursive: true});
    fs.writeFileSync(file, '#!/usr/bin/env bash\nset -eu\n' + content, {mode: 0o700});
  };
  script(path.join(sdk, 'platform-tools/adb'), String.raw`
printf 'adb %s\n' "$*" >> "$RECORD"
if [[ $1 == devices ]]; then
  printf 'List of devices attached\n'
  if [[ $EMULATOR_MODE == occupied ]]; then printf 'emulator-5554\toffline\n';
  elif [[ -f $AVD_NAME ]]; then printf 'emulator-5554 device transport_id:17\n'; fi
  exit 0
fi
selector=$1
[[ ( $1 == -s && $2 == emulator-5554 ) || ( $1 == -t && $2 == 17 ) ]]
shift 2
if [[ $selector == -t && -f $REPLACED ]]; then echo 'verified transport disconnected' >&2; exit 1; fi
case "$*" in
  'wait-for-device') ;;
  'emu avd name'|'shell getprop ro.boot.qemu.avd_name')
    if [[ $EMULATOR_MODE == foreign ]]; then printf 'foreign-avd\n'; else cat "$AVD_NAME"; fi ;;
  'shell getprop ro.kernel.qemu') printf '1\n' ;;
  'shell getprop sys.boot_completed')
    case "$EMULATOR_MODE" in
      emulator-killed|emulator-exited) printf '0\n' ;;
      *) printf '1\n' ;;
    esac ;;
  'shell am get-current-user')
    if [[ $EMULATOR_MODE == replaced ]]; then touch "$REPLACED"; fi
    printf '0\n' ;;
  'shell dumpsys window policy')
    if [[ $EMULATOR_MODE == screen-stalled ]]; then exec /bin/sleep 120; fi
    printf 'KeyguardServiceDelegate\n showing=false\n screenState=2\n' ;;
  'shell svc power stayon true'|'shell wm dismiss-keyguard'|'shell settings put global '*) ;;
  'shell input '*) echo 'boot-time synthetic input would target the launcher' >&2; exit 23 ;;
  *) echo "unexpected adb command: $*" >&2; exit 24 ;;
esac
`);
  script(path.join(sdk, 'cmdline-tools/latest/bin/avdmanager'), String.raw`
printf 'avdmanager %s\n' "$*" >> "$RECORD"
if [[ $EMULATOR_MODE == stalled ]]; then exec /bin/sleep 120; fi
while [[ $# -gt 0 ]]; do
  if [[ $1 == -n ]]; then printf '%s\n' "$2" > "$AVD_NAME"; break; fi
  shift
done
`);
  script(path.join(sdk, 'emulator/emulator'), String.raw`
if [[ $EMULATOR_MODE == stubborn ]]; then trap '' TERM; fi
printf '%s\n' "$$" > "$EMULATOR_PID"
printf 'emulator %s\n' "$*" >> "$RECORD"
case "$EMULATOR_MODE" in
  emulator-killed) kill -KILL "$$" ;;
  emulator-exited) exit 0 ;;
esac
# Exit when the test removes its temporary files, with a bounded fallback.
expires=$((SECONDS + 120))
while [[ -f "$EMULATOR_PID" ]] && (( SECONDS < expires )); do
  /bin/sleep 0.25
done
`);
  script(path.join(bin, 'node'), String.raw`
if [[ "$*" == *'android-agent-ui.mjs self-test'* ]]; then
  printf 'self-test %s\n' "$*" >> "$RECORD"
  if [[ $EMULATOR_MODE == fixture-fails ]]; then touch "$REPLACED"; exit 1; fi
  exit 0
fi
exec "$REAL_NODE" "$@"
`);
  // Preserve retry and cleanup branches without making fixture runs wait real seconds.
  script(path.join(bin, 'sleep'), 'exec /bin/sleep 0.05\n');
  script(path.join(bin, 'timeout'), String.raw`
printf 'timeout %s\n' "$*" >> "$RECORD"
if [[ $1 == --kill-after=2s ]]; then
  [[ $2 =~ ^[1-9][0-9]*s$ ]]
  shift 2
  if [[ ( $EMULATOR_MODE == stalled && $1 == */avdmanager ) ||
        ( $EMULATOR_MODE == screen-stalled && "$*" == *'shell dumpsys window policy' ) ]]; then
    exec "$REAL_NODE" -e 'const [, tool, ...args] = process.argv;
      const result = require("node:child_process").spawnSync(tool, args, {timeout: 250, killSignal: "SIGKILL"});
      process.exit(result.error?.code === "ETIMEDOUT" ? 124 : 1);' "$@"
  fi
else
  shift
fi
exec "$@"
`);
  const result = spawnSync('bash', ['apps/browser/scripts/run-android-java-coverage-emulator.sh'], {
    cwd: checkout,
    env: {...process.env, PATH: bin + path.delimiter + process.env.PATH,
      REAL_NODE: process.execPath, ANDROID_SDK_ROOT: sdk, RUNNER_TEMP: root,
      EVIDENCE_DIR: path.join(root, 'evidence'), AVD_NAME: path.join(root, 'avd-name'),
      RECORD: record, EMULATOR_MODE: mode, REPLACED: path.join(root, 'transport-replaced'),
      EMULATOR_PID: emulatorPid, BASH_ENV: bashEnv},
    encoding: 'utf8',
    timeout: 45000,
  });
  assert.ifError(result.error);
  if (fs.existsSync(emulatorPid)) {
    const pid = readEmulatorPid(emulatorPid);
    assert.notEqual(pid, null, 'the fixture emulator must record a valid PID');
    assert.throws(() => process.kill(pid, 0), {code: 'ESRCH'}, 'the fixture emulator must be reaped');
    fs.unlinkSync(emulatorPid);
  }
  return {status: result.status, stderr: result.stderr, operations: fs.readFileSync(record, 'utf8')};
}

test('cold-boot coverage runs on the owned API 36 transport without injecting key events', t => {
  const result = runCoverage(t, 'ready');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.operations, /avdmanager create avd .*system-images;android-36;default;x86_64/);
  assert.match(result.operations, /emulator -port 5554 -avd aegis-java-coverage\./);
  assert.match(result.operations, /adb -t 17 shell getprop ro\.boot\.qemu\.avd_name\n[\s\S]*adb -t 17 shell wm dismiss-keyguard\n/);
  assert.match(result.operations, /self-test .* --serial emulator-5554 .*--transport-id 17/);
  assert.doesNotMatch(result.operations, /adb -s |shell input /);
});

test('foreign or occupied coverage serial fails before device changes or fixtures', t => {
  for (const mode of ['foreign', 'occupied']) {
    const result = runCoverage(t, mode);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /not the newly created AVD|already present/);
    assert.doesNotMatch(result.operations, /shell (?:svc|wm|settings|input) |self-test /);
    if (mode === 'occupied') assert.doesNotMatch(result.operations, /avdmanager create avd/);
  }
});

test('a serial rebound after admission does not receive device changes or fixtures', t => {
  const result = runCoverage(t, 'replaced');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /verified transport disconnected/);
  assert.match(result.operations, /adb -t 17 shell svc power stayon true/);
  assert.doesNotMatch(result.operations, /adb -s |self-test /);
});

test('the startup deadline bounds stalled AVD creation', t => {
  const result = runCoverage(t, 'stalled');
  assert.equal(result.status, 124, result.stderr);
  assert.match(result.stderr, /startup deadline/);
  assert.match(result.operations, /timeout --kill-after=2s \d+s .*\/avdmanager create avd/);
  assert.doesNotMatch(result.operations, /emulator -port|self-test /);
});

test('cleanup reaps a child that ignores SIGTERM and preserves the fixture result', t => {
  const result = runCoverage(t, 'stubborn');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.operations, /self-test /);
});


test('a stalled screen probe receives only the remaining startup budget without another attempt', t => {
  const result = runCoverage(t, 'screen-stalled');
  assert.equal(result.status, 124, result.stderr);
  assert.match(result.stderr, /startup deadline/);
  assert.equal((result.operations.match(/^adb -t 17 shell dumpsys window policy$/gm) ?? []).length, 1);
  const probe = result.operations.match(/^timeout --kill-after=2s ([1-9]\d*)s .*\/adb -t 17 shell dumpsys window policy$/m);
  assert.ok(probe && Number(probe[1]) <= 30, result.operations);
  assert.doesNotMatch(result.operations, /self-test /);
});

test('helper failure diagnostics stay on the admitted transport after disconnect', t => {
  const result = runCoverage(t, 'fixture-fails');
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.operations, /self-test .* --transport-id 17/);
  assert.match(result.operations, /adb -t 17 shell dumpsys window displays/);
  assert.match(result.operations, /adb -t 17 shell dumpsys activity lastanr/);
  assert.match(result.operations, /adb -t 17 logcat .*am_anr am_crash/);
  assert.match(result.operations, /adb -t 17 logcat .*AndroidRuntime:E/);
  assert.doesNotMatch(result.operations, /adb -s /);
});


test('early SIGKILL is distinct from an emulator bootstrap timeout', t => {
  const result = runCoverage(t, 'early-killed');
  assert.equal(result.status, 137, result.stderr);
  assert.doesNotMatch(result.stderr, /startup deadline/);
  assert.doesNotMatch(result.operations, /emulator -port|self-test /);
});

test('SIGKILL at the shared startup deadline is reported as timeout', t => {
  const result = runCoverage(t, 'deadline-killed');
  assert.equal(result.status, 124, result.stderr);
  assert.match(result.stderr, /startup deadline/);
  assert.doesNotMatch(result.operations, /emulator -port|self-test /);
});

test('the emulator child keeps its signal status and an early clean exit fails', t => {
  for (const [mode, status] of [['emulator-killed', 137], ['emulator-exited', 1]]) {
    const result = runCoverage(t, mode);
    assert.equal(result.status, status, result.stderr);
    assert.match(result.stderr, /emulator exited before completing boot/);
    assert.doesNotMatch(result.operations, /self-test /);
  }
});

test('only complete and valid PID records are used to check emulator liveness', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-emulator-pid-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const file = path.join(root, 'emulator.pid');
  assert.equal(readEmulatorPid(file), null);
  const otherPid = process.pid === 1234 ? 1235 : 1234;
  for (const value of ['', String(otherPid), otherPid + '\n\n', ' 23\n', '23\r\n',
    '0\n', '1\n', '-1\n', '1e2\n', '21x\n', '2147483648\n', process.pid + '\n']) {
    fs.writeFileSync(file, value);
    assert.equal(readEmulatorPid(file), null, JSON.stringify(value));
  }
  fs.writeFileSync(file, otherPid + '\n');
  assert.equal(readEmulatorPid(file), otherPid);
});
