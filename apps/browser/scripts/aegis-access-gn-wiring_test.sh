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
POLICY_GENERATION_PATCH_FILE="$BROWSER_DIR/patches/0128-feat-aegis-own-committed-policy-generation.patch"
NETWORK_EPOCH_PATCH_FILE="$BROWSER_DIR/patches/0129-feat-aegis-own-browser-network-epoch.patch"
IDENTITY_GENERATION_PATCH_FILE="$BROWSER_DIR/patches/0130-feat-aegis-own-profile-identity-generation.patch"
SELECTION_GENERATION_PATCH_FILE="$BROWSER_DIR/patches/0131-feat-aegis-own-proxy-selection-generation.patch"
BASE_PROXY_GENERATION_PATCH_FILE="$BROWSER_DIR/patches/0132-feat-aegis-own-base-proxy-config-generation.patch"
PUBLISHED_GENERATION_RUNTIME_PATCH_FILE="$BROWSER_DIR/patches/0133-feat-aegis-publish-request-generation-runtime.patch"
RUNTIME_THREAD_BOUNDARY_PATCH_FILE="$BROWSER_DIR/patches/0134-fix-aegis-harden-published-runtime-thread-boundary.patch"
REAL_URL_LOADER_PATCH_FILE="$BROWSER_DIR/patches/0135-feat-aegis-gate-real-document-url-loader-traffic.patch"
REQUEST_TERMINATION_PATCH_FILE="$BROWSER_DIR/patches/0136-feat-aegis-terminate-in-flight-access-requests.patch"
POLICY_PUBLICATION_ACK_PATCH_FILE="$BROWSER_DIR/patches/0137-feat-aegis-version-policy-publication-acks.patch"
NAVIGATION_URL_LOADER_PATCH_FILE="$BROWSER_DIR/patches/0138-feat-aegis-gate-real-navigation-url-loader-traffic.patch"
SUBFRAME_NAVIGATION_PATCH_FILE="$BROWSER_DIR/patches/0139-feat-aegis-gate-primary-page-subframe-navigation.patch"
REDIRECT_REEVALUATION_PATCH_FILE="$BROWSER_DIR/patches/0140-feat-aegis-reevaluate-proxied-redirects.patch"
WORKER_MAIN_RESOURCE_PATCH_FILE="$BROWSER_DIR/patches/0141-feat-aegis-gate-worker-main-resource-traffic.patch"
WORKER_SUBRESOURCE_PATCH_FILE="$BROWSER_DIR/patches/0142-feat-aegis-gate-worker-subresource-traffic.patch"
PROFILE_ONLY_BACKGROUND_PATCH_FILE="$BROWSER_DIR/patches/0143-feat-aegis-add-profile-only-background-ownership.patch"
FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE="$BROWSER_DIR/patches/0144-feat-aegis-gate-frameless-worker-subresource-traffic.patch"
PROFILE_ONLY_BACKGROUND_TEST="$BROWSER_DIR/overlay/chrome/browser/aegis/access/access_browser_request_adapter_unittest.cc"
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
rg -Fq 'source_set("access_request_dispatch_state")' "$ACCESS_BUILD" ||
  fail "overlay must define the Profile-owned Access request dispatch state"
rg -Fq 'source_set("access_proxying_url_loader_factory")' "$ACCESS_BUILD" ||
  fail "overlay must define the real Access URLLoader proxy factory"
rg -Fq 'test("access_request_dispatch_state_unittests")' "$ACCESS_BUILD" ||
  fail "overlay must compile the Profile dispatch-state regression"
rg -Fq '"access/access_proxying_url_loader_factory_browsertest.cc",' "$AEGIS_BUILD" ||
  fail "Aegis browser_tests must compile the real URLLoader proxy smoke"
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

rg -Fq 'record.candidate.policy_generation = record.operation_sequence;' \
  "$POLICY_GENERATION_PATCH_FILE" ||
  fail "patch 0128 must reserve policy generation during Prepare"
rg -Fq 'committed_policy_generation = record.operation_sequence;' \
  "$POLICY_GENERATION_PATCH_FILE" ||
  fail "patch 0128 must commit the reserved policy generation"
rg -Fq 'ReservedPolicyGenerationIsRecoveredAndNeverReused' \
  "$POLICY_GENERATION_PATCH_FILE" ||
  fail "patch 0128 must cover recovery and non-reuse"
rg -Fq 'CommittedJournalGenerationMustMatchReservedSequence' \
  "$POLICY_GENERATION_PATCH_FILE" ||
  fail "patch 0128 must reject journal generation drift"
