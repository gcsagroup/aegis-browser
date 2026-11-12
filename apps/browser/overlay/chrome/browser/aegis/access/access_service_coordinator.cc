// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_service_coordinator.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/time/time.h"
#include "chrome/browser/aegis/access/access_build_channel.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/access/access_identity_generation_source.h"
#include "chrome/browser/aegis/access/access_published_request_runtime.h"
#include "chrome/browser/aegis/access/access_proxy_selection_generation_source.h"
#include "chrome/browser/aegis/access/access_request_dispatch_state.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/browser_thread.h"

namespace aegis::access {

namespace {
const void* const kAccessServiceCoordinatorKey = &kAccessServiceCoordinatorKey;

bool SelectorMatchesMutation(
    const aegis_access::RequestCancellationSelector& selector,
    const SiteGroupMutationRequest& request) {
  if (!aegis_access::IsValidRequestCancellationSelector(selector) ||
      selector.owner != request.candidate_group.owner ||
      selector.website_context != request.candidate_group.website_context ||
      selector.exact_host != request.candidate_group.canonical_host) {
    return false;
  }
  return std::ranges::any_of(
      request.candidate_members, [&](const SiteProxyRuleMember& member) {
        return member.owner == selector.owner &&
               member.exact_host == selector.exact_host &&
               member.top_level_site == selector.top_level_site &&
               std::ranges::find(member.schemes, selector.scheme) !=
                   member.schemes.end();
      });
}

std::optional<AccessMode> OrdinaryMutationMode(
    const SiteGroupMutationRequest& request) {
  if (request.candidate_members.empty()) {
    return std::nullopt;
  }
  const AccessMode mode = request.candidate_members.front().mode;
  if (mode != AccessMode::kDirect && mode != AccessMode::kProxy) {
    return std::nullopt;
  }
  for (const auto& member : request.candidate_members) {
    if (member.mode != mode) {
      return std::nullopt;
    }
  }
  return mode;
}

AccessMutationTransactionResult Result(
    AccessMutationTransactionStatus status,
    StoreStatus store_status = StoreStatus::kValid,
    uint64_t generation = 0) {
  return {status, store_status, generation};
}
}

AccessServiceCoordinator::AccessServiceCoordinator(Profile* profile)
    : profile_(profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessServiceCoordinator::~AccessServiceCoordinator() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessServiceCoordinator* AccessServiceCoordinator::Get(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessServiceCoordinator*>(
      profile->GetUserData(kAccessServiceCoordinatorKey));
}

AccessServiceCoordinator* AccessServiceCoordinator::GetOrCreate(
    Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile || !aegis::IsAegisProfileSupported(profile)) {
    return nullptr;
  }

  auto* existing = Get(profile);
  if (existing) {
    return existing;
  }

  auto coordinator = std::unique_ptr<AccessServiceCoordinator>(
      new AccessServiceCoordinator(profile));
  auto* result = coordinator.get();
  profile->SetUserData(kAccessServiceCoordinatorKey, std::move(coordinator));
  return result;
}

struct AccessServiceCoordinator::MutationTransaction {
  MutationTransaction();
  ~MutationTransaction();

