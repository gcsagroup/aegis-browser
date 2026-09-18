#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARGS_FILE="$BROWSER_DIR/args/aegis.gn"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"
COMPONENT_BUILD="$BROWSER_DIR/overlay/components/aegis_access/BUILD.gn"
ACCESS_BUILD="$BROWSER_DIR/overlay/chrome/browser/aegis/access/BUILD.gn"
AEGIS_BUILD="$BROWSER_DIR/overlay/chrome/browser/aegis/BUILD.gn"
BROWSER_METADATA_ADAPTER="$BROWSER_DIR/overlay/chrome/browser/aegis/access/access_browser_request_adapter.cc"
BROWSER_METADATA_BROWSER_TEST="$BROWSER_DIR/overlay/chrome/browser/aegis/access/access_browser_request_adapter_browsertest.cc"
PATCH_FILE="$BROWSER_DIR/patches/0114-feat-aegis-add-access-route-planning-contract.patch"
MATCHER_PATCH_FILE="$BROWSER_DIR/patches/0115-feat-aegis-add-trusted-policy-context-matching.patch"
PROXY_ADAPTER_PATCH_FILE="$BROWSER_DIR/patches/0117-feat-aegis-add-fail-closed-proxy-route-adapter.patch"
NETWORK_TRANSPORT_PATCH_FILE="$BROWSER_DIR/patches/0118-feat-aegis-bind-profile-network-context-proxy.patch"
NETWORK_ACCEPTANCE_PATCH_FILE="$BROWSER_DIR/patches/0119-test-aegis-local-proxy-network-acceptance.patch"
CPP_REGRESSION_PATCH_FILE="$BROWSER_DIR/patches/0120-test-aegis-expand-access-cpp-regressions.patch"
OWNERSHIP_PATCH_FILE="$BROWSER_DIR/patches/0121-feat-aegis-add-request-ownership-registry.patch"
TARGETED_CANCEL_PATCH_FILE="$BROWSER_DIR/patches/0122-feat-aegis-add-targeted-request-cancellation.patch"
DISPATCH_BARRIER_PATCH_FILE="$BROWSER_DIR/patches/0123-feat-aegis-add-request-dispatch-block-barriers.patch"
OWNERSHIP_REFACTOR_PATCH_FILE="$BROWSER_DIR/patches/0124-refactor-aegis-request-ownership-contracts.patch"
DISPATCH_GATE_PATCH_FILE="$BROWSER_DIR/patches/0125-feat-aegis-enforce-request-dispatch-gate.patch"
BROWSER_METADATA_PATCH_FILE="$BROWSER_DIR/patches/0126-feat-aegis-add-browser-owned-request-metadata-adapter.patch"
PUBLISHED_RUNTIME_PATCH_FILE="$BROWSER_DIR/patches/0127-feat-aegis-add-published-request-runtime.patch"
BROWSER_TEST_WIRING_PATCH_FILE="$BROWSER_DIR/patches/0060-feat-aegis-add-browser-agent-side-panel-and-entry-po.patch"
SERIES_FILE="$BROWSER_DIR/patches/series"
STORE_CONTRACT_TEST="$SCRIPT_DIR/access-rule-store-contract_test.sh"
TARGET="//components/aegis_access:aegis_access_unittests"
OWNERSHIP_TARGET="//components/aegis_access:request_ownership_registry_unittests"
DISPATCH_GATE_TARGET="//components/aegis_access:request_dispatch_gate_unittests"
BROWSER_METADATA_TARGET="//components/aegis_access:browser_request_metadata_seed_unittests"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ "$(rg -F -c "$TARGET" "$ARGS_FILE")" == 1 ]] ||
  fail "aegis.gn must add the access test exactly once"
args_block="$(awk '/^root_extra_deps = \[$/,/^\]$/' "$ARGS_FILE")"
[[ "$args_block" == *"$TARGET"* ]] ||
  fail "the access test must be reachable through root_extra_deps"
[[ "$(rg -F -c "$OWNERSHIP_TARGET" "$ARGS_FILE")" == 1 ]] ||
  fail "aegis.gn must add the ownership registry test exactly once"
