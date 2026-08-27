#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_depot_tools_on_path

SRC="$CHROMIUM_ROOT/src"
PATCH_DIR="${AEGIS_PATCH_DIR:-$ROOT_DIR/patches}"
SERIES="${AEGIS_SERIES_FILE:-$PATCH_DIR/series}"
V8_PATCH_DIR="${AEGIS_V8_PATCH_DIR:-$PATCH_DIR/v8}"
V8_SERIES="${AEGIS_V8_SERIES_FILE:-$V8_PATCH_DIR/series}"
BASE_FILE="${AEGIS_COMMIT_FILE:-$COMMIT_FILE}"

if ! git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Chromium src missing at $SRC — run fetch first."
  exit 1
fi

base_sha="$(read_pinned_value "$BASE_FILE" 2>/dev/null || true)"
if [[ ! "$base_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Chromium base SHA invalid in $BASE_FILE: ${base_sha:-missing}" >&2
  exit 1
fi
if ! git -C "$SRC" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
  echo "Chromium checkout does not contain pinned base $base_sha" >&2
  exit 1
fi

dirty_status="$(git -C "$SRC" status --porcelain=v1 --untracked-files=all --ignore-submodules=all)"
if [[ -n "$dirty_status" ]]; then
  echo "Chromium checkout must be clean before applying patches:" >&2
  printf '%s\n' "$dirty_status" >&2
  exit 1
fi

head_sha="$(git -C "$SRC" rev-parse HEAD)"
if [[ "$head_sha" != "$base_sha" ]]; then
  echo "Chromium checkout HEAD must equal pinned base before applying patches." >&2
  echo "  HEAD: $head_sha" >&2
  echo "  base: $base_sha" >&2
  exit 1
fi

if [[ ! -s "$SERIES" ]] || \
   ! grep -vqE '^[[:space:]]*(#|$)' "$SERIES"; then
  echo "No patches listed in patches/series yet — nothing to apply."
  echo "Checkout OK at $SRC"
  exit 0
fi

patch_names=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*\# ]] && continue
  if [[ "$line" == */* || "$line" == *..* ]]; then
    echo "Unsafe patch path in series: $line" >&2
    exit 1
  fi
  patch_file="$PATCH_DIR/$line"
  if [[ ! -f "$patch_file" ]]; then
    echo "Missing patch: $patch_file"
    exit 1
  fi
  patch_names+=("$line")
done < "$SERIES"

v8_patch_names=()
if [[ -s "$V8_SERIES" ]] &&
   grep -vqE '^[[:space:]]*(#|$)' "$V8_SERIES"; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*\# ]] && continue
    if [[ "$line" == */* || "$line" == *..* ]]; then
      echo "Unsafe V8 patch path in series: $line" >&2
      exit 1
    fi
    patch_file="$V8_PATCH_DIR/$line"
    if [[ ! -f "$patch_file" ]]; then
      echo "Missing V8 patch: $patch_file" >&2
      exit 1
    fi
    v8_patch_names+=("$line")
  done < "$V8_SERIES"
fi

if [[ "${#v8_patch_names[@]}" -gt 0 ]]; then
  V8_SRC="$SRC/v8"
  if ! git -C "$V8_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "V8 checkout missing at $V8_SRC — run fetch first." >&2
    exit 1
  fi
  v8_base_sha="$(git -C "$SRC" rev-parse "${base_sha}:v8" 2>/dev/null || true)"
  if [[ ! "$v8_base_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Pinned Chromium base does not contain a valid V8 gitlink." >&2
    exit 1
  fi
  v8_dirty_status="$(git -C "$V8_SRC" status --porcelain=v1 --untracked-files=all)"
  if [[ -n "$v8_dirty_status" ]]; then
    echo "V8 checkout must be clean before applying patches:" >&2
    printf '%s\n' "$v8_dirty_status" >&2
    exit 1
  fi
  v8_head_sha="$(git -C "$V8_SRC" rev-parse HEAD)"
  if [[ "$v8_head_sha" != "$v8_base_sha" ]]; then
    echo "V8 checkout HEAD must equal the V8 gitlink from pinned Chromium base." >&2
    echo "  HEAD: $v8_head_sha" >&2
    echo "  base: $v8_base_sha" >&2
    exit 1
  fi
fi

cd "$SRC"
for line in "${patch_names[@]}"; do
  patch_file="$PATCH_DIR/$line"
  echo "Applying $line"
  if ! git am --3way "$patch_file"; then
    echo "Patch failed: $line" >&2
    echo "git am state preserved for inspection or an explicit continue/abort." >&2
    exit 1
  fi
done

if [[ "${#v8_patch_names[@]}" -gt 0 ]]; then
  cd "$V8_SRC"
  for line in "${v8_patch_names[@]}"; do
    patch_file="$V8_PATCH_DIR/$line"
    echo "Applying V8/$line"
    if ! git am --3way "$patch_file"; then
      echo "V8 patch failed: $line" >&2
      echo "git am state preserved in the V8 checkout for inspection or an explicit continue/abort." >&2
      exit 1
    fi
  done
fi

echo "Chromium and nested V8 patches applied."
