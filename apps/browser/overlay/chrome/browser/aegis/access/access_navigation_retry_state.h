// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NAVIGATION_RETRY_STATE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NAVIGATION_RETRY_STATE_H_

#include <cstdint>
#include <optional>
#include <string_view>

#include "base/unguessable_token.h"
#include "url/gurl.h"

namespace aegis::access {

struct AccessNavigationRetryTicket {
  base::UnguessableToken identity;
  GURL original_url;
  GURL failed_url;

  friend bool operator==(const AccessNavigationRetryTicket&,
                         const AccessNavigationRetryTicket&) = default;
};

// One instance belongs to one WebContents. Its inputs must come from that
// WebContents' primary NavigationHandle, never a visible URL or renderer field.
// A route-ready callback must consume its exact ticket before initiating the
// single reload. Starting another navigation revokes all outstanding tickets.
class AccessNavigationRetryState {
 public:
  AccessNavigationRetryState();
  ~AccessNavigationRetryState();
  AccessNavigationRetryState(const AccessNavigationRetryState&) = delete;
  AccessNavigationRetryState& operator=(const AccessNavigationRetryState&) = delete;

  void BeginNavigation(int64_t navigation_id);
  // Stop revokes the current ticket. Only a new user request from this
  // same committed error entry may receive a new one.
  void StopOnErrorEntry(int entry_id);
  std::optional<AccessNavigationRetryTicket> CaptureForUserRetry(int entry_id);
  bool RecordFailure(int64_t navigation_id,
                     const GURL& original_url,
                     const GURL& failed_url,
                     std::string_view initial_method,
                     int net_error,
                     bool committed_error_page);
  std::optional<AccessNavigationRetryTicket> Capture() const;
  bool Consume(const AccessNavigationRetryTicket& ticket);

 private:
  int64_t navigation_id_ = 0;
  std::optional<AccessNavigationRetryTicket> ticket_;
  std::optional<int> stopped_entry_id_;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NAVIGATION_RETRY_STATE_H_