[[ "$args_block" == *"$OWNERSHIP_TARGET"* ]] ||
  fail "the ownership registry test must be reachable through root_extra_deps"
[[ "$(rg -F -c "$DISPATCH_GATE_TARGET" "$ARGS_FILE")" == 1 ]] ||
  fail "aegis.gn must add the dispatch gate test exactly once"
[[ "$args_block" == *"$DISPATCH_GATE_TARGET"* ]] ||
  fail "the dispatch gate test must be reachable through root_extra_deps"
[[ "$(rg -F -c "$BROWSER_METADATA_TARGET" "$ARGS_FILE")" == 1 ]] ||
  fail "aegis.gn must add the browser metadata seed test exactly once"
[[ "$args_block" == *"$BROWSER_METADATA_TARGET"* ]] ||
  fail "the browser metadata seed test must be reachable through root_extra_deps"

rg -Fq 'test("aegis_access_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the independent access test"
rg -Fq 'source_set("request_ownership_registry")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the request ownership registry"
rg -Fq 'test("request_ownership_registry_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the ownership registry unit/regression test"
rg -Fq 'source_set("request_dispatch_gate")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the request dispatch gate"
rg -Fq 'test("request_dispatch_gate_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the dispatch gate unit/regression test"
dispatch_gate_test_block="$(
  awk '/^test\("request_dispatch_gate_unittests"\) \{/,/^}$/' "$COMPONENT_BUILD"
)"
for ownership_header in \
  request_cancellation_contract_test.h \
  request_dispatch_barrier_contract_test.h \
  request_ownership_registry_contract_test.h \
  request_ownership_registry_test_support.h \
  request_ownership_registry_unit_test.h; do
  [[ "$dispatch_gate_test_block" == *"\"$ownership_header\""* ]] ||
    fail "dispatch gate test must own transitive header $ownership_header"
done
rg -Fq 'source_set("browser_request_metadata_seed")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the browser metadata seed"
rg -Fq 'test("browser_request_metadata_seed_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the browser metadata seed unit/regression test"
rg -Fq 'source_set("access_browser_request_adapter")' "$ACCESS_BUILD" ||
  fail "overlay does not define the browser-owned Access request adapter"
rg -Fq '"//components/aegis_access:browser_request_metadata_seed",' "$ACCESS_BUILD" ||
  fail "browser-owned adapter must directly depend on metadata seed target"
rg -Fq 'request_frame->GetPage().IsPrimary()' "$BROWSER_METADATA_ADAPTER" ||
  fail "browser-owned adapter must reject non-primary Pages"
rg -Fq '"access/access_browser_request_adapter_browsertest.cc",' "$AEGIS_BUILD" ||
  fail "Aegis browser_tests must compile the browser metadata regression"
rg -Fq '"//chrome/browser/aegis/access:access_browser_request_adapter",' "$AEGIS_BUILD" ||
  fail "Aegis browser_tests must directly depend on the browser metadata adapter"
rg -Fq 'PrerenderPageCannotInheritPrimaryPageIdentity' "$BROWSER_METADATA_BROWSER_TEST" ||
  fail "browser metadata regression must cover prerender identity isolation"
rg -Fq 'AccessBrowserRequestMetadataStatus::kInvalidAttribution' \
  "$BROWSER_METADATA_BROWSER_TEST" ||
  fail "prerender regression must assert fail-closed attribution"
rg -Fq '"//chrome/browser/aegis:browser_tests",' "$BROWSER_TEST_WIRING_PATCH_FILE" ||
  fail "chrome browser_tests must include the existing Aegis browser_tests target"
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
rg -Fq 'EndpointIdentityTupleMismatchFailsClosed' "$CPP_REGRESSION_PATCH_FILE" ||
  fail "patch 0120 does not expand proxy identity regression coverage"
rg -Fq 'RejectedPublishDoesNotClobberExistingSelection' \
  "$CPP_REGRESSION_PATCH_FILE" ||
  fail "patch 0120 does not cover transactional selection rejection"
