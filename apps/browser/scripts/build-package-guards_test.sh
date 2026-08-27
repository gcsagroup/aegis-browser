#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aegis-build-package-guards.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 签名会修改产物字节：只能在 build finalize 前执行，run 不得再签名。
if rg -q 'sign-chromium-app\.sh' "$SCRIPT_DIR/run-release.sh"; then
  fail "run-release 不得修改已由身份清单绑定的 App"
fi
sign_line="$(rg -n 'sign-chromium-app\.sh' "$SCRIPT_DIR/build-release.sh" | \
  head -n 1 | cut -d: -f1)"
finalize_line="$(rg -n '^echo "Finalizing source-to-artifact identity' \
  "$SCRIPT_DIR/build-release.sh" | head -n 1 | cut -d: -f1)"
if [[ -z "$sign_line" || -z "$finalize_line" || "$sign_line" -ge "$finalize_line" ]]; then
  fail "build-release 必须在身份清单 finalize 前完成签名"
fi

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
cat > "$FAKE_BIN/gn" <<'EOF'
#!/usr/bin/env bash
touch "$FAKE_GN_REACHED"
echo "FAKE_GN_STOP" >&2
exit 23
EOF
cat > "$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
touch "$FAKE_NODE_REACHED"
printf '%s\n' "$*" >> "$FAKE_NODE_LOG"
if [[ "$FAKE_NODE_MODE" == "fail" ]]; then
  echo "FAKE_NODE_STOP" >&2
  exit 23
fi
printf '%s\n' '{"localCandidate":true,"verified":true}'
EOF
cat > "$FAKE_BIN/ditto" <<'EOF'
#!/usr/bin/env bash
touch "$FAKE_DITTO_REACHED"
echo "FAKE_DITTO_STOP" >&2
exit 23
EOF
chmod +x "$FAKE_BIN/gn" "$FAKE_BIN/node" "$FAKE_BIN/ditto"

# build:release 必须在任何 out/.aegis/gn 写入前拒绝非正式 OUT。
build_out_root="$TEST_ROOT/build-out/chromium"
mkdir -p "$build_out_root/src"
expect_failure "build:release 接受了 checkout 外 OUT_DIR" \
  "build:release OUT_DIR must be exactly" \
  env CHROMIUM_ROOT="$build_out_root" \
    DEPOT_TOOLS_DIR="$TEST_ROOT/no-depot-tools" \
    OUT_DIR="$TEST_ROOT/not-allowed" \
    bash "$SCRIPT_DIR/build-release.sh"
[[ ! -e "$build_out_root/src/out" ]] || fail "非法 OUT 拒绝前创建了 src/out"
[[ ! -e "$TEST_ROOT/not-allowed" ]] || fail "非法 OUT 拒绝前修改了目标"

# 预置 .aegis symlink 不得把 lock/history 写到树外。
build_link_root="$TEST_ROOT/build-link/chromium"
build_link_out="$build_link_root/src/out/AegisRelease"
build_link_escape="$TEST_ROOT/build-link/escape"
mkdir -p "$build_link_out" "$build_link_escape"
touch "$build_link_escape/sentinel"
ln -s "$build_link_escape" "$build_link_out/.aegis"
expect_failure "build:release 接受了 .aegis symlink" \
  "Release identity directories must not be symlinks" \
  env CHROMIUM_ROOT="$build_link_root" \
    DEPOT_TOOLS_DIR="$TEST_ROOT/no-depot-tools" \
    bash "$SCRIPT_DIR/build-release.sh"
[[ -f "$build_link_escape/sentinel" ]] || fail ".aegis symlink 负例改动了 sentinel"
[[ ! -e "$build_link_escape/build.lock" ]] || fail ".aegis symlink 负例在树外创建了 lock"
[[ ! -e "$build_link_escape/history" ]] || fail ".aegis symlink 负例在树外创建了 history"

# 合法的首次路径应安全创建 src/out 并到达 gn，不能因过度约束无条件失败。
build_reach_root="$TEST_ROOT/build-reach/chromium"
build_reach_marker="$TEST_ROOT/build-reach/gn-reached"
mkdir -p "$build_reach_root/src"
expect_failure "build:release 合法路径未到达 gn" \
  "FAKE_GN_STOP" \
  env PATH="$FAKE_BIN:$PATH" \
    CHROMIUM_ROOT="$build_reach_root" \
    DEPOT_TOOLS_DIR="$TEST_ROOT/no-depot-tools" \
    FAKE_GN_REACHED="$build_reach_marker" \
    bash "$SCRIPT_DIR/build-release.sh"
[[ -f "$build_reach_marker" ]] || fail "合法 build 路径未调用 gn"
[[ -d "$build_reach_root/src/out/AegisRelease/.aegis" ]] || \
  fail "合法 build 路径未创建内部 identity 目录"
[[ ! -e "$build_reach_root/src/out/AegisRelease/.aegis/build.lock" ]] || \
  fail "gn 失败后残留 build lock"

