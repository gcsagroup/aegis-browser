// Copyright 2026 GCSA

#include "components/aegis_access/browser_request_metadata_seed.h"

#include <utility>

namespace aegis_access {
namespace {

bool IsKnownChannel(ChannelNamespace channel) {
  switch (channel) {
    case ChannelNamespace::kDev:
    case ChannelNamespace::kAlpha:
    case ChannelNamespace::kBeta:
    case ChannelNamespace::kRelease:
      return true;
    case ChannelNamespace::kInvalid:
      return false;
  }
  return false;
}

bool IsCompleteOwner(const OwnershipKey& owner) {
  return IsKnownChannel(owner.channel) && !owner.profile_token.empty() &&
         !owner.storage_partition_token.empty();
}

BrowserRequestMetadataSeedResult Error(BrowserRequestMetadataSeedError error) {
  return {error, std::nullopt};
}

}  // namespace

ChannelNamespace MapBrowserReleaseChannel(BrowserReleaseChannel channel) {
  switch (channel) {
    case BrowserReleaseChannel::kUnknown:
    case BrowserReleaseChannel::kDev:
      return ChannelNamespace::kDev;
    case BrowserReleaseChannel::kCanary:
      return ChannelNamespace::kAlpha;
    case BrowserReleaseChannel::kBeta:
      return ChannelNamespace::kBeta;
    case BrowserReleaseChannel::kStable:
      return ChannelNamespace::kRelease;
    case BrowserReleaseChannel::kInvalid:
      return ChannelNamespace::kInvalid;
  }
  return ChannelNamespace::kInvalid;
}

BrowserRequestMetadataSeedResult PrepareBrowserRequestMetadataSeed(
    BrowserRequestMetadataSeedInput input) {
  if (!IsCompleteOwner(input.owner)) {
    return Error(BrowserRequestMetadataSeedError::kInvalidOwner);
  }
  if (input.request_id.empty()) {
    return Error(BrowserRequestMetadataSeedError::kInvalidRequestId);
  }

  BrowserRequestMetadataSeed seed;
  seed.request_id = std::move(input.request_id);
  seed.owner = std::move(input.owner);

  if (!input.pending_navigation_token.empty()) {
    seed.attribution_kind = BrowserRequestAttributionKind::kPendingNavigation;
    seed.pending_navigation_token = std::move(input.pending_navigation_token);
    return {BrowserRequestMetadataSeedError::kNone, std::move(seed)};
  }

  if (!input.document_token.empty()) {
    if (input.top_frame_site.empty()) {
      return Error(BrowserRequestMetadataSeedError::kInvalidAttribution);
    }
    seed.attribution_kind = BrowserRequestAttributionKind::kDocument;
    seed.document_token = std::move(input.document_token);
    seed.top_frame_site = std::move(input.top_frame_site);
    return {BrowserRequestMetadataSeedError::kNone, std::move(seed)};
  }

  if (!input.top_frame_site.empty()) {
    return Error(BrowserRequestMetadataSeedError::kInvalidAttribution);
  }

  seed.attribution_kind = BrowserRequestAttributionKind::kProfileOnly;
  return {BrowserRequestMetadataSeedError::kNone, std::move(seed)};
}

}  // namespace aegis_access
