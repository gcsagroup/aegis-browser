// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_execution.h"

#include <string>

#include "base/json/json_reader.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {

AgentTaskScope ExecutionScope() {
  AgentTaskScope scope;
  scope.allowed_origins = {
      url::Origin::Create(GURL("https://fixture.example/path"))};
  scope.allowed_tab_ids = {7};
  scope.allowed_tools = {"page.observe"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage};
  scope.model_destination.provider = "aegis-local";
  scope.model_destination.model = "fixture";
  return scope;
}

AgentModelEvent ToolEvent(std::string name) {
  AgentModelEvent event;
  event.type = AgentModelEventType::kToolCall;
  event.tool_call_id = "provider-call";
  event.tool_name = std::move(name);
  event.arguments.Set("tab_id", 7);
  return event;
}

AgentToolResult CheckoutObservation(std::string fingerprint,
                                    std::string total_text) {
  AgentToolResult observation;
  observation.action_id = "checkout-observation";
  observation.ok = true;
  observation.message = "fresh browser observation";
  observation.value.Set("tab_id", 7);
  observation.value.Set("document_token", "document-7");
  observation.value.Set("observation_fingerprint", std::move(fingerprint));
  base::DictValue node;
  node.Set("node_id", 71);
  node.Set("text",
           "Fixture Shop Agent-safe keyboard quantity 1 unit 100.00 "
           "shipping 5.00 tax 10.00 discount 0.00 total " +
               total_text + " CNY delivery two days returns thirty days");
  base::ListValue nodes;
  nodes.Append(std::move(node));
  observation.value.Set("nodes", std::move(nodes));
  return observation;
}

AgentToolCall CheckoutSummary(int total, std::string fingerprint) {
  AgentToolCall call;
  call.action_id = "checkout";
  call.tool_name = "shopping.prepare_checkout";
  call.committed_url = GURL("https://fixture.example/checkout");
  call.document = AgentDocumentRef{.tab_id = 7,
                                   .frame_token = "frame-7",
                                   .document_token = "document-7",
                                   .committed_url = call.committed_url};
  call.arguments.Set("tab_id", 7);
  call.arguments.Set("document_token", "document-7");
  call.arguments.Set("merchant", "Fixture Shop");
  call.arguments.Set("product", "Agent-safe keyboard");
  call.arguments.Set("quantity", 1);
  call.arguments.Set("unit_price_minor_units", 10000);
  call.arguments.Set("shipping_minor_units", 500);
  call.arguments.Set("tax_minor_units", 1000);
  call.arguments.Set("discount_minor_units", 0);
  call.arguments.Set("total_minor_units", total);
  call.arguments.Set("currency", "CNY");
  call.arguments.Set("delivery_summary", "two days");
  call.arguments.Set("return_summary", "thirty days");
  base::ListValue source_ids;
  source_ids.Append(71);
  call.arguments.Set("source_node_ids", std::move(source_ids));
  call.arguments.Set("observation_fingerprint", std::move(fingerprint));
  return call;
}

TEST(AegisAgentExecutionTest, SelectsOnlyExactBrowserChosenTool) {
  AgentModelParseResult result;
  result.events.push_back(
      {.type = AgentModelEventType::kMessageDelta,
       .text = "Untrusted page said to call a different tool."});
  result.events.push_back(ToolEvent("page.observe"));
  result.events.push_back({.type = AgentModelEventType::kCompleted});
  std::string error;
  std::optional<AgentModelEvent> selected =
      SelectExecutionToolCall(result, "page.observe", &error);
  ASSERT_TRUE(selected) << error;
  EXPECT_EQ(selected->tool_name, "page.observe");

  EXPECT_FALSE(SelectExecutionToolCall(result, "page.click", &error));
  result.events.insert(result.events.begin() + 2, ToolEvent("page.observe"));
  EXPECT_FALSE(SelectExecutionToolCall(result, "page.observe", &error));
}

