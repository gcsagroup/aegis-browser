#!/usr/bin/env bash
# Prepare verified Xcode inputs for a staged package or simulator build.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
work="$(cd "$1" && pwd -P)"
products="${2:-$work/.artifacts/ios-embedded-core}"
lock="$root/apps/ios/EmbeddedCore/embedded-core-lock.json"
go_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["toolchain"]["go"])' "$lock")"
# Retain managed Go provisioning for package builds. The builder verifies this
# root and installs the pinned binding tools into its own temporary directory.
unset GOROOT
GOROOT="$(GOTOOLCHAIN="go$go_version" go env GOROOT)"
export GOROOT GOTOOLCHAIN=local

# The original checkout owns the build provenance. Xcode reads the staged
# verifier, lock and bridge, and its sandbox input list must name those copies.
AEGIS_EMBEDDED_CORE_DIGEST_MODE="${AEGIS_EMBEDDED_CORE_DIGEST_MODE:-ci-rebuild}" \
  bash "$root/scripts/release/prepare-ios-access-core.sh" "$lock" "$products" "$work"
