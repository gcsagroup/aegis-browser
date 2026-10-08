// Copyright 2026 GCSA
#include "chrome/browser/aegis/agent/agent_observation.h"

#include <string>

#include "base/json/json_writer.h"
#include "base/strings/string_util.h"
#include "components/optimization_guide/proto/features/common_quality_data.pb.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::agent {
namespace {
namespace proto = optimization_guide::proto;

proto::ContentNode* AddText(proto::ContentNode* parent,
                            int id,
                            const std::string& text) {
  auto* node = parent->add_children_nodes();
  auto* attributes = node->mutable_content_attributes();
  attributes->set_attribute_type(proto::CONTENT_ATTRIBUTE_TEXT);
  attributes->set_common_ancestor_dom_node_id(id);
  attributes->mutable_text_data()->set_text_content(text);
  return node;
}

std::string Serialize(const AgentObservationNodes& observation) {
  return base::WriteJson(observation.nodes).value();
}

TEST(AgentObservationTest, CompleteDownloadLinksStayOutsideModelObservation) {
  proto::ContentNode root;
  auto* node = root.add_children_nodes();
  auto* attributes = node->mutable_content_attributes();
  attributes->set_common_ancestor_dom_node_id(17);
  attributes->set_attribute_type(proto::CONTENT_ATTRIBUTE_ANCHOR);
  attributes->mutable_anchor_data()->set_url(
      "https://fixture.example/file?token=synthetic#fragment");
  const auto ordinary = BuildAgentObservationNodes(root, true);
  EXPECT_TRUE(ordinary.download_links.empty());
  const auto download = BuildAgentObservationNodes(root, true, true);
  ASSERT_EQ(download.download_links.size(), 1u);
  EXPECT_EQ(download.download_links.at(17).spec(),
            "https://fixture.example/file?token=synthetic#fragment");
  EXPECT_EQ(Serialize(download).find("synthetic"), std::string::npos);
  EXPECT_EQ(Serialize(download).find("fragment"), std::string::npos);
  EXPECT_NE(Serialize(download).find("https://fixture.example/file"),
            std::string::npos);
}

TEST(AgentObservationTest,
     HiddenAndCredentialLinksCannotBecomeDownloadCapabilities) {
  proto::ContentNode root;
  for (int id : {17, 18, 19}) {
    auto* node = root.add_children_nodes();
    auto* a = node->mutable_content_attributes();
    a->set_common_ancestor_dom_node_id(id);
    a->set_attribute_type(proto::CONTENT_ATTRIBUTE_ANCHOR);
    a->mutable_anchor_data()->set_url(
        id == 17   ? "https://fixture.example/file?hidden=1"
        : id == 18 ? "https://user:secret@fixture.example/file"
                   : "file:///private/file");
    if (id == 17) {
      a->add_annotated_roles(proto::ANNOTATED_ROLE_CONTENT_HIDDEN);
    }
  }
  EXPECT_TRUE(
      BuildAgentObservationNodes(root, true, true).download_links.empty());
}

TEST(AgentObservationTest, ReadOnlyKeepsBodyAndTableWithoutNavigationOrForms) {
  proto::ContentNode root;
  root.mutable_content_attributes()->set_attribute_type(
      proto::CONTENT_ATTRIBUTE_ROOT);
  auto* article = root.add_children_nodes();
  article->mutable_content_attributes()->add_annotated_roles(
      proto::ANNOTATED_ROLE_ARTICLE);
  AddText(article, 1, "正文指标42");
  auto* table = article->add_children_nodes();
  table->mutable_content_attributes()->set_attribute_type(
      proto::CONTENT_ATTRIBUTE_TABLE);
  AddText(table, 2, "实验数据：42");
  for (auto role : {proto::ANNOTATED_ROLE_NAV, proto::ANNOTATED_ROLE_HEADER,
                    proto::ANNOTATED_ROLE_FOOTER, proto::ANNOTATED_ROLE_ASIDE,
                    proto::ANNOTATED_ROLE_SEARCH}) {
    auto* extra = root.add_children_nodes();
    extra->mutable_content_attributes()->add_annotated_roles(role);
    AddText(extra, 100 + static_cast<int>(role),
            "无关导航" + std::string(300, 'x'));
  }
  auto* form = root.add_children_nodes();
  form->mutable_content_attributes()->mutable_form_data();
  AddText(form, 90, "表单标签不属于正文");
  const auto read_only = BuildAgentObservationNodes(root, false);
  const auto interactive = BuildAgentObservationNodes(root, true);
  const auto text = Serialize(read_only);
  EXPECT_NE(text.find("正文指标42"), std::string::npos);
  EXPECT_NE(text.find("实验数据：42"), std::string::npos);
  EXPECT_EQ(text.find("无关导航"), std::string::npos);
  EXPECT_EQ(text.find("表单标签"), std::string::npos);
  EXPECT_FALSE(read_only.truncated);
  // 合成同页对照仅验证裁剪实际发生，不代替完整任务集的输入收益指标。
  EXPECT_LT(text.size() * 10, Serialize(interactive).size() * 7);
}

TEST(AgentObservationTest, ButtonTextRetainsItsActualControlTarget) {
  proto::ContentNode root;
  for (int id : {15, 25}) {
    auto* button = root.add_children_nodes();
    auto* attributes = button->mutable_content_attributes();
    attributes->set_common_ancestor_dom_node_id(id);
    attributes->set_attribute_type(proto::CONTENT_ATTRIBUTE_FORM_CONTROL);
    attributes->mutable_form_control_data()->set_form_control_type(
        proto::FORM_CONTROL_TYPE_BUTTON_BUTTON);
    auto* nested = button->add_children_nodes();
    AddText(nested, id + 1, "执行操作");
    auto* hidden = AddText(button, id + 2, "秘密不能成为按钮标签");
    hidden->mutable_content_attributes()->add_annotated_roles(
        proto::ANNOTATED_ROLE_CONTENT_HIDDEN);
  }
  AddText(&root, 99, "执行操作");
  const auto result = BuildAgentObservationNodes(root, true);
  int verified = 0;
  for (const auto& item : result.nodes) {
    const auto& node = item.GetDict();
    const auto id = node.FindInt("node_id");
    if (!id) {
      continue;
    }
    if (*id == 99) {
      EXPECT_FALSE(node.Find("click_target_node_id"));
    } else {
      EXPECT_EQ(node.FindInt("click_target_node_id"), *id < 20 ? 15 : 25);
      ++verified;
    }
  }
  EXPECT_EQ(verified, 4);
  EXPECT_EQ(Serialize(result).find("秘密"), std::string::npos);
  const auto read_only = BuildAgentObservationNodes(root, false);
  ASSERT_EQ(read_only.nodes.size(), 1u);
  EXPECT_EQ(read_only.nodes[0].GetDict().FindInt("node_id"), 99);
}

TEST(AgentObservationTest, PreservesArticleMetadataWithoutSiteChromeOrSecrets) {
  proto::ContentNode root;
  auto* site = root.add_children_nodes();
  site->mutable_content_attributes()->add_annotated_roles(
      proto::ANNOTATED_ROLE_HEADER);
  AddText(site, 1, "站点菜单");
  auto* article = root.add_children_nodes();
  article->mutable_content_attributes()->add_annotated_roles(
      proto::ANNOTATED_ROLE_ARTICLE);
  auto* header = article->add_children_nodes();
  header->mutable_content_attributes()->add_annotated_roles(
      proto::ANNOTATED_ROLE_HEADER);
  AddText(header, 2, "作者：测试作者；日期：2026-09-16");
  AddText(article, 3, "指标42");
  auto* footer = article->add_children_nodes();
  footer->mutable_content_attributes()->add_annotated_roles(
      proto::ANNOTATED_ROLE_FOOTER);
  AddText(footer, 4, "方法注脚：三次测量取中位数");
  auto* form = footer->add_children_nodes();
  form->mutable_content_attributes()
      ->mutable_form_control_data()
      ->set_form_control_type(proto::FORM_CONTROL_TYPE_INPUT_PASSWORD);
  AddText(form, 5, "合成密码不能保留");
  auto* aside = article->add_children_nodes();
  aside->mutable_content_attributes()->add_annotated_roles(
      proto::ANNOTATED_ROLE_ASIDE);
  AddText(aside, 6, "推广旁注");
  const auto text = Serialize(BuildAgentObservationNodes(root, false));
  EXPECT_NE(text.find("测试作者"), std::string::npos);
  EXPECT_NE(text.find("2026-09-16"), std::string::npos);
  EXPECT_NE(text.find("三次测量取中位数"), std::string::npos);
  EXPECT_NE(text.find("指标42"), std::string::npos);
  EXPECT_EQ(text.find("站点菜单"), std::string::npos);
  EXPECT_EQ(text.find("合成密码"), std::string::npos);
  EXPECT_EQ(text.find("推广旁注"), std::string::npos);
}

TEST(AgentObservationTest, KeepsTextWhenThePageHasNoMainRole) {
  proto::ContentNode root;
  AddText(&root, 1, "没有main角色的普通正文");
  auto result = BuildAgentObservationNodes(root, false);
  ASSERT_EQ(result.nodes.size(), 1u);
  EXPECT_EQ(*result.nodes[0].GetDict().FindString("text"),
            "没有main角色的普通正文");
}

TEST(AgentObservationTest, SensitiveControlsRetainOnlyBlockingMetadata) {
  for (int scenario = 0; scenario < 3; ++scenario) {
    SCOPED_TRACE(scenario);
    proto::ContentNode root;
    auto* node = root.add_children_nodes();
    auto* attributes = node->mutable_content_attributes();
    attributes->set_attribute_type(proto::CONTENT_ATTRIBUTE_FORM_CONTROL);
    attributes->set_common_ancestor_dom_node_id(7);
    attributes->set_label("秘密标签canary-label");
    auto* control = attributes->mutable_form_control_data();
    control->set_placeholder("秘密占位canary-placeholder");
    control->set_form_control_type(scenario == 0
                                       ? proto::FORM_CONTROL_TYPE_INPUT_PASSWORD
                                       : proto::FORM_CONTROL_TYPE_INPUT_TEXT);
    if (scenario > 0) {
      control->add_coarse_autofill_field_type(
          scenario == 1 ? proto::COARSE_AUTOFILL_FIELD_TYPE_OTP
                        : proto::COARSE_AUTOFILL_FIELD_TYPE_CREDIT_CARD);
    }
    AddText(node, 8, "子树秘密canary-child");
    auto interactive = BuildAgentObservationNodes(root, true);
    ASSERT_EQ(interactive.nodes.size(), 1u);
    const auto& metadata = interactive.nodes[0].GetDict();
    EXPECT_EQ(metadata.FindInt("node_id"), 7);
    EXPECT_EQ(metadata.FindBool("is_sensitive_control"), true);
    EXPECT_FALSE(metadata.Find("text"));
    EXPECT_FALSE(metadata.Find("label"));
    EXPECT_EQ(Serialize(interactive).find("canary"), std::string::npos);
    EXPECT_TRUE(BuildAgentObservationNodes(root, false).nodes.empty());
  }
}

TEST(AgentObservationTest, OmitsFramesHiddenAndRedactedSubtrees) {
  proto::ContentNode root;
  auto* frame = root.add_children_nodes();
  frame->mutable_content_attributes()->mutable_iframe_data();
  AddText(frame, 1, "其他框架秘密");
  auto* hidden = root.add_children_nodes();
  hidden->mutable_content_attributes()->add_annotated_roles(
      proto::ANNOTATED_ROLE_CONTENT_HIDDEN);
  AddText(hidden, 2, "隐藏秘密");
  auto* redacted = root.add_children_nodes();
  redacted->mutable_content_attributes()->set_redaction_decision(
      proto::REDACTION_DECISION_REDACTED_IS_OTP);
  AddText(redacted, 3, "遮挡子树秘密");
  AddText(&root, 4, "可见正文");
  for (bool interactive : {false, true}) {
    auto result = BuildAgentObservationNodes(root, interactive);
    ASSERT_EQ(result.nodes.size(), 1u);
    EXPECT_EQ(Serialize(result).find("秘密"), std::string::npos);
    EXPECT_NE(Serialize(result).find("可见正文"), std::string::npos);
  }
}

TEST(AgentObservationTest, ReusesSecretRedactionAndPreservesByteLimits) {
  const std::string secret = "api_key=fixture-canary-secret123";
  auto text = BoundedAgentObservationText(secret, 2048);
  EXPECT_EQ(text.find("fixture-canary-secret123"), std::string::npos);
  EXPECT_NE(text.find("[REDACTED]"), std::string::npos);
  proto::ContentNode root;
  auto* node = AddText(&root, 1, secret);
  node->mutable_content_attributes()->set_label(secret);
  EXPECT_EQ(Serialize(BuildAgentObservationNodes(root, true))
                .find("fixture-canary-secret123"),
            std::string::npos);
  for (size_t remaining : {0u, 1u, 5u, 9u, 2048u}) {
    auto bounded = BoundedAgentObservationText(
        "中文内容" + std::string(3000, 'x'), remaining);
    EXPECT_LE(bounded.size(), remaining);
    EXPECT_TRUE(base::IsStringUTF8(bounded));
  }
}

TEST(AgentObservationTest, StopsAtNodeAndTextBudgets) {
  proto::ContentNode root;
  for (int i = 1; i <= 600; ++i)
    AddText(&root, i, "正文");
  auto result = BuildAgentObservationNodes(root, false);
  EXPECT_EQ(result.nodes.size(), 512u);
  EXPECT_TRUE(result.truncated);
  root.clear_children_nodes();
  for (int i = 1; i <= 100; ++i)
    AddText(&root, i, std::string(3000, 'x'));
  result = BuildAgentObservationNodes(root, false);
  EXPECT_TRUE(result.truncated);
  size_t bytes = 0;
  for (const auto& node : result.nodes) {
    const auto* text = node.GetDict().FindString("text");
    ASSERT_TRUE(text);
    EXPECT_LE(text->size(), 2048u);
    bytes += text->size();
  }
  EXPECT_LE(bytes, 128u * 1024u);
}
}  // namespace
}  // namespace aegis::agent
