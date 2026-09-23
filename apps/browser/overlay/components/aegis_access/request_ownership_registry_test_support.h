// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_TEST_SUPPORT_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_TEST_SUPPORT_H_

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "components/aegis_access/request_ownership_registry.h"

#if __has_include("base/memory/raw_ptr.h")
#include "base/memory/raw_ptr.h"
#endif

namespace aegis_access::test {

#if __has_include("base/memory/raw_ptr.h")
template <typename T>
using RegistryTestPtr = raw_ptr<T>;
#else
template <typename T>
using RegistryTestPtr = T*;
#endif

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
  explicit RecordingTerminationHandle(int* call_count);

  RecordingTerminationHandle(int* call_count,
                             RequestOwnershipRegistry* registry,
                             std::string request_id,
                             OwnershipKey owner,
                             GenerationTuple generations,
                             bool* erased_before_callback);
  ~RecordingTerminationHandle() override;

  void Terminate() override;

 private:
  RegistryTestPtr<int> call_count_;
  RegistryTestPtr<RequestOwnershipRegistry> registry_ = nullptr;
  std::string request_id_;
  OwnershipKey owner_;
  GenerationTuple generations_;
  RegistryTestPtr<bool> erased_before_callback_ = nullptr;
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
      bool* all_erased_before_callback);
  ~BatchVisibilityTerminationHandle() override;

  void Terminate() override;

 private:
  RegistryTestPtr<int> call_count_;
  RegistryTestPtr<RequestOwnershipRegistry> registry_;
  OwnershipKey owner_;
  std::vector<WatchedRequest> watched_;
  RegistryTestPtr<bool> all_erased_before_callback_;
};

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_TEST_SUPPORT_H_