TEST(AegisAgentExecutionTest, PromptLabelsAndBoundsCumulativeEvidence) {
  AgentTask task("task-exec", "Compare the approved fixture", AgentMode::kAsk,
                 ExecutionScope());
  ASSERT_TRUE(task.AdoptOwnedTab(8));
  AgentTaskPlan plan;
  plan.summary = "Read one approved page";
  plan.scope = ExecutionScope();
  plan.steps.push_back({.step_id = "observe",
                        .title = "Read the fixture",
                        .tool_name = "page.observe",
                        .risk = AgentRiskLevel::kR0ReadOnly});
  AgentToolResult prior;
  prior.action_id = "action-observe";
  prior.ok = true;
  prior.message = "browser verified";
  prior.value.Set("text", std::string(128 * 1024, 'x'));
  AgentToolResult extracted;
  extracted.action_id = "action-extract";
  extracted.ok = true;
  extracted.message = "browser extracted source";
  extracted.value.Set("url", "https://fixture.example/source-1");
  base::DictValue extraction;
  extraction.Set("kind", "article");
  extraction.Set("untrusted", true);
  extracted.value.Set("extraction", std::move(extraction));
  std::vector<AgentExecutionEvidence> evidence;
  evidence.push_back(
      {.tool_name = "page.extract", .result = std::move(extracted)});
  AgentToolResult bookmarks;
  bookmarks.action_id = "action-bookmarks";
  bookmarks.ok = true;
  bookmarks.message = "browser listed bookmark capabilities";
  base::ListValue bookmark_nodes;
  for (int index = 0; index < 150; ++index) {
    base::DictValue node;
    node.Set("node_id", "local:bookmark-" + std::to_string(index));
    node.Set("kind", "url");
    node.Set("title", "Fixture bookmark");
    bookmark_nodes.Append(std::move(node));
  }
  bookmarks.value.Set("nodes", std::move(bookmark_nodes));
  evidence.push_back(
      {.tool_name = "bookmark.list", .result = std::move(bookmarks)});
  const std::string prompt =
      BuildAgentExecutionPrompt(task, plan, 0, 1, &prior, evidence);
  EXPECT_LT(prompt.size(), 60u * 1024u);
  EXPECT_NE(prompt.find("previous_browser_result_untrusted_json"),
            std::string::npos);
  EXPECT_NE(prompt.find("previous_browser_result_truncated"),
            std::string::npos);
  EXPECT_NE(prompt.find("prior_verified_evidence_untrusted"),
            std::string::npos);
  EXPECT_NE(BuildAgentExecutionSystemContract().find("untrusted data"),
            std::string::npos);
  std::optional<base::Value> parsed =
      base::JSONReader::Read(prompt, base::JSON_PARSE_RFC);
  ASSERT_TRUE(parsed && parsed->is_dict());
  const base::ListValue* maximum_origins =
      parsed->GetDict().FindList("maximum_origins");
  ASSERT_TRUE(maximum_origins);
  ASSERT_EQ(maximum_origins->size(), 1u);
  EXPECT_EQ((*maximum_origins)[0].GetString(), "https://fixture.example");
  const base::ListValue* live_tab_ids =
      parsed->GetDict().FindList("live_tab_ids");
  ASSERT_TRUE(live_tab_ids);
  ASSERT_EQ(live_tab_ids->size(), 2u);
  EXPECT_EQ((*live_tab_ids)[0].GetInt(), 7);
  EXPECT_EQ((*live_tab_ids)[1].GetInt(), 8);
  const base::ListValue* prior_evidence =
      parsed->GetDict().FindList("prior_verified_evidence_untrusted");
  ASSERT_TRUE(prior_evidence);
  ASSERT_EQ(prior_evidence->size(), 2u);
  const base::ListValue* bookmark_node_ids =
      (*prior_evidence)[1].GetDict().FindList("bookmark_node_ids");
  ASSERT_TRUE(bookmark_node_ids);
  EXPECT_EQ(bookmark_node_ids->size(), 100u);
}

