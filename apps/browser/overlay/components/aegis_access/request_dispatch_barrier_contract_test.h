// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_DISPATCH_BARRIER_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_DISPATCH_BARRIER_CONTRACT_TEST_H_

#include "components/aegis_access/request_ownership_registry_test_support.h"

namespace aegis_access::test {

inline void RunRequestDispatchBarrierGenerationUnitTests(
    RequestOwnershipRegistryTestObserver& observer,
    const RequestDispatchBarrierRegistry& barriers,
    const RequestDispatchBarrier& barrier,
    const RequestOwnershipRecord& old_generation) {
  RequestOwnershipRecord new_generation =
      DocumentOwnershipRecord("barrier-new-generation");
  ++new_generation.generations.policy_generation;
  ++new_generation.generations.identity_generation;
  ++new_generation.generations.selection_generation;
  ++new_generation.generations.network_epoch;
  ++new_generation.generations.base_proxy_config_generation;

  const RequestDispatchEvaluationResult old_result =
      barriers.EvaluateRequest(old_generation);
  const RequestDispatchEvaluationResult new_result =
      barriers.EvaluateRequest(new_generation);
  observer.Expect(old_result.status == RequestDispatchBarrierStatus::kOk &&
                      old_result.decision == RequestDispatchDecision::kBlock &&
                      old_result.barrier.has_value(),
                  "barrier unit blocks old generation request");
  observer.Expect(new_result.status == RequestDispatchBarrierStatus::kOk &&
                      new_result.decision == RequestDispatchDecision::kBlock &&
                      new_result.barrier.has_value(),
                  "barrier unit blocks new generation request");
  if (old_result.barrier) {
    observer.Expect(old_result.barrier->operation_id == barrier.operation_id &&
                        old_result.barrier->operation_sequence ==
                            barrier.operation_sequence,
                    "barrier unit returns owning operation");
  }
}

inline void RunRequestDispatchBarrierReleaseUnitTests(
    RequestOwnershipRegistryTestObserver& observer,
    RequestDispatchBarrierRegistry& barriers,
    const RequestDispatchBarrier& barrier,
    const RequestOwnershipRecord& old_generation) {
  RequestOwnershipRecord nonmatch = old_generation;
  nonmatch.request_id = "barrier-nonmatch";
  nonmatch.exact_host = "other.example.test";
  const RequestDispatchEvaluationResult nonmatch_result =
      barriers.EvaluateRequest(nonmatch);
  observer.Expect(nonmatch_result.status == RequestDispatchBarrierStatus::kOk &&
                      nonmatch_result.decision == RequestDispatchDecision::kAllow &&
                      !nonmatch_result.barrier,
                  "barrier unit allows nonmatching request");

  observer.Expect(
      barriers.InstallBlockBarrier(barrier) == RequestDispatchBarrierStatus::kOk &&
          barriers.size() == 1u,
      "barrier unit exact reinstall is idempotent");
  observer.Expect(
      barriers.ReleaseBlockBarrier(barrier.selector, barrier.operation_id,
                                   barrier.operation_sequence) ==
          RequestDispatchBarrierStatus::kOk,
      "barrier unit exact release");
  observer.Expect(barriers.size() == 0u, "barrier unit release removes barrier");
  observer.Expect(barriers.EvaluateRequest(old_generation).decision ==
                      RequestDispatchDecision::kAllow,
                  "barrier unit request allowed after release");
}

inline void RunRequestDispatchBarrierPendingNavigationUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry pending_barriers(2);
  RequestDispatchBarrier pending_barrier{
      "pending-block", 7, PendingCancellationSelector()};
  observer.Expect(pending_barriers.InstallBlockBarrier(pending_barrier) ==
                      RequestDispatchBarrierStatus::kOk,
                  "barrier unit install pending navigation barrier");
  observer.Expect(pending_barriers.EvaluateRequest(PendingOwnershipRecord()).decision ==
                      RequestDispatchDecision::kBlock,
                  "barrier unit blocks exact pending navigation");
}

inline void RunRequestDispatchBarrierUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  const RequestDispatchBarrier barrier = DocumentBlockBarrier();
  observer.Expect(
      barriers.InstallBlockBarrier(barrier) == RequestDispatchBarrierStatus::kOk,
      "barrier unit install");
  observer.Expect(barriers.size() == 1u, "barrier unit size after install");
  const RequestOwnershipRecord old_generation =
      DocumentOwnershipRecord("barrier-old-generation");
  RunRequestDispatchBarrierGenerationUnitTests(observer, barriers, barrier,
                                               old_generation);
  RunRequestDispatchBarrierReleaseUnitTests(observer, barriers, barrier,
                                            old_generation);
  RunRequestDispatchBarrierPendingNavigationUnitTests(observer);
}

inline void RunRequestDispatchBarrierStaleOperationRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(4);
  const RequestDispatchBarrier original = DocumentBlockBarrier("old-op", 10);
  RequestDispatchBarrier newer = DocumentBlockBarrier("new-op", 20);
  observer.Expect(barriers.InstallBlockBarrier(original) ==
                      RequestDispatchBarrierStatus::kOk,
                  "barrier regression install original");
  observer.Expect(barriers.InstallBlockBarrier(newer) ==
                      RequestDispatchBarrierStatus::kOk,
                  "barrier regression newer operation replaces scope");
  observer.Expect(barriers.size() == 1u,
                  "barrier regression replacement keeps one scope");
  const RequestDispatchEvaluationResult after_replace =
      barriers.EvaluateRequest(DocumentOwnershipRecord("after-replace"));
  observer.Expect(after_replace.decision == RequestDispatchDecision::kBlock &&
                      after_replace.barrier &&
                      after_replace.barrier->operation_id == "new-op" &&
                      after_replace.barrier->operation_sequence == 20,
                  "barrier regression newer operation owns scope");
  observer.Expect(
      barriers.InstallBlockBarrier(DocumentBlockBarrier("stale-install", 15)) ==
          RequestDispatchBarrierStatus::kStaleOperation,
      "barrier regression stale install rejected");
  observer.Expect(
      barriers.ReleaseBlockBarrier(original.selector, original.operation_id,
                                   original.operation_sequence) ==
          RequestDispatchBarrierStatus::kStaleOperation,
      "barrier regression stale release cannot clear newer barrier");
  observer.Expect(barriers.EvaluateRequest(
                      DocumentOwnershipRecord("after-stale-release"))
                      .decision == RequestDispatchDecision::kBlock,
                  "barrier regression stale release leaves block active");
  observer.Expect(
      barriers.ReleaseBlockBarrier(newer.selector, newer.operation_id,
                                   newer.operation_sequence) ==
          RequestDispatchBarrierStatus::kOk,
      "barrier regression exact newer release succeeds");
}

inline void RunRequestDispatchBarrierIsolationRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(2);
  observer.Expect(barriers.InstallBlockBarrier(DocumentBlockBarrier()) ==
                      RequestDispatchBarrierStatus::kOk,
                  "barrier regression isolation base install");
  const RequestOwnershipRecord matching =
      DocumentOwnershipRecord("barrier-match");
  RequestOwnershipRecord other_document = matching;
  other_document.request_id = "barrier-other-document";
  other_document.document_token = "other-document-token";
  RequestOwnershipRecord other_profile = matching;
  other_profile.request_id = "barrier-other-profile";
  other_profile.owner.profile_token = "other-profile";
  RequestOwnershipRecord other_partition = matching;
  other_partition.request_id = "barrier-other-partition";
  other_partition.owner.storage_partition_token = "other-partition";
  RequestOwnershipRecord other_site = matching;
  other_site.request_id = "barrier-other-site";
  other_site.top_level_site = "https://other-top.example.test";
  RequestOwnershipRecord other_host = matching;
  other_host.request_id = "barrier-other-host";
  other_host.exact_host = "other.example.test";
  RequestOwnershipRecord other_scheme = matching;
  other_scheme.request_id = "barrier-other-scheme";
  other_scheme.scheme = RequestScheme::kHttp;
  RequestOwnershipRecord other_port = matching;
  other_port.request_id = "barrier-other-port";
  other_port.port = 8443;
  RequestOwnershipRecord background = ProfileOwnershipRecord("barrier-background");
  background.exact_host = matching.exact_host;
  const std::vector<RequestOwnershipRecord> allowed = {
      other_document, other_profile, other_partition, other_site,
      other_host,     other_scheme,  other_port,      background};
  for (const auto& record : allowed) {
    const RequestDispatchEvaluationResult result =
        barriers.EvaluateRequest(record);
    observer.Expect(result.status == RequestDispatchBarrierStatus::kOk &&
                        result.decision == RequestDispatchDecision::kAllow,
                    "barrier regression isolates nonmatching scope");
  }
}

inline void RunRequestDispatchBarrierValidationRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(1);
  RequestDispatchBarrier invalid = DocumentBlockBarrier();
  invalid.operation_id.clear();
  observer.Expect(barriers.InstallBlockBarrier(invalid) ==
                      RequestDispatchBarrierStatus::kInvalidBarrier,
                  "barrier regression empty operation id rejected");
  invalid = DocumentBlockBarrier();
  invalid.operation_sequence = 0;
  observer.Expect(barriers.InstallBlockBarrier(invalid) ==
                      RequestDispatchBarrierStatus::kInvalidBarrier,
                  "barrier regression zero operation sequence rejected");
  invalid = DocumentBlockBarrier();
  invalid.selector.document_token.clear();
  observer.Expect(barriers.InstallBlockBarrier(invalid) ==
                      RequestDispatchBarrierStatus::kInvalidBarrier,
                  "barrier regression invalid selector rejected");
  observer.Expect(barriers.size() == 0u,
                  "barrier regression invalid installs never mutate state");
  const RequestDispatchBarrier first = DocumentBlockBarrier("capacity-a", 1);
  RequestDispatchBarrier second = first;
  second.operation_id = "capacity-b";
  second.operation_sequence = 2;
  second.selector.document_token = "second-document-token";
  observer.Expect(barriers.InstallBlockBarrier(first) ==
                      RequestDispatchBarrierStatus::kOk,
                  "barrier regression capacity first install");
  observer.Expect(barriers.InstallBlockBarrier(second) ==
                      RequestDispatchBarrierStatus::kCapacityExceeded,
                  "barrier regression capacity overflow fails closed");
  observer.Expect(barriers.size() == 1u,
                  "barrier regression capacity overflow preserves state");
}

inline void RunRequestDispatchBarrierInvalidRequestRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestDispatchBarrierRegistry barriers(2);
  const RequestDispatchBarrier barrier = DocumentBlockBarrier();
  observer.Expect(barriers.InstallBlockBarrier(barrier) ==
                      RequestDispatchBarrierStatus::kOk,
                  "barrier regression invalid request base install");
  RequestOwnershipRecord invalid_request =
      DocumentOwnershipRecord("invalid-dispatch-request");
  invalid_request.generations.policy_generation = 0;
  const RequestDispatchEvaluationResult invalid_result =
      barriers.EvaluateRequest(invalid_request);
  observer.Expect(
      invalid_result.status == RequestDispatchBarrierStatus::kInvalidRequest &&
          invalid_result.decision == RequestDispatchDecision::kBlock &&
          !invalid_result.barrier,
      "barrier regression malformed controlled request fails closed");
  observer.Expect(
      barriers.ReleaseBlockBarrier(barrier.selector, "wrong-op",
                                   barrier.operation_sequence) ==
          RequestDispatchBarrierStatus::kStaleOperation,
      "barrier regression wrong operation id cannot release");
  observer.Expect(
      barriers.ReleaseBlockBarrier(barrier.selector, barrier.operation_id,
                                   barrier.operation_sequence + 1) ==
          RequestDispatchBarrierStatus::kStaleOperation,
      "barrier regression wrong operation sequence cannot release");
  observer.Expect(barriers.size() == 1u,
                  "barrier regression failed releases keep barrier installed");
}

inline void RunRequestDispatchBarrierRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RunRequestDispatchBarrierStaleOperationRegressionTests(observer);
  RunRequestDispatchBarrierIsolationRegressionTests(observer);
  RunRequestDispatchBarrierValidationRegressionTests(observer);
  RunRequestDispatchBarrierInvalidRequestRegressionTests(observer);
}


}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_DISPATCH_BARRIER_CONTRACT_TEST_H_
