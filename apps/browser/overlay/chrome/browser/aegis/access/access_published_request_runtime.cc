// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_published_request_runtime.h"

#include <memory>
#include <utility>

#include "chrome/browser/aegis/access/access_identity_generation_source.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/access/access_proxy_selection_generation_source.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/net/profile_network_context_service.h"
#include "chrome/browser/net/profile_network_context_service_factory.h"
#include "chrome/browser/profiles/profile.h"

namespace aegis::access {
namespace {

const void* const kPublishedRequestRuntimeUserDataKey =
    &kPublishedRequestRuntimeUserDataKey;

AccessPolicyPublicationResult PublicationResult(
    AccessPolicyPublicationStatus status,
    uint64_t generation = 0) {
  return {status, generation};
}

}  // namespace

// static
AccessPublishedRequestRuntime* AccessPublishedRequestRuntime::Get(
    Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessPublishedRequestRuntime*>(
      profile->GetUserData(kPublishedRequestRuntimeUserDataKey));
}

// static
AccessPublishedRequestRuntime* AccessPublishedRequestRuntime::GetOrCreate(
    Profile* profile) {
  if (!profile || !aegis::IsAegisProfileSupported(profile)) {
    return nullptr;
  }
  if (auto* existing = Get(profile)) {
    return existing;
  }
  auto runtime = std::unique_ptr<AccessPublishedRequestRuntime>(
      new AccessPublishedRequestRuntime(profile));
  auto* result = runtime.get();
  profile->SetUserData(kPublishedRequestRuntimeUserDataKey, std::move(runtime));
  return result;
}

AccessPublishedRequestRuntime::AccessPublishedRequestRuntime(Profile* profile)
    : profile_(profile) {}

AccessPublishedRequestRuntime::~AccessPublishedRequestRuntime() = default;

AccessPolicyPublicationResult
AccessPublishedRequestRuntime::PublishCommittedPolicySnapshot(
    const StoredPolicySnapshot& stored) {
  StoreResult<MatcherRuleSetCandidate> candidate =
      AccessRuleStore::AdaptMatcherSnapshot(stored);
  if (candidate.status != StoreStatus::kValid || !candidate.value.has_value()) {
    return PublicationResult(AccessPolicyPublicationStatus::kInvalidSnapshot);
  }

  AccessNetworkContextTransport* transport =
      AccessNetworkContextTransport::Get(profile_);
  if (!transport) {
    return PublicationResult(AccessPolicyPublicationStatus::kMissingTransport);
  }
  if (!transport->OwnsConfiguredPartition(candidate.value->owner)) {
    return PublicationResult(
        AccessPolicyPublicationStatus::kOwnershipMismatch);
  }

  aegis_access::PublishedAccessPolicySnapshot snapshot{
      candidate.value->owner,
      candidate.value->committed_policy_generation,
      candidate.value->rules,
  };
  auto it = policy_snapshots_.find(snapshot.owner.storage_partition_token);
  if (it == policy_snapshots_.end()) {
    policy_snapshots_.emplace(snapshot.owner.storage_partition_token,
                              std::move(snapshot));
    return PublicationResult(AccessPolicyPublicationStatus::kPublished,
                             candidate.value->committed_policy_generation);
  }

  if (it->second.owner != snapshot.owner) {
    return PublicationResult(
        AccessPolicyPublicationStatus::kOwnershipMismatch);
  }
  if (snapshot.policy_generation < it->second.policy_generation) {
    return PublicationResult(AccessPolicyPublicationStatus::kStaleGeneration,
                             it->second.policy_generation);
  }
  if (snapshot.policy_generation == it->second.policy_generation) {
    if (snapshot == it->second) {
      return PublicationResult(AccessPolicyPublicationStatus::kUnchanged,
                               snapshot.policy_generation);
    }
    return PublicationResult(
        AccessPolicyPublicationStatus::kConflictingGeneration,
        snapshot.policy_generation);
  }

  it->second = std::move(snapshot);
  return PublicationResult(AccessPolicyPublicationStatus::kPublished,
                           it->second.policy_generation);
}

const aegis_access::PublishedAccessPolicySnapshot*
AccessPublishedRequestRuntime::GetPublishedPolicySnapshot(
    const aegis_access::OwnershipKey& owner) const {
  const auto it = policy_snapshots_.find(owner.storage_partition_token);
  if (it == policy_snapshots_.end() || it->second.owner != owner) {
    return nullptr;
  }
  return &it->second;
}

bool AccessPublishedRequestRuntime::InvalidatePublishedPolicySnapshot(
    const aegis_access::OwnershipKey& owner) {
  const auto it = policy_snapshots_.find(owner.storage_partition_token);
  if (it == policy_snapshots_.end() || it->second.owner != owner) {
    return false;
  }
  policy_snapshots_.erase(it);
  return true;
}

aegis_access::RequestGenerationTupleBuildResult
AccessPublishedRequestRuntime::BuildProxyGenerationTuple(
    const aegis_access::OwnershipKey& owner,
    const std::string& proxy_group_id) const {
  aegis_access::RequestGenerationTupleInput input;
  input.request_owner = owner;
  input.snapshot_owner = owner;

  if (const auto* snapshot = GetPublishedPolicySnapshot(owner)) {
    input.snapshot_owner = snapshot->owner;
    input.policy_generation = snapshot->policy_generation;
  }

  if (AccessIdentityGenerationSource* identity =
          AccessIdentityGenerationSource::Get(profile_)) {
    input.identity_generation = identity->identity_generation();
  }

  if (!proxy_group_id.empty()) {
    if (AccessProxySelectionGenerationSource* selection =
            AccessProxySelectionGenerationSource::Get(profile_)) {
      input.selection_generation =
          selection->selection_generation(proxy_group_id);
    }
  }

  if (AccessNetworkContextTransport* transport =
          AccessNetworkContextTransport::Get(profile_)) {
    input.network_epoch = transport->network_epoch();
  }

  if (ProfileNetworkContextService* network_service =
          ProfileNetworkContextServiceFactory::GetForContext(profile_)) {
    input.base_proxy_config_generation =
        network_service->GetAegisBaseProxyConfigGeneration();
  }

  return aegis_access::BuildCompleteRequestGenerationTuple(input);
}

}  // namespace aegis::access
