#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AEGIS_STATUS_SOURCE_ONLY=1
source "$SCRIPT_DIR/status.sh"
unset AEGIS_STATUS_SOURCE_ONLY

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s（实际=%s，预期=%s）\n' "$label" "$actual" "$expected" >&2
    exit 1
  fi
}

assert_eq exact "$(patch_lineage_kind true true)" \
  "原始 commit 与 patch-id 均匹配才是 exact"
assert_eq replay "$(patch_lineage_kind false true)" \
  "只有 patch-id 匹配时才是 replay"
assert_eq mismatch "$(patch_lineage_kind true false)" \
  "commit 相同但 patch-id 不同必须失败"
assert_eq /tmp/out/Chromium.app/Contents/MacOS/Chromium \
  "$(desktop_binary_path /tmp/out Darwin)" "macOS 产物路径"
assert_eq /tmp/out/chrome "$(desktop_binary_path /tmp/out Linux)" \
  "Linux 产物路径"
if desktop_binary_path /tmp/out Unknown >/dev/null 2>&1; then
  printf 'FAIL: 未知宿主不应返回桌面产物路径\n' >&2
  exit 1
fi

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/aegis-status-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
OVERLAY_DIR="$fixture_root/overlay"
SRC="$fixture_root/src"
mkdir -p "$OVERLAY_DIR/chrome/test" "$SRC/chrome/test"
printf 'same\n' > "$OVERLAY_DIR/chrome/test/policy.cc"
printf 'same\n' > "$SRC/chrome/test/policy.cc"

SKIP_OVERLAY_CHECK=0
errors=0
warnings=0
check_overlay_matches_checkout >/dev/null
assert_eq 0 "$errors" "一致 overlay 应通过"

printf 'drifted\n' > "$SRC/chrome/test/policy.cc"
errors=0
warnings=0
check_overlay_matches_checkout >/dev/null
assert_eq 1 "$errors" "内容漂移必须硬失败"

SKIP_OVERLAY_CHECK=1
errors=0
warnings=0
check_overlay_matches_checkout >/dev/null
assert_eq 0 "$errors" "显式跳过不应计为失败"
assert_eq 1 "$warnings" "显式跳过必须留下警告"

# 真实 Chromium 配置会忽略 submodule dirty；状态门只能额外豁免
# .DS_Store，未跟踪头文件仍必须显示为依赖 checkout 脏改动。
gitlink_src="$fixture_root/gitlink-src"
gitlink_child="$gitlink_src/third_party/dependency"
mkdir -p "$gitlink_child"
git -C "$gitlink_src" init -q
git -C "$gitlink_src" config user.name AegisFixture
git -C "$gitlink_src" config user.email aegis-fixture@example.invalid
printf 'root\n' > "$gitlink_src/root.txt"
git -C "$gitlink_src" add root.txt
git -C "$gitlink_src" commit -qm root
git -C "$gitlink_child" init -q
git -C "$gitlink_child" config user.name AegisFixture
git -C "$gitlink_child" config user.email aegis-fixture@example.invalid
printf 'clean\n' > "$gitlink_child/value.txt"
git -C "$gitlink_child" add value.txt
git -C "$gitlink_child" commit -qm base
gitlink_sha="$(git -C "$gitlink_child" rev-parse HEAD)"
git -C "$gitlink_src" update-index --add --cacheinfo \
  "160000,$gitlink_sha,third_party/dependency"
git -C "$gitlink_src" commit -qm gitlink
git -C "$gitlink_src" config diff.ignoreSubmodules dirty

printf 'local metadata\n' > "$gitlink_child/.DS_Store"
assert_eq '' "$(chromium_checkout_status "$gitlink_src")" \
  ".DS_Store 不应污染源码身份"
printf 'build input\n' > "$gitlink_child/untracked-header.h"
gitlink_status="$(chromium_checkout_status "$gitlink_src")"
if [[ "$gitlink_status" != *third_party/dependency* ]]; then
  printf 'FAIL: 未跟踪依赖源码被错误隐藏（实际=%s）\n' "$gitlink_status" >&2
  exit 1
fi

printf 'PASS: status.sh fixture\n'