rg -Fq 'CommittedGroupGenerationMustMatchOperationSequence' \
  "$POLICY_GENERATION_PATCH_FILE" ||
  fail "patch 0128 must reject committed group generation drift"
rg -Fq 'generation != sequence' "$POLICY_GENERATION_PATCH_FILE" ||
  fail "patch 0128 must bind persisted group generation to operation sequence"
rg -Fq 'NetworkChangeObserver' "$NETWORK_EPOCH_PATCH_FILE" ||
  fail "patch 0129 must use Chromium NetworkChangeNotifier"
rg -Fq 'AddNetworkChangeObserver(this);' "$NETWORK_EPOCH_PATCH_FILE" ||
  fail "patch 0129 must register the production network epoch source"
rg -Fq 'endpoint.generations.network_epoch == network_epoch_' \
  "$NETWORK_EPOCH_PATCH_FILE" ||
  fail "patch 0129 must validate endpoint generation against the current network epoch"
rg -Fq 'NetworkChangeAdvancesEpochAndRejectsStaleEndpoint' \
  "$NETWORK_EPOCH_PATCH_FILE" ||
  fail "patch 0129 must cover real network-change epoch advancement"
rg -Fq 'NetworkEpochOverflowFailsClosedPermanently' \
  "$NETWORK_EPOCH_PATCH_FILE" ||
  fail "patch 0129 must cover epoch exhaustion fail-closed behavior"
rg -Fq 'violate REQUIRE_PROXY' "$NETWORK_EPOCH_PATCH_FILE" ||
  fail "patch 0129 must preserve the no-DIRECT-fallback rationale"
rg -Fq 'source_set("access_identity_generation_state")' "$COMPONENT_BUILD" ||
  fail "overlay must define the identity generation core"
rg -Fq 'test("access_identity_generation_state_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay must define the identity generation core test"
rg -Fq 'source_set("access_identity_generation_source")' "$ACCESS_BUILD" ||
  fail "overlay must define the Profile-owned identity source"
rg -Fq 'test("access_identity_generation_source_unittests")' "$ACCESS_BUILD" ||
  fail "overlay must define the Profile-owned identity source test"
rg -Fq 'IdentityGenerationState::Commit' "$IDENTITY_GENERATION_PATCH_FILE" ||
  fail "patch 0130 must own committed identity generation"
rg -Fq 'AccessIdentityGenerationSource::CommitIdentity'   "$IDENTITY_GENERATION_PATCH_FILE" ||
  fail "patch 0130 must bridge committed identity into the Profile source"
rg -Fq 'StartsUnpublishedUntilCommittedIdentity'   "$IDENTITY_GENERATION_PATCH_FILE" ||
  fail "patch 0130 must keep identity generation unpublished before commit"
rg -Fq 'CommittedIdentityTransitionsAdvanceGeneration'   "$IDENTITY_GENERATION_PATCH_FILE" ||
  fail "patch 0130 must cover committed identity transitions"
rg -Fq 'ProfileOwnedSourcesAreIsolated' "$IDENTITY_GENERATION_PATCH_FILE" ||
  fail "patch 0130 must cover Profile-owned identity isolation"
rg -Fq 'ExpectIdentityGenerationOverflowFailsClosed'   "$IDENTITY_GENERATION_PATCH_FILE" ||
  fail "patch 0130 must cover identity generation exhaustion"
rg -Fq 'source_set("access_proxy_selection_generation_state")' "$COMPONENT_BUILD" ||
  fail "overlay must define the proxy selection generation core"
rg -Fq 'test("access_proxy_selection_generation_state_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay must define the proxy selection generation core test"
rg -Fq 'source_set("access_proxy_selection_generation_source")' "$ACCESS_BUILD" ||
  fail "overlay must define the Profile-owned proxy selection source"
rg -Fq 'test("access_proxy_selection_generation_source_unittests")' "$ACCESS_BUILD" ||
  fail "overlay must define the Profile-owned proxy selection source test"
rg -Fq 'ProxySelectionGenerationState::Commit' "$SELECTION_GENERATION_PATCH_FILE" ||
  fail "patch 0131 must own committed proxy selection generation"
rg -Fq 'binding.binding_revision <= binding_->binding_revision' "$SELECTION_GENERATION_PATCH_FILE" ||
  fail "patch 0131 must reject stale binding revisions"
