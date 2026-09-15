#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STORE_DIR="$BROWSER_DIR/overlay/chrome/browser/aegis/access"
ARGS_FILE="$BROWSER_DIR/args/aegis.gn"
PATCH_FILE="$BROWSER_DIR/patches/0116-feat-aegis-add-access-rule-store-recovery.patch"
SERIES_FILE="$BROWSER_DIR/patches/series"
TARGET="//chrome/browser/aegis/access:access_rule_store_unittests"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for file in access_rule_store.h access_rule_store.cc \
  access_rule_store_unittest.cc BUILD.gn; do
  [[ -f "$STORE_DIR/$file" ]] || fail "missing store overlay $file"
done

store_target_block="$(awk '/^source_set\("access_rule_store"\)/,/^}/' \
  "$STORE_DIR/BUILD.gn")"
for dependency in '//net' '//url'; do
  [[ "$store_target_block" == *"\"$dependency\""* ]] ||
    fail "store target must directly depend on $dependency"
done

[[ "$(rg -F -c "$TARGET" "$ARGS_FILE")" == 1 ]] ||
  fail "store GTest must appear once in developer root_extra_deps"
if rg -Fq "$TARGET" "$BROWSER_DIR/args/aegis-release.gn"; then
  fail "release args must not depend on the store GTest"
fi
if rg -Fq ':access_rule_store_unittests' \
  "$BROWSER_DIR/overlay/chrome/browser/aegis/BUILD.gn"; then
  fail "production Aegis target must not depend on the store GTest"
fi

[[ -f "$PATCH_FILE" ]] || fail "missing sequential patch 0116"
rg -Fq '+  <variant name="AegisAccess"' "$PATCH_FILE" ||
  fail "0116 must register the sql::Database AegisAccess tag"
rg -Fq '+test("access_rule_store_unittests")' "$PATCH_FILE" ||
  fail "0116 must deliver the native store test target"
rg -Fq '+class AccessRuleStore' "$PATCH_FILE" ||
  fail "0116 must deliver the production store"
[[ "$(rg -F -c '0116-feat-aegis-add-access-rule-store-recovery.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0116 must appear once in series"
[[ "$(tail -n 2 "$SERIES_FILE" | head -n 1)" == \
  '0116-feat-aegis-add-access-rule-store-recovery.patch' ]] ||
  fail "0116 must immediately precede the current access patch"

if [[ -e "$BROWSER_DIR/overlay/components/aegis_access/access_rule_store.cc" ||
      -e "$BROWSER_DIR/overlay/components/aegis_access/access_rule_store.h" ]]; then
  fail "Profile persistence must remain in chrome/browser, not components"
fi
if rg -Fq 'SetSiteProxy' "$STORE_DIR"; then
  fail "P2a must not implement the product SetSiteProxy surface"
fi

printf 'PASS: AccessRuleStore overlay, patch, and GN wiring contract\n'
