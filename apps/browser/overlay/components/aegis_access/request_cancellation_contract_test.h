// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_CANCELLATION_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_CANCELLATION_CONTRACT_TEST_H_

#include "components/aegis_access/request_ownership_registry_test_support.h"

namespace aegis_access::test {

inline void PrepareTargetedCancellationBatch(
    RequestOwnershipRegistryTestObserver& observer,
    RequestOwnershipRegistry& registry,
    RequestOwnershipRecord& old_request,
    RequestOwnershipRecord& new_request,
    RequestOwnershipRecord& queued_request,
    int* old_terminations,
    int* new_terminations) {
  ++new_request.generations.policy_generation;
  ++new_request.generations.identity_generation;
  ++queued_request.generations.network_epoch;
  observer.Expect(registry.Register(old_request) == RequestOwnershipStatus::kOk,
                  "targeted unit register old generation");
  observer.Expect(registry.Register(new_request) == RequestOwnershipStatus::kOk,
                  "targeted unit register new generation");
  observer.Expect(registry.Register(queued_request) == RequestOwnershipStatus::kOk,
                  "targeted unit register queued request");
  observer.Expect(
      registry.MarkDispatched(
          old_request.request_id, old_request.owner, old_request.generations,
          std::make_unique<RecordingTerminationHandle>(old_terminations)) ==
          RequestOwnershipStatus::kOk,
      "targeted unit dispatch old generation");
  observer.Expect(registry.MarkStreaming(old_request.request_id, old_request.owner,
                                         old_request.generations) ==
                      RequestOwnershipStatus::kOk,
                  "targeted unit stream old generation");
  observer.Expect(
      registry.MarkDispatched(
          new_request.request_id, new_request.owner, new_request.generations,
          std::make_unique<RecordingTerminationHandle>(new_terminations)) ==
          RequestOwnershipStatus::kOk,
      "targeted unit dispatch new generation");
}

inline void VerifyTargetedCancellationBatch(
    RequestOwnershipRegistryTestObserver& observer,
    const RequestOwnershipBatchCancelResult& cancelled,
    const RequestOwnershipRecord& old_request,
    const RequestOwnershipRecord& new_request,
    const RequestOwnershipRecord& queued_request,
    int old_terminations,
    int new_terminations) {
  observer.Expect(cancelled.status == RequestOwnershipStatus::kOk,
                  "targeted unit batch status");
  observer.Expect(cancelled.cancellations.size() == 3u,
                  "targeted unit cancels every matching generation");
  observer.Expect(old_terminations == 1 && new_terminations == 1,
                  "targeted unit invokes active handles once");
  const auto* old_cancel = FindCancellation(cancelled, old_request.request_id);
  const auto* new_cancel = FindCancellation(cancelled, new_request.request_id);
  const auto* queued_cancel = FindCancellation(cancelled, queued_request.request_id);
  observer.Expect(old_cancel && old_cancel->termination_invoked &&
                      old_cancel->previous_lifecycle ==
                          RequestOwnershipLifecycle::kStreaming,
                  "targeted unit reports streaming cancellation");
  observer.Expect(new_cancel && new_cancel->termination_invoked &&
                      new_cancel->previous_lifecycle ==
                          RequestOwnershipLifecycle::kDispatched,
                  "targeted unit reports dispatched cancellation");
  observer.Expect(queued_cancel && !queued_cancel->termination_invoked &&
                      queued_cancel->previous_lifecycle ==
                          RequestOwnershipLifecycle::kNew,
                  "targeted unit reports queued cancellation");
}

inline void RunTargetedAcrossGenerationsUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(8);
  auto old_request = DocumentOwnershipRecord("target-old");
  auto new_request = DocumentOwnershipRecord("target-new");
  auto queued_request = DocumentOwnershipRecord("target-queued");
  int old_terminations = 0;
  int new_terminations = 0;
  PrepareTargetedCancellationBatch(observer, registry, old_request, new_request,
                                   queued_request, &old_terminations,
                                   &new_terminations);
  const auto cancelled =
      registry.CancelMatchingPageTarget(DocumentCancellationSelector());
  observer.Expect(registry.size() == 0u,
                  "targeted unit removes all matching requests");
  VerifyTargetedCancellationBatch(observer, cancelled, old_request, new_request,
                                  queued_request, old_terminations,
                                  new_terminations);
  const auto repeated =
      registry.CancelMatchingPageTarget(DocumentCancellationSelector());
  observer.Expect(repeated.status == RequestOwnershipStatus::kOk &&
                      repeated.cancellations.empty(),
                  "targeted unit repeated batch is idempotently empty");
  observer.Expect(old_terminations == 1 && new_terminations == 1,
                  "targeted unit repeated batch never reterminates");
}

inline void RunTargetedPendingNavigationUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(2);
  const auto pending = PendingOwnershipRecord();
  observer.Expect(registry.Register(pending) == RequestOwnershipStatus::kOk,
                  "targeted unit register pending navigation");
  const auto cancelled =
      registry.CancelMatchingPageTarget(PendingCancellationSelector());
  observer.Expect(cancelled.status == RequestOwnershipStatus::kOk &&
                      cancelled.cancellations.size() == 1u &&
                      registry.size() == 0u,
                  "targeted unit pending navigation exact match");
}

inline void RunTargetedRequestCancellationUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RunTargetedAcrossGenerationsUnitTests(observer);
  RunTargetedPendingNavigationUnitTests(observer);
}


inline std::vector<RequestOwnershipRecord> TargetedIsolationSurvivors(
    const RequestOwnershipRecord& matching) {
  auto other_document = DocumentOwnershipRecord("other-document");
  other_document.document_token = "other-document-token";
  auto other_profile = DocumentOwnershipRecord("other-profile");
  other_profile.owner.profile_token = "other-profile-owner";
  auto other_partition = DocumentOwnershipRecord("other-partition");
  other_partition.owner.storage_partition_token = "other-partition-owner";
  auto background = ProfileOwnershipRecord("background");
  background.exact_host = matching.exact_host;
  auto other_host = DocumentOwnershipRecord("other-host");
  other_host.exact_host = "other.example.test";
  auto other_scheme = DocumentOwnershipRecord("other-scheme");
  other_scheme.scheme = RequestScheme::kHttp;
  auto other_port = DocumentOwnershipRecord("other-port");
  other_port.port = 8443;
  auto other_site = DocumentOwnershipRecord("other-site");
  other_site.top_level_site = "https://other-top.example.test";
  return {other_document, other_profile, other_partition, background,
          other_host, other_scheme, other_port, other_site};
}

inline void RunTargetedIsolationRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(16);
  const auto matching = DocumentOwnershipRecord("matching");
  observer.Expect(registry.Register(matching) == RequestOwnershipStatus::kOk,
                  "targeted regression register matching request");
  const auto survivors = TargetedIsolationSurvivors(matching);
  for (const auto& survivor : survivors) {
    observer.Expect(registry.Register(survivor) == RequestOwnershipStatus::kOk,
                    "targeted regression register isolation survivor");
  }
  const auto result =
      registry.CancelMatchingPageTarget(DocumentCancellationSelector());
  observer.Expect(result.status == RequestOwnershipStatus::kOk &&
                      result.cancellations.size() == 1u &&
                      FindCancellation(result, matching.request_id),
                  "targeted regression cancels only exact page target");
  observer.Expect(registry.size() == survivors.size(),
                  "targeted regression preserves every nonmatch");
  for (const auto& survivor : survivors) {
    observer.Expect(registry.Lookup(survivor.request_id, survivor.owner,
                                    survivor.generations)
                        .status == RequestOwnershipStatus::kOk,
                    "targeted regression nonmatch remains registered");
  }
}

inline std::vector<RequestCancellationSelector> InvalidCancellationSelectors() {
  std::vector<RequestCancellationSelector> selectors;
  auto selector = DocumentCancellationSelector();
  selector.document_token.clear();
  selectors.push_back(selector);
  selector = DocumentCancellationSelector();
  selector.pending_navigation_token = "also-pending";
  selectors.push_back(selector);
  selector = DocumentCancellationSelector();
  selector.owner.profile_token.clear();
  selectors.push_back(selector);
  selector = DocumentCancellationSelector();
  selector.top_level_site.clear();
  selectors.push_back(selector);
  selector = DocumentCancellationSelector();
  selector.exact_host.clear();
  selectors.push_back(selector);
  selector = DocumentCancellationSelector();
  selector.scheme = static_cast<RequestScheme>(99);
  selectors.push_back(selector);
  selector = DocumentCancellationSelector();
  selector.port = 0;
  selectors.push_back(selector);
  return selectors;
}

inline void RunTargetedInvalidSelectorRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(4);
  const auto record = DocumentOwnershipRecord("invalid-scope");
  observer.Expect(registry.Register(record) == RequestOwnershipStatus::kOk,
                  "targeted regression invalid selector base register");
  const size_t original_size = registry.size();
  for (const auto& selector : InvalidCancellationSelectors()) {
    const auto result = registry.CancelMatchingPageTarget(selector);
    observer.Expect(
        result.status == RequestOwnershipStatus::kInvalidCancellationSelector &&
            result.cancellations.empty(),
        "targeted regression invalid selector fails closed");
    observer.Expect(registry.size() == original_size,
                    "targeted regression invalid selector never mutates registry");
  }
  observer.Expect(registry.Lookup(record.request_id, record.owner,
                                  record.generations)
                      .status == RequestOwnershipStatus::kOk,
                  "targeted regression invalid selectors preserve request");
}


inline void RunTargetedBatchVisibilityRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(4);
  auto first = DocumentOwnershipRecord("batch-a");
  auto second = DocumentOwnershipRecord("batch-b");
  ++second.generations.policy_generation;
  observer.Expect(registry.Register(first) == RequestOwnershipStatus::kOk,
                  "targeted regression register batch first");
  observer.Expect(registry.Register(second) == RequestOwnershipStatus::kOk,
                  "targeted regression register batch second");
  const std::vector<BatchVisibilityTerminationHandle::WatchedRequest> watched = {
      {first.request_id, first.generations},
      {second.request_id, second.generations}};
  int termination_calls = 0;
  bool all_erased_before_callback = true;
  for (const auto* request : {&first, &second}) {
    observer.Expect(
        registry.MarkDispatched(
            request->request_id, request->owner, request->generations,
            std::make_unique<BatchVisibilityTerminationHandle>(
                &termination_calls, &registry, request->owner, watched,
                &all_erased_before_callback)) == RequestOwnershipStatus::kOk,
        request == &first ? "targeted regression dispatch batch first"
                          : "targeted regression dispatch batch second");
  }
  const auto result =
      registry.CancelMatchingPageTarget(DocumentCancellationSelector());
  observer.Expect(result.status == RequestOwnershipStatus::kOk &&
                      result.cancellations.size() == 2u,
                  "targeted regression cancels complete batch");
  observer.Expect(termination_calls == 2,
                  "targeted regression terminates every active batch member");
  observer.Expect(all_erased_before_callback,
                  "targeted regression erases full batch before first callback");
  observer.Expect(registry.size() == 0u,
                  "targeted regression batch leaves no matching request");
}

inline void RunTargetedAttributionKindRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(2);
  auto document = DocumentOwnershipRecord("document-kind");
  auto pending = PendingOwnershipRecord("pending-kind");
  pending.top_level_site = document.top_level_site;
  pending.exact_host = document.exact_host;
  observer.Expect(registry.Register(document) == RequestOwnershipStatus::kOk,
                  "targeted regression register document attribution");
  observer.Expect(registry.Register(pending) == RequestOwnershipStatus::kOk,
                  "targeted regression register pending attribution");
  const auto result =
      registry.CancelMatchingPageTarget(DocumentCancellationSelector());
  observer.Expect(result.cancellations.size() == 1u &&
                      FindCancellation(result, document.request_id),
                  "targeted regression document selector excludes pending token");
  observer.Expect(registry.Lookup(pending.request_id, pending.owner,
                                  pending.generations)
                      .status == RequestOwnershipStatus::kOk,
                  "targeted regression pending request survives document selector");
}

inline void RunTargetedRequestCancellationRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RunTargetedIsolationRegressionTests(observer);
  RunTargetedInvalidSelectorRegressionTests(observer);
  RunTargetedBatchVisibilityRegressionTests(observer);
  RunTargetedAttributionKindRegressionTests(observer);
}


}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_CANCELLATION_CONTRACT_TEST_H_
