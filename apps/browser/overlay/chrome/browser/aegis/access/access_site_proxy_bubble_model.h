// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_MODEL_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_MODEL_H_

#include <string>
#include <string_view>

#include "chrome/browser/aegis/access/access_site_intent.h"
#include "url/gurl.h"

namespace aegis::access {

// Connection / session readiness for the toolbar bubble. Distinct from the
// product site-proxy switch (AccessSiteIntent). P-mac-2 shows both; P-mac-3
// advances connection through publish/ACK.
enum class AccessSiteConnectionState {
  kIdle,
  kConnecting,
  kReady,
  kUnavailable,
};

// Short intent-line ids. UI localizes; never conflate with connection copy.
enum class AccessSiteProxyIntentStatusId {
  kNoTrustedSite,
  kOffBrowserDefault,
  kAllowNotConnected,
  kAllowConnected,
  kBlockLocalRefuse,
};

enum class AccessSiteProxyConnectionStatusId {
  kIdle,
  kConnecting,
  kReady,
  kUnavailable,
};

// Presentation snapshot for the toolbar site-proxy bubble.
struct AccessSiteProxyBubbleSnapshot {
  bool has_trusted_site = false;
  AccessSiteHost host;
  AccessSiteIntent intent = AccessSiteIntent::kOff;
  AccessSiteConnectionState connection = AccessSiteConnectionState::kIdle;
  // Checked when intent == allow. Independent of connection readiness.
  bool toggle_on = false;
  // False when the committed URL is not a trusted http(s) navigation host.
  bool toggle_enabled = false;
  AccessSiteProxyIntentStatusId intent_status =
      AccessSiteProxyIntentStatusId::kNoTrustedSite;
  AccessSiteProxyConnectionStatusId connection_status =
      AccessSiteProxyConnectionStatusId::kIdle;
};

std::string_view AccessSiteConnectionStateToString(
    AccessSiteConnectionState state);

// Resolves an exact-host product key from the current navigation's trusted
// URL only: last-committed http(s). Visible/typed URLs are not admitted.
AccessSiteHostResult ResolveTrustedNavigationHost(const GURL& committed_url);

// Builds bubble state. Intent comes from the product store; connection is an
// independent input so switch-on never implies Access connectivity.
AccessSiteProxyBubbleSnapshot BuildSiteProxyBubbleSnapshot(
    const GURL& committed_url,
    const AccessSiteIntentStore& store,
    AccessSiteConnectionState connection);

// Product toggle → allow/off intent. Does not publish, ACK, or claim ready.
bool ApplySiteProxyToggle(AccessSiteIntentStore* store,
                          const AccessSiteHost& host,
                          bool enabled);

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_BUBBLE_MODEL_H_
