// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_bubble_controller.h"

#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/browser_thread.h"

namespace aegis::access {
namespace {

const void* const kAccessSiteProxyBubbleControllerKey =
    &kAccessSiteProxyBubbleControllerKey;

}  // namespace

AccessSiteProxyBubbleController::AccessSiteProxyBubbleController(
    Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  (void)profile;
}

AccessSiteProxyBubbleController::~AccessSiteProxyBubbleController() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessSiteProxyBubbleController* AccessSiteProxyBubbleController::Get(
    Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessSiteProxyBubbleController*>(
      profile->GetUserData(kAccessSiteProxyBubbleControllerKey));
}

AccessSiteProxyBubbleController* AccessSiteProxyBubbleController::GetOrCreate(
    Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile || !aegis::IsAegisProfileSupported(profile)) {
    return nullptr;
  }
  if (AccessSiteProxyBubbleController* existing = Get(profile)) {
    return existing;
  }
  auto controller = std::unique_ptr<AccessSiteProxyBubbleController>(
      new AccessSiteProxyBubbleController(profile));
  AccessSiteProxyBubbleController* raw = controller.get();
  profile->SetUserData(kAccessSiteProxyBubbleControllerKey,
                       std::move(controller));
  return raw;
}

AccessSiteProxyBubbleSnapshot
AccessSiteProxyBubbleController::SnapshotForCommittedUrl(
    const GURL& committed_url) const {
  return BuildSiteProxyBubbleSnapshot(committed_url, intent_store_,
                                      connection_state_);
}

bool AccessSiteProxyBubbleController::ApplyHostProxyToggle(
    const AccessSiteHost& host,
    bool enabled) {
  return ApplySiteProxyToggle(&intent_store_, host, enabled);
}

}  // namespace aegis::access