build_out_link_root="$TEST_ROOT/build-out-link/chromium"
build_out_link_escape="$TEST_ROOT/build-out-link/escape"
mkdir -p "$build_out_link_root/src/out" "$build_out_link_escape"
ln -s "$build_out_link_escape" "$build_out_link_root/src/out/AegisRelease"
expect_failure "build:release 接受了 AegisRelease symlink" \
  "Release OUT_DIR must not be a symlink" \
  env CHROMIUM_ROOT="$build_out_link_root" \
    DEPOT_TOOLS_DIR="$TEST_ROOT/no-depot-tools" \
    bash "$SCRIPT_DIR/build-release.sh"
[[ ! -e "$build_out_link_escape/.aegis" ]] || fail "OUT symlink 负例在树外写入了 .aegis"

# package 路径门必须在 lock/ditto/rm 前拒绝。清单只是为了让用例到达
# DIST 路径校验，不会进入真实身份复验。
package_root="$TEST_ROOT/package/chromium"
package_out="$package_root/src/out/AegisRelease"
package_app="$package_out/Chromium.app"
package_manifest="$package_out/.aegis/build-manifest.json"
mkdir -p "$package_app/Contents" "$package_out/.aegis"
touch "$package_manifest" "$package_manifest.sha256"
fixed_sha="$(printf 'a%.0s' {1..64})"

expect_failure "package 接受了路径穿越版本" \
  "Unsafe version or architecture path component" \
  env CHROMIUM_ROOT="$package_root" \
    AEGIS_PACKAGE_VERSION='../escape' \
    AEGIS_BUILD_MANIFEST_SHA256="$fixed_sha" \
    DIST_DIR="$TEST_ROOT/package/version-dist" \
    PACKAGE_FORMATS=app \
    bash "$SCRIPT_DIR/package.sh"
[[ ! -e "$TEST_ROOT/package/version-dist" ]] || fail "版本路径负例创建了 dist"

package_escape="$TEST_ROOT/package/dist-escape"
package_dist_link="$TEST_ROOT/package/dist-link"
mkdir -p "$package_escape"
touch "$package_escape/sentinel"
ln -s "$package_escape" "$package_dist_link"
expect_failure "package 接受了 DIST_DIR symlink" \
  "DIST_DIR must not be a symlink" \
  env CHROMIUM_ROOT="$package_root" \
    AEGIS_BUILD_MANIFEST_SHA256="$fixed_sha" \
    DIST_DIR="$package_dist_link" \
    PACKAGE_FORMATS=app \
    bash "$SCRIPT_DIR/package.sh"
[[ -f "$package_escape/sentinel" ]] || fail "DIST symlink 负例改动了 sentinel"
[[ ! -e "$package_escape/GCSA-aegis.app" ]] || fail "DIST symlink 负例写入了树外"

inside_app_dist="$package_app/Contents/dist"
expect_failure "package 接受了源 App 内 DIST_DIR" \
  "DIST_DIR must not overlap source, App, or build identity" \
  env CHROMIUM_ROOT="$package_root" \
    AEGIS_BUILD_MANIFEST_SHA256="$fixed_sha" \
    DIST_DIR="$inside_app_dist" \
    PACKAGE_FORMATS=app \
    bash "$SCRIPT_DIR/package.sh"
[[ ! -e "$inside_app_dist" ]] || fail "App 交叠负例在源 App 内写入了 dist"
[[ ! -e "$package_out/.aegis/build.lock" ]] || fail "App 交叠负例提前创建了 lock"

package_link_root="$TEST_ROOT/package-id-link/chromium"
package_link_out="$package_link_root/src/out/AegisRelease"
package_link_escape="$TEST_ROOT/package-id-link/escape"
mkdir -p "$package_link_out/Chromium.app/Contents" "$package_link_escape"
touch "$package_link_escape/build-manifest.json"
touch "$package_link_escape/build-manifest.json.sha256"
touch "$package_link_escape/sentinel"
ln -s "$package_link_escape" "$package_link_out/.aegis"
expect_failure "package 接受了 build identity symlink" \
  "Package build identity directory must be a real child of OUT" \
  env CHROMIUM_ROOT="$package_link_root" \
    AEGIS_BUILD_MANIFEST_SHA256="$fixed_sha" \
    DIST_DIR="$TEST_ROOT/package-id-link/dist" \
    PACKAGE_FORMATS=app \
    bash "$SCRIPT_DIR/package.sh"
[[ -f "$package_link_escape/sentinel" ]] || fail "identity symlink 负例改动了 sentinel"
[[ ! -e "$package_link_escape/build.lock" ]] || fail "identity symlink 负例在树外创建了 lock"
[[ ! -e "$TEST_ROOT/package-id-link/dist" ]] || fail "identity symlink 负例创建了 dist"