rg -Fq 'StaleBindingRevisionCannotOverwriteNewerSelection' "$SELECTION_GENERATION_PATCH_FILE" ||
  fail "patch 0131 must cover late selection results"
rg -Fq 'ProxyGroupsAndProfilesAreIsolated' "$SELECTION_GENERATION_PATCH_FILE" ||
  fail "patch 0131 must cover group and Profile isolation"
rg -Fq 'ExpectSelectionGenerationOverflowFailsClosed' "$SELECTION_GENERATION_PATCH_FILE" ||
  fail "patch 0131 must cover selection generation exhaustion"
rg -Fq 'source_set("access_base_proxy_config_generation_state")' "$COMPONENT_BUILD" ||
  fail "overlay must define the base proxy config generation core"
rg -Fq 'test("access_base_proxy_config_generation_state_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay must define the base proxy config generation core test"
rg -Fq 'BaseProxyConfigGenerationState::PublishCurrentConfig' "$BASE_PROXY_GENERATION_PATCH_FILE" ||
  fail "patch 0132 must own native base proxy generation"
rg -Fq 'base_proxy_config_generation_state_.PublishCurrentConfig();' "$BASE_PROXY_GENERATION_PATCH_FILE" ||
  fail "patch 0132 must publish the first available native proxy config"
rg -Fq 'base_proxy_config_generation_state_.AdvanceOnConfigChange();' "$BASE_PROXY_GENERATION_PATCH_FILE" ||
  fail "patch 0132 must advance on Chromium proxy config observer updates"
rg -Fq 'availability != net::ProxyConfigService::CONFIG_PENDING' "$BASE_PROXY_GENERATION_PATCH_FILE" ||
  fail "patch 0132 must keep pending native proxy config unpublished"
rg -Fq 'GetAegisBaseProxyConfigGeneration' "$BASE_PROXY_GENERATION_PATCH_FILE" ||
  fail "patch 0132 must expose the current native proxy generation"
rg -Fq '//components/aegis_access:access_base_proxy_config_generation_state' "$BASE_PROXY_GENERATION_PATCH_FILE" ||
  fail "patch 0132 must wire chrome/browser/net to the base proxy generation state"
rg -Fq 'ExpectBaseProxyConfigGenerationOverflowFailsClosed' "$BASE_PROXY_GENERATION_PATCH_FILE" ||
  fail "patch 0132 must cover base proxy generation exhaustion"
rg -Fq 'source_set("request_generation_tuple_builder")' "$COMPONENT_BUILD" ||
  fail "overlay must define the request generation tuple builder"
rg -Fq 'test("request_generation_tuple_builder_unittests")' "$COMPONENT_BUILD" ||
  fail "overlay must define the request generation tuple builder test"
rg -Fq 'source_set("access_published_request_runtime")' "$ACCESS_BUILD" ||
  fail "overlay must define the browser published request runtime"
rg -Fq 'AccessRuleStore::AdaptMatcherSnapshot' "$PUBLISHED_GENERATION_RUNTIME_PATCH_FILE" ||
  fail "patch 0133 must validate durable store snapshots before publication"
rg -Fq 'OwnsConfiguredPartition' "$PUBLISHED_GENERATION_RUNTIME_PATCH_FILE" ||
  fail "patch 0133 must bind publication to the configured Profile partition"
rg -Fq 'AccessIdentityGenerationSource::Get(profile_)' "$PUBLISHED_GENERATION_RUNTIME_PATCH_FILE" ||
  fail "patch 0133 must read the production identity generation source"
rg -Fq 'selection->selection_generation(proxy_group_id)' "$PUBLISHED_GENERATION_RUNTIME_PATCH_FILE" ||
  fail "patch 0133 must read selection generation only for a concrete proxy group"
rg -Fq 'transport->network_epoch()' "$PUBLISHED_GENERATION_RUNTIME_PATCH_FILE" ||
  fail "patch 0133 must read the production network epoch"
rg -Fq 'GetAegisBaseProxyConfigGeneration' "$PUBLISHED_GENERATION_RUNTIME_PATCH_FILE" ||
  fail "patch 0133 must read Chromium native base proxy generation"
rg -Fq 'BuildCompleteRequestGenerationTuple' "$PUBLISHED_GENERATION_RUNTIME_PATCH_FILE" ||
  fail "patch 0133 must fail closed through the shared tuple builder"
rg -Fq 'kMissingSelectionGeneration' "$PUBLISHED_GENERATION_RUNTIME_PATCH_FILE" ||
  fail "patch 0133 must test missing selection generation as fail closed"
