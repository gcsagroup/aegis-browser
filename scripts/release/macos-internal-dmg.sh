#!/usr/bin/env bash
# Package an existing Mac .app as an unnotarized internal DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.8.0}"
ARCH="${2:-arm64}"
if [[ "$ARCH" != arm64 ]]; then
  printf 'This release runner/build supports arm64 only.\n' >&2
  exit 2
fi

is_mac_app() {
  local candidate="$1"
  [[ -d "$candidate/Contents/MacOS" && -f "$candidate/Contents/Info.plist" && ! -L "$candidate" ]]
}

find_app() {
  local root candidate
  local roots=()
  local names=('GCSA Aegis.app' 'GCSA-aegis.app' 'Aegis.app')
  [[ -n "${AEGIS_MACOS_APP_ROOT:-}" ]] && roots+=("$AEGIS_MACOS_APP_ROOT")
  roots+=(
    "$HOME/Projects/GCSA-aegis-build/macos/src/out/AegisRelease"
    "$HOME/Projects/GCSA-aegis-build/macos/src/out/Aegis"
    "$HOME/src/aegis-browser/src/out/AegisRelease"
    "$HOME/src/aegis-browser/src/out/Aegis"
    "/Volumes/CI/Git/gsca/aegis-browser/src/out/AegisRelease"
    "/Volumes/CI/Git/gsca/aegis-browser/src/out/Aegis"
  )
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    for candidate in "${names[@]}"; do
      if is_mac_app "$root/$candidate"; then
        printf '%s\n' "$root/$candidate"
        return 0
      fi
    done
  done
  roots+=(
    "$HOME/Projects"
    "$HOME/src"
    "$HOME/Developer"
    "/Volumes/CI"
    "/Volumes/ExternalSSD"
    "/Volumes/CI/Codex"
  )
  local name
  for name in "GCSA Aegis.app" "GCSA-aegis.app" "Aegis.app"; do
    for root in "${roots[@]}"; do
      [[ -d "$root" ]] || continue
      while IFS= read -r candidate; do
        if is_mac_app "$candidate"; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done < <(find "$root" -maxdepth 8 -name "$name" -type d -prune 2>/dev/null | head -n 5)
    done
  done
  return 1
}

APP="$(find_app || true)"
if [[ -z "$APP" ]]; then
  printf 'No GCSA Aegis.app with Contents/MacOS under the Mac release output. Refusing to invent a DMG.\n' >&2
  report_roots=(
    "${AEGIS_MACOS_APP_ROOT:-}"
    "$HOME/Projects/GCSA-aegis-build/macos/src/out/AegisRelease"
    "$HOME/Projects/GCSA-aegis-build/macos/src/out/Aegis"
    "$HOME/src/aegis-browser/src/out/AegisRelease"
    "$HOME/src/aegis-browser/src/out/Aegis"
    "/Volumes/CI/Git/gsca/aegis-browser/src/out/AegisRelease"
    "/Volumes/CI/Git/gsca/aegis-browser/src/out/Aegis"
  )
  for root in "${report_roots[@]}"; do
    [[ -n "$root" ]] || continue
    if [[ ! -d "$root" ]]; then
      printf 'missing %s\n' "$root" >&2
      continue
    fi
    printf 'exists %s\n' "$root" >&2
    for name in "GCSA Aegis.app" "GCSA-aegis.app" "Aegis.app"; do
      if [[ -d "$root/$name" ]]; then
        if [[ -d "$root/$name/Contents/MacOS" && ! -L "$root/$name" ]]; then
          printf 'present %s/%s Contents/MacOS=yes\n' "$root" "$name" >&2
        else
          printf 'present %s/%s Contents/MacOS=no\n' "$root" "$name" >&2
        fi
      fi
    done
    if [[ -d "$root/src/out" ]]; then
      printf 'out %s/src/out\n' "$root" >&2
      find "$root/src/out" -maxdepth 2 \( -name '*.app' -o -type d \) -print 2>/dev/null | head -n 40 >&2
    fi
  done
  for root in \
    "$HOME/Projects" \
    "$HOME/Projects/GCSA-aegis-build" \
    "$HOME/Projects/GCSA-aegis-build/macos" \
    "/Volumes/CI" \
    "/Volumes/CI/Git" \
    "/Volumes/CI/Git/gsca" \
    "/Volumes/CI/Git/gsca/aegis-browser" \
    "/Volumes/CI/Codex"
  do
    if [[ -d "$root" ]]; then
      printf 'exists %s\n' "$root" >&2
    else
      printf 'missing %s\n' "$root" >&2
    fi
  done
  exit 3
fi

APP_ROOT="$(cd "$(dirname "$APP")" && pwd -P)"
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
OUTPUT="${MACOS_OUTPUT_DIR:-${RUNNER_TEMP:-/tmp}/aegis-macos-internal-${VERSION}-$$}"
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  printf 'Refusing to overwrite existing package output: %s\n' "$OUTPUT" >&2
  exit 2
fi

export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-quinn521/aegis-browser}"
export GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-workflow_dispatch}"
export GITHUB_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
export MACOS_OPERATION=package
export MACOS_VERSION="$VERSION"
export MACOS_ARCH="$ARCH"
export MACOS_APP_PATH="$APP"
export AEGIS_MACOS_APP_ROOT="$APP_ROOT"
export AEGIS_IOS_RUNNER_LABEL="${AEGIS_IOS_RUNNER_LABEL:-aegis-ios-fork-migration}"
export MACOS_ACTUAL_ARCH="$(uname -m)"
export MACOS_OUTPUT_DIR="$OUTPUT"
export MACOS_NOTARIZE=false
export MACOS_SIGNING_MODE=ad-hoc

python3 scripts/release/macos-dmg.py package
echo "MACOS_INTERNAL_DMG=$OUTPUT"
