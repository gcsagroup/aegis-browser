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
  --output <evidence directory>
EOF
  exit 2
}

DESTINATION=""
LOCK=""
NODE_FILE=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination) DESTINATION="${2:-}"; shift 2 ;;
    --lock) LOCK="${2:-}"; shift 2 ;;
    --node-file) NODE_FILE="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

[[ -n "$DESTINATION" && -n "$LOCK" && -n "$NODE_FILE" && -n "$OUTPUT" ]] || usage

mkdir -p "$OUTPUT"
RECEIPT="$OUTPUT/k-receipt.json"
LOG="$OUTPUT/xcodebuild.log"
RESULT="$OUTPUT/result.xcresult"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SOURCE_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
PLATFORM_KIND="unknown"
case "$DESTINATION" in
  *Simulator*) PLATFORM_KIND="simulator" ;;
  *iOS*) PLATFORM_KIND="device" ;;
esac

write_receipt() {
  local status="$1"
  local detail="$2"
  python3 - "$RECEIPT" "$status" "$detail" "$STAMP" "$SOURCE_SHA" "$PLATFORM_KIND" "$LOCK" "$NODE_FILE" <<'PY'
import json, hashlib, os, sys
path, status, detail, stamp, sha, platform, lock, node = sys.argv[1:]

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
        arts = root.get("artifacts") or {}
        for key in ("iosArm64Sha256", "iosArm64SimulatorSha256"):
            if arts.get(key):
                slices[key] = arts[key]
    except Exception:
        lock_status = "unreadable"

receipt = {
    "schemaVersion": 1,
    "kind": "ios-access-core-k-receipt",
    "status": status,
    "detail": detail,
    "recordedAt": stamp,
    "candidate": {"sourceSha": sha, "platformKind": platform},
    "inputs": {
        "lockPathName": os.path.basename(lock),
        "lockSha256": lock_digest,
        "lockStatus": lock_status,
        "nodePathName": os.path.basename(node),
        "nodePresent": os.path.isfile(node),
        # Never record node bytes or parsed credentials.
    },
    "embeddedCoreSlices": slices,
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

XCFW="$ROOT/apps/ios/EmbeddedCore/Products/AegisEmbeddedCore.xcframework"
[[ -d "$XCFW" ]] || not_run "AegisEmbeddedCore.xcframework missing under EmbeddedCore/Products (build locally first)"

if ! command -v xcodebuild >/dev/null 2>&1; then
  not_run "xcodebuild not available"
fi

export AEGIS_ACCESS_LOCAL_V2RAY_CONFIG="$NODE_FILE"
export AEGIS_ACCESS_LOCAL_V2RAY_LIVE=1

rm -rf "$RESULT"
set +e
xcodebuild test \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -destination "$DESTINATION" \
  -only-testing:"AegisTests/AccessEmbeddedCoreLiveTests" \
  -only-testing:"AegisTests/AccessEmbeddedCoreAdapterTests" \
  -only-testing:"AegisTests/AccessEmbeddedCoreManifestTests" \
  -resultBundlePath "$RESULT" \
  -derivedDataPath "$OUTPUT/DerivedData" \
  CODE_SIGNING_ALLOWED=YES \
  TEST_RUNNER_AEGIS_ACCESS_LOCAL_V2RAY_CONFIG="$NODE_FILE" \
  TEST_RUNNER_AEGIS_ACCESS_LOCAL_V2RAY_LIVE=1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

if [[ "$STATUS" -eq 0 ]]; then
  write_receipt "PASS" "AccessEmbeddedCore live/adapter/manifest tests exited 0 ($PLATFORM_KIND)"
  printf 'PASS (%s). receipt %s\n' "$PLATFORM_KIND" "$RECEIPT"
  exit 0
fi

write_receipt "FAIL" "xcodebuild exit $STATUS ($PLATFORM_KIND); see xcodebuild.log"
printf 'FAIL: xcodebuild exit %s\n' "$STATUS" >&2
exit "$STATUS"
