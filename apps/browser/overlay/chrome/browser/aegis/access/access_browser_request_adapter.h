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
  kMissingTrustedProcess,
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
// top-level navigation cannot inherit the old page's authorization. Pending
// subframe navigation in the primary Page additionally carries the browser-owned
// primary main-frame SchemefulSite, keeping iframe destination hosts scoped to
// the real top-level site. Prerender/BFCache/fenced/pending Pages are rejected.
// Requests without a trusted WebContents/frame are rejected rather than
// borrowing an active tab identity.
AccessBrowserRequestMetadataResult BuildBrowserOwnedRequestMetadata(
    Profile* profile,
    const base::RepeatingCallback<content::WebContents*()>& wc_getter,
    content::FrameTreeNodeId frame_tree_node_id,
    std::optional<int64_t> navigation_id);

// Builds Profile-only metadata for browser-owned background request factories
// that have no unique page client. The render process supplies only trusted
// BrowserContext/StoragePartition ownership; no WebContents, document token or
// top-level site is borrowed. Site-scoped policy therefore remains ineligible.
AccessBrowserRequestMetadataResult BuildBrowserOwnedProfileOnlyRequestMetadata(
    Profile* profile,
    int render_process_id);

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BROWSER_REQUEST_ADAPTER_H_
