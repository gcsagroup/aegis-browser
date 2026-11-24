#!/usr/bin/env bash
# The unsigned archive supervisor launches this worker with private tool output.
set -euo pipefail

test "$PWD" = "${IOS_CI_SOURCE:?IOS_CI_SOURCE is required}" || exit 1
: "${IOS_CI_ROOT:?IOS_CI_ROOT is required}"

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH \
  GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_NO_REPLACE_OBJECTS GIT_SHALLOW_FILE \
  GIT_NAMESPACE GIT_ATTR_SOURCE
lock="$PWD/apps/ios/EmbeddedCore/embedded-core-lock.json"
export GOROOT="${IOS_CI_SCRATCH:?IOS_CI_SCRATCH is required}/go"
export GOTOOLCHAIN=local
export PATH="$GOROOT/bin:$PATH"

# Both the bridge and its receipt must use the job-private checkout.
AEGIS_EMBEDDED_CORE_DIGEST_MODE=ci-rebuild \
  bash scripts/release/prepare-ios-access-core.sh \
    "$lock" \
    "$IOS_CI_ROOT/EmbeddedCore"
test -d "$IOS_CI_ROOT/EmbeddedCore/AegisEmbeddedCore.xcframework"
