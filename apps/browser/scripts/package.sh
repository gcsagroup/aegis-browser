#!/usr/bin/env bash
# Package a distributable GCSA-aegis Mac .app (+ zip/dmg).
#
# Expects a non-component build (self-contained Chromium.app).
# Dev component builds are refused unless ALLOW_COMPONENT_PACKAGE=1.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SRC="$CHROMIUM_ROOT/src"
# Prefer release out dir when present.
if [[ -z "${OUT_DIR:-}" ]]; then
  if [[ -d "$SRC/out/AegisRelease/Chromium.app" ]]; then
    OUT="$SRC/out/AegisRelease"
  else
    OUT="$SRC/out/Aegis"
  fi
else
  OUT="$OUT_DIR"
fi

VERSION="$(read_pinned_value "$VERSION_FILE" 2>/dev/null || echo "0.0.0")"
APP_VERSION="${AEGIS_PACKAGE_VERSION:-0.1.0}"
CPU="$(uname -m)"
STAMP="$(date -u +%Y%m%d)"
DIST_ROOT="${DIST_DIR:-$ROOT_DIR/dist}"
PRODUCT_APP_NAME="GCSA-aegis.app"
BUNDLE_NAME="GCSA-aegis-${APP_VERSION}-chromium-${VERSION}-mac-${CPU}"
STAGE="$DIST_ROOT/$BUNDLE_NAME"
FORMATS="${PACKAGE_FORMATS:-app,zip,dmg}"

if [[ ! -d "$OUT/Chromium.app" ]]; then
  echo "Missing $OUT/Chromium.app"
  echo "Build a distributable app first:"
  echo "  pnpm --filter @gcsa-aegis/browser build:release"
  exit 1
fi

component=0
if grep -Eq 'is_component_build\s*=\s*true' "$OUT/args.gn" 2>/dev/null; then
  component=1
fi

if [[ "$component" -eq 1 && "${ALLOW_COMPONENT_PACKAGE:-0}" != "1" ]]; then
  cat <<EOF
Refusing to package a component build as a single .app.

Current out: $OUT (is_component_build=true)
That layout needs Chromium.app + hundreds of sibling .dylibs — not a real
distributable.

Do this instead:
  pnpm --filter @gcsa-aegis/browser build:release
  pnpm --filter @gcsa-aegis/browser package

(Or set ALLOW_COMPONENT_PACKAGE=1 for the old multi-file folder package.)
EOF
  exit 1
fi

echo "Packaging from $OUT"
echo "  component_build=$component"
echo "  stage=$STAGE"

rm -rf "$STAGE"
mkdir -p "$STAGE"

copy_tree() {
  ditto "$1" "$2"
}

