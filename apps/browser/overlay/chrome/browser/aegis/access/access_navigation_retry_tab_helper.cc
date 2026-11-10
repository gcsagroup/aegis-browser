// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_navigation_retry_tab_helper.h"

#include "base/functional/bind.h"
#include "base/logging.h"
#include "components/error_page/content/browser/net_error_auto_reloader.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/page_type.h"
#include "ui/base/page_transition_types.h"

namespace aegis::access {

WEB_CONTENTS_USER_DATA_KEY_IMPL(AccessNavigationRetryTabHelper);

AccessNavigationRetryTabHelper::AccessNavigationRetryTabHelper(
    content::WebContents* contents)
    : content::WebContentsObserver(contents),
      content::WebContentsUserData<AccessNavigationRetryTabHelper>(*contents) {}

AccessNavigationRetryTabHelper::~AccessNavigationRetryTabHelper() = default;

void AccessNavigationRetryTabHelper::ObservePendingNavigation(
    content::WebContents* contents,
    int64_t navigation_id) {
  if (!contents || FromWebContents(contents)) {
    return;
  }
  CreateForWebContents(contents);
  FromWebContents(contents)->state_.BeginNavigation(navigation_id);
}

std::optional<AccessNavigationRetryTicket>
AccessNavigationRetryTabHelper::FailureForRetry() const {
  if (!web_contents()) {
    return std::nullopt;
  }
  auto& controller = web_contents()->GetController();
  const auto* entry = controller.GetLastCommittedEntry();
  if (controller.GetPendingEntry() || !entry ||
      entry->GetPageType() != content::PAGE_TYPE_ERROR) {
    return std::nullopt;
  }
  return state_.Capture();
}

base::OnceClosure AccessNavigationRetryTabHelper::CaptureRouteReadyCallback() {
  auto ticket = FailureForRetry();
  if (!ticket) {
    return {};
  }
  const int entry_id =
      web_contents()->GetController().GetLastCommittedEntry()->GetUniqueID();
  return base::BindOnce(&AccessNavigationRetryTabHelper::OnRouteReady,
                        weak_factory_.GetWeakPtr(), *ticket, entry_id);
}

void AccessNavigationRetryTabHelper::SetProxyRetryHandler(ProxyRetryHandler handler) {
  proxy_retry_handler_ = std::move(handler);
}
bool AccessNavigationRetryTabHelper::RequestProxyRetry(
    base::OnceCallback<void(bool)> completion) {
  auto ticket = FailureForRetry();
  VLOG(1) << "Aegis proxy retry request: ticket=" << ticket.has_value()
          << " remembered_ticket=" << state_.Capture().has_value()
          << " pending_entry=" << !!web_contents()->GetController().GetPendingEntry()
          << " handler=" << !!proxy_retry_handler_
          << " preparing=" << proxy_preparation_pending_;
  if (!ticket || !proxy_retry_handler_ || proxy_preparation_pending_) {
    std::move(completion).Run(false);
    return false;
  }
  proxy_preparation_pending_ = true;
  const int entry_id =
      web_contents()->GetController().GetLastCommittedEntry()->GetUniqueID();
  proxy_retry_handler_.Run(ticket->original_url, base::BindOnce(
      &AccessNavigationRetryTabHelper::OnProxyPrepared, weak_factory_.GetWeakPtr(),
      *ticket, entry_id, std::move(completion)));
  return true;
}
void AccessNavigationRetryTabHelper::OnProxyPrepared(
    AccessNavigationRetryTicket ticket, int error_entry_id,
    base::OnceCallback<void(bool)> completion, bool ready) {
  proxy_preparation_pending_ = false;
  const auto current = FailureForRetry();
  const bool retry = ready && current && *current == ticket &&
      web_contents()->GetController().GetLastCommittedEntry()->GetUniqueID() ==
          error_entry_id;
  if (retry) OnRouteReady(ticket, error_entry_id);
  std::move(completion).Run(retry);
}

void AccessNavigationRetryTabHelper::DidStartNavigation(
    content::NavigationHandle* navigation) {
  if (navigation->IsInPrimaryMainFrame()) {
    VLOG(1) << "Aegis proxy retry start: id=" << navigation->GetNavigationId();
    proxy_preparation_pending_ = false;
    weak_factory_.InvalidateWeakPtrs();
    state_.BeginNavigation(navigation->GetNavigationId());
  }
}

void AccessNavigationRetryTabHelper::DidFinishNavigation(
    content::NavigationHandle* navigation) {
  if (!navigation->IsInPrimaryMainFrame()) {
    return;
  }
  const auto& redirects = navigation->GetRedirectChain();
  const bool recorded = state_.RecordFailure(
      navigation->GetNavigationId(),
      redirects.empty() ? navigation->GetURL() : redirects.front(),
      navigation->GetURL(), navigation->GetRequestMethod(),
      navigation->GetNetErrorCode(),
      navigation->HasCommitted() && navigation->IsErrorPage());
  if (recorded) {
    if (auto* auto_reloader =
            error_page::NetErrorAutoReloader::FromWebContents(web_contents())) {
      // Chromium's background reload may be aborted without replacing the
      // visible error document, revoking its retry ticket before the user can
      // act. Keep this explicit recovery page stable, including during prepare.
      auto_reloader->SuppressAutoReloadForCurrentDocument();
    }
  }
  VLOG(1) << "Aegis proxy retry navigation: id=" << navigation->GetNavigationId()
          << " method=" << navigation->GetRequestMethod()
          << " error=" << navigation->GetNetErrorCode()
          << " committed=" << navigation->HasCommitted()
          << " error_page=" << navigation->IsErrorPage()
          << " recorded=" << recorded;
}

void AccessNavigationRetryTabHelper::NavigationStopped() {
  proxy_preparation_pending_ = false;
  weak_factory_.InvalidateWeakPtrs();
  state_.BeginNavigation(0);
}

void AccessNavigationRetryTabHelper::OnRouteReady(
    AccessNavigationRetryTicket ticket,
    int error_entry_id) {
  const auto current = FailureForRetry();
  if (!current || *current != ticket ||
      web_contents()->GetController().GetLastCommittedEntry()->GetUniqueID() !=
          error_entry_id || !state_.Consume(ticket)) {
    return;
  }
  // Consume before LoadURLWithParams: navigation observers may re-enter here.
  content::NavigationController::LoadURLParams params(ticket.original_url);
  params.transition_type = ui::PAGE_TRANSITION_RELOAD;
  params.should_replace_current_entry = true;
  params.has_user_gesture = true;
  web_contents()->GetController().LoadURLWithParams(params);
}

}  // namespace aegis::access