rg -Fq 'DCHECK_CURRENTLY_ON(content::BrowserThread::UI);' \
  "$RUNTIME_THREAD_BOUNDARY_PATCH_FILE" ||
  fail "patch 0134 must enforce the UI-thread Profile runtime boundary"
rg -Fq 'CaptureProxyGenerationTupleOnUiThread' \
  "$RUNTIME_THREAD_BOUNDARY_PATCH_FILE" ||
  fail "patch 0134 must expose an explicitly UI-thread generation capture API"
rg -Fq 'inline bool IsKnownChannel(ChannelNamespace channel)' \
  "$RUNTIME_THREAD_BOUNDARY_PATCH_FILE" ||
  fail "patch 0134 must centralize channel validation"
rg -Fq 'inline bool IsCompleteOwner(const OwnershipKey& owner)' \
  "$RUNTIME_THREAD_BOUNDARY_PATCH_FILE" ||
  fail "patch 0134 must centralize ownership validation"
rg -Fq 'URLLoaderFactoryType::kDocumentSubResource' "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must install only the first document-subresource slice"
rg -Fq 'MaybeProxyDocumentSubresource' "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must wire the Aegis URLLoader proxy factory"
rg -Fq 'CaptureProxyGenerationTupleOnUiThread' "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must consume the UI-captured five-source generation tuple"
rg -Fq 'CaptureSelectedProxyEndpoint' "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must bind requests to the exact selected localhost endpoint"
rg -Fq 'EvaluatePublishedRequestForDispatch' "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must run the published request dispatch gate before send"
rg -Fq 'MarkDispatched' "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must attach a termination-capable dispatch lifecycle before send"
rg -Fq 'ERR_PROXY_CONNECTION_FAILED' "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must fail closed when required proxy state is unavailable"
rg -Fq '//chrome/browser/aegis/access:access_proxying_url_loader_factory' \
  "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must link the URLLoader proxy factory into chrome_browser_main"
rg -Fq 'RuntimePolicyUpdateRoutesExistingFactoryThroughProxy' \
  "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must carry the runtime policy-to-localhost-proxy browser smoke"
rg -Fq 'ProxyPolicyWithoutSelectedEndpointFailsClosed' \
  "$REAL_URL_LOADER_PATCH_FILE" ||
  fail "patch 0135 must cover missing-endpoint no-DIRECT-fallback behavior"
rg -Fq 'InstallBlockBarrierAndCancelMatching' "$REQUEST_TERMINATION_PATCH_FILE" ||
  fail "patch 0136 must install the BLOCK barrier before cancellation"
rg -Fq 'CancelMatchingPageTarget' "$REQUEST_TERMINATION_PATCH_FILE" ||
  fail "patch 0136 must cancel matching in-flight ownership entries"
rg -Fq 'TerminateFromRegistry' "$REQUEST_TERMINATION_PATCH_FILE" ||
  fail "patch 0136 must invoke the real URLLoader termination handle"
rg -Fq 'access_proxying_url_tracked_request.cc' "$REQUEST_TERMINATION_PATCH_FILE" ||
  fail "patch 0136 must isolate the tracked URLLoader lifecycle"
rg -Fq 'BlockBarrierTerminatesMatchingDispatchedRequest' \
  "$REQUEST_TERMINATION_PATCH_FILE" ||
  fail "patch 0136 must unit-test barrier-first cancellation"
rg -Fq 'BlockBarrierTerminatesInFlightProxyRequest' \
  "$REQUEST_TERMINATION_PATCH_FILE" ||
  fail "patch 0136 must browser-test real in-flight request termination"
rg -Fq 'source_set("policy_publication_ack_tracker")' "$COMPONENT_BUILD" ||
  fail "overlay must define the versioned policy publication ack tracker"
rg -Fq 'PolicyPublicationAckTracker::Begin' "$POLICY_PUBLICATION_ACK_PATCH_FILE" ||
  fail "patch 0137 must version policy publication acknowledgements"
rg -Fq 'LateAckCannotReleaseNewerBlockBarrier' "$POLICY_PUBLICATION_ACK_PATCH_FILE" ||
  fail "patch 0137 must reject late ACK release of a newer BLOCK barrier"
rg -Fq 'OnCustomProxyConfigUpdated' "$POLICY_PUBLICATION_ACK_PATCH_FILE" ||
  fail "patch 0137 must use Chromium CustomProxyConfigClient acknowledgements"
