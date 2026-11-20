#!/usr/bin/env bash
set -euo pipefail

browser_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mail_dir="$(mktemp -d "${TMPDIR:-/tmp}/aegis-patch-mail.XXXXXX")"
trap 'rm -rf -- "$mail_dir"' EXIT

if (( $# > 0 )); then
  patch_dirs=("$@")
else
  patch_dirs=("$browser_dir/patches" "$browser_dir/patches/v8"
              "$browser_dir/patches-android" "$browser_dir/patches-android/v8")
fi

for patch_dir in "${patch_dirs[@]}"; do
  series_file="$patch_dir/series"
  if [[ ! -f "$series_file" ]]; then
    printf 'FAIL: missing patch series file: %s\n' "$series_file" >&2
    exit 1
  fi
  while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
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
    # Production uses git am, and lineage requires a format-patch commit ID.
    # A bare diff passes git apply --stat but cannot satisfy either contract.
    IFS= read -r first_line < "$patch_dir/$patch_name"
    if [[ ! "$first_line" =~ ^From\ [0-9a-f]{40}\  ]]; then
      printf 'FAIL: missing format-patch commit header: %s\n' "$patch_dir/$patch_name" >&2
      exit 1
    fi
    if ! git mailinfo "$mail_dir/message" "$mail_dir/diff" \
        < "$patch_dir/$patch_name" > "$mail_dir/metadata"; then
      printf 'FAIL: invalid patch mail: %s\n' "$patch_dir/$patch_name" >&2
      exit 1
    fi
    for field in Author Email Subject Date; do
      if ! grep -Eq "^$field: [^[:space:]]" "$mail_dir/metadata"; then
        printf 'FAIL: missing patch mail %s: %s\n' "$field" "$patch_dir/$patch_name" >&2
        exit 1
      fi
    done
    if ! git apply --stat "$mail_dir/diff" >/dev/null; then
      printf 'FAIL: missing diff in patch mail: %s\n' "$patch_dir/$patch_name" >&2
      exit 1
    fi
  done < "$series_file"
done

printf 'PASS: Chromium and V8 patch formats\n'
