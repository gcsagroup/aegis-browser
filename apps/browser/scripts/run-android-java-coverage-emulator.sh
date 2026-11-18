#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_SDK_ROOT:?ANDROID_SDK_ROOT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${EVIDENCE_DIR:?EVIDENCE_DIR is required}"

if [[ "$EVIDENCE_DIR" != /* || -e "$EVIDENCE_DIR/coverage" ||
  -e "$EVIDENCE_DIR/self-test.json" || -e "$EVIDENCE_DIR/emulator.log" ]]; then
  echo "coverage evidence paths must be new and absolute" >&2
  exit 1
fi

adb="$ANDROID_SDK_ROOT/platform-tools/adb"
avdmanager="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/avdmanager"
emulator="$ANDROID_SDK_ROOT/emulator/emulator"
serial="emulator-5554"
devices=$("$adb" devices)
if awk -v serial="$serial" '$1 == serial { found = 1 } END { exit !found }' <<< "$devices"; then
  echo "coverage emulator serial is already present: $serial" >&2
  exit 1
fi

mkdir -p "$EVIDENCE_DIR"
avd_root=$(mktemp -d "$RUNNER_TEMP/aegis-java-coverage.XXXXXXXX")
avd_name=$(basename "$avd_root")
export ANDROID_AVD_HOME="$avd_root/avd"
mkdir "$ANDROID_AVD_HOME"
"$avdmanager" create avd -n "$avd_name" -k 'system-images;android-36;default;x86_64' --device pixel_6 <<< no
"$emulator" -port 5554 -avd "$avd_name" -cores 2 -memory 4096 -accel on \
  -no-window -gpu swiftshader_indirect -no-snapshot -noaudio -no-boot-anim -no-metrics -camera-back none \
  > "$EVIDENCE_DIR/emulator.log" 2>&1 &
emulator_pid=$!
trap 'kill "$emulator_pid" 2>/dev/null || true; wait "$emulator_pid" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

emulator_booted=0
boot_deadline=$((SECONDS + 600))
while (( SECONDS < boot_deadline )); do
  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    echo 'coverage emulator exited before completing boot' >&2
    exit 1
  fi
  if identity=$(timeout 5 "$adb" -s "$serial" emu avd name 2>/dev/null | tr -d '\r'); then
    if [[ "${identity%%$'\n'*}" != "$avd_name" ]]; then
      echo "coverage emulator is not the newly created AVD: $serial" >&2
      exit 1
    fi
    if boot_completed=$(timeout 5 "$adb" -s "$serial" shell getprop sys.boot_completed | tr -d '\r') &&
      [[ "$boot_completed" == 1 ]]; then
      emulator_booted=1
      break
    fi
  fi
  sleep 2
done
if (( emulator_booted != 1 )); then
  echo 'coverage emulator did not complete boot before its deadline' >&2
  exit 1
fi

if [[ "$("$adb" -s "$serial" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]]; then
  echo "coverage self-test requires the dedicated emulator" >&2
  exit 1
fi
if [[ "$("$adb" -s "$serial" shell am get-current-user | tr -d '\r')" != "0" ]]; then
  echo "coverage self-test requires Android user 0" >&2
  exit 1
fi

# A synthetic MENU key at boot can time out in Launcher3 before it has a
# focused window. Use power and keyguard services on the verified AVD.
"$adb" -s "$serial" shell svc power stayon true
"$adb" -s "$serial" shell wm dismiss-keyguard
for setting in window_animation_scale transition_animation_scale animator_duration_scale; do
  "$adb" -s "$serial" shell settings put global "$setting" 0.0
done

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
