// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/aegis_actor_bridge.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <memory>
#include <string_view>
#include <utility>
#include <vector>

#include "base/check_deref.h"
#include "base/containers/flat_set.h"
#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/unguessable_token.h"
#include "chrome/browser/actor/actor_keyed_service.h"
#include "chrome/browser/actor/actor_proto_conversion.h"
#include "chrome/browser/actor/actor_task.h"
#include "chrome/browser/actor/actor_task_metadata.h"
#include "chrome/browser/actor/enterprise_policy_checker.h"
#include "chrome/browser/actor/tools/attempt_form_filling_tool_request.h"
#include "chrome/browser/actor/tools/attempt_login_tool_request.h"
#include "chrome/browser/actor/tools/attempt_otp_filling_tool_request.h"
#include "chrome/browser/actor/tools/click_tool_request.h"
#include "chrome/browser/actor/tools/drag_and_release_tool_request.h"
#include "chrome/browser/actor/tools/history_tool_request.h"
#include "chrome/browser/actor/tools/media_control_tool_request.h"
#include "chrome/browser/actor/tools/navigate_tool_request.h"
#include "chrome/browser/actor/tools/script_tool_request.h"
#include "chrome/browser/actor/tools/scroll_tool_request.h"
#include "chrome/browser/actor/tools/select_tool_request.h"
#include "chrome/browser/actor/tools/tool_request.h"
#include "chrome/browser/actor/tools/type_tool_request.h"
#include "chrome/browser/actor/tools/wait_tool_request.h"
#include "chrome/browser/aegis/agent/agent_execution.h"
#include "chrome/browser/aegis/agent/agent_model_protocol.h"
#include "chrome/browser/aegis/agent/agent_observation.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/actor.mojom.h"
#include "chrome/common/actor/action_result.h"
#include "chrome/common/actor/actor_constants.h"
#include "chrome/common/aegis/features.h"
#include "components/actor/core/task_source_info.h"
#include "components/optimization_guide/proto/features/common_quality_data.pb.h"
#include "components/tabs/public/tab_handle_factory.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "crypto/sha2.h"
#include "url/gurl.h"
#include "url/url_constants.h"