  PendingMutationRecord pending;
  StoredPolicySnapshot candidate;
  std::optional<StoredPolicySnapshot> previous;
  AccessTransportSelection previous_selection;
  AccessTransportSelection candidate_selection;
  aegis_access::PolicyPublicationIdentity identity;
  aegis_access::GenerationTuple common_generations;
  base::OnceCallback<void(AccessMutationTransactionResult)> completion;
  bool tracker_started = false;
  bool runtime_published = false;
};

AccessServiceCoordinator::MutationTransaction::MutationTransaction() = default;
AccessServiceCoordinator::MutationTransaction::~MutationTransaction() = default;

bool AccessServiceCoordinator::CanDispatch(const OwnershipKey& owner) const {
  return !recovery_required_ && !mutation_in_flight_ &&
      (!async_store_ || committed_cache_.contains(owner.storage_partition_token));
}

void AccessServiceCoordinator::InitializeForProfile(
    const OwnershipKey& owner, base::OnceCallback<void(bool)> completion) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  if (store_ || recovery_required_ || !transport || !transport->OwnsConfiguredPartition(owner)) {
    std::move(completion).Run(false);
    return;
  }
  if (committed_cache_.contains(owner.storage_partition_token)) {
    std::move(completion).Run(true);
    return;
  }
  auto& waiting = initializing_[owner.storage_partition_token];
  waiting.push_back(std::move(completion));
  if (waiting.size() > 1) return;
  if (!async_store_) {
    const auto durable = "aegis-access-profile:" + profile_->GetPath().AsUTF8Unsafe();
    auto binding = profile_->IsOffTheRecord()
        ? TrustedAccessStoreBindingFactory::CreateEphemeral(
              owner.channel, durable, owner.profile_token)
        : TrustedAccessStoreBindingFactory::CreatePersistent(
              owner.channel, durable, owner.profile_token, profile_->GetPath());
    if (!binding) {
      OnStoreInitialized(owner, {.status = StoreStatus::kInvalidArgument});
      return;
    }
    async_store_ = std::make_unique<AccessAsyncRuleStore>(*binding);
  }
  async_store_->InitializeAndRestore(owner.storage_partition_token,
      base::BindOnce(&AccessServiceCoordinator::OnStoreInitialized,
                     weak_factory_.GetWeakPtr(), owner));
}
void AccessServiceCoordinator::OnStoreInitialized(
    OwnershipKey owner, AsyncAccessStoreRestoration result) {
  auto* runtime = AccessPublishedRequestRuntime::GetOrCreate(profile_);
  bool ready = result.status == StoreStatus::kValid && result.committed &&
      result.publication && result.publication->owner == owner && runtime;
  if (ready) {
    auto* identity = AccessIdentityGenerationSource::GetOrCreate(profile_);
    if (!identity->binding()) identity->CommitIdentity(
        {aegis_access::AccessIdentityKind::kSignedOut, {}, {},
         LocalAccessIdentityChannel(owner.channel),
         "authorized-local-node"});
    const auto published = runtime->PublishRestoredPolicyCandidate(*result.publication);
    ready = published.status == AccessPolicyPublicationStatus::kPublished ||
            published.status == AccessPolicyPublicationStatus::kUnchanged;
    if (ready) committed_cache_.insert_or_assign(
        owner.storage_partition_token, std::move(*result.committed));
  }
  auto callbacks = std::move(initializing_.at(owner.storage_partition_token));
  initializing_.erase(owner.storage_partition_token);
  for (auto& callback : callbacks) std::move(callback).Run(ready);
}

StoreResult<StoredPolicySnapshot>
AccessServiceCoordinator::ReadCommittedSnapshot(
    const std::string& storage_partition_token) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (async_store_) {
    const auto found = committed_cache_.find(storage_partition_token);
    return found == committed_cache_.end()
        ? StoreResult<StoredPolicySnapshot>{.status = StoreStatus::kMissing}
        : StoreResult<StoredPolicySnapshot>{.status = StoreStatus::kValid,
                                           .value = found->second};
  }
  if (!store_) {
    return {.status = StoreStatus::kMissing};
  }
  return store_->ReadCommittedSnapshot(storage_partition_token);
}