if [[ "$component" -eq 1 ]]; then
  # Legacy multi-file package (dev only).
  copy_tree "$OUT/Chromium.app" "$STAGE/Chromium.app"
  shopt -s nullglob
  for helper in "$OUT"/Chromium\ Helper*.app; do
    copy_tree "$helper" "$STAGE/$(basename "$helper")"
  done
  for lib in "$OUT"/*.dylib; do
    cp -p "$lib" "$STAGE/"
  done
  for f in icudtl.dat v8_context_snapshot.bin snapshot_blob.bin; do
    [[ -f "$OUT/$f" ]] && cp -p "$OUT/$f" "$STAGE/"
  done
  for d in locales resources MEIPreload PrivacySandboxAttestationsPreloaded; do
    [[ -d "$OUT/$d" ]] && copy_tree "$OUT/$d" "$STAGE/$d"
  done
  shopt -u nullglob
  APP_PATH="$STAGE/Chromium.app"
  bash "$ROOT_DIR/scripts/sign-chromium-app.sh" "$APP_PATH" "$STAGE"
else
  # Single self-contained app.
  copy_tree "$OUT/Chromium.app" "$STAGE/$PRODUCT_APP_NAME"
  APP_PATH="$STAGE/$PRODUCT_APP_NAME"
  # Display name in Finder/Dock (internal helper binaries stay Chromium-named).
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName GCSA-aegis" \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string GCSA-aegis" \
      "$APP_PATH/Contents/Info.plist" || true
  bash "$ROOT_DIR/scripts/sign-chromium-app.sh" "$APP_PATH" "$STAGE"
fi

cat > "$STAGE/README.txt" <<EOF
GCSA-aegis (Chromium fork)
=========================

Version:     $APP_VERSION
Chromium:    $VERSION
Arch:        $CPU
Built:       $STAMP (UTC)
Component:   $component

Run: open $PRODUCT_APP_NAME

If macOS says the app is damaged:
  xattr -cr "$PRODUCT_APP_NAME"
  then right-click → Open

Ad-hoc signed only (not notarized).
EOF

if [[ "$component" -eq 0 ]]; then
  cat > "$STAGE/Open GCSA-aegis.command" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "\$(dirname "\$0")"
xattr -cr "./$PRODUCT_APP_NAME" 2>/dev/null || true
open "./$PRODUCT_APP_NAME"
EOF
else
  cat > "$STAGE/Open GCSA-aegis.command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
xattr -cr . 2>/dev/null || true
open "./Chromium.app"
EOF
fi
chmod +x "$STAGE/Open GCSA-aegis.command"

mkdir -p "$DIST_ROOT"
SIZE_MB="$(du -sm "$STAGE" | awk '{print $1}')"
echo "Staged ${SIZE_MB} MB → $STAGE"

# Also expose a top-level .app copy for convenience when non-component.
if [[ "$component" -eq 0 ]]; then
  rm -rf "$DIST_ROOT/$PRODUCT_APP_NAME"
  ditto "$APP_PATH" "$DIST_ROOT/$PRODUCT_APP_NAME"
  echo "Copied $DIST_ROOT/$PRODUCT_APP_NAME"
fi

IFS=',' read -r -a formats <<< "$FORMATS"
for fmt in "${formats[@]}"; do
  fmt="$(echo "$fmt" | tr -d '[:space:]')"
  case "$fmt" in
    app)
      # Already staged / copied above.
      ;;
    zip)
      ZIP="$DIST_ROOT/${BUNDLE_NAME}.zip"
      rm -f "$ZIP"
      echo "Writing $ZIP …"
      if [[ "$component" -eq 0 ]]; then
        # Zip contains only the .app at top level.
        TMP_ZIP_DIR=$(mktemp -d)
        ditto "$APP_PATH" "$TMP_ZIP_DIR/$PRODUCT_APP_NAME"
        ditto -c -k --sequesterRsrc --keepParent "$TMP_ZIP_DIR/$PRODUCT_APP_NAME" "$ZIP"
        rm -rf "$TMP_ZIP_DIR"
      else
        ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
      fi
      ls -lh "$ZIP"
      ;;
    dmg)
      DMG="$DIST_ROOT/${BUNDLE_NAME}.dmg"
      rm -f "$DMG"
      echo "Writing $DMG …"
      if [[ "$component" -eq 0 ]]; then
        TMP_DMG_DIR=$(mktemp -d)
        ditto "$APP_PATH" "$TMP_DMG_DIR/$PRODUCT_APP_NAME"
        ln -s /Applications "$TMP_DMG_DIR/Applications"
        hdiutil create \
          -volname "GCSA-aegis" \
          -srcfolder "$TMP_DMG_DIR" \
          -ov -format UDZO \
          "$DMG"
        rm -rf "$TMP_DMG_DIR"
      else
        hdiutil create \
          -volname "GCSA-aegis" \
          -srcfolder "$STAGE" \
          -ov -format UDZO \
          "$DMG"
      fi
      ls -lh "$DMG"
      ;;
    '')
      ;;
    *)
      echo "Unknown PACKAGE_FORMATS entry: $fmt (use app, zip, dmg)"
      exit 1
      ;;
  esac
done

echo "Done. Artifacts under $DIST_ROOT"
