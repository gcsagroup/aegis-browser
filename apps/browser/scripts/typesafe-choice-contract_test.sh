#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OVERLAY_DIR="$(cd "${SCRIPT_DIR}/../overlay" && pwd -P)"
SOURCE="${OVERLAY_DIR}/chrome/browser/aegis/agent/typesafe_choice_contract.cc"
TEST_SOURCE="${SCRIPT_DIR}/typesafe-choice-contract_test.cc"
TEST_BINARY="$(mktemp "${TMPDIR:-/tmp}/aegis-typesafe-choice.XXXXXX")"
trap 'rm -f "${TEST_BINARY}"' EXIT

"${CXX:-c++}" -std=c++20 -Wall -Wextra -Werror \
  -I"${OVERLAY_DIR}" "${SOURCE}" "${TEST_SOURCE}" -o "${TEST_BINARY}"
"${TEST_BINARY}"