void AccessServiceCoordinator::CommitSiteGroupMutation(
    std::unique_ptr<AccessRuleStore> supplied_store,
    SiteGroupMutationRequest request,
    aegis_access::RequestCancellationSelector selector,
    base::OnceCallback<void(AccessMutationTransactionResult)> completion) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!completion) {
    return;
  }
  if (mutation_in_flight_) {
    std::move(completion).Run(Result(AccessMutationTransactionStatus::kBusy));
    return;
  }
  if (supplied_store && (store_ || async_store_)) {
    std::move(completion).Run(Result(AccessMutationTransactionStatus::kInvalidRequest));
    return;
  }
  if (supplied_store) {
    store_ = std::move(supplied_store);
  }
  mutation_in_flight_ = true;
  auto transaction = std::make_unique<MutationTransaction>();
  transaction->completion = std::move(completion);
  transaction->identity.selector = std::move(selector);
  if (async_store_) {
    if (!committed_cache_.contains(request.candidate_group.owner.storage_partition_token) ||
        !SelectorMatchesMutation(transaction->identity.selector, request) ||
        !OrdinaryMutationMode(request)) {
      Finish(std::move(transaction->completion),
             Result(AccessMutationTransactionStatus::kInvalidRequest));
      return;
    }
    async_store_->Prepare(std::move(request), base::BindOnce(
        &AccessServiceCoordinator::OnAsyncPrepared, weak_factory_.GetWeakPtr(),
        std::move(transaction)));
    return;
  }
  if (auto outcome = PrepareCandidate(*transaction, request)) {
    if (outcome->status == AccessMutationTransactionStatus::kCommitted) {
      Finish(std::move(transaction->completion), *outcome);
    } else {
      FailTransaction(std::move(transaction), *outcome);
    }
    return;
  }
  if (auto failure = BeginPublication(*transaction)) {
    FailTransaction(std::move(transaction), *failure);
    return;
  }
  if (auto failure = PublishCandidate(*transaction)) {
    FailTransaction(std::move(transaction), *failure);
    return;
  }
  RequestPublicationAck(std::move(transaction));
}
void AccessServiceCoordinator::OnAsyncPrepared(
    std::unique_ptr<MutationTransaction> transaction,
    AsyncAccessStorePrepared result) {
  // PREPARED is already durable even if construction of its full candidate
  // fails. Keep its identity so FailTransaction supersedes the journal entry.
  if (result.pending && result.pending->phase == MutationPhase::kPrepared) {
    transaction->pending = *result.pending;
    transaction->previous = std::move(result.previous);
  }
  if (result.status != StoreStatus::kValid || !result.pending) {
    FailTransaction(std::move(transaction),
        Result(AccessMutationTransactionStatus::kPrepareFailed, result.status));
    return;
  }
  if (result.pending->phase == MutationPhase::kCommitted) {
    Finish(std::move(transaction->completion),
        Result(AccessMutationTransactionStatus::kCommitted, StoreStatus::kValid,
               result.pending->committed_policy_generation));
    return;
  }
  if (!result.candidate) {
    FailTransaction(std::move(transaction),
        Result(AccessMutationTransactionStatus::kCandidateBuildFailed, result.status));
    return;
  }
  transaction->candidate = std::move(*result.candidate);
  if (transaction->pending.candidate.group.website_context) {
    if (auto failure = ValidateTransportScope(*transaction,
            transaction->pending.candidate.members.front().policy.mode)) {
      FailTransaction(std::move(transaction), *failure);
      return;
    }
  }
  if (auto failure = BeginPublication(*transaction)) {
    FailTransaction(std::move(transaction), *failure);
    return;
  }
  if (auto failure = PublishCandidate(*transaction)) {
    FailTransaction(std::move(transaction), *failure);
    return;
  }
  RequestPublicationAck(std::move(transaction));
}

std::optional<AccessMutationTransactionResult>
AccessServiceCoordinator::PrepareCandidate(
    MutationTransaction& transaction,
    const SiteGroupMutationRequest& request) {
  if (!store_ || !store_->is_open() ||
      !SelectorMatchesMutation(transaction.identity.selector, request) ||
      !OrdinaryMutationMode(request).has_value()) {
    return Result(AccessMutationTransactionStatus::kInvalidRequest);
  }
  if (auto failure = ReadPreviousSnapshot(transaction, request)) {
    return failure;
  }
  auto prepared = store_->PrepareSiteGroupMutation(request);
  if (prepared.status != StoreStatus::kValid || !prepared.value) {
    return Result(AccessMutationTransactionStatus::kPrepareFailed,
                  prepared.status);
  }
  if (prepared.value->phase == MutationPhase::kCommitted) {
    return Result(AccessMutationTransactionStatus::kCommitted,
                  StoreStatus::kValid,
                  prepared.value->committed_policy_generation);
  }
  if (prepared.value->phase != MutationPhase::kPrepared) {
    return Result(AccessMutationTransactionStatus::kPrepareFailed,
                  StoreStatus::kConflict);
  }
  transaction.pending = std::move(*prepared.value);
  auto built = store_->BuildPreparedCandidateSnapshot(transaction.pending);
  if (built.status != StoreStatus::kValid || !built.value) {
    return Result(AccessMutationTransactionStatus::kCandidateBuildFailed,
                  built.status);
  }
  transaction.candidate = std::move(*built.value);
  return ValidateTransportScope(transaction, *OrdinaryMutationMode(request));
}

