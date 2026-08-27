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
IDENTITY_ARTIFACTS=()
BUILD_MANIFEST="${AEGIS_BUILD_MANIFEST:-$OUT/.aegis/build-manifest.json}"
IDENTITY="$DIST_ROOT/${BUNDLE_NAME}.build-identity.json"
BUILD_LOCK="$OUT/.aegis/build.lock"
BUILD_IDENTITY_DIR="$OUT/.aegis"

safe_path_component() {
  local value="$1"
  [[ "$value" =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] && \
    [[ "$value" != *..* ]]
}
if ! safe_path_component "$VERSION" || ! safe_path_component "$APP_VERSION" || \
   ! safe_path_component "$CPU"; then
  echo "Unsafe version or architecture path component." >&2
  exit 1
fi
if [[ ! -d "$SRC" || -L "$SRC" ]]; then
  echo "Chromium source must be a real directory: $SRC" >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd -P)"
if [[ ! -d "$OUT" || -L "$OUT" ]]; then
  echo "Package OUT_DIR must be an existing real directory: $OUT" >&2
  exit 1
fi
OUT="$(cd "$OUT" && pwd -P)"
case "$OUT" in
  "$SRC"/out/*) ;;
  *)
    echo "Package OUT_DIR must be a strict child of $SRC/out" >&2
    exit 1
    ;;
esac

BUILD_MANIFEST="${AEGIS_BUILD_MANIFEST:-$OUT/.aegis/build-manifest.json}"
BUILD_LOCK="$OUT/.aegis/build.lock"
BUILD_IDENTITY_DIR="$OUT/.aegis"

if [[ ! -d "$OUT/Chromium.app" || -L "$OUT/Chromium.app" ]]; then
  echo "Missing real source App: $OUT/Chromium.app" >&2
  echo "Build a distributable app first." >&2
  exit 1
fi
if [[ ! -d "$BUILD_IDENTITY_DIR" || -L "$BUILD_IDENTITY_DIR" ]] || \
   [[ "$(cd "$BUILD_IDENTITY_DIR" 2>/dev/null && pwd -P)" != "$BUILD_IDENTITY_DIR" ]]; then
  echo "Package build identity directory must be a real child of OUT: $BUILD_IDENTITY_DIR" >&2
  exit 1
fi
if [[ ! -f "$BUILD_MANIFEST" || ! -f "$BUILD_MANIFEST.sha256" || \
      -L "$BUILD_MANIFEST" || -L "$BUILD_MANIFEST.sha256" ]]; then
  echo "Missing or unsafe finalized build identity: $BUILD_MANIFEST" >&2
  echo "Run build:release before packaging." >&2
  exit 1
fi
expected_build_sha="${AEGIS_BUILD_MANIFEST_SHA256:-}"
if [[ -z "$expected_build_sha" ]]; then
  if [[ "${AEGIS_ALLOW_DIRTY_IDENTITY:-0}" != "1" ]]; then
    echo "AEGIS_BUILD_MANIFEST_SHA256 is required for non-diagnostic packaging." >&2
    exit 1
  fi
  expected_build_sha="$(awk 'NR == 1 {print $1}' "$BUILD_MANIFEST.sha256")"
fi
if [[ ! "$expected_build_sha" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid build identity SHA-256: ${expected_build_sha:-missing}" >&2
  exit 1
fi

# 在 mkdir/rm/ditto 之前规范化分发根。叶子 symlink 与指入源 App/OUT
# 的父目录都必须先被拒绝，不能等打包后复验再发现源产物已损坏。
if [[ -L "$DIST_ROOT" ]]; then
  echo "DIST_DIR must not be a symlink: $DIST_ROOT" >&2
  exit 1
fi
dist_parent="$(dirname "$DIST_ROOT")"
dist_leaf="$(basename "$DIST_ROOT")"
if [[ ! -d "$dist_parent" || "$dist_leaf" == "." || \
      "$dist_leaf" == ".." || "$dist_leaf" == "/" ]]; then
  echo "DIST_DIR must have an existing parent and a safe leaf: $DIST_ROOT" >&2
  exit 1
fi
DIST_ROOT="$(cd "$dist_parent" && pwd -P)/$dist_leaf"
paths_overlap() {
  local first="$1"
  local second="$2"
  [[ "$first" == "$second" || "$first" == "$second/"* || \
     "$second" == "$first/"* ]]
}
manifest_parent="$(cd "$(dirname "$BUILD_MANIFEST")" && pwd -P)"
canonical_build_manifest="$manifest_parent/$(basename "$BUILD_MANIFEST")"
for protected_path in \
  "$SRC" "$OUT" "$OUT/Chromium.app" "$canonical_build_manifest"; do
  if paths_overlap "$DIST_ROOT" "$protected_path"; then
    echo "DIST_DIR must not overlap source, App, or build identity: $DIST_ROOT" >&2
    exit 1
  fi
done
STAGE="$DIST_ROOT/$BUNDLE_NAME"
IDENTITY="$DIST_ROOT/${BUNDLE_NAME}.build-identity.json"

# 格式和 component 适配也是写入前条件。任何 typo 或不可分发的
# component build 都必须在归档旧 identity、删除 stage 或签名前失败。
IFS=',' read -r -a requested_formats <<< "$FORMATS"
formats=()
for requested_format in "${requested_formats[@]}"; do
  fmt="$(printf '%s' "$requested_format" | tr -d '[:space:]')"
  case "$fmt" in
    app|zip|dmg) formats+=("$fmt") ;;
    '') ;;
    *)
      echo "Unknown PACKAGE_FORMATS entry: $fmt (use app, zip, dmg)" >&2
      exit 1
      ;;
  esac
done

component=0
if grep -Eq 'is_component_build\s*=\s*true' "$OUT/args.gn" 2>/dev/null; then
  component=1
fi
if [[ "$component" -eq 1 && "${ALLOW_COMPONENT_PACKAGE:-0}" != "1" ]]; then
  echo "Refusing to package a component build as a single .app: $OUT" >&2
  exit 1
fi

if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
  echo "Another build or package operation holds: $BUILD_LOCK" >&2
  exit 1
fi
release_build_lock() {
  rmdir "$BUILD_LOCK" 2>/dev/null || true
}
trap release_build_lock EXIT

# 在任何 dist 写入前验证构建时的两阶段清单。未显式提供摘要时读取构建
# 阶段生成的 sidecar；正式调用方可用 AEGIS_BUILD_MANIFEST_SHA256 固定摘要。
build_verification="$(node "$ROOT_DIR/scripts/write-build-identity.mjs" \
  --phase verify \
  --manifest "$BUILD_MANIFEST" \
  --expected-sha256 "$expected_build_sha" \
  --out-dir "$OUT" \
  --artifact "$OUT/Chromium.app")"
if [[ "${AEGIS_ALLOW_DIRTY_IDENTITY:-0}" != "1" ]]; then
  if ! BUILD_VERIFICATION="$build_verification" node -e '
    const value = JSON.parse(process.env.BUILD_VERIFICATION);
    if (!value.localCandidate) process.exit(1);
  '; then
    echo "Build identity is not a clean local candidate; refusing packaging." >&2
    echo "Set AEGIS_ALLOW_DIRTY_IDENTITY=1 only for an isolated local package." >&2
    exit 1
  fi
fi

mkdir -p "$DIST_ROOT"
if [[ "$(cd "$DIST_ROOT" && pwd -P)" != "$DIST_ROOT" ]]; then
  echo "DIST_DIR resolved unexpectedly after creation: $DIST_ROOT" >&2
  exit 1
fi

if [[ -L "$IDENTITY" || -L "$IDENTITY.sha256" ]]; then
  echo "Package identity files must not be symlinks: $IDENTITY" >&2
  exit 1
fi
if [[ -e "$IDENTITY" || -e "$IDENTITY.sha256" ]]; then
  if [[ "${AEGIS_REPLACE_PACKAGE_IDENTITY:-0}" != "1" ]]; then
    echo "Refusing to overwrite existing package identity: $IDENTITY" >&2
    exit 1
  fi
  package_identity_dir="$DIST_ROOT/.aegis"
  package_history_dir="$package_identity_dir/history"
  if [[ -L "$package_identity_dir" || -L "$package_history_dir" ]]; then
    echo "Package identity history must not use symlink directories: $package_history_dir" >&2
    exit 1
  fi
  mkdir -p "$package_history_dir"
  if [[ "$(cd "$package_identity_dir" && pwd -P)" != "$package_identity_dir" ]] || \
     [[ "$(cd "$package_history_dir" && pwd -P)" != "$package_history_dir" ]]; then
    echo "Package identity history resolves outside DIST_ROOT: $package_history_dir" >&2
    exit 1
  fi
  identity_history="$package_history_dir/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if [[ -e "$identity_history" || -L "$identity_history" ]] || \
     ! mkdir "$identity_history"; then
    echo "Refusing existing package identity history attempt: $identity_history" >&2
    exit 1
  fi
  if [[ "$(cd "$identity_history" && pwd -P)" != "$identity_history" ]]; then
    echo "Package identity history attempt resolves outside DIST_ROOT: $identity_history" >&2
    exit 1
  fi
  for identity_file in "$IDENTITY" "$IDENTITY.sha256"; do
    if [[ -f "$identity_file" ]]; then
      mv "$identity_file" "$identity_history/$(basename "$identity_file")"
    fi
  done
fi

echo "Packaging from $OUT"
echo "  component_build=$component"
echo "  stage=$STAGE"

if [[ -L "$STAGE" ]]; then
  echo "Refusing symlink package stage: $STAGE" >&2
  exit 1
fi
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

English
-------
Run: open $PRODUCT_APP_NAME

If macOS says the app is damaged:
  xattr -cr "$PRODUCT_APP_NAME"
  then right-click → Open

Ad-hoc signed only (not notarized).

简体中文
--------
运行：open $PRODUCT_APP_NAME

如果 macOS 提示应用已损坏：
  xattr -cr "$PRODUCT_APP_NAME"
  然后右键点击 → 打开

仅使用临时签名（未公证）。

繁體中文
--------
執行：open $PRODUCT_APP_NAME

如果 macOS 顯示應用程式已損毀：
  xattr -cr "$PRODUCT_APP_NAME"
  然後按右鍵 → 打開

僅使用臨時簽署（未公證）。
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
  if [[ -L "$DIST_ROOT/$PRODUCT_APP_NAME" ]]; then
    echo "Refusing symlink package App: $DIST_ROOT/$PRODUCT_APP_NAME" >&2
    exit 1
  fi
  rm -rf "$DIST_ROOT/$PRODUCT_APP_NAME"
  ditto "$APP_PATH" "$DIST_ROOT/$PRODUCT_APP_NAME"
  IDENTITY_ARTIFACTS+=("$DIST_ROOT/$PRODUCT_APP_NAME")
  echo "Copied $DIST_ROOT/$PRODUCT_APP_NAME"
else
  IDENTITY_ARTIFACTS+=("$STAGE")
fi

for fmt in "${formats[@]}"; do
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
      IDENTITY_ARTIFACTS+=("$ZIP")
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
      IDENTITY_ARTIFACTS+=("$DMG")
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

# 复制和签名完成后再次验证源 App；与复制前的 JSON 必须逐字一致，避免
# 打包过程中来源发生变化。
build_verification_after="$(node "$ROOT_DIR/scripts/write-build-identity.mjs" \
  --phase verify \
  --manifest "$BUILD_MANIFEST" \
  --expected-sha256 "$expected_build_sha" \
  --out-dir "$OUT" \
  --artifact "$OUT/Chromium.app")"
if [[ "$build_verification_after" != "$build_verification" ]]; then
  echo "Build identity changed while packaging; refusing to publish package identity." >&2
  exit 1
fi

identity_args=(
  --phase snapshot
  --output "$IDENTITY"
  --out-dir "$OUT"
  --artifact-root "$DIST_ROOT"
  --parent-manifest "$BUILD_MANIFEST"
  --parent-manifest-sha256 "$expected_build_sha"
)
for artifact in "${IDENTITY_ARTIFACTS[@]}"; do
  identity_args+=(--artifact "$artifact")
done
if [[ "${AEGIS_ALLOW_DIRTY_IDENTITY:-0}" == "1" ]]; then
  identity_args+=(--allow-dirty)
fi
node "$ROOT_DIR/scripts/write-build-identity.mjs" "${identity_args[@]}"

echo "Done. Artifacts under $DIST_ROOT"
