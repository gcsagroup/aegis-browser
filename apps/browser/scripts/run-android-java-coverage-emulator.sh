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
boot_deadline=$((SECONDS + 600))

during_startup() {
  local remaining=$((boot_deadline - SECONDS))
  if (( remaining <= 0 )); then
    echo 'coverage emulator startup deadline exceeded' >&2
    return 124
  fi
  local status=0
  timeout --kill-after=2s "${remaining}s" "$@" || status=$?
  if (( status == 124 || (status == 137 && SECONDS >= boot_deadline) )); then
    printf 'coverage emulator startup deadline exceeded during %s\n' "${1##*/}" >&2
    return 124
  fi
  return "$status"
}

devices=$(during_startup "$adb" devices -l)
if awk -v serial="$serial" '$1 == serial { found = 1 } END { exit !found }' <<< "$devices"; then
  echo "coverage emulator serial is already present: $serial" >&2
  exit 1
fi

mkdir -p "$EVIDENCE_DIR"
avd_root=$(mktemp -d "$RUNNER_TEMP/aegis-java-coverage.XXXXXXXX")
avd_name=$(basename "$avd_root")
export ANDROID_AVD_HOME="$avd_root/avd"
mkdir "$ANDROID_AVD_HOME"
during_startup "$avdmanager" create avd -n "$avd_name" -k 'system-images;android-36;default;x86_64' --device pixel_6 <<< no
"$emulator" -port 5554 -avd "$avd_name" -cores 2 -memory 4096 -accel on \
  -no-window -gpu swiftshader_indirect -no-snapshot -noaudio -no-boot-anim -no-metrics -camera-back none \
  > "$EVIDENCE_DIR/emulator.log" 2>&1 &
emulator_pid=$!

cleanup() {
  local status=$?
  trap - EXIT
  # The emulator is this shell's only background job.
  if kill -TERM %+ 2>/dev/null; then
    for _ in {1..5}; do
      if ! kill -0 %+ 2>/dev/null; then break; fi
      sleep 1
    done
    kill -KILL %+ 2>/dev/null || true
  fi
  wait "$emulator_pid" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

emulator_booted=0
while (( SECONDS < boot_deadline )); do
  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    echo 'coverage emulator exited before completing boot' >&2
    exit 1
  fi
  if devices=$(during_startup "$adb" devices -l) &&
    transport=$(awk -v serial="$serial" '
    $1 == serial && $2 == "device" {
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^transport_id:[1-9][0-9]*$/) { id = substr($i, 14); found++ }
      }
    }
    END { if (found != 1) exit 1; print id }
  ' <<< "$devices") && boot_completed=$(during_startup "$adb" -t "$transport" shell getprop sys.boot_completed | tr -d '\r') &&
    [[ "$boot_completed" == 1 ]]; then
    emulator_booted=1
    break
  else
    probe_rc=$?
    if (( probe_rc == 124 || probe_rc == 137 )); then exit "$probe_rc"; fi
  fi
  during_startup sleep 2
done
if (( emulator_booted != 1 )); then
  echo 'coverage emulator did not complete boot before its startup deadline' >&2
  exit 124
fi

# Verify the AVD name through the same ADB transport used by the fixture.
# A new emulator that reuses the serial receives a different transport ID.
startup_adb() {
  during_startup "$adb" -t "$transport" "$@"
}
actual_avd=$(startup_adb shell getprop ro.boot.qemu.avd_name | tr -d '\r')
if [[ "$actual_avd" != "$avd_name" ]]; then
  echo "coverage emulator is not the newly created AVD: $serial" >&2
  exit 1
fi
qemu=$(startup_adb shell getprop ro.kernel.qemu | tr -d '\r')
if [[ "$qemu" != 1 ]]; then
  echo 'coverage self-test requires the dedicated emulator' >&2
  exit 1
fi
android_user=$(startup_adb shell am get-current-user | tr -d '\r')
if [[ "$android_user" != 0 ]]; then
  echo 'coverage self-test requires Android user 0' >&2
  exit 1
fi
printf 'Verified dedicated API 36 AVD %s (%s, ADB transport %s)\n' "$avd_name" "$serial" "$transport"

# A synthetic MENU key at boot can time out in Launcher3 before it has a
# focused window. Use power and keyguard services on the verified AVD.
startup_adb shell svc power stayon true
startup_adb shell wm dismiss-keyguard
for setting in window_animation_scale transition_animation_scale animator_duration_scale; do
  startup_adb shell settings put global "$setting" 0.0
done

# sys.boot_completed can precede the final keyguard/screen transition. Wait for the
# same fail-closed API 36 state that android-agent-ui.mjs checks again before install.
emulator_ready=0
for attempt in {1..15}; do
  probe_rc=0
  policy=$(startup_adb shell dumpsys window policy) || probe_rc=$?
  if (( probe_rc == 0 )); then
    during_startup node --input-type=module -e '
      import {parseKeyguard} from "./apps/browser/scripts/verify-android-agent-target.mjs";
      let dump = "";
      process.stdin.setEncoding("utf8");
      for await (const chunk of process.stdin) dump += chunk;
      const state = parseKeyguard(dump);
      process.exit(state.known && state.unlocked && state.screenOn ? 0 : 1);
    ' <<< "$policy" || probe_rc=$?
  fi
  if (( probe_rc == 0 )); then
    emulator_ready=1
    break
  fi
  if (( probe_rc == 124 || probe_rc == 137 )); then exit "$probe_rc"; fi
  if (( attempt < 15 )); then during_startup sleep 1; fi
done
if (( emulator_ready != 1 )); then
  echo 'dedicated emulator did not reach the verified unlocked screen state' >&2
  exit 1
fi

if ! node apps/browser/scripts/android-agent-ui.mjs self-test \
  --adb "$adb" \
  --serial "$serial" \
  --transport-id "$transport" \
  --driver-build "$RUNNER_TEMP/aegis-driver-coverage" \
  --coverage-output "$EVIDENCE_DIR/coverage" \
  --output "$EVIDENCE_DIR/self-test.json"; then
  # Only this verified, disposable emulator is inspected. Keep system focus/ANR
  # metadata, never screenshots, UI hierarchies, or an attempt to dismiss dialogs.
  node --input-type=module - "$adb" "$transport" > "$EVIDENCE_DIR/emulator-failure-metadata.txt" <<'NODE' || true
    import {execFileSync} from 'node:child_process';
    const [,, adb, transport] = process.argv;
    const probes = [
      ['window-focus', ['shell', 'dumpsys', 'window', 'displays'], /^\s*(mCurrentFocus|mFocusedApp)=/u],
      ['last-anr', ['shell', 'dumpsys', 'activity', 'lastanr'], /^\s*(ANR in |PID:|Reason:|ErrorId:|Frozen:|No ANR)/u],
      ['system-errors', ['logcat', '-d', '-b', 'events', '-s', 'am_anr', 'am_crash'], /am_(anr|crash)/u],
    ];
    for (const [label, args, selected] of probes) {
      console.log('[' + label + ']');
      try {
        const output = execFileSync(adb, ['-t', transport, ...args], {
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
  timeout --kill-after=2s 10s "$adb" -t "$transport" logcat -d -v brief 'AndroidRuntime:E' '*:S' | tail -n 120 >&2 || true
  exit 1
fi
