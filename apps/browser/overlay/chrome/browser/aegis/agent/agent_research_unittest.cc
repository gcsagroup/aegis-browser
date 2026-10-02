// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_research.h"

#include "base/strings/string_number_conversions.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {
AgentToolResult Observation(int id,
                            std::string text = "测试文章的可核对完整正文") {
  AgentToolResult result;
  result.ok = true;
  result.value.Set("tab_id", id);
  result.value.Set("untrusted", true);
  result.value.Set("captured_at_ms", "1789530000000");
  result.value.Set("title", "测试文章");
  result.value.Set(
      "nodes",
      base::ListValue().Append(
          base::DictValue().Set("node_id", 1).Set("text", std::move(text))));
  return result;
}
AgentTaskScope ResearchScope() {
  AgentTaskScope scope;
  scope.selected_pages_research = true;
  scope.allowed_tab_ids = {1, 2, 3};
  scope.allowed_origins = {
      url::Origin::Create(GURL("https://fixture.example/"))};
  scope.allowed_tools = {"page.observe"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage};
  scope.model_destination.provider = "aegis-local";
  scope.model_destination.model = "fixture";
  return scope;
}
std::optional<base::DictValue> Record(bool partial = false) {
  auto scope = ResearchScope();
  std::map<int32_t, GURL> urls;
  std::vector<AgentExecutionEvidence> evidence;
  for (int id : scope.allowed_tab_ids) {
    urls.emplace(id,
                 GURL("https://fixture.example/" + base::NumberToString(id)));
    if (partial && id == 3) {
      continue;
    }
    evidence.push_back(
        {.tool_name = "page.observe", .result = Observation(id)});
  }
  AgentTask task("research-fixture", "比较三篇文章", AgentMode::kAct, scope);
  AgentCompletionSummary completion;
  completion.outcome = partial ? "partial" : "completed";
  completion.summary = "保留来源分歧";
  if (partial) {
    completion.unfinished_items = {"第三来源不可读"};
  }
  return BuildAgentResearchRecord(task, completion, evidence, urls);
}
TEST(AegisAgentResearchTest, HashIgnoresReloadIdsButDetectsChangedText) {
  auto before = Observation(1, "正文  一\n第二行");
  auto after = Observation(42, "正文 一 第二行");
  after.value.Set("document_id", "new-document");
  EXPECT_EQ(AgentResearchContentHash(before), AgentResearchContentHash(after));
  EXPECT_NE(AgentResearchContentHash(before),
            AgentResearchContentHash(Observation(1, "正文有变化")));
}
TEST(AegisAgentResearchTest, RejectsEmptyIncompleteAndUntrustedFlagMissing) {
  auto result = Observation(1, " ");
  EXPECT_FALSE(AgentResearchContentHash(result));
  result = Observation(1);
  result.value.Set("truncated", true);
  EXPECT_FALSE(AgentResearchContentHash(result));
  result.value.Remove("truncated");
  result.value.Remove("untrusted");
  EXPECT_FALSE(AgentResearchContentHash(result));
  result.value.Set("untrusted", true);
  result.ok = false;
  EXPECT_FALSE(AgentResearchContentHash(result));
}
TEST(AegisAgentResearchTest,
     StoresBoundSourcesAndPreservesUnavailablePartialSource) {
  auto complete = Record();
  ASSERT_TRUE(complete);
  ASSERT_EQ(complete->FindList("sources")->size(), 3u);
  EXPECT_EQ(
      complete->FindList("sources")->front().GetDict().FindBool("available"),
      true);
  auto partial = Record(true);
  ASSERT_TRUE(partial);
  EXPECT_EQ(
      partial->FindList("sources")->back().GetDict().FindBool("available"),
      false);
  EXPECT_EQ(partial->FindList("unfinished")->size(), 1u);
}
TEST(AegisAgentResearchTest, MissingSourceCannotBypassLifecycleScopeOrBudget) {
  AgentTask task("skip-fixture", "读取来源", AgentMode::kAct, ResearchScope());
  AgentToolCall call;
  call.tool_name = "page.observe";
  call.arguments.Set("tab_id", 1);
  AgentToolResult failure;
  failure.error = AgentErrorCode::kVerificationFailed;
  EXPECT_FALSE(CanSkipUnreadableResearchSource(task, call, failure, 3, true));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kPlanning, "测试"));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kAwaitingTaskConsent, "测试"));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kRunning, "测试"));
  EXPECT_TRUE(CanSkipUnreadableResearchSource(task, call, failure, 3, true));
  for (int attempt : {0, 1, 2, 4}) {
    EXPECT_FALSE(
        CanSkipUnreadableResearchSource(task, call, failure, attempt, true));
  }
  EXPECT_FALSE(CanSkipUnreadableResearchSource(task, call, failure, 3, false));
  for (const auto error :
       {AgentErrorCode::kScopeViolation, AgentErrorCode::kStaleDocument,
        AgentErrorCode::kBudgetExhausted, AgentErrorCode::kCancelled,
        AgentErrorCode::kApprovalRequired, AgentErrorCode::kInternal}) {
    failure.error = error;
    EXPECT_FALSE(CanSkipUnreadableResearchSource(task, call, failure, 3, true));
  }
  failure.error = AgentErrorCode::kVerificationFailed;
  call.tool_name = "page.click";
  EXPECT_FALSE(CanSkipUnreadableResearchSource(task, call, failure, 3, true));
  call.tool_name = "page.observe";
  call.arguments.Set("tab_id", 999);
  EXPECT_FALSE(CanSkipUnreadableResearchSource(task, call, failure, 3, true));
  call.arguments.Set("tab_id", 1);
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kReflecting, "测试"));
  EXPECT_TRUE(CanSkipUnreadableResearchSource(task, call, failure, 3, true));
  while (task.ConsumeToolCall()) {
  }
  EXPECT_FALSE(CanSkipUnreadableResearchSource(task, call, failure, 3, true));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kCancelled, "测试"));
  EXPECT_FALSE(CanSkipUnreadableResearchSource(task, call, failure, 3, true));
}

