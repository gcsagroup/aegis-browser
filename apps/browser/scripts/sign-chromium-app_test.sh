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
expected_identity="${FAKE_SIGNING_IDENTITY:-7C33B517942161311A087CE893D2F1CE9B204B44}"
expected_team="${FAKE_SIGNING_TEAM:-R3JK7R29AC}"
if [[ " $* " == *" --force "* && " $* " == *" --sign $expected_identity "* && \
      "$*" == *"Helper Sibling.app"* ]]; then
  touch "$FAKE_SIBLING_SIGNED"
fi
if [[ " $* " == *" --force "* && "$FAKE_CODESIGN_MODE" == sign_failed ]]; then
  exit 41
fi
if [[ " $* " == *" --verify "* ]]; then
  [[ " $* " == *" --test-requirement "* && "$*" == *"certificate leaf = H\"$expected_identity\""* && "$*" == *"$expected_team"* ]] || exit 42
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
      if [[ "$*" == *"Helper Sibling.app"* ]]; then
        [[ -f "$FAKE_SIBLING_SIGNED" ]]
      elif [[ "$count" -gt 1 ]]; then
        exit 0
      else
        exit 1
      fi
      ;;
    sibling_invalid)
      if [[ "$*" == *"Helper Sibling.app"* ]]; then exit 1; else exit 0; fi
      ;;
    never_valid|sign_failed) exit 1 ;;
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
rg -q -- '--force --sign 7C33B517942161311A087CE893D2F1CE9B204B44' "$TEST_ROOT/sign_then_valid/calls.log"
[[ "$(<"$TEST_ROOT/sign_then_valid/count")" -eq 3 ]]

run_case sibling_sign_then_valid
rg -q -- '--force --sign 7C33B517942161311A087CE893D2F1CE9B204B44 .*Chromium Helper Sibling.app' \
  "$TEST_ROOT/sibling_sign_then_valid/calls.log"

brand_root="$TEST_ROOT/branded"
brand_app="$brand_root/Aegis Browser.app"
mkdir -p "$brand_app/Contents/Frameworks/Aegis Browser Framework.framework/Versions/Current/Helpers"
: > "$brand_app/Contents/Frameworks/Aegis Browser Framework.framework/Versions/Current/Aegis Browser Framework"
cat > "$brand_app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Aegis Browser</string>
</dict></plist>
EOF
mkdir -p "$brand_root/Aegis Browser Helper Sibling.app"
export FAKE_CODESIGN_MODE=sibling_sign_then_valid
export FAKE_CODESIGN_LOG="$brand_root/calls.log"
export FAKE_CODESIGN_COUNT="$brand_root/count"
export FAKE_SIBLING_SIGNED="$brand_root/sibling-signed"
CODESIGN="$FAKE_CODESIGN" bash "$SCRIPT_DIR/sign-chromium-app.sh" \
  "$brand_app" "$brand_root"
rg -q -- '--force --sign 7C33B517942161311A087CE893D2F1CE9B204B44 .*Aegis Browser Framework.framework/Versions/Current/Aegis Browser Framework' \
  "$brand_root/calls.log"
rg -q -- '--force --sign 7C33B517942161311A087CE893D2F1CE9B204B44 .*Aegis Browser Helper Sibling.app' \
  "$brand_root/calls.log"

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

set +e
run_case sign_failed >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 41 ]]
[[ "$(rg -c -- '--force' "$TEST_ROOT/sign_failed/calls.log")" -eq 1 ]]

# 本地验收必须同时使用指定开发身份和非 official 参数；正式参数禁止签名。
local_root="$TEST_ROOT/local_acceptance"
local_app="$(make_app "$local_root")"
export FAKE_CODESIGN_MODE=sign_then_valid
export FAKE_CODESIGN_LOG="$local_root/calls.log"
export FAKE_CODESIGN_COUNT="$local_root/count"
export FAKE_SIBLING_SIGNED="$local_root/sibling-signed"
export FAKE_SIGNING_IDENTITY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
export FAKE_SIGNING_TEAM=LOCALDEV01
export AEGIS_MACOS_LOCAL_SIGNING_IDENTITY="$FAKE_SIGNING_IDENTITY"
export AEGIS_MACOS_LOCAL_SIGNING_TEAM="$FAKE_SIGNING_TEAM"
printf '%s\n' 'is_official_build = true' > "$local_root/args.gn"
if AEGIS_MACOS_LOCAL_ACCEPTANCE=1 CODESIGN="$FAKE_CODESIGN" \
    bash "$SCRIPT_DIR/sign-chromium-app.sh" "$local_app" "$local_root"; then
  echo "正式构建误用了本地开发身份" >&2
  exit 1
fi
[[ ! -e "$FAKE_CODESIGN_LOG" ]]
printf '%s\n' 'is_official_build = false' > "$local_root/args.gn"
AEGIS_MACOS_LOCAL_ACCEPTANCE=1 CODESIGN="$FAKE_CODESIGN" \
  bash "$SCRIPT_DIR/sign-chromium-app.sh" "$local_app" "$local_root"
rg -q -- '--force --sign AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$FAKE_CODESIGN_LOG"
if rg -q -- '7C33B517942161311A087CE893D2F1CE9B204B44|R3JK7R29AC' "$FAKE_CODESIGN_LOG"; then
  echo "本地验收仍使用了旧签名身份" >&2
  exit 1
fi
unset FAKE_SIGNING_IDENTITY FAKE_SIGNING_TEAM AEGIS_MACOS_LOCAL_SIGNING_IDENTITY AEGIS_MACOS_LOCAL_SIGNING_TEAM

for log in "$TEST_ROOT"/*/calls.log; do
  while IFS= read -r call; do
    [[ " $call " != *" --sign - "* ]] || {
      echo "不得回退到临时签名" >&2
      exit 1
    }
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

echo "PASS: 固定 GCSA 证书、严格校验、失败关闭与 Helper 签名回归"
