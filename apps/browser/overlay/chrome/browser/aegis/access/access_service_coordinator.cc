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
#include "chrome/browser/aegis/access/access_network_context_transport.h"
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
  base::OnceCallback<void(AccessMutationTransactionResult)> completion;
  bool tracker_started = false;
  bool runtime_published = false;
};

AccessServiceCoordinator::MutationTransaction::MutationTransaction() = default;
AccessServiceCoordinator::MutationTransaction::~MutationTransaction() = default;

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
  if (supplied_store && store_) {
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
  if (auto failure = PrepareCandidate(*transaction, request)) {
    FailTransaction(std::move(transaction), *failure);
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
  // CustomProxyConfig selects by destination host, not top-level-site scope.
  const auto matcher =
      AccessRuleStore::AdaptMatcherSnapshot(transaction.candidate);
  if (!matcher.value) {
    return Result(AccessMutationTransactionStatus::kUnsupportedTransportScope);
  }
  const auto& host = transaction.identity.selector.exact_host;
  const bool incompatible = std::ranges::any_of(
      matcher.value->rules, [&](const AccessPolicyRule& rule) {
        const bool overlaps = rule.destination_host == host ||
                              (rule.include_subdomains &&
                               host.ends_with("." + rule.destination_host));
        const bool opposite =
            (mode == AccessMode::kDirect && rule.mode == AccessMode::kProxy) ||
            (mode == AccessMode::kProxy && rule.mode == AccessMode::kDirect);
        return overlaps && opposite;
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
  return std::nullopt;
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
  auto settlement = std::make_shared<base::OnceCallback<void(bool)>>(
      base::BindOnce(&AccessServiceCoordinator::OnNetworkContextPublicationAck,
                     weak_factory_.GetWeakPtr(), std::move(transaction)));
  auto settle = [](std::shared_ptr<base::OnceCallback<void(bool)>> callback,
                   bool accepted) {
    if (*callback) {
      std::move(*callback).Run(accepted);
    }
  };
  publication_timeout_.Start(
      FROM_HERE, base::Seconds(30), base::BindOnce(settle, settlement, false));
  AccessRequestDispatchState::Get(profile_)
      ->RequestNetworkContextPublicationAck(identity, owner,
                                            base::BindOnce(settle, settlement));
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
  if (!acknowledged || !dispatch || !store_ ||
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