TEST(AegisAgentResearchTest,
     PartialResultKeepsFirstAndLastMissingSourceExplicit) {
  for (size_t missing : {0u, 2u}) {
    auto record = Record();
    ASSERT_TRUE(record);
    auto& source = (*record->FindList("sources"))[missing].GetDict();
    const auto url = *source.FindString("url");
    source.Set("available", false);
    source.Set("content_hash", "");
    source.Set("captured_ms", "");
    auto partial = BuildPartialResearchCompletion(*record);
    ASSERT_TRUE(partial);
    EXPECT_EQ(partial->source_urls.size(), 2u);
    EXPECT_EQ(partial->unfinished_items.front(), "未读取来源：" + url);
  }
  auto record = Record();
  ASSERT_TRUE(record);
  for (auto& item : *record->FindList("sources")) {
    item.GetDict().Set("excerpt", " ");
  }
  EXPECT_FALSE(BuildPartialResearchCompletion(*record));
}

TEST(AegisAgentResearchTest, PartialReadKeepsActualExcerptsAndMissingSources) {
  auto record = Record(true);
  ASSERT_TRUE(record);
  auto partial = BuildPartialResearchCompletion(*record);
  ASSERT_TRUE(partial);
  EXPECT_EQ(partial->outcome, "partial");
  EXPECT_EQ(partial->source_urls.size(), 2u);
  EXPECT_EQ(partial->unfinished_items.size(), 2u);
  EXPECT_NE(partial->summary.find("未完成完整比较"), std::string::npos);
  EXPECT_NE(partial->summary.find("测试文章的可核对完整正文"),
            std::string::npos);
  auto complete = Record();
  ASSERT_TRUE(complete);
  EXPECT_FALSE(BuildPartialResearchCompletion(*complete));
  for (auto& item : *record->FindList("sources")) {
    item.GetDict().Set("available", false);
    item.GetDict().Set("content_hash", "");
    item.GetDict().Set("captured_ms", "");
  }
  EXPECT_FALSE(BuildPartialResearchCompletion(*record));
}

