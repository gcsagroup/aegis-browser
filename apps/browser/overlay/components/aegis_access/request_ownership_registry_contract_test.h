// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_CONTRACT_TEST_H_

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "components/aegis_access/request_ownership_registry.h"

namespace aegis_access::test {

class RequestOwnershipRegistryTestObserver {
 public:
  virtual ~RequestOwnershipRegistryTestObserver() = default;
  virtual void Expect(bool condition, const std::string& label) = 0;
};

inline OwnershipKey OwnershipOwner() {
  return OwnershipKey{ChannelNamespace::kBeta, "profile-owner",
                      "partition-owner"};
}

inline GenerationTuple OwnershipGenerations() {
  return GenerationTuple{11, 12, 13, 14, 15};
}

inline RequestOwnershipRecord DocumentOwnershipRecord(
    std::string request_id = "request-document") {
  return RequestOwnershipRecord{
      std::move(request_id), OwnershipOwner(), OwnershipGenerations(),
      "document-token", {}, true, "https://example.test", "cdn.example.test",
      RequestScheme::kHttps, 443};
}

inline RequestOwnershipRecord ProfileOwnershipRecord(
    std::string request_id = "request-profile") {
  return RequestOwnershipRecord{
      std::move(request_id), OwnershipOwner(), OwnershipGenerations(), {}, {},
      false, {}, "background.example.test", RequestScheme::kHttps, 443};
}

class RecordingTerminationHandle final : public RequestTerminationHandle {
 public:
  explicit RecordingTerminationHandle(int* call_count)
      : call_count_(call_count) {}

  RecordingTerminationHandle(int* call_count,
                             RequestOwnershipRegistry* registry,
                             std::string request_id,
                             OwnershipKey owner,
                             GenerationTuple generations,
                             bool* erased_before_callback)
      : call_count_(call_count),
        registry_(registry),
        request_id_(std::move(request_id)),
        owner_(std::move(owner)),
        generations_(generations),
        erased_before_callback_(erased_before_callback) {}

  void Terminate() override {
    ++*call_count_;
    if (registry_ && erased_before_callback_) {
      *erased_before_callback_ =
          registry_->Lookup(request_id_, owner_, generations_).status ==
          RequestOwnershipStatus::kNotFound;
    }
  }

 private:
  int* call_count_;
  RequestOwnershipRegistry* registry_ = nullptr;
  std::string request_id_;
  OwnershipKey owner_;
  GenerationTuple generations_;
  bool* erased_before_callback_ = nullptr;
};

inline RequestOwnershipRecord PendingOwnershipRecord(
    std::string request_id = "request-pending") {
  return RequestOwnershipRecord{
      std::move(request_id), OwnershipOwner(), OwnershipGenerations(), {},
      "pending-token", true, "https://pending.example.test",
      "pending.example.test", RequestScheme::kHttps, 443};
}

inline RequestCancellationSelector DocumentCancellationSelector() {
  return RequestCancellationSelector{
      OwnershipOwner(), "document-token", {}, "https://example.test",
      "cdn.example.test", RequestScheme::kHttps, 443};
}

inline RequestCancellationSelector PendingCancellationSelector() {
  return RequestCancellationSelector{
      OwnershipOwner(), {}, "pending-token", "https://pending.example.test",
      "pending.example.test", RequestScheme::kHttps, 443};
}

inline const RequestOwnershipTerminalResult* FindCancellation(
    const RequestOwnershipBatchCancelResult& result,
    const std::string& request_id) {
  for (const auto& cancellation : result.cancellations) {
    if (cancellation.record && cancellation.record->request_id == request_id) {
      return &cancellation;
    }
  }
  return nullptr;
}

class BatchVisibilityTerminationHandle final : public RequestTerminationHandle {
 public:
  struct WatchedRequest {
    std::string request_id;
    GenerationTuple generations;
  };

  BatchVisibilityTerminationHandle(
      int* call_count,
      RequestOwnershipRegistry* registry,
      OwnershipKey owner,
      std::vector<WatchedRequest> watched,
      bool* all_erased_before_callback)
      : call_count_(call_count),
        registry_(registry),
        owner_(std::move(owner)),
        watched_(std::move(watched)),
        all_erased_before_callback_(all_erased_before_callback) {}

  void Terminate() override {
    ++*call_count_;
    bool all_erased = true;
    for (const auto& watched : watched_) {
      if (registry_->Lookup(watched.request_id, owner_, watched.generations)
              .status != RequestOwnershipStatus::kNotFound) {
        all_erased = false;
      }
    }
    *all_erased_before_callback_ &= all_erased;
  }