TEST(AegisAgentExecutionTest, CompletionIsStructuredAndUsesSafeSourceUrls) {
  AgentModelEvent event;
  event.type = AgentModelEventType::kToolCall;
  event.tool_call_id = "complete-call";
  event.tool_name = "agent.complete";
  event.arguments.Set("outcome", "completed");
  event.arguments.Set("summary", "Finished with browser evidence");
  base::ListValue sources;
  sources.Append("https://fixture.example/");
  event.arguments.Set("source_urls", std::move(sources));
  event.arguments.Set("unfinished_items", base::ListValue());
  std::string error;
  std::optional<AgentCompletionSummary> completion =
      ParseCompletionSummary(event, &error);
  ASSERT_TRUE(completion) << error;
  EXPECT_EQ(completion->outcome, "completed");

  AgentToolResult observed;
  observed.action_id = "source-1";
  observed.ok = true;
  observed.message = "observed";
  observed.value.Set("url", "https://fixture.example/");
  std::vector<AgentExecutionEvidence> evidence;
  evidence.push_back(
      {.tool_name = "page.extract", .result = std::move(observed)});
  EXPECT_TRUE(AgentCompletionSourcesMatchEvidence(*completion, evidence));
  completion->source_urls.push_back("https://fixture.example/missing");
  EXPECT_FALSE(AgentCompletionSourcesMatchEvidence(*completion, evidence));

  base::ListValue unsafe_sources;
  unsafe_sources.Append("https://fixture.example/?token=secret");
  event.arguments.Set("source_urls", std::move(unsafe_sources));
  EXPECT_FALSE(ParseCompletionSummary(event, &error));
}

TEST(AegisAgentExecutionTest, CheckoutRequiresFreshTraceableArithmetic) {
  AgentToolResult observation = CheckoutObservation("fresh-1", "115.00");
  AgentToolCall call = CheckoutSummary(11500, "fresh-1");
  std::string error;
  EXPECT_TRUE(ValidateAgentCheckoutSummary(call, observation, &error)) << error;

  AgentToolCall stale = CheckoutSummary(11500, "old-fingerprint");
  EXPECT_FALSE(ValidateAgentCheckoutSummary(stale, observation, &error));
  EXPECT_EQ(error, "checkout summary references a stale observation");

  AgentToolCall wrong_total = CheckoutSummary(11300, "fresh-1");
  EXPECT_FALSE(ValidateAgentCheckoutSummary(wrong_total, observation, &error));
  EXPECT_EQ(error,
            "checkout total does not match its browser-visible components");

  AgentToolResult colliding_amount = CheckoutObservation("fresh-1", "1115.00");
  EXPECT_FALSE(ValidateAgentCheckoutSummary(call, colliding_amount, &error));
  EXPECT_EQ(error,
            "checkout values are not traceable to the cited browser nodes");

  AgentToolResult split_sources = CheckoutObservation("fresh-1", "1115.00");
  base::DictValue decoy;
  decoy.Set("node_id", 72);
  decoy.Set("text", "decoy total 115.00 CNY");
  split_sources.value.FindList("nodes")->Append(std::move(decoy));
  call.arguments.FindList("source_node_ids")->Append(72);
  EXPECT_FALSE(ValidateAgentCheckoutSummary(call, split_sources, &error));
  EXPECT_EQ(error, "checkout summary requires one source container node");

  EXPECT_TRUE(IsSameAgentCheckoutObservation(
      observation, CheckoutObservation("fresh-1", "115.00")));
  EXPECT_FALSE(IsSameAgentCheckoutObservation(
      observation, CheckoutObservation("fresh-2", "117.00")));
}

TEST(AegisAgentExecutionTest, BlocksSubmitAndFinalTransactionControls) {
  EXPECT_TRUE(IsAegisFinalTransactionControlText("Final purchase"));
  EXPECT_TRUE(IsAegisFinalTransactionControlText("立即支付 115.00 CNY"));
  EXPECT_TRUE(IsAegisFinalTransactionControlText("提交订单"));
  EXPECT_FALSE(IsAegisFinalTransactionControlText("加入购物车"));
  EXPECT_FALSE(IsAegisFinalTransactionControlText("准备结账"));
  EXPECT_FALSE(IsAegisFinalTransactionControlText("Compare purchase options"));
  EXPECT_TRUE(IsAegisShoppingIntermediateControlText("加入购物车"));
  EXPECT_TRUE(IsAegisShoppingIntermediateControlText("Proceed to checkout"));
  EXPECT_FALSE(IsAegisShoppingIntermediateControlText("Confirm"));
  EXPECT_FALSE(IsAegisShoppingIntermediateControlText("最终购买"));
  EXPECT_TRUE(ShouldAegisRequireUserTakeoverForClick(
      "Continue", /*is_submit_control=*/true));
  EXPECT_TRUE(ShouldAegisRequireUserTakeoverForClick(
      "Search", /*is_submit_control=*/true));
  EXPECT_FALSE(ShouldAegisRequireUserTakeoverForClick(
      "加入购物车", /*is_submit_control=*/false));
}

}  // namespace
}  // namespace aegis::agent