# 合法 package 路径必须到达身份复验；复验主动失败时，预存 dist
# 的文件集和内容不得变化，且不得残留 lock。
verify_fail_dist="$TEST_ROOT/package/verify-fail-dist"
verify_fail_sentinel="$verify_fail_dist/sentinel"
verify_fail_node="$TEST_ROOT/package/verify-fail-node-reached"
verify_fail_node_log="$TEST_ROOT/package/verify-fail-node.log"
verify_fail_ditto="$TEST_ROOT/package/verify-fail-ditto-reached"
mkdir -p "$verify_fail_dist"
printf 'preserve\n' > "$verify_fail_sentinel"
before_sentinel_sha="$(shasum -a 256 "$verify_fail_sentinel" | awk '{print $1}')"
expect_failure "package 合法路径未到达身份复验" \
  "FAKE_NODE_STOP" \
  env PATH="$FAKE_BIN:$PATH" \
    CHROMIUM_ROOT="$package_root" \
    AEGIS_ALLOW_DIRTY_IDENTITY=1 \
    AEGIS_BUILD_MANIFEST_SHA256="$fixed_sha" \
    DIST_DIR="$verify_fail_dist" \
    PACKAGE_FORMATS=app \
    FAKE_NODE_MODE=fail \
    FAKE_NODE_REACHED="$verify_fail_node" \
    FAKE_NODE_LOG="$verify_fail_node_log" \
    FAKE_DITTO_REACHED="$verify_fail_ditto" \
    bash "$SCRIPT_DIR/package.sh"
[[ -f "$verify_fail_node" ]] || fail "合法 package 路径未调用 identity verifier"
[[ ! -e "$verify_fail_ditto" ]] || fail "identity 复验失败后仍调用了 ditto"
[[ "$(find "$verify_fail_dist" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == "1" ]] || \
  fail "identity 复验失败改变了 dist 文件集"
[[ "$(shasum -a 256 "$verify_fail_sentinel" | awk '{print $1}')" == "$before_sentinel_sha" ]] || \
  fail "identity 复验失败改变了 dist sentinel"
[[ ! -e "$package_out/.aegis/build.lock" ]] || fail "identity 复验失败后残留 build lock"

# formats typo 必须在 lock 和 identity verifier 前失败。
formats_marker="$TEST_ROOT/package/formats-node-reached"
expect_failure "package 接受了未知 PACKAGE_FORMATS" \
  "Unknown PACKAGE_FORMATS entry: typo" \
  env PATH="$FAKE_BIN:$PATH" \
    CHROMIUM_ROOT="$package_root" \
    AEGIS_ALLOW_DIRTY_IDENTITY=1 \
    AEGIS_BUILD_MANIFEST_SHA256="$fixed_sha" \
    DIST_DIR="$verify_fail_dist" \
    PACKAGE_FORMATS='app,typo' \
    FAKE_NODE_MODE=success \
    FAKE_NODE_REACHED="$formats_marker" \
    FAKE_NODE_LOG="$TEST_ROOT/package/formats-node.log" \
    FAKE_DITTO_REACHED="$TEST_ROOT/package/formats-ditto-reached" \
    bash "$SCRIPT_DIR/package.sh"
[[ ! -e "$formats_marker" ]] || fail "formats typo 拒绝前调用了 identity verifier"
[[ ! -e "$package_out/.aegis/build.lock" ]] || fail "formats typo 拒绝前创建了 lock"

# 包输出 identity 及 sidecar 叶子 symlink 必须在 stage/ditto 前被拒绝。
identity_dist="$TEST_ROOT/package/output-identity-link-dist"
identity_escape="$TEST_ROOT/package/output-identity-link-target"
identity_node_marker="$TEST_ROOT/package/output-identity-node-reached"
identity_node_log="$TEST_ROOT/package/output-identity-node.log"
identity_ditto_marker="$TEST_ROOT/package/output-identity-ditto-reached"
version="$(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/../CHROMIUM_VERSION" | head -n 1 | tr -d '[:space:]')"
cpu="$(uname -m)"
identity_base="$identity_dist/GCSA-aegis-0.1.0-chromium-${version}-mac-${cpu}.build-identity.json"
mkdir -p "$identity_dist"
touch "$identity_escape"
for identity_link in "$identity_base" "$identity_base.sha256"; do
  ln -s "$identity_escape" "$identity_link"
  expect_failure "package 接受了输出 identity 叶子 symlink" \
    "Package identity files must not be symlinks" \
    env PATH="$FAKE_BIN:$PATH" \
      CHROMIUM_ROOT="$package_root" \
      AEGIS_ALLOW_DIRTY_IDENTITY=1 \
      AEGIS_BUILD_MANIFEST_SHA256="$fixed_sha" \
      DIST_DIR="$identity_dist" \
      PACKAGE_FORMATS=app \
      FAKE_NODE_MODE=success \
      FAKE_NODE_REACHED="$identity_node_marker" \
      FAKE_NODE_LOG="$identity_node_log" \
      FAKE_DITTO_REACHED="$identity_ditto_marker" \
      bash "$SCRIPT_DIR/package.sh"
  [[ -f "$identity_node_marker" ]] || fail "identity 叶子 symlink 用例未到达身份复验"
  [[ ! -e "$identity_ditto_marker" ]] || fail "identity 叶子 symlink 拒绝后调用了 ditto"
  rm "$identity_link" "$identity_node_marker"
done

printf 'PASS: build/package path guard fixtures\n'
