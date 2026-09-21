#!/usr/bin/env bash
set -euo pipefail

browser_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$browser_dir"

bash ./scripts/patch-series-format_test.sh
bash ./scripts/test-aegis-access-native.sh
bash ./scripts/vector-generators_test.sh
bash ./scripts/aegis-access-gn-wiring_test.sh
bash ./scripts/status_test.sh
bash ./scripts/fetch-toolchain_test.sh
bash ./scripts/run_test.sh
bash ./scripts/apply-patches_test.sh
bash ./scripts/build-package-guards_test.sh
bash ./scripts/sign-chromium-app_test.sh

bash -n ./scripts/bootstrap-libtorrent.sh
bash -n ./scripts/fetch-chromium.sh
bash -n ./scripts/fetch-chromium-detached.sh
bash -n ./scripts/fix-vpython-network.sh
bash -n ./scripts/install-threat-index.sh
bash -n ./scripts/build-release.sh
bash -n ./scripts/package.sh
bash -n ./scripts/sign-chromium-app.sh

node --check ./scripts/write-build-identity.mjs
node ./scripts/write-build-identity.mjs --self-test
node --check ./scripts/verify-agent-runtime.mjs
node ./scripts/verify-agent-runtime.mjs --self-test
node --check ./scripts/verify-agent-local-model.mjs
node ./scripts/verify-agent-local-model.mjs --help
node --check ./scripts/verify-bytecode-shadow-runtime.mjs
node ./scripts/verify-bytecode-shadow-runtime.mjs --self-test
node --check ./scripts/verify-bytecode-shadow-sites-runtime.mjs
node ./scripts/verify-bytecode-shadow-sites-runtime.mjs --self-test
node --check ./scripts/verify-cdp-runtime.mjs
node --check ./scripts/verify-download-runtime.mjs
node --check ./scripts/verify-fingerprint-runtime.mjs
node ./scripts/verify-fingerprint-runtime.mjs --self-test
node --check ./scripts/verify-miner-runtime.mjs
node ./scripts/verify-miner-runtime.mjs --self-test
node --check ./scripts/verify-multisite-runtime.mjs