TEST(AegisAgentResearchTest, PartialExcerptRetainsSplitInlineValuesAndBounds) {
  AgentTask task("split-inline", "比较三个来源", AgentMode::kAct,
                 ResearchScope());
  const std::map<int32_t, GURL> urls = {{1, GURL("https://fixture.example/1")},
                                        {2, GURL("https://fixture.example/2")},
                                        {3, GURL("https://fixture.example/3")}};
  AgentCompletionSummary completion;
  completion.outcome = "partial";
  completion.summary = "第三来源不可读";
  completion.unfinished_items = {"第三来源不可读"};
  auto first = Observation(1);
  first.value.Set("nodes", base::ListValue()
                               .Append(base::DictValue()
                                           .Set("text", "不应混入正文的标题")
                                           .Set("text_is_heading", true))
                               .Append(base::DictValue().Set(
                                   "text", "经该来源测得，稳定指标为 "))
                               .Append(base::DictValue().Set("text", "43"))
                               .Append(base::DictValue().Set(
                                   "text", "。方法：固定输入、三次测量。")));
  std::vector<AgentExecutionEvidence> evidence;
  evidence.push_back({.tool_name = "page.observe", .result = std::move(first)});
  evidence.push_back({.tool_name = "page.observe", .result = Observation(2)});
  auto record = BuildAgentResearchRecord(task, completion, evidence, urls);
  ASSERT_TRUE(record);
  auto partial = BuildPartialResearchCompletion(*record);
  ASSERT_TRUE(partial);
  EXPECT_NE(partial->summary.find("稳定指标为 43。方法"), std::string::npos);
  EXPECT_EQ(partial->summary.find("不应混入正文的标题"), std::string::npos);
  auto* nodes = evidence[0].result.value.FindList("nodes");
  nodes->Append(base::DictValue().Set("text", std::string(509, 'x') + "界"));
  record = BuildAgentResearchRecord(task, completion, evidence, urls);
  ASSERT_TRUE(record);
  EXPECT_LE(record->FindList("sources")
                ->front()
                .GetDict()
                .FindString("excerpt")
                ->size(),
            512u);
  EXPECT_TRUE(IsValidAgentResearchRecord(*record));
  auto headings = Observation(1);
  headings.value.FindList("nodes")->front().GetDict().Set("text_is_heading",
                                                          true);
  evidence.push_back(
      {.tool_name = "page.observe", .result = std::move(headings)});
  record = BuildAgentResearchRecord(task, completion, evidence, urls);
  ASSERT_TRUE(record);
  EXPECT_TRUE(record->FindList("sources")
                  ->front()
                  .GetDict()
                  .FindString("excerpt")
                  ->empty());
}

