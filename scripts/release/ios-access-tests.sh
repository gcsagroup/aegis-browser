#!/usr/bin/env bash
# Simulator Access tests for the fork. No App Store signing and no upload.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  printf 'iOS Access simulator tests need xcodebuild on the self-hosted Mac.\n' >&2
  exit 2
fi

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec apps/ios/project.yml
fi

DESTINATION="${AEGIS_IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
xcodebuild test \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -destination "$DESTINATION" \
  -only-testing:AccessKitTests \
  -only-testing:AegisTests/AccessSiteProxyToggleModelTests \
  CODE_SIGNING_ALLOWED=YES
