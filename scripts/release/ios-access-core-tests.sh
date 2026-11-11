#!/usr/bin/env bash
# Opt-in K gate for in-process Access core (simulator or device destination).
# Missing lock / node / framework → NOT_RUN (non-zero). Never prints node secrets.
# Does not mark simulator results as device results. Not part of default U gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

usage() {
  cat >&2 <<'EOF'
usage: ios-access-core-tests.sh \
  --destination <xcodebuild destination> \
  --lock <embedded-core-lock.json> \
  --node-file <private Reality Vision uri/json> \
  --output <new evidence directory> [--products <verified build directory>]
EOF
  exit 2
}

DESTINATION=""
LOCK=""
NODE_FILE=""
OUTPUT=""
PRODUCTS="$ROOT/.artifacts/ios-embedded-core"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination) DESTINATION="${2:-}"; shift 2 ;;
    --lock) LOCK="${2:-}"; shift 2 ;;
    --node-file) NODE_FILE="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --products) PRODUCTS="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

[[ -n "$DESTINATION" && -n "$LOCK" && -n "$NODE_FILE" && -n "$OUTPUT" ]] || usage

if [[ -e "$OUTPUT/k-receipt.json" || -e "$OUTPUT/result.xcresult" || -e "$OUTPUT/xcodebuild.log" ]]; then
  printf 'Evidence already exists; use a new K output directory.\n' >&2
  exit 2
fi
mkdir -p "$OUTPUT"
RECEIPT="$OUTPUT/k-receipt.json"
LOG="$OUTPUT/xcodebuild.log"
RESULT="$OUTPUT/result.xcresult"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SOURCE_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
SOURCE_TREE="$(git rev-parse 'HEAD^{tree}' 2>/dev/null || echo unknown)"
PLATFORM_KIND="unknown"
case "$DESTINATION" in
  *Simulator*) PLATFORM_KIND="simulator" ;;
  *iOS*) PLATFORM_KIND="device" ;;
esac

