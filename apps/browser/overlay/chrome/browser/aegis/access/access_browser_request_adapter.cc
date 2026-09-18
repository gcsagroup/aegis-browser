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
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
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

AccessBrowserRequestMetadataStatus ResolveTrustedContents(
    Profile* profile,
    const base::RepeatingCallback<content::WebContents*()>& wc_getter,
    content::FrameTreeNodeId frame_tree_node_id,
    content::WebContents** trusted_contents) {
  content::WebContents* callback_contents =
      wc_getter.is_null() ? nullptr : wc_getter.Run();
  content::WebContents* frame_contents =
      frame_tree_node_id
          ? content::WebContents::FromFrameTreeNodeId(frame_tree_node_id)
          : nullptr;
  if (callback_contents && frame_contents &&
      callback_contents != frame_contents) {
    return AccessBrowserRequestMetadataStatus::kBrowserContextMismatch;
  }
  content::WebContents* contents =
      frame_contents ? frame_contents : callback_contents;
  if (!contents) {
    return AccessBrowserRequestMetadataStatus::kMissingTrustedContents;
  }
  if (contents->GetBrowserContext() != profile) {
    return AccessBrowserRequestMetadataStatus::kBrowserContextMismatch;
  }
  *trusted_contents = contents;
  return AccessBrowserRequestMetadataStatus::kOk;
}

AccessBrowserRequestMetadataStatus ValidatePrimaryFrameTreeFrame(
    Profile* profile,
    content::WebContents* contents,
    content::RenderFrameHost* request_frame) {
  if (!contents) {
    return AccessBrowserRequestMetadataStatus::kMissingTrustedContents;
  }
  if (!request_frame) {
    return AccessBrowserRequestMetadataStatus::kMissingTrustedFrame;
  }
  if (request_frame->GetBrowserContext() != profile) {
    return AccessBrowserRequestMetadataStatus::kBrowserContextMismatch;
  }
  if (!request_frame->GetPage().IsPrimary() ||
      request_frame->GetMainFrame() != contents->GetPrimaryMainFrame()) {
    return AccessBrowserRequestMetadataStatus::kInvalidAttribution;
  }
  return AccessBrowserRequestMetadataStatus::kOk;
}

AccessBrowserRequestMetadataStatus ResolveTrustedFrame(
    Profile* profile,
    content::WebContents* contents,
    content::FrameTreeNodeId frame_tree_node_id,
    content::RenderFrameHost** trusted_frame) {
  content::RenderFrameHost* request_frame =
      frame_tree_node_id
          ? contents->UnsafeFindFrameByFrameTreeNodeId(frame_tree_node_id)
          : contents->GetPrimaryMainFrame();
  const AccessBrowserRequestMetadataStatus status =
      ValidatePrimaryFrameTreeFrame(profile, contents, request_frame);
  if (status != AccessBrowserRequestMetadataStatus::kOk) {
    return status;
  }
  *trusted_frame = request_frame;
  return AccessBrowserRequestMetadataStatus::kOk;
}

AccessBrowserRequestMetadataStatus ResolveOwnerForPartition(
    Profile* profile,
    content::StoragePartition* partition,
    AccessNetworkContextTransport* transport,
    aegis_access::OwnershipKey* owner) {
  if (!partition) {
    return AccessBrowserRequestMetadataStatus::kMissingStoragePartition;
  }
  const std::optional<base::FilePath> relative_partition_path =
      RelativePartitionPath(profile, partition);
  if (!relative_partition_path) {
    return AccessBrowserRequestMetadataStatus::kInvalidPartitionPath;
  }
  const aegis_access::ChannelNamespace channel =
      aegis_access::MapBrowserReleaseChannel(BrowserReleaseChannel());
  const std::optional<aegis_access::OwnershipKey> resolved_owner =
      transport->OwnerForPartition(channel, *relative_partition_path);
  if (!resolved_owner) {
    return AccessBrowserRequestMetadataStatus::kInvalidOwner;
  }
  *owner = *resolved_owner;
  return AccessBrowserRequestMetadataStatus::kOk;
}

AccessBrowserRequestMetadataStatus ResolveOwner(
    Profile* profile,
    content::RenderFrameHost* request_frame,
    AccessNetworkContextTransport* transport,
    aegis_access::OwnershipKey* owner) {
  return ResolveOwnerForPartition(
      profile, request_frame ? request_frame->GetStoragePartition() : nullptr,
      transport, owner);
}

AccessBrowserRequestMetadataStatus ResolvePrimaryTopFrameSite(
    Profile* profile,
    content::WebContents* contents,
    net::SchemefulSite* top_frame_site) {
  if (!profile || !contents || !top_frame_site) {
    return AccessBrowserRequestMetadataStatus::kMissingTrustedFrame;
  }
  content::RenderFrameHost* primary_frame = contents->GetPrimaryMainFrame();
  const AccessBrowserRequestMetadataStatus frame_status =
      ValidatePrimaryFrameTreeFrame(profile, contents, primary_frame);
  if (frame_status != AccessBrowserRequestMetadataStatus::kOk) {
    return frame_status;
  }

  const net::SchemefulSite resolved_site(
      primary_frame->GetLastCommittedOrigin());
  if (resolved_site.opaque() ||
      !resolved_site.GetURL().SchemeIsHTTPOrHTTPS()) {
    return AccessBrowserRequestMetadataStatus::kInvalidAttribution;
  }
  *top_frame_site = resolved_site;
  return AccessBrowserRequestMetadataStatus::kOk;
}

