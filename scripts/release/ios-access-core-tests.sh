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

if [[ "$STATUS" -ne 0 ]]; then
  write_receipt "FAIL" "xcodebuild exit $STATUS ($PLATFORM_KIND); see xcodebuild.log"
  printf 'FAIL: xcodebuild exit %s\n' "$STATUS" >&2
  exit "$STATUS"
fi

# Exit 0 with every live case skipped must not become a K PASS (device config often invisible).
# Prefer per-test results (`test-results tests`) over summary aggregates.
LIVE_SUMMARY="$(
  python3 - "$RESULT" <<'PY'
import json, subprocess, sys
from pathlib import Path
result = Path(sys.argv[1])
if not result.exists():
    print("MISSING")
    raise SystemExit(0)

def run_xcresult(*args):
    return subprocess.check_output(
        ["xcrun", "xcresulttool", *args, "--path", str(result)],
        stderr=subprocess.DEVNULL,
        text=True,
    )

raw = None
for args in (
    ("get", "test-results", "tests"),
    ("get", "test-results", "summary"),
):
    try:
        raw = run_xcresult(*args)
        break
    except Exception:
        continue
if raw is None:
    print("UNREADABLE")
    raise SystemExit(0)

try:
    data = json.loads(raw)
except Exception:
    print("UNREADABLE")
    raise SystemExit(0)

live_markers = (
    "accessembeddedcorelivetests",
    "aegistests/accessembeddedcorelivetests",
)
required_live = []

def is_live_name(name: str) -> bool:
    lowered = name.lower()
    return any(marker in lowered for marker in live_markers)

def status_of(node: dict) -> str:
    for key in ("result", "status", "testStatus", "outcome"):
        value = node.get(key)
        if value is None:
            continue
        if isinstance(value, dict):
            value = value.get("_value") or value.get("value")
        text = str(value).lower()
        if text:
            return text
    return ""

def name_of(node: dict) -> str:
    for key in ("identifier", "name", "testName", "testIdentifier", "nodeIdentifier"):
        value = node.get(key)
        if value is None:
            continue
        if isinstance(value, dict):
            value = value.get("_value") or value.get("value") or value.get("identifier")
        text = str(value)
        if text:
            return text
    return ""

def walk(node, acc):
    if isinstance(node, dict):
        name = name_of(node)
        status = status_of(node)
        # Prefer leaf tests: nodes that look like XCTest cases under LiveTests.
        if name and is_live_name(name) and (
            "test" in name.lower()
            or status in {"passed", "success", "succeeded", "failed", "skipped", "expected failure"}
        ):
            # Skip pure suite containers that only mirror the class name.
            leafish = "/" in name or name.lower().count("test") >= 2 or status in {
                "passed", "success", "succeeded", "failed", "skipped", "expected failure"
            }
            if leafish and not name.lower().endswith("accessembeddedcorelivetests"):
                acc.append((name, status))
            elif leafish and status in {"passed", "success", "succeeded", "failed", "skipped"}:
                acc.append((name, status))
        for value in node.values():
            walk(value, acc)
    elif isinstance(node, list):
        for item in node:
            walk(item, acc)

walk(data, required_live)
# Deduplicate while preserving order.
seen = set()
live_hits = []
for name, status in required_live:
    key = (name.lower(), status)
    if key in seen:
        continue
    seen.add(key)
    live_hits.append((name, status))

if not live_hits:
    print("NO_LIVE_SIGNAL")
elif all(("skip" in status or status in {"expected failure", "unknown", ""}) for _, status in live_hits):
    print("ALL_SKIPPED")
elif any(status in {"success", "passed", "succeeded"} for _, status in live_hits):
    print("EXECUTED")
else:
    print("NO_LIVE_SIGNAL")
PY
)"

case "$LIVE_SUMMARY" in
  EXECUTED)
    write_receipt "PASS" "AccessEmbeddedCore live/adapter/manifest tests exited 0 with executed live cases ($PLATFORM_KIND)"
    printf 'PASS (%s). receipt %s\n' "$PLATFORM_KIND" "$RECEIPT"
    exit 0
    ;;
  ALL_SKIPPED)
    write_receipt "FAIL" "live AccessEmbeddedCore tests were all skipped ($PLATFORM_KIND); refusing K PASS"
    printf 'FAIL: live tests all skipped (%s)\n' "$PLATFORM_KIND" >&2
    exit 4
    ;;
  *)
    write_receipt "FAIL" "could not verify live AccessEmbeddedCore execution from xcresult ($PLATFORM_KIND: $LIVE_SUMMARY)"
    printf 'FAIL: live execution unverified (%s: %s)\n' "$PLATFORM_KIND" "$LIVE_SUMMARY" >&2
    exit 4
    ;;
esac
