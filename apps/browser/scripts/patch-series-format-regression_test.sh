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
cat > "$patch_dir/valid.patch" <<'PATCH'
diff --git a/example.txt b/example.txt
new file mode 100644
index 0000000..8e27be7
--- /dev/null
+++ b/example.txt
@@ -0,0 +1 @@
+example
PATCH

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
