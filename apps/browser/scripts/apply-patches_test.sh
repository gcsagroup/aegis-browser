#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/apply-patches.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s（实际=%s，预期=%s）\n' \
      "$label" "$actual" "$expected" >&2
    exit 1
  fi
}

assert_contains() {
  local value="$1"
  local expected="$2"
  local label="$3"
  if [[ "$value" != *"$expected"* ]]; then
    printf 'FAIL: %s（未找到=%s）\n' "$label" "$expected" >&2
    exit 1
  fi
}

configure_repo() {
  local repo="$1"
  git -C "$repo" config user.name AegisFixture
  git -C "$repo" config user.email aegis-fixture@localhost
}

run_apply() {
  local chromium_root="$1"
  local patch_dir="$2"
  local series_file="$3"
  local base_file="$4"
  CHROMIUM_ROOT="$chromium_root" \
    AEGIS_PATCH_DIR="$patch_dir" \
    AEGIS_SERIES_FILE="$series_file" \
    AEGIS_COMMIT_FILE="$base_file" \
    bash "$SCRIPT_UNDER_TEST"
}

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/aegis-apply-patches-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

# 成功场景：format-patch 必须通过 git am 形成一个真实提交。
success_chromium_root="$fixture_root/success/chromium"
success_src="$success_chromium_root/src"
success_patch_dir="$fixture_root/success/patches"
success_series="$success_patch_dir/series"
success_base_file="$fixture_root/success/CHROMIUM_COMMIT"
mkdir -p "$success_src" "$success_patch_dir"
git -C "$success_src" init -q
configure_repo "$success_src"

printf 'base\n' > "$success_src/state.txt"
git -C "$success_src" add state.txt
git -C "$success_src" commit -q -m base
success_base_sha="$(git -C "$success_src" rev-parse HEAD)"

printf 'patched\n' > "$success_src/state.txt"
git -C "$success_src" commit -qam 'fixture patch'
git -C "$success_src" format-patch --stdout -1 HEAD \
  > "$success_patch_dir/0001-fixture.patch"
git -C "$success_src" reset -q --hard "$success_base_sha"
printf '%s\n' "$success_base_sha" > "$success_base_file"
printf '%s\n' '0001-fixture.patch' > "$success_series"

run_apply "$success_chromium_root" "$success_patch_dir" \
  "$success_series" "$success_base_file" >/dev/null
assert_eq 1 \
  "$(git -C "$success_src" rev-list --count "$success_base_sha"..HEAD)" \
  "成功应用必须新增一个提交"
assert_eq 'fixture patch' \
  "$(git -C "$success_src" show -s --format=%s HEAD)" \
  "git am 必须保留补丁提交信息"
assert_eq 'patched' "$(tr -d '\n' < "$success_src/state.txt")" \
  "成功应用后的内容"
assert_eq '' "$(git -C "$success_src" status --porcelain)" \
  "成功应用后 checkout 必须干净"

# 脏树场景：未跟踪文件也必须被拒绝，且不能改变 HEAD。
git -C "$success_src" reset -q --hard "$success_base_sha"
printf 'do not touch\n' > "$success_src/untracked.txt"
if dirty_output="$(run_apply "$success_chromium_root" "$success_patch_dir" \
  "$success_series" "$success_base_file" 2>&1)"; then
  fail "存在未跟踪文件时不应应用补丁"
fi
assert_contains "$dirty_output" 'must be clean' "脏树拒绝原因"
assert_eq "$success_base_sha" "$(git -C "$success_src" rev-parse HEAD)" \
  "脏树拒绝不能移动 HEAD"
[[ -f "$success_src/untracked.txt" ]] || fail "脏树拒绝不能删除用户文件"
rm -f "$success_src/untracked.txt"

# 非 base 场景：即使 checkout 干净，也必须精确拒绝其他 HEAD。
git -C "$success_src" commit -q --allow-empty -m 'not pinned base'
wrong_head_sha="$(git -C "$success_src" rev-parse HEAD)"
if head_output="$(run_apply "$success_chromium_root" "$success_patch_dir" \
  "$success_series" "$success_base_file" 2>&1)"; then
  fail "非固定 base HEAD 不应应用补丁"
fi
assert_contains "$head_output" 'HEAD must equal pinned base' \
  "非 base HEAD 拒绝原因"
assert_eq "$wrong_head_sha" "$(git -C "$success_src" rev-parse HEAD)" \
  "非 base 拒绝不能移动 HEAD"
assert_eq '' "$(git -C "$success_src" status --porcelain)" \
  "非 base 拒绝不能污染 checkout"

# 冲突场景：git am 失败后必须保留 rebase-apply 和冲突索引。
conflict_chromium_root="$fixture_root/conflict/chromium"
conflict_src="$conflict_chromium_root/src"
conflict_patch_dir="$fixture_root/conflict/patches"
conflict_series="$conflict_patch_dir/series"
conflict_base_file="$fixture_root/conflict/CHROMIUM_COMMIT"
mkdir -p "$conflict_src" "$conflict_patch_dir"
git -C "$conflict_src" init -q
configure_repo "$conflict_src"

