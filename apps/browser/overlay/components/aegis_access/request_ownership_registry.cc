// Copyright 2026 GCSA

#include "components/aegis_access/request_ownership_registry.h"

#include <utility>

namespace aegis_access {
namespace {

bool IsKnownChannel(ChannelNamespace channel) {
  switch (channel) {
    case ChannelNamespace::kDev:
    case ChannelNamespace::kAlpha:
    case ChannelNamespace::kBeta:
    case ChannelNamespace::kRelease:
      return true;
    case ChannelNamespace::kInvalid:
      return false;
  }
  return false;
}

bool IsComplete(const OwnershipKey& owner) {
  return IsKnownChannel(owner.channel) && !owner.profile_token.empty() &&
         !owner.storage_partition_token.empty();
}

bool IsComplete(const GenerationTuple& generations) {
  return generations.policy_generation != 0 &&
         generations.identity_generation != 0 &&
         generations.selection_generation != 0 &&
         generations.network_epoch != 0 &&
         generations.base_proxy_config_generation != 0;
}

bool IsKnown(RequestScheme scheme) {
  switch (scheme) {
    case RequestScheme::kHttp:
    case RequestScheme::kHttps:
    case RequestScheme::kWs:
    case RequestScheme::kWss:
      return true;
    case RequestScheme::kInvalid:
      return false;
  }
  return false;
}

bool HasExactlyOneAttributionToken(const RequestOwnershipRecord& record) {
  return record.document_token.empty() !=
         record.pending_navigation_token.empty();
}

bool HasValidRequestMetadata(const RequestOwnershipRecord& record) {
  return !record.request_id.empty() && IsComplete(record.owner) &&
         IsComplete(record.generations) && !record.exact_host.empty() &&
         IsKnown(record.scheme) && record.port != 0;
}

bool HasValidAttribution(const RequestOwnershipRecord& record) {
  if (record.site_ownership_reliable) {
    return !record.top_level_site.empty() &&
           HasExactlyOneAttributionToken(record);
  }
  return record.top_level_site.empty() && record.document_token.empty() &&
         record.pending_navigation_token.empty();
}

bool IsValidRecord(const RequestOwnershipRecord& record) {
  return HasValidRequestMetadata(record) && HasValidAttribution(record);
}

RequestOwnershipStatus ValidateExpected(
    const RequestOwnershipRecord& record,
    const OwnershipKey& expected_owner,
    const GenerationTuple& expected_generations) {
  if (record.owner != expected_owner) {
    return RequestOwnershipStatus::kOwnershipMismatch;
  }
  if (record.generations != expected_generations) {
    return RequestOwnershipStatus::kStaleGeneration;
  }
  return RequestOwnershipStatus::kOk;
}

}  // namespace

RequestOwnershipRegistry::RequestOwnershipRegistry(size_t max_entries)
    : max_entries_(max_entries) {}

RequestOwnershipRegistry::~RequestOwnershipRegistry() = default;

RequestOwnershipStatus RequestOwnershipRegistry::Register(
    RequestOwnershipRecord record) {
  if (!IsValidRecord(record)) {
    return RequestOwnershipStatus::kInvalidRecord;
  }
  if (entries_.contains(record.request_id)) {
    return RequestOwnershipStatus::kDuplicateRequestId;
  }
  if (entries_.size() >= max_entries_) {
    return RequestOwnershipStatus::kCapacityExceeded;
  }
  const std::string request_id = record.request_id;
  entries_.emplace(request_id,
                   Entry{std::move(record), RequestOwnershipLifecycle::kNew,
                         nullptr});
  return RequestOwnershipStatus::kOk;
}

RequestOwnershipLookupResult RequestOwnershipRegistry::Lookup(
    const std::string& request_id,
    const OwnershipKey& expected_owner,
    const GenerationTuple& expected_generations) const {
  const auto it = entries_.find(request_id);
  if (it == entries_.end()) {
    return {RequestOwnershipStatus::kNotFound, std::nullopt};
  }
  const RequestOwnershipStatus status = ValidateExpected(
      it->second.record, expected_owner, expected_generations);
  if (status != RequestOwnershipStatus::kOk) {
    return {status, std::nullopt};
  }
  return {RequestOwnershipStatus::kOk,
          RequestOwnershipSnapshot{it->second.record, it->second.lifecycle,
                                   it->second.termination_handle != nullptr}};
}

RequestOwnershipStatus RequestOwnershipRegistry::MarkDispatched(
    const std::string& request_id,
    const OwnershipKey& expected_owner,
    const GenerationTuple& expected_generations,
    std::unique_ptr<RequestTerminationHandle> termination_handle) {
  auto it = entries_.find(request_id);
  if (it == entries_.end()) {
    return RequestOwnershipStatus::kNotFound;
  }
  const RequestOwnershipStatus status = ValidateExpected(
      it->second.record, expected_owner, expected_generations);
  if (status != RequestOwnershipStatus::kOk) {
    return status;
  }
  if (it->second.lifecycle != RequestOwnershipLifecycle::kNew) {
    return RequestOwnershipStatus::kInvalidLifecycle;
  }
  if (!termination_handle) {
    return RequestOwnershipStatus::kMissingTerminationHandle;
  }
  it->second.lifecycle = RequestOwnershipLifecycle::kDispatched;
  it->second.termination_handle = std::move(termination_handle);
  return RequestOwnershipStatus::kOk;
}

RequestOwnershipStatus RequestOwnershipRegistry::MarkStreaming(
    const std::string& request_id,
    const OwnershipKey& expected_owner,
    const GenerationTuple& expected_generations) {
  auto it = entries_.find(request_id);
  if (it == entries_.end()) {
    return RequestOwnershipStatus::kNotFound;
  }
  const RequestOwnershipStatus status = ValidateExpected(
      it->second.record, expected_owner, expected_generations);
  if (status != RequestOwnershipStatus::kOk) {
    return status;
  }
  if (it->second.lifecycle != RequestOwnershipLifecycle::kDispatched) {
    return RequestOwnershipStatus::kInvalidLifecycle;
  }
  it->second.lifecycle = RequestOwnershipLifecycle::kStreaming;
  return RequestOwnershipStatus::kOk;
}

RequestOwnershipTerminalResult RequestOwnershipRegistry::Complete(
    const std::string& request_id,
    const OwnershipKey& expected_owner,
    const GenerationTuple& expected_generations) {
  auto it = entries_.find(request_id);
  if (it == entries_.end()) {
    return {};
  }
  const RequestOwnershipStatus status = ValidateExpected(
      it->second.record, expected_owner, expected_generations);
  if (status != RequestOwnershipStatus::kOk) {
    RequestOwnershipTerminalResult result;
    result.status = status;
    return result;
  }

  RequestOwnershipTerminalResult result;
  result.status = RequestOwnershipStatus::kOk;
  result.record = std::move(it->second.record);
  result.previous_lifecycle = it->second.lifecycle;
  entries_.erase(it);
  return result;
}

RequestOwnershipTerminalResult RequestOwnershipRegistry::Cancel(
    const std::string& request_id,
    const OwnershipKey& expected_owner,
    const GenerationTuple& expected_generations) {
  auto it = entries_.find(request_id);
  if (it == entries_.end()) {
    return {};
  }
  const RequestOwnershipStatus status = ValidateExpected(
      it->second.record, expected_owner, expected_generations);
  if (status != RequestOwnershipStatus::kOk) {
    RequestOwnershipTerminalResult result;
    result.status = status;
    return result;
  }
  if (it->second.lifecycle != RequestOwnershipLifecycle::kNew &&
      !it->second.termination_handle) {
    RequestOwnershipTerminalResult result;
    result.status = RequestOwnershipStatus::kMissingTerminationHandle;
    return result;
  }

  RequestOwnershipTerminalResult result;
  result.status = RequestOwnershipStatus::kOk;
  result.record = std::move(it->second.record);
  result.previous_lifecycle = it->second.lifecycle;
  std::unique_ptr<RequestTerminationHandle> termination_handle =
      std::move(it->second.termination_handle);

  // Erase before entering externally owned cancellation code. A reentrant or
  // late callback can therefore only observe kNotFound, never a half-cancelled
  // request that could be cancelled or completed twice.
  entries_.erase(it);
  if (termination_handle) {
    termination_handle->Terminate();
    result.termination_invoked = true;
  }
  return result;
}

}  // namespace aegis_access
