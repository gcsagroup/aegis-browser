// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_DEV_ALLOW_BLOCK_PANEL_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_DEV_ALLOW_BLOCK_PANEL_H_

#include <optional>
#include <string>
#include <string_view>

#include "chrome/browser/aegis/access/access_site_intent.h"
#include "components/version_info/channel.h"
#include "url/gurl.h"

namespace aegis::access {

// P-mac-4: DEV/Alpha debug panel for explicit-host ALLOW / BLOCK.
// Beta/Release must not register this panel or a general Access rule editor.

enum class AccessDevAllowBlockChannelAdmission {
  kAdmitted,
  kNotAdmitted,
};

// DEV / Canary / Unknown (local developer builds) admit the panel.
// Beta / Stable never register it.
AccessDevAllowBlockChannelAdmission AccessDevAllowBlockPanelAdmissionFor(
    version_info::Channel channel);

bool IsAccessDevAllowBlockPanelAdmitted(version_info::Channel channel);

// Hard rule for this feat: never register a general rule editor entry.
// Beta/Release stay false; DEV panel is host ALLOW/BLOCK only.
bool IsGeneralAccessRuleEditorRegistered(version_info::Channel channel);

enum class AccessDevAllowBlockAction {
  kAllow,
  kBlock,
  kOff,
};

enum class AccessDevAllowBlockApplyStatus {
  kApplied,
  kChannelNotAdmitted,
  kInvalidHost,
};

struct AccessDevAllowBlockApplyResult {
  AccessDevAllowBlockApplyStatus status =
      AccessDevAllowBlockApplyStatus::kInvalidHost;
  std::optional<AccessSiteHost> host;
  AccessSiteIntent intent = AccessSiteIntent::kOff;
};

// Applies product intent for an explicit host when the channel admits the
// panel. Never invents DIRECT success for allow/block. Does not publish/ACK
// (session finalize stays on the product toggle / P-mac-3 path).
AccessDevAllowBlockApplyResult ApplyAccessDevAllowBlock(
    AccessSiteIntentStore* store,
    version_info::Channel channel,
    std::string_view raw_host,
    AccessDevAllowBlockAction action);

enum class AccessDevAllowBlockStatusId {
  kPanelNotRegistered,
  kNoTrustedHost,
  kOff,
  kAllowProxyIntent,
  kBlockLocalRefuse,
};

struct AccessDevAllowBlockPanelSnapshot {
  // False on Beta/Release — UI must not render the section.
  bool panel_registered = false;
  // Always false: this feat is not a general rule editor.
  bool general_rule_editor_registered = false;
  bool has_explicit_host = false;
  AccessSiteHost host;
  AccessSiteIntent intent = AccessSiteIntent::kOff;
  AccessDevAllowBlockStatusId status_id =
      AccessDevAllowBlockStatusId::kPanelNotRegistered;
};

// Presentation for the DEV panel. Host comes from a trusted committed URL or
// an already-canonical explicit host string.
AccessDevAllowBlockPanelSnapshot BuildAccessDevAllowBlockPanelSnapshot(
    version_info::Channel channel,
    const AccessSiteIntentStore& store,
    const GURL& committed_url);

AccessDevAllowBlockPanelSnapshot BuildAccessDevAllowBlockPanelSnapshotForHost(
    version_info::Channel channel,
    const AccessSiteIntentStore& store,
    std::string_view raw_host);

std::string_view AccessDevAllowBlockActionToString(
    AccessDevAllowBlockAction action);
std::string_view AccessDevAllowBlockApplyStatusToString(
    AccessDevAllowBlockApplyStatus status);

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_DEV_ALLOW_BLOCK_PANEL_H_
