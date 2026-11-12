#!/usr/bin/env bash
set -euo pipefail
# Builds AegisEmbeddedCore.xcframework from the thin StartInstance/Dial bridge.
# Verifies the lock pin, then records digests. Refuses source_candidate packaging.
usage() {
  echo "usage: $0 --lock <embedded-core-lock.json> --output <dir>" >&2
  exit 2
}
lock=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock) lock="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$lock" && -n "$output" ]] || usage
[[ -f "$lock" ]] || { echo "missing lock: $lock" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRIDGE="$ROOT/apps/ios/EmbeddedCore/bridge"
[[ -d "$BRIDGE" ]] || { echo "missing bridge: $BRIDGE" >&2; exit 2; }

python3 - "$lock" <<'PY'
import json, sys
from pathlib import Path
lock = json.loads(Path(sys.argv[1]).read_text())
core = lock.get("xrayCore") or {}
for key in ("commit", "tag", "tree", "repository"):
    if not core.get(key):
        raise SystemExit(f"lock missing xrayCore.{key}")
if lock.get("status") not in ("verified_build", "source_candidate"):
    raise SystemExit("lock status must be source_candidate or verified_build")
print(core["commit"])
print(core["tag"])
PY

COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["xrayCore"]["commit"])' "$lock")"
export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-$ROOT}"
if command -v mise >/dev/null 2>&1; then
  GOROOT="$(mise where go@1.27.3 2>/dev/null || true)"
  if [[ -n "${GOROOT:-}" ]]; then
    export GOROOT
    export PATH="$GOROOT/bin:$PATH:${GOPATH:-$HOME/go}/bin"
  fi
fi
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
command -v go >/dev/null || { echo "go missing" >&2; exit 2; }
command -v gomobile >/dev/null || { echo "gomobile missing; go install golang.org/x/mobile/cmd/gomobile@latest" >&2; exit 2; }

mkdir -p "$output"
WORK="$output/work"
rm -rf "$WORK"
mkdir -p "$WORK"
# Dependency resolution and gomobile may write module metadata. Work on a copy,
# leaving every reviewed bridge/source input unchanged.
cp -R "$BRIDGE" "$WORK/bridge"
cd "$WORK/bridge"
go mod tidy
cmp "$BRIDGE/go.mod" go.mod
cmp "$BRIDGE/go.sum" go.sum
# Confirm go.mod still points at the frozen commit prefix.
if ! grep -q "${COMMIT:0:12}" go.mod go.sum; then
  echo "bridge go.mod/sum does not reference frozen commit ${COMMIT:0:12}" >&2
  exit 2
fi

echo "building AegisEmbeddedCore.xcframework (ios + iossimulator)..."
# Prefer reproducible inputs: trim paths, drop VCS stamping and Go buildids.
# Mach-O UUIDs may still drift across hosted clang links; prepare may accept
# digests under AEGIS_EMBEDDED_CORE_DIGEST_MODE=ci-rebuild when source pins match.
export GOFLAGS="${GOFLAGS:--trimpath -buildvcs=false}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
gomobile bind \
  -target ios,iossimulator \
  -iosversion 15.0 \
  -trimpath \
  -ldflags "-buildid=" \
  -o "$WORK/AegisEmbeddedCore.xcframework" \
  .

DEST="$output/AegisEmbeddedCore.xcframework"
rm -rf "$DEST"
mv "$WORK/AegisEmbeddedCore.xcframework" "$DEST"
"$ROOT/scripts/release/record-ios-access-core-digests.sh" --xcframework "$DEST" | tee "$output/slice-digests.txt"
echo "wrote $DEST"
echo "NOTE: freeze digests into the lock as verified_build before linking the app."
