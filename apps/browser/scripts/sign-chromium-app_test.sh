#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_CODESIGN="$TEST_ROOT/codesign"
cat > "$FAKE_CODESIGN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CODESIGN_LOG"
if [[ " $* " == *" --force "* && " $* " == *" --sign - "* && \
      "$*" == *"Chromium Helper Sibling.app"* ]]; then
  touch "$FAKE_SIBLING_SIGNED"
fi
if [[ " $* " == *" --verify "* ]]; then
  count=0
  [[ ! -f "$FAKE_CODESIGN_COUNT" ]] || count="$(<"$FAKE_CODESIGN_COUNT")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$FAKE_CODESIGN_COUNT"
  case "$FAKE_CODESIGN_MODE" in
    already) exit 0 ;;
    sign_then_valid)
      if [[ "$count" -gt 1 ]]; then exit 0; else exit 1; fi
      ;;
    sibling_sign_then_valid)
      if [[ "$*" == *"Chromium Helper Sibling.app"* ]]; then
        [[ -f "$FAKE_SIBLING_SIGNED" ]]
      elif [[ "$count" -gt 1 ]]; then
        exit 0
      else
        exit 1
      fi
      ;;
    sibling_invalid)
      if [[ "$*" == *"Chromium Helper Sibling.app"* ]]; then exit 1; else exit 0; fi
      ;;
    never_valid) exit 1 ;;
    *) exit 2 ;;
  esac
fi
exit 0
EOF
chmod +x "$FAKE_CODESIGN"

make_app() {
  local root="$1"
  local app="$root/Chromium.app"
  mkdir -p "$app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Helpers"
  : > "$app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework"
  printf '%s\n' "$app"
}

run_case() {
  local mode="$1"
  local case_root="$TEST_ROOT/$mode"
  local app
  mkdir -p "$case_root"
  app="$(make_app "$case_root")"
  if [[ "$mode" == sibling_* ]]; then
    mkdir -p "$case_root/Chromium Helper Sibling.app"
  fi
  export FAKE_CODESIGN_MODE="$mode"
  export FAKE_CODESIGN_LOG="$case_root/calls.log"
  export FAKE_CODESIGN_COUNT="$case_root/count"
  export FAKE_SIBLING_SIGNED="$case_root/sibling-signed"
  CODESIGN="$FAKE_CODESIGN" bash "$SCRIPT_DIR/sign-chromium-app.sh" \
    "$app" "$case_root"
}

run_case already
if rg -q -- '--force' "$TEST_ROOT/already/calls.log"; then
  echo "strict/deep-valid App was signed again" >&2
  exit 1
fi

run_case sign_then_valid
rg -q -- '--force --sign -' "$TEST_ROOT/sign_then_valid/calls.log"
[[ "$(<"$TEST_ROOT/sign_then_valid/count")" -eq 3 ]]

run_case sibling_sign_then_valid
rg -q -- '--force --sign - .*Chromium Helper Sibling.app' \
  "$TEST_ROOT/sibling_sign_then_valid/calls.log"

set +e
run_case never_valid >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]]

set +e
run_case sibling_invalid >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]]

for log in "$TEST_ROOT"/*/calls.log; do
  while IFS= read -r call; do
    if [[ " $call " == *" --verify "* ]]; then
      [[ " $call " == *" --deep "* && " $call " == *" --strict "* ]] || {
        echo "verify call missing --deep/--strict: $call" >&2
        exit 1
      }
      [[ " $call " != *" --quiet "* ]] || {
        echo "verify call uses unsupported --quiet: $call" >&2
        exit 1
      }
    fi
  done < "$log"
done

echo "PASS: sign-chromium-app strict/deep fixture"
