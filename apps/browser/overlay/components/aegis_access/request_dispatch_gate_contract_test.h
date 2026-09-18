// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_DISPATCH_GATE_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_DISPATCH_GATE_CONTRACT_TEST_H_

#include "components/aegis_access/request_dispatch_gate.h"
#include "components/aegis_access/request_ownership_registry_contract_test.h"

namespace aegis_access::test {

namespace request_dispatch_gate_test_detail {

inline void ExpectAllowRegistersOwnership(
    RequestOwnershipRegistryTestObserver& observer,
    RequestDispatchBarrierRegistry& barriers,
    RequestOwnershipRegistry& ownership) {
  const RequestOwnershipRecord allowed = DocumentOwnershipRecord("gate-unit-allow");
  const RequestDispatchGateResult allowed_result =
      EvaluateAndRegisterRequestForDispatch(allowed, &barriers, &ownership);
  observer.Expect(allowed_result.status == RequestDispatchGateStatus::kAllowRegistered &&
                      allowed_result.decision == RequestDispatchDecision::kAllow &&
                      allowed_result.ownership_status == RequestOwnershipStatus::kOk,
                  "dispatch gate unit registers before allow");
  observer.Expect(ownership.Lookup(allowed.request_id, allowed.owner,
                                   allowed.generations)
                      .status == RequestOwnershipStatus::kOk,
                  "dispatch gate unit allowed request is registered");
}

inline void ExpectBarrierBlocksBeforeRegistration(
    RequestOwnershipRegistryTestObserver& observer,
    RequestDispatchBarrierRegistry& barriers,
    RequestOwnershipRegistry& ownership) {
  const RequestDispatchBarrier barrier = DocumentBlockBarrier();
  observer.Expect(barriers.InstallBlockBarrier(barrier) ==
                      RequestDispatchBarrierStatus::kOk,
                  "dispatch gate unit installs barrier");
  const RequestDispatchGateResult blocked = EvaluateAndRegisterRequestForDispatch(
      DocumentOwnershipRecord("gate-unit-blocked"), &barriers, &ownership);
  observer.Expect(blocked.status == RequestDispatchGateStatus::kBlockedByBarrier &&
                      blocked.decision == RequestDispatchDecision::kBlock &&
                      blocked.barrier.has_value(),
                  "dispatch gate unit blocks matching barrier");
  observer.Expect(ownership.size() == 1u,
                  "dispatch gate unit blocked request is never registered");
}

inline void ExpectMalformedRequestFailsClosed(
    RequestOwnershipRegistryTestObserver& observer,
    RequestDispatchBarrierRegistry& barriers,
    RequestOwnershipRegistry& ownership) {
  RequestOwnershipRecord invalid = DocumentOwnershipRecord("gate-unit-invalid");
  invalid.generations.policy_generation = 0;
  const RequestDispatchGateResult invalid_result =
      EvaluateAndRegisterRequestForDispatch(invalid, &barriers, &ownership);
  observer.Expect(invalid_result.status == RequestDispatchGateStatus::kInvalidRequest &&
                      invalid_result.decision == RequestDispatchDecision::kBlock,
                  "dispatch gate unit malformed request fails closed");
}

inline void ExpectPendingNavigationBlocksBeforeRegistration(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry pending_barriers(2);
  RequestOwnershipRegistry pending_ownership(2);
  observer.Expect(pending_barriers.InstallBlockBarrier(
                      RequestDispatchBarrier{"pending-gate", 8,
                                             PendingCancellationSelector()}) ==
                      RequestDispatchBarrierStatus::kOk,
                  "dispatch gate unit installs pending barrier");
  observer.Expect(EvaluateAndRegisterRequestForDispatch(
                      PendingOwnershipRecord("gate-unit-pending"),
                      &pending_barriers, &pending_ownership)
                      .decision == RequestDispatchDecision::kBlock &&
                      pending_ownership.size() == 0u,
                  "dispatch gate unit blocks pending navigation before register");
}

inline void ExpectMissingDependenciesFailClosed(
    RequestOwnershipRegistryTestObserver& observer,
    RequestDispatchBarrierRegistry& barriers,
    RequestOwnershipRegistry& ownership) {
  observer.Expect(EvaluateAndRegisterRequestForDispatch(
                      DocumentOwnershipRecord("gate-null-barriers"), nullptr,
                      &ownership)
                      .status == RequestDispatchGateStatus::kInvalidDependencies,
                  "dispatch gate unit missing barrier registry fails closed");
  observer.Expect(EvaluateAndRegisterRequestForDispatch(
                      DocumentOwnershipRecord("gate-null-ownership"), &barriers,
                      nullptr)
                      .status == RequestDispatchGateStatus::kInvalidDependencies,
                  "dispatch gate unit missing ownership registry fails closed");
}

inline void ExpectGenerationBarrierCannotBeBypassed(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  observer.Expect(barriers.InstallBlockBarrier(DocumentBlockBarrier()) ==
                      RequestDispatchBarrierStatus::kOk,
                  "dispatch gate regression installs generation-independent barrier");
  RequestOwnershipRecord old_generation =
      DocumentOwnershipRecord("gate-regression-old-generation");
  old_generation.generations = GenerationTuple{1, 2, 3, 4, 5};
  RequestOwnershipRecord new_generation =
      DocumentOwnershipRecord("gate-regression-new-generation");
  new_generation.generations = GenerationTuple{101, 102, 103, 104, 105};
  for (const auto& record : {old_generation, new_generation}) {
    const RequestDispatchGateResult result =
        EvaluateAndRegisterRequestForDispatch(record, &barriers, &ownership);
    observer.Expect(result.status == RequestDispatchGateStatus::kBlockedByBarrier &&
                        result.decision == RequestDispatchDecision::kBlock,
                    "dispatch gate regression generations cannot bypass barrier");
  }
  observer.Expect(ownership.size() == 0u,
                  "dispatch gate regression generation bypass registers nothing");
}

inline void ExpectOwnerIsolation(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  observer.Expect(barriers.InstallBlockBarrier(DocumentBlockBarrier()) ==
                      RequestDispatchBarrierStatus::kOk,
                  "dispatch gate regression installs owner isolation barrier");
  RequestOwnershipRecord other_profile =
      DocumentOwnershipRecord("gate-regression-other-profile");
  other_profile.owner.profile_token = "other-profile";
  RequestOwnershipRecord other_partition =
      DocumentOwnershipRecord("gate-regression-other-partition");
  other_partition.owner.storage_partition_token = "other-partition";
  for (const auto& record : {other_profile, other_partition}) {
    const RequestDispatchGateResult result =
        EvaluateAndRegisterRequestForDispatch(record, &barriers, &ownership);
    observer.Expect(result.status == RequestDispatchGateStatus::kAllowRegistered &&
                        result.decision == RequestDispatchDecision::kAllow &&
                        ownership.Lookup(record.request_id, record.owner,
                                         record.generations)
                                .status == RequestOwnershipStatus::kOk,
                    "dispatch gate regression isolates Profile and partition");
  }
}

inline void ExpectDuplicateRegistrationFailsClosed(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  const RequestOwnershipRecord duplicate =
      DocumentOwnershipRecord("gate-regression-duplicate");
  observer.Expect(ownership.Register(duplicate) == RequestOwnershipStatus::kOk,
                  "dispatch gate regression seeds duplicate");
  const RequestDispatchGateResult result =
      EvaluateAndRegisterRequestForDispatch(duplicate, &barriers, &ownership);
  observer.Expect(result.status == RequestDispatchGateStatus::kRegistrationFailed &&
                      result.decision == RequestDispatchDecision::kBlock &&
                      result.ownership_status ==
                          RequestOwnershipStatus::kDuplicateRequestId &&
                      ownership.size() == 1u,
                  "dispatch gate regression duplicate never falls through to allow");
}

inline void ExpectCapacityFailureFailsClosed(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(1);
  observer.Expect(ownership.Register(
                      ProfileOwnershipRecord("gate-regression-capacity-seed")) ==
                      RequestOwnershipStatus::kOk,
                  "dispatch gate regression fills ownership capacity");
  const RequestDispatchGateResult result = EvaluateAndRegisterRequestForDispatch(
      DocumentOwnershipRecord("gate-regression-capacity-new"), &barriers,
      &ownership);
  observer.Expect(result.status == RequestDispatchGateStatus::kRegistrationFailed &&
                      result.decision == RequestDispatchDecision::kBlock &&
                      result.ownership_status ==
                          RequestOwnershipStatus::kCapacityExceeded &&
                      ownership.size() == 1u,
                  "dispatch gate regression capacity failure never dispatches");
}

inline void ExpectBarrierPrecedesRegistryMutation(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  const RequestOwnershipRecord existing =
      ProfileOwnershipRecord("gate-regression-existing-background");
  observer.Expect(ownership.Register(existing) == RequestOwnershipStatus::kOk,
                  "dispatch gate regression seeds unrelated request");
  observer.Expect(barriers.InstallBlockBarrier(DocumentBlockBarrier()) ==
                      RequestDispatchBarrierStatus::kOk,
                  "dispatch gate regression installs page barrier");
  const RequestDispatchGateResult blocked =
      EvaluateAndRegisterRequestForDispatch(
          DocumentOwnershipRecord("gate-regression-blocked-new"), &barriers,
          &ownership);
  observer.Expect(blocked.status == RequestDispatchGateStatus::kBlockedByBarrier &&
                      ownership.size() == 1u &&
                      ownership.Lookup(existing.request_id, existing.owner,
                                       existing.generations)
                              .status == RequestOwnershipStatus::kOk,
                  "dispatch gate regression block precedes registry mutation");
}

}  // namespace request_dispatch_gate_test_detail

inline void RunRequestDispatchGateUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  RequestOwnershipRegistry ownership(4);
  request_dispatch_gate_test_detail::ExpectAllowRegistersOwnership(
      observer, barriers, ownership);
  request_dispatch_gate_test_detail::ExpectBarrierBlocksBeforeRegistration(
      observer, barriers, ownership);
  request_dispatch_gate_test_detail::ExpectMalformedRequestFailsClosed(
      observer, barriers, ownership);
  request_dispatch_gate_test_detail::ExpectPendingNavigationBlocksBeforeRegistration(
      observer);
  request_dispatch_gate_test_detail::ExpectMissingDependenciesFailClosed(
      observer, barriers, ownership);
}

inline void RunRequestDispatchGateRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  request_dispatch_gate_test_detail::ExpectGenerationBarrierCannotBeBypassed(observer);
  request_dispatch_gate_test_detail::ExpectOwnerIsolation(observer);
  request_dispatch_gate_test_detail::ExpectDuplicateRegistrationFailsClosed(observer);
  request_dispatch_gate_test_detail::ExpectCapacityFailureFailsClosed(observer);
  request_dispatch_gate_test_detail::ExpectBarrierPrecedesRegistryMutation(observer);
}

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_DISPATCH_GATE_CONTRACT_TEST_H_
