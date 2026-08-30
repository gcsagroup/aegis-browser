// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/v2_runtime_spike.h"

#include <utility>

#include "net/base/url_util.h"

namespace aegis::agent {

bool V2DocumentBinding::IsValid() const {
  return !profile_id.empty() && !task_id.empty() && tab_id > 0 &&
         !frame_token.empty() && !document_token.empty() && !origin.opaque();
}

V2RuntimeSpike::V2RuntimeSpike(std::string profile_id,
                               std::string task_id,
                               std::vector<url::Origin> allowed_origins,
                               size_t max_tabs)
    : profile_id_(std::move(profile_id)),
      task_id_(std::move(task_id)),
      allowed_origins_(std::move(allowed_origins)),
      max_tabs_(max_tabs) {}

V2RuntimeSpike::~V2RuntimeSpike() = default;

GURL V2RuntimeSpike::BuildDiscoveryUrl(const GURL& search_endpoint,
                                       const std::string& goal) const {
  if (stopped_ || goal.empty() || !search_endpoint.SchemeIsHTTPOrHTTPS() ||
      search_endpoint.has_username() || search_endpoint.has_password() ||
      !AllowsOrigin(url::Origin::Create(search_endpoint))) {
    return GURL();
  }
  return net::AppendQueryParameter(search_endpoint, "q", goal);
}

bool V2RuntimeSpike::AdoptOwnedTab(int32_t tab_id) {
  if (stopped_ || tab_id <= 0 || owned_tabs_.size() >= max_tabs_) {
    return false;
  }
  return owned_tabs_.insert(tab_id).second;
}

bool V2RuntimeSpike::ReleaseOwnedTab(int32_t tab_id) {
  documents_.erase(tab_id);
  dom_failed_documents_.erase(tab_id);
  visual_fallback_documents_.erase(tab_id);
  return owned_tabs_.erase(tab_id) > 0;
}

bool V2RuntimeSpike::CommitDocument(V2DocumentBinding binding) {
  if (stopped_ || !binding.IsValid() || binding.profile_id != profile_id_ ||
      binding.task_id != task_id_ || !OwnsTab(binding.tab_id) ||
      !AllowsOrigin(binding.origin)) {
    return false;
  }
  const auto current = documents_.find(binding.tab_id);
  if (current == documents_.end() || current->second != binding) {
    dom_failed_documents_.erase(binding.tab_id);
    visual_fallback_documents_.erase(binding.tab_id);
  }
  documents_.insert_or_assign(binding.tab_id, std::move(binding));
  return true;
}

V2SpikeDecision V2RuntimeSpike::Authorize(const V2SpikeAction& action) {
  if (stopped_) {
    return V2SpikeDecision::kStopped;
  }
  if (action.action_id.empty() ||
      consumed_action_ids_.contains(action.action_id)) {
    return V2SpikeDecision::kDuplicateAction;
  }
  if (action.binding.profile_id != profile_id_ ||
      action.binding.task_id != task_id_ || !OwnsTab(action.binding.tab_id)) {
    return V2SpikeDecision::kScopeViolation;
  }
  const auto document = documents_.find(action.binding.tab_id);
  if (document == documents_.end() || document->second != action.binding) {
    return V2SpikeDecision::kStaleDocument;
  }
  if (action.tool == V2SpikeTool::kReadBookmarks) {
    if (action.destination) {
      return V2SpikeDecision::kToolDenied;
    }
    consumed_action_ids_.insert(action.action_id);
    return V2SpikeDecision::kAllow;
  }
  if (action.tool == V2SpikeTool::kNavigate) {
    if (!action.destination || !action.destination->SchemeIsHTTPOrHTTPS() ||
        action.destination->has_username() ||
        action.destination->has_password() ||
        !AllowsOrigin(url::Origin::Create(*action.destination))) {
      return V2SpikeDecision::kInvalidDestination;
    }
  } else if (action.destination) {
    return V2SpikeDecision::kToolDenied;
  }
  consumed_action_ids_.insert(action.action_id);
  return V2SpikeDecision::kAllow;
}

bool V2RuntimeSpike::MarkDomObservationFailed(
    const V2DocumentBinding& binding) {
  const auto document = documents_.find(binding.tab_id);
  if (stopped_ || document == documents_.end() || document->second != binding) {
    return false;
  }
  dom_failed_documents_.insert_or_assign(binding.tab_id, binding);
  return true;
}

bool V2RuntimeSpike::ConsumeVisualFallback(const V2DocumentBinding& binding) {
  const auto document = documents_.find(binding.tab_id);
  const auto dom_failed = dom_failed_documents_.find(binding.tab_id);
  const auto visual_fallback = visual_fallback_documents_.find(binding.tab_id);
  if (stopped_ || document == documents_.end() || document->second != binding ||
      dom_failed == dom_failed_documents_.end() ||
      dom_failed->second != binding ||
      (visual_fallback != visual_fallback_documents_.end() &&
       visual_fallback->second == binding)) {
    return false;
  }
  visual_fallback_documents_.insert_or_assign(binding.tab_id, binding);
  return true;
}

std::vector<int32_t> V2RuntimeSpike::Stop() {
  std::vector<int32_t> owned_tabs(owned_tabs_.begin(), owned_tabs_.end());
  stopped_ = true;
  owned_tabs_.clear();
  documents_.clear();
  consumed_action_ids_.clear();
  dom_failed_documents_.clear();
  visual_fallback_documents_.clear();
  return owned_tabs;
}

bool V2RuntimeSpike::AllowsOrigin(const url::Origin& origin) const {
  return allowed_origins_.contains(origin);
}

}  // namespace aegis::agent