rg -Fq 'BarrierClosure' "$POLICY_PUBLICATION_ACK_PATCH_FILE" ||
  fail "patch 0137 must wait for all attached NetworkContext clients"
rg -Fq 'RequestNetworkContextPublicationAck' "$POLICY_PUBLICATION_ACK_PATCH_FILE" ||
  fail "patch 0137 must bridge real NetworkContext ACKs into dispatch state"
rg -Fq 'ReleaseBlockBarrierForReadyPublication' "$POLICY_PUBLICATION_ACK_PATCH_FILE" ||
  fail "patch 0137 must gate BLOCK barrier release on publication readiness"
rg -Fq 'RealCustomProxyConfigCallbackAcknowledgesPublication' \
  "$POLICY_PUBLICATION_ACK_PATCH_FILE" ||
  fail "patch 0137 must test the real NetworkContext ACK callback"
rg -Fq 'std::move(all_clients_settled).Run(false)' \
  "$POLICY_PUBLICATION_ACK_PATCH_FILE" ||
  fail "patch 0137 must settle immediate NetworkContext ACK failures"
rg -Fq 'MissingNetworkTransportFailsPublicationImmediately' \
  "$POLICY_PUBLICATION_ACK_PATCH_FILE" ||
  fail "patch 0137 must fail publication when NetworkContext ACK cannot start"
rg -Fq 'URLLoaderFactoryType::kNavigation' \
  "$NAVIGATION_URL_LOADER_PATCH_FILE" ||
  fail "patch 0138 must install the navigation URLLoader slice"
rg -Fq 'navigation_id.has_value()' "$NAVIGATION_URL_LOADER_PATCH_FILE" ||
  fail "patch 0138 must require Chromium browser-owned navigation identity"
rg -Fq 'MaybeProxyNavigation' "$NAVIGATION_URL_LOADER_PATCH_FILE" ||
  fail "patch 0138 must wire the navigation proxy factory"
rg -Fq 'IsInPrimaryMainFrame()' "$NAVIGATION_URL_LOADER_PATCH_FILE" ||
  fail "patch 0138 must remain scoped to primary main-frame navigation"
rg -Fq 'RequestAttributionKind::kPendingNavigation' \
  "$NAVIGATION_URL_LOADER_PATCH_FILE" ||
  fail "patch 0138 must preserve pending-navigation attribution"
rg -Fq 'PendingNavigationUsesDestinationSiteNotOldDocument' \
  "$NAVIGATION_URL_LOADER_PATCH_FILE" ||
  fail "patch 0138 must prove navigation does not borrow old document identity"
rg -Fq 'MainNavigationUsesPendingNavigationProxy' \
  "$NAVIGATION_URL_LOADER_PATCH_FILE" ||
  fail "patch 0138 must browser-test real navigation through localhost proxy"
rg -Fq 'MainNavigationWithoutPolicyPreservesNativePath' \
  "$NAVIGATION_URL_LOADER_PATCH_FILE" ||
  fail "patch 0138 must preserve native navigation without Access policy"
rg -Fq 'seed_input->top_frame_site = top_frame_site.Serialize();' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must capture the browser-owned primary top site"
rg -Fq 'nested navigation preserves trusted top site' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must preserve pending subframe top-site seed semantics"
rg -Fq 'UsesBrowserOwnedTopSiteForNestedPendingNavigation' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must canonicalize nested navigation from the trusted top site"
rg -Fq 'SubframePendingNavigationPreservesPrimaryTopFrameSite' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must browser-test subframe top-site ownership"
rg -Fq 'ResolvePrimaryTopFrameSite' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must centralize trusted primary top-site resolution"
rg -Fq 'request_frame->GetPage().IsPrimary()' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must defensively reject non-primary request frames"
rg -Fq 'request_frame->GetMainFrame() != contents->GetPrimaryMainFrame()' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must reject frames outside the primary frame tree"
rg -Fq 'kPrerenderNavigationId' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must regression-test pending navigation from prerender pages"
rg -Fq 'RejectsInvalidBrowserOwnedTopSiteForNestedPendingNavigation' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must reject invalid browser-owned nested top sites"
rg -Fq 'SubframePendingNavigationRejectsOpaquePrimaryTopFrameSite' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must reject opaque nested top-frame attribution"
rg -Fq 'SubframeNavigationWithoutPolicyPreservesNativePath' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must preserve native subframe navigation without Access policy"
rg -Fq 'SubframeNavigationUsesPrimaryPageProxy' \
  "$SUBFRAME_NAVIGATION_PATCH_FILE" ||
  fail "patch 0139 must browser-test proxied subframe navigation"
