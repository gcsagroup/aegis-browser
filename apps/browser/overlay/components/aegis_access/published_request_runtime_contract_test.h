// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_PUBLISHED_REQUEST_RUNTIME_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_PUBLISHED_REQUEST_RUNTIME_CONTRACT_TEST_H_

#include <string>
#include <utility>

#include "components/aegis_access/published_request_runtime.h"
#include "components/aegis_access/request_ownership_registry_test_support.h"

namespace aegis_access::test {
namespace published_request_runtime_test_detail {

inline PublishedRequestRuntimeInput ReadyRuntimeInput(
    std::string request_id = "runtime-ready") {
  PublishedRequestRuntimeInput input;
  input.request = DocumentOwnershipRecord(std::move(request_id));
  input.policy_state = PolicyState::kValid;
  input.effective_mode = AccessMode::kProxy;
  input.policy_scope = PolicyScope::kSite;
  input.effective_proxy_group_id = "runtime-proxy-group";
  input.matched_policy_generation = input.request.generations.policy_generation;
  input.require_proxy_intent = true;
  input.snapshot_state = SnapshotState::kPublished;
  input.snapshot_owner = input.request.owner;
  input.snapshot_generations = input.request.generations;
  input.protection_restriction = ProtectionRestriction::kNone;
  input.managed_restriction = ManagedRestriction::kNone;
  input.runtime_state = ProxyRuntimeState::kReady;
  input.registered_proxy_entry =
      RegisteredProxyEntry{"runtime-entry", input.effective_proxy_group_id,
                           input.request.owner, input.request.generations};
  return input;
}

inline void ExpectReadyProxyRegisters(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  const PublishedRequestRuntimeInput input = ReadyRuntimeInput();
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(
      result.status == PublishedRequestRuntimeStatus::kDispatchRegistered &&
          result.route_plan.action == RouteAction::kUseRegisteredProxy &&
          result.dispatch_gate.decision == RequestDispatchDecision::kAllow &&
          ownership.Lookup(input.request.request_id, input.request.owner,
                           input.request.generations)
                  .status == RequestOwnershipStatus::kOk,
      "published runtime unit ready proxy registers before dispatch");
}

inline void ExpectDirectPreservesNativeAndRegisters(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  PublishedRequestRuntimeInput input = ReadyRuntimeInput("runtime-direct");
  input.effective_mode = AccessMode::kDirect;
  input.effective_proxy_group_id.clear();
  input.require_proxy_intent = false;
  input.runtime_state = ProxyRuntimeState::kStopped;
  input.registered_proxy_entry.reset();
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(
      result.status == PublishedRequestRuntimeStatus::kDispatchRegistered &&
          result.route_plan.action == RouteAction::kPreserveNative &&
          ownership.size() == 1u,
      "published runtime unit direct preserves native after registration");
}

inline void ExpectWaitDoesNotRegister(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  PublishedRequestRuntimeInput input = ReadyRuntimeInput("runtime-wait");
  input.snapshot_state = SnapshotState::kRestoring;
  input.matched_policy_generation = 0;
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(result.status == PublishedRequestRuntimeStatus::kWait &&
                      result.route_plan.action == RouteAction::kWait &&
                      ownership.size() == 0u,
                  "published runtime unit wait never registers");
}

inline void ExpectDenyDoesNotRegister(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  PublishedRequestRuntimeInput input = ReadyRuntimeInput("runtime-deny");
  input.protection_restriction = ProtectionRestriction::kDeny;
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(result.status == PublishedRequestRuntimeStatus::kDeny &&
                      result.route_plan.action == RouteAction::kDeny &&
                      ownership.size() == 0u,
                  "published runtime unit deny never registers");
}

inline void ExpectStalePolicyGenerationFailsClosed(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  PublishedRequestRuntimeInput input =
      ReadyRuntimeInput("runtime-stale-policy");
  --input.matched_policy_generation;
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(
      result.status == PublishedRequestRuntimeStatus::kStalePolicyGeneration &&
          result.route_plan.action == RouteAction::kFail &&
          result.route_plan.reason == RouteReason::kStaleGeneration &&
          ownership.size() == 0u,
      "published runtime regression stale policy generation fails closed");
}

inline void ExpectIncompleteRequestGenerationFailsClosed(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  PublishedRequestRuntimeInput input =
      ReadyRuntimeInput("runtime-zero-generation");
  input.request.generations.identity_generation = 0;
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(result.status == PublishedRequestRuntimeStatus::kFail &&
                      result.route_plan.action == RouteAction::kFail &&
                      ownership.size() == 0u,
                  "published runtime regression incomplete tuple fails closed");
}

inline void ExpectSnapshotGenerationMismatchFailsClosed(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  PublishedRequestRuntimeInput input =
      ReadyRuntimeInput("runtime-stale-snapshot");
  ++input.snapshot_generations.network_epoch;
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(result.status == PublishedRequestRuntimeStatus::kFail &&
                      result.route_plan.reason ==
                          RouteReason::kStaleGeneration &&
                      ownership.size() == 0u,
                  "published runtime regression stale snapshot fails closed");
}

inline void ExpectBarrierBlocksBeforeRegistration(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  observer.Expect(barriers.InstallBlockBarrier(DocumentBlockBarrier()) ==
                      RequestDispatchBarrierStatus::kOk,
                  "published runtime regression installs block barrier");
  PublishedRequestRuntimeInput input =
      ReadyRuntimeInput("runtime-barrier-blocked");
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(
      result.status == PublishedRequestRuntimeStatus::kBlockedByBarrier &&
          result.dispatch_gate.decision == RequestDispatchDecision::kBlock &&
          ownership.size() == 0u,
      "published runtime regression barrier blocks before registration");
}

inline void ExpectDuplicateRegistrationFailsClosed(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  PublishedRequestRuntimeInput input =
      ReadyRuntimeInput("runtime-duplicate");
  observer.Expect(ownership.Register(input.request) ==
                      RequestOwnershipStatus::kOk,
                  "published runtime regression seeds duplicate");
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(
      result.status == PublishedRequestRuntimeStatus::kRegistrationFailed &&
          result.dispatch_gate.ownership_status ==
              RequestOwnershipStatus::kDuplicateRequestId &&
          ownership.size() == 1u,
      "published runtime regression duplicate never dispatches");
}

inline void ExpectConflictFailsBeforeRegistration(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  PublishedRequestRuntimeInput input =
      ReadyRuntimeInput("runtime-conflict");
  input.policy_state = PolicyState::kConflict;
  const PublishedRequestRuntimeResult result =
      EvaluatePublishedRequestForDispatch(input, barriers, ownership);
  observer.Expect(result.status == PublishedRequestRuntimeStatus::kFail &&
                      result.route_plan.reason ==
                          RouteReason::kPolicyConflict &&
                      ownership.size() == 0u,
                  "published runtime regression policy conflict fails closed");
}

}  // namespace published_request_runtime_test_detail

inline void RunPublishedRequestRuntimeUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  published_request_runtime_test_detail::ExpectReadyProxyRegisters(observer);
  published_request_runtime_test_detail::ExpectDirectPreservesNativeAndRegisters(
      observer);
  published_request_runtime_test_detail::ExpectWaitDoesNotRegister(observer);
  published_request_runtime_test_detail::ExpectDenyDoesNotRegister(observer);
}

inline void RunPublishedRequestRuntimeRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  published_request_runtime_test_detail::ExpectStalePolicyGenerationFailsClosed(
      observer);
  published_request_runtime_test_detail::
      ExpectIncompleteRequestGenerationFailsClosed(observer);
  published_request_runtime_test_detail::
      ExpectSnapshotGenerationMismatchFailsClosed(observer);
  published_request_runtime_test_detail::ExpectBarrierBlocksBeforeRegistration(
      observer);
  published_request_runtime_test_detail::
      ExpectDuplicateRegistrationFailsClosed(observer);
  published_request_runtime_test_detail::ExpectConflictFailsBeforeRegistration(
      observer);
}

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_PUBLISHED_REQUEST_RUNTIME_CONTRACT_TEST_H_
