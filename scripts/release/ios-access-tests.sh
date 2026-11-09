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
printf 'Using destination %s\n' "$DESTINATION"
xcodebuild test \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -destination "$DESTINATION" \
  -only-testing:AccessKitTests \
  -only-testing:AegisTests/AccessSiteProxyToggleModelTests \
  CODE_SIGNING_ALLOWED=YES
