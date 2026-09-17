// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_browser_request_adapter.h"

#include <string>
#include <utility>

#include "base/files/file_path.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/uuid.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/channel_info.h"
#include "components/aegis_access/browser_request_metadata_seed.h"
#include "components/version_info/channel.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "net/base/schemeful_site.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

AccessBrowserRequestMetadataResult Error(
    AccessBrowserRequestMetadataStatus status) {
  return {status, std::nullopt};
}

aegis_access::BrowserReleaseChannel BrowserReleaseChannel() {
  switch (chrome::GetChannel()) {
    case version_info::Channel::STABLE:
      return aegis_access::BrowserReleaseChannel::kStable;
    case version_info::Channel::BETA:
      return aegis_access::BrowserReleaseChannel::kBeta;
    case version_info::Channel::DEV:
      return aegis_access::BrowserReleaseChannel::kDev;
    case version_info::Channel::CANARY:
      return aegis_access::BrowserReleaseChannel::kCanary;
    case version_info::Channel::UNKNOWN:
      return aegis_access::BrowserReleaseChannel::kUnknown;
  }
  return aegis_access::BrowserReleaseChannel::kInvalid;
}

std::optional<base::FilePath> RelativePartitionPath(
    Profile* profile,
    content::StoragePartition* partition) {
  if (!profile || !partition) {
    return std::nullopt;
  }
  const base::FilePath& profile_path = profile->GetPath();
  const base::FilePath& partition_path = partition->GetPath();
  if (partition_path == profile_path) {
    return base::FilePath();
  }
  base::FilePath relative_partition_path;
  if (!profile_path.AppendRelativePath(partition_path,
                                       &relative_partition_path)) {
    return std::nullopt;
  }
  return relative_partition_path;
}

std::optional<aegis_access::RequestAttributionKind> ToAttributionKind(
    aegis_access::BrowserRequestAttributionKind kind) {
  switch (kind) {
    case aegis_access::BrowserRequestAttributionKind::kDocument:
      return aegis_access::RequestAttributionKind::kDocument;
    case aegis_access::BrowserRequestAttributionKind::kPendingNavigation:
      return aegis_access::RequestAttributionKind::kPendingNavigation;
    case aegis_access::BrowserRequestAttributionKind::kProfileOnly:
      return aegis_access::RequestAttributionKind::kProfileOnly;
  }
  return std::nullopt;
}

}  // namespace