namespace aegis::agent {

namespace {

constexpr size_t kMaxNodeTextBytes = 2048;
constexpr size_t kMaxWebMcpSchemaBytes = 32 * 1024;
constexpr size_t kMaxWebMcpResultBytes = 8 * 1024;

bool IsSafeToolName(std::string_view name) {
  return !name.empty() && name.size() <= 128u &&
         std::ranges::all_of(name, [](unsigned char character) {
           return base::IsAsciiAlphaNumeric(character) || character == '.' ||
                  character == '_' || character == '-';
         });
}

bool IsForbiddenFieldName(std::string_view name) {
  const std::string lowered = base::ToLowerASCII(name);
  return lowered == "password" || lowered == "passwd" || lowered == "otp" ||
         lowered == "cookie" || lowered == "card_number" || lowered == "cvv" ||
         lowered == "api_key" || lowered == "authorization" ||
         lowered == "access_token" || lowered == "accesstoken" ||
         lowered == "refresh_token" || lowered == "refreshtoken" ||
         lowered == "auth_token" || lowered == "authtoken" ||
         lowered == "client_secret" || lowered == "clientsecret" ||
         lowered == "private_key" || lowered == "privatekey" ||
         lowered == "bearer" || lowered == "secret" || lowered == "token" ||
         lowered == "session" || lowered == "session_id" ||
         lowered == "sessionid";
}

bool HasForbiddenWebMcpField(const base::Value& value) {
  if (value.is_list()) {
    return std::ranges::any_of(value.GetList(), HasForbiddenWebMcpField);
  }
  if (!value.is_dict()) {
    return false;
  }
  return std::ranges::any_of(value.GetDict(), [](const auto& entry) {
    return IsForbiddenFieldName(entry.first) ||
           HasForbiddenWebMcpField(entry.second);
  });
}

bool IsAllowedSchemaKeyword(std::string_view key) {
  return key == "type" || key == "properties" || key == "required" ||
         key == "additionalProperties" || key == "items" || key == "enum" ||
         key == "minLength" || key == "maxLength" || key == "minimum" ||
         key == "maximum" || key == "minItems" || key == "maxItems";
}

bool IsSafeWebMcpSchemaNode(const base::DictValue& schema, int depth) {
  if (depth > 8 || schema.size() > 16u ||
      std::ranges::any_of(schema, [](const auto& entry) {
        return !IsAllowedSchemaKeyword(entry.first);
      })) {
    return false;
  }
  const std::string* type = schema.FindString("type");
  if (!type || (*type != "object" && *type != "array" && *type != "string" &&
                *type != "boolean" && *type != "integer" && *type != "number" &&
                *type != "null")) {
    return false;
  }
  if (const base::ListValue* choices = schema.FindList("enum");
      choices && choices->size() > 64u) {
    return false;
  }
  if (*type == "array") {
    const base::DictValue* items = schema.FindDict("items");
    const std::optional<int> min_items = schema.FindInt("minItems");
    const std::optional<int> max_items = schema.FindInt("maxItems");
    return items && max_items && *max_items > 0 && *max_items <= 64 &&
           (!min_items || (*min_items >= 0 && *min_items <= *max_items)) &&
           !schema.contains("properties") && !schema.contains("required") &&
           !schema.contains("additionalProperties") &&
           IsSafeWebMcpSchemaNode(*items, depth + 1);
  }
  if (*type != "object") {
    return !schema.contains("properties") && !schema.contains("required") &&
           !schema.contains("additionalProperties") &&
           !schema.contains("items") && !schema.contains("minItems") &&
           !schema.contains("maxItems");
  }

  const base::DictValue* properties = schema.FindDict("properties");
  const base::ListValue* required = schema.FindList("required");
  if (!properties || properties->size() > 32u ||
      schema.FindBool("additionalProperties").value_or(true) ||
      schema.contains("items") || schema.contains("minItems") ||
      schema.contains("maxItems")) {
    return false;
  }
  for (const auto [key, child] : *properties) {
    if (!IsSafeToolName(key) || IsForbiddenFieldName(key) || !child.is_dict() ||
        !IsSafeWebMcpSchemaNode(child.GetDict(), depth + 1)) {
      return false;
    }
  }
  if (required) {
    if (required->size() > properties->size()) {
      return false;
    }
    for (const base::Value& name : *required) {
      if (!name.is_string() || !properties->contains(name.GetString())) {
        return false;
      }
    }
  }
  return true;
}

std::optional<base::DictValue> ParseSafeWebMcpSchema(
    std::string_view schema_json) {
  if (schema_json.empty() || schema_json.size() > kMaxWebMcpSchemaBytes) {
    return std::nullopt;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(schema_json, base::JSON_PARSE_RFC);
  const std::string* root_type = parsed && parsed->is_dict()
                                     ? parsed->GetDict().FindString("type")
                                     : nullptr;
  if (!parsed || !parsed->is_dict() || !root_type || *root_type != "object" ||
      !IsSafeWebMcpSchemaNode(parsed->GetDict(), 0)) {
    return std::nullopt;
  }
  return std::make_optional(std::move(*parsed).TakeDict());
}

std::string WebMcpRevision(std::string_view document_token,
                           const optimization_guide::proto::ScriptTool& tool) {
  return base::HexEncode(crypto::SHA256HashString(
      std::string(document_token) + "\n" + tool.name() + "\n" +
      tool.description() + "\n" + tool.input_schema() + "\n" +
      (tool.has_annotations() && tool.annotations().read_only() ? "1" : "0")));
}

std::optional<std::string> SafeWebMcpResult(std::string_view value) {
  if (value.size() > kMaxWebMcpResultBytes || !base::IsStringUTF8(value)) {
    return std::nullopt;
  }
  const std::string lowered = base::ToLowerASCII(value);
  constexpr std::array<std::string_view, 19> kSecretMarkers = {
      "password",     "passwd",      "authorization",
      "bearer ",      "cookie",      "api_key",
      "access_token", "accesstoken", "refresh_token",
      "refreshtoken", "auth_token",  "client_secret",
      "private_key",  "card_number", "session_id",
      "sessionid",    "token",       "secret",
      "cvv"};
  if (std::ranges::any_of(kSecretMarkers, [&lowered](std::string_view marker) {
        return lowered.find(marker) != std::string::npos;
      })) {
    return std::nullopt;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(value, base::JSON_PARSE_RFC);
  if (parsed && HasForbiddenWebMcpField(*parsed)) {
    return std::nullopt;
  }
  return std::string(value);
}

AgentToolResult ErrorResult(std::string action_id,
                            AgentErrorCode error,
                            std::string message) {
  return {.action_id = std::move(action_id),
          .ok = false,
          .error = error,
          .message = std::move(message)};
}

void FinishPageExtraction(std::string kind,
                          std::vector<std::string> requested_fields,
                          AegisActorBridge::ToolResultCallback callback,
                          AgentToolResult result) {
  if (!result.ok) {
    std::move(callback).Run(std::move(result));
    return;
  }
  const base::ListValue* nodes = result.value.FindList("nodes");
  if (!nodes) {
    std::move(callback).Run(ErrorResult(
        std::move(result.action_id), AgentErrorCode::kVerificationFailed,
        "fresh observation has no extractable nodes"));
    return;
  }

  if (requested_fields.empty()) {
    requested_fields = {"title", "summary"};
  }
  // 字段名命中标题只表示找到了章节，不能把标题本身冒充章节内容。
  // 这里只组合已获授权、已脱敏的主文档文本，不额外读取 DOM 或表单值。
  struct Section {
    std::string heading;
    std::string body;
    std::vector<int> source_ids;
  };
  std::vector<Section> sections;
  Section document_body;
  const auto append_text = [](const base::DictValue& node, Section* section) {
    const std::string* text = node.FindString("text");
    if (!text || text->empty()) {
      return;
    }
    if (!section->body.empty()) {
      section->body.push_back('\n');
    }
    section->body.append(*text);
    if (const std::optional<int> id = node.FindInt("node_id");
        id && std::ranges::find(section->source_ids, *id) ==
                  section->source_ids.end()) {
      section->source_ids.push_back(*id);
    }
  };
  for (const base::Value& node : *nodes) {
    const base::DictValue& item = node.GetDict();
    if (item.FindInt("kind") ==
        optimization_guide::proto::CONTENT_ATTRIBUTE_HEADING) {
      sections.emplace_back();
    }
    if (item.FindInt("kind") !=
        optimization_guide::proto::CONTENT_ATTRIBUTE_TEXT) {
      continue;
    }
    if (item.FindInt("text_block_kind") ==
        optimization_guide::proto::CONTENT_ATTRIBUTE_HEADING) {
      if (sections.empty() || !sections.back().body.empty()) {
        sections.emplace_back();
      }
      if (const std::string* text = item.FindString("text")) {
        sections.back().heading.append(*text);
      }
    } else {
      append_text(item, &document_body);
      if (!sections.empty()) {
        append_text(item, &sections.back());
      }
    }
  }
  base::ListValue fields;
  for (const std::string& requested : requested_fields) {
    const std::string lowered = base::ToLowerASCII(requested);
    Section selected;
    if (lowered == "title") {
      if (const std::string* title = result.value.FindString("title")) {
        selected.body = *title;
      }
    } else if (lowered == "summary" || lowered == "content") {
      selected = document_body;
    } else {
      for (const Section& section : sections) {
        if (!lowered.empty() &&
            base::ToLowerASCII(section.heading).contains(lowered)) {
          selected = section;
          break;
        }
      }
      if (selected.heading.empty()) {
        for (const base::Value& node : *nodes) {
          const base::DictValue& candidate = node.GetDict();
          if (candidate.FindInt("kind") !=
                  optimization_guide::proto::CONTENT_ATTRIBUTE_TEXT ||
              candidate.FindInt("text_block_kind") ==
                  optimization_guide::proto::CONTENT_ATTRIBUTE_HEADING) {
            continue;
          }
          const std::string* text = candidate.FindString("text");
          // 单独的字段标签不是字段值；保留未知字段的未解析状态。
          if (text && !lowered.empty() &&
              base::ToLowerASCII(*text) != lowered &&
              base::ToLowerASCII(*text).contains(lowered)) {
            append_text(candidate, &selected);
            break;
          }
        }
      }
    }

    base::DictValue extracted;
    extracted.Set("field", requested);
    const std::string value(
        base::TruncateUTF8ToByteSize(selected.body, kMaxNodeTextBytes));
    if (!value.empty()) {
      extracted.Set("value", value);
      extracted.Set("truncated", value.size() < selected.body.size());
      base::ListValue source_ids;
      for (int id : selected.source_ids) {
        source_ids.Append(id);
      }
      extracted.Set("source_node_ids", std::move(source_ids));
      extracted.Set(
          "source_hash",
          base::HexEncode(crypto::SHA256HashString(requested + "\n" + value)));
      extracted.Set("resolved", true);
    } else {
      extracted.Set("resolved", false);
    }
    fields.Append(std::move(extracted));
  }
  base::DictValue extraction;
  extraction.Set("kind", std::move(kind));
  extraction.Set("fields", std::move(fields));
  extraction.Set("method", "bounded_semantic_nodes");
  extraction.Set("untrusted", true);
  // 指定字段提取只携带实际引用节点，不把无关章节再附给模型。
  base::flat_set<int> referenced_nodes;
  for (const auto& field : *extraction.FindList("fields")) {
    if (const auto* ids = field.GetDict().FindList("source_node_ids")) {
      for (const auto& id : *ids)
        referenced_nodes.insert(id.GetInt());
    }
  }
  base::ListValue selected_nodes;
  for (const auto& node : *nodes) {
    const auto id = node.GetDict().FindInt("node_id");
    if (id && referenced_nodes.contains(*id))
      selected_nodes.Append(node.Clone());
  }
  result.value.Set("nodes", std::move(selected_nodes));
  result.value.Set("extraction", std::move(extraction));
  result.message = "bounded page fields extracted with source nodes";
  std::move(callback).Run(std::move(result));
}

std::string CurrentFrameToken(tabs::TabInterface& tab) {
  content::WebContents* contents = tab.GetContents();
  if (!contents || !contents->GetPrimaryMainFrame()) {
    return {};
  }
  return contents->GetPrimaryMainFrame()
      ->GetGlobalFrameToken()
      .frame_token.ToString();
}

bool SameDocument(const AgentDocumentRef& left, const AgentDocumentRef& right) {
  return left.tab_id == right.tab_id && left.frame_token == right.frame_token &&
         left.document_token == right.document_token &&
         left.committed_url == right.committed_url;
}

bool IsErrorPage(content::WebContents* contents) {
  if (!contents || !contents->GetPrimaryMainFrame() ||
      contents->GetPrimaryMainFrame()->IsErrorDocument()) {
    return true;
  }
  const auto* entry = contents->GetController().GetLastCommittedEntry();
  // 0也可能来自会话恢复；保留未知状态，不把它伪造成200或一律判失败。
  return entry && entry->GetHttpStatusCode() >= 400;
}

std::string BoundedText(std::string_view value, size_t remaining) {
  return BoundedAgentObservationText(value, remaining);
}

std::string SafeObservationUrl(std::string_view value) {
  const GURL url(value);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return {};
  }
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  replacements.ClearQuery();
  replacements.ClearRef();
  return url.ReplaceComponents(replacements).spec();
}

std::unique_ptr<actor::ToolRequest> BuildActorRequest(
    tabs::TabInterface& tab,
    const AgentToolCall& call) {
  const tabs::TabHandle tab_handle = tab.GetHandle();
  if (call.tool_name == "page.navigate") {
    const std::string* url = call.arguments.FindString("url");
    return url ? std::make_unique<actor::NavigateToolRequest>(tab_handle,
                                                              GURL(*url))
               : nullptr;
  }
  if (!call.document) {
    return nullptr;
  }

  const std::string& document_token = call.document->document_token;
  if (call.tool_name == "page.click") {
    std::optional<int> node_id = call.arguments.FindInt("node_id");
    if (!node_id) {
      return nullptr;
    }
    actor::mojom::ClickType click_type = actor::mojom::ClickType::kLeft;
    const std::string* button = call.arguments.FindString("button");
    if (button && *button == "right") {
      click_type = actor::mojom::ClickType::kRight;
    }
    return std::make_unique<actor::ClickToolRequest>(
        tab_handle, actor::PageTarget(actor::DomNode{*node_id, document_token}),
        click_type, actor::mojom::ClickCount::kSingle);
  }
  if (call.tool_name == "page.type") {
    std::optional<int> node_id = call.arguments.FindInt("node_id");
    const std::string* text = call.arguments.FindString("text");
    if (!node_id || !text) {
      return nullptr;
    }
    const bool replace = call.arguments.FindBool("replace").value_or(true);
    return std::make_unique<actor::TypeToolRequest>(
        tab_handle, actor::PageTarget(actor::DomNode{*node_id, document_token}),
        *text, false,
        replace ? actor::TypeToolRequest::Mode::kReplace
                : actor::TypeToolRequest::Mode::kAppend);
  }
  if (call.tool_name == "page.select") {
    std::optional<int> node_id = call.arguments.FindInt("node_id");
    const std::string* value = call.arguments.FindString("value");
    if (!node_id || !value) {
      return nullptr;
    }
    return std::make_unique<actor::SelectToolRequest>(
        tab_handle, actor::PageTarget(actor::DomNode{*node_id, document_token}),
        *value);
  }
  if (call.tool_name == "page.scroll") {
    const std::string* direction = call.arguments.FindString("direction");
    std::optional<int> amount = call.arguments.FindInt("amount");
    if (!direction || !amount) {
      return nullptr;
    }
    actor::ScrollToolRequest::Direction actor_direction =
        actor::ScrollToolRequest::Direction::kDown;
    if (*direction == "up") {
      actor_direction = actor::ScrollToolRequest::Direction::kUp;
    } else if (*direction == "left") {
      actor_direction = actor::ScrollToolRequest::Direction::kLeft;
    } else if (*direction == "right") {
      actor_direction = actor::ScrollToolRequest::Direction::kRight;
    }
    return std::make_unique<actor::ScrollToolRequest>(
        tab_handle,
        actor::PageTarget(
            actor::DomNode{actor::kRootElementDomNodeId, document_token}),
        actor_direction, static_cast<float>(*amount));
  }
  if (call.tool_name == "page.drag") {
    std::optional<int> from_node_id = call.arguments.FindInt("from_node_id");
    std::optional<int> to_node_id = call.arguments.FindInt("to_node_id");
    if (!from_node_id || !to_node_id) {
      return nullptr;
    }
    return std::make_unique<actor::DragAndReleaseToolRequest>(
        tab_handle,
        actor::PageTarget(actor::DomNode{*from_node_id, document_token}),
        actor::PageTarget(actor::DomNode{*to_node_id, document_token}));
  }
  if (call.tool_name == "page.wait") {
    std::optional<int> timeout_ms = call.arguments.FindInt("timeout_ms");
    if (!timeout_ms) {
      return nullptr;
    }
    return std::make_unique<actor::WaitToolRequest>(
        base::Milliseconds(*timeout_ms), tab_handle);
  }
  if (call.tool_name == "page.history") {
    const std::string* direction = call.arguments.FindString("direction");
    if (!direction) {
      return nullptr;
    }
    return std::make_unique<actor::HistoryToolRequest>(
        tab_handle, *direction == "back"
                        ? actor::HistoryToolRequest::Direction::kBack
                        : actor::HistoryToolRequest::Direction::kForward);
  }
  if (call.tool_name == "page.media") {
    const std::string* action = call.arguments.FindString("action");
    if (!action) {
      return nullptr;
    }
    if (*action == "play") {
      return std::make_unique<actor::MediaControlToolRequest>(
          tab_handle, actor::PlayMedia{});
    }
    if (*action == "pause") {
      return std::make_unique<actor::MediaControlToolRequest>(
          tab_handle, actor::PauseMedia{});
    }
    std::optional<int> position_ms = call.arguments.FindInt("position_ms");
    return position_ms ? std::make_unique<actor::MediaControlToolRequest>(
                             tab_handle, actor::SeekMedia{*position_ms})
                       : nullptr;
  }
  if (call.tool_name == "page.webmcp.invoke") {
    const std::string* name = call.arguments.FindString("name");
    const std::string* input_json = call.arguments.FindString("input_json");
    std::optional<base::UnguessableToken> token =
        base::UnguessableToken::DeserializeFromString(document_token);
    return name && input_json && token
               ? std::make_unique<actor::ScriptToolRequest>(tab_handle, *token,
                                                            *name, *input_json)
               : nullptr;
  }
  if (call.tool_name == "auth.attempt_login") {
    std::optional<actor::PageTarget> password_button;
    if (std::optional<int> node_id =
            call.arguments.FindInt("password_button_node_id")) {
      password_button =
          actor::PageTarget(actor::DomNode{*node_id, document_token});
    }
    return std::make_unique<actor::AttemptLoginToolRequest>(
        tab_handle, std::move(password_button), std::nullopt);
  }
  if (call.tool_name == "auth.fill_otp") {
    const base::ListValue* node_ids = call.arguments.FindList("field_node_ids");
    if (!node_ids || node_ids->empty() || node_ids->size() > 8u) {
      return nullptr;
    }
    std::vector<actor::PageTarget> targets;
    for (const base::Value& node_id : *node_ids) {
      targets.emplace_back(actor::DomNode{node_id.GetInt(), document_token});
    }
    return std::make_unique<actor::AttemptOtpFillingToolRequest>(
        tab_handle, std::move(targets),
        call.arguments.FindBool("for_signin").value_or(false));
  }
  if (call.tool_name == "form.fill") {
    const base::ListValue* node_ids = call.arguments.FindList("field_node_ids");
    const std::string* requested_data =
        call.arguments.FindString("requested_data");
    if (!node_ids || node_ids->empty() || node_ids->size() > 32u ||
        !requested_data) {
      return nullptr;
    }
    using RequestedData = actor::AttemptFormFillingToolRequest::RequestedData;
    RequestedData data = RequestedData::kAddress;
    if (*requested_data == "billing_address") {
      data = RequestedData::kBillingAddress;
    } else if (*requested_data == "shipping_address") {
      data = RequestedData::kShippingAddress;
    } else if (*requested_data == "work_address") {
      data = RequestedData::kWorkAddress;
    } else if (*requested_data == "home_address") {
      data = RequestedData::kHomeAddress;
    } else if (*requested_data == "contact_information") {
      data = RequestedData::kContactInformation;
    }
    actor::AttemptFormFillingToolRequest::FormFillingRequest request;
    request.requested_data = data;
    if (const std::string* section_label =
            call.arguments.FindString("section_label")) {
      request.section_label = *section_label;
    }
    for (const base::Value& node_id : *node_ids) {
      request.trigger_fields.emplace_back(
          actor::DomNode{node_id.GetInt(), document_token});
    }
    std::vector<actor::AttemptFormFillingToolRequest::FormFillingRequest>
        requests;
    requests.push_back(std::move(request));
    return std::make_unique<actor::AttemptFormFillingToolRequest>(
        tab_handle, std::move(requests));
  }
  return nullptr;
}

class AegisActorPolicyChecker final : public actor::EnterprisePolicyChecker {
 public:
  AegisActorPolicyChecker(AgentTaskScope scope, std::vector<GURL> selected_urls)
      : scope_(std::move(scope)), selected_urls_(std::move(selected_urls)) {}
  ~AegisActorPolicyChecker() override = default;

  UrlBlockReason Evaluate(const GURL& url) const override {
    return ((!scope_.restrict_to_current_page &&
             !scope_.selected_pages_research)
                ? scope_.AllowsPageDestination(url, std::nullopt)
                : std::ranges::any_of(selected_urls_,
                                      [&](const GURL& selected) {
                                        return scope_.AllowsPageDestination(
                                            url, selected);
                                      }))
               ? UrlBlockReason::kNotBlocked
               : UrlBlockReason::kExplicitlyBlocked;
  }

  void ValidateContentSentToRenderer(
      content::RenderFrameHost* frame,
      const std::string& content,
      ContentValidationCallback callback) const override {
    // Actor content injection is bounded independently of the model context.
    // Secrets still use Chromium's protected login/form/OTP paths and are not
    // accepted through this generic content channel.
    constexpr size_t kMaxInjectedContentBytes = 64 * 1024;
    std::move(callback).Run(content.size() <= kMaxInjectedContentBytes
                                ? ContentValidationReason::kAllowed
                                : ContentValidationReason::kBlocked);
  }

 private:
  const AgentTaskScope scope_;
  const std::vector<GURL> selected_urls_;
};

}  // namespace

AegisActorBridge::AegisActorBridge(Profile* profile)
    : profile_(profile),
      actor_service_(actor::ActorKeyedService::Get(&CHECK_DEREF(profile))) {
  if (actor_service_) {
    actor_state_subscription_ = actor_service_->AddTaskStateChangedCallback(
        base::BindRepeating(&AegisActorBridge::OnActorTaskStateChanged,
                            weak_ptr_factory_.GetWeakPtr()));
  }
}

AegisActorBridge::~AegisActorBridge() {
  if (!actor_service_) {
    return;
  }
  actor_state_subscription_ = {};
  for (const auto& [agent_task_id, actor_task_id] : actor_tasks_) {
    if (actor_service_->GetTask(actor_task_id)) {
      actor_service_->StopTask(actor_task_id,
                               actor::ActorTask::StoppedReason::kShutdown);
    }
  }
}

bool AegisActorBridge::IsAvailable() const {
  return actor_service_ != nullptr;
}

void AegisActorBridge::SetStateEventCallback(StateEventCallback callback) {
  state_event_callback_ = std::move(callback);
}

std::optional<actor::TaskId> AegisActorBridge::StartTask(
    const std::string& agent_task_id,
    const AgentTaskScope& scope) {
  if (!actor_service_ || agent_task_id.empty() || !scope.IsValid() ||
      actor_tasks_.contains(agent_task_id)) {
    return std::nullopt;
  }
  std::vector<GURL> selected_urls;
  if (scope.restrict_to_current_page || scope.selected_pages_research) {
    for (int32_t tab_id : scope.allowed_tab_ids) {
      tabs::TabInterface* selected = tabs::TabHandle(tab_id).Get();
      if (!selected || selected->GetProfile() != profile_ ||
          !scope.AllowsOrigin(selected->GetURL())) {
        return std::nullopt;
      }
      // 完整地址冻结，后续服务器重定向也不能扩展该集合。
      selected_urls.push_back(selected->GetURL());
    }
  }
  actor::TaskId actor_task_id =
      actor_service_->CreateTaskWithOwnedPolicyChecker(
          actor::TaskSourceInfo(actor::TaskSourceInfo::Client::kAegis,
                                agent_task_id),
          std::make_unique<AegisActorPolicyChecker>(scope,
                                                    std::move(selected_urls)),
          nullptr, nullptr);
  if (actor_task_id.is_null()) {
    return std::nullopt;
  }
  actor_tasks_.emplace(agent_task_id, actor_task_id);
  task_scopes_.emplace(agent_task_id, scope);
  return actor_task_id;
}

bool AegisActorBridge::PauseTask(const std::string& agent_task_id,
                                 bool by_user) {
  actor::ActorTask* task = GetActorTask(agent_task_id);
  if (!task || task->IsCompleted()) {
    return false;
  }
  task->Pause(/*from_actor=*/!by_user);
  last_documents_.erase(agent_task_id);
  observed_documents_.erase(agent_task_id);
  last_fingerprints_.erase(agent_task_id);
  observed_node_text_.erase(agent_task_id);
  webmcp_documents_.erase(agent_task_id);
  return true;
}

bool AegisActorBridge::ResumeTask(const std::string& agent_task_id) {
  actor::ActorTask* task = GetActorTask(agent_task_id);
  if (!task || task->IsCompleted() || !task->IsUnderUserControl()) {
    return false;
  }
  last_documents_.erase(agent_task_id);
  observed_documents_.erase(agent_task_id);
  last_fingerprints_.erase(agent_task_id);
  observed_node_text_.erase(agent_task_id);
  webmcp_documents_.erase(agent_task_id);
  task->Resume();
  return true;
}

bool AegisActorBridge::StopTask(const std::string& agent_task_id,
                                bool completed) {
  auto it = actor_tasks_.find(agent_task_id);
  if (it == actor_tasks_.end()) {
    return false;
  }
  const actor::TaskId actor_task_id = it->second;
  if (actor_service_->GetTask(actor_task_id)) {
    actor_service_->StopTask(
        actor_task_id, completed
                           ? actor::ActorTask::StoppedReason::kTaskComplete
                           : actor::ActorTask::StoppedReason::kStoppedByUser);
  }
  // StopTask() 会同步通知观察者；回调可能已删除该项，因此按键删除，
  // 不再使用可能失效的迭代器。
  actor_tasks_.erase(agent_task_id);
  task_scopes_.erase(agent_task_id);
  last_documents_.erase(agent_task_id);
  observed_documents_.erase(agent_task_id);
  last_fingerprints_.erase(agent_task_id);
  observed_node_text_.erase(agent_task_id);
  webmcp_documents_.erase(agent_task_id);
  return true;
}

bool AegisActorBridge::HasTask(const std::string& agent_task_id) const {
  return GetActorTask(agent_task_id) != nullptr;
}

bool AegisActorBridge::AdoptTab(const std::string& agent_task_id,
                                int32_t tab_id) {
  auto scope_it = task_scopes_.find(agent_task_id);
  return GetActorTask(agent_task_id) && scope_it != task_scopes_.end() &&
         tab_id > 0 && scope_it->second.allowed_tab_ids.insert(tab_id).second;
}

bool AegisActorBridge::ReleaseTab(const std::string& agent_task_id,
                                  int32_t tab_id) {
  auto scope_it = task_scopes_.find(agent_task_id);
  if (scope_it == task_scopes_.end() || tab_id <= 0 ||
      scope_it->second.allowed_tab_ids.erase(tab_id) != 1u) {
    return false;
  }
  auto documents = last_documents_.find(agent_task_id);
  if (documents != last_documents_.end()) {
    documents->second.erase(tab_id);
  }
  auto webmcp = webmcp_documents_.find(agent_task_id);
  if (webmcp != webmcp_documents_.end()) {
    webmcp->second.erase(tab_id);
  }
  auto observed_nodes = observed_node_text_.find(agent_task_id);
  if (observed_nodes != observed_node_text_.end()) {
    observed_nodes->second.erase(tab_id);
  }
  return true;
}

void AegisActorBridge::AttachBlankMonitorTab(
    const std::string& agent_task_id,
    int32_t tab_id,
    base::OnceCallback<void(bool)> callback) {
  actor::ActorTask* task = GetActorTask(agent_task_id);
  const auto scope = task_scopes_.find(agent_task_id);
  tabs::TabInterface* tab = tabs::TabHandle(tab_id).Get();
  if (!task || scope == task_scopes_.end() || !tab ||
      tab->GetProfile() != profile_ || !scope->second.AllowsTab(tab_id) ||
      tab->GetURL() != GURL(url::kAboutBlankURL) ||
      scope->second.allowed_origins.size() != 1u ||
      scope->second.allowed_tools != base::flat_set<std::string>{"page.observe"}) {
    std::move(callback).Run(false);
    return;
  }
  task->AddTab(tab->GetHandle(), /*stop_task_on_detach=*/true,
               base::BindOnce(
                   [](base::OnceCallback<void(bool)> ready,
                      actor::mojom::ActionResultPtr result) {
                     std::move(ready).Run(result && actor::IsOk(*result));
                   },
                   std::move(callback)));
}

void AegisActorBridge::ExecutePageTool(const std::string& agent_task_id,
                                       const AgentToolCall& call,
                                       ToolResultCallback callback) {
  if (base::StartsWith(call.tool_name, "page.webmcp.") &&
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgentWebMcp)) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kToolUnavailable,
                                        "WebMCP is disabled"));
    return;
  }
  actor::ActorTask* actor_task = GetActorTask(agent_task_id);
  auto scope_it = task_scopes_.find(agent_task_id);
  if (!actor_task || scope_it == task_scopes_.end() ||
      !scope_it->second.AllowsTool(call.tool_name)) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kToolUnavailable,
                                        "actor task is unavailable"));
    return;
  }

  std::optional<int> tab_id = call.arguments.FindInt("tab_id");
  tabs::TabInterface* tab = tab_id ? tabs::TabHandle(*tab_id).Get() : nullptr;
  if (!tab || tab->GetProfile() != profile_ ||
      !scope_it->second.AllowsTab(*tab_id) ||
      !scope_it->second.AllowsOrigin(tab->GetURL())) {
    std::move(callback).Run(
        ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                    "tab or committed origin is unavailable"));
    return;
  }
  if (!call.committed_url.is_valid() || tab->GetURL() != call.committed_url) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kStaleDocument,
                                        "tab URL changed before execution"));
    return;
  }
  if (call.tool_name == "page.extract") {
    std::vector<std::string> fields;
    if (const base::ListValue* values = call.arguments.FindList("fields")) {
      for (const base::Value& value : *values) {
        fields.push_back(value.GetString());
      }
    }
    ObservePage(agent_task_id, call.action_id, *tab_id, call.committed_url,
                false,
                base::BindOnce(&FinishPageExtraction,
                               call.arguments.FindString("kind")
                                   ? *call.arguments.FindString("kind")
                                   : std::string("article"),
                               std::move(fields), std::move(callback)));
    return;
  }
  if (call.tool_name == "page.observe" ||
      call.tool_name == "page.webmcp.list") {
    ObservePage(agent_task_id, call.action_id, *tab_id, call.committed_url,
                false, std::move(callback));
    return;
  }

  if (call.tool_name != "page.navigate") {
    std::optional<AgentDocumentRef> observed =
        LastDocument(agent_task_id, *tab_id);
    if (!call.document || !observed ||
        !SameDocument(*call.document, *observed) ||
        call.document->frame_token != CurrentFrameToken(*tab)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                      "page action requires the latest observation"));
      return;
    }
  }

  std::vector<int> target_node_ids;
  const auto append_node = [&](std::string_view key) {
    if (const std::optional<int> node_id = call.arguments.FindInt(key)) {
      target_node_ids.push_back(*node_id);
    }
  };
  if (call.tool_name == "page.click" || call.tool_name == "page.type" ||
      call.tool_name == "page.select") {
    append_node("node_id");
  } else if (call.tool_name == "page.drag") {
    append_node("from_node_id");
    append_node("to_node_id");
  } else if (call.tool_name == "auth.attempt_login") {
    append_node("password_button_node_id");
  } else if (call.tool_name == "auth.fill_otp" ||
             call.tool_name == "form.fill") {
    if (const base::ListValue* node_ids =
            call.arguments.FindList("field_node_ids")) {
      for (const base::Value& node_id : *node_ids) {
        target_node_ids.push_back(node_id.GetInt());
      }
    }
  }
  const bool requires_observed_target =
      call.tool_name == "page.click" || call.tool_name == "page.type" ||
      call.tool_name == "page.select" || call.tool_name == "page.drag" ||
      call.tool_name == "auth.attempt_login" ||
      call.tool_name == "auth.fill_otp" || call.tool_name == "form.fill";
  const std::map<int, ObservedNodeMetadata>* observed_nodes = nullptr;
  auto task_nodes = observed_node_text_.find(agent_task_id);
  if (task_nodes != observed_node_text_.end()) {
    auto tab_nodes = task_nodes->second.find(*tab_id);
    if (tab_nodes != task_nodes->second.end()) {
      observed_nodes = &tab_nodes->second;
    }
  }
  if ((requires_observed_target && target_node_ids.empty()) ||
      std::ranges::any_of(target_node_ids, [&](int node_id) {
        return !observed_nodes || !observed_nodes->contains(node_id);
      })) {
    std::move(callback).Run(
        ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                    "page target is absent from the latest observation"));
    return;
  }
  if ((call.tool_name == "page.type" || call.tool_name == "page.select" ||
       call.tool_name == "page.drag") &&
      std::ranges::any_of(target_node_ids, [&](int node_id) {
        return observed_nodes->at(node_id).is_sensitive_control;
      })) {
    std::move(callback).Run(
        ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                    "generic page tools cannot target password, OTP, or "
                    "payment controls"));
    return;
  }

  if (call.tool_name == "page.click") {
    const int node_id = target_node_ids.front();
    const auto node = observed_nodes->find(node_id);
    if (ShouldAegisRequireUserTakeoverForClick(
            node->second.text, node->second.is_submit_control)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                      "form submission and final transaction controls require "
                      "direct user takeover"));
      return;
    }
    if (scope_it->second.AllowsTool("shopping.prepare_checkout") &&
        !IsAegisShoppingIntermediateControlText(node->second.text)) {
      std::move(callback).Run(ErrorResult(
          call.action_id, AgentErrorCode::kScopeViolation,
          "shopping clicks are limited to cart and checkout preparation "
          "controls"));
      return;
    }
  }

  if (call.tool_name == "page.webmcp.invoke") {
    const std::string* name = call.arguments.FindString("name");
    const std::string* revision = call.arguments.FindString("tool_revision");
    const std::string* input_json = call.arguments.FindString("input_json");
    auto task_documents = webmcp_documents_.find(agent_task_id);
    auto document = task_documents == webmcp_documents_.end()
                        ? std::map<int32_t, WebMcpDocument>::iterator()
                        : task_documents->second.find(*tab_id);
    if (!name || !revision || !input_json ||
        task_documents == webmcp_documents_.end() ||
        document == task_documents->second.end() ||
        document->second.document_token != call.document->document_token) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                      "WebMCP registry changed after observation"));
      return;
    }
    auto tool = document->second.tools.find(*name);
    if (tool == document->second.tools.end() ||
        tool->second.revision != *revision) {
      std::move(callback).Run(ErrorResult(call.action_id,
                                          AgentErrorCode::kStaleDocument,
                                          "WebMCP tool revision is stale"));
      return;
    }
    std::optional<base::Value> parsed_input =
        base::JSONReader::Read(*input_json, base::JSON_PARSE_RFC);
    AgentModelToolDefinition tool_contract{
        .name = *name,
        .description = "untrusted same-document WebMCP tool",
        .input_schema = tool->second.input_schema.Clone()};
    std::string validation_error;
    if (!parsed_input || !parsed_input->is_dict() ||
        HasForbiddenWebMcpField(*parsed_input) ||
        !ValidateAgentToolArguments(tool_contract, parsed_input->GetDict(),
                                    &validation_error)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kInvalidRequest,
                      "WebMCP input rejected: " + validation_error));
      return;
    }
  }

  if (call.tool_name == "page.click") {
    const auto task_fingerprints = last_fingerprints_.find(agent_task_id);
    if (task_fingerprints == last_fingerprints_.end() ||
        !task_fingerprints->second.contains(*tab_id)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                      "点击前缺少页面观察，请先重新读取页面"));
      return;
    }
    // 保存浏览器产生的点击前指纹，模型参数不能伪造这份证据。
    callback = base::BindOnce(
        [](std::string before, ToolResultCallback done,
           AgentToolResult result) {
          if (result.ok) {
            result.value.Set("pre_action_fingerprint", std::move(before));
          }
          std::move(done).Run(std::move(result));
        },
        task_fingerprints->second.at(*tab_id), std::move(callback));
  }

  std::unique_ptr<actor::ToolRequest> request = BuildActorRequest(*tab, call);
  if (!request) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kToolUnavailable,
                                        "page tool is not implemented"));
    return;
  }
  if (call.tool_name == "page.navigate" || call.tool_name == "page.history") {
    last_documents_[agent_task_id].erase(*tab_id);
    observed_documents_[agent_task_id].erase(*tab_id);
    last_fingerprints_[agent_task_id].erase(*tab_id);
    observed_node_text_[agent_task_id].erase(*tab_id);
    webmcp_documents_[agent_task_id].erase(*tab_id);
  }
  std::vector<std::unique_ptr<actor::ToolRequest>> requests;
  requests.push_back(std::move(request));
  actor_service_->PerformActions(
      actor_task->id(), std::move(requests), actor::ActorTaskMetadata(),
      base::BindOnce(&AegisActorBridge::OnActionsPerformed,
                     weak_ptr_factory_.GetWeakPtr(), agent_task_id,
                     call.action_id, *tab_id, std::move(callback)));
}

