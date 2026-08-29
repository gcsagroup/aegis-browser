// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_types.h"

#include <algorithm>

#include "net/base/ip_address.h"

namespace aegis::agent {

namespace {

bool IsNumericLoopback(const GURL& url) {
  net::IPAddress address;
  return address.AssignFromIPLiteral(url.HostNoBracketsPiece()) &&
         address.IsLoopback();
}

template <typename T>
bool IsSubset(const base::flat_set<T>& subset,
              const base::flat_set<T>& superset) {
  return std::ranges::all_of(
      subset, [&superset](const T& value) { return superset.contains(value); });
}

}  // namespace

bool AgentBudgets::IsValid() const {
  return max_tabs > 0 && max_tabs <= 20 && max_tool_calls > 0 &&
         max_model_calls > 0 && max_network_requests > 0 &&
         max_duration.is_positive() && max_duration <= base::Hours(24);
}

bool AgentBudgets::IsNoBroaderThan(const AgentBudgets& other) const {
  return max_tabs <= other.max_tabs && max_tool_calls <= other.max_tool_calls &&
         max_model_calls <= other.max_model_calls &&
         max_network_requests <= other.max_network_requests &&
         max_duration <= other.max_duration;
}

bool AgentModelDestination::IsValid() const {
  if (provider.empty() || model.empty()) {
    return false;
  }
  if (kind == Kind::kOnDevice) {
    return endpoint.empty();
  }

  const GURL endpoint_url(endpoint);
  if (!endpoint_url.is_valid() || !endpoint_url.username().empty() ||
      !endpoint_url.password().empty() || endpoint_url.has_query() ||
      endpoint_url.has_ref()) {
    return false;
  }
  if (kind == Kind::kLoopback) {
    return endpoint_url.SchemeIsHTTPOrHTTPS() &&
           IsNumericLoopback(endpoint_url);
  }
  return endpoint_url.SchemeIs("https");
}

bool AgentTaskScope::IsValid() const {
  if (!budgets.IsValid() || !model_destination.IsValid() ||
      allowed_tools.empty() || allowed_tools.size() > 128u ||
      allowed_origins.size() > 64u || allowed_tab_ids.size() > 20u ||
      allowed_data_classes.empty() || allowed_data_classes.size() > 6u ||
      allowed_data_classes.contains(AgentDataClass::kSecret) ||
      std::ranges::any_of(allowed_tab_ids,
                          [](int32_t tab_id) { return tab_id <= 0; }) ||
      allowed_tab_ids.size() > static_cast<size_t>(budgets.max_tabs)) {
    return false;
  }
  base::flat_set<std::string> origin_keys;
  return std::ranges::all_of(allowed_origins, [&](const url::Origin& origin) {
    return !origin.opaque() &&
           (origin.scheme() == "http" || origin.scheme() == "https") &&
           origin_keys.insert(origin.Serialize()).second;
  });
}

bool AgentTaskScope::AllowsTab(int32_t tab_id) const {
  return tab_id > 0 && allowed_tab_ids.contains(tab_id);
}

bool AgentTaskScope::AllowsOrigin(const GURL& url) const {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  const url::Origin requested = url::Origin::Create(url);
  return std::ranges::find(allowed_origins, requested) != allowed_origins.end();
}

bool AgentTaskScope::AllowsTool(const std::string& tool_name) const {
  return allowed_tools.contains(tool_name);
}

bool AgentTaskScope::AllowsDataClass(AgentDataClass data_class) const {
  return data_class != AgentDataClass::kSecret &&
         allowed_data_classes.contains(data_class);
}

bool AgentTaskScope::IsNoBroaderThan(const AgentTaskScope& other) const {
  if (!budgets.IsNoBroaderThan(other.budgets) ||
      model_destination != other.model_destination ||
      !IsSubset(allowed_tab_ids, other.allowed_tab_ids) ||
      !IsSubset(allowed_tools, other.allowed_tools) ||
      !IsSubset(allowed_data_classes, other.allowed_data_classes)) {
    return false;
  }
  return std::ranges::all_of(
      allowed_origins, [&other](const url::Origin& origin) {
        return std::ranges::find(other.allowed_origins, origin) !=
               other.allowed_origins.end();
      });
}

bool AgentDocumentRef::IsValid() const {
  return tab_id > 0 && !frame_token.empty() && !document_token.empty() &&
         committed_url.is_valid() && committed_url.SchemeIsHTTPOrHTTPS();
}

bool IsTerminalState(AgentTaskState state) {
  return state == AgentTaskState::kCompleted ||
         state == AgentTaskState::kFailed ||
         state == AgentTaskState::kCancelled ||
         state == AgentTaskState::kExpired;
}

const char* AgentTaskStateToString(AgentTaskState state) {
  switch (state) {
    case AgentTaskState::kDraft:
      return "draft";
    case AgentTaskState::kPlanning:
      return "planning";
    case AgentTaskState::kAwaitingTaskConsent:
      return "awaiting_task_consent";
    case AgentTaskState::kRunning:
      return "running";
    case AgentTaskState::kReflecting:
      return "reflecting";
    case AgentTaskState::kAwaitingActionApproval:
      return "awaiting_action_approval";
    case AgentTaskState::kPausedByUser:
      return "paused_by_user";
    case AgentTaskState::kUserTakeover:
      return "user_takeover";
    case AgentTaskState::kRecovering:
      return "recovering";
    case AgentTaskState::kVerifying:
      return "verifying";
    case AgentTaskState::kCompleted:
      return "completed";
    case AgentTaskState::kFailed:
      return "failed";
    case AgentTaskState::kCancelled:
      return "cancelled";
    case AgentTaskState::kExpired:
      return "expired";
  }
}

}  // namespace aegis::agent
