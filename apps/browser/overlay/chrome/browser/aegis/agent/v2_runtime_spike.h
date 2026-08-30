// Copyright 2026 GCSA
// Isolated Native Hybrid v2 prototype. This is not the production runtime.

#ifndef CHROME_BROWSER_AEGIS_AGENT_V2_RUNTIME_SPIKE_H_
#define CHROME_BROWSER_AEGIS_AGENT_V2_RUNTIME_SPIKE_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "base/containers/flat_map.h"
#include "base/containers/flat_set.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {

enum class V2SpikeTool {
  kNavigate,
  kClick,
  kType,
  kExtract,
  kWait,
  kScreenshot,
  kReadBookmarks,
};

struct V2DocumentBinding {
  std::string profile_id;
  std::string task_id;
  int32_t tab_id = 0;
  std::string frame_token;
  std::string document_token;
  url::Origin origin;

  bool IsValid() const;
  bool operator==(const V2DocumentBinding&) const = default;
};

struct V2SpikeAction {
  std::string action_id;
  V2SpikeTool tool = V2SpikeTool::kExtract;
  V2DocumentBinding binding;
  std::optional<GURL> destination;
};

enum class V2SpikeDecision {
  kAllow,
  kStopped,
  kScopeViolation,
  kStaleDocument,
  kDuplicateAction,
  kToolDenied,
  kInvalidDestination,
};

// Browser-process authority contract for the M3 spike. It deliberately has no
// CDP endpoint, shell, filesystem, secret, or arbitrary JavaScript capability.
class V2RuntimeSpike {
 public:
  V2RuntimeSpike(std::string profile_id,
                 std::string task_id,
                 std::vector<url::Origin> allowed_origins,
                 size_t max_tabs = 4);
  V2RuntimeSpike(const V2RuntimeSpike&) = delete;
  V2RuntimeSpike& operator=(const V2RuntimeSpike&) = delete;
  ~V2RuntimeSpike();

  GURL BuildDiscoveryUrl(const GURL& search_endpoint,
                         const std::string& goal) const;
  bool AdoptOwnedTab(int32_t tab_id);
  bool ReleaseOwnedTab(int32_t tab_id);
  bool CommitDocument(V2DocumentBinding binding);
  V2SpikeDecision Authorize(const V2SpikeAction& action);
  bool MarkDomObservationFailed(const V2DocumentBinding& binding);
  bool ConsumeVisualFallback(const V2DocumentBinding& binding);
  std::vector<int32_t> Stop();

  bool stopped() const { return stopped_; }
  size_t owned_tab_count() const { return owned_tabs_.size(); }
  bool OwnsTab(int32_t tab_id) const { return owned_tabs_.contains(tab_id); }
  bool AllowsNativeBookmarkMutation() const { return false; }

 private:
  bool AllowsOrigin(const url::Origin& origin) const;

  const std::string profile_id_;
  const std::string task_id_;
  const base::flat_set<url::Origin> allowed_origins_;
  const size_t max_tabs_;
  base::flat_set<int32_t> owned_tabs_;
  base::flat_map<int32_t, V2DocumentBinding> documents_;
  base::flat_set<std::string> consumed_action_ids_;
  base::flat_map<int32_t, V2DocumentBinding> dom_failed_documents_;
  base::flat_map<int32_t, V2DocumentBinding> visual_fallback_documents_;
  bool stopped_ = false;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_V2_RUNTIME_SPIKE_H_
