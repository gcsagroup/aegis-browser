// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_TEST_SUPPORT_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_TEST_SUPPORT_H_

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

inline RequestDispatchBarrier DocumentBlockBarrier(
    std::string operation_id = "block-op",
    uint64_t operation_sequence = 21) {
  return RequestDispatchBarrier{std::move(operation_id), operation_sequence,
                                DocumentCancellationSelector()};
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

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_TEST_SUPPORT_H_