std::optional<AccessMutationTransactionResult>
AccessServiceCoordinator::ReadPreviousSnapshot(
    MutationTransaction& transaction,
    const SiteGroupMutationRequest& request) {
  auto prior = store_->ReadCommittedSnapshot(
      request.candidate_group.owner.storage_partition_token);
  if (prior.status == StoreStatus::kValid && prior.value) {
    transaction.previous = std::move(*prior.value);
  } else if (prior.status != StoreStatus::kMissing) {
    return Result(AccessMutationTransactionStatus::kStoreReadFailed,
                  prior.status);
  }
  return std::nullopt;
}

std::optional<AccessMutationTransactionResult>
AccessServiceCoordinator::ValidateTransportScope(
    const MutationTransaction& transaction,
    AccessMode mode) const {
  if (transaction.pending.candidate.group.website_context) {
    auto* transport = AccessNetworkContextTransport::Get(profile_);
    return transport && transport->HasReadyPrivateContext(transaction.pending.owner)
        ? std::nullopt
        : std::make_optional(Result(AccessMutationTransactionStatus::kUnsupportedTransportScope));
  }
  // CustomProxyConfig selects by destination host, not top-level-site scope.
  const auto matcher =
      AccessRuleStore::AdaptMatcherSnapshot(transaction.candidate);
  if (!matcher.value) {
    return Result(AccessMutationTransactionStatus::kUnsupportedTransportScope);
  }
  const aegis_access::SiteProxyTransportRule candidate{
      transaction.identity.selector.exact_host, false, mode,
      transaction.pending.candidate.members.front().policy.proxy_group_id};
  const bool incompatible = std::ranges::any_of(
      matcher.value->rules, [&](const AccessPolicyRule& rule) {
        return !aegis_access::IsSiteProxyTransportCompatible(
            candidate, {rule.destination_host, rule.include_subdomains,
                        rule.mode, rule.proxy_group_id});
      });
  if (incompatible) {
    return Result(AccessMutationTransactionStatus::kUnsupportedTransportScope);
  }
  return std::nullopt;
}

std::optional<uint64_t> AccessServiceCoordinator::SelectionGeneration(
    const MutationTransaction& transaction) const {
  const auto& pending = transaction.pending;
  if (pending.candidate.members.front().policy.mode != AccessMode::kProxy) {
    return 0;
  }
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto& group = pending.candidate.members.front().policy.proxy_group_id;
  const auto endpoint = transport->CurrentEndpoint(pending.owner);
  auto* source = AccessProxySelectionGenerationSource::Get(profile_);
  if (!endpoint || endpoint->owner != pending.owner ||
      endpoint->proxy_group_id != group || !source ||
      endpoint->generations.selection_generation == 0 ||
      endpoint->generations.network_epoch != transport->network_epoch() ||
      source->selection_generation(group) !=
          endpoint->generations.selection_generation) {
    return std::nullopt;
  }
  return endpoint->generations.selection_generation;
}

std::optional<AccessMutationTransactionResult>
AccessServiceCoordinator::BeginPublication(MutationTransaction& transaction) {
  if (!AccessPublishedRequestRuntime::GetOrCreate(profile_)) {
    return Result(AccessMutationTransactionStatus::kMissingRuntime);
  }
  auto* dispatch = AccessRequestDispatchState::GetOrCreate(profile_);
  if (!dispatch) {
    return Result(AccessMutationTransactionStatus::kMissingDispatchState);
  }
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto& pending = transaction.pending;
  if (!transport || !transport->OwnsConfiguredPartition(pending.owner)) {
    return Result(AccessMutationTransactionStatus::kMissingTransport);
  }
  const auto selection_generation = SelectionGeneration(transaction);
  if (!selection_generation) {
    return Result(AccessMutationTransactionStatus::kProxySelectionUnavailable);
  }
  transaction.identity.operation_id = pending.operation_id;
  transaction.identity.operation_sequence = pending.operation_sequence;
  transaction.identity.policy_generation =
      pending.candidate.policy_generation;
  transaction.identity.proxy_group_id =
      pending.candidate.members.front().policy.mode == AccessMode::kProxy
          ? pending.candidate.members.front().policy.proxy_group_id
          : std::string();
  transaction.identity.selection_generation = *selection_generation;
  transaction.identity.network_epoch = transport->network_epoch();
  const auto begin = dispatch->BeginPolicyPublication(
      {transaction.identity, {"network-context"}, false});
  if (begin.status != aegis_access::PolicyPublicationAckStatus::kPending) {
    return Result(AccessMutationTransactionStatus::kPublicationTrackerRejected);
  }
  transaction.tracker_started = true;
  PrepareTransportCandidate(transaction);
  return std::nullopt;
}

