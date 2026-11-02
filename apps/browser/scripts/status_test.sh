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

assert_eq '/tmp/out/GCSA Aegis.app/Contents/MacOS/GCSA Aegis' \
  "$(desktop_binary_path /tmp/out Darwin)" "macOS 产物路径"
assert_eq '/tmp/out/GCSA Aegis.app' \
  "$(desktop_app_path /tmp/out)" "macOS App 路径"
assert_eq /tmp/out/chrome "$(desktop_binary_path /tmp/out Linux)" \
  "Linux 产物路径"
if desktop_binary_path /tmp/out Unknown >/dev/null 2>&1; then
  printf 'FAIL: 未知宿主不应返回桌面产物路径\n' >&2
  exit 1
fi

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/aegis-status-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
lineage_src="$fixture_root/lineage-src"
lineage_patches="$fixture_root/lineage-patches"
mkdir -p "$lineage_src" "$lineage_patches"
git -C "$lineage_src" init -q
git -C "$lineage_src" config user.name AegisFixture
git -C "$lineage_src" config user.email aegis-fixture@example.invalid
printf 'original\n' > "$lineage_src/value.txt"
git -C "$lineage_src" add value.txt
git -C "$lineage_src" commit -qm base
lineage_base="$(git -C "$lineage_src" rev-parse HEAD)"
printf 'current\n' > "$lineage_src/value.txt"
git -C "$lineage_src" commit -qam change
git -C "$lineage_src" format-patch -1 --stdout --full-index > "$lineage_patches/0001-fixture.patch"
printf '0001-fixture.patch\n' > "$lineage_patches/series"
assert_eq exact "$(patch_lineage_kind "$lineage_src" "$lineage_base" "$lineage_patches" Chromium "$lineage_patches/series")" \
  "status 使用与 build 相同的 v2 精确树及规范化 ID 校验"
assert_eq exact "$(patch_lineage_kind "$lineage_src" "$lineage_base" "$lineage_patches" V8 "$lineage_patches/series")" \
  "V8 使用同一 v2 判定"

selected_series="$fixture_root/selected-series"
printf '0001-selected.patch\n' > "$selected_series"
cp "$lineage_patches/0001-fixture.patch" "$fixture_root/original.patch"
sed 's/^+current$/+selected-drift/' "$fixture_root/original.patch" > "$lineage_patches/0001-selected.patch"
run_selected_lineage() {
  env AEGIS_STATUS_SOURCE_ONLY=1 AEGIS_PATCH_DIR="$lineage_patches" \
    AEGIS_V8_PATCH_DIR="$lineage_patches" AEGIS_SERIES_FILE="$selected_series" \
    AEGIS_V8_SERIES_FILE="$selected_series" bash -c '
      source "$1"
      if [[ "$4" == V8 ]]; then
        selected="$V8_SERIES_FILE"; patches="$V8_PATCH_DIR"
      else
        selected="$SERIES_FILE"; patches="$PATCH_DIR"
      fi
      patch_lineage_kind "$2" "$3" "$patches" "$4" "$selected"
    ' status-selector-fixture "$SCRIPT_DIR/status.sh" "$lineage_src" "$lineage_base" "$1"
}
selector_errors=0
for lineage_label in Chromium V8; do
  if selected_result="$(run_selected_lineage "$lineage_label" 2>&1)"; then
    printf 'FAIL: R53 %s 接受了所选替代 series 的内容漂移（%s）\n' "$lineage_label" "$selected_result" >&2
    selector_errors=$((selector_errors + 1))
  elif [[ "$selected_result" != *'ordered exact patch tree'* ]]; then
    printf 'FAIL: R53 %s 未传播所选 series 的精确树拒绝：%s\n' "$lineage_label" "$selected_result" >&2
    selector_errors=$((selector_errors + 1))
  fi
