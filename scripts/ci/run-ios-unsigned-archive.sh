#!/usr/bin/env bash
# Compile the uncredentialed iOS archive from the job-private Source tree.
set -euo pipefail

# Keep the Actions entry PID through compilation and validation.
trap 'exit 143' TERM
trap 'exit 130' INT

: "${IOS_CI_ROOT:?IOS_CI_ROOT is required}"
SOURCE="${IOS_CI_SOURCE:?IOS_CI_SOURCE is required}"

if [[ "$SOURCE" != /* || ! -d "$SOURCE" ]]; then
  printf 'archive source must be an absolute directory under admitted storage\n' >&2
  exit 1
fi
if [[ ! -f "$SOURCE/apps/ios/Aegis.xcodeproj/project.pbxproj" ]]; then
  printf 'archive source is missing apps/ios/Aegis.xcodeproj\n' >&2
  exit 1
fi

REPO_ROOT="$(cd -P "$(dirname "$0")/../.." && pwd)"
if [[ "$REPO_ROOT" != "$SOURCE" ]]; then
  printf 'archive wrapper must run from the admitted Source tree\n' >&2
  exit 1
fi
# Use the admitted checkout's storage without discarding Git transport policy.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH \
  GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_NO_REPLACE_OBJECTS GIT_SHALLOW_FILE \
  GIT_NAMESPACE GIT_ATTR_SOURCE

enter_source() {
  cd -P -- "$SOURCE" || exit 1
  if [[ "$PWD" != "$SOURCE" ]]; then
    printf 'archive source does not match the admitted directory\n' >&2
    exit 1
  fi
}

if [[ "${1:-}" == --verify-archive ]]; then
  enter_source
  python3 "$REPO_ROOT/scripts/release/verify-ios-archive.py" \
    "$IOS_CI_ROOT/Aegis.xcarchive" 1.0.0 1
  python3 -B "$REPO_ROOT/scripts/release/test_ios_linked_bundle.py" \
    "$IOS_CI_ROOT/Aegis.xcarchive/Products/Applications/Aegis.app" \
    "$IOS_CI_ROOT/EmbeddedCore" "$IOS_CI_ROOT/DerivedData" device
  exec python3 -I -B "$REPO_ROOT/scripts/ci/ios-ci-storage.py" seal --root "$IOS_CI_ROOT"
fi

# shellcheck source=apps/browser/scripts/common.sh
source "$REPO_ROOT/apps/browser/scripts/common.sh"
# Suppress informational stdout before the best-effort console is installed.
configure_git_for_chromium_fetch >/dev/null

export TMPDIR="$IOS_CI_ROOT/tmp"
export CLANG_MODULE_CACHE_PATH="$IOS_CI_ROOT/ModuleCache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

python3 -B "$REPO_ROOT/scripts/release/ios_embedded_core.py" verify --root "$SOURCE" \
  --source-lock "$SOURCE/apps/ios/EmbeddedCore/embedded-core-lock.json" \
  --products "$IOS_CI_ROOT/EmbeddedCore" >/dev/null

enter_source
compiler="$(command -v xcodebuild)"

exec python3 -I -B "$REPO_ROOT/scripts/ci/ios-archive-supervisor.py" \
    "$IOS_CI_ROOT/xcodebuild.log" "$BASH" "$REPO_ROOT/scripts/ci/run-ios-unsigned-archive.sh" \
    "$compiler" -scmProvider system -onlyUsePackageVersionsFromResolvedFile \
    -project apps/ios/Aegis.xcodeproj -scheme Aegis -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$IOS_CI_ROOT/Aegis.xcarchive" \
    -derivedDataPath "$IOS_CI_ROOT/DerivedData" \
    -clonedSourcePackagesDirPath "$IOS_CI_ROOT/SourcePackages" \
    -packageCachePath "$IOS_CI_ROOT/PackageCache" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=1 \
    AEGIS_EMBEDDED_CORE_PRODUCTS="$IOS_CI_ROOT/EmbeddedCore" \
    archive