void AccessServiceCoordinator::PrepareTransportCandidate(
    MutationTransaction& transaction) {
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto& pending = transaction.pending;
  transaction.previous_selection = *transport->CurrentSelection(pending.owner);
  transaction.candidate_selection = transaction.previous_selection;
  if (transaction.candidate_selection.endpoint) {
    transaction.candidate_selection.endpoint->generations.policy_generation =
        pending.operation_sequence;
  }
  if (pending.candidate.members.front().policy.mode == AccessMode::kDirect) {
    std::erase(transaction.candidate_selection.exact_hosts,
               transaction.identity.selector.exact_host);
  } else {
    auto insertion = std::ranges::lower_bound(
        transaction.candidate_selection.exact_hosts,
        transaction.identity.selector.exact_host);
    if (insertion == transaction.candidate_selection.exact_hosts.end() ||
        *insertion != transaction.identity.selector.exact_host) {
      transaction.candidate_selection.exact_hosts.insert(
          insertion, transaction.identity.selector.exact_host);
    }
  }
}

std::optional<AccessMutationTransactionResult>
AccessServiceCoordinator::PublishCandidate(MutationTransaction& transaction) {
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto publication =
      runtime->PublishPreparedPolicyCandidate(transaction.candidate);
  if (publication.status != AccessPolicyPublicationStatus::kPublished &&
      publication.status != AccessPolicyPublicationStatus::kUnchanged) {
    return Result(AccessMutationTransactionStatus::kRuntimePublicationFailed);
  }
  transaction.runtime_published = true;
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  if (!transport->ReplaceSelection(transaction.pending.owner,
                                   transaction.previous_selection,
                                   transaction.candidate_selection)) {
    return Result(AccessMutationTransactionStatus::kRuntimePublicationFailed);
  }
  return std::nullopt;
}

void AccessServiceCoordinator::RequestPublicationAck(
    std::unique_ptr<MutationTransaction> transaction) {
  // Copy arguments before moving ownership into the callback.
  const auto identity = transaction->identity;
  const auto owner = transaction->pending.owner;
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto common = async_store_ && runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(owner) : std::nullopt;
  if (async_store_ && !common) {
    OnNetworkContextPublicationAck(std::move(transaction), false);
    return;
  }
  if (common) transaction->common_generations = *common;
  auto reply = WithPublicationTimeout(base::BindOnce(
      &AccessServiceCoordinator::OnNetworkContextPublicationAck,
      weak_factory_.GetWeakPtr(), std::move(transaction)));
  if (async_store_) {
    AccessRequestDispatchState::Get(profile_)->RequestPrivateSnapshotAck(
        identity, *runtime->GetPublishedPolicySnapshot(owner), *common,
        std::move(reply));
    return;
  }
  AccessRequestDispatchState::Get(profile_)
      ->RequestNetworkContextPublicationAck(identity, owner,
                                            std::move(reply));
}

base::OnceCallback<void(bool)> AccessServiceCoordinator::WithPublicationTimeout(
    base::OnceCallback<void(bool)> completion) {
  auto settlement = std::make_shared<base::OnceCallback<void(bool)>>(
      std::move(completion));
  auto settle = [](std::shared_ptr<base::OnceCallback<void(bool)>> callback,
                   bool accepted) {
    if (*callback) {
      std::move(*callback).Run(accepted);
    }
  };
  publication_timeout_.Start(
      FROM_HERE, base::Seconds(30), base::BindOnce(settle, settlement, false));
  return base::BindOnce(settle, settlement);
}