AccessBrowserRequestMetadataStatus BuildSeedInput(
    Profile* profile,
    content::WebContents* contents,
    content::RenderFrameHost* request_frame,
    std::optional<int64_t> navigation_id,
    const aegis_access::OwnershipKey& owner,
    aegis_access::BrowserRequestMetadataSeedInput* seed_input) {
  const AccessBrowserRequestMetadataStatus frame_status =
      ValidatePrimaryFrameTreeFrame(profile, contents, request_frame);
  if (frame_status != AccessBrowserRequestMetadataStatus::kOk) {
    return frame_status;
  }

  seed_input->request_id =
      base::Uuid::GenerateRandomV4().AsLowercaseString();
  seed_input->owner = owner;
  if (navigation_id.has_value()) {
    const content::FrameTreeNodeId frame_tree_node_id =
        request_frame->GetFrameTreeNodeId();
    if (!frame_tree_node_id) {
      return AccessBrowserRequestMetadataStatus::kInvalidAttribution;
    }
    seed_input->pending_navigation_token = base::StrCat(
        {"nav:", base::NumberToString(frame_tree_node_id.value()), ":",
         base::NumberToString(*navigation_id)});
    if (!request_frame->IsInPrimaryMainFrame()) {
      net::SchemefulSite top_frame_site;
      const AccessBrowserRequestMetadataStatus status =
          ResolvePrimaryTopFrameSite(profile, contents, &top_frame_site);
      if (status != AccessBrowserRequestMetadataStatus::kOk) {
        return status;
      }
      seed_input->top_frame_site = top_frame_site.Serialize();
    }
    return AccessBrowserRequestMetadataStatus::kOk;
  }

  seed_input->document_token =
      AegisService::DocumentIdForWebContents(contents);
  if (seed_input->document_token.empty()) {
    return AccessBrowserRequestMetadataStatus::kOk;
  }
  net::SchemefulSite top_frame_site;
  const AccessBrowserRequestMetadataStatus status =
      ResolvePrimaryTopFrameSite(profile, contents, &top_frame_site);
  if (status != AccessBrowserRequestMetadataStatus::kOk) {
    return status;
  }
  seed_input->top_frame_site = top_frame_site.Serialize();
  return AccessBrowserRequestMetadataStatus::kOk;
}

AccessBrowserRequestMetadataResult BuildMetadataFromSeed(
    aegis_access::BrowserRequestMetadataSeedInput seed_input) {
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
          aegis_access::BrowserRequestAttributionKind::kProfileOnly ||
      (seed.attribution_kind ==
           aegis_access::BrowserRequestAttributionKind::kPendingNavigation &&
       seed.top_frame_site.empty())) {
    return {AccessBrowserRequestMetadataStatus::kOk, std::move(metadata)};
  }
  const GURL top_site_url(seed.top_frame_site);
  if (!top_site_url.is_valid()) {
    return Error(AccessBrowserRequestMetadataStatus::kInvalidMetadata);
  }
  metadata.top_frame_site = net::SchemefulSite(top_site_url);
  if (metadata.top_frame_site->opaque()) {
    return Error(AccessBrowserRequestMetadataStatus::kInvalidMetadata);
  }
  return {AccessBrowserRequestMetadataStatus::kOk, std::move(metadata)};
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

  content::WebContents* contents = nullptr;
  AccessBrowserRequestMetadataStatus status = ResolveTrustedContents(
      profile, wc_getter, frame_tree_node_id, &contents);
  if (status != AccessBrowserRequestMetadataStatus::kOk) {
    return Error(status);
  }
  content::RenderFrameHost* request_frame = nullptr;
  status = ResolveTrustedFrame(profile, contents, frame_tree_node_id,
                               &request_frame);
  if (status != AccessBrowserRequestMetadataStatus::kOk) {
    return Error(status);
  }
  aegis_access::OwnershipKey owner;
  status = ResolveOwner(profile, request_frame, transport, &owner);
  if (status != AccessBrowserRequestMetadataStatus::kOk) {
    return Error(status);
  }
  aegis_access::BrowserRequestMetadataSeedInput seed_input;
  status = BuildSeedInput(profile, contents, request_frame, navigation_id, owner,
                          &seed_input);
  return status == AccessBrowserRequestMetadataStatus::kOk
             ? BuildMetadataFromSeed(std::move(seed_input))
             : Error(status);
}

AccessBrowserRequestMetadataResult BuildBrowserOwnedProfileOnlyRequestMetadata(
    Profile* profile,
    int render_process_id) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!aegis::IsAegisProfileSupported(profile)) {
    return Error(AccessBrowserRequestMetadataStatus::kUnsupportedProfile);
  }

  AccessNetworkContextTransport* transport =
      AccessNetworkContextTransport::Get(profile);
  if (!transport) {
    return Error(AccessBrowserRequestMetadataStatus::kMissingTransport);
  }

  content::RenderProcessHost* process =
      content::RenderProcessHost::FromID(render_process_id);
  if (!process) {
    return Error(AccessBrowserRequestMetadataStatus::kMissingTrustedProcess);
  }
  if (process->GetBrowserContext() != profile) {
    return Error(AccessBrowserRequestMetadataStatus::kBrowserContextMismatch);
  }

  aegis_access::OwnershipKey owner;
  const AccessBrowserRequestMetadataStatus status = ResolveOwnerForPartition(
      profile, process->GetStoragePartition(), transport, &owner);
  if (status != AccessBrowserRequestMetadataStatus::kOk) {
    return Error(status);
  }

  aegis_access::BrowserRequestMetadataSeedInput seed_input;
  seed_input.request_id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  seed_input.owner = std::move(owner);
  return BuildMetadataFromSeed(std::move(seed_input));
}

}  // namespace aegis::access
