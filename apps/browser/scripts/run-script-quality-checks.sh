#!/usr/bin/env bash
set -euo pipefail

browser_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$browser_dir"

run_check() {
  local label="$1"
  shift
  printf '==> %s\n' "$label"
  "$@"
}

run_check 'patch series formats' bash ./scripts/patch-series-format_test.sh
run_check 'patch series regression fixtures' bash ./scripts/patch-series-format-regression_test.sh
run_check 'Access native unit tests' bash ./scripts/test-aegis-access-native.sh
run_check 'fixed Chromium Access GTest runner tests' python3 -B ../../scripts/dev/chromium_access_gtests_test.py
run_check 'TypeSafe choice contract unit tests' bash ./scripts/typesafe-choice-contract_test.sh
run_check 'model generation profiles and accounting' bash ./scripts/agent-generation-profile_test.sh
run_check 'paired model routing evaluation' node --test ./scripts/evaluate-agent-model-routing_test.mjs
run_check 'vector generators' bash ./scripts/vector-generators_test.sh
run_check 'Access GN wiring' bash ./scripts/aegis-access-gn-wiring_test.sh
run_check 'browser status script' bash ./scripts/status_test.sh
run_check 'toolchain fetch script' bash ./scripts/fetch-toolchain_test.sh
run_check 'browser run script' bash ./scripts/run_test.sh
run_check 'patch application script' bash ./scripts/apply-patches_test.sh
run_check 'package guard script' bash ./scripts/build-package-guards_test.sh
run_check 'Chromium signing script' bash ./scripts/sign-chromium-app_test.sh

run_check 'bootstrap libtorrent syntax' bash -n ./scripts/bootstrap-libtorrent.sh
run_check 'fetch Chromium syntax' bash -n ./scripts/fetch-chromium.sh
run_check 'detached Chromium fetch syntax' bash -n ./scripts/fetch-chromium-detached.sh
run_check 'vpython network fix syntax' bash -n ./scripts/fix-vpython-network.sh
run_check 'threat index installer syntax' bash -n ./scripts/install-threat-index.sh
run_check 'release build syntax' bash -n ./scripts/build-release.sh
run_check 'package script syntax' bash -n ./scripts/package.sh
run_check 'signing script syntax' bash -n ./scripts/sign-chromium-app.sh

run_check 'build identity syntax' node --check ./scripts/write-build-identity.mjs
run_check 'build identity self-test' node ./scripts/write-build-identity.mjs --self-test
run_check 'Agent runtime syntax' node --check ./scripts/verify-agent-runtime.mjs
run_check 'Agent runtime self-test' node ./scripts/verify-agent-runtime.mjs --self-test
run_check 'local model verifier syntax' node --check ./scripts/verify-agent-local-model.mjs
run_check 'local model verifier help' node ./scripts/verify-agent-local-model.mjs --help
run_check 'bytecode shadow verifier syntax' node --check ./scripts/verify-bytecode-shadow-runtime.mjs
run_check 'bytecode shadow verifier self-test' node ./scripts/verify-bytecode-shadow-runtime.mjs --self-test
run_check 'bytecode shadow site verifier syntax' node --check ./scripts/verify-bytecode-shadow-sites-runtime.mjs
run_check 'bytecode shadow site verifier self-test' node ./scripts/verify-bytecode-shadow-sites-runtime.mjs --self-test
run_check 'CDP runtime verifier syntax' node --check ./scripts/verify-cdp-runtime.mjs
run_check 'download runtime verifier syntax' node --check ./scripts/verify-download-runtime.mjs
run_check 'fingerprint runtime verifier syntax' node --check ./scripts/verify-fingerprint-runtime.mjs
run_check 'fingerprint runtime verifier self-test' node ./scripts/verify-fingerprint-runtime.mjs --self-test
run_check 'miner runtime verifier syntax' node --check ./scripts/verify-miner-runtime.mjs
run_check 'miner runtime verifier self-test' node ./scripts/verify-miner-runtime.mjs --self-test
run_check 'multisite runtime verifier syntax' node --check ./scripts/verify-multisite-runtime.mjs