rg -Fq 'UnavailableSelectedProxyFailsHttpsWithoutDirectFallback' \
  "$CPP_REGRESSION_PATCH_FILE" ||
  fail "patch 0120 does not cover HTTPS dead-proxy fail-closed behavior"
rg -Fq '+source_set("request_ownership_registry")' "$OWNERSHIP_PATCH_FILE" ||
  fail "patch 0121 does not deliver the ownership registry production target"
rg -Fq '+test("request_ownership_registry_unittests")' "$OWNERSHIP_PATCH_FILE" ||
  fail "patch 0121 does not deliver ownership unit/regression tests"
rg -Fq '+class RequestOwnershipRegistry' "$OWNERSHIP_PATCH_FILE" ||
  fail "patch 0121 does not deliver RequestOwnershipRegistry"
rg -Fq 'RunRequestOwnershipRegistryRegressionTests' "$OWNERSHIP_PATCH_FILE" ||
  fail "patch 0121 does not carry shared ownership regression coverage"
rg -Fq 'CancelMatchingPageTarget' "$TARGETED_CANCEL_PATCH_FILE" ||
  fail "patch 0122 does not deliver targeted request cancellation"
rg -Fq 'RunTargetedRequestCancellationUnitTests' "$TARGETED_CANCEL_PATCH_FILE" ||
  fail "patch 0122 does not carry targeted cancellation unit coverage"
rg -Fq 'RunTargetedRequestCancellationRegressionTests' "$TARGETED_CANCEL_PATCH_FILE" ||
  fail "patch 0122 does not carry targeted cancellation regression coverage"
rg -Fq 'class RequestDispatchBarrierRegistry' "$DISPATCH_BARRIER_PATCH_FILE" ||
  fail "patch 0123 does not deliver the dispatch barrier registry"
rg -Fq 'InstallBlockBarrier' "$DISPATCH_BARRIER_PATCH_FILE" ||
  fail "patch 0123 does not deliver synchronous barrier installation"
rg -Fq 'RunRequestDispatchBarrierUnitTests' "$DISPATCH_BARRIER_PATCH_FILE" ||
  fail "patch 0123 does not carry dispatch barrier unit coverage"
rg -Fq 'RunRequestDispatchBarrierRegressionTests' "$DISPATCH_BARRIER_PATCH_FILE" ||
  fail "patch 0123 does not carry dispatch barrier regression coverage"
rg -Fq '+    "request_cancellation_contract_test.h",' "$OWNERSHIP_REFACTOR_PATCH_FILE" ||
  fail "patch 0124 does not split request cancellation contract coverage"
rg -Fq 'FindAndValidateEntry' "$OWNERSHIP_REFACTOR_PATCH_FILE" ||
  fail "patch 0124 does not centralize terminal request validation"
rg -Fq 'not published / not initialized' "$OWNERSHIP_REFACTOR_PATCH_FILE" ||
  fail "patch 0124 does not define zero-generation sentinel semantics"
rg -Fq 'EvaluateAndRegisterRequestForDispatch' "$DISPATCH_GATE_PATCH_FILE" ||
  fail "patch 0125 does not deliver the request dispatch gate"
rg -Fq 'RunRequestDispatchGateUnitTests' "$DISPATCH_GATE_PATCH_FILE" ||
  fail "patch 0125 does not carry dispatch gate unit coverage"
rg -Fq 'RunRequestDispatchGateRegressionTests' "$DISPATCH_GATE_PATCH_FILE" ||
  fail "patch 0125 does not carry dispatch gate regression coverage"
for ownership_header in \
  request_cancellation_contract_test.h \
  request_dispatch_barrier_contract_test.h \
  request_ownership_registry_contract_test.h \
  request_ownership_registry_test_support.h \
  request_ownership_registry_unit_test.h; do
  rg -Fq "+    \"$ownership_header\"," "$DISPATCH_GATE_PATCH_FILE" ||
    fail "patch 0125 does not make the dispatch gate own $ownership_header"
done
rg -Fq 'BuildBrowserOwnedRequestMetadata' "$BROWSER_METADATA_PATCH_FILE" ||
  fail "patch 0126 does not deliver the browser-owned metadata adapter"
