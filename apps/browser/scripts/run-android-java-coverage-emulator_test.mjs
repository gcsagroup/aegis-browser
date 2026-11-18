import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {test} from 'node:test';

const checkout = path.resolve(import.meta.dirname, '../../..');

function runCoverage(t, mode) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-emulator-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const sdk = path.join(root, 'sdk');
  const bin = path.join(root, 'bin');
  const record = path.join(root, 'operations.log');
  fs.writeFileSync(record, '');
  const script = (file, content) => {
    fs.mkdirSync(path.dirname(file), {recursive: true});
    fs.writeFileSync(file, '#!/usr/bin/env bash\nset -eu\n' + content, {mode: 0o700});
  };
  script(path.join(sdk, 'platform-tools/adb'), String.raw`
printf 'adb %s\n' "$*" >> "$RECORD"
if [[ $1 == devices ]]; then
  printf 'List of devices attached\n'
  if [[ $EMULATOR_MODE == occupied ]]; then printf 'emulator-5554\toffline\n'; fi
  exit 0
fi
[[ $1 == -s && $2 == emulator-5554 ]]
shift 2
case "$*" in
  'wait-for-device') ;;
  'emu avd name')
    if [[ $EMULATOR_MODE == foreign ]]; then printf 'foreign-avd\nOK\n'; else cat "$AVD_NAME"; fi ;;
  'shell getprop ro.kernel.qemu'|'shell getprop sys.boot_completed') printf '1\n' ;;
  'shell am get-current-user') printf '0\n' ;;
  'shell dumpsys window policy') printf 'KeyguardServiceDelegate\n showing=false\n screenState=2\n' ;;
  'shell svc power stayon true'|'shell wm dismiss-keyguard'|'shell settings put global '*) ;;
  'shell input '*) echo 'boot-time synthetic input would target the launcher' >&2; exit 23 ;;
  *) echo "unexpected adb command: $*" >&2; exit 24 ;;
esac
`);
  script(path.join(sdk, 'cmdline-tools/latest/bin/avdmanager'), String.raw`
printf 'avdmanager %s\n' "$*" >> "$RECORD"
while [[ $# -gt 0 ]]; do
  if [[ $1 == -n ]]; then printf '%s\nOK\n' "$2" > "$AVD_NAME"; break; fi
  shift
done
`);
  script(path.join(sdk, 'emulator/emulator'), String.raw`
printf 'emulator %s\n' "$*" >> "$RECORD"
exec sleep 30
`);
  script(path.join(bin, 'node'), String.raw`
if [[ "$*" == *'android-agent-ui.mjs self-test'* ]]; then
  printf 'self-test %s\n' "$*" >> "$RECORD"
  exit 0
fi
exec "$REAL_NODE" "$@"
`);
  script(path.join(bin, 'timeout'), 'shift\nexec "$@"\n');
  const result = spawnSync('bash', ['apps/browser/scripts/run-android-java-coverage-emulator.sh'], {
    cwd: checkout,
    env: {...process.env, PATH: bin + path.delimiter + process.env.PATH,
      REAL_NODE: process.execPath, ANDROID_SDK_ROOT: sdk, RUNNER_TEMP: root,
      EVIDENCE_DIR: path.join(root, 'evidence'), AVD_NAME: path.join(root, 'avd-name'),
      RECORD: record, EMULATOR_MODE: mode},
    encoding: 'utf8',
    timeout: 15000,
  });
  assert.ifError(result.error);
  return {status: result.status, stderr: result.stderr, operations: fs.readFileSync(record, 'utf8')};
}

test('cold-boot coverage runs on the owned API 36 emulator without injecting key events', t => {
  const result = runCoverage(t, 'ready');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.operations, /avdmanager create avd .*system-images;android-36;default;x86_64/);
  assert.match(result.operations, /emulator -port 5554 -avd aegis-java-coverage\./);
  assert.match(result.operations, /emu avd name\n[\s\S]*shell getprop sys\.boot_completed\n[\s\S]*shell wm dismiss-keyguard\n[\s\S]*self-test .* --serial emulator-5554/);
  assert.doesNotMatch(result.operations, /shell input /);
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
