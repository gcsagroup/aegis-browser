// Copyright 2026 GCSA
#include "chrome/browser/aegis/agent/agent_observation.h"
#include <algorithm>
#include <utility>
#include "base/strings/string_util.h"
#include "chrome/browser/aegis/summary_policy.h"
#include "components/optimization_guide/proto/features/common_quality_data.pb.h"
#include "url/gurl.h"
namespace aegis::agent {
namespace {
constexpr size_t kMaxObservationBytes = 128 * 1024;
constexpr size_t kMaxObservationNodes = 512;
constexpr size_t kMaxNodeTextBytes = 2048;
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

void AppendMainFrameNodes(
    const optimization_guide::proto::ContentNode& node,
    bool interactive,
    base::ListValue* nodes,
    size_t* used_bytes,
    bool* truncated,
    std::map<int, GURL>* download_links,
    int text_block_kind = optimization_guide::proto::CONTENT_ATTRIBUTE_ROOT,
    int click_target_node_id = 0,
    bool in_article = false) {
  if (*used_bytes >= kMaxObservationBytes ||
      nodes->size() >= kMaxObservationNodes) {
    *truncated = true;
    return;
  }

  const auto& attributes = node.content_attributes();
  // 跨框架、隐藏节点及已判定需遮挡的整个子树都不进入模型上下文。
  if (attributes.has_iframe_data() ||
      attributes.redaction_decision() !=
          optimization_guide::proto::
              REDACTION_DECISION_NO_REDACTION_NECESSARY ||
      std::ranges::find(
          attributes.annotated_roles(),
          optimization_guide::proto::ANNOTATED_ROLE_CONTENT_HIDDEN) !=
          attributes.annotated_roles().end()) {
    return;
  }
  in_article |=
      std::ranges::find(attributes.annotated_roles(),
                        optimization_guide::proto::ANNOTATED_ROLE_ARTICLE) !=
      attributes.annotated_roles().end();
  if (!interactive) {
    if (attributes.has_form_control_data() || attributes.has_form_data()) {
      return;
    }
    for (auto role : attributes.annotated_roles()) {
      if (role == optimization_guide::proto::ANNOTATED_ROLE_NAV ||
          (!in_article &&
           (role == optimization_guide::proto::ANNOTATED_ROLE_HEADER ||
            role == optimization_guide::proto::ANNOTATED_ROLE_FOOTER)) ||
          role == optimization_guide::proto::ANNOTATED_ROLE_ASIDE ||
          role == optimization_guide::proto::ANNOTATED_ROLE_SEARCH) {
        return;
      }
    }
  }
  if (attributes.has_form_control_data()) {
    const auto& control = attributes.form_control_data();
    bool sensitive =
        control.form_control_type() ==
        optimization_guide::proto::FORM_CONTROL_TYPE_INPUT_PASSWORD;
    for (auto type : control.coarse_autofill_field_type()) {
      sensitive |=
          type == optimization_guide::proto::COARSE_AUTOFILL_FIELD_TYPE_OTP ||
          type ==
              optimization_guide::proto::COARSE_AUTOFILL_FIELD_TYPE_CREDIT_CARD;
    }
    if (sensitive) {
      base::DictValue item;
      if (attributes.common_ancestor_dom_node_id() > 0) {
        item.Set("node_id", attributes.common_ancestor_dom_node_id());
      }
      item.Set("kind", static_cast<int>(attributes.attribute_type()));
      item.Set("form_control_type",
               static_cast<int>(control.form_control_type()));
      item.Set("is_sensitive_control", true);
      nodes->Append(std::move(item));
      return;
    }
    // 保留按钮与内部文字的真实DOM关系，避免把文字节点当成点击对象。
    switch (control.form_control_type()) {
      case optimization_guide::proto::FORM_CONTROL_TYPE_BUTTON_BUTTON:
      case optimization_guide::proto::FORM_CONTROL_TYPE_BUTTON_SUBMIT:
      case optimization_guide::proto::FORM_CONTROL_TYPE_BUTTON_RESET:
      case optimization_guide::proto::FORM_CONTROL_TYPE_BUTTON_POPOVER:
      case optimization_guide::proto::FORM_CONTROL_TYPE_INPUT_BUTTON:
      case optimization_guide::proto::FORM_CONTROL_TYPE_INPUT_SUBMIT:
      case optimization_guide::proto::FORM_CONTROL_TYPE_INPUT_IMAGE:
        click_target_node_id = attributes.common_ancestor_dom_node_id();
        break;
      default:
        click_target_node_id = 0;
        break;
    }
  }
  if (attributes.attribute_type() ==
          optimization_guide::proto::CONTENT_ATTRIBUTE_HEADING ||
      attributes.attribute_type() ==
          optimization_guide::proto::CONTENT_ATTRIBUTE_PARAGRAPH) {
    text_block_kind = attributes.attribute_type();
  }
  if (attributes.redaction_decision() ==
      optimization_guide::proto::REDACTION_DECISION_NO_REDACTION_NECESSARY) {
    base::DictValue item;
    if (attributes.common_ancestor_dom_node_id() > 0) {
      item.Set("node_id", attributes.common_ancestor_dom_node_id());
      if (interactive && click_target_node_id > 0) {
        item.Set("click_target_node_id", click_target_node_id);
      }
    }
    item.Set("kind", static_cast<int>(attributes.attribute_type()));

    const size_t remaining = kMaxObservationBytes - *used_bytes;
    std::string text;
    if (attributes.has_text_data()) {
      text = BoundedAgentObservationText(attributes.text_data().text_content(),
                                         remaining);
    } else if (attributes.has_anchor_data()) {
      const GURL raw(attributes.anchor_data().url());
      const int id = attributes.common_ancestor_dom_node_id();
      if (download_links && id > 0 && raw.SchemeIsHTTPOrHTTPS() &&
          !raw.has_username() && !raw.has_password() &&
          raw.spec().size() <= 4096u) {
        auto [it, inserted] = download_links->emplace(id, raw);
        if (!inserted && it->second != raw) {
          it->second = GURL();
        }
      }
      text = BoundedAgentObservationText(
          SafeObservationUrl(attributes.anchor_data().url()), remaining);
    } else if (attributes.has_form_control_data()) {
      text = BoundedAgentObservationText(
          attributes.form_control_data().placeholder(), remaining);
    }
    if (!text.empty()) {
      *used_bytes += text.size();
      item.Set("text", std::move(text));
      if (attributes.has_text_data()) {
        item.Set("text_block_kind", text_block_kind);
        item.Set("text_is_heading",
                 text_block_kind ==
                     optimization_guide::proto::CONTENT_ATTRIBUTE_HEADING);
        // 只保留已授权、已脱敏 APC 的相对字号，不冒充 HTML 标题等级。
        if (attributes.text_data().has_text_style() &&
            attributes.text_data().text_style().has_text_size()) {
          const char* size = nullptr;
          switch (attributes.text_data().text_style().text_size()) {
            case optimization_guide::proto::TEXT_SIZE_XS:
              size = "XS";
              break;
            case optimization_guide::proto::TEXT_SIZE_S:
              size = "S";
              break;
            case optimization_guide::proto::TEXT_SIZE_M_DEFAULT:
              size = "M";
              break;
            case optimization_guide::proto::TEXT_SIZE_L:
              size = "L";
              break;
            case optimization_guide::proto::TEXT_SIZE_XL:
              size = "XL";
              break;
            default:
              break;
          }
          if (size) {
            item.Set("text_size", size);
          }
        }
      }
    }

    std::string label = BoundedAgentObservationText(
        attributes.label(), kMaxObservationBytes - *used_bytes);
    if (!label.empty()) {
      *used_bytes += label.size();
      item.Set("label", std::move(label));
    }
    if (attributes.has_form_control_data()) {
      const auto& form_control = attributes.form_control_data();
      item.Set("form_control_type",
               static_cast<int>(form_control.form_control_type()));
    }
    if (item.size() > 1u) {
      nodes->Append(std::move(item));
    }
  }

  for (const auto& child : node.children_nodes()) {
    AppendMainFrameNodes(child, interactive, nodes, used_bytes, truncated,
                         download_links, text_block_kind, click_target_node_id,
                         in_article);
    if (*truncated) {
      return;
    }
  }
}

}  // namespace
std::string BoundedAgentObservationText(std::string_view text,
                                        size_t remaining) {
  const size_t limit = std::min(remaining, kMaxNodeTextBytes);
  return std::string(base::TruncateUTF8ToByteSize(
      SanitizeModelContextText(base::TruncateUTF8ToByteSize(text, limit)),
      limit));
}
AgentObservationNodes BuildAgentObservationNodes(
    const optimization_guide::proto::ContentNode& root,
    bool interactive,
    bool capture_download_links) {
  AgentObservationNodes result;
  size_t used_bytes = 0;
  AppendMainFrameNodes(
      root, interactive, &result.nodes, &used_bytes, &result.truncated,
      capture_download_links ? &result.download_links : nullptr);
  return result;
}
}  // namespace aegis::agent