TEST(AegisAgentResearchTest, RejectsExpandedSchemaDuplicatesAndInvalidHash) {
  auto original = Record();
  ASSERT_TRUE(original);
  auto record = original->Clone();
  record.Set("unexpected", "field");
  EXPECT_FALSE(IsValidAgentResearchRecord(record));
  record = original->Clone();
  auto* sources = record.FindList("sources");
  (*sources)[1].GetDict().Set("url", "https://fixture.example/1");
  EXPECT_FALSE(IsValidAgentResearchRecord(record));
  record = original->Clone();
  record.FindList("sources")->front().GetDict().Set("content_hash",
                                                    "not-a-hash");
  EXPECT_FALSE(IsValidAgentResearchRecord(record));
  record = original->Clone();
  record.FindList("sources")->front().GetDict().Set(
      "url", "https://user:secret@fixture.example/");
  EXPECT_FALSE(IsValidAgentResearchRecord(record));
  record = original->Clone();
  record.FindList("unfinished")->Append("还未完成");
  EXPECT_FALSE(IsValidAgentResearchRecord(record));
}
struct ComparisonFixture {
  AgentTaskScope scope;
  std::map<int32_t, GURL> urls;
  std::vector<AgentExecutionEvidence> evidence;
  AgentCompletionSummary completion{
      .outcome = "completed",
      .summary = "错误结论：七个一致，第十来源为例外"};
  explicit ComparisonFixture(std::vector<std::string> values)
      : scope(ResearchScope()) {
    scope.allowed_tab_ids.clear();
    scope.budgets.max_tabs = 10;
    AgentResearchComparison dimension{
        .label = "延迟", .prefix = "延迟：", .suffix = "。"};
    int id = 0;
    for (const auto& value : values) {
      ++id;
      scope.allowed_tab_ids.insert(id);
      const GURL url("https://fixture.example/" + base::NumberToString(id));
      urls.emplace(id, url);
      auto observed =
          Observation(id, "延迟：" + value + "。使用相同测量方法。");
      observed.value.Set("url", url.spec());
      evidence.push_back(
          {.tool_name = "page.observe", .result = std::move(observed)});
      dimension.values.push_back({.source_url = url.spec(), .value = value});
      completion.source_urls.push_back(url.spec());
    }
    completion.research_comparisons.push_back(std::move(dimension));
  }
  void Run() {
    AgentTask task("comparison", "比较所选来源的延迟及例外", AgentMode::kAct,
                   scope);
    NormalizeAgentResearchComparison(&completion, task, evidence, urls);
  }
};
TEST(AegisAgentResearchTest, NativeGroupsReplaceIncorrectTenSourceProse) {
  ComparisonFixture fixture({"18 ms", "18 ms", "18 ms", "18 ms", "21 ms",
                             "18 ms", "18 ms", "17 ms", "18 ms", "18 ms"});
  fixture.Run();
  EXPECT_EQ(fixture.completion.outcome, "completed");
  const auto& text = fixture.completion.summary;
  EXPECT_EQ(text.find("错误结论"), std::string::npos);
  EXPECT_NE(
      text.find("“18 ms”：8 个来源 [1]、[2]、[3]、[4]、[6]、[7]、[9]、[10]"),
      std::string::npos);
  EXPECT_NE(text.find("“21 ms”：1 个来源 [5]（与多数来源不同）"),
            std::string::npos);
  EXPECT_NE(text.find("“17 ms”：1 个来源 [8]（与多数来源不同）"),
            std::string::npos);
}
TEST(AegisAgentResearchTest, PreviouslyRejectedStableMetricBoundaries) {
  // 050 实机两次响应都漏掉了“为”后的空格，值及完整上下文没有错误。
  for (const auto& values : {std::vector<std::string>{"42", "42", "42"},
                             std::vector<std::string>{"42", "43", "41"}}) {
    ComparisonFixture fixture(values);
    auto& dimension = fixture.completion.research_comparisons[0];
    dimension.label = "稳定指标";
    dimension.prefix = "经该来源测得，稳定指标为";
    for (size_t i = 0; i < values.size(); ++i) {
      fixture.evidence[i].result.value.FindList("nodes")->front().GetDict().Set(
          "text", "经该来源测得，稳定指标为 " + values[i] + "。");
    }
    fixture.Run();
    EXPECT_EQ(fixture.completion.outcome, "completed");
    EXPECT_NE(fixture.completion.summary.find(values[0] == values[1]
                                                  ? "3 个来源 [1]、[2]、[3]"
                                                  : "不指定多数值或例外组"),
              std::string::npos);
  }
}
TEST(AegisAgentResearchTest, BoundaryWhitespaceDoesNotSplitEqualGroups) {
  for (const std::string whitespace : {"", " ", "\t\n  "}) {
    SCOPED_TRACE(whitespace);
    ComparisonFixture fixture({"18 ms", "18 ms", "18 ms"});
    auto& dimension = fixture.completion.research_comparisons[0];
    dimension.prefix += whitespace;
    dimension.suffix = whitespace + dimension.suffix;
    dimension.values[0].value = whitespace + "18 ms";
    dimension.values[1].value = "18 ms" + whitespace;
    for (size_t i = 0; i < fixture.evidence.size(); ++i) {
      const std::string gap = i == 0 ? "" : i == 1 ? " " : "\t\n";
      fixture.evidence[i].result.value.FindList("nodes")->front().GetDict().Set(
          "text", "延迟：" + gap + "18 ms" + gap + "。");
    }
    fixture.Run();
    EXPECT_EQ(fixture.completion.outcome, "completed");
    EXPECT_NE(fixture.completion.summary.find("“18 ms”：3 个来源"),
              std::string::npos);
  }
}
TEST(AegisAgentResearchTest, BoundaryWhitespaceUsesActualWordPositions) {
  for (bool joined : {false, true}) {
    ComparisonFixture fixture({"18 ms", "18 ms", "18 ms"});
    auto& dimension = fixture.completion.research_comparisons[0];
    dimension.label = "latency";
    dimension.prefix = "latency ";
    for (auto& item : fixture.evidence) {
      item.result.value.FindList("nodes")->front().GetDict().Set(
          "text", joined ? "latency18 ms。" : "latency 18 ms。");
    }
    fixture.Run();
    EXPECT_EQ(fixture.completion.outcome, joined ? "partial" : "completed");
  }
}
TEST(AegisAgentResearchTest, BoundaryWhitespaceCannotAlterValueOrContext) {
  const std::vector<std::pair<std::string, std::string>> cases = {
      {"142", "42"}, {"18.5", "18"}, {"18 ms", "18"},    {"18 ms", "18 s"},
      {"1 2", "12"}, {"12", "1 2"},  {"不支持", "支持"}, {"18ms", "18 ms"}};
  for (const auto& [observed, claimed] : cases) {
    SCOPED_TRACE(observed + " / " + claimed);
    ComparisonFixture fixture({observed, observed, observed});
    auto& dimension = fixture.completion.research_comparisons[0];
    dimension.prefix += " ";
    for (auto& cell : dimension.values)
      cell.value = claimed;
    fixture.Run();
    EXPECT_EQ(fixture.completion.outcome, "partial");
    EXPECT_EQ(fixture.completion.summary.find("3 个来源"), std::string::npos);
  }
  ComparisonFixture context({"42", "42", "42"});
  context.completion.research_comparisons[0].prefix = "延 迟： ";
  context.Run();
  EXPECT_EQ(context.completion.outcome, "partial");
}
TEST(AegisAgentResearchTest, RepeatedFieldsShareBoundaryWhitespaceRules) {
  for (const std::string repeated : {"18 ms", "21 ms"}) {
    ComparisonFixture fixture({"18 ms", "18 ms", "18 ms"});
    fixture.completion.research_comparisons[0].prefix += " ";
    fixture.evidence[0].result.value.FindList("nodes")->Append(
        base::DictValue()
            .Set("node_id", 2)
            .Set("text", "更新后延迟：\t" + repeated + " 。"));
    fixture.Run();
    EXPECT_EQ(fixture.completion.outcome,
              repeated == "18 ms" ? "completed" : "partial");
  }
}
TEST(AegisAgentResearchTest,
     RejectsInventedSwappedDuplicatedAndPartialTokenValues) {
  for (int scenario = 0; scenario < 8; ++scenario) {
    SCOPED_TRACE(scenario);
    ComparisonFixture fixture({"142", "42", "42"});
    auto& dimension = fixture.completion.research_comparisons[0];
    if (scenario == 0)
      dimension.values[0].value = "42";
    if (scenario == 1)
      std::swap(dimension.values[0].value, dimension.values[1].value);
    if (scenario == 2)
      dimension.values[0].source_url = dimension.values[1].source_url;
    if (scenario == 3)
      dimension.values.pop_back();
    if (scenario == 4)
      dimension.label = "无关的吞吐率";
    if (scenario == 5) {
      dimension.prefix = "延迟：1";
      dimension.values[0].value = "42";
    }
    if (scenario == 6)
      dimension.prefix = "";
    if (scenario == 7)
      fixture.completion.research_comparisons.clear();
    fixture.Run();
    EXPECT_EQ(fixture.completion.outcome, "partial");
    EXPECT_EQ(fixture.completion.summary.find("错误结论"), std::string::npos);
    EXPECT_EQ(fixture.completion.summary.find("（与多数来源不同）"),
              std::string::npos);
    EXPECT_FALSE(fixture.completion.unfinished_items.empty());
  }
}
TEST(AegisAgentResearchTest, MissingOrStaleSourcesAreNotExceptions) {
  for (int scenario = 0; scenario < 5; ++scenario) {
    SCOPED_TRACE(scenario);
    ComparisonFixture fixture({"18 ms", "18 ms", "18 ms"});
    auto& result = fixture.evidence.back().result;
    if (scenario == 0)
      result.ok = false;
    if (scenario == 1)
      result.value.Set("truncated", true);
    if (scenario == 2)
      result.value.Set("url", "https://fixture.example/changed");
    if (scenario == 3)
      fixture.completion.research_comparisons[0].values.back().value.clear();
    if (scenario == 4) {
      auto stale = Observation(3, "旧网页");
      stale.value.Set("url", "https://fixture.example/3");
      stale.ok = false;
      fixture.evidence.push_back(
          {.tool_name = "page.observe", .result = std::move(stale)});
    }
    fixture.Run();
    EXPECT_EQ(fixture.completion.outcome, "partial");
    EXPECT_NE(fixture.completion.summary.find("待核实：[3]"),
              std::string::npos);
    EXPECT_EQ(fixture.completion.summary.find("（与多数来源不同）"),
              std::string::npos);
  }
}
TEST(AegisAgentResearchTest, TiesAndAllEqualGroupsDoNotInventExceptions) {
  ComparisonFixture tie({"18 ms", "20 ms", "22 ms"});
  tie.Run();
  EXPECT_EQ(tie.completion.outcome, "completed");
  EXPECT_NE(tie.completion.summary.find("不指定多数值或例外组"),
            std::string::npos);
  ComparisonFixture equal({"18 ms", "18 ms", "18 ms"});
  equal.Run();
  EXPECT_EQ(equal.completion.outcome, "completed");
  EXPECT_NE(equal.completion.summary.find("3 个来源 [1]、[2]、[3]"),
            std::string::npos);
  EXPECT_EQ(equal.completion.summary.find("（与多数来源不同）"),
            std::string::npos);
}
TEST(AegisAgentResearchTest, RepeatedConflictingFieldIsNotCherryPicked) {
  ComparisonFixture fixture({"18 ms", "18 ms", "18 ms"});
  fixture.evidence[0].result.value.FindList("nodes")->Append(
      base::DictValue().Set("node_id", 2).Set("text", "更新后延迟：21 ms。"));
  fixture.Run();
  EXPECT_EQ(fixture.completion.outcome, "partial");
  EXPECT_EQ(fixture.completion.summary.find("3 个来源"), std::string::npos);
}
TEST(AegisAgentResearchTest,
     InlineNodesAndSavedContentUseSameVerifiedComparison) {
  ComparisonFixture fixture({"18 ms", "18 ms", "21 ms"});
  fixture.evidence[0].result.value.Set(
      "nodes",
      base::ListValue()
          .Append(base::DictValue().Set("node_id", 1).Set("text", "延迟："))
          .Append(base::DictValue().Set("node_id", 2).Set("text", "18 ms"))
          .Append(base::DictValue().Set("node_id", 3).Set("text", "。")));
  fixture.Run();
  ASSERT_EQ(fixture.completion.outcome, "completed");
  AgentTask task("saved", "比较延迟并保存", AgentMode::kAct, fixture.scope);
  auto record = BuildAgentResearchRecord(task, fixture.completion,
                                         fixture.evidence, fixture.urls);
  ASSERT_TRUE(record);
  EXPECT_EQ(*record->FindString("summary"), fixture.completion.summary);
  UpdateAgentResearchSaveCompletion(&fixture.completion, task, false);
  EXPECT_EQ(fixture.completion.outcome, "partial");
  UpdateAgentResearchSaveCompletion(&fixture.completion, task, true);
  EXPECT_EQ(fixture.completion.outcome, "completed");
  EXPECT_EQ(*record->FindString("summary"), fixture.completion.summary);
}

}  // namespace
}  // namespace aegis::agent
