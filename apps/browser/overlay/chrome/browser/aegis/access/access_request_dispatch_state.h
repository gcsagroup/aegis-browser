// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_REQUEST_DISPATCH_STATE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_REQUEST_DISPATCH_STATE_H_

#include <cstddef>

#include "base/supports_user_data.h"
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

 private:
  AccessRequestDispatchState();

  aegis_access::RequestDispatchBarrierRegistry barriers_;
  aegis_access::RequestOwnershipRegistry ownership_;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_REQUEST_DISPATCH_STATE_H_