std::optional<AgentDocumentRef> AegisActorBridge::LastDocument(
    const std::string& agent_task_id,
    int32_t tab_id) const {
  auto task_it = last_documents_.find(agent_task_id);
  if (task_it == last_documents_.end()) {
    return std::nullopt;
  }
  auto document_it = task_it->second.find(tab_id);
  return document_it == task_it->second.end()
             ? std::nullopt
             : std::make_optional(document_it->second);
}

bool AegisActorBridge::IsObservedDocumentCurrent(
    const std::string& agent_task_id,
    int32_t tab_id,
    const std::string& document_token) const {
  const auto document = LastDocument(agent_task_id, tab_id);
  const auto observed = observed_documents_.find(agent_task_id);
  auto* tab = tabs::TabHandle(tab_id).Get();
  if (!document || document->document_token != document_token || !tab ||
      tab->GetProfile() != profile_ || !tab->GetContents() ||
      observed == observed_documents_.end()) {
    return false;
  }
  const auto pointer = observed->second.find(tab_id);
  return pointer != observed->second.end() &&
         pointer->second.AsRenderFrameHostIfValid() &&
         pointer->second.AsRenderFrameHostIfValid() ==
             tab->GetContents()->GetPrimaryMainFrame() &&
         document->committed_url == tab->GetURL() &&
         !IsErrorPage(tab->GetContents());
}

