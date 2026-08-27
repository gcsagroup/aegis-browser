#!/usr/bin/env bash
# Seed overlay into Chromium src and emit patches/0001-*.patch + series entry.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_depot_tools_on_path
SRC="$CHROMIUM_ROOT/src"
OVERLAY="$ROOT_DIR/overlay"
PATCHES="$ROOT_DIR/patches"

if [[ ! -d "$SRC/.git" ]]; then
  echo "Chromium src missing at $SRC"
  exit 1
fi

cd "$SRC"

# Clean any previous aegis WIP on this branch tip
if git rev-parse --verify aegis-wip >/dev/null 2>&1; then
  git branch -D aegis-wip >/dev/null 2>&1 || true
fi

# Ensure clean-ish: abort mid-rebase/am if any
git am --abort >/dev/null 2>&1 || true
git rebase --abort >/dev/null 2>&1 || true

# Start from pinned HEAD
git checkout --detach HEAD
git checkout -B aegis-wip

echo "Copying overlay…"
mkdir -p chrome/browser/aegis chrome/common/aegis
cp -R "$OVERLAY/chrome/browser/aegis/." chrome/browser/aegis/
cp -R "$OVERLAY/chrome/common/aegis/." chrome/common/aegis/

# Wire //chrome/browser/aegis into chrome_browser_main
if ! grep -q '//chrome/browser/aegis' chrome/browser/BUILD.gn; then
  python3 - <<'PY'
from pathlib import Path
path = Path("chrome/browser/BUILD.gn")
text = path.read_text()
needle = 'source_set("chrome_browser_main") {'
idx = text.find(needle)
if idx < 0:
    raise SystemExit("chrome_browser_main target not found")
# Insert dep near the start of deps = [ inside that target
# Find first deps = [ after the target
deps_idx = text.find("deps = [", idx)
if deps_idx < 0:
    raise SystemExit("deps not found in chrome_browser_main")
insert_at = text.find("\n", deps_idx) + 1
line = '    "//chrome/browser/aegis",\n'
if '//chrome/browser/aegis' not in text[idx:idx+2000]:
    text = text[:insert_at] + line + text[insert_at:]
    path.write_text(text)
    print("BUILD.gn: added //chrome/browser/aegis dep")
else:
    print("BUILD.gn: dep already present")
PY
fi

# Hook InitializeForProfile after ProfileInitManager creation
if ! grep -q 'aegis/aegis_service.h' chrome/browser/chrome_browser_main.cc; then
  python3 - <<'PY'
from pathlib import Path
path = Path("chrome/browser/chrome_browser_main.cc")
text = path.read_text()
include = '#include "chrome/browser/aegis/aegis_service.h"\n'
# Place after other chrome/browser includes — after the first block of includes
if include not in text:
    # Insert after chrome_browser_main.h include
    marker = '#include "chrome/browser/chrome_browser_main.h"\n'
    if marker not in text:
        raise SystemExit("include marker missing")
    text = text.replace(marker, marker + include, 1)

hook = """
  if (profile) {
    aegis::AegisService::GetInstance()->InitializeForProfile(profile);
  }
"""
anchor = "  profile_init_manager_ = std::make_unique<ProfileInitManager>(this, profile);\n"
if "AegisService::GetInstance" not in text:
    if anchor not in text:
        raise SystemExit("ProfileInitManager anchor missing")
    text = text.replace(anchor, anchor + hook, 1)

path.write_text(text)
print("chrome_browser_main.cc: hooked AegisService")
PY
fi

# Need base/memory/singleton include in service cc (already via header)
# Add missing include in .cc for FeatureList via features.h — ok

git add chrome/browser/aegis chrome/common/aegis \
  chrome/browser/BUILD.gn chrome/browser/chrome_browser_main.cc

git -c user.email="aegis@gcsa.local" -c user.name="GCSA-aegis" commit -m "$(cat <<'EOF'
Aegis: add stub service and feature flags

Land chrome/browser/aegis + chrome/common/aegis and initialize the
browser-process service once the startup Profile is ready.
EOF
)"

mkdir -p "$PATCHES"
rm -f "$PATCHES"/0001-*.patch
git format-patch -1 -o "$PATCHES"
PATCH_FILE="$(ls "$PATCHES"/0001-*.patch | head -1)"
PATCH_BASE="$(basename "$PATCH_FILE")"

# Rewrite series
{
  echo "# Patch series (one file per line, applied in order)"
  echo "$PATCH_BASE"
} > "$PATCHES/series"

echo "Wrote $PATCH_FILE"
echo "Listed in patches/series"
echo "Next: pnpm --filter @gcsa-aegis/browser apply-patches && build"