printf 'common\n' > "$conflict_src/state.txt"
git -C "$conflict_src" add state.txt
git -C "$conflict_src" commit -q -m ancestor
ancestor_sha="$(git -C "$conflict_src" rev-parse HEAD)"

git -C "$conflict_src" checkout -q -b patch-source
printf 'patch side\n' > "$conflict_src/state.txt"
git -C "$conflict_src" commit -qam 'conflicting patch'
git -C "$conflict_src" format-patch --stdout -1 HEAD \
  > "$conflict_patch_dir/0001-conflict.patch"

git -C "$conflict_src" checkout -q -b pinned-target "$ancestor_sha"
printf 'target side\n' > "$conflict_src/state.txt"
git -C "$conflict_src" commit -qam 'pinned target'
conflict_base_sha="$(git -C "$conflict_src" rev-parse HEAD)"
printf '%s\n' "$conflict_base_sha" > "$conflict_base_file"
printf '%s\n' '0001-conflict.patch' > "$conflict_series"

if conflict_output="$(run_apply "$conflict_chromium_root" \
  "$conflict_patch_dir" "$conflict_series" "$conflict_base_file" 2>&1)"; then
  fail "三方冲突必须让补丁工作流失败"
fi
assert_contains "$conflict_output" 'git am state preserved' \
  "冲突失败必须说明保留现场"
assert_eq "$conflict_base_sha" "$(git -C "$conflict_src" rev-parse HEAD)" \
  "冲突失败不能自动移动或重置 HEAD"
am_state="$(git -C "$conflict_src" rev-parse --absolute-git-dir)/rebase-apply"
[[ -d "$am_state" ]] || fail "冲突失败后必须保留 rebase-apply"
[[ -n "$(git -C "$conflict_src" ls-files -u)" ]] || \
  fail "冲突失败后必须保留冲突索引"

# 嵌套 V8 场景：顶层与 V8 必须从各自固定 base 独立重放并保持干净。
nested_chromium_root="$fixture_root/nested/chromium"
nested_src="$nested_chromium_root/src"
nested_v8="$nested_src/v8"
nested_patch_dir="$fixture_root/nested/patches"
nested_v8_patch_dir="$nested_patch_dir/v8"
nested_base_file="$fixture_root/nested/CHROMIUM_COMMIT"
mkdir -p "$nested_v8" "$nested_v8_patch_dir"
git -C "$nested_src" init -q
git -C "$nested_v8" init -q
configure_repo "$nested_src"
configure_repo "$nested_v8"

printf 'v8 base\n' > "$nested_v8/v8-state.txt"
git -C "$nested_v8" add v8-state.txt
git -C "$nested_v8" commit -q -m 'v8 base'
nested_v8_base="$(git -C "$nested_v8" rev-parse HEAD)"
printf 'root base\n' > "$nested_src/root-state.txt"
git -C "$nested_src" add root-state.txt v8
git -C "$nested_src" commit -q -m 'root base with v8 gitlink'
git -C "$nested_src" config diff.ignoreSubmodules dirty
nested_base_sha="$(git -C "$nested_src" rev-parse HEAD)"
printf '%s\n' "$nested_base_sha" > "$nested_base_file"

printf 'root patched\n' > "$nested_src/root-state.txt"
git -C "$nested_src" commit -qam 'root fixture patch'
git -C "$nested_src" format-patch --stdout -1 HEAD > \
  "$nested_patch_dir/0001-root-fixture.patch"
git -C "$nested_src" reset -q --hard "$nested_base_sha"
printf '%s\n' '0001-root-fixture.patch' > "$nested_patch_dir/series"

printf 'v8 patched\n' > "$nested_v8/v8-state.txt"
git -C "$nested_v8" commit -qam 'v8 fixture patch'
git -C "$nested_v8" format-patch --stdout -1 HEAD > \
  "$nested_v8_patch_dir/0001-v8-fixture.patch"
git -C "$nested_v8" reset -q --hard "$nested_v8_base"
printf '%s\n' '0001-v8-fixture.patch' > "$nested_v8_patch_dir/series"

run_apply "$nested_chromium_root" "$nested_patch_dir" \
  "$nested_patch_dir/series" "$nested_base_file" >/dev/null
assert_eq 1 \
  "$(git -C "$nested_src" rev-list --count "$nested_base_sha"..HEAD)" \
  "顶层嵌套 fixture 必须应用一个提交"
assert_eq 1 \
  "$(git -C "$nested_v8" rev-list --count "$nested_v8_base"..HEAD)" \
  "V8 嵌套 fixture 必须应用一个提交"
assert_eq 'root patched' "$(tr -d '\n' < "$nested_src/root-state.txt")" \
  "顶层嵌套 fixture 内容"
assert_eq 'v8 patched' "$(tr -d '\n' < "$nested_v8/v8-state.txt")" \
  "V8 嵌套 fixture 内容"
assert_eq '' "$(git -C "$nested_src" status --porcelain --ignore-submodules=all)" \
  "顶层嵌套 fixture 重放后必须干净"
assert_eq '' "$(git -C "$nested_v8" status --porcelain)" \
  "V8 嵌套 fixture 重放后必须干净"

printf 'PASS: apply-patches.sh fixture\n'