std::string AegisActorBridge::DescribeObservedClickTarget(
    const std::string& agent_task_id,
    const AgentToolCall& call) const {
  const auto target = ResolveObservedClickTarget(agent_task_id, call);
  if (!target) {
    return {};
  }
  const auto& metadata = observed_node_text_.at(agent_task_id)
                             .at(*call.arguments.FindInt("tab_id"))
                             .at(*target);
  return BoundedText(
      std::string(base::TrimWhitespaceASCII(metadata.text, base::TRIM_ALL)),
      512u);
}

std::optional<int> AegisActorBridge::ResolveObservedClickTarget(
    const std::string& agent_task_id,
    const AgentToolCall& call) const {
  const auto tab_id = call.arguments.FindInt("tab_id");
  const auto node_id = call.arguments.FindInt("node_id");
  if (call.tool_name != "page.click" || !call.document || !tab_id || !node_id) {
    return {};
  }
  const auto document = LastDocument(agent_task_id, *tab_id);
  if (!document || !SameDocument(*document, *call.document)) {
    return {};
  }
  const auto task = observed_node_text_.find(agent_task_id);
  if (task == observed_node_text_.end()) {
    return {};
  }
  const auto tab = task->second.find(*tab_id);
  if (tab == task->second.end()) {
    return {};
  }
  const auto node = tab->second.find(*node_id);
  if (node == tab->second.end() || node->second.is_sensitive_control) {
    return {};
  }
  const auto target = tab->second.find(node->second.click_target_node_id);
  if (target == tab->second.end() || target->second.is_sensitive_control ||
      target->second.click_target_node_id != target->first) {
    return {};
  }
  return target->first;
}