rg -Fq 'EvaluateRedirect' "$REDIRECT_REEVALUATION_PATCH_FILE" ||
  fail "patch 0140 must re-evaluate redirect targets before follow"
rg -Fq 'RebindOwnershipForRedirect' "$REDIRECT_REEVALUATION_PATCH_FILE" ||
  fail "patch 0140 must rebind request ownership for each redirect hop"
rg -Fq 'pending_redirect_url_' "$REDIRECT_REEVALUATION_PATCH_FILE" ||
  fail "patch 0140 must hold redirect follow until browser re-evaluation"
rg -Fq 'redirected_record.request_id != stable_request_id' \
  "$REDIRECT_REEVALUATION_PATCH_FILE" ||
  fail "patch 0140 must preserve one stable logical request identity"
rg -Fq 'SameHostRedirectReevaluatesThroughProxy' \
  "$REDIRECT_REEVALUATION_PATCH_FILE" ||
  fail "patch 0140 must browser-test same-host redirect re-evaluation"
rg -Fq 'MainNavigationRedirectReevaluatesThroughProxy' \
  "$REDIRECT_REEVALUATION_PATCH_FILE" ||
  fail "patch 0140 must browser-test main-navigation redirects"
rg -Fq 'SubframeNavigationRedirectReevaluatesThroughProxy' \
  "$REDIRECT_REEVALUATION_PATCH_FILE" ||
  fail "patch 0140 must preserve 0139 subframe attribution across redirects"
rg -Fq 'RedirectToUnselectedHostFailsClosed' \
  "$REDIRECT_REEVALUATION_PATCH_FILE" ||
  fail "patch 0140 must fail closed when redirect target lacks a selected proxy"
rg -Fq 'URLLoaderFactoryType::kWorkerMainResource' \
  "$WORKER_MAIN_RESOURCE_PATCH_FILE" ||
  fail "patch 0141 must wire the Chromium Worker main-resource factory"
rg -Fq 'MaybeProxyWorkerMainResource' "$WORKER_MAIN_RESOURCE_PATCH_FILE" ||
  fail "patch 0141 must install the Aegis Worker main-resource wrapper"
rg -Fq 'RequestAttributionKind::kDocument' "$WORKER_MAIN_RESOURCE_PATCH_FILE" ||
  fail "patch 0141 must require browser-owned document attribution for Worker main scripts"
rg -Fq 'WorkerMainResourceWithoutPolicyPreservesNativePath' \
  "$WORKER_MAIN_RESOURCE_PATCH_FILE" ||
  fail "patch 0141 must browser-test native Worker main-resource behavior"
rg -Fq 'WorkerMainResourceUsesSelectedProxy' \
  "$WORKER_MAIN_RESOURCE_PATCH_FILE" ||
  fail "patch 0141 must browser-test proxied Worker main-resource behavior"
rg -Fq 'WorkerMainResourceWithoutEndpointFailsClosed' \
  "$WORKER_MAIN_RESOURCE_PATCH_FILE" ||
  fail "patch 0141 must fail closed when Worker PROXY lacks an endpoint"
if rg -Fq 'URLLoaderFactoryType::kWorkerSubResource' \
  "$WORKER_MAIN_RESOURCE_PATCH_FILE"; then
  fail "patch 0141 must not claim Worker subresource coverage"
fi
if rg -Fq 'URLLoaderFactoryType::kServiceWorker' \
  "$WORKER_MAIN_RESOURCE_PATCH_FILE"; then
  fail "patch 0141 must not claim ServiceWorker coverage"
fi
rg -Fq 'URLLoaderFactoryType::kWorkerSubResource && frame' \
  "$WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0142 must gate Worker subresources on a browser-owned frame"
rg -Fq 'MaybeProxyWorkerSubResource' "$WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0142 must install the Worker subresource wrapper"
rg -Fq 'Frame-less SharedWorker subresources' "$WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0142 must document the frame-less SharedWorker exclusion"
rg -Fq 'WorkerSubresourceWithoutPolicyPreservesNativePath' \
  "$WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0142 must preserve native Worker subresources without policy"
rg -Fq 'WorkerSubresourceUsesSelectedProxy' \
  "$WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0142 must browser-test selected proxy Worker subresources"
rg -Fq 'WorkerSubresourceWithoutEndpointFailsClosed' \
  "$WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0142 must fail closed when Worker subresource PROXY lacks an endpoint"