rg -Fq 'request_frame->GetPage().IsPrimary()' "$BROWSER_METADATA_PATCH_FILE" ||
  fail "patch 0126 does not reject non-primary Pages"
rg -Fq '"//components/aegis_access:browser_request_metadata_seed",' \
  "$BROWSER_METADATA_PATCH_FILE" ||
  fail "patch 0126 does not carry the direct metadata seed dependency"
rg -Fq 'PrerenderPageCannotInheritPrimaryPageIdentity' \
  "$BROWSER_METADATA_PATCH_FILE" ||
  fail "patch 0126 does not carry the prerender browser regression"
rg -Fq 'RunBrowserRequestMetadataSeedUnitTests' "$BROWSER_METADATA_PATCH_FILE" ||
  fail "patch 0126 does not carry browser metadata unit coverage"
rg -Fq 'RunBrowserRequestMetadataSeedRegressionTests' "$BROWSER_METADATA_PATCH_FILE" ||
  fail "patch 0126 does not carry browser metadata regression coverage"

rg -Fq 'source_set("published_request_runtime")' "$COMPONENT_BUILD" ||
  fail "overlay does not define the published request runtime"
rg -Fq '"published_request_runtime_unittest.cc",' "$COMPONENT_BUILD" ||
  fail "access test target does not compile the published runtime regression"
rg -Fq 'EvaluatePublishedRequestForDispatch' "$PUBLISHED_RUNTIME_PATCH_FILE" ||
  fail "patch 0127 does not deliver the published request runtime"
rg -Fq 'RunPublishedRequestRuntimeUnitTests' "$PUBLISHED_RUNTIME_PATCH_FILE" ||
  fail "patch 0127 does not carry published runtime unit coverage"
rg -Fq 'RunPublishedRequestRuntimeRegressionTests' "$PUBLISHED_RUNTIME_PATCH_FILE" ||
  fail "patch 0127 does not carry published runtime regression coverage"
if rg -Fq 'request_initiator' "$BROWSER_METADATA_ADAPTER"; then
  fail "browser-owned Access metadata adapter must not consume renderer request_initiator"
fi
if rg -Fq 'seed_input.request_initiator' "$BROWSER_METADATA_PATCH_FILE"; then
  fail "patch 0126 must not trust renderer request_initiator"
