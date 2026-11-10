#!/usr/bin/env bash
set -euo pipefail
# Records SHA-256 for ios-arm64 and ios-arm64-simulator slices.
# Does not mutate the lock; prints digests for a human freeze step.
usage() {
  echo "usage: $0 --xcframework <AegisEmbeddedCore.xcframework>" >&2
  exit 2
}
xcframework=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --xcframework) xcframework="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$xcframework" && -d "$xcframework" ]] || usage

python3 - "$xcframework" <<'PY'
import hashlib, sys
from pathlib import Path

root = Path(sys.argv[1])
wanted = {
    "ios-arm64": None,
    "ios-arm64-simulator": None,
}
for slice_dir in sorted(p for p in root.iterdir() if p.is_dir()):
    name = slice_dir.name
    key = None
    if name == "ios-arm64":
        key = "ios-arm64"
    elif "simulator" in name and "arm64" in name:
        key = "ios-arm64-simulator"
    if key is None:
        continue
    binaries = sorted(p for p in slice_dir.rglob("*") if p.is_file() and not p.name.startswith("."))
    if not binaries:
        raise SystemExit(f"empty slice: {slice_dir}")
    h = hashlib.sha256()
    for path in binaries:
        h.update(path.relative_to(slice_dir).as_posix().encode())
        h.update(b"\0")
        h.update(path.read_bytes())
        h.update(b"\0")
    wanted[key] = h.hexdigest()

missing = [k for k, v in wanted.items() if not v]
if missing:
    raise SystemExit("missing slices: " + ", ".join(missing) + f" under {root}")
print(f"iosArm64Sha256={wanted['ios-arm64']}")
print(f"iosArm64SimulatorSha256={wanted['ios-arm64-simulator']}")
print("NOTE: only write these into the lock after accepting the build as verified_build.")
PY
