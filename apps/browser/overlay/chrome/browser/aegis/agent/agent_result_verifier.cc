// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_result_verifier.h"

#include <algorithm>
#include <array>
#include <string_view>
#include <utility>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_util.h"
#include "base/uuid.h"
#include "url/gurl.h"

namespace aegis::agent {
namespace {

constexpr size_t kMaxVerifiedResultBytes = 256 * 1024;

AgentVerificationDecision Reject(std::string reason) {
  return {.accepted = false,
          .postcondition_met = false,
          .error = AgentErrorCode::kVerificationFailed,
          .reason = std::move(reason)};
}

AgentVerificationDecision Accept(bool postcondition_met, std::string reason) {
  return {.accepted = true,
          .postcondition_met = postcondition_met,
          .error = AgentErrorCode::kNone,
          .reason = std::move(reason)};
}

bool HasForbiddenResultField(const base::Value& value, int depth = 0) {
  if (depth > 16) {
    return true;
  }
  if (value.is_list()) {
    for (const base::Value& child : value.GetList()) {
      if (HasForbiddenResultField(child, depth + 1)) {
        return true;
      }
    }
    return false;
  }
  if (value.is_string()) {
    std::optional<base::Value> parsed =
        base::JSONReader::Read(value.GetString(), base::JSON_PARSE_RFC);
    return parsed && HasForbiddenResultField(*parsed, depth + 1);
  }
  if (!value.is_dict()) {
    return false;
  }
  for (const auto [key, child] : value.GetDict()) {
    const std::string lowered = base::ToLowerASCII(key);
    if (lowered == "password" || lowered == "passwd" || lowered == "otp" ||
        lowered == "cookie" || lowered == "authorization" ||
        lowered == "api_key" || lowered == "full_path" ||
        lowered == "local_path" || lowered == "card_number" ||
        lowered == "cvv" || lowered == "access_token" ||
        lowered == "accesstoken" || lowered == "refresh_token" ||
        lowered == "refreshtoken" || lowered == "auth_token" ||
        lowered == "authtoken" || lowered == "client_secret" ||
        lowered == "clientsecret" || lowered == "private_key" ||
        lowered == "privatekey" || lowered == "bearer" || lowered == "secret" ||
        lowered == "token" || lowered == "session" || lowered == "session_id" ||
        lowered == "sessionid" || HasForbiddenResultField(child, depth + 1)) {
      return true;
    }
  }
  return false;
}

bool HasString(const base::DictValue& value, std::string_view key) {
  const std::string* found = value.FindString(key);
  return found && !found->empty();
}

bool HasList(const base::DictValue& value, std::string_view key) {
  return value.FindList(key) != nullptr;
}

bool IsKnownUrlClassification(std::string_view value) {
  constexpr std::array<std::string_view, 9> kClassifications = {
      "live",         "redirect",  "auth_required", "rate_limited",
      "timeout",      "dns_error", "tls_error",     "permanent_http_error",
      "indeterminate"};
  return std::ranges::find(kClassifications, value) != kClassifications.end() ||
         value == "temporary_http_error" || value == "scope_blocked";
}

}  // namespace

AgentResultVerifier::AgentResultVerifier() = default;
AgentResultVerifier::~AgentResultVerifier() = default;

AgentVerificationDecision AgentResultVerifier::Verify(
    const AgentTask& task,
    const AgentToolCall& call,
    const AgentToolDescriptor& descriptor,
    const AgentToolResult& result) const {
  if (result.schema_version != kAgentSchemaVersion ||
      result.action_id != call.action_id || result.message.empty()) {
    return Reject("result identity or schema is invalid");
  }
  std::string serialized;
  base::DictValue envelope;
  envelope.Set("value", result.value.Clone());
  envelope.Set("evidence", result.evidence.Clone());
  if (!base::JSONWriter::Write(envelope, &serialized) ||
      serialized.size() > kMaxVerifiedResultBytes ||
      HasForbiddenResultField(base::Value(std::move(envelope)))) {
    return Reject("result is too large or contains a forbidden field");
  }
  if (!result.ok) {
    if (result.error == AgentErrorCode::kNone) {
      return Reject("failed result has no error code");
    }
    return Accept(/*postcondition_met=*/false,
                  "browser produced a structured failure");
  }
  if (result.error != AgentErrorCode::kNone ||
      descriptor.risk == AgentRiskLevel::kR3UserTakeover ||
      descriptor.risk == AgentRiskLevel::kBlocked) {
    return Reject("successful result conflicts with its risk or error state");
  }

  const base::DictValue& value = result.value;
  if (base::StartsWith(call.tool_name, "page.") ||
      base::StartsWith(call.tool_name, "auth.") ||
      call.tool_name == "form.fill") {
    const std::optional<int> tab_id = value.FindInt("tab_id");
    const std::string* url = value.FindString("url");
    if (!tab_id || !task.AllowsTab(*tab_id) || !url ||
        !task.scope().AllowsOrigin(GURL(*url)) ||
        value.FindBool("untrusted") != true ||
        !HasString(value, "frame_token") ||
        !HasString(value, "document_token") ||
        !HasString(value, "observation_fingerprint") ||
        !HasList(value, "nodes") || result.evidence.empty()) {
      return Reject("page result lacks a fresh scoped browser observation");
    }
    if (call.tool_name == "page.extract" && !value.FindDict("extraction")) {
      return Reject("page extraction lacks source-bound fields");
    }
    if (call.tool_name == "page.webmcp.list" &&
        !HasList(value, "webmcp_tools")) {
      return Reject("WebMCP discovery lacks a bounded tool list");
    }
    if (call.tool_name == "page.webmcp.invoke" &&
        !HasList(value, "webmcp_results")) {
      return Reject("WebMCP invocation lacks a fresh result list");
    }
    return Accept(true, "fresh browser observation verifies page action");
  }
  if (call.tool_name == "tab.list") {
    return HasList(value, "tabs") && HasString(value, "revision")
               ? Accept(true, "tab snapshot is present")
               : Reject("tab list lacks a revision");
  }
  if (call.tool_name == "tab.create") {
    const std::optional<int> tab_id = value.FindInt("tab_id");
    return tab_id && task.AllowsTab(*tab_id) && HasString(value, "revision")
               ? Accept(true, "created tab is task-owned")
               : Reject("created tab was not adopted by the task");
  }
  if (call.tool_name == "tab.activate") {
    const std::optional<int> tab_id = value.FindInt("tab_id");
    return tab_id && task.AllowsTab(*tab_id)
               ? Accept(true, "activated tab remains in task scope")
               : Reject("activated tab is outside task scope");
  }
  if (call.tool_name == "tab.close" || call.tool_name == "tab.group") {
    return HasString(value, "revision")
               ? Accept(true, "post-action tab revision is present")
               : Reject("tab mutation lacks a post-action revision");
  }
  if (call.tool_name == "window.list") {
    return HasList(value, "windows") && HasString(value, "revision")
               ? Accept(true, "window snapshot is present")
               : Reject("window list lacks a revision");
  }
  if (call.tool_name == "window.create") {
    const std::optional<int> tab_id = value.FindInt("tab_id");
    return tab_id && task.AllowsTab(*tab_id) &&
                   value.FindInt("window_id").has_value() &&
                   HasString(value, "revision")
               ? Accept(true, "created window tab is task-owned")
               : Reject("created window was not adopted by the task");
  }
  if (call.tool_name == "window.activate") {
    return value.FindInt("window_id").has_value() &&
                   value.FindBool("active") == true
               ? Accept(true, "window activation was acknowledged")
               : Reject("window activation lacks browser state");
  }
  if (call.tool_name == "window.close") {
    return value.FindInt("window_id").has_value() &&
                   value.FindBool("close_requested") == true
               ? Accept(true, "safe window close was requested")
               : Reject("window close lacks browser acknowledgement");
  }
  if (call.tool_name == "workspace.save") {
    return HasString(value, "workspace_id") &&
                   HasString(value, "workspace_revision") &&
                   value.FindInt("tab_count").value_or(0) > 0
               ? Accept(true, "workspace snapshot was persisted")
               : Reject("workspace save lacks identity or content");
  }
  if (call.tool_name == "workspace.restore") {
    const base::ListValue* tab_ids = value.FindList("tab_ids");
    if (!tab_ids || tab_ids->empty() ||
        !HasString(value, "workspace_revision") ||
        !HasString(value, "revision")) {
      return Reject("workspace restore lacks revision or tabs");
    }
    for (const base::Value& tab_id : *tab_ids) {
      if (!tab_id.is_int() || !task.AllowsTab(tab_id.GetInt())) {
        return Reject("workspace restored a tab outside task scope");
      }
    }
    return Accept(true, "workspace tabs are task-owned");
  }
  if (call.tool_name == "bookmark.list") {
    return HasList(value, "nodes") && HasString(value, "snapshot_hash")
               ? Accept(true, "bookmark snapshot is present")
               : Reject("bookmark list lacks a snapshot");
  }
  if (call.tool_name == "bookmark.plan") {
    return HasString(value, "plan_id") && HasString(value, "snapshot_hash") &&
                   HasList(value, "moves")
               ? Accept(true, "bookmark plan is bound to a snapshot")
               : Reject("bookmark plan lacks identity or snapshot");
  }
  if (call.tool_name == "bookmark.apply") {
    const std::optional<int> moved = value.FindInt("moved");
    return moved && HasString(value, "snapshot_hash") &&
                   (*moved == 0 || HasString(value, "undo_token"))
               ? Accept(true, "bookmark transaction has verification and undo")
               : Reject("bookmark transaction lacks verification or undo");
  }
  if (call.tool_name == "bookmark.undo") {
    return HasString(value, "snapshot_hash")
               ? Accept(true, "bookmark undo restored an exact snapshot")
               : Reject("bookmark undo lacks an exact snapshot");
  }
  if (call.tool_name == "bookmark.check_urls") {
    const base::ListValue* results = value.FindList("results");
    if (!results) {
      return Reject("URL check lacks results");
    }
    for (const base::Value& checked : *results) {
      const std::string* classification =
          checked.GetDict().FindString("classification");
      if (!classification || !IsKnownUrlClassification(*classification)) {
        return Reject("URL check contains an unknown classification");
      }
    }
    return Accept(true, "URL classifications are deterministic");
  }
  if (call.tool_name == "history.search") {
    return HasList(value, "results")
               ? Accept(true, "history results are bounded by task scope")
               : Reject("history search lacks results");
  }
  if (call.tool_name == "permissions.inspect") {
    const std::string* origin = value.FindString("origin");
    return origin && task.scope().AllowsOrigin(GURL(*origin)) &&
                   value.FindDict("permissions")
               ? Accept(true, "site permission snapshot is scoped")
               : Reject("permission snapshot lacks an approved origin");
  }
  if (call.tool_name == "monitor.create") {
    const std::string* origin = value.FindString("origin");
    return HasString(value, "monitor_id") && HasString(value, "target_hash") &&
                   origin && task.scope().AllowsOrigin(GURL(*origin)) &&
                   value.FindInt("interval_minutes").value_or(0) >= 15 &&
                   HasString(value, "revision") &&
                   !value.FindString("target_url")
               ? Accept(true, "encrypted page monitor was persisted")
               : Reject("monitor creation lacks bounded browser evidence");
  }
  if (call.tool_name == "monitor.list") {
    return HasList(value, "monitors") && HasString(value, "revision")
               ? Accept(true, "task-owned monitor snapshot is present")
               : Reject("monitor list lacks a revision");
  }
  if (call.tool_name == "monitor.pause") {
    return HasString(value, "monitor_id") &&
                   value.FindBool("paused").has_value() &&
                   HasString(value, "revision")
               ? Accept(true, "monitor pause state was persisted")
               : Reject("monitor pause result lacks current state");
  }
  if (call.tool_name == "monitor.delete") {
    return HasString(value, "monitor_id") &&
                   value.FindBool("deleted") == true &&
                   HasString(value, "revision")
               ? Accept(true, "task-owned monitor was deleted")
               : Reject("monitor deletion lacks browser acknowledgement");
  }
  if (call.tool_name == "download.find_official") {
    return HasString(value, "candidate_url") &&
                   value.FindBool("requires_user_review") == true &&
                   value.FindBool("publisher_identity_verified") == false
               ? Accept(true, "download source evidence does not overclaim")
               : Reject("download source evidence is incomplete");
  }
  if (call.tool_name == "download.start") {
    return HasString(value, "download_id") &&
                   value.FindBool("safety_checks_required") == true
               ? Accept(true, "native DownloadItem was created")
               : Reject("download start lacks native safety evidence");
  }
  if (call.tool_name == "download.pause" ||
      call.tool_name == "download.resume") {
    return HasString(value, "download_id") &&
                   value.FindBool("paused").has_value()
               ? Accept(true, "download pause state is present")
               : Reject("download control lacks current pause state");
  }
  if (call.tool_name == "download.list") {
    return HasList(value, "downloads")
               ? Accept(true, "task-owned download snapshot is present")
               : Reject("download list lacks native state");
  }
  if (call.tool_name == "download.cancel") {
    return HasString(value, "download_id") && value.FindString("state") &&
                   *value.FindString("state") == "cancelled"
               ? Accept(true, "native download is cancelled")
               : Reject("download cancellation lacks cancelled state");
  }
  if (call.tool_name == "download.verify") {
    if (!HasString(value, "download_id") || !HasString(value, "state") ||
        !value.FindBool("verified").has_value() ||
        !value.FindBool("safe_and_complete").has_value() ||
        !HasString(value, "integrity")) {
      return Reject("download verification lacks native state");
    }
    const bool verified = value.FindBool("verified").value_or(false);
    const std::string* integrity = value.FindString("integrity");
    if (verified && (*integrity != "match" || !HasString(value, "sha256"))) {
      return Reject("verified download lacks matching SHA-256 evidence");
    }
    return Accept(verified, "download state was read from DownloadItem");
  }
  if (call.tool_name == "download.open") {
    return HasString(value, "download_id") &&
                   value.FindBool("opened") == true &&
                   value.FindString("state") &&
                   *value.FindString("state") == "complete"
               ? Accept(true, "verified native download was opened")
               : Reject("download open lacks verified native state");
  }
  return Reject("tool has no deterministic result verifier");
}

}  // namespace aegis::agent