if rg -Fq 'URLLoaderFactoryType::kServiceWorker' \
  "$WORKER_SUBRESOURCE_PATCH_FILE"; then
  fail "patch 0142 must not claim ServiceWorker coverage"
fi
rg -Fq 'BuildBrowserOwnedProfileOnlyRequestMetadata' \
  "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must expose the browser-owned Profile-only process bridge"
rg -Fq 'RenderProcessHost::FromID' "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must bind Profile-only ownership to a browser-owned render process"
rg -Fq 'process->GetStoragePartition()' "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must resolve the trusted render process StoragePartition"
rg -Fq 'BuildBrowserOwnedProfileRequestMetadata' \
  "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must expose exact StoragePartition Profile-only ownership"
rg -Fq 'AccessBrowserRequestMetadataStatus::kUnconfiguredPartition' \
  "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must fail closed for an unconfigured background partition"
rg -Fq 'OwnsConfiguredPartition' "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must bind Profile-only ownership to a configured Access partition"
rg -Fq 'transport, /*require_configured_partition=*/false, owner);' \
  "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must preserve frame-owned ownership without background pre-configuration"
rg -Fq 'RequestAttributionKind::kProfileOnly' \
  "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must produce Profile-only request attribution"
rg -Fq 'ProfileOnlyMetadataUsesRenderProcessPartitionWithoutSiteIdentity' \
  "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must browser-test process-owned Profile-only metadata"
rg -Fq 'ProfileOnlyMetadataRejectsUnknownRenderProcess' \
  "$PROFILE_ONLY_BACKGROUND_PATCH_FILE" ||
  fail "patch 0143 must fail closed for an unknown render process"
rg -Fq 'BackgroundMetadataDoesNotCreateTransport' \
  "$PROFILE_ONLY_BACKGROUND_TEST" ||
  fail "0143 contract must not create transport while resolving background ownership"
rg -Fq 'BackgroundMetadataRequiresConfiguredPartition' \
  "$PROFILE_ONLY_BACKGROUND_TEST" ||
  fail "0143 contract must reject unconfigured background partitions"
rg -Fq 'BackgroundMetadataUsesProfileOnlyConfiguredPartitionOwnership' \
  "$PROFILE_ONLY_BACKGROUND_TEST" ||
  fail "0143 contract must prove configured Profile-only ownership"
rg -Fq 'BackgroundMetadataRejectsCrossProfilePartition' \
  "$PROFILE_ONLY_BACKGROUND_TEST" ||
  fail "0143 contract must reject cross-Profile partitions"
rg -Fq 'BackgroundMetadataRejectsMissingPartition' \
  "$PROFILE_ONLY_BACKGROUND_TEST" ||
  fail "0143 contract must reject a missing partition"
if rg -Fq 'URLLoaderFactoryType::kServiceWorker' \
  "$PROFILE_ONLY_BACKGROUND_PATCH_FILE"; then
  fail "patch 0143 must not wire ServiceWorker URLLoader factories"
fi
rg -Fq 'if (type == URLLoaderFactoryType::kWorkerSubResource)' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0144 must include frame-less Worker subresource factories"
rg -Fq 'render_process_id, factory_builder' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0144 must pass the browser-owned render process id"
rg -Fq 'CaptureProfileOnlyProxyFactoryMetadata' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0144 must capture Profile-only Worker ownership"
rg -Fq 'if (!aegis::IsAegisProfileSupported(profile))' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0144 must reject unsupported Profiles before Profile-only capture"
rg -Fq 'BuildBrowserOwnedProfileOnlyRequestMetadata' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0144 must re-evaluate Profile-only ownership per request"
rg -Fq 'profile_only_render_process_id_' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0144 must retain the trusted process source for re-evaluation"
rg -Fq 'SharedWorkerSubresourceWithoutPolicyPreservesNativePath' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0144 must preserve native SharedWorker subresources without policy"
rg -Fq 'SharedWorkerSubresourceUsesSelectedProxy' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0144 must browser-test proxied SharedWorker subresources"
rg -Fq 'SharedWorkerSubresourceWithoutEndpointFailsClosed' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE" ||
  fail "patch 0144 must fail closed when SharedWorker PROXY lacks an endpoint"
if rg -Fq 'URLLoaderFactoryType::kServiceWorker' \
  "$FRAMELESS_WORKER_SUBRESOURCE_PATCH_FILE"; then
  fail "patch 0144 must not claim ServiceWorker coverage"
