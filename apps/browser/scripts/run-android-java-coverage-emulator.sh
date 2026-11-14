#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_SDK_ROOT:?ANDROID_SDK_ROOT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${EVIDENCE_DIR:?EVIDENCE_DIR is required}"

if [[ "$EVIDENCE_DIR" != /* || -e "$EVIDENCE_DIR/coverage" || -e "$EVIDENCE_DIR/self-test.json" ]]; then
  echo "coverage evidence paths must be new and absolute" >&2
  exit 1
fi

adb="$ANDROID_SDK_ROOT/platform-tools/adb"
serial="emulator-5554"
"$adb" -s "$serial" wait-for-device

if [[ "$("$adb" -s "$serial" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]]; then
  echo "coverage self-test requires the dedicated emulator" >&2
  exit 1
fi
if [[ "$("$adb" -s "$serial" shell am get-current-user | tr -d '\r')" != "0" ]]; then
  echo "coverage self-test requires Android user 0" >&2
  exit 1
fi

"$adb" -s "$serial" shell input keyevent KEYCODE_WAKEUP
"$adb" -s "$serial" shell wm dismiss-keyguard
"$adb" -s "$serial" shell input keyevent 82

# sys.boot_completed can precede the final keyguard/screen transition. Wait for the
# same fail-closed API 36 state that android-agent-ui.mjs checks again before install.
emulator_ready=0
for _ in {1..15}; do
  if "$adb" -s "$serial" shell dumpsys window policy | node --input-type=module -e '
    import {parseKeyguard} from "./apps/browser/scripts/verify-android-agent-target.mjs";
    let dump = "";
    process.stdin.setEncoding("utf8");
    for await (const chunk of process.stdin) dump += chunk;
    const state = parseKeyguard(dump);
    process.exit(state.known && state.unlocked && state.screenOn ? 0 : 1);
  '; then
    emulator_ready=1
    break
  fi
  sleep 1
done
if (( emulator_ready != 1 )); then
  echo 'dedicated emulator did not reach the verified unlocked screen state' >&2
  exit 1
fi

if ! node apps/browser/scripts/android-agent-ui.mjs self-test \
  --adb "$adb" \
  --serial "$serial" \
  --driver-build "$RUNNER_TEMP/aegis-driver-coverage" \
  --coverage-output "$EVIDENCE_DIR/coverage" \
  --output "$EVIDENCE_DIR/self-test.json"; then
  # Only this verified, disposable emulator is inspected. Keep system focus/ANR
  # metadata, never screenshots, UI hierarchies, or an attempt to dismiss dialogs.
  node --input-type=module - "$adb" > "$EVIDENCE_DIR/emulator-failure-metadata.txt" <<'NODE' || true
    import {execFileSync} from 'node:child_process';
    const adb = process.argv[2];
    const probes = [
      ['window-focus', ['shell', 'dumpsys', 'window', 'displays'], /^\s*(mCurrentFocus|mFocusedApp)=/u],
      ['last-anr', ['shell', 'dumpsys', 'activity', 'lastanr'], /^\s*(ANR in |PID:|Reason:|ErrorId:|Frozen:|No ANR)/u],
      ['system-errors', ['logcat', '-d', '-b', 'events', '-s', 'am_anr', 'am_crash'], /am_(anr|crash)/u],
    ];
    for (const [label, args, selected] of probes) {
      console.log('[' + label + ']');
      try {
        const output = execFileSync(adb, ['-s', 'emulator-5554', ...args], {
          encoding: 'utf8', timeout: 10000, killSignal: 'SIGKILL', maxBuffer: 2 * 1024 * 1024,
          stdio: ['ignore', 'pipe', 'pipe'],
        });
        const lines = output.split(/\r?\n/u).filter(line => selected.test(line));
        console.log(lines.slice(-12).map(line => line.slice(0, 512)).join('\n') || 'no matching metadata');
      } catch (error) {
        console.log('metadata unavailable: ' + (error.code ?? 'command failed'));
      }
    }
NODE
  cat "$EVIDENCE_DIR/emulator-failure-metadata.txt" >&2 || true
  # This emulator contains only the dedicated fixture helper; retain its crash class and stack for CI diagnosis.
  "$adb" -s "$serial" logcat -d -v brief 'AndroidRuntime:E' '*:S' | tail -n 120 >&2 || true
  exit 1
fi