std::optional<GURL> AegisActorBridge::ResolveObservedDownloadUrl(
    const std::string& agent_task_id,
    const AgentToolCall& call) const {
  const auto tab_id = call.arguments.FindInt("tab_id");
  const auto* requested = call.arguments.FindString("url");
  if (call.tool_name != "download.start" || !call.document || !tab_id ||
      !requested) {
    return std::nullopt;
  }
  const GURL candidate(*requested);
  const auto document = LastDocument(agent_task_id, *tab_id);
  const auto task = observed_node_text_.find(agent_task_id);
  if (!document || !SameDocument(*document, *call.document) ||
      task == observed_node_text_.end() || !candidate.SchemeIsHTTPOrHTTPS() ||
      candidate.has_username() || candidate.has_password()) {
    return std::nullopt;
  }
  const auto tab = task->second.find(*tab_id);
  if (tab == task->second.end()) {
    return std::nullopt;
  }
  std::optional<GURL> matched;
  for (const auto& [id, node] : tab->second) {
    const GURL& url = node.download_url;
    if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || url.has_username() ||
        url.has_password() || node.is_sensitive_control ||
        (candidate != url &&
         candidate.spec() != SafeObservationUrl(url.spec()))) {
      continue;
    }
    if (matched && *matched != url) {
      return std::nullopt;
    }
    matched = url;
  }
  return matched;
}