done
[[ "$selector_errors" -eq 0 ]] || exit 1
# Inverse case: the selected list is correct while the default list is wrong.
cp "$fixture_root/original.patch" "$lineage_patches/0001-selected.patch"
sed 's/^+current$/+default-drift/' "$fixture_root/original.patch" > "$lineage_patches/0001-fixture.patch"
for lineage_label in Chromium V8; do
  assert_eq exact "$(run_selected_lineage "$lineage_label")" \
    "R53 $lineage_label 必须验证所选 manifest，不能回退默认 series"
done
cp "$fixture_root/original.patch" "$lineage_patches/0001-fixture.patch"

r54_logical="$fixture_root/r54-logical"
r54_physical="$fixture_root/r54-physical"
mkdir -p "$r54_logical" "$r54_physical/inner"
ln -s "$r54_physical/inner" "$r54_logical/alias"
printf '0001-physical.patch\n' > "$r54_physical/series"
printf '0001-lexical.patch\n' > "$r54_logical/series"
cp "$fixture_root/original.patch" "$lineage_patches/0001-lexical.patch"
sed 's/^+current$/+physical-drift/' "$fixture_root/original.patch" > "$lineage_patches/0001-physical.patch"
r54_raw_series="$r54_logical/alias/../series"
assert_eq '0001-physical.patch' "$(cat "$r54_raw_series")" \
  "R54 文件系统必须先遍历目录符号链接，再处理 .."
run_r54_selected_lineage() {
  if [[ "$2" == relative ]]; then
    (cd "$fixture_root"; selected_series='r54-logical/alias/../series'; run_selected_lineage "$1")
  else
    selected_series="$r54_raw_series" run_selected_lineage "$1"
  fi
}
r54_selector_errors=0
for lineage_label in Chromium V8; do
  for selection_form in absolute relative; do
    if selected_result="$(run_r54_selected_lineage "$lineage_label" "$selection_form" 2>&1)"; then
      printf 'FAIL: R54 %s/%s 校验了词法路径而非所选清单（%s）\n' "$lineage_label" "$selection_form" "$selected_result" >&2
      r54_selector_errors=$((r54_selector_errors + 1))
    elif [[ "$selected_result" != *'ordered exact patch tree'*'0001-physical'* ]]; then
      printf 'FAIL: R54 %s/%s 未传播实际所选清单拒绝：%s\n' "$lineage_label" "$selection_form" "$selected_result" >&2
      r54_selector_errors=$((r54_selector_errors + 1))
    fi
  done
done
[[ "$r54_selector_errors" -eq 0 ]] || exit 1
cp "$fixture_root/original.patch" "$lineage_patches/0001-physical.patch"
sed 's/^+current$/+lexical-drift/' "$fixture_root/original.patch" > "$lineage_patches/0001-lexical.patch"
for lineage_label in Chromium V8; do
  for selection_form in absolute relative; do
    assert_eq exact "$(run_r54_selected_lineage "$lineage_label" "$selection_form")" \
      "R54 $lineage_label/$selection_form 必须接受实际所选清单，不读词法替代文件"
  done
done
printf 'PASS: R54 Chromium/V8 absolute/relative filesystem selectors\n'

sed 's/^+current$/+drifted/' "$lineage_patches/0001-fixture.patch" > "$lineage_patches/drift.patch"
mv "$lineage_patches/drift.patch" "$lineage_patches/0001-fixture.patch"
if patch_lineage_kind "$lineage_src" "$lineage_base" "$lineage_patches" Chromium "$lineage_patches/series" \
    > "$fixture_root/lineage-drift.log" 2>&1; then
  printf 'FAIL: status 接受了真实内容漂移\n' >&2
  exit 1
fi
if ! rg -q 'ordered exact patch tree' "$fixture_root/lineage-drift.log"; then
  printf 'FAIL: status 未传播精确树拒绝原因\n' >&2
  exit 1
fi

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

# check_overlay_matches_checkout comes from the sourced status.sh and reads this
# shell variable directly; ShellCheck cannot follow the dynamic source path.
# shellcheck disable=SC2034
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