bool AccessServiceCoordinator::CandidateStillCurrent(
    const MutationTransaction& transaction) const {
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto& owner = transaction.pending.owner;
  if (!runtime || !transport || !transport->OwnsConfiguredPartition(owner) ||
      transport->network_epoch() != transaction.identity.network_epoch) {
    return false;
  }
  if (async_store_ && runtime->CaptureCommonGenerationTupleOnUiThread(owner) !=
                          transaction.common_generations) return false;
  const auto* published = runtime->GetPublishedPolicySnapshot(owner);
  const auto adapted =
      AccessRuleStore::AdaptMatcherSnapshot(transaction.candidate);
  if (!published || !adapted.value ||
      *published != aegis_access::PublishedAccessPolicySnapshot{
                        adapted.value->owner,
                        adapted.value->committed_policy_generation,
                        adapted.value->rules}) {
    return false;
  }
  return transport->CurrentSelection(owner) ==
             transaction.candidate_selection &&
         SelectionGeneration(transaction) ==
             transaction.identity.selection_generation;
}

void AccessServiceCoordinator::FailTransaction(
    std::unique_ptr<MutationTransaction> transaction,
    AccessMutationTransactionResult result) {
  if (transaction->tracker_started) {
    if (auto* dispatch = AccessRequestDispatchState::Get(profile_)) {
      dispatch->FailPolicyPublication(transaction->identity);
    }
  }
  if (async_store_) {
    if (!transaction->pending.operation_id.empty()) {
      const auto pending = transaction->pending;
      async_store_->RecoverFailedMutation(pending,
          base::BindOnce(&AccessServiceCoordinator::OnAsyncRecovered,
              weak_factory_.GetWeakPtr(), std::move(transaction), result));
    } else {
      Finish(std::move(transaction->completion), result);
    }
    return;
  }
  if (transaction->runtime_published) {
    RestoreCandidate(*transaction);
  }
  if (store_ && !transaction->pending.operation_id.empty()) {
    const auto cleanup = store_->SupersedePreparedMutation(
        transaction->pending.operation_id,
        transaction->pending.request_fingerprint);
    if (cleanup != StoreStatus::kValid) {
      result.store_status = cleanup;
    }
  }
  Finish(std::move(transaction->completion), result);
}
void AccessServiceCoordinator::OnAsyncRecovered(
    std::unique_ptr<MutationTransaction> transaction,
    AccessMutationTransactionResult failure, AsyncAccessStoreRestoration result) {
  if (result.status == StoreStatus::kValid && result.publication && result.committed) {
    committed_cache_.insert_or_assign(transaction->pending.owner.storage_partition_token,
                                      std::move(*result.committed));
    if (auto* runtime = AccessPublishedRequestRuntime::Get(profile_)) {
      const auto published = runtime->PublishRestoredPolicyCandidate(*result.publication);
      if (published.status != AccessPolicyPublicationStatus::kPublished &&
          published.status != AccessPolicyPublicationStatus::kUnchanged) {
        recovery_required_ = true;
      } else if (auto common = runtime->CaptureCommonGenerationTupleOnUiThread(
                     transaction->pending.owner)) {
        auto* transport = AccessNetworkContextTransport::Get(profile_);
        // A live NetworkContext can hold the original ACK indefinitely.
        // Bound rollback as well; a late ACK must not finish a later mutation.
        auto recovered = WithPublicationTimeout(base::BindOnce(
            [](base::WeakPtr<AccessServiceCoordinator> self,
               std::unique_ptr<MutationTransaction> transaction,
               AccessMutationTransactionResult failure, bool restored) {
              if (self) self->Finish(std::move(transaction->completion), failure);
            }, weak_factory_.GetWeakPtr(), std::move(transaction), failure));
        transport->PublishPrivatePolicy(*result.publication, *common,
                                        std::move(recovered));
        return;
      }
    } else {
      recovery_required_ = true;
    }
  } else {
    recovery_required_ = true;
    failure.store_status = result.status;
  }
  Finish(std::move(transaction->completion), failure);
}

void AccessServiceCoordinator::RestoreCandidate(
    const MutationTransaction& transaction) {
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  if (!runtime || !runtime->RollbackPreparedPolicyCandidate(
                      transaction.candidate, transaction.previous)) {
    return;
  }
  if (auto* transport = AccessNetworkContextTransport::Get(profile_)) {
    transport->ReplaceSelection(transaction.pending.owner,
                                transaction.candidate_selection,
                                transaction.previous_selection);
  }
}

