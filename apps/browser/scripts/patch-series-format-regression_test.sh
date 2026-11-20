#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/aegis-patch-series.XXXXXX")"

cleanup() {
  rm -rf -- "$fixture_root"
}
trap cleanup EXIT

patch_dir="$fixture_root/patches"
mkdir -p "$patch_dir"
repo="$fixture_root/repo"
git init -q "$repo"
git -C "$repo" config user.name 'Patch Format Test'
git -C "$repo" config user.email 'patch-format@example.invalid'
git -C "$repo" -c core.hooksPath=/dev/null commit -q --allow-empty -m baseline
base="$(git -C "$repo" rev-parse HEAD)"
printf 'example\n' > "$repo/example.txt"
git -C "$repo" add example.txt
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m 'Add example'
git -C "$repo" format-patch -1 --stdout > "$patch_dir/valid.patch"
# Exercise the same mail consumer as production, not just the diff parser.
git -C "$repo" reset -q --hard "$base"
git -C "$repo" -c core.hooksPath=/dev/null am --3way "$patch_dir/valid.patch" >/dev/null
[[ "$(cat "$repo/example.txt")" == example ]]

expect_rejected() {
  local name="$1" expected="$2"
  printf '%s\n' "$name" > "$patch_dir/series"
  if bash "$script_dir/patch-series-format_test.sh" "$patch_dir" \
      >"$fixture_root/rejected.out" 2>"$fixture_root/rejected.err"; then
    printf 'FAIL: invalid patch mail was accepted: %s\n' "$name" >&2
    exit 1
  fi
  grep -F "$expected" "$fixture_root/rejected.err" >/dev/null
}

# This is syntactically valid diff input, but git am needs its mail headers.
sed -n '/^diff --git /,$p' "$patch_dir/valid.patch" > "$patch_dir/bare.patch"
git apply --stat "$patch_dir/bare.patch" >/dev/null
expect_rejected bare.patch 'FAIL: missing format-patch commit header:'
for field in From Date Subject; do
  sed "/^$field: /d" "$patch_dir/valid.patch" > "$patch_dir/no-$field.patch"
  expect_rejected "no-$field.patch" 'FAIL: missing patch mail '
done
sed 's/^From: .*/From: <>/' "$patch_dir/valid.patch" > "$patch_dir/empty-author.patch"
expect_rejected empty-author.patch 'FAIL: missing patch mail Author:'

# Deliberately omit the final newline. A missing last entry must be rejected,
# which proves that the loop executed instead of only printing its success line.
printf '%s' 'missing.patch' > "$patch_dir/series"
if bash "$script_dir/patch-series-format_test.sh" "$patch_dir" >"$fixture_root/unterminated.out" 2>"$fixture_root/unterminated.err"; then
  printf 'FAIL: unterminated invalid patch entry was skipped\n' >&2
  exit 1
fi
grep -F "FAIL: invalid patch path in $patch_dir/series: missing.patch" "$fixture_root/unterminated.err" >/dev/null

# A valid unterminated last entry must also be accepted.
printf '%s' 'valid.patch' > "$patch_dir/series"
output="$(bash "$script_dir/patch-series-format_test.sh" "$patch_dir")"
[[ "$output" == 'PASS: Chromium and V8 patch formats' ]]

missing_dir="$fixture_root/missing"
mkdir -p "$missing_dir"
if bash "$script_dir/patch-series-format_test.sh" "$missing_dir" >"$fixture_root/missing.out" 2>"$fixture_root/missing.err"; then
  printf 'FAIL: missing series file was accepted\n' >&2
  exit 1
fi
grep -F "FAIL: missing patch series file: $missing_dir/series" "$fixture_root/missing.err" >/dev/null

printf 'PASS: patch series format regressions\n'
