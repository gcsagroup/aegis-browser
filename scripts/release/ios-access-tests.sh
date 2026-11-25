#!/usr/bin/env bash
# Simulator Access tests for the fork. No App Store signing and no upload.
# A missing, failed, or skipped expected case is a gate failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TEST_ROOTS=(--root apps/ios/Tests/AccessKitTests --root apps/ios/Tests/AegisTests)
CLASS_FILTER="${AEGIS_IOS_ACCESS_TEST_CLASSES:-}"
SELECTORS="$(python3 -B scripts/release/ios_access_test_gate.py "${TEST_ROOTS[@]}" --selection "$CLASS_FILTER")"
ONLY=()
while IFS= read -r selector; do
  ONLY+=(-only-testing:"AegisTests/${selector}")
done <<< "$SELECTORS"

if ! command -v xcodebuild >/dev/null 2>&1; then
  printf 'iOS Access simulator tests need xcodebuild on the self-hosted Mac.\n' >&2
  exit 2
fi

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec apps/ios/project.yml
fi

if [[ -n "${AEGIS_IOS_DESTINATION:-}" ]]; then
  DESTINATION="$AEGIS_IOS_DESTINATION"
else
  DESTINATION="$(python3 - <<'PY'
import json, subprocess, sys
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
phones = []
for runtime, devices in json.loads(raw).get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") is False:
            continue
        name = device.get("name", "")
        if name.startswith("iPhone"):
            phones.append(name)
if not phones:
    sys.exit("No available iPhone simulator")
for name in ("iPhone 16", "iPhone 17", "iPhone 15"):
    if name in phones:
        print(f"platform=iOS Simulator,name={name}")
        break
else:
    print(f"platform=iOS Simulator,name={phones[0]}")
PY
)"
fi

STAMP="$(date +%Y%m%d%H%M%S)"
RUN_ROOT="${AEGIS_IOS_ACCESS_RUN_ROOT:-$ROOT/.artifacts/ios-access-tests/$STAMP}"
mkdir -p "$RUN_ROOT"
LOG="$RUN_ROOT/xcodebuild.log"
RESULT="$RUN_ROOT/result.xcresult"

PRODUCTS="${AEGIS_EMBEDDED_CORE_PRODUCTS:-$RUN_ROOT/EmbeddedCore}"
if [[ -n "${AEGIS_EMBEDDED_CORE_PRODUCTS:-}" ]]; then
  python3 -B scripts/release/ios_embedded_core.py verify --root "$ROOT" \
    --source-lock apps/ios/EmbeddedCore/embedded-core-lock.json --products "$PRODUCTS"
else
  bash scripts/release/prepare-ios-package-core.sh "$ROOT" "$PRODUCTS"
fi

printf 'Using destination %s\n' "$DESTINATION"
printf 'Run directory %s\n' "$RUN_ROOT"
set +e
xcodebuild test \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -destination "$DESTINATION" \
  -parallel-testing-enabled NO \
  "AEGIS_EMBEDDED_CORE_PRODUCTS=$PRODUCTS" \
  "${ONLY[@]}" \
  -resultBundlePath "$RESULT" \
  -derivedDataPath "$RUN_ROOT/DerivedData" \
  CODE_SIGNING_ALLOWED=YES | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

python3 scripts/release/ios_access_test_gate.py \
  --log "$LOG" \
  --status "$STATUS" \
  "${TEST_ROOTS[@]}" --selection "$CLASS_FILTER"