void AegisActorBridge::ObservePage(const std::string& agent_task_id,
                                   std::string action_id,
                                   int32_t tab_id,
                                   std::optional<GURL> expected_url,
                                   bool post_action,
                                   ToolResultCallback callback) {
  actor::ActorTask* actor_task = GetActorTask(agent_task_id);
  tabs::TabInterface* tab = tabs::TabHandle(tab_id).Get();
  if (!actor_task || !tab || tab->GetProfile() != profile_) {
    std::move(callback).Run(ErrorResult(std::move(action_id),
                                        AgentErrorCode::kStaleDocument,
                                        "tab disappeared before observation"));
    return;
  }
  if (IsErrorPage(tab->GetContents())) {
    std::move(callback).Run(
        ErrorResult(std::move(action_id), AgentErrorCode::kVerificationFailed,
                    "page source is an error document or HTTP error"));
    return;
  }
  actor_service_->RequestTabObservation(
      *tab, actor_task->id(), std::nullopt,
      base::BindOnce(
          &AegisActorBridge::OnObservation, weak_ptr_factory_.GetWeakPtr(),
          agent_task_id, std::move(action_id), tab_id,
          tab->GetContents()->GetPrimaryMainFrame()->GetWeakDocumentPtr(),
          std::move(expected_url), post_action, std::move(callback)));
}

