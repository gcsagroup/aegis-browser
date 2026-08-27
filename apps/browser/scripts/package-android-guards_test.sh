#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aegis-android-package-guards.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  local expected="$2"
  local output
  shift 2
  if output="$("$@" 2>&1)"; then
    fail "$label"
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL: %s（未命中预期门=%s，实际=%s）\n' \
      "$label" "$expected" "$output" >&2
    exit 1
  fi
}

FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch "$FAKE_NODE_REACHED"
if [[ "${FAKE_NODE_MODE:-fail}" == "fail" ]]; then
  echo "FAKE_NODE_STOP" >&2
  exit 23
fi
output=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$output" ]]
printf '{"kind":"test-identity"}\n' > "$output"
printf '%064d  %s\n' 0 "$(basename "$output")" > "$output.sha256"
EOF
chmod +x "$FAKE_BIN/node"

PACKAGE_ROOT="$TEST_ROOT/chromium"
PACKAGE_OUT="$PACKAGE_ROOT/src/out/AegisAndroid"
APK_SRC="$PACKAGE_OUT/apks/ChromePublic.apk"
mkdir -p "$(dirname "$APK_SRC")"
printf 'representative-apk\n' > "$APK_SRC"

expect_failure "package:android 接受了路径穿越版本" \
  "Unsafe Android package version path component" \
  env CHROMIUM_ROOT="$PACKAGE_ROOT" \
    AEGIS_PACKAGE_VERSION='../escape' \
    DIST_DIR="$TEST_ROOT/version-dist" \
    bash "$SCRIPT_DIR/package-android.sh"
[[ ! -e "$TEST_ROOT/version-dist" ]] || fail "版本路径负例创建了 dist"

OUTSIDE_OUT="$TEST_ROOT/outside-out"
mkdir -p "$OUTSIDE_OUT/apks"
printf 'outside-apk\n' > "$OUTSIDE_OUT/apks/ChromePublic.apk"
expect_failure "package:android 接受了 checkout 外 OUT_DIR" \
  "Android package OUT_DIR must be a strict child" \
  env CHROMIUM_ROOT="$PACKAGE_ROOT" \
    OUT_DIR="$OUTSIDE_OUT" \
    DIST_DIR="$TEST_ROOT/outside-dist" \
    bash "$SCRIPT_DIR/package-android.sh"
[[ ! -e "$TEST_ROOT/outside-dist" ]] || fail "非法 OUT 负例创建了 dist"

# 预置目标符号链接必须在 node 校验和复制之前被拒绝。
LINK_CASE="$TEST_ROOT/link-case"
LINK_DIST="$LINK_CASE/dist"
LINK_SENTINEL="$LINK_CASE/outside-sentinel"
LINK_NODE="$LINK_CASE/node-reached"
mkdir -p "$LINK_DIST"
printf 'sentinel-before\n' > "$LINK_SENTINEL"
ln -s "$LINK_SENTINEL" "$LINK_DIST/GCSA-aegis.apk"
expect_failure "package:android 接受了既有 APK 符号链接" \
  "Refusing existing Android package output" \
  env PATH="$FAKE_BIN:$PATH" \
    CHROMIUM_ROOT="$PACKAGE_ROOT" \
    DIST_DIR="$LINK_DIST" \
    FAKE_NODE_REACHED="$LINK_NODE" \
    FAKE_NODE_MODE=success \
    bash "$SCRIPT_DIR/package-android.sh"
[[ "$(cat "$LINK_SENTINEL")" == "sentinel-before" ]] || \
  fail "APK 符号链接负例覆盖了树外 sentinel"
[[ ! -e "$LINK_NODE" ]] || fail "APK 符号链接拒绝前调用了 identity"

# identity 失败时不得改变 dist 文件集或现有内容。
FAIL_CASE="$TEST_ROOT/identity-fail-case"
FAIL_DIST="$FAIL_CASE/dist"
FAIL_SENTINEL="$FAIL_DIST/sentinel"
FAIL_NODE="$FAIL_CASE/node-reached"
mkdir -p "$FAIL_DIST"
printf 'preserve\n' > "$FAIL_SENTINEL"
before_sha="$(shasum -a 256 "$FAIL_SENTINEL" | awk '{print $1}')"
expect_failure "package:android identity 失败后仍发布了产物" \
  "FAKE_NODE_STOP" \
  env PATH="$FAKE_BIN:$PATH" \
    CHROMIUM_ROOT="$PACKAGE_ROOT" \
    DIST_DIR="$FAIL_DIST" \
    FAKE_NODE_REACHED="$FAIL_NODE" \
    FAKE_NODE_MODE=fail \
    bash "$SCRIPT_DIR/package-android.sh"
[[ -f "$FAIL_NODE" ]] || fail "identity 失败负例未到达 node"
[[ "$(find "$FAIL_DIST" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == "1" ]] || \
  fail "identity 失败改变了 dist 文件集"
[[ "$(shasum -a 256 "$FAIL_SENTINEL" | awk '{print $1}')" == "$before_sha" ]] || \
  fail "identity 失败改变了 dist sentinel"
[[ ! -e "$FAIL_CASE/.aegis-android-package.lock" ]] || fail "identity 失败残留了 lock"
[[ -z "$(find "$FAIL_CASE" -maxdepth 1 -name '.aegis-android-package.*' -print -quit)" ]] || \
  fail "identity 失败残留了暂存目录"

# 代表性正常输入应先到达 identity，再发布四个普通文件。
SUCCESS_CASE="$TEST_ROOT/success-case"
SUCCESS_DIST="$SUCCESS_CASE/dist"
SUCCESS_NODE="$SUCCESS_CASE/node-reached"
mkdir -p "$SUCCESS_CASE"
env PATH="$FAKE_BIN:$PATH" \
  CHROMIUM_ROOT="$PACKAGE_ROOT" \
  DIST_DIR="$SUCCESS_DIST" \
  FAKE_NODE_REACHED="$SUCCESS_NODE" \
  FAKE_NODE_MODE=success \
  bash "$SCRIPT_DIR/package-android.sh" >/dev/null
[[ -f "$SUCCESS_NODE" ]] || fail "合法路径未调用 identity"
[[ "$(cat "$SUCCESS_DIST/GCSA-aegis.apk")" == "representative-apk" ]] || \
  fail "代表性 APK 内容不匹配"
[[ "$(find "$SUCCESS_DIST" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" == "4" ]] || \
  fail "合法路径未发布完整 APK 与 identity"
[[ ! -e "$SUCCESS_CASE/.aegis-android-package.lock" ]] || fail "合法路径残留了 lock"

printf 'PASS: Android package path and publish guards\n'
