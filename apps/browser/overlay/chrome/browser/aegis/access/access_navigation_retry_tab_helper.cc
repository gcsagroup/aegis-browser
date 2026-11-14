// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_navigation_retry_tab_helper.h"

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/logging.h"
#include "components/error_page/content/browser/net_error_auto_reloader.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/common/page_type.h"
#include "ui/base/page_transition_types.h"

namespace aegis::access {

WEB_CONTENTS_USER_DATA_KEY_IMPL(AccessNavigationRetryTabHelper);

AccessNavigationRetryTabHelper::AccessNavigationRetryTabHelper(
    content::WebContents* contents)
    : content::WebContentsObserver(contents),
      content::WebContentsUserData<AccessNavigationRetryTabHelper>(*contents) {}

AccessNavigationRetryTabHelper::~AccessNavigationRetryTabHelper() {
  state_.BeginNavigation(0);
  CancelPendingPreparation();
}

void AccessNavigationRetryTabHelper::ObservePendingNavigation(
    content::WebContents* contents,
    int64_t navigation_id) {
  if (!contents || FromWebContents(contents)) {
    return;
  }
  CreateForWebContents(contents);
  FromWebContents(contents)->state_.BeginNavigation(navigation_id);
}

const content::NavigationEntry*
AccessNavigationRetryTabHelper::CurrentErrorEntry() const {
  if (!web_contents()) {
    return nullptr;
  }
  auto& controller = web_contents()->GetController();
  const auto* entry = controller.GetLastCommittedEntry();
  if (controller.GetPendingEntry() || !entry ||
      entry->GetPageType() != content::PAGE_TYPE_ERROR) {
    return nullptr;
  }
  return entry;
}

std::optional<AccessNavigationRetryTicket>
AccessNavigationRetryTabHelper::FailureForRetry() const {
  return CurrentErrorEntry() ? state_.Capture() : std::nullopt;
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

const content::NavigationEntry*
AccessNavigationRetryTabHelper::ReloadableSiteEntry() const {
  auto* tab = web_contents();
  if (!committed_safe_get_ || !tab || tab->IsBeingDestroyed() ||
      tab->GetVisibility() != content::Visibility::VISIBLE ||
      tab->HasUncommittedNavigationInPrimaryMainFrame()) {
    return nullptr;
  }
  auto& controller = tab->GetController();
  const auto* entry = controller.GetLastCommittedEntry();
  return !controller.GetPendingEntry() && entry &&
                 entry->GetPageType() == content::PAGE_TYPE_NORMAL &&
                 !entry->GetHasPostData() && entry->GetURL().SchemeIsHTTPOrHTTPS() &&
                 !entry->GetURL().has_username() && !entry->GetURL().has_password()
             ? entry : nullptr;
}

base::OnceClosure AccessNavigationRetryTabHelper::CaptureSiteProxyReload() {
  const auto* entry = ReloadableSiteEntry();
  if (!entry || preparing_site_reload_) return {};
  auto completion = base::BindOnce(
      &AccessNavigationRetryTabHelper::FinishSiteProxyReload,
      site_reload_weak_.GetWeakPtr(), entry->GetUniqueID(), entry->GetURL());
  // A rejected or superseded publication drops its closure. Clear the Stop
  // state in that case as well as on a successful route installation.
  auto callbacks = base::SplitOnceCallback(std::move(completion));
  auto reload = base::BindOnce(
      [](base::OnceCallback<void(bool)> complete,
         base::ScopedClosureRunner abandon) {
        (void)abandon.Release();
        std::move(complete).Run(true);
      }, std::move(callbacks.first),
      base::ScopedClosureRunner(base::BindOnce(std::move(callbacks.second), false)));
  preparing_site_reload_ = true;
  UpdateStopControl();
  return reload;
}

void AccessNavigationRetryTabHelper::FinishSiteProxyReload(
    int entry_id, const GURL& url, bool ready) {
  CancelSiteProxyReload();
  if (!ready) return;
  const auto* current = ReloadableSiteEntry();
  if (!current || current->GetUniqueID() != entry_id || current->GetURL() != url) {
    return;
  }
  // The controller reloads the committed entry and preserves its history.
  // Bypass the original cache so the request exercises the new route.
  web_contents()->GetController().Reload(content::ReloadType::BYPASSING_CACHE,
                                          /*check_for_repost=*/true);
}

void AccessNavigationRetryTabHelper::CancelSiteProxyReload() {
  site_reload_weak_.InvalidateWeakPtrs();
  if (!preparing_site_reload_) return;
  preparing_site_reload_ = false;
  UpdateStopControl();
}

void AccessNavigationRetryTabHelper::SetProxyRetryHandler(ProxyRetryHandler handler) {
  proxy_retry_handler_ = std::move(handler);
}
bool AccessNavigationRetryTabHelper::RequestProxyRetry(
    base::OnceCallback<void(bool)> completion) {
  const auto* entry = CurrentErrorEntry();
  auto ticket = entry ? state_.CaptureForUserRetry(entry->GetUniqueID())
                      : std::nullopt;
  VLOG(1) << "Aegis proxy retry request: ticket=" << ticket.has_value()
          << " remembered_ticket=" << state_.Capture().has_value()
          << " pending_entry=" << !!web_contents()->GetController().GetPendingEntry()
          << " handler=" << !!proxy_retry_handler_
          << " preparing=" << !!pending_retry_reply_;
  if (!ticket || !proxy_retry_handler_ || pending_retry_reply_) {
    std::move(completion).Run(false);
    return false;
  }
  const int entry_id = entry->GetUniqueID();
  pending_retry_reply_ = std::move(completion);
  UpdateStopControl();
  // Grant the failed destination; OnRouteReady still reloads the original URL.
  proxy_retry_handler_.Run(ticket->failed_url, base::BindOnce(
      &AccessNavigationRetryTabHelper::OnProxyPrepared, weak_factory_.GetWeakPtr(),
      *ticket, entry_id));
  return true;
}
void AccessNavigationRetryTabHelper::OnProxyPrepared(
    AccessNavigationRetryTicket ticket, int error_entry_id, bool ready) {
  // Loading the original URL can synchronously start another navigation.
  auto reply = std::move(pending_retry_reply_);
  UpdateStopControl();
  const auto current = FailureForRetry();
  const bool retry = ready && current && *current == ticket &&
      web_contents()->GetController().GetLastCommittedEntry()->GetUniqueID() ==
          error_entry_id;
  if (retry) OnRouteReady(ticket, error_entry_id);
  std::move(reply).Run(retry);
}

void AccessNavigationRetryTabHelper::CancelPendingPreparation() {
  weak_factory_.InvalidateWeakPtrs();
  CancelSiteProxyReload();
  // Stop can leave the same error document and its Mojo reply pipe alive.
  if (pending_retry_reply_) {
    auto reply = std::move(pending_retry_reply_);
    UpdateStopControl();
    std::move(reply).Run(false);
  }
}

void AccessNavigationRetryTabHelper::UpdateStopControl() {
  auto* contents = web_contents();
  if (contents && !contents->IsBeingDestroyed() && contents->GetDelegate()) {
    contents->GetDelegate()->LoadingStateChanged(contents,
                                                contents->ShouldShowLoadingUI());
  }
}

void AccessNavigationRetryTabHelper::DidStartNavigation(
    content::NavigationHandle* navigation) {
  if (navigation->IsInPrimaryMainFrame()) {
    VLOG(1) << "Aegis proxy retry start: id=" << navigation->GetNavigationId();
    state_.BeginNavigation(navigation->GetNavigationId());
    CancelPendingPreparation();
  }
}

void AccessNavigationRetryTabHelper::DidFinishNavigation(
    content::NavigationHandle* navigation) {
  if (!navigation->IsInPrimaryMainFrame()) {
    return;
  }
  if (navigation->HasCommitted() && !navigation->IsSameDocument()) {
    committed_safe_get_ = !navigation->IsErrorPage() &&
                          !navigation->IsPageActivation() &&
                          navigation->GetRequestMethod() == "GET";
  }
  const auto& redirects = navigation->GetRedirectChain();
  const bool recorded = state_.RecordFailure(
      navigation->GetNavigationId(),
      redirects.empty() ? navigation->GetURL() : redirects.front(),
      navigation->GetURL(), navigation->GetRequestMethod(),
      navigation->GetNetErrorCode(),
      navigation->HasCommitted() && navigation->IsErrorPage());
  if (recorded && HasProxyRetryHandler()) {
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
  if (const auto* entry = CurrentErrorEntry()) {
    state_.StopOnErrorEntry(entry->GetUniqueID());
  } else {
    state_.BeginNavigation(0);
  }
  CancelPendingPreparation();
}

void AccessNavigationRetryTabHelper::OnVisibilityChanged(
    content::Visibility visibility) {
  if (visibility == content::Visibility::HIDDEN) {
    CancelSiteProxyReload();
  }
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
