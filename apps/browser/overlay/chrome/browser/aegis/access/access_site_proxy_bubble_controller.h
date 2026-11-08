// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_CONTROLLER_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_CONTROLLER_H_

#include "base/supports_user_data.h"
#include "chrome/browser/aegis/access/access_site_proxy_bubble_model.h"
#include "url/gurl.h"

class Profile;

namespace aegis::access {

// Profile-owned product state for the toolbar site-proxy bubble.
// Holds intent separately from connection. Does not publish or ACK
// (session finalize is P-mac-3).
class AccessSiteProxyBubbleController : public base::SupportsUserData::Data {
 public:
  static AccessSiteProxyBubbleController* Get(Profile* profile);
  static AccessSiteProxyBubbleController* GetOrCreate(Profile* profile);

  AccessSiteProxyBubbleController(const AccessSiteProxyBubbleController&) =
      delete;
  AccessSiteProxyBubbleController& operator=(
      const AccessSiteProxyBubbleController&) = delete;
  ~AccessSiteProxyBubbleController() override;

  AccessSiteIntentStore& intent_store() { return intent_store_; }
  const AccessSiteIntentStore& intent_store() const { return intent_store_; }

  AccessSiteConnectionState connection_state() const {
    return connection_state_;
  }
  // P-mac-3 advances this through connecting/ready/unavailable. P-mac-2 keeps
  // the default idle so switch-on never implies connectivity.
  void SetConnectionState(AccessSiteConnectionState state) {
    connection_state_ = state;
  }

  AccessSiteProxyBubbleSnapshot SnapshotForCommittedUrl(
      const GURL& committed_url) const;

  // Updates product intent only. Never sets connection to ready.
  bool ApplyHostProxyToggle(const AccessSiteHost& host, bool enabled);

 private:
  explicit AccessSiteProxyBubbleController(Profile* profile);

  AccessSiteIntentStore intent_store_;
  AccessSiteConnectionState connection_state_ =
      AccessSiteConnectionState::kIdle;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_CONTROLLER_H_
