#!/usr/bin/env bash
# Build and measure the pinned iOS binding without editing the source lock.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
exec python3 -B "$root/scripts/release/ios_core_build.py" "$@"
