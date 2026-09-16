// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_CONTRACT_TEST_H_

#include <memory>
#include <string>
#include <utility>

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

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_CONTRACT_TEST_H_
