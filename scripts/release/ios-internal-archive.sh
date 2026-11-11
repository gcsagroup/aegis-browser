#!/usr/bin/env bash
# Build a 0.8.0 alpha archive for development self-test.
# Alpha stays internal. Firebase stays disabled because the dev plist is not in git.
# Do not upload and do not submit for review.
# The closed train blocks 送审 only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.8.0}"
BUILD="${2:-1}"
PROFILE="${3:-alpha}"
ARCHIVE="${IOS_INTERNAL_ARCHIVE:-${RUNNER_TEMP:-/tmp}/Aegis-${VERSION}-${BUILD}.xcarchive}"
DERIVED="${IOS_INTERNAL_DERIVED:-${RUNNER_TEMP:-/tmp}/Aegis-derived-${VERSION}-${BUILD}}"

if [[ "$PROFILE" != "alpha" ]]; then
  printf '0.8.0 self-test packages are alpha only.\n' >&2
  exit 2
fi
if [[ -n "${IOS_SUBMIT_FOR_REVIEW:-}" || -n "${IOS_UPLOAD:-}" ]]; then
  printf 'Alpha self-test does not upload or submit for review.\n' >&2
  exit 2
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  printf 'iOS internal archive needs xcodebuild on the self-hosted Mac.\n' >&2
  exit 2
fi
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec apps/ios/project.yml
fi

python3 - "$PROFILE" <<'PY'
import plistlib, sys
profile = sys.argv[1]
for relative in ("apps/ios/AegisApp/Info.plist", "apps/ios/SafariWebExtension/Info.plist", "apps/ios/ShareExtension/Info.plist"):
    path = relative
    with open(path, "rb") as handle:
        info = plistlib.load(handle)
    info["AegisReleaseProfile"] = profile
    with open(path, "wb") as handle:
        plistlib.dump(info, handle)
PY

# Access channel must match the internal profile. Release defaults would cap Alpha at 16.
ACCESS_CHANNEL="$PROFILE"
if [[ "$ACCESS_CHANNEL" == "alpha" || "$ACCESS_CHANNEL" == "dev" ]]; then
  :
else
  ACCESS_CHANNEL=release
fi

# Clean archives need the locked EmbeddedCore product on disk.
# Reuse only when both slice digests still match the current lock.
XCFW="$ROOT/apps/ios/EmbeddedCore/Products/AegisEmbeddedCore.xcframework"
LOCK_FILE="$ROOT/apps/ios/EmbeddedCore/embedded-core-lock.json"
need_prepare=0
if [[ ! -d "$XCFW" ]]; then
  need_prepare=1
else
  if ! python3 - "$LOCK_FILE" "$XCFW" <<'PY'
import hashlib, json, sys
from pathlib import Path
lock = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
arts = lock.get("artifacts") or {}
expected = {
    "ios-arm64": arts.get("iosArm64Sha256"),
    "ios-arm64-simulator": arts.get("iosArm64SimulatorSha256"),
}
if not all(expected.values()):
    raise SystemExit("lock missing slice digests")

def digest_slice(slice_dir: Path) -> str:
    binaries = sorted(p for p in slice_dir.rglob("*") if p.is_file() and not p.name.startswith("."))
    if not binaries:
        raise SystemExit(f"empty slice: {slice_dir}")
    h = hashlib.sha256()
    for path in binaries:
        h.update(path.relative_to(slice_dir).as_posix().encode())
        h.update(b"\0")
        h.update(path.read_bytes())
        h.update(b"\0")
    return h.hexdigest()

actual = {}
for slice_dir in sorted(p for p in root.iterdir() if p.is_dir()):
    name = slice_dir.name
    if name == "ios-arm64":
        actual["ios-arm64"] = digest_slice(slice_dir)
    elif "simulator" in name and "arm64" in name:
        actual["ios-arm64-simulator"] = digest_slice(slice_dir)
for key, want in expected.items():
    got = actual.get(key)
    if got != want:
        raise SystemExit(f"digest mismatch for {key}")
PY
  then
    need_prepare=1
  fi
fi
if [[ "$need_prepare" -eq 1 ]]; then
  bash "$ROOT/scripts/release/prepare-ios-access-core.sh"
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
  AEGIS_FIREBASE_CHANNEL=disabled \
  AEGIS_ACCESS_RELEASE_CHANNEL="$ACCESS_CHANNEL" \
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

python3 - "$RECEIPT" "$VERSION" "$BUILD" "$ARCHIVE" "$SIGNED" "$PROFILE" <<'PY'
import json, plistlib, sys
path, version, build, archive, signed, profile = sys.argv[1:]
app = __import__("pathlib").Path(archive) / "Products/Applications/Aegis.app/Info.plist"
stamped = plistlib.loads(app.read_bytes()).get("AegisReleaseProfile")
if stamped != profile:
    raise SystemExit(f"archive profile is {stamped}, expected {profile}")
json.dump({
    "product": "ios-alpha",
    "profile": profile,
    "audience": "development-self-test",
    "version": version,
    "build": build,
    "archive": archive,
    "signed": signed == "true",
    "testFlight": False,
    "appStoreUpload": False,
    "reviewSubmission": False,
    "reason": "0.8.0 alpha is for development self-test. The closed train blocks review submission only.",
}, open(path, "w"), indent=2)
print(path)
PY
echo "IOS_INTERNAL_ARCHIVE=$ARCHIVE"
