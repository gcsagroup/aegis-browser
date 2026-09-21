// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_result_verifier.h"

#include <algorithm>
#include <array>
#include <string_view>
#include <utility>

#include "base/containers/flat_set.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/uuid.h"
#include "crypto/sha2.h"
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

AgentVerificationDecision VerifyExtraction(const AgentToolCall& call,
                                           const base::DictValue& value) {
  const base::DictValue* extraction = value.FindDict("extraction");
  const base::ListValue* fields =
      extraction ? extraction->FindList("fields") : nullptr;
  const base::ListValue* nodes = value.FindList("nodes");
  if (!fields || !nodes || extraction->FindBool("untrusted") != true) {
    return Reject("page extraction lacks source-bound fields");
  }
  const std::string* kind = call.arguments.FindString("kind");
  if (!extraction->FindString("kind") ||
      *extraction->FindString("kind") != (kind ? *kind : "article") ||
      (call.document &&
       (value.FindString("document_token") == nullptr ||
        *value.FindString("document_token") != call.document->document_token ||
        value.FindString("frame_token") == nullptr ||
        *value.FindString("frame_token") != call.document->frame_token))) {
    return Reject("extraction is not bound to the requested document or kind");
  }
  base::flat_set<std::string> requested;
  if (const auto* input = call.arguments.FindList("fields")) {
    for (const auto& field : *input) {
      if (!field.is_string() || field.GetString().empty() ||
          !requested.insert(field.GetString()).second) {
        return Reject("requested extraction fields are invalid");
      }
    }
  }
  if (requested.empty()) {
    requested = {"title", "summary"};
  }
  if (fields->size() != requested.size()) {
    return Reject("extraction does not cover all requested fields");
  }
  base::flat_set<int> source_nodes;
  for (const auto& node : *nodes) {
    if (!node.is_dict()) {
      return Reject("extraction source node is invalid");
    }
    if (auto id = node.GetDict().FindInt("node_id")) {
      source_nodes.insert(*id);
    }
  }
  bool all_resolved = true;
  for (const auto& item : *fields) {
    if (!item.is_dict()) {
      return Reject("extraction field is invalid");
    }
    const auto& field = item.GetDict();
    const std::string* name = field.FindString("field");
    if (!name || requested.erase(*name) != 1u ||
        !field.FindBool("resolved").has_value()) {
      return Reject("extraction field does not match the request");
    }
    if (field.FindBool("resolved") != true) {
      all_resolved = false;
      continue;
    }
    const std::string* text = field.FindString("value");
    const std::string* hash = field.FindString("source_hash");
    const auto* ids = field.FindList("source_node_ids");
    if (!text || base::ContainsOnlyChars(*text, " \t\r\n") || !hash || !ids ||
        !base::EqualsCaseInsensitiveASCII(
            *hash,
            base::HexEncode(crypto::SHA256HashString(*name + "\n" + *text)))) {
      return Reject("resolved extraction field lacks content or integrity");
    }
    if (base::EqualsCaseInsensitiveASCII(*name, "title")) {
      if (!value.FindString("title") || *text != *value.FindString("title")) {
        return Reject("extracted title does not match the observed document");
      }
    } else if (ids->empty()) {
      return Reject("extracted content lacks source nodes");
    }
    for (const auto& id : *ids) {
      if (!id.is_int() || !source_nodes.contains(id.GetInt())) {
        return Reject("extracted content references an unobserved node");
      }
    }
  }
  return Accept(all_resolved,
                all_resolved ? "requested fields have browser evidence"
                             : "部分提取字段没有对应原文；请检查resolved标记。"
                               "总结任务可读取title及content或summary，"
                               "不得将自造的事实键名当作页面字段。");
}

bool IsKnownUrlClassification(std::string_view value) {
  constexpr std::array<std::string_view, 9> kClassifications = {
      "live",         "redirect",  "auth_required", "rate_limited",
      "timeout",      "dns_error", "tls_error",     "permanent_http_error",
      "indeterminate"};
  return std::ranges::find(kClassifications, value) != kClassifications.end() ||
         value == "temporary_http_error" || value == "scope_blocked" ||
         value == "not_checked";
}

}  // namespace

AgentResultVerifier::AgentResultVerifier() = default;
AgentResultVerifier::~AgentResultVerifier() = default;

