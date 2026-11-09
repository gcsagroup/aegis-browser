#!/usr/bin/env bash
# Build an internal iOS  archive for fork testing.
# Does not upload to App Store Connect. The 0.8.0 train is closed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.8.0}"
BUILD="${2:-1}"
ARCHIVE="${IOS_INTERNAL_ARCHIVE:-${RUNNER_TEMP:-/tmp}/Aegis-${VERSION}-${BUILD}.xcarchive}"
DERIVED="${IOS_INTERNAL_DERIVED:-${RUNNER_TEMP:-/tmp}/Aegis-derived-${VERSION}-${BUILD}}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  printf 'iOS internal archive needs xcodebuild on the self-hosted Mac.\n' >&2
  exit 2
fi
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec apps/ios/project.yml
fi

mkdir -p "$(dirname "$ARCHIVE")"
xcodebuild \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  archive

python3 scripts/release/verify-ios-archive.py "$ARCHIVE" "$VERSION" "$BUILD"

RECEIPT="$(dirname "$ARCHIVE")/ios-internal-receipt.json"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGNED="false"
if printf '%s\n' "$IDENTITIES" | grep -Eq 'Apple Development|iPhone Distribution|Apple Distribution'; then
  APP="$ARCHIVE/Products/Applications/Aegis.app"
  IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Apple Development|Apple Distribution|iPhone Distribution/ {print $2; exit}')"
  if [[ -n "$IDENTITY" && -d "$APP" ]]; then
    if /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$APP" \
        && /usr/bin/codesign --verify --strict "$APP"; then
      SIGNED="true"
    fi
  fi
fi

python3 - "$RECEIPT" "$VERSION" "$BUILD" "$ARCHIVE" "$SIGNED" <<'PY'
import json, sys
path, version, build, archive, signed = sys.argv[1:]
json.dump({
    "product": "ios-internal",
    "version": version,
    "build": build,
    "archive": archive,
    "signed": signed == "true",
    "testFlight": False,
    "appStoreUpload": False,
    "reason": "0.8.0 App Store train is closed; this artifact stays on the fork runner",
}, open(path, "w"), indent=2)
print(path)
PY
echo "IOS_INTERNAL_ARCHIVE=$ARCHIVE"