 private:
  int* call_count_;
  RequestOwnershipRegistry* registry_;
  OwnershipKey owner_;
  std::vector<WatchedRequest> watched_;
  bool* all_erased_before_callback_;
};

inline void RunRequestOwnershipRegistrationUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(2);
  const RequestOwnershipRecord document = DocumentOwnershipRecord();
  observer.Expect(registry.Register(document) == RequestOwnershipStatus::kOk,
                  "unit register document");
  observer.Expect(registry.size() == 1u, "unit registry size after register");
  const RequestOwnershipLookupResult initial = registry.Lookup(
      document.request_id, document.owner, document.generations);
  observer.Expect(initial.status == RequestOwnershipStatus::kOk,
                  "unit lookup document");
  observer.Expect(initial.snapshot.has_value(), "unit lookup has snapshot");
  if (initial.snapshot) {
    observer.Expect(initial.snapshot->record == document,
                    "unit lookup preserves record");
    observer.Expect(initial.snapshot->lifecycle == RequestOwnershipLifecycle::kNew,
                    "unit initial lifecycle");
    observer.Expect(!initial.snapshot->has_termination_handle,
                    "unit initial handle absent");
  }
}

inline void RunRequestOwnershipLifecycleUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(2);
  const RequestOwnershipRecord document = DocumentOwnershipRecord();
  observer.Expect(registry.Register(document) == RequestOwnershipStatus::kOk,
                  "unit lifecycle register document");
  int termination_calls = 0;
  observer.Expect(
      registry.MarkDispatched(
          document.request_id, document.owner, document.generations,
          std::make_unique<RecordingTerminationHandle>(&termination_calls)) ==
          RequestOwnershipStatus::kOk,
      "unit mark dispatched");
  const RequestOwnershipLookupResult dispatched = registry.Lookup(
      document.request_id, document.owner, document.generations);
  observer.Expect(dispatched.snapshot.has_value() &&
                      dispatched.snapshot->lifecycle ==
                          RequestOwnershipLifecycle::kDispatched &&
                      dispatched.snapshot->has_termination_handle,
                  "unit dispatched snapshot");
  observer.Expect(registry.MarkStreaming(document.request_id, document.owner,
                                         document.generations) ==
                      RequestOwnershipStatus::kOk,
                  "unit mark streaming");
  const RequestOwnershipTerminalResult completed = registry.Complete(
      document.request_id, document.owner, document.generations);
  observer.Expect(completed.status == RequestOwnershipStatus::kOk,
                  "unit complete request");
  observer.Expect(completed.record.has_value() && completed.record == document,
                  "unit completion returns identity");
  observer.Expect(completed.previous_lifecycle ==
                      RequestOwnershipLifecycle::kStreaming,
                  "unit completion remembers lifecycle");
  observer.Expect(!completed.termination_invoked && termination_calls == 0,
                  "unit completion does not terminate");
  observer.Expect(registry.size() == 0u, "unit completion erases entry");
}

inline void RunRequestOwnershipProfileOnlyUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(2);
  const RequestOwnershipRecord profile = ProfileOwnershipRecord();
  observer.Expect(registry.Register(profile) == RequestOwnershipStatus::kOk,
                  "unit profile-only register");
  const RequestOwnershipLookupResult profile_lookup = registry.Lookup(
      profile.request_id, profile.owner, profile.generations);
  observer.Expect(profile_lookup.snapshot.has_value() &&
                      !profile_lookup.snapshot->record.site_ownership_reliable &&
                      profile_lookup.snapshot->record.top_level_site.empty(),
                  "unit profile-only has no borrowed page identity");
}

inline void RunRequestOwnershipRegistryUnitTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RunRequestOwnershipRegistrationUnitTests(observer);
  RunRequestOwnershipLifecycleUnitTests(observer);
  RunRequestOwnershipProfileOnlyUnitTests(observer);
}

inline void RunRequestOwnershipDuplicateRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(2);
  RequestOwnershipRecord original = DocumentOwnershipRecord("duplicate");
  RequestOwnershipRecord replacement = original;
  replacement.exact_host = "replacement.example.test";
  observer.Expect(registry.Register(original) == RequestOwnershipStatus::kOk,
                  "regression duplicate base register");
  observer.Expect(registry.Register(replacement) ==
                      RequestOwnershipStatus::kDuplicateRequestId,
                  "regression duplicate rejected");
  const RequestOwnershipLookupResult lookup = registry.Lookup(
      original.request_id, original.owner, original.generations);
  observer.Expect(lookup.snapshot.has_value() &&
                      lookup.snapshot->record.exact_host == original.exact_host,
                  "regression duplicate never replaces original");
}

