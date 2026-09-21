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
#include "content/public/browser/browser_thread.h"

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
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessPublishedRequestRuntime*>(
      profile->GetUserData(kPublishedRequestRuntimeUserDataKey));
}

// static
AccessPublishedRequestRuntime* AccessPublishedRequestRuntime::GetOrCreate(
    Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
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
    : profile_(profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessPublishedRequestRuntime::~AccessPublishedRequestRuntime() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessPolicyPublicationResult
AccessPublishedRequestRuntime::PublishCommittedPolicySnapshot(
    const StoredPolicySnapshot& stored) {
  return PublishPolicySnapshot(stored);
}

AccessPolicyPublicationResult
AccessPublishedRequestRuntime::PublishPreparedPolicyCandidate(
    const StoredPolicySnapshot& candidate) {
  return PublishPolicySnapshot(candidate);
}

bool AccessPublishedRequestRuntime::RollbackPreparedPolicyCandidate(
    const StoredPolicySnapshot& candidate,
    const std::optional<StoredPolicySnapshot>& previous) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  StoreResult<MatcherRuleSetCandidate> prepared =
      AccessRuleStore::AdaptMatcherSnapshot(candidate);
  if (prepared.status != StoreStatus::kValid || !prepared.value.has_value()) {
    return false;
  }
  aegis_access::PublishedAccessPolicySnapshot expected{
      prepared.value->owner,
      prepared.value->committed_policy_generation,
      prepared.value->rules,
  };
  auto it = policy_snapshots_.find(expected.owner.storage_partition_token);
  if (it == policy_snapshots_.end() || it->second != expected) {
    return false;
  }
  if (!previous.has_value()) {
    policy_snapshots_.erase(it);
    return true;
  }
  StoreResult<MatcherRuleSetCandidate> prior =
      AccessRuleStore::AdaptMatcherSnapshot(*previous);
  if (prior.status != StoreStatus::kValid || !prior.value.has_value() ||
      prior.value->owner != expected.owner) {
    return false;
  }
  it->second = aegis_access::PublishedAccessPolicySnapshot{
      prior.value->owner,
      prior.value->committed_policy_generation,
      prior.value->rules,
  };
  return true;
}

AccessPolicyPublicationResult
AccessPublishedRequestRuntime::PublishPolicySnapshot(
    const StoredPolicySnapshot& stored) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
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
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto it = policy_snapshots_.find(owner.storage_partition_token);
  if (it == policy_snapshots_.end() || it->second.owner != owner) {
    return nullptr;
  }
  return &it->second;
}

bool AccessPublishedRequestRuntime::InvalidatePublishedPolicySnapshot(
    const aegis_access::OwnershipKey& owner) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto it = policy_snapshots_.find(owner.storage_partition_token);
  if (it == policy_snapshots_.end() || it->second.owner != owner) {
    return false;
  }
  policy_snapshots_.erase(it);
  return true;
}

aegis_access::RequestGenerationTupleBuildResult
AccessPublishedRequestRuntime::CaptureProxyGenerationTupleOnUiThread(
    const aegis_access::OwnershipKey& owner,
    const std::string& proxy_group_id) const {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  aegis_access::RequestGenerationTupleInput input;
  input.request_owner = owner;
  input.snapshot_owner = owner;

  if (const auto* snapshot = GetPublishedPolicySnapshot(owner)) {
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
