#!/usr/bin/env bash
# Package an existing Mac .app as an unnotarized internal DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.8.0}"
ARCH="${2:-arm64}"

find_app() {
  local root candidate
  local roots=()
  [[ -n "${AEGIS_MACOS_APP_ROOT:-}" ]] && roots+=("$AEGIS_MACOS_APP_ROOT")
  roots+=(
    "$HOME/src/aegis-browser"
    "/Volumes/CI/Git/gsca/aegis-browser"
    "/Volumes/CI/Codex"
  )
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r candidate; do
      if [[ -d "$candidate/Contents/MacOS" && -f "$candidate/Contents/Info.plist" && ! -L "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(find "$root" -maxdepth 8 \( -name 'GCSA-aegis.app' -o -name 'Aegis.app' \) -type d -prune 2>/dev/null | head -n 20)
  done
  return 1
}

APP="$(find_app || true)"
if [[ -z "$APP" ]]; then
  printf 'No GCSA-aegis.app or Aegis.app under the Mac build roots. Refusing to invent a DMG.\n' >&2
  exit 3
fi

APP_ROOT="$(cd "$(dirname "$APP")" && pwd -P)"
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
OUTPUT="${MACOS_OUTPUT_DIR:-${RUNNER_TEMP:-/tmp}/aegis-macos-internal-${VERSION}-$$}"
rm -rf "$OUTPUT"

export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-quinn521/aegis-browser}"
export GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-workflow_dispatch}"
export GITHUB_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
export MACOS_OPERATION=package
export MACOS_VERSION="$VERSION"
export MACOS_SIGNING_MODE="${MACOS_SIGNING_MODE:-ad-hoc}"
export MACOS_ARCH="$ARCH"
export MACOS_APP_PATH="$APP"
export AEGIS_MACOS_APP_ROOT="$APP_ROOT"
export AEGIS_IOS_RUNNER_LABEL="${AEGIS_IOS_RUNNER_LABEL:-aegis-ios-fork-migration}"
export MACOS_ACTUAL_ARCH="$(uname -m)"
export MACOS_OUTPUT_DIR="$OUTPUT"
export MACOS_NOTARIZE=false

python3 scripts/release/macos-dmg.py package
echo "MACOS_INTERNAL_DMG=$OUTPUT"
