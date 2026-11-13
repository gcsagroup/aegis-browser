#!/usr/bin/env bash
# Rebuild GCSA Aegis.app from a Chromium checkout on this Mac, then ad-hoc sign a DMG.
# Does not fetch Chromium and does not invent an app when the checkout is absent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.8.0}"
ARCH="${2:-arm64}"
if [[ "$ARCH" != arm64 ]]; then
  printf 'This release runner/build supports arm64 only.\n' >&2
  exit 2
fi
ARGS_FILE="$ROOT/apps/browser/args/aegis-release.gn"

is_chromium_src() {
  local src="$1"
  [[ -d "$src" && ! -L "$src" && -f "$src/chrome/BUILD.gn" && -d "$src/build" ]]
}

remember_src() {
  local src="$1"
  is_chromium_src "$src" || return 0
  src="$(cd "$src" && pwd -P)"
  case "$src" in
    *android*) ANDROID_SRC="${ANDROID_SRC:-$src}" ;;
    *macos*|*mac-*|*upstream-candidate*|*Aegis*|*aegis*) MAC_SRC="$src" ;;
    *) OTHER_SRC="${OTHER_SRC:-$src}" ;;
  esac
  printf 'found chromium %s\n' "$src" >&2
}

find_src() {
  local candidate root build_gn
  local candidates=()
  [[ -n "${CHROMIUM_ROOT:-}" ]] && candidates+=("${CHROMIUM_ROOT}/src")
  candidates+=(
    "$HOME/Projects/GCSA-aegis-build/macos/src"
    "$HOME/Projects/GCSA-aegis-build/upstream-candidate/src"
    "/Users/lazy/Projects/GCSA-aegis-build/macos/src"
    "/Users/lazy/Projects/GCSA-aegis-build/upstream-candidate/src"
    "/Volumes/AegisBuild/upstream-candidate/src"
    "/Volumes/CI/Git/gsca/chromium/src"
    "/Volumes/CI/repositories/aegis-release-build/macos/src"
    "/Volumes/ExternalSSD/repositories/aegis-release-build/src"
  )
  for candidate in "${candidates[@]}"; do
    remember_src "$candidate"
  done
  local roots=(
    "$HOME/Projects"
    "$HOME/src"
    "/Users/lazy/Projects"
    "/Volumes/AegisBuild"
    "/Volumes/CI/repositories"
    "/Volumes/ExternalSSD"
  )
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r build_gn; do
      remember_src "$(dirname "$(dirname "$build_gn")")"
      [[ -n "${MAC_SRC:-}" ]] && break
    done < <(find "$root" -maxdepth 8 -type f -path '*/chrome/BUILD.gn' -print 2>/dev/null || true)
    [[ -n "${MAC_SRC:-}" ]] && break
  done
  if [[ -n "${MAC_SRC:-}" ]]; then
    printf '%s\n' "$MAC_SRC"
  elif [[ -n "${OTHER_SRC:-}" ]]; then
    printf '%s\n' "$OTHER_SRC"
  else
    if [[ -n "${ANDROID_SRC:-}" ]]; then
      printf 'Only checkout is an Android tree: %s\n' "$ANDROID_SRC" >&2
      printf 'Its host Python is not a Mac binary, so it cannot regenerate GCSA Aegis.app.\n' >&2
    fi
    return 1
  fi
}

find_depot_tools() {
  local dir parent autoninja
  local start="$1"
  parent="$start"
  local depth
  for depth in 1 2 3 4 5 6; do
    parent="$(dirname "$parent")"
    dir="$parent/depot_tools"
    if [[ -f "$dir/autoninja" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  for dir in \
    "${DEPOT_TOOLS_DIR:-}" \
    "$HOME/depot_tools" \
    "/opt/depot_tools" \
    "/opt/homebrew/opt/depot_tools" \
    "/Volumes/CI/depot_tools" \
    "/Volumes/CI/repositories/depot_tools" \
    "/Volumes/AegisBuild/depot_tools" \
    "/Users/lazy/depot_tools"; do
    [[ -n "$dir" && -f "$dir/autoninja" ]] || continue
    printf '%s\n' "$dir"
    return 0
  done
  for parent in /Volumes/CI /Volumes/AegisBuild /opt /Users/quinn /Users/lazy "$HOME"; do
    [[ -d "$parent" ]] || continue
    while IFS= read -r autoninja; do
      printf '%s\n' "$(dirname "$autoninja")"
      return 0
    done < <(find "$parent" -maxdepth 6 -type f -path '*/depot_tools/autoninja' -print 2>/dev/null || true)
  done
  return 1
}

if [[ -n "${CHROMIUM_ROOT:-}" ]]; then
  SRC="${CHROMIUM_ROOT}/src"
  if ! is_chromium_src "$SRC"; then
    printf 'Explicit CHROMIUM_ROOT has no Chromium src: %s\n' "$SRC" >&2
    exit 3
  fi
else
  SRC="$(find_src || true)"
fi
if [[ -z "$SRC" ]]; then
  printf 'No Chromium checkout with chrome/BUILD.gn. Refusing to fetch or invent an app.\n' >&2
  exit 3
fi
SRC="$(cd "$SRC" && pwd -P)"
printf 'Using Chromium src %s\n' "$SRC"

DEPOT="$(find_depot_tools "$SRC" || true)"
if [[ -z "$DEPOT" ]]; then
  printf 'depot_tools not found. Cannot run gn or autoninja.\n' >&2
  exit 3
fi
export PATH="$DEPOT:$PATH"
export DEPOT_TOOLS_UPDATE=0
command -v gn >/dev/null
command -v autoninja >/dev/null

OUT="$SRC/out/AegisRelease"
if [[ -L "$SRC/out" || -L "$OUT" ]]; then
  printf 'Release output must not be a symlink: %s\n' "$OUT" >&2
  exit 2
fi
mkdir -p "$OUT"

avail_kb="$(df -Pk "$SRC" | awk 'NR==2 {print $4}')"
printf 'Free space on %s: %s KiB\n' "$SRC" "$avail_kb"
if [[ "${avail_kb:-0}" -lt $((20 * 1024 * 1024)) ]]; then
  printf 'Need at least 20 GiB free before regenerating the release app.\n' >&2
  exit 2
fi

# The canonical builder owns out/AegisRelease/.aegis/build.lock before GN,
# records begin/finalize identity, and retains that same lock through packaging.
export CHROMIUM_ROOT="$(dirname "$SRC")"
export DEPOT_TOOLS_DIR="$DEPOT"
export AEGIS_MACOS_PACKAGE_AFTER_BUILD=1
export MACOS_VERSION="$VERSION"
export MACOS_ARCH="$ARCH"
exec bash "$ROOT/apps/browser/scripts/build-release.sh"