write_receipt() {
  local status="$1"
  local detail="$2"
  python3 - "$RECEIPT" "$status" "$detail" "$STAMP" "$SOURCE_SHA" "$PLATFORM_KIND" "$LOCK" "$NODE_FILE" "$OUTPUT" "$SOURCE_TREE" "${STATUS:-}" <<'PY'
import json, hashlib, os, sys
path, status, detail, stamp, sha, platform, lock, node, output, tree, exit_code = sys.argv[1:]
from pathlib import Path

def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

lock_digest = None
lock_status = None
slices = {}
if os.path.isfile(lock):
    lock_digest = sha256_file(lock)
    try:
        root = json.load(open(lock, encoding="utf-8"))
        lock_status = root.get("status")
    except Exception:
        lock_status = "unreadable"

build_inputs = Path(output) / "build-inputs.json"
verified = json.loads(build_inputs.read_text()) if build_inputs.is_file() else None
live_tests = Path(output) / "live-tests.json"
leaves = json.loads(live_tests.read_text()) if live_tests.is_file() else None
summary_path = Path(output) / "xcresult-summary.json"
summary = json.loads(summary_path.read_text()) if summary_path.is_file() and summary_path.stat().st_size else {}
receipt = {
    "schemaVersion": 1,
    "kind": "ios-access-core-k-receipt",
    "status": status,
    "detail": detail,
    "recordedAt": stamp,
    "candidate": {"sourceSha": sha, "sourceTree": tree, "platformKind": platform},
    "inputs": {
        "lockPathName": os.path.basename(lock),
        "lockSha256": lock_digest,
        "lockStatus": lock_status,
        "nodePathName": os.path.basename(node),
        "nodePresent": os.path.isfile(node),
        # Never record node bytes or parsed credentials.
    },
    "embeddedCoreSlices": verified["slices"] if verified else {},
    "verifiedBuildInputs": verified,
    "liveTests": leaves,
    "testExecution": {
        "xcodebuildExit": int(exit_code) if exit_code else None,
        **{key: summary.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests",
                                             "devicesAndConfigurations")},
    },
    "notes": [
        "Desensitized receipt only; no UUID/publicKey/shortId/URL contents.",
        "simulator results must not be labeled device.",
    ],
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(receipt, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

not_run() {
  local detail="$1"
  write_receipt "NOT_RUN" "$detail"
  printf 'NOT_RUN: %s\n' "$detail" >&2
  printf 'receipt %s\n' "$RECEIPT" >&2
  exit 3
}

[[ -f "$LOCK" ]] || not_run "lock file missing"
[[ -f "$NODE_FILE" ]] || not_run "node file missing"

python3 - "$LOCK" <<'PY' || not_run "lock is not verified_build with both slice digests"
import json, sys
root = json.load(open(sys.argv[1], encoding="utf-8"))
assert root.get("status") == "verified_build"
arts = root.get("artifacts") or {}
assert arts.get("iosArm64Sha256") and arts.get("iosArm64SimulatorSha256")
PY

XCFW="$PRODUCTS/AegisEmbeddedCore.xcframework"
[[ -d "$XCFW" ]] || not_run "AegisEmbeddedCore.xcframework missing (build locally first)"
if ! python3 -B scripts/release/ios_embedded_core.py verify --root "$ROOT" \
  --source-lock "$LOCK" --products "$PRODUCTS" --output "$OUTPUT/build-inputs.json"; then
  write_receipt "FAIL" "actual EmbeddedCore slices / bundled lock differ from the build manifest"
  exit 4
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  not_run "xcodebuild not available"
fi

cp "$OUTPUT/build-inputs.json" "$OUTPUT/build-inputs-before.json"
export AEGIS_ACCESS_LOCAL_V2RAY_CONFIG="$NODE_FILE"
export AEGIS_ACCESS_LOCAL_V2RAY_LIVE=1
export TEST_RUNNER_AEGIS_ACCESS_LOCAL_V2RAY_CONFIG="$NODE_FILE"
export TEST_RUNNER_AEGIS_ACCESS_LOCAL_V2RAY_LIVE=1

set +e
xcodebuild test -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO \
  -clonedSourcePackagesDirPath "${AEGIS_IOS_SOURCE_PACKAGES:-$OUTPUT/SourcePackages}" \
  -packageCachePath "${AEGIS_IOS_PACKAGE_CACHE:-$OUTPUT/PackageCache}" \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -destination "$DESTINATION" \
  -only-testing:"AegisTests/AccessEmbeddedCoreLiveTests" \
  -only-testing:"AegisTests/AccessEmbeddedCoreAdapterTests" \
  -only-testing:"AegisTests/AccessEmbeddedCoreManifestTests" \
  -resultBundlePath "$RESULT" \
  -derivedDataPath "$OUTPUT/DerivedData" \
  AEGIS_EMBEDDED_CORE_PRODUCTS="$PRODUCTS" \
  CODE_SIGNING_ALLOWED=YES | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

SUMMARY_STATUS=0
xcrun xcresulttool get test-results summary --path "$RESULT" > "$OUTPUT/xcresult-summary.json" || SUMMARY_STATUS=$?
LEAF_STATUS=0
if ! xcrun xcresulttool get test-results tests --path "$RESULT" > "$OUTPUT/xcresult-tests.json" \
  || ! python3 -B scripts/release/ios_access_core_gate.py \
    --tests "$OUTPUT/xcresult-tests.json" --output "$OUTPUT/live-tests.json"; then
  LEAF_STATUS=4
fi
if [[ "$STATUS" -ne 0 ]]; then
  write_receipt "FAIL" "xcodebuild exit $STATUS ($PLATFORM_KIND); see xcodebuild.log"
  printf 'FAIL: xcodebuild exit %s\n' "$STATUS" >&2
  exit "$STATUS"
fi

# Retain the exact leaf results. Summary totals and suite names cannot satisfy K.
if [[ "$LEAF_STATUS" -ne 0 || "$SUMMARY_STATUS" -ne 0 ]]; then
  write_receipt "FAIL" "one or more required live K leaves are missing, failed, or skipped ($PLATFORM_KIND)"
  exit 4
fi
if [[ "$PLATFORM_KIND" == simulator ]]; then
  TEST_APP="$OUTPUT/DerivedData/Build/Products/Debug-iphonesimulator/Aegis.app"
else
  TEST_APP="$OUTPUT/DerivedData/Build/Products/Debug-iphoneos/Aegis.app"
fi
# Verify once more so a changed input cannot acquire a successful execution receipt.
python3 -B scripts/release/ios_embedded_core.py verify --root "$ROOT" \
  --source-lock "$LOCK" --products "$PRODUCTS" --bundle "$TEST_APP" --derived "$OUTPUT/DerivedData" --platform "$PLATFORM_KIND" --output "$OUTPUT/build-inputs.json" || {
    write_receipt "FAIL" "EmbeddedCore build inputs changed during the K run"
    exit 4
  }
if ! python3 - "$OUTPUT" <<'PYVERIFY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
before = json.loads((root / "build-inputs-before.json").read_text())
after = json.loads((root / "build-inputs.json").read_text())
assert all(after.get(key) == value for key, value in before.items())
PYVERIFY
then
  write_receipt "FAIL" "EmbeddedCore identity changed during the K run"
  exit 4
fi
write_receipt "PASS" "all three required live K leaves passed with verified EmbeddedCore inputs ($PLATFORM_KIND)"
printf 'PASS (%s). receipt %s\n' "$PLATFORM_KIND" "$RECEIPT"