void AegisActorBridge::OnObservation(
    const std::string& agent_task_id,
    std::string action_id,
    int32_t tab_id,
    content::WeakDocumentPtr expected_document,
    std::optional<GURL> expected_url,
    bool post_action,
    ToolResultCallback callback,
    actor::ActorKeyedService::TabObservationResult observation_result) {
  tabs::TabInterface* tab = tabs::TabHandle(tab_id).Get();
  auto scope_it = task_scopes_.find(agent_task_id);
  if (!GetActorTask(agent_task_id) || !tab || tab->GetProfile() != profile_ ||
      scope_it == task_scopes_.end() ||
      !expected_document.AsRenderFrameHostIfValid() ||
      expected_document.AsRenderFrameHostIfValid() !=
          tab->GetContents()->GetPrimaryMainFrame() ||
      !scope_it->second.AllowsOrigin(tab->GetURL()) ||
      (expected_url && tab->GetURL() != *expected_url)) {
    std::move(callback).Run(ErrorResult(std::move(action_id),
                                        AgentErrorCode::kStaleDocument,
                                        "page changed during observation"));
    return;
  }
  if (IsErrorPage(tab->GetContents())) {
    std::move(callback).Run(
        ErrorResult(std::move(action_id), AgentErrorCode::kVerificationFailed,
                    "observed source is an error document or HTTP error"));
    return;
  }
  // 专用后台监控只使用语义节点，不消费截图。截图失败不能抹掉已经成功
  // 提取的正文；仍要求真实 APC、后续文档身份和范围校验全部通过。
  const bool semantic_monitor =
      !post_action && agent_task_id.starts_with("monitor-page-") &&
      scope_it->second.allowed_origins.size() == 1u &&
      scope_it->second.allowed_tab_ids.size() == 1u &&
      scope_it->second.allowed_tools ==
          base::flat_set<std::string>{"page.observe"};
  std::optional<std::string> observation_error;
  if (semantic_monitor) {
    if (!observation_result.has_value() ||
        !observation_result.value()->annotated_page_content_result.has_value()) {
      observation_error = "monitor semantic content is unavailable";
    }
  } else {
    observation_error =
        actor::ActorKeyedService::ExtractErrorMessageIfFailed(observation_result);
  }
  if (observation_error) {
    std::move(callback).Run(ErrorResult(std::move(action_id),
                                        AgentErrorCode::kVerificationFailed,
                                        "page observation failed: " +
                                            *observation_error));
    return;
  }

  optimization_guide::proto::TabObservation observation;
  actor::FillInTabObservation(**observation_result, observation);
  if (!observation.has_annotated_page_content()) {
    std::move(callback).Run(
        ErrorResult(std::move(action_id), AgentErrorCode::kVerificationFailed,
                    "page observation has no semantic content"));
    return;
  }
  const auto& page = observation.annotated_page_content();
  const GURL observed_url(page.main_frame_data().url());
  const std::string document_token =
      page.main_frame_data().document_identifier().serialized_token();
  const std::string frame_token = CurrentFrameToken(*tab);
  if (observed_url != tab->GetURL() || document_token.empty() ||
      frame_token.empty()) {
    std::move(callback).Run(
        ErrorResult(std::move(action_id), AgentErrorCode::kStaleDocument,
                    "page identity changed during observation"));
    return;
  }

  AgentDocumentRef document{.tab_id = tab_id,
                            .frame_token = frame_token,
                            .document_token = document_token,
                            .committed_url = observed_url};
  last_documents_[agent_task_id][tab_id] = document;
  observed_documents_[agent_task_id][tab_id] = expected_document;

  // 以已批准工具范围决定是否保留交互控件；研究与监控只读取正文。
  const bool interactive = std::ranges::any_of(
      scope_it->second.allowed_tools, [](const std::string& tool) {
        return tool == "page.click" || tool == "page.type" ||
               tool == "page.select" || tool == "page.drag" ||
               tool == "form.fill" || base::StartsWith(tool, "auth.") ||
               tool == "page.webmcp.invoke";
      });
  auto bounded =
      BuildAgentObservationNodes(page.root_node(), interactive,
                                 scope_it->second.AllowsTool("download.start"));
  base::ListValue nodes = std::move(bounded.nodes);
  const bool truncated = bounded.truncated;
  std::string serialized_nodes;
  if (!base::JSONWriter::Write(nodes, &serialized_nodes)) {
    std::move(callback).Run(
        ErrorResult(std::move(action_id), AgentErrorCode::kVerificationFailed,
                    "page observation could not be fingerprinted"));
    return;
  }
  const std::string observation_fingerprint = base::HexEncode(
      crypto::SHA256HashString(observed_url.spec() + "\n" + document_token +
                               "\n" + serialized_nodes));
  last_fingerprints_[agent_task_id][tab_id] = observation_fingerprint;
  std::map<int, ObservedNodeMetadata>& observed_nodes =
      observed_node_text_[agent_task_id][tab_id];
  observed_nodes.clear();
  for (const base::Value& value : nodes) {
    const base::DictValue& node = value.GetDict();
    const std::optional<int> node_id = node.FindInt("node_id");
    if (!node_id) {
      continue;
    }
    ObservedNodeMetadata& metadata = observed_nodes[*node_id];
    if (auto link = bounded.download_links.find(*node_id);
        link != bounded.download_links.end()) {
      metadata.download_url = link->second;
    }
    metadata.click_target_node_id =
        node.FindInt("click_target_node_id").value_or(0);
    if (const std::string* text = node.FindString("text")) {
      metadata.text += " " + *text;
    }
    if (const std::string* label = node.FindString("label")) {
      metadata.text += " " + *label;
    }
    const std::optional<int> control_type = node.FindInt("form_control_type");
    if (control_type ==
            optimization_guide::proto::FORM_CONTROL_TYPE_BUTTON_SUBMIT ||
        control_type ==
            optimization_guide::proto::FORM_CONTROL_TYPE_INPUT_SUBMIT ||
        control_type ==
            optimization_guide::proto::FORM_CONTROL_TYPE_INPUT_IMAGE) {
      metadata.is_submit_control = true;
    }
    if (control_type ==
        optimization_guide::proto::FORM_CONTROL_TYPE_INPUT_PASSWORD) {
      metadata.is_sensitive_control = true;
    }
    metadata.is_sensitive_control |=
        node.FindBool("is_sensitive_control").value_or(false);
  }

  // 只聚合已裁剪和脱敏的真实子节点文字；不根据相同文本猜测其他控件。
  for (const auto& [node_id, metadata] : observed_nodes) {
    const auto target = observed_nodes.find(metadata.click_target_node_id);
    if (target != observed_nodes.end() && target->first != node_id &&
        !metadata.is_sensitive_control &&
        !target->second.is_sensitive_control) {
      target->second.text =
          BoundedText(target->second.text + " " + metadata.text, 2048u);
    }
  }

  AgentToolResult result;
  result.action_id = std::move(action_id);
  result.ok = true;
  result.message = post_action ? "action verified by a fresh page observation"
                               : "page observation completed";
  result.value.Set("tab_id", tab_id);
  result.value.Set("is_error_document", false);
  const auto* entry =
      tab->GetContents()->GetController().GetLastCommittedEntry();
  result.value.Set("http_status", entry ? entry->GetHttpStatusCode() : 0);
  const std::string safe_observed_url = SafeObservationUrl(observed_url.spec());
  result.value.Set("url", safe_observed_url);
  result.value.Set("title", BoundedText(base::UTF16ToUTF8(tab->GetTitle()),
                                        kMaxNodeTextBytes));
  result.value.Set("frame_token", document.frame_token);
  result.value.Set("document_token", document.document_token);
  result.value.Set("observation_fingerprint", observation_fingerprint);
  result.value.Set(
      "captured_at_ms",
      base::NumberToString(base::Time::Now().InMillisecondsSinceUnixEpoch()));
  result.value.Set("untrusted", true);
  result.value.Set("truncated", truncated);
  result.value.Set("nodes", std::move(nodes));

  WebMcpDocument webmcp_document;
  webmcp_document.document_token = document.document_token;
  base::ListValue webmcp_tools;
  const bool expose_webmcp =
      base::FeatureList::IsEnabled(aegis::features::kAegisAgentWebMcp) &&
      scope_it->second.AllowsTool("page.webmcp.list");
  if (expose_webmcp) {
    for (const optimization_guide::proto::ScriptTool& tool :
         page.main_frame_data().script_tools()) {
      std::optional<base::DictValue> schema =
          ParseSafeWebMcpSchema(tool.input_schema());
      if (!schema || !IsSafeToolName(tool.name()) ||
          !base::IsStringUTF8(tool.description()) ||
          tool.description().size() > 2048u) {
        continue;
      }
      const std::string revision =
          WebMcpRevision(document.document_token, tool);
      const bool read_only =
          tool.has_annotations() && tool.annotations().read_only();
      base::DictValue exposed;
      exposed.Set("name", tool.name());
      exposed.Set("description", tool.description());
      exposed.Set("input_schema", schema->Clone());
      exposed.Set("tool_revision", revision);
      exposed.Set("read_only", read_only);
      exposed.Set("untrusted", true);
      webmcp_tools.Append(std::move(exposed));
      webmcp_document.tools.emplace(
          tool.name(), WebMcpToolMetadata{.revision = revision,
                                          .input_schema = std::move(*schema),
                                          .read_only = read_only});
    }
  }
  webmcp_documents_[agent_task_id][tab_id] = std::move(webmcp_document);
  result.value.Set("webmcp_tools", std::move(webmcp_tools));

  base::ListValue webmcp_results;
  if (expose_webmcp && scope_it->second.AllowsTool("page.webmcp.invoke")) {
    for (const optimization_guide::proto::ScriptToolResult& tool_result :
         page.main_frame_data().script_tool_results()) {
      if (!IsSafeToolName(tool_result.tool_name())) {
        continue;
      }
      base::DictValue exposed;
      exposed.Set("name", tool_result.tool_name());
      exposed.Set("untrusted", true);
      if (std::optional<std::string> safe_result =
              SafeWebMcpResult(tool_result.result())) {
        exposed.Set("result", std::move(*safe_result));
        exposed.Set("result_omitted", false);
      } else {
        exposed.Set("result_omitted", true);
      }
      webmcp_results.Append(std::move(exposed));
    }
  }
  result.value.Set("webmcp_results", std::move(webmcp_results));
  base::DictValue evidence;
  evidence.Set("kind", "browser_observation");
  evidence.Set("url", safe_observed_url);
  evidence.Set("document_token", document.document_token);
  result.evidence.Append(std::move(evidence));
  std::move(callback).Run(std::move(result));
}

