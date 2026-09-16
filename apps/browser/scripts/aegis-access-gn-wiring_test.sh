#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARGS_FILE="$BROWSER_DIR/args/aegis.gn"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"
COMPONENT_BUILD="$BROWSER_DIR/overlay/components/aegis_access/BUILD.gn"
ACCESS_BUILD="$BROWSER_DIR/overlay/chrome/browser/aegis/access/BUILD.gn"
PATCH_FILE="$BROWSER_DIR/patches/0114-feat-aegis-add-access-route-planning-contract.patch"
MATCHER_PATCH_FILE="$BROWSER_DIR/patches/0115-feat-aegis-add-trusted-policy-context-matching.patch"
PROXY_ADAPTER_PATCH_FILE="$BROWSER_DIR/patches/0117-feat-aegis-add-fail-closed-proxy-route-adapter.patch"
NETWORK_TRANSPORT_PATCH_FILE="$BROWSER_DIR/patches/0118-feat-aegis-bind-profile-network-context-proxy.patch"
NETWORK_ACCEPTANCE_PATCH_FILE="$BROWSER_DIR/patches/0119-test-aegis-local-proxy-network-acceptance.patch"
SERIES_FILE="$BROWSER_DIR/patches/series"
STORE_CONTRACT_TEST="$SCRIPT_DIR/access-rule-store-contract_test.sh"
TARGET="//components/aegis_access:aegis_access_unittests"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ "$(rg -F -c "$TARGET" "$ARGS_FILE")" == 1 ]] ||
  fail "aegis.gn must add the access test exactly once"
args_block="$(awk '/^root_extra_deps = \[$/,/^\]$/' "$ARGS_FILE")"
[[ "$args_block" == *"$TARGET"* ]] ||
  fail "the access test must be reachable through root_extra_deps"

rg -Fq 'test("aegis_access_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the independent access test"
rg -Fq '+test("aegis_access_unittests")' "$PATCH_FILE" ||
  fail "patch 0114 does not deliver the independent access test"
rg -Fq '+    "access_policy_evaluator.cc",' "$MATCHER_PATCH_FILE" ||
  fail "patch 0115 does not deliver the policy matcher"
rg -Fq '+action("generate_policy_matcher_vectors")' "$MATCHER_PATCH_FILE" ||
  fail "patch 0115 does not deliver the shared matcher vectors"
rg -Fq '"access_proxy_route_adapter.cc",' "$COMPONENT_BUILD" ||
  fail "overlay does not compile the proxy route adapter"
rg -Fq '"access_proxy_route_adapter_unittest.cc",' "$COMPONENT_BUILD" ||
  fail "overlay does not compile the proxy route adapter regression"
rg -Fq '+    "access_proxy_route_adapter.cc",' "$PROXY_ADAPTER_PATCH_FILE" ||
  fail "patch 0117 does not deliver the proxy route adapter"
rg -Fq '+    "access_proxy_route_adapter_unittest.cc",' "$PROXY_ADAPTER_PATCH_FILE" ||
  fail "patch 0117 does not deliver the proxy route adapter regression"
rg -Fq '"access_network_context_transport.cc",' "$ACCESS_BUILD" ||
  fail "overlay does not compile the NetworkContext proxy transport"
rg -Fq 'access_network_context_transport_unittest.cc' "$ACCESS_BUILD" ||
  fail "overlay does not compile the NetworkContext transport regression"
rg -Fq '"access_local_proxy_acceptance_unittest.cc",' "$COMPONENT_BUILD" ||
  fail "component test target does not compile the localhost proxy acceptance regression"
rg -Fq '+    "access_network_context_transport.cc",' "$NETWORK_TRANSPORT_PATCH_FILE" ||
  fail "patch 0118 does not deliver the NetworkContext proxy transport"
rg -Fq 'AccessNetworkContextTransport::ConfigureNetworkContext' \
  "$NETWORK_TRANSPORT_PATCH_FILE" ||
  fail "patch 0118 does not wire ProfileNetworkContextService"
rg -Fq '//chrome/browser/aegis/access:access_network_context_transport' \
  "$NETWORK_TRANSPORT_PATCH_FILE" ||
  fail "patch 0118 does not wire chrome/browser/net to the transport"
rg -Fq '+    "access_local_proxy_acceptance_unittest.cc",' \
  "$NETWORK_ACCEPTANCE_PATCH_FILE" ||
  fail "patch 0119 does not deliver the localhost proxy acceptance regression"
[[ "$(rg -F -c '0114-feat-aegis-add-access-route-planning-contract.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0114 must appear once in series"
[[ "$(rg -F -c '0115-feat-aegis-add-trusted-policy-context-matching.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0115 must appear once in series"
[[ "$(rg -F -c '0117-feat-aegis-add-fail-closed-proxy-route-adapter.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0117 must appear once in series"
[[ "$(rg -F -c '0118-feat-aegis-bind-profile-network-context-proxy.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0118 must appear once in series"
[[ "$(rg -F -c '0119-test-aegis-local-proxy-network-acceptance.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0119 must appear once in series"
[[ "$(tail -n 5 "$SERIES_FILE" | head -n 1)" == \
  "0115-feat-aegis-add-trusted-policy-context-matching.patch" ]] ||
  fail "patch 0115 must immediately precede patch 0116"
[[ "$(tail -n 4 "$SERIES_FILE" | head -n 1)" == \
  "0116-feat-aegis-add-access-rule-store-recovery.patch" ]] ||
  fail "patch 0116 must immediately precede patch 0117"
[[ "$(tail -n 3 "$SERIES_FILE" | head -n 1)" == \
  "0117-feat-aegis-add-fail-closed-proxy-route-adapter.patch" ]] ||
  fail "patch 0117 must immediately precede patch 0118"
[[ "$(tail -n 2 "$SERIES_FILE" | head -n 1)" == \
  "0118-feat-aegis-bind-profile-network-context-proxy.patch" ]] ||
  fail "patch 0118 must immediately precede patch 0119"
[[ "$(tail -n 1 "$SERIES_FILE")" == \
  "0119-test-aegis-local-proxy-network-acceptance.patch" ]] ||
  fail "patch 0119 must be the current series tail"

# The developer build still requests only Chromium's production chrome target.
# root_extra_deps makes the test discoverable from test-only gn_all and does
# not create a dependency from chrome to the test executable.
rg -Fq 'autoninja -C "$OUT" chrome' "$BUILD_SCRIPT" ||
  fail "developer build no longer selects the production chrome target"
if rg -Fq "$TARGET" "$BROWSER_DIR/args/aegis-release.gn"; then
  fail "release GN args must not include the access test"
fi
if rg -Fq "$TARGET" "$BROWSER_DIR/overlay/chrome"; then
  fail "production Chrome overlay must not depend on the access test"
fi

bash "$STORE_CONTRACT_TEST"

printf 'PASS: aegis_access GN developer-graph wiring contract\n'