fi
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
[[ "$(rg -F -c '0128-feat-aegis-own-committed-policy-generation.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0128 must appear once in series"
[[ "$(rg -F -c '0129-feat-aegis-own-browser-network-epoch.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0129 must appear once in series"
[[ "$(rg -F -c '0130-feat-aegis-own-profile-identity-generation.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0130 must appear once in series"
[[ "$(rg -F -c '0131-feat-aegis-own-proxy-selection-generation.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0131 must appear once in series"
[[ "$(rg -F -c '0132-feat-aegis-own-base-proxy-config-generation.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0132 must appear once in series"
[[ "$(rg -F -c '0133-feat-aegis-publish-request-generation-runtime.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0133 must appear once in series"
[[ "$(rg -F -c '0134-fix-aegis-harden-published-runtime-thread-boundary.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0134 must appear once in series"
[[ "$(rg -F -c '0135-feat-aegis-gate-real-document-url-loader-traffic.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0135 must appear once in series"
[[ "$(rg -F -c '0136-feat-aegis-terminate-in-flight-access-requests.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0136 must appear once in series"
[[ "$(rg -F -c '0137-feat-aegis-version-policy-publication-acks.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "0137 must appear once in series"
[[ "$(rg -F -c '0138-feat-aegis-gate-real-navigation-url-loader-traffic.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0138 must appear once in series"
[[ "$(rg -F -c '0139-feat-aegis-gate-primary-page-subframe-navigation.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0139 must appear once in series"
[[ "$(rg -F -c '0140-feat-aegis-reevaluate-proxied-redirects.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0140 must appear once in series"
[[ "$(rg -F -c '0141-feat-aegis-gate-worker-main-resource-traffic.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0141 must appear once in series"
[[ "$(rg -F -c '0142-feat-aegis-gate-worker-subresource-traffic.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0142 must appear once in series"
[[ "$(rg -F -c '0143-feat-aegis-add-profile-only-background-ownership.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0143 must appear once in series"
[[ "$(rg -F -c '0144-feat-aegis-gate-frameless-worker-subresource-traffic.patch' \
  "$SERIES_FILE")" == 1 ]] || fail "patch 0144 must appear once in series"
expected_access_tail="$(cat <<'EOF'
0115-feat-aegis-add-trusted-policy-context-matching.patch
0116-feat-aegis-add-access-rule-store-recovery.patch
0117-feat-aegis-add-fail-closed-proxy-route-adapter.patch
0118-feat-aegis-bind-profile-network-context-proxy.patch
0119-test-aegis-local-proxy-network-acceptance.patch
0120-test-aegis-expand-access-cpp-regressions.patch
0121-feat-aegis-add-request-ownership-registry.patch
0122-feat-aegis-add-targeted-request-cancellation.patch
0123-feat-aegis-add-request-dispatch-block-barriers.patch
0124-refactor-aegis-request-ownership-contracts.patch
0125-feat-aegis-enforce-request-dispatch-gate.patch
0126-feat-aegis-add-browser-owned-request-metadata-adapter.patch
0127-feat-aegis-add-published-request-runtime.patch
0128-feat-aegis-own-committed-policy-generation.patch
0129-feat-aegis-own-browser-network-epoch.patch
0130-feat-aegis-own-profile-identity-generation.patch
0131-feat-aegis-own-proxy-selection-generation.patch
0132-feat-aegis-own-base-proxy-config-generation.patch
0133-feat-aegis-publish-request-generation-runtime.patch
0134-fix-aegis-harden-published-runtime-thread-boundary.patch
0135-feat-aegis-gate-real-document-url-loader-traffic.patch
0136-feat-aegis-terminate-in-flight-access-requests.patch
0137-feat-aegis-version-policy-publication-acks.patch
0138-feat-aegis-gate-real-navigation-url-loader-traffic.patch
0139-feat-aegis-gate-primary-page-subframe-navigation.patch
0140-feat-aegis-reevaluate-proxied-redirects.patch
0141-feat-aegis-gate-worker-main-resource-traffic.patch
0142-feat-aegis-gate-worker-subresource-traffic.patch
0143-feat-aegis-add-profile-only-background-ownership.patch
0144-feat-aegis-gate-frameless-worker-subresource-traffic.patch
EOF
)"
[[ "$(tail -n 30 "$SERIES_FILE")" == "$expected_access_tail" ]] ||
  fail "Access patch tail must remain sequential through patch 0144"

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