// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_CONTROLLER_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_CONTROLLER_H_

#include <map>
#include <memory>
#include <string>
#include <string_view>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/aegis/access/access_local_core_manager.h"
#include "base/supports_user_data.h"
#include "chrome/browser/aegis/access/access_rule_store.h"
#include "chrome/browser/aegis/access/access_service_coordinator.h"
#include "chrome/browser/aegis/access/access_site_dev_allow_block_panel.h"
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

  uint64_t state_revision() const { return state_revision_; }

  AccessSiteProxyBubbleSnapshot SnapshotForCommittedUrl(
      const GURL& committed_url) const;

  // Updates product intent only (no publish). Prefer RequestHostProxySession
  // from the toolbar so publication/ACK runs.
  bool ApplyHostProxyToggle(const AccessSiteHost& host, bool enabled);

  // Product path: enable → local proxy ready → Prepare/Publish/ACK → ready.
  // Disable does not require a live proxy; publication failures remain visible.
  // Returns false only when the host/toggle cannot be accepted.
  bool RequestHostProxySession(const AccessSiteHost& host, bool enabled);
  void RequestFailedNavigationProxy(const GURL& original_url,
      base::OnceCallback<void(bool)> completion);
  base::RepeatingCallback<void(const GURL&, base::OnceCallback<void(bool)>)>
  GetFailedNavigationRetryHandler();
  void EnsureProfileRestored(const OwnershipKey& owner);

  // P-mac-4 DEV panel. False on Beta/Release — UI must not register the
  // section. Never admits a general Access rule editor.
  bool IsDevAllowBlockPanelRegistered() const;
  AccessDevAllowBlockPanelSnapshot DevAllowBlockSnapshotForCommittedUrl(
      const GURL& committed_url) const;
  // Intent-only allow/block/off for an explicit host. Fail-closed when the
  // channel does not admit the panel. Does not publish/ACK.
  AccessDevAllowBlockApplyResult ApplyDevAllowBlock(
      std::string_view raw_host,
      AccessDevAllowBlockAction action);

  // P-mac-5: node/runtime fault while allow stays allow. Never clears the
  // PROXY selection or publishes DIRECT. |wait| holds new requests; otherwise
  // they fail closed.
  bool NotifyHostProxyRuntimeFault(const AccessSiteHost& host, bool wait);

  // Re-arms the allow publication path after fault recovery.
  bool RecoverHostProxySession(const AccessSiteHost& host);

  // Rebuild PROXY publication after Network Service restart (no DIRECT).
  bool RebuildHostProxyAfterNetworkServiceRestart(const AccessSiteHost& host);

 private:
  explicit AccessSiteProxyBubbleController(Profile* profile);
  void PrepareLocalCore(const AccessSiteHost& host);
  void RestoreSavedIntents(OwnershipKey owner, bool restored);
  void OnProfileRestoredForCore(AccessSiteHost host, OwnershipKey owner,
                               bool restored);
  void OnLocalCorePrepared(AccessSiteHost host, OwnershipKey owner,
                          AccessLocalCoreReady result);
  void OnCommittedCoreVerified(AccessSiteHost host, AccessLocalCoreReady result);
  void FailCorePreparation(const AccessSiteHost& host, std::string error);

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
  struct HostState {
    AccessSiteConnectionState connection = AccessSiteConnectionState::kIdle;
    std::string failure_reason;
  };
  std::map<AccessSiteHost, HostState> host_states_;
  uint64_t state_revision_ = 0;
  bool publication_in_flight_ = false;
  std::unique_ptr<AccessLocalCoreManager> local_core_;
  base::OnceCallback<void(bool)> retry_completion_;
  base::WeakPtrFactory<AccessSiteProxyBubbleController> weak_factory_{this};
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_CONTROLLER_H_
