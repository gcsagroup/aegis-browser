#!/usr/bin/env bash
set -euo pipefail

browser_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for patch_dir in "$browser_dir/patches" "$browser_dir/patches/v8"; do
  series_file="$patch_dir/series"
  while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" =~ ^[[:space:]]*# ]] && continue
    if [[ "$patch_name" == */* || "$patch_name" == *..* ||
          ! -f "$patch_dir/$patch_name" ]]; then
      printf 'FAIL: invalid patch path in %s: %s\n' "$series_file" "$patch_name" >&2
      exit 1
    fi
    if ! git apply --stat "$patch_dir/$patch_name" >/dev/null; then
      printf 'FAIL: malformed patch in %s: %s\n' "$series_file" "$patch_name" >&2
      exit 1
    fi
  done < "$series_file"
done

printf 'PASS: Chromium and V8 patch formats\n'
