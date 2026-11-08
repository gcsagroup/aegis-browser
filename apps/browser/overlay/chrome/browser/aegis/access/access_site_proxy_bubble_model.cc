// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_bubble_model.h"

namespace aegis::access {
namespace {

AccessSiteProxyConnectionStatusId ConnectionStatusId(
    AccessSiteConnectionState connection) {
  switch (connection) {
    case AccessSiteConnectionState::kIdle:
      return AccessSiteProxyConnectionStatusId::kIdle;
    case AccessSiteConnectionState::kConnecting:
      return AccessSiteProxyConnectionStatusId::kConnecting;
    case AccessSiteConnectionState::kReady:
      return AccessSiteProxyConnectionStatusId::kReady;
    case AccessSiteConnectionState::kUnavailable:
      return AccessSiteProxyConnectionStatusId::kUnavailable;
  }
  return AccessSiteProxyConnectionStatusId::kUnavailable;
}

AccessSiteProxyIntentStatusId IntentStatusId(
    AccessSiteIntent intent,
    AccessSiteConnectionState connection) {
  switch (intent) {
    case AccessSiteIntent::kOff:
      return AccessSiteProxyIntentStatusId::kOffBrowserDefault;
    case AccessSiteIntent::kBlock:
      return AccessSiteProxyIntentStatusId::kBlockLocalRefuse;
    case AccessSiteIntent::kAllow:
      return connection == AccessSiteConnectionState::kReady
                 ? AccessSiteProxyIntentStatusId::kAllowConnected
                 : AccessSiteProxyIntentStatusId::kAllowNotConnected;
  }
  return AccessSiteProxyIntentStatusId::kOffBrowserDefault;
}

}  // namespace

std::string_view AccessSiteConnectionStateToString(
    AccessSiteConnectionState state) {
  switch (state) {
    case AccessSiteConnectionState::kIdle:
      return "idle";
    case AccessSiteConnectionState::kConnecting:
      return "connecting";
    case AccessSiteConnectionState::kReady:
      return "ready";
    case AccessSiteConnectionState::kUnavailable:
      return "unavailable";
  }
  return "unavailable";
}

AccessSiteHostResult ResolveTrustedNavigationHost(const GURL& committed_url) {
  if (!committed_url.is_valid() || !committed_url.SchemeIsHTTPOrHTTPS() ||
      !committed_url.has_host()) {
    return {.status = AccessSiteHostStatus::kEmpty};
  }
  // Committed navigation URL only — never visible/typed speculative hosts.
  return NormalizeAccessSiteHost(committed_url.host());
}

AccessSiteProxyBubbleSnapshot BuildSiteProxyBubbleSnapshot(
    const GURL& committed_url,
    const AccessSiteIntentStore& store,
    AccessSiteConnectionState connection,
    std::string_view failure_reason) {
  AccessSiteProxyBubbleSnapshot snapshot;
  snapshot.connection = connection;
  snapshot.connection_status = ConnectionStatusId(connection);
  snapshot.failure_reason = std::string(failure_reason);

  const AccessSiteHostResult host = ResolveTrustedNavigationHost(committed_url);
  if (host.status != AccessSiteHostStatus::kOk || !host.host.has_value()) {
    snapshot.intent_status = AccessSiteProxyIntentStatusId::kNoTrustedSite;
    return snapshot;
  }

  snapshot.has_trusted_site = true;
  snapshot.host = *host.host;
  snapshot.intent = store.Get(snapshot.host);
  snapshot.toggle_enabled = true;
  snapshot.toggle_on = snapshot.intent == AccessSiteIntent::kAllow;
  snapshot.intent_status = IntentStatusId(snapshot.intent, connection);
  return snapshot;
}

bool ApplySiteProxyToggle(AccessSiteIntentStore* store,
                          const AccessSiteHost& host,
                          bool enabled) {
  if (!store || host.value.empty()) {
    return false;
  }
  const AccessSiteHostResult checked = MakeAccessSiteHost(host.value);
  if (checked.status != AccessSiteHostStatus::kOk) {
    return false;
  }
  store->Set(host, enabled ? AccessSiteIntent::kAllow : AccessSiteIntent::kOff);
  return true;
}

}  // namespace aegis::access