fi
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
[[ "$(rg -F -c '0120-test-aegis-expand-access-cpp-regressions.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0120 must appear once in series"
[[ "$(rg -F -c '0121-feat-aegis-add-request-ownership-registry.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0121 must appear once in series"
[[ "$(rg -F -c '0122-feat-aegis-add-targeted-request-cancellation.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0122 must appear once in series"
[[ "$(rg -F -c '0123-feat-aegis-add-request-dispatch-block-barriers.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0123 must appear once in series"
[[ "$(rg -F -c '0124-refactor-aegis-request-ownership-contracts.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0124 must appear once in series"
[[ "$(rg -F -c '0125-feat-aegis-enforce-request-dispatch-gate.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0125 must appear once in series"
[[ "$(rg -F -c '0126-feat-aegis-add-browser-owned-request-metadata-adapter.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0126 must appear once in series"
[[ "$(rg -F -c '0127-feat-aegis-add-published-request-runtime.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0127 must appear once in series"
[[ "$(tail -n 13 "$SERIES_FILE" | head -n 1)" == \
  "0115-feat-aegis-add-trusted-policy-context-matching.patch" ]] ||
  fail "patch 0115 must immediately precede patch 0116"
[[ "$(tail -n 12 "$SERIES_FILE" | head -n 1)" == \
  "0116-feat-aegis-add-access-rule-store-recovery.patch" ]] ||
  fail "patch 0116 must immediately precede patch 0117"
[[ "$(tail -n 11 "$SERIES_FILE" | head -n 1)" == \
  "0117-feat-aegis-add-fail-closed-proxy-route-adapter.patch" ]] ||
  fail "patch 0117 must immediately precede patch 0118"
[[ "$(tail -n 10 "$SERIES_FILE" | head -n 1)" == \
  "0118-feat-aegis-bind-profile-network-context-proxy.patch" ]] ||
  fail "patch 0118 must immediately precede patch 0119"
[[ "$(tail -n 9 "$SERIES_FILE" | head -n 1)" == \
  "0119-test-aegis-local-proxy-network-acceptance.patch" ]] ||
  fail "patch 0119 must immediately precede patch 0120"
[[ "$(tail -n 8 "$SERIES_FILE" | head -n 1)" == \
  "0120-test-aegis-expand-access-cpp-regressions.patch" ]] ||
  fail "patch 0120 must immediately precede patch 0121"
[[ "$(tail -n 7 "$SERIES_FILE" | head -n 1)" == \
  "0121-feat-aegis-add-request-ownership-registry.patch" ]] ||
  fail "patch 0121 must immediately precede patch 0122"
[[ "$(tail -n 6 "$SERIES_FILE" | head -n 1)" == \
  "0122-feat-aegis-add-targeted-request-cancellation.patch" ]] ||
  fail "patch 0122 must immediately precede patch 0123"
[[ "$(tail -n 5 "$SERIES_FILE" | head -n 1)" == \
  "0123-feat-aegis-add-request-dispatch-block-barriers.patch" ]] ||
  fail "patch 0123 must immediately precede patch 0124"
[[ "$(tail -n 4 "$SERIES_FILE" | head -n 1)" == \
  "0124-refactor-aegis-request-ownership-contracts.patch" ]] ||
  fail "patch 0124 must immediately precede patch 0125"
[[ "$(tail -n 3 "$SERIES_FILE" | head -n 1)" == \
  "0125-feat-aegis-enforce-request-dispatch-gate.patch" ]] ||
  fail "patch 0125 must immediately precede patch 0126"
[[ "$(tail -n 2 "$SERIES_FILE" | head -n 1)" == \
  "0126-feat-aegis-add-browser-owned-request-metadata-adapter.patch" ]] ||
  fail "patch 0126 must immediately precede patch 0127"
[[ "$(tail -n 1 "$SERIES_FILE")" == \
  "0127-feat-aegis-add-published-request-runtime.patch" ]] ||
  fail "patch 0127 must be the current series tail"

# The developer build still requests only Chromium's production chrome target.
# root_extra_deps makes the test discoverable from test-only gn_all and does
# not create a dependency from chrome to the test executable.
rg -Fq 'autoninja -C "$OUT" chrome' "$BUILD_SCRIPT" ||
  fail "developer build no longer selects the production chrome target"
if rg -Fq "$TARGET" "$BROWSER_DIR/args/aegis-release.gn"; then
  fail "release GN args must not include the access test"
fi
if rg -Fq "$OWNERSHIP_TARGET" "$BROWSER_DIR/args/aegis-release.gn"; then
  fail "release GN args must not include the ownership registry test"
fi
if rg -Fq "$DISPATCH_GATE_TARGET" "$BROWSER_DIR/args/aegis-release.gn"; then
  fail "release GN args must not include the dispatch gate test"
fi
if rg -Fq "$BROWSER_METADATA_TARGET" "$BROWSER_DIR/args/aegis-release.gn"; then
  fail "release GN args must not include the browser metadata seed test"
fi
if rg -Fq "$TARGET" "$BROWSER_DIR/overlay/chrome"; then
  fail "production Chrome overlay must not depend on the access test"
fi
if rg -Fq "$OWNERSHIP_TARGET" "$BROWSER_DIR/overlay/chrome"; then
  fail "production Chrome overlay must not depend on the ownership registry test"
fi
if rg -Fq "$DISPATCH_GATE_TARGET" "$BROWSER_DIR/overlay/chrome"; then
  fail "production Chrome overlay must not depend on the dispatch gate test"
fi
if rg -Fq "$BROWSER_METADATA_TARGET" "$BROWSER_DIR/overlay/chrome"; then
  fail "production Chrome overlay must not depend on the browser metadata seed test"
fi

bash "$STORE_CONTRACT_TEST"

printf 'PASS: aegis_access GN developer-graph wiring contract\n'
