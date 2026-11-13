// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_navigation_retry_state.h"

#include "net/base/net_errors.h"

namespace aegis::access {
namespace {

bool IsRetryableConnectionFailure(int error) {
  switch (error) {
    case net::ERR_NAME_NOT_RESOLVED:
    case net::ERR_CONNECTION_REFUSED:
    case net::ERR_CONNECTION_RESET:
    case net::ERR_CONNECTION_CLOSED:
    case net::ERR_CONNECTION_TIMED_OUT:
    case net::ERR_TIMED_OUT:
    case net::ERR_INTERNET_DISCONNECTED:
    case net::ERR_NETWORK_CHANGED:
      return true;
    default:
      return false;
  }
}

bool IsWebUrl(const GURL& url) {
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() && url.has_host();
}

}  // namespace

AccessNavigationRetryState::AccessNavigationRetryState() = default;
AccessNavigationRetryState::~AccessNavigationRetryState() = default;

void AccessNavigationRetryState::BeginNavigation(int64_t navigation_id) {
  navigation_id_ = navigation_id;
  ticket_.reset();
  stopped_entry_id_.reset();
}

void AccessNavigationRetryState::StopOnErrorEntry(int entry_id) {
  navigation_id_ = 0;
  if (ticket_ && !stopped_entry_id_) {
    stopped_entry_id_ = entry_id;
  }
}

std::optional<AccessNavigationRetryTicket>
AccessNavigationRetryState::CaptureForUserRetry(int entry_id) {
  if (stopped_entry_id_ == entry_id) {
    ticket_->identity = base::UnguessableToken::Create();
    stopped_entry_id_.reset();
  }
  return Capture();
}

bool AccessNavigationRetryState::RecordFailure(
    int64_t navigation_id,
    const GURL& original_url,
    const GURL& failed_url,
    std::string_view initial_method,
    int net_error,
    bool committed_error_page) {
  if (navigation_id <= 0 || navigation_id != navigation_id_) {
    return false;
  }
  ticket_.reset();
  // Primary Chromium navigations use GET or POST. Never convert a failed
  // POST (including one redirected to GET) or another method into a GET.
  if (!committed_error_page || initial_method != "GET" ||
      !IsRetryableConnectionFailure(net_error) || !IsWebUrl(original_url) ||
      !IsWebUrl(failed_url)) {
    return false;
  }
  ticket_ = AccessNavigationRetryTicket{
      base::UnguessableToken::Create(), original_url, failed_url};
  return true;
}

std::optional<AccessNavigationRetryTicket>
AccessNavigationRetryState::Capture() const {
  return stopped_entry_id_ ? std::nullopt : ticket_;
}

bool AccessNavigationRetryState::Consume(
    const AccessNavigationRetryTicket& ticket) {
  if (stopped_entry_id_ || !ticket_ || *ticket_ != ticket) {
    return false;
  }
  // Revoke before the caller starts a navigation, including any re-entrant
  // callback that navigation may cause.
  ticket_.reset();
  return true;
}

}  // namespace aegis::access
