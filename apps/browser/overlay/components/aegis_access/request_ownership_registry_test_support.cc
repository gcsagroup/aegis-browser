// Copyright 2026 GCSA

#include "components/aegis_access/request_ownership_registry_test_support.h"

#include <utility>

namespace aegis_access::test {

RecordingTerminationHandle::RecordingTerminationHandle(int* call_count)
    : call_count_(call_count) {}

RecordingTerminationHandle::RecordingTerminationHandle(
    int* call_count,
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

RecordingTerminationHandle::~RecordingTerminationHandle() = default;

void RecordingTerminationHandle::Terminate() {
  ++*call_count_;
  if (registry_ && erased_before_callback_) {
    *erased_before_callback_ =
        registry_->Lookup(request_id_, owner_, generations_).status ==
        RequestOwnershipStatus::kNotFound;
  }
}

BatchVisibilityTerminationHandle::BatchVisibilityTerminationHandle(
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

BatchVisibilityTerminationHandle::~BatchVisibilityTerminationHandle() = default;

void BatchVisibilityTerminationHandle::Terminate() {
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

}  // namespace aegis_access::test