void AccessServiceCoordinator::OnNetworkContextPublicationAck(
    std::unique_ptr<MutationTransaction> transaction,
    bool acknowledged) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* dispatch = AccessRequestDispatchState::Get(profile_);
  if (!acknowledged || !dispatch || (!store_ && !async_store_) ||
      !CandidateStillCurrent(*transaction)) {
    FailTransaction(
        std::move(transaction),
        Result(AccessMutationTransactionStatus::kNetworkPublicationFailed));
    return;
  }
  if (!dispatch->CanCommitPolicyPublication(transaction->identity)) {
    FailTransaction(
        std::move(transaction),
        Result(AccessMutationTransactionStatus::kPublicationTrackerRejected));
    return;
  }
  if (async_store_) {
    const auto pending = transaction->pending;
    async_store_->Commit(pending, base::BindOnce(
        &AccessServiceCoordinator::OnAsyncCommitted, weak_factory_.GetWeakPtr(),
        std::move(transaction)));
    return;
  }
  // Through finalization, execution is synchronous on UI. The store neither
  // pumps tasks nor invokes callbacks: validated tracker transitions cannot
  // change here. Never report a durable commit as a rolled-back transaction.
  auto committed = store_->CommitPreparedMutation(transaction->pending);
  if (committed.status != StoreStatus::kValid || !committed.value) {
    FailTransaction(std::move(transaction),
                    Result(AccessMutationTransactionStatus::kCommitFailed,
                           committed.status));
    return;
  }
  const auto ready =
      dispatch->MarkPolicyPublicationDurablyCommitted(transaction->identity);
  CHECK(ready.status == aegis_access::PolicyPublicationAckStatus::kReady);
  const auto finalized =
      dispatch->FinalizePolicyPublication(transaction->identity);
  CHECK(finalized.status == aegis_access::PolicyPublicationAckStatus::kFinalized);
  ++state_generation_;
  Finish(
      std::move(transaction->completion),
      Result(AccessMutationTransactionStatus::kCommitted, StoreStatus::kValid,
             committed.value->committed_policy_generation));
}

void AccessServiceCoordinator::OnAsyncCommitted(
    std::unique_ptr<MutationTransaction> transaction,
    StoreResult<PendingMutationRecord> committed) {
  if (committed.status != StoreStatus::kValid || !committed.value) {
    FailTransaction(std::move(transaction),
        Result(AccessMutationTransactionStatus::kCommitFailed, committed.status));
    return;
  }
  // Durability cannot be undone if Context/identity changes while IO is pending.
  // Retain committed intent, report unavailable, and keep the request barrier.
  committed_cache_.insert_or_assign(transaction->pending.owner.storage_partition_token,
                                    transaction->candidate);
  ++state_generation_;
  auto* dispatch = AccessRequestDispatchState::Get(profile_);
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  bool ready = dispatch && transport &&
               transport->HasReadyPrivateContext(transaction->pending.owner) &&
               CandidateStillCurrent(*transaction) &&
               dispatch->CanCommitPolicyPublication(transaction->identity);
  if (ready) {
    ready = dispatch->MarkPolicyPublicationDurablyCommitted(transaction->identity).status ==
        aegis_access::PolicyPublicationAckStatus::kReady;
    if (ready) ready = dispatch->FinalizePolicyPublication(transaction->identity).status ==
        aegis_access::PolicyPublicationAckStatus::kFinalized;
  }
  if (!ready && dispatch) dispatch->FailPolicyPublication(transaction->identity);
  Finish(std::move(transaction->completion), Result(
      ready ? AccessMutationTransactionStatus::kCommitted
            : AccessMutationTransactionStatus::kCommittedUnavailable,
      StoreStatus::kValid, committed.value->committed_policy_generation));
}

void AccessServiceCoordinator::Finish(
    base::OnceCallback<void(AccessMutationTransactionResult)> completion,
    AccessMutationTransactionResult result) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  publication_timeout_.Stop();
  mutation_in_flight_ = false;
  if (completion) {
    std::move(completion).Run(result);
  }
}

}  // namespace aegis::access
