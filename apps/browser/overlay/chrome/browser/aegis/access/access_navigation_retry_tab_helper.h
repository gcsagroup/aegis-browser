// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NAVIGATION_RETRY_TAB_HELPER_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NAVIGATION_RETRY_TAB_HELPER_H_

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/aegis/access/access_navigation_retry_state.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"

namespace content {
class NavigationEntry;
}

namespace aegis::access {

class AccessNavigationRetryTabHelper
    : public content::WebContentsObserver,
      public content::WebContentsUserData<AccessNavigationRetryTabHelper> {
 public:
  ~AccessNavigationRetryTabHelper() override;

  // Factory interception can begin after DidStartNavigation. Bootstrap only
  // a newly attached observer with that browser-owned navigation identity.
  static void ObservePendingNavigation(content::WebContents* contents,
                                       int64_t navigation_id);
  std::optional<AccessNavigationRetryTicket> FailureForRetry() const;
  base::OnceClosure CaptureRouteReadyCallback();
  // Captures the current safe GET document for a trusted toolbar action.
  // The callback is invalidated by navigation or Stop.
  base::OnceClosure CaptureSiteProxyReload();
  using ProxyRetryHandler = base::RepeatingCallback<void(
      const GURL&, base::OnceCallback<void(bool)>)>;
  bool HasProxyRetryHandler() const { return !!proxy_retry_handler_; }
  void SetProxyRetryHandler(ProxyRetryHandler handler);
  // Called only after Browser validates the sender is the current primary
  // error document. The target comes from this helper, never renderer IPC.
  bool RequestProxyRetry(base::OnceCallback<void(bool)> completion);

  bool IsPreparingProxyRetry() const {
    return !!pending_retry_reply_ || preparing_site_reload_;
  }

  void DidStartNavigation(content::NavigationHandle* navigation) override;
  void DidFinishNavigation(content::NavigationHandle* navigation) override;
  void OnVisibilityChanged(content::Visibility visibility) override;
  void NavigationStopped() override;

 private:
  friend class content::WebContentsUserData<AccessNavigationRetryTabHelper>;
  explicit AccessNavigationRetryTabHelper(content::WebContents* contents);
  const content::NavigationEntry* CurrentErrorEntry() const;
  const content::NavigationEntry* ReloadableSiteEntry() const;
  void FinishSiteProxyReload(int entry_id, const GURL& url, bool ready);
  void CancelSiteProxyReload();
  void OnRouteReady(AccessNavigationRetryTicket ticket, int error_entry_id);
  void OnProxyPrepared(AccessNavigationRetryTicket ticket, int error_entry_id,
                       bool ready);
  void CancelPendingPreparation();
  void UpdateStopControl();

  AccessNavigationRetryState state_;
  bool committed_safe_get_ = false;
  bool preparing_site_reload_ = false;
  ProxyRetryHandler proxy_retry_handler_;
  base::OnceCallback<void(bool)> pending_retry_reply_;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
  base::WeakPtrFactory<AccessNavigationRetryTabHelper> site_reload_weak_{this};
  base::WeakPtrFactory<AccessNavigationRetryTabHelper> weak_factory_{this};
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_NAVIGATION_RETRY_TAB_HELPER_H_
