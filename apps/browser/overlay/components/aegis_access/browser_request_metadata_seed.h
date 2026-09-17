// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_BROWSER_REQUEST_METADATA_SEED_H_
#define COMPONENTS_AEGIS_ACCESS_BROWSER_REQUEST_METADATA_SEED_H_

#include <optional>
#include <string>

#include "components/aegis_access/access_route_types.h"

namespace aegis_access {

enum class BrowserReleaseChannel {
  kUnknown,
  kCanary,
  kDev,
  kBeta,
  kStable,
  kInvalid,
};

enum class BrowserRequestAttributionKind {
  kDocument,
  kPendingNavigation,
  kProfileOnly,
};

struct BrowserRequestMetadataSeedInput {
  std::string request_id;
  OwnershipKey owner;
  std::string document_token;
  std::string pending_navigation_token;
  std::string top_frame_site;
};

struct BrowserRequestMetadataSeed {
  std::string request_id;
  OwnershipKey owner;
  BrowserRequestAttributionKind attribution_kind =
      BrowserRequestAttributionKind::kProfileOnly;
  std::string document_token;
  std::string pending_navigation_token;
  std::string top_frame_site;
};

enum class BrowserRequestMetadataSeedError {
  kNone,
  kInvalidOwner,
  kInvalidRequestId,
  kInvalidAttribution,
};

struct BrowserRequestMetadataSeedResult {
  BrowserRequestMetadataSeedError error =
      BrowserRequestMetadataSeedError::kInvalidAttribution;
  std::optional<BrowserRequestMetadataSeed> seed;
};

ChannelNamespace MapBrowserReleaseChannel(BrowserReleaseChannel channel);
BrowserRequestMetadataSeedResult PrepareBrowserRequestMetadataSeed(
    BrowserRequestMetadataSeedInput input);

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_BROWSER_REQUEST_METADATA_SEED_H_