AccessBrowserRequestMetadataResult BuildBrowserOwnedRequestMetadata(
    Profile* profile,
    const base::RepeatingCallback<content::WebContents*()>& wc_getter,
    content::FrameTreeNodeId frame_tree_node_id,
    std::optional<int64_t> navigation_id) {
  if (!aegis::IsAegisProfileSupported(profile)) {
    return Error(AccessBrowserRequestMetadataStatus::kUnsupportedProfile);
  }

  AccessNetworkContextTransport* transport =
      AccessNetworkContextTransport::Get(profile);
  if (!transport) {
    return Error(AccessBrowserRequestMetadataStatus::kMissingTransport);
  }

  content::WebContents* callback_contents =
      wc_getter.is_null() ? nullptr : wc_getter.Run();
  content::WebContents* frame_contents =
      frame_tree_node_id
          ? content::WebContents::FromFrameTreeNodeId(frame_tree_node_id)
          : nullptr;
  if (callback_contents && frame_contents &&
      callback_contents != frame_contents) {
    return Error(AccessBrowserRequestMetadataStatus::kBrowserContextMismatch);
  }
  content::WebContents* contents =
      frame_contents ? frame_contents : callback_contents;
  if (!contents) {
    return Error(AccessBrowserRequestMetadataStatus::kMissingTrustedContents);
  }
  if (contents->GetBrowserContext() != profile) {
    return Error(AccessBrowserRequestMetadataStatus::kBrowserContextMismatch);
  }

  content::RenderFrameHost* request_frame =
      frame_tree_node_id
          ? contents->UnsafeFindFrameByFrameTreeNodeId(frame_tree_node_id)
          : contents->GetPrimaryMainFrame();
  if (!request_frame) {
    return Error(AccessBrowserRequestMetadataStatus::kMissingTrustedFrame);
  }
  if (request_frame->GetBrowserContext() != profile) {
    return Error(AccessBrowserRequestMetadataStatus::kBrowserContextMismatch);
  }
  if (!request_frame->GetPage().IsPrimary()) {
    return Error(AccessBrowserRequestMetadataStatus::kInvalidAttribution);
  }

  content::StoragePartition* partition = request_frame->GetStoragePartition();
  if (!partition) {
    return Error(AccessBrowserRequestMetadataStatus::kMissingStoragePartition);
  }
  const std::optional<base::FilePath> relative_partition_path =
      RelativePartitionPath(profile, partition);
  if (!relative_partition_path) {
    return Error(AccessBrowserRequestMetadataStatus::kInvalidPartitionPath);
  }

  const aegis_access::ChannelNamespace channel =
      aegis_access::MapBrowserReleaseChannel(BrowserReleaseChannel());
  const std::optional<aegis_access::OwnershipKey> owner =
      transport->OwnerForPartition(channel, *relative_partition_path);
  if (!owner) {
    return Error(AccessBrowserRequestMetadataStatus::kInvalidOwner);
  }

  aegis_access::BrowserRequestMetadataSeedInput seed_input;
  seed_input.request_id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  seed_input.owner = *owner;

  if (navigation_id.has_value()) {
    if (!frame_tree_node_id) {
      return Error(AccessBrowserRequestMetadataStatus::kInvalidAttribution);
    }
    seed_input.pending_navigation_token = base::StrCat(
        {"nav:", base::NumberToString(frame_tree_node_id.value()), ":",
         base::NumberToString(*navigation_id)});
  } else {
    seed_input.document_token =
        AegisService::DocumentIdForWebContents(contents);
    if (!seed_input.document_token.empty()) {
      content::RenderFrameHost* primary_frame = contents->GetPrimaryMainFrame();
      if (!primary_frame || primary_frame->GetBrowserContext() != profile) {
        return Error(AccessBrowserRequestMetadataStatus::kMissingTrustedFrame);
      }
      const net::SchemefulSite top_frame_site(
          primary_frame->GetLastCommittedOrigin());
      if (top_frame_site.opaque() ||
          !top_frame_site.GetURL().SchemeIsHTTPOrHTTPS()) {
        return Error(AccessBrowserRequestMetadataStatus::kInvalidAttribution);
      }
      seed_input.top_frame_site = top_frame_site.Serialize();
    }
  }

  aegis_access::BrowserRequestMetadataSeedResult seed_result =
      aegis_access::PrepareBrowserRequestMetadataSeed(std::move(seed_input));
  if (!seed_result.seed) {
    return Error(AccessBrowserRequestMetadataStatus::kInvalidMetadata);
  }
  const aegis_access::BrowserRequestMetadataSeed& seed = *seed_result.seed;
  const std::optional<aegis_access::RequestAttributionKind> attribution_kind =
      ToAttributionKind(seed.attribution_kind);
  if (!attribution_kind) {
    return Error(AccessBrowserRequestMetadataStatus::kInvalidMetadata);
  }

  aegis_access::BrowserOwnedRequestMetadata metadata;
  metadata.request_id = seed.request_id;
  metadata.owner = seed.owner;
  metadata.attribution_kind = *attribution_kind;
  metadata.document_token = seed.document_token;
  metadata.pending_navigation_token = seed.pending_navigation_token;
  if (seed.attribution_kind ==
      aegis_access::BrowserRequestAttributionKind::kDocument) {
    const GURL top_site_url(seed.top_frame_site);
    if (!top_site_url.is_valid()) {
      return Error(AccessBrowserRequestMetadataStatus::kInvalidMetadata);
    }
    metadata.top_frame_site = net::SchemefulSite(top_site_url);
    if (metadata.top_frame_site->opaque()) {
      return Error(AccessBrowserRequestMetadataStatus::kInvalidMetadata);
    }
  }

  return {AccessBrowserRequestMetadataStatus::kOk, std::move(metadata)};
}

}  // namespace aegis::access
