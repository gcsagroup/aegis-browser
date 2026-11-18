import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {test} from 'node:test';

const checkout = path.resolve(import.meta.dirname, '../../..');

function runCoverage(t, mode) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-emulator-test-'));
  const sdk = path.join(root, 'sdk');
  const bin = path.join(root, 'bin');
  const record = path.join(root, 'operations.log');
  const emulatorPid = path.join(root, 'emulator.pid');
  const bashEnv = path.join(root, 'bash-env');
  // Simulate GNU timeout's ambiguous 137 on either side of the shared deadline.
  const timeoutOverride = String.raw`
timeout() {
  if [[ $3 == */avdmanager ]]; then
    case "$EMULATOR_MODE" in
      early-killed) return 137 ;;
      deadline-killed) SECONDS=$boot_deadline; return 137 ;;
    esac
  fi
  command timeout "$@"
}
`;
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Fixed bootstrap file in this test's private mkdtemp directory.
  fs.writeFileSync(bashEnv, timeoutOverride); // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- The operation log belongs to the current fixture directory.
  fs.writeFileSync(record, ''); // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  const script = (file, content) => {
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- All callers supply fixed mock SDK or bin paths under this private directory.
    fs.mkdirSync(path.dirname(file), {recursive: true}); // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- Only the static scripts below are written to the fixture SDK and bin directories.
    fs.writeFileSync(file, '#!/usr/bin/env bash\nset -eu\n' + content, {mode: 0o700}); // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
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
  'shell getprop ro.kernel.qemu'|'shell getprop sys.boot_completed') printf '1\n' ;;
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
# Stop when the fixture directory disappears, even if the script under test failed to reap us.
while [[ -d "$RUNNER_TEMP" ]] && (( SECONDS < 120 )); do /bin/sleep 0.1; done
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
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- The mock writes this PID to a fixed file under the private fixture directory.
  const pid = fs.existsSync(emulatorPid) ? Number(fs.readFileSync(emulatorPid, 'utf8')) : null; // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
  if (pid !== null) {
    assert.throws(() => process.kill(pid, 0), {code: 'ESRCH'}, 'the fixture emulator must be reaped');
  }
  // eslint-disable-next-line security/detect-non-literal-fs-filename -- Read the fixed log that this fixture created.
  return {status: result.status, stderr: result.stderr, operations: fs.readFileSync(record, 'utf8')}; // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
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


test('a stalled screen probe preserves the startup timeout without another attempt', t => {
  const result = runCoverage(t, 'screen-stalled');
  assert.equal(result.status, 124, result.stderr);
  assert.match(result.stderr, /startup deadline/);
  assert.equal((result.operations.match(/^adb -t 17 shell dumpsys window policy$/gm) ?? []).length, 1);
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
