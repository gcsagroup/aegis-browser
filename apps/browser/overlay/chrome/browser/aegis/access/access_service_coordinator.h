// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SERVICE_COORDINATOR_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SERVICE_COORDINATOR_H_

#include <cstdint>
#include <memory>
#include <optional>

#include "base/functional/callback_forward.h"
#include "base/memory/weak_ptr.h"
#include "base/supports_user_data.h"
#include "base/timer/timer.h"
#include "chrome/browser/aegis/access/access_rule_store.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "components/aegis_access/policy_publication_ack_tracker.h"
#include "components/aegis_access/access_proxy_route_adapter.h"

class Profile;

namespace aegis::access {

enum class AccessMutationTransactionStatus {
  kCommitted,
  kBusy,
  kInvalidRequest,
  kStoreReadFailed,
  kPrepareFailed,
  kCandidateBuildFailed,
  kUnsupportedTransportScope,
  kMissingRuntime,
  kMissingDispatchState,
  kMissingTransport,
  kProxySelectionUnavailable,
  kPublicationTrackerRejected,
  kRuntimePublicationFailed,
  kNetworkPublicationFailed,
  kCommitFailed,
};

struct AccessMutationTransactionResult {
  AccessMutationTransactionStatus status =
      AccessMutationTransactionStatus::kInvalidRequest;
  StoreStatus store_status = StoreStatus::kInvalidArgument;
  uint64_t policy_generation = 0;
};

// Profile-owned transaction coordinator for ordinary site proxy mutations.
// The durable journal stays PREPARED while the full candidate is published to
// request-time memory and exact candidate identity/version is ACKed by every
// owning NetworkContext. Only that exact ACK permits durable commit.
class AccessServiceCoordinator : public base::SupportsUserData::Data {
 public:
  static AccessServiceCoordinator* Get(Profile* profile);
  static AccessServiceCoordinator* GetOrCreate(Profile* profile);

  AccessServiceCoordinator(const AccessServiceCoordinator&) = delete;
  AccessServiceCoordinator& operator=(const AccessServiceCoordinator&) = delete;
  ~AccessServiceCoordinator() override;

  uint64_t state_generation() const { return state_generation_; }

  // Retains the first trusted store for the Profile lifetime, including an
  // ephemeral session database. Later mutations pass nullptr to reuse it.
  // A replacement store is rejected. This stage accepts ordinary DIRECT
  // and PROXY mutations; BLOCK/ALLOW debug actions keep their dedicated
  // barrier/cancellation flow.
  void CommitSiteGroupMutation(
      std::unique_ptr<AccessRuleStore> store,
      SiteGroupMutationRequest request,
      aegis_access::RequestCancellationSelector selector,
      base::OnceCallback<void(AccessMutationTransactionResult)> completion);

 private:
  explicit AccessServiceCoordinator(Profile* profile);
  struct MutationTransaction;
  std::optional<AccessMutationTransactionResult> PrepareCandidate(
      MutationTransaction& transaction,
      const SiteGroupMutationRequest& request);
  std::optional<AccessMutationTransactionResult> ReadPreviousSnapshot(
      MutationTransaction& transaction,
      const SiteGroupMutationRequest& request);
  std::optional<AccessMutationTransactionResult> ValidateTransportScope(
      const MutationTransaction& transaction,
      AccessMode mode) const;
  std::optional<uint64_t> SelectionGeneration(
      const MutationTransaction& transaction) const;
  std::optional<AccessMutationTransactionResult> BeginPublication(
      MutationTransaction& transaction);
  void PrepareTransportCandidate(MutationTransaction& transaction);
  std::optional<AccessMutationTransactionResult> PublishCandidate(
      MutationTransaction& transaction);
  void RequestPublicationAck(std::unique_ptr<MutationTransaction> transaction);
  bool CandidateStillCurrent(const MutationTransaction& transaction) const;
  void FailTransaction(std::unique_ptr<MutationTransaction> transaction,
                       AccessMutationTransactionResult result);
  void RestoreCandidate(const MutationTransaction& transaction);
  void OnNetworkContextPublicationAck(
      std::unique_ptr<MutationTransaction> transaction,
      bool acknowledged);
  void Finish(
      base::OnceCallback<void(AccessMutationTransactionResult)> completion,
      AccessMutationTransactionResult result);

  Profile* const profile_;
  std::unique_ptr<AccessRuleStore> store_;
  uint64_t state_generation_ = 0;
  bool mutation_in_flight_ = false;
  base::OneShotTimer publication_timeout_;
  base::WeakPtrFactory<AccessServiceCoordinator> weak_factory_{this};
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SERVICE_COORDINATOR_H_
