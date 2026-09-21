// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_request_dispatch_state.h"

#include <memory>
#include <utility>

#include "base/functional/bind.h"

#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/browser_thread.h"

namespace aegis::access {
namespace {

const void* const kDispatchStateUserDataKey = &kDispatchStateUserDataKey;
constexpr size_t kMaxDispatchBarriers = 256;
constexpr size_t kMaxOwnedRequests = 4096;
constexpr size_t kMaxPolicyPublications = 256;
constexpr size_t kMaxPolicyPublicationAckTokens = 8;

}  // namespace

// static
AccessRequestDispatchState* AccessRequestDispatchState::Get(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessRequestDispatchState*>(
      profile->GetUserData(kDispatchStateUserDataKey));
}

// static
AccessRequestDispatchState* AccessRequestDispatchState::GetOrCreate(
    Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile || !aegis::IsAegisProfileSupported(profile)) {
    return nullptr;
  }
  if (auto* existing = Get(profile)) {
    return existing;
  }
  auto state =
      std::unique_ptr<AccessRequestDispatchState>(new AccessRequestDispatchState(profile));
  auto* result = state.get();
  profile->SetUserData(kDispatchStateUserDataKey, std::move(state));
  return result;
}

AccessRequestDispatchState::AccessRequestDispatchState(Profile* profile)
    : profile_(profile),
      barriers_(kMaxDispatchBarriers),
      ownership_(kMaxOwnedRequests),
      publication_acks_(kMaxPolicyPublications,
                        kMaxPolicyPublicationAckTokens) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessRequestDispatchState::~AccessRequestDispatchState() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessBlockAndCancelResult
AccessRequestDispatchState::InstallBlockBarrierAndCancelMatching(
    aegis_access::RequestDispatchBarrier barrier) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);

  const aegis_access::RequestCancellationSelector selector = barrier.selector;
  AccessBlockAndCancelResult result;
  result.barrier_status = barriers_.InstallBlockBarrier(std::move(barrier));
  if (result.barrier_status !=
      aegis_access::RequestDispatchBarrierStatus::kOk) {
    return result;
  }

  const aegis_access::RequestOwnershipBatchCancelResult cancellations =
      ownership_.CancelMatchingPageTarget(selector);
  result.cancellation_status = cancellations.status;
  result.matched_requests = cancellations.cancellations.size();
  for (const auto& cancellation : cancellations.cancellations) {
    if (cancellation.termination_invoked) {
      ++result.terminated_requests;
    }
  }
  return result;
}

aegis_access::PolicyPublicationAckResult
AccessRequestDispatchState::BeginPolicyPublication(
    aegis_access::PolicyPublicationAckRequirements requirements) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return publication_acks_.Begin(std::move(requirements));
}

aegis_access::PolicyPublicationAckResult
AccessRequestDispatchState::AcknowledgePolicyPublication(
    const aegis_access::PolicyPublicationIdentity& identity,
    const std::string& ack_token) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return publication_acks_.Acknowledge(identity, ack_token);
}

aegis_access::PolicyPublicationAckResult
AccessRequestDispatchState::MarkPolicyPublicationTerminationsComplete(
    const aegis_access::PolicyPublicationIdentity& identity) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return publication_acks_.MarkTerminationsComplete(identity);
}

bool AccessRequestDispatchState::CanCommitPolicyPublication(
    const aegis_access::PolicyPublicationIdentity& identity) const {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return publication_acks_.CanCommit(identity);
}

aegis_access::PolicyPublicationAckResult
AccessRequestDispatchState::MarkPolicyPublicationDurablyCommitted(
    const aegis_access::PolicyPublicationIdentity& identity) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return publication_acks_.MarkDurablyCommitted(identity);
}

aegis_access::PolicyPublicationAckResult
AccessRequestDispatchState::FailPolicyPublication(
    const aegis_access::PolicyPublicationIdentity& identity) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return publication_acks_.Abort(identity);
}

aegis_access::PolicyPublicationAckResult
AccessRequestDispatchState::FinalizePolicyPublication(
    const aegis_access::PolicyPublicationIdentity& identity) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return publication_acks_.Finalize(identity);
}

AccessPolicyBarrierReleaseResult
AccessRequestDispatchState::ReleaseBlockBarrierForReadyPublication(
    const aegis_access::PolicyPublicationIdentity& identity) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  AccessPolicyBarrierReleaseResult result;
  const auto publication = publication_acks_.Lookup(identity);
  result.publication_status = publication.status;
  if (publication.status != aegis_access::PolicyPublicationAckStatus::kReady) {
    return result;
  }

  result.barrier_status = barriers_.ReleaseBlockBarrier(
      identity.selector, identity.operation_id, identity.operation_sequence);
  if (result.barrier_status !=
      aegis_access::RequestDispatchBarrierStatus::kOk) {
    return result;
  }

  const auto finalized = publication_acks_.Finalize(identity);
  result.publication_status = finalized.status;
  result.released =
      finalized.status == aegis_access::PolicyPublicationAckStatus::kFinalized;
  return result;
}

AccessNetworkConfigAckResult
AccessRequestDispatchState::RequestNetworkContextPublicationAck(
    const aegis_access::PolicyPublicationIdentity& identity,
    const aegis_access::OwnershipKey& owner,
    base::OnceCallback<void(bool)> completion) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  AccessNetworkContextTransport* transport =
      AccessNetworkContextTransport::Get(profile_);
  if (!transport) {
    publication_acks_.MarkFailed(identity);
    if (completion) {
      std::move(completion).Run(false);
    }
    return {AccessNetworkConfigAckStatus::kMissingTransport, 0};
  }
  AccessNetworkConfigAckResult result =
      transport->PublishPolicyCandidateWithAck(
          identity, owner,
          base::BindOnce(
              &AccessRequestDispatchState::OnNetworkContextPublicationAck,
              weak_factory_.GetWeakPtr(), identity, std::move(completion)));
  if (result.status != AccessNetworkConfigAckStatus::kStarted) {
    publication_acks_.MarkFailed(identity);
  }
  return result;
}

void AccessRequestDispatchState::OnNetworkContextPublicationAck(
    aegis_access::PolicyPublicationIdentity identity,
    base::OnceCallback<void(bool)> completion,
    bool acknowledged) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (acknowledged) {
    const auto result =
        publication_acks_.Acknowledge(identity, "network-context");
    acknowledged = result.status ==
                       aegis_access::PolicyPublicationAckStatus::kPending ||
                   result.status ==
                       aegis_access::PolicyPublicationAckStatus::kReady;
  } else {
    publication_acks_.MarkFailed(identity);
  }
  if (completion) {
    std::move(completion).Run(acknowledged);
  }
}

}  // namespace aegis::access
