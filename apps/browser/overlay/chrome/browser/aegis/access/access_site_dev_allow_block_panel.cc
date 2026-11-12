// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_dev_allow_block_panel.h"

#include "chrome/browser/aegis/access/access_site_proxy_bubble_model.h"

namespace aegis::access {
namespace {

AccessSiteIntent IntentForAction(AccessDevAllowBlockAction action) {
  switch (action) {
    case AccessDevAllowBlockAction::kAllow:
      return AccessSiteIntent::kAllow;
    case AccessDevAllowBlockAction::kBlock:
      return AccessSiteIntent::kBlock;
    case AccessDevAllowBlockAction::kOff:
      return AccessSiteIntent::kOff;
  }
  return AccessSiteIntent::kOff;
}

AccessDevAllowBlockStatusId StatusForIntent(AccessSiteIntent intent) {
  switch (intent) {
    case AccessSiteIntent::kAllow:
      return AccessDevAllowBlockStatusId::kAllowProxyIntent;
    case AccessSiteIntent::kBlock:
      return AccessDevAllowBlockStatusId::kBlockLocalRefuse;
    case AccessSiteIntent::kOff:
      return AccessDevAllowBlockStatusId::kOff;
  }
  return AccessDevAllowBlockStatusId::kOff;
}

AccessDevAllowBlockPanelSnapshot SnapshotForResolvedHost(
    version_info::Channel channel,
    const AccessSiteIntentStore& store,
    const AccessSiteHostResult& host_result) {
  AccessDevAllowBlockPanelSnapshot snapshot;
  snapshot.general_rule_editor_registered =
      IsGeneralAccessRuleEditorRegistered(channel);
  if (!IsAccessDevAllowBlockPanelAdmitted(channel)) {
    snapshot.panel_registered = false;
    snapshot.status_id = AccessDevAllowBlockStatusId::kPanelNotRegistered;
    return snapshot;
  }
  snapshot.panel_registered = true;
  if (host_result.status != AccessSiteHostStatus::kOk || !host_result.host) {
    snapshot.status_id = AccessDevAllowBlockStatusId::kNoTrustedHost;
    return snapshot;
  }
  snapshot.has_explicit_host = true;
  snapshot.host = *host_result.host;
  snapshot.intent = store.Get(snapshot.host);
  snapshot.status_id = StatusForIntent(snapshot.intent);
  return snapshot;
}

}  // namespace

AccessDevAllowBlockChannelAdmission AccessDevAllowBlockPanelAdmissionFor(
    version_info::Channel channel) {
  switch (channel) {
    case version_info::Channel::DEV:
    case version_info::Channel::CANARY:
    case version_info::Channel::UNKNOWN:
      return AccessDevAllowBlockChannelAdmission::kAdmitted;
    case version_info::Channel::BETA:
    case version_info::Channel::STABLE:
      return AccessDevAllowBlockChannelAdmission::kNotAdmitted;
  }
  return AccessDevAllowBlockChannelAdmission::kNotAdmitted;
}

bool IsAccessDevAllowBlockPanelAdmitted(version_info::Channel channel) {
  return AccessDevAllowBlockPanelAdmissionFor(channel) ==
         AccessDevAllowBlockChannelAdmission::kAdmitted;
}

bool IsGeneralAccessRuleEditorRegistered(version_info::Channel channel) {
  // P-mac-4 deliberately does not register a general rule editor on any
  // channel. Beta/Release must stay without that entry.
  (void)channel;
  return false;
}

AccessDevAllowBlockApplyResult ApplyAccessDevAllowBlock(
    AccessSiteIntentStore* store,
    version_info::Channel channel,
    std::string_view raw_host,
    AccessDevAllowBlockAction action) {
  AccessDevAllowBlockApplyResult result;
  if (!store) {
    result.status = AccessDevAllowBlockApplyStatus::kInvalidHost;
    return result;
  }
  if (!IsAccessDevAllowBlockPanelAdmitted(channel)) {
    result.status = AccessDevAllowBlockApplyStatus::kChannelNotAdmitted;
    return result;
  }

  AccessSiteHostResult host_result = NormalizeAccessSiteHost(raw_host);
  if (host_result.status != AccessSiteHostStatus::kOk || !host_result.host) {
    // Already-canonical exact hosts are also accepted.
    host_result = MakeAccessSiteHost(raw_host);
  }
  if (host_result.status != AccessSiteHostStatus::kOk || !host_result.host) {
    result.status = AccessDevAllowBlockApplyStatus::kInvalidHost;
    return result;
  }

  const AccessSiteIntent intent = IntentForAction(action);
  store->Set(*host_result.host, intent);
  result.status = AccessDevAllowBlockApplyStatus::kApplied;
  result.host = *host_result.host;
  result.intent = intent;
  return result;
}

AccessDevAllowBlockPanelSnapshot BuildAccessDevAllowBlockPanelSnapshot(
    version_info::Channel channel,
    const AccessSiteIntentStore& store,
    const GURL& committed_url) {
  return SnapshotForResolvedHost(channel, store,
                                 ResolveTrustedNavigationHost(committed_url));
}

AccessDevAllowBlockPanelSnapshot BuildAccessDevAllowBlockPanelSnapshotForHost(
    version_info::Channel channel,
    const AccessSiteIntentStore& store,
    std::string_view raw_host) {
  AccessSiteHostResult host_result = NormalizeAccessSiteHost(raw_host);
  if (host_result.status != AccessSiteHostStatus::kOk || !host_result.host) {
    host_result = MakeAccessSiteHost(raw_host);
  }
  return SnapshotForResolvedHost(channel, store, host_result);
}

std::string_view AccessDevAllowBlockActionToString(
    AccessDevAllowBlockAction action) {
  switch (action) {
    case AccessDevAllowBlockAction::kAllow:
      return "allow";
    case AccessDevAllowBlockAction::kBlock:
      return "block";
    case AccessDevAllowBlockAction::kOff:
      return "off";
  }
  return "off";
}

std::string_view AccessDevAllowBlockApplyStatusToString(
    AccessDevAllowBlockApplyStatus status) {
  switch (status) {
    case AccessDevAllowBlockApplyStatus::kApplied:
      return "applied";
    case AccessDevAllowBlockApplyStatus::kChannelNotAdmitted:
      return "channel_not_admitted";
    case AccessDevAllowBlockApplyStatus::kInvalidHost:
      return "invalid_host";
  }
  return "invalid_host";
}

}  // namespace aegis::access
