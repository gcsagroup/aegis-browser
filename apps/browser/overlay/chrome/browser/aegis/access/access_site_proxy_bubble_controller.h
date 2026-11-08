// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_CONTROLLER_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_CONTROLLER_H_

#include <memory>
#include <string>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/supports_user_data.h"
#include "chrome/browser/aegis/access/access_rule_store.h"
#include "chrome/browser/aegis/access/access_service_coordinator.h"
#include "chrome/browser/aegis/access/access_site_proxy_bubble_model.h"
#include "chrome/browser/aegis/access/access_site_proxy_session.h"
#include "url/gurl.h"

class Profile;

namespace aegis::access {

// Profile-owned product state for the toolbar site-proxy bubble.
// Holds intent separately from connection. P-mac-3 wires the toggle onto
// PrepareCandidate → Publish → ACK (and requires local proxy readiness).
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
  const std::string& failure_reason() const { return failure_reason_; }

  void SetConnectionState(AccessSiteConnectionState state) {
    connection_state_ = state;
  }

  AccessSiteProxyBubbleSnapshot SnapshotForCommittedUrl(
      const GURL& committed_url) const;

  // Updates product intent only (no publish). Prefer RequestHostProxySession
  // from the toolbar so publication/ACK runs.
  bool ApplyHostProxyToggle(const AccessSiteHost& host, bool enabled);

  // Product path: enable → local proxy ready → Prepare/Publish/ACK → ready.
  // Disable locally commits even when the Access service is unavailable.
  // Returns false only when the host/toggle cannot be accepted.
  bool RequestHostProxySession(const AccessSiteHost& host, bool enabled);

 private:
  explicit AccessSiteProxyBubbleController(Profile* profile);

  AccessSiteProxySessionError EnsureLocalProxyReady(
      const AccessSiteHost& host,
      AccessSiteProxyLocalProxyReadyInfo* out) const;
  void BeginEnablePublication(const AccessSiteHost& host,
                              AccessSiteProxyLocalProxyReadyInfo ready);
  void BeginDisablePublication(const AccessSiteHost& host);
  void OnPublicationComplete(AccessSiteHost host,
                             bool enabling,
                             AccessMutationTransactionResult result);
  std::unique_ptr<AccessRuleStore> OpenSessionStore(
      const OwnershipKey& owner) const;

  const raw_ptr<Profile> profile_;
  AccessSiteIntentStore intent_store_;
  AccessSiteConnectionState connection_state_ =
      AccessSiteConnectionState::kIdle;
  std::string failure_reason_;
  bool store_retained_ = false;
  bool publication_in_flight_ = false;
  base::WeakPtrFactory<AccessSiteProxyBubbleController> weak_factory_{this};
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_CONTROLLER_H_