void AegisActorBridge::OnActionsPerformed(
    const std::string& agent_task_id,
    std::string action_id,
    int32_t tab_id,
    ToolResultCallback callback,
    std::vector<actor::ActionResultWithLatencyInfo> action_results,
    actor::TabObservationStrategy observation_strategy) {
  if (action_results.size() != 1u || !action_results.front().result ||
      !actor::IsOk(*action_results.front().result)) {
    std::string message = "actor page action failed";
    if (!action_results.empty() && action_results.front().result) {
      message += ": " + actor::ToDebugString(*action_results.front().result);
    }
    std::move(callback).Run(ErrorResult(std::move(action_id),
                                        AgentErrorCode::kVerificationFailed,
                                        std::move(message)));
    return;
  }
  ObservePage(agent_task_id, std::move(action_id), tab_id, std::nullopt, true,
              std::move(callback));
}

actor::ActorTask* AegisActorBridge::GetActorTask(
    const std::string& agent_task_id) const {
  if (!actor_service_) {
    return nullptr;
  }
  auto it = actor_tasks_.find(agent_task_id);
  return it == actor_tasks_.end() ? nullptr
                                  : actor_service_->GetTask(it->second);
}

void AegisActorBridge::OnActorTaskStateChanged(actor::ActorTask& task) {
  if (task.source_info().type != actor::TaskSourceInfo::Client::kAegis ||
      !task.source_info().id) {
    return;
  }
  const std::string& agent_task_id = task.source_info().id.value();
  if (task.GetState() == actor::ActorTask::State::kPausedByUser) {
    last_documents_.erase(agent_task_id);
    observed_documents_.erase(agent_task_id);
    last_fingerprints_.erase(agent_task_id);
    observed_node_text_.erase(agent_task_id);
    webmcp_documents_.erase(agent_task_id);
    if (state_event_callback_) {
      state_event_callback_.Run(agent_task_id, StateEvent::kPausedByUser);
    }
  } else if (task.GetState() == actor::ActorTask::State::kWaitingOnUser) {
    last_documents_.erase(agent_task_id);
    observed_documents_.erase(agent_task_id);
    last_fingerprints_.erase(agent_task_id);
    observed_node_text_.erase(agent_task_id);
    webmcp_documents_.erase(agent_task_id);
    if (state_event_callback_) {
      state_event_callback_.Run(agent_task_id, StateEvent::kWaitingOnUser);
    }
  }
  if (!task.IsCompleted()) {
    return;
  }
  actor_tasks_.erase(agent_task_id);
  task_scopes_.erase(agent_task_id);
  last_documents_.erase(agent_task_id);
  observed_documents_.erase(agent_task_id);
  last_fingerprints_.erase(agent_task_id);
  observed_node_text_.erase(agent_task_id);
  webmcp_documents_.erase(agent_task_id);
}

}  // namespace aegis::agent