AgentToolCall AgentResultVerifier::RetainVerificationContext(
    const AgentToolCall& call) {
  AgentToolCall context;
  context.action_id = call.action_id;
  context.tool_name = call.tool_name;
  if (call.tool_name == "page.extract") {
    context.document = call.document;
    for (const auto* name : {"kind", "fields"}) {
      if (const base::Value* value = call.arguments.Find(name)) {
        context.arguments.Set(name, value->Clone());
      }
    }
  } else if (call.tool_name == "tab.group") {
    if (const auto* ids = call.arguments.FindList("tab_ids")) {
      context.arguments.Set("tab_ids", ids->Clone());
    }
  } else if (call.tool_name == "download.find_official") {
    context.document = call.document;
    context.committed_url = call.committed_url;
    if (const auto* candidate = call.arguments.FindString("candidate_url")) {
      context.arguments.Set("candidate_url", *candidate);
    }
  }
  return context;
}

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
    if (value.FindBool("is_error_document") == true ||
        value.FindInt("http_status").value_or(0) >= 400) {
      return Reject("error page cannot verify the requested page result");
    }
    if (call.tool_name == "page.click") {
      const auto* before = value.FindString("pre_action_fingerprint");
      const auto* after = value.FindString("observation_fingerprint");
      if (!before || before->empty() || !after || after->empty()) {
        return Reject("点击结果缺少操作前后的浏览器观察");
      }
      // 页面变化只证明观察发生变化；业务目标仍需后续字段或结果核验。
      return Accept(
          *before != *after,
          *before != *after
              ? "点击后的页面观察发生变化，仍需核对任务目标"
              : "点击后未观察到变化，无法确认生效；请回读结果，不要重复点击");
    }
    if (call.tool_name == "page.extract") {
      return VerifyExtraction(call, value);
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
    if (task.scope().tab_metadata_window_id > 0 ||
        value.contains("tab_count")) {
      const base::ListValue* tabs = value.FindList("tabs");
      const std::optional<int> count = value.FindInt("tab_count");
      const std::optional<bool> truncated = value.FindBool("list_truncated");
      const std::string* count_scope = value.FindString("count_scope");
      if (!tabs || !count || *count < 0 || !truncated || !count_scope ||
          *count_scope != (task.scope().tab_metadata_window_id > 0
                               ? "current_window"
                               : "task_tabs") ||
          static_cast<size_t>(*count) < tabs->size() ||
          *truncated != (static_cast<size_t>(*count) > tabs->size())) {
        return Reject("tab list coverage is inconsistent");
      }
    }
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
  if (call.tool_name == "tab.group") {
    const auto* requested = call.arguments.FindList("tab_ids");
    const auto* grouped = value.FindList("tab_ids");
    if (!requested || requested->empty() || !grouped ||
        requested->size() != grouped->size() || !HasString(value, "group_id") ||
        !HasString(value, "revision")) {
      return Reject("标签分组缺少完整回读");
    }
    base::flat_set<int> seen;
    for (const auto& id : *grouped) {
      if (!id.is_int() || !task.AllowsTab(id.GetInt()) ||
          !seen.insert(id.GetInt()).second ||
          !std::ranges::contains(*requested, id)) {
        return Reject("标签分组回读与请求不一致");
      }
    }
    return Accept(true, "标签组与请求的标签集合一致");
  }
  if (call.tool_name == "tab.close") {
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
    base::DictValue counts;
    base::flat_set<std::string> unique_ids;
    for (const base::Value& checked : *results) {
      const base::DictValue* entry = checked.GetIfDict();
      const std::string* classification =
          entry ? entry->FindString("classification") : nullptr;
      const std::string* node_id =
          entry ? entry->FindString("node_id") : nullptr;
      if (!classification || !IsKnownUrlClassification(*classification) ||
          !node_id || !unique_ids.insert(*node_id).second) {
        return Reject("URL check contains an unknown classification");
      }
      counts.Set(*classification,
                 counts.FindInt(*classification).value_or(0) + 1);
    }
    if (const std::string* reference =
            call.arguments.FindString("selection_ref")) {
      const std::string* returned = value.FindString("selection_ref");
      if (!returned || *returned != *reference) {
        return Reject("URL check selection does not match its task capability");
      }
    }
    if (value.contains("selected_count") ||
        call.arguments.contains("selection_ref")) {
      const auto selected = value.FindInt("selected_count");
      const auto attempted = value.FindInt("attempted_count");
      const auto* returned_counts = value.FindDict("classification_counts");
      if (!selected || *selected < 0 ||
          static_cast<size_t>(*selected) != results->size() || !attempted ||
          *attempted < 0 || *attempted > *selected ||
          !value.FindBool("list_truncated").has_value() || !returned_counts ||
          *returned_counts != counts) {
        return Reject("URL check coverage does not match its results");
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
    const std::optional<bool> session_only = value.FindBool("session_only");
    if (!HasString(value, "monitor_id") ||
        !HasString(value, "target_hash") || !origin ||
        !task.scope().AllowsOrigin(GURL(*origin)) ||
        value.FindInt("interval_minutes").value_or(0) < 15 ||
        !HasString(value, "revision") || !session_only.has_value() ||
        value.FindString("target_url")) {
      return Reject("monitor creation lacks bounded browser evidence");
    }
    return *session_only
               ? Accept(true, "session-only page monitor is browser-bound")
               : Accept(true, "encrypted page monitor was persisted");
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
    const auto* source = value.FindString("source_url");
    const auto* candidate = value.FindString("candidate_url");
    const auto* requested = call.arguments.FindString("candidate_url");
    GURL::Replacements redact;
    redact.ClearUsername();
    redact.ClearPassword();
    redact.ClearQuery();
    redact.ClearRef();
    if (!call.document || !task.AllowsTab(call.document->tab_id) ||
        call.document->committed_url != call.committed_url ||
        !task.scope().AllowsOrigin(call.committed_url) || !source ||
        *source != call.committed_url.ReplaceComponents(redact).spec() ||
        !candidate || !requested ||
        *candidate != GURL(*requested).ReplaceComponents(redact).spec()) {
      return Reject("下载来源回读没有绑定实际页面及候选链接");
    }
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
    const std::string* hash = value.FindString("sha256");
    if (verified && (*integrity != "match" || !hash || hash->size() != 64u ||
                     !std::ranges::all_of(
                         *hash, [](char c) { return base::IsHexDigit(c); }) ||
                     *value.FindString("state") != "complete" ||
                     value.FindBool("safe_and_complete") != true ||
                     value.FindBool("dangerous") == true ||
                     value.FindBool("wait_timed_out") == true)) {
      return Reject(
          "verified download conflicts with native completion or integrity");
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
