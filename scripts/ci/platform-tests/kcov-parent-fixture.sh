#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
child_output="$(bash "$SCRIPT_DIR/kcov-child-fixture.sh" child-process-covered)"
[[ "$child_output" == "child-process-covered" ]]
printf 'parent-and-child-covered\n'
