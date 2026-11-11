#!/usr/bin/env bash
# Build AegisEmbeddedCore.xcframework into EmbeddedCore/Products and verify
# slice digests against the frozen lock. Used by clean CI archives.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="${1:-$ROOT/apps/ios/EmbeddedCore/embedded-core-lock.json}"
PRODUCTS="${2:-$ROOT/apps/ios/EmbeddedCore/Products}"
XCFW="$PRODUCTS/AegisEmbeddedCore.xcframework"

[[ -f "$LOCK" ]] || { echo "missing lock: $LOCK" >&2; exit 2; }

status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$LOCK")"
if [[ "$status" != "verified_build" ]]; then
  echo "lock status must be verified_build for archive prepare (got $status)" >&2
  exit 2
fi

"$ROOT/scripts/release/build-ios-access-core.sh" --lock "$LOCK" --output "$PRODUCTS"
[[ -d "$XCFW" ]] || { echo "missing xcframework after build: $XCFW" >&2; exit 2; }

python3 - "$LOCK" "$XCFW" <<'PY'
import hashlib, json, sys
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
arts = lock.get("artifacts") or {}
expected = {
    "ios-arm64": arts.get("iosArm64Sha256"),
    "ios-arm64-simulator": arts.get("iosArm64SimulatorSha256"),
}
missing = [k for k, v in expected.items() if not v]
if missing:
    raise SystemExit("lock missing artifact digests: " + ", ".join(missing))

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
        raise SystemExit(f"digest mismatch for {key}: lock={want} built={got}")
print("verified AegisEmbeddedCore.xcframework digests against lock")
PY
