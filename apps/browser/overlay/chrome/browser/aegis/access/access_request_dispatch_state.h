// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_REQUEST_DISPATCH_STATE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_REQUEST_DISPATCH_STATE_H_

#include <cstddef>
#include <string>

#include "base/memory/weak_ptr.h"
#include "base/supports_user_data.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "components/aegis_access/policy_publication_ack_tracker.h"
#include "components/aegis_access/request_ownership_registry.h"

class Profile;

namespace aegis::access {

struct AccessBlockAndCancelResult {
  aegis_access::RequestDispatchBarrierStatus barrier_status =
      aegis_access::RequestDispatchBarrierStatus::kInvalidBarrier;
  aegis_access::RequestOwnershipStatus cancellation_status =
      aegis_access::RequestOwnershipStatus::kInvalidCancellationSelector;
  size_t matched_requests = 0;
  size_t terminated_requests = 0;
};

struct AccessPolicyBarrierReleaseResult {
  aegis_access::PolicyPublicationAckStatus publication_status =
      aegis_access::PolicyPublicationAckStatus::kNotFound;
  aegis_access::RequestDispatchBarrierStatus barrier_status =
      aegis_access::RequestDispatchBarrierStatus::kNotFound;
  bool released = false;
};

// UI-thread Profile-owned request dispatch state shared by all Aegis
// URLLoaderFactory wrappers for the Profile. Keeping barrier and ownership
// registries here gives policy mutation/cancellation code one stable owner
// without exposing renderer or Network Service objects to the pure contracts.
class AccessRequestDispatchState : public base::SupportsUserData::Data {
 public:
  static AccessRequestDispatchState* Get(Profile* profile);
  static AccessRequestDispatchState* GetOrCreate(Profile* profile);

  AccessRequestDispatchState(const AccessRequestDispatchState&) = delete;
  AccessRequestDispatchState& operator=(const AccessRequestDispatchState&) =
      delete;
  ~AccessRequestDispatchState() override;

  aegis_access::RequestDispatchBarrierRegistry& barriers() {
    return barriers_;
  }
  aegis_access::RequestOwnershipRegistry& ownership() {
    return ownership_;
  }

  // Installs the BLOCK barrier before touching in-flight ownership state, then
  // terminates every matching request. If cancellation fails, the barrier is
  // deliberately retained so new matching requests continue to fail closed.
  AccessBlockAndCancelResult InstallBlockBarrierAndCancelMatching(
      aegis_access::RequestDispatchBarrier barrier);

  aegis_access::PolicyPublicationAckResult BeginPolicyPublication(
      aegis_access::PolicyPublicationAckRequirements requirements);
  aegis_access::PolicyPublicationAckResult AcknowledgePolicyPublication(
      const aegis_access::PolicyPublicationIdentity& identity,
      const std::string& ack_token);
  aegis_access::PolicyPublicationAckResult
  MarkPolicyPublicationTerminationsComplete(
      const aegis_access::PolicyPublicationIdentity& identity);
  aegis_access::PolicyPublicationAckResult MarkPolicyPublicationDurablyCommitted(
      const aegis_access::PolicyPublicationIdentity& identity);
  AccessPolicyBarrierReleaseResult ReleaseBlockBarrierForReadyPublication(
      const aegis_access::PolicyPublicationIdentity& identity);

  AccessNetworkConfigAckResult RequestNetworkContextPublicationAck(
      const aegis_access::PolicyPublicationIdentity& identity,
      const aegis_access::OwnershipKey& owner);

 private:
  explicit AccessRequestDispatchState(Profile* profile);
  void OnNetworkContextPublicationAck(
      aegis_access::PolicyPublicationIdentity identity,
      bool acknowledged);

  Profile* const profile_;
  aegis_access::RequestDispatchBarrierRegistry barriers_;
  aegis_access::RequestOwnershipRegistry ownership_;
  aegis_access::PolicyPublicationAckTracker publication_acks_;
  base::WeakPtrFactory<AccessRequestDispatchState> weak_factory_{this};
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_REQUEST_DISPATCH_STATE_H_
