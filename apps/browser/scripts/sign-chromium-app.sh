#!/usr/bin/env bash
# Ad-hoc codesign a Chromium-family .app and its sibling Helper apps.
# Component / linker-signed builds often fail Gatekeeper with:
#   "code has no resources but signature indicates they must be present"
set -euo pipefail

CS="${CODESIGN:-/usr/bin/codesign}"
APP="${1:-}"
OUT_DIR="${2:-}"

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Usage: $0 /path/to/browser.app [/optional/parent/for/Helper*.app]"
  exit 1
fi

PARENT="${OUT_DIR:-$(cd "$(dirname "$APP")" && pwd)}"
APP_EXECUTABLE_NAME="$(basename "$APP" .app)"
INFO_PLIST="$APP/Contents/Info.plist"
if [[ -f "$INFO_PLIST" && -x /usr/libexec/PlistBuddy ]]; then
  configured_name="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
  if [[ -n "$configured_name" ]]; then
    APP_EXECUTABLE_NAME="$configured_name"
  fi
fi
if [[ -z "$APP_EXECUTABLE_NAME" || "$APP_EXECUTABLE_NAME" == . || \
      "$APP_EXECUTABLE_NAME" == .. || "$APP_EXECUTABLE_NAME" == */* ]]; then
  echo "Unsafe or missing CFBundleExecutable: $APP_EXECUTABLE_NAME" >&2
  exit 1
fi
FRAMEWORK_NAME="$APP_EXECUTABLE_NAME Framework"
SIBLING_HELPER_PREFIX="$APP_EXECUTABLE_NAME Helper"

verify_package() {
  "$CS" --verify --deep --strict "$APP" >/dev/null 2>&1 || return 1
  shopt -s nullglob
  local helper
  for helper in "$PARENT"/"$SIBLING_HELPER_PREFIX"*.app; do
    if ! "$CS" --verify --deep --strict "$helper" >/dev/null 2>&1; then
      shopt -u nullglob
      return 1
    fi
  done
  shopt -u nullglob
}

sign_one() {
  local path="$1"
  "$CS" --force --sign - --timestamp=none "$path" >/dev/null 2>&1 || \
    "$CS" --force --sign - "$path" >/dev/null
}

echo "Ad-hoc signing $APP …"

# 只有整包 strict/deep 验证通过时才允许跳过。Chromium 的 linker-signed
# 顶层经常能通过浅层 verify，但资源封装仍然无效。
if verify_package; then
  echo "Already strict/deep valid, skip codesign"
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP" 2>/dev/null || true
  fi
  exit 0
fi

HELPERS="$APP/Contents/Frameworks/$FRAMEWORK_NAME.framework/Versions/Current/Helpers"
if [[ -d "$HELPERS" ]]; then
  shopt -s nullglob
  for h in "$HELPERS"/*.app; do
    sign_one "$h"
  done
  # crashpad / other Mach-O helpers
  for bin in "$HELPERS"/chrome_crashpad_handler "$HELPERS"/app_mode_loader \
             "$HELPERS"/web_app_shortcut_copier; do
    [[ -x "$bin" ]] && sign_one "$bin"
  done
  shopt -u nullglob
fi

FRAME_BIN="$APP/Contents/Frameworks/$FRAMEWORK_NAME.framework/Versions/Current/$FRAMEWORK_NAME"
[[ -f "$FRAME_BIN" ]] && sign_one "$FRAME_BIN"
FRAME="$APP/Contents/Frameworks/$FRAMEWORK_NAME.framework"
[[ -d "$FRAME" ]] && sign_one "$FRAME"

shopt -s nullglob
for h in "$PARENT"/"$SIBLING_HELPER_PREFIX"*.app; do
  sign_one "$h"
done
shopt -u nullglob

"$CS" --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  "$CS" --force --deep --sign - "$APP" >/dev/null

if ! verify_package; then
  echo "Ad-hoc signing completed but strict/deep verification failed: $APP" >&2
  exit 1
fi
"$CS" --verify --deep --strict --verbose=2 "$APP"

# Drop quarantine so Finder double-click works for local builds.
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP" 2>/dev/null || true
  shopt -s nullglob
  for h in "$PARENT"/"$SIBLING_HELPER_PREFIX"*.app; do
    xattr -cr "$h" 2>/dev/null || true
  done
  shopt -u nullglob
fi

echo "Signed OK (ad-hoc, strict/deep local structure only)."
echo "This is not Developer ID signing or notarization."
