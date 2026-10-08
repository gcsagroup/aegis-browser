// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_policy_broker.h"

#include <algorithm>
#include <utility>

#include "base/check.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/uuid.h"
#include "chrome/browser/aegis/agent/agent_planner.h"
#include "crypto/sha2.h"
#include "url/gurl.h"

namespace aegis::agent {

namespace {

AgentPolicyDecision Deny(AgentErrorCode error, std::string reason) {
  return {.disposition = AgentPolicyDisposition::kDeny,
          .risk = AgentRiskLevel::kBlocked,
          .error = error,
          .reason = std::move(reason)};
}

bool ContainsForbiddenSecretField(const base::Value& value) {
  if (value.is_list()) {
    return std::ranges::any_of(value.GetList(), ContainsForbiddenSecretField);
  }
  if (!value.is_dict()) {
    return false;
  }
  for (const auto [key, child] : value.GetDict()) {
    const std::string lowered = base::ToLowerASCII(key);
    if (lowered == "password" || lowered == "passwd" || lowered == "otp" ||
        lowered == "cookie" || lowered == "card_number" || lowered == "cvv" ||
        lowered == "api_key" || lowered == "authorization" ||
        lowered == "access_token" || lowered == "accesstoken" ||
        lowered == "refresh_token" || lowered == "refreshtoken" ||
        lowered == "auth_token" || lowered == "authtoken" ||
        lowered == "client_secret" || lowered == "clientsecret" ||
        lowered == "private_key" || lowered == "privatekey" ||
        lowered == "bearer" || lowered == "secret" || lowered == "token" ||
        lowered == "session" || lowered == "session_id" ||
        lowered == "sessionid" || ContainsForbiddenSecretField(child)) {
      return true;
    }
  }
  return false;
}

bool ContainsForbiddenSecretJson(std::string_view json) {
  std::optional<base::Value> parsed =
      base::JSONReader::Read(json, base::JSON_PARSE_RFC);
  return parsed && ContainsForbiddenSecretField(*parsed);
}

}  // namespace

AgentPolicyBroker::AgentPolicyBroker(const AgentToolRegistry* registry)
    : registry_(registry) {
  CHECK(registry_);
}

AgentPolicyBroker::~AgentPolicyBroker() = default;

AgentPolicyDecision AgentPolicyBroker::Evaluate(
    const AgentTask& task,
    const AgentToolCall& call,
    const std::optional<std::string>& approval_id,
    base::Time now) {
  const bool completed_bookmark_undo =
      task.state() == AgentTaskState::kCompleted &&
      call.tool_name == "bookmark.undo";
  if (IsTerminalState(task.state()) && !completed_bookmark_undo) {
    return Deny(AgentErrorCode::kInvalidRequest, "task is terminal");
  }
  if (call.schema_version != kAgentSchemaVersion || call.action_id.empty() ||
      call.action_id.size() > 128 || call.tool_name.empty()) {
    return Deny(AgentErrorCode::kInvalidRequest,
                "invalid schema, action id, or tool name");
  }

  const AgentToolDescriptor* descriptor = registry_->Find(call.tool_name);
  if (!descriptor) {
    return Deny(AgentErrorCode::kToolUnavailable, "unknown tool");
  }
  if (!task.scope().AllowsTool(call.tool_name) ||
      !task.scope().AllowsDataClass(descriptor->data_class)) {
    return Deny(AgentErrorCode::kScopeViolation,
                "tool or data class is outside task scope");
  }
  if (call.tool_name == "tab.close" &&
      !AgentGoalRequestsTabClose(task.goal())) {
    return Deny(AgentErrorCode::kScopeViolation,
                "tab.close requires an explicit user request to close tabs");
  }
  std::optional<AgentModelToolDefinition> tool_schema =
      registry_->ModelToolForName(call.tool_name);
  std::string schema_error;
  if (!tool_schema || !ValidateAgentToolArguments(*tool_schema, call.arguments,
                                                  &schema_error)) {
    return Deny(AgentErrorCode::kInvalidRequest,
                schema_error.empty() ? "tool arguments have no fixed schema"
                                     : std::move(schema_error));
  }
  if (ContainsForbiddenSecretField(base::Value(call.arguments.Clone()))) {
    return Deny(AgentErrorCode::kScopeViolation,
                "secret fields are forbidden in model tool arguments");
  }
  if (call.tool_name == "bookmark.check_urls") {
    const auto* ids = call.arguments.FindList("node_ids");
    const auto* reference = call.arguments.FindString("selection_ref");
    if ((ids != nullptr) == (reference != nullptr) || (ids && ids->empty())) {
      return Deny(AgentErrorCode::kInvalidRequest,
                  "bookmark check requires exactly one nonempty selection");
    }
  }
  if (const std::string* input_json = call.arguments.FindString("input_json");
      input_json && ContainsForbiddenSecretJson(*input_json)) {
    return Deny(AgentErrorCode::kScopeViolation,
                "secret fields are forbidden in nested tool input");
  }
  if (descriptor->requires_origin &&
      !task.scope().AllowsOrigin(call.committed_url)) {
    return Deny(AgentErrorCode::kScopeViolation,
                "origin is outside task scope");
  }
  if (descriptor->requires_document) {
    if (!call.document || !call.document->IsValid()) {
      return Deny(AgentErrorCode::kStaleDocument,
                  "an exact document binding is required");
    }
    if (call.document->committed_url != call.committed_url) {
      return Deny(AgentErrorCode::kStaleDocument,
                  "document URL does not match the approved URL");
    }
    if (const std::optional<int> tab_id = call.arguments.FindInt("tab_id");
        tab_id && *tab_id != call.document->tab_id) {
      return Deny(AgentErrorCode::kStaleDocument,
                  "tool tab does not match the approved document");
    }
    if (const std::string* document_token =
            call.arguments.FindString("document_token");
        document_token && *document_token != call.document->document_token) {
      return Deny(AgentErrorCode::kStaleDocument,
                  "tool document token does not match the approved document");
    }
  }
  if (const std::optional<int> tab_id = call.arguments.FindInt("tab_id");
      tab_id && !task.AllowsTab(*tab_id)) {
    return Deny(AgentErrorCode::kScopeViolation, "tab is outside task scope");
  }
  if (const base::ListValue* tab_ids = call.arguments.FindList("tab_ids")) {
    for (const base::Value& value : *tab_ids) {
      if (!task.AllowsTab(value.GetInt())) {
        return Deny(AgentErrorCode::kScopeViolation,
                    "one or more tabs are outside task scope");
      }
    }
  }
  if (const std::string* url_argument = call.arguments.FindString("url")) {
    const GURL target(*url_argument);
    if (!task.scope().AllowsOrigin(target) || target.has_username() ||
        target.has_password()) {
      return Deny(AgentErrorCode::kScopeViolation,
                  "target URL origin is outside task scope");
    }
  }
  if (const std::string* candidate_url =
          call.arguments.FindString("candidate_url")) {
    const GURL target(*candidate_url);
    if (!task.scope().AllowsOrigin(target) || target.has_username() ||
        target.has_password()) {
      return Deny(AgentErrorCode::kScopeViolation,
                  "candidate URL origin is outside task scope");
    }
  }
  const AgentRiskLevel effective_risk = EffectiveRisk(task, call);
  if (!HasTaskConsent(task) && !completed_bookmark_undo) {
    return {.disposition = AgentPolicyDisposition::kRequireTaskConsent,
            .risk = effective_risk,
            .error = AgentErrorCode::kApprovalRequired,
            .reason = "task consent is required"};
  }
  if (task.state() != AgentTaskState::kRunning &&
      task.state() != AgentTaskState::kReflecting &&
      task.state() != AgentTaskState::kAwaitingActionApproval &&
      !completed_bookmark_undo) {
    return Deny(AgentErrorCode::kInvalidRequest,
                "task is not in an executable state");
  }

  switch (effective_risk) {
    case AgentRiskLevel::kR0ReadOnly:
    case AgentRiskLevel::kR1Reversible:
      return {.disposition = AgentPolicyDisposition::kAllow,
              .risk = effective_risk,
              .error = AgentErrorCode::kNone,
              .reason = "allowed by task scope"};
    case AgentRiskLevel::kR2ExternalSideEffect:
      if (approval_id &&
          ConsumeApproval(task, call, approval_id.value(), now)) {
        return {.disposition = AgentPolicyDisposition::kAllow,
                .risk = effective_risk,
                .error = AgentErrorCode::kNone,
                .reason = "allowed by exact action approval"};
      }
      return {
          .disposition = AgentPolicyDisposition::kRequireActionApproval,
          .risk = effective_risk,
          .error = AgentErrorCode::kApprovalRequired,
          .reason = descriptor->risk == effective_risk
                        ? "exact action approval is required"
                        : "新地址可能携带任务内容；必须核对完整路径、查询参数"
                          "和接收方后批准"};
    case AgentRiskLevel::kR3UserTakeover:
      return {.disposition = AgentPolicyDisposition::kRequireUserTakeover,
              .risk = descriptor->risk,
              .error = AgentErrorCode::kApprovalRequired,
              .reason = "final transaction requires user takeover"};
    case AgentRiskLevel::kBlocked:
      return Deny(AgentErrorCode::kScopeViolation, "tool is prohibited");
  }
}

std::optional<AgentApprovalReceipt> AgentPolicyBroker::IssueApproval(
    const AgentTask& task,
    const AgentToolCall& call,
    base::TimeDelta ttl,
    int uses,
    base::Time now) {
  if (ttl <= base::TimeDelta() || ttl > base::Minutes(10) || uses != 1 ||
      !HasTaskConsent(task)) {
    return std::nullopt;
  }
  const AgentToolDescriptor* descriptor = registry_->Find(call.tool_name);
  if (!descriptor ||
      EffectiveRisk(task, call) != AgentRiskLevel::kR2ExternalSideEffect) {
    return std::nullopt;
  }

  AgentPolicyDecision unapproved = Evaluate(task, call, std::nullopt, now);
  if (unapproved.disposition !=
      AgentPolicyDisposition::kRequireActionApproval) {
    return std::nullopt;
  }

  AgentApprovalReceipt receipt{
      .approval_id = base::Uuid::GenerateRandomV4().AsLowercaseString(),
      .task_id = task.id(),
      .action_hash = ActionHash(call),
      .expires_at = now + ttl,
      .uses_remaining = uses,
  };
  approvals_[receipt.approval_id] = receipt;
  return receipt;
}

void AgentPolicyBroker::RevokeTaskApprovals(const std::string& task_id) {
  std::erase_if(approvals_, [&task_id](const auto& entry) {
    return entry.second.task_id == task_id;
  });
}

bool AgentPolicyBroker::BindSelectedReadUrls(const AgentTask& task,
                                             const std::vector<GURL>& urls) {
  if (task.state() != AgentTaskState::kDraft ||
      selected_read_urls_.contains(task.id()) || urls.size() > 64u ||
      std::ranges::any_of(urls, [&](const GURL& url) {
        return !task.scope().AllowsOrigin(url) || url.has_username() ||
               url.has_password();
      })) {
    return false;
  }
  selected_read_urls_.emplace(task.id(),
                              base::flat_set<GURL>(urls.begin(), urls.end()));
  return true;
}

bool AgentPolicyBroker::IsSelectedReadUrl(const AgentTask& task,
                                          const GURL& url) const {
  const auto selected = selected_read_urls_.find(task.id());
  return task.scope().AllowsOrigin(url) &&
         selected != selected_read_urls_.end() &&
         selected->second.contains(url);
}

AgentRiskLevel AgentPolicyBroker::EffectiveRisk(
    const AgentTask& task,
    const AgentToolCall& call) const {
  const AgentToolDescriptor* descriptor = registry_->Find(call.tool_name);
  if (!descriptor) {
    return AgentRiskLevel::kBlocked;
  }
  if (descriptor->risk >= AgentRiskLevel::kR2ExternalSideEffect) {
    return descriptor->risk;
  }
  if (task.scope().restrict_to_current_page && call.tool_name == "page.click") {
    return AgentRiskLevel::kR2ExternalSideEffect;
  }
  // 同源URL的路径、查询串和片段同样能够携带数据，不能只比较origin。
  // candidate_url只用于本机下载来源比对，不发起网络请求。
  for (const char* key : {"url"}) {
    if (const auto* value = call.arguments.FindString(key)) {
      const GURL target(*value);
      auto selected = selected_read_urls_.find(task.id());
      if (selected == selected_read_urls_.end() ||
          !selected->second.contains(target)) {
        return AgentRiskLevel::kR2ExternalSideEffect;
      }
    }
  }
  return descriptor->risk;
}

// static
std::string AgentPolicyBroker::ActionHash(const AgentToolCall& call) {
  std::string arguments;
  base::JSONWriter::Write(call.arguments, &arguments);
  std::string material = call.action_id + "\n" + call.tool_name + "\n" +
                         call.committed_url.spec() + "\n" + arguments;
  if (call.document) {
    material += "\n" + std::to_string(call.document->tab_id) + "\n" +
                call.document->frame_token + "\n" +
                call.document->document_token + "\n" +
                call.document->committed_url.spec();
  }
  return base::HexEncode(crypto::SHA256HashString(material));
}

// static
bool AgentPolicyBroker::HasTaskConsent(const AgentTask& task) {
  switch (task.state()) {
    case AgentTaskState::kRunning:
    case AgentTaskState::kReflecting:
    case AgentTaskState::kAwaitingActionApproval:
    case AgentTaskState::kPausedByUser:
    case AgentTaskState::kUserTakeover:
    case AgentTaskState::kRecovering:
    case AgentTaskState::kVerifying:
      return true;
    case AgentTaskState::kDraft:
    case AgentTaskState::kPlanning:
    case AgentTaskState::kAwaitingTaskConsent:
    case AgentTaskState::kCompleted:
    case AgentTaskState::kFailed:
    case AgentTaskState::kCancelled:
    case AgentTaskState::kExpired:
      return false;
  }
}

bool AgentPolicyBroker::ConsumeApproval(const AgentTask& task,
                                        const AgentToolCall& call,
                                        const std::string& approval_id,
                                        base::Time now) {
  auto it = approvals_.find(approval_id);
  if (it == approvals_.end()) {
    return false;
  }
  AgentApprovalReceipt& receipt = it->second;
  if (receipt.task_id != task.id() || receipt.action_hash != ActionHash(call) ||
      receipt.uses_remaining != 1 || now >= receipt.expires_at) {
    return false;
  }
  --receipt.uses_remaining;
  approvals_.erase(it);
  return true;
}

}  // namespace aegis::agent
