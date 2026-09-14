#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

child_value="${1:-}"
[[ "$child_value" == "child-process-covered" ]]
printf '%s\n' "$child_value"
