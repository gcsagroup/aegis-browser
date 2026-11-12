#!/usr/bin/env bash
# Prepare verified Xcode inputs for a staged package or simulator build.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
work="$(cd "$1" && pwd -P)"
products="${2:-$work/.artifacts/ios-embedded-core}"
lock="$root/apps/ios/EmbeddedCore/embedded-core-lock.json"
export GOBIN="$(dirname "$products")/go-bin"
mkdir -p "$GOBIN"
go_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["toolchain"]["go"])' "$lock")"
mobile="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["toolchain"]["gomobile"])' "$lock")"
# Let the selected go binary locate its matching compiler and standard library.
unset GOROOT
export GOTOOLCHAIN="go$go_version"
export PATH="$GOBIN:$PATH"
go install "golang.org/x/mobile/cmd/gomobile@${mobile##*@}" "golang.org/x/mobile/cmd/gobind@${mobile##*@}"

# The original checkout owns the build provenance. Xcode reads the staged
# verifier, lock and bridge, and its sandbox input list must name those copies.
AEGIS_EMBEDDED_CORE_DIGEST_MODE="${AEGIS_EMBEDDED_CORE_DIGEST_MODE:-ci-rebuild}" \
  bash "$root/scripts/release/prepare-ios-access-core.sh" "$lock" "$products" "$work"
