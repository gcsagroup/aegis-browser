// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BROWSER_REQUEST_ADAPTER_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BROWSER_REQUEST_ADAPTER_H_

#include <cstdint>
#include <optional>

#include "base/functional/callback.h"
#include "components/aegis_access/request_policy_context.h"
#include "content/public/browser/frame_tree_node_id.h"

class Profile;

namespace content {
class WebContents;
}

namespace aegis::access {

enum class AccessBrowserRequestMetadataStatus {
  kOk,
  kUnsupportedProfile,
  kMissingTransport,
  kMissingTrustedContents,
  kBrowserContextMismatch,
  kMissingTrustedFrame,
  kMissingStoragePartition,
  kInvalidPartitionPath,
  kInvalidOwner,
  kInvalidAttribution,
  kInvalidMetadata,
};

struct AccessBrowserRequestMetadataResult {
  AccessBrowserRequestMetadataStatus status =
      AccessBrowserRequestMetadataStatus::kInvalidMetadata;
  std::optional<aegis_access::BrowserOwnedRequestMetadata> metadata;
};

// Builds Access metadata exclusively from browser-owned Profile/WebContents /
// RenderFrameHost / StoragePartition state. It never consumes renderer-supplied
// request_initiator/source-site strings and never creates transport state.
//
// A navigation id takes precedence over the currently committed document so a
// navigation cannot inherit the old page's authorization. Only frames in the
// primary Page are eligible; prerender/BFCache/fenced/pending Pages are rejected
// rather than inheriting the primary page's identity. Requests without a trusted
// WebContents/frame are rejected in this slice rather than borrowing an active
// tab identity.
AccessBrowserRequestMetadataResult BuildBrowserOwnedRequestMetadata(
    Profile* profile,
    const base::RepeatingCallback<content::WebContents*()>& wc_getter,
    content::FrameTreeNodeId frame_tree_node_id,
    std::optional<int64_t> navigation_id);

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BROWSER_REQUEST_ADAPTER_H_
