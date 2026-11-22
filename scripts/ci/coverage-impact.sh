#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

base="${1:?base commit is required}"
tested="${2:?tested commit is required}"
[[ "$base" =~ ^[0-9a-f]{40}$ && "$tested" =~ ^[0-9a-f]{40}$ ]]
paths=(
  .github/workflows/android-java-coverage.yml
  scripts/ci/coverage-impact.sh
  apps/browser/CHROMIUM_VERSION
  apps/browser/scripts/android-agent-ui.mjs
  apps/browser/scripts/android-agent-ui_test.mjs
  apps/browser/scripts/android-ui-driver/AndroidManifest.xml
  apps/browser/scripts/android-ui-driver/Driver.java
  apps/browser/scripts/android-ui-driver/jacoco-agent.properties
  apps/browser/scripts/common.sh
  apps/browser/scripts/package-android.sh
  apps/browser/scripts/package-android-guards_test.sh
  apps/browser/scripts/run-android-java-coverage-emulator.sh
  apps/browser/scripts/run-android-java-coverage-emulator_test.mjs
  apps/browser/scripts/verify-android-agent-target.mjs
  apps/browser/scripts/verify-android-agent-target_test.mjs
)

# Git compares the complete pair of trees, including deletions and type changes.
run=true
if git diff --quiet --no-ext-diff --no-textconv --no-renames "$base" "$tested" -- "${paths[@]}"; then
  run=false
else
  diff_status=$?
  test "$diff_status" -eq 1 || exit "$diff_status"
fi
printf 'run=%s\n' "$run" >> "$GITHUB_OUTPUT"