inline void RunRequestOwnershipInvalidMetadataRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(8);
  RequestOwnershipRecord invalid = DocumentOwnershipRecord("invalid-id");
  invalid.request_id.clear();
  observer.Expect(registry.Register(invalid) ==
                      RequestOwnershipStatus::kInvalidRecord,
                  "regression empty request id rejected");
  invalid = DocumentOwnershipRecord("invalid-owner");
  invalid.owner.channel = static_cast<ChannelNamespace>(99);
  observer.Expect(registry.Register(invalid) ==
                      RequestOwnershipStatus::kInvalidRecord,
                  "regression unknown channel rejected");
  invalid = DocumentOwnershipRecord("invalid-generation");
  invalid.generations.network_epoch = 0;
  observer.Expect(registry.Register(invalid) ==
                      RequestOwnershipStatus::kInvalidRecord,
                  "regression incomplete generation rejected");
  invalid = DocumentOwnershipRecord("invalid-scheme");
  invalid.scheme = static_cast<RequestScheme>(99);
  observer.Expect(registry.Register(invalid) ==
                      RequestOwnershipStatus::kInvalidRecord,
                  "regression unknown scheme rejected");
  invalid = DocumentOwnershipRecord("invalid-port");
  invalid.port = 0;
  observer.Expect(registry.Register(invalid) ==
                      RequestOwnershipStatus::kInvalidRecord,
                  "regression zero port rejected");
}

inline void RunRequestOwnershipInvalidAttributionRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(8);
  RequestOwnershipRecord invalid =
      DocumentOwnershipRecord("ambiguous-attribution");
  invalid.pending_navigation_token = "also-pending";
  observer.Expect(registry.Register(invalid) ==
                      RequestOwnershipStatus::kInvalidRecord,
                  "regression ambiguous site attribution rejected");
  invalid = ProfileOwnershipRecord("borrowed-site");
  invalid.top_level_site = "https://borrowed.example";
  observer.Expect(registry.Register(invalid) ==
                      RequestOwnershipStatus::kInvalidRecord,
                  "regression profile-only cannot borrow site");
}

inline void RunRequestOwnershipCapacityRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(1);
  const RequestOwnershipRecord first = DocumentOwnershipRecord("capacity-a");
  const RequestOwnershipRecord second = DocumentOwnershipRecord("capacity-b");
  observer.Expect(registry.Register(first) == RequestOwnershipStatus::kOk,
                  "regression capacity first register");
  observer.Expect(registry.Register(second) ==
                      RequestOwnershipStatus::kCapacityExceeded,
                  "regression capacity fails closed");
  observer.Expect(registry.Complete(first.request_id, first.owner,
                                    first.generations)
                      .status == RequestOwnershipStatus::kOk,
                  "regression capacity completion frees entry");
  observer.Expect(registry.Register(second) == RequestOwnershipStatus::kOk,
                  "regression capacity reused after terminal state");
}

inline RequestOwnershipRecord RegisterIdentityRegressionRecord(
    RequestOwnershipRegistryTestObserver& observer,
    RequestOwnershipRegistry& registry) {
  const RequestOwnershipRecord record = DocumentOwnershipRecord("identity");
  observer.Expect(registry.Register(record) == RequestOwnershipStatus::kOk,
                  "regression identity register");
  return record;
}

inline void RunRequestOwnershipMismatchRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(2);
  const RequestOwnershipRecord record =
      RegisterIdentityRegressionRecord(observer, registry);
  OwnershipKey wrong_owner = record.owner;
  wrong_owner.profile_token = "other-profile";
  observer.Expect(registry.Lookup(record.request_id, wrong_owner,
                                  record.generations)
                      .status == RequestOwnershipStatus::kOwnershipMismatch,
                  "regression cross-profile lookup rejected");
  OwnershipKey wrong_partition = record.owner;
  wrong_partition.storage_partition_token = "other-partition";
  observer.Expect(registry.Lookup(record.request_id, wrong_partition,
                                  record.generations)
                      .status == RequestOwnershipStatus::kOwnershipMismatch,
                  "regression cross-partition lookup rejected");
  int rejected_termination_calls = 0;
  observer.Expect(
      registry.MarkDispatched(
          record.request_id, wrong_owner, record.generations,
          std::make_unique<RecordingTerminationHandle>(
              &rejected_termination_calls)) ==
          RequestOwnershipStatus::kOwnershipMismatch,
      "regression cross-profile dispatch rejected");
  observer.Expect(rejected_termination_calls == 0,
                  "regression rejected dispatch never terminates");
  observer.Expect(registry.Lookup(record.request_id, record.owner,
                                  record.generations)
                      .status == RequestOwnershipStatus::kOk,
                  "regression rejected owner leaves entry intact");
}

inline void RunRequestOwnershipStaleGenerationRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(2);
  const RequestOwnershipRecord record =
      RegisterIdentityRegressionRecord(observer, registry);
  GenerationTuple stale_policy = record.generations;
  ++stale_policy.policy_generation;
  observer.Expect(registry.Lookup(record.request_id, record.owner, stale_policy)
                      .status == RequestOwnershipStatus::kStaleGeneration,
                  "regression stale policy generation rejected");
  GenerationTuple stale = record.generations;
  ++stale.network_epoch;
  int termination_calls = 0;
  observer.Expect(
      registry.MarkDispatched(
          record.request_id, record.owner, record.generations,
          std::make_unique<RecordingTerminationHandle>(&termination_calls)) ==
          RequestOwnershipStatus::kOk,
      "regression valid dispatch after owner mismatch");
  observer.Expect(registry.Cancel(record.request_id, record.owner, stale).status ==
                      RequestOwnershipStatus::kStaleGeneration,
                  "regression stale cancel rejected");
  observer.Expect(termination_calls == 0 && registry.size() == 1u,
                  "regression stale cancel keeps request active");
}

inline void RunRequestOwnershipLifecycleRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(3);
  const RequestOwnershipRecord lifecycle =
      DocumentOwnershipRecord("lifecycle");
  observer.Expect(registry.Register(lifecycle) == RequestOwnershipStatus::kOk,
                  "regression lifecycle register");
  observer.Expect(registry.MarkStreaming(lifecycle.request_id, lifecycle.owner,
                                         lifecycle.generations) ==
                      RequestOwnershipStatus::kInvalidLifecycle,
                  "regression streaming before dispatch rejected");
  observer.Expect(registry.MarkDispatched(lifecycle.request_id, lifecycle.owner,
                                          lifecycle.generations, nullptr) ==
                      RequestOwnershipStatus::kMissingTerminationHandle,
                  "regression dispatch requires termination handle");
  const RequestOwnershipTerminalResult new_cancel = registry.Cancel(
      lifecycle.request_id, lifecycle.owner, lifecycle.generations);
  observer.Expect(new_cancel.status == RequestOwnershipStatus::kOk &&
                      !new_cancel.termination_invoked && registry.size() == 0u,
                  "regression new request cancels without external handle");
}

inline void RunRequestOwnershipReentrantCancellationRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RequestOwnershipRegistry registry(2);
  const RequestOwnershipRecord record = DocumentOwnershipRecord("reentrant");
  observer.Expect(registry.Register(record) == RequestOwnershipStatus::kOk,
                  "regression reentrant register");
  int termination_calls = 0;
  bool erased_before_callback = false;
  observer.Expect(
      registry.MarkDispatched(
          record.request_id, record.owner, record.generations,
          std::make_unique<RecordingTerminationHandle>(
              &termination_calls, &registry, record.request_id, record.owner,
              record.generations, &erased_before_callback)) ==
          RequestOwnershipStatus::kOk,
      "regression reentrant dispatch");
  observer.Expect(registry.MarkStreaming(record.request_id, record.owner,
                                         record.generations) ==
                      RequestOwnershipStatus::kOk,
                  "regression reentrant streaming");
  const RequestOwnershipTerminalResult cancelled = registry.Cancel(
      record.request_id, record.owner, record.generations);
  observer.Expect(cancelled.status == RequestOwnershipStatus::kOk &&
                      cancelled.termination_invoked && termination_calls == 1,
                  "regression cancellation invokes handle once");
  observer.Expect(erased_before_callback,
                  "regression erase precedes external termination callback");
  observer.Expect(registry.Cancel(record.request_id, record.owner,
                                  record.generations)
                      .status == RequestOwnershipStatus::kNotFound,
                  "regression repeated cancel cannot reterminate");
  observer.Expect(registry.Complete(record.request_id, record.owner,
                                    record.generations)
                      .status == RequestOwnershipStatus::kNotFound,
                  "regression late completion after cancel is ignored");
}

inline void RunRequestOwnershipRegistryRegressionTests(
    RequestOwnershipRegistryTestObserver& observer) {
  RunRequestOwnershipDuplicateRegressionTests(observer);
  RunRequestOwnershipInvalidMetadataRegressionTests(observer);
  RunRequestOwnershipInvalidAttributionRegressionTests(observer);
  RunRequestOwnershipCapacityRegressionTests(observer);
  RunRequestOwnershipMismatchRegressionTests(observer);
  RunRequestOwnershipStaleGenerationRegressionTests(observer);
  RunRequestOwnershipLifecycleRegressionTests(observer);
  RunRequestOwnershipReentrantCancellationRegressionTests(observer);
}

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

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_CONTRACT_TEST_H_
