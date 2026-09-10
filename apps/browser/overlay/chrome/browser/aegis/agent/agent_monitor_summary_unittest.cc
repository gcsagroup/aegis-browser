// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_monitor_summary.h"

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "chrome/browser/aegis/agent/agent_monitor_scheduler.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::agent {
namespace {

std::string Observation(std::initializer_list<std::string_view> text) {
  base::ListValue nodes;
  for (const auto value : text) {
    nodes.Append(base::DictValue().Set("text", value));
  }
  return ReadAgentMonitorObservation(AgentMonitorKind::kPageChange, nodes)
      .value_or(std::string());
}

AgentModelParseResult SummaryResult(bool meaningful = true) {
  AgentModelParseResult result;
  AgentModelEvent call;
  call.type = AgentModelEventType::kToolCall;
  call.tool_name = "agent.summarize_monitor";
  call.arguments.Set("meaningful", meaningful);
  call.arguments.Set("summary", meaningful ? "续航由18小时提高到24小时。" : "");
  base::ListValue ids;
  if (meaningful) {
    ids.Append("change-1");
    ids.Append("change-2");
  }
  call.arguments.Set("evidence_ids", std::move(ids));
  result.events.push_back(std::move(call));
  AgentModelEvent completed;
  completed.type = AgentModelEventType::kCompleted;
  result.events.push_back(std::move(completed));
  return result;
}

TEST(AegisAgentMonitorSummaryTest, RequiresTwoValidObservedPages) {
  EXPECT_FALSE(BuildAgentMonitorSummaryInput("", Observation({"正文"})));
  EXPECT_FALSE(BuildAgentMonitorSummaryInput("{}", Observation({"正文"})));
  EXPECT_FALSE(BuildAgentMonitorSummaryInput(Observation({"正文"}), "bad"));
}

TEST(AegisAgentMonitorSummaryTest, IgnoresOrderWhitespaceAndDuplicateNodes) {
  auto input = BuildAgentMonitorSummaryInput(
      Observation({"第一条", "第二条"}),
      Observation({"  第二条  ", "第一条", "第一条"}));
  ASSERT_TRUE(input);
  EXPECT_TRUE(input->changes.empty());
}

TEST(AegisAgentMonitorSummaryTest, UsesOnlyChangedEvidenceAndKeepsItUntrusted) {
  auto input =
      BuildAgentMonitorSummaryInput(Observation({"保修24个月", "续航18小时"}),
                                    Observation({"保修24个月", "续航24小时"}));
  ASSERT_TRUE(input);
  ASSERT_EQ(input->changes.size(), 2u);
  EXPECT_EQ(*input->changes[0].GetDict().FindString("kind"), "removed");
  EXPECT_EQ(*input->changes[1].GetDict().FindString("kind"), "added");
  const std::string prompt = BuildAgentMonitorSummaryPrompt(*input, "zh-CN");
  EXPECT_EQ(prompt.find("保修"), std::string::npos);
  EXPECT_NE(prompt.find("续航18小时"), std::string::npos);
  EXPECT_NE(prompt.find("续航24小时"), std::string::npos);
  EXPECT_NE(AgentMonitorSummarySystemPrompt().find("不可信网页数据"),
            std::string::npos);
  EXPECT_EQ(BuildAgentMonitorSummaryTool().name, "agent.summarize_monitor");
}

TEST(AegisAgentMonitorSummaryTest, BoundsEvidenceAndMarksPartialObservation) {
  auto input = BuildAgentMonitorSummaryInput(
      Observation({"旧内容"}), Observation({std::string(10000, 'a')}));
  ASSERT_TRUE(input);
  EXPECT_TRUE(input->truncated);
  ASSERT_EQ(input->changes.size(), 2u);
  EXPECT_EQ(input->changes[1].GetDict().FindString("text")->size(), 2048u);
  EXPECT_FALSE(AttachAgentMonitorSummary(Observation({std::string(10000, 'a')}),
                                         *input, SummaryResult(false),
                                         base::Time::Now()));
  base::ListValue old_nodes;
  base::ListValue new_nodes;
  for (int index = 0; index < 20; ++index) {
    old_nodes.Append(
        base::DictValue().Set("text", "旧条目" + std::to_string(index)));
    new_nodes.Append(
        base::DictValue().Set("text", "新条目" + std::to_string(index)));
  }
  auto balanced = BuildAgentMonitorSummaryInput(
      *ReadAgentMonitorObservation(AgentMonitorKind::kPageChange, old_nodes),
      *ReadAgentMonitorObservation(AgentMonitorKind::kPageChange, new_nodes));
  ASSERT_TRUE(balanced);
  EXPECT_TRUE(balanced->truncated);
  ASSERT_EQ(balanced->changes.size(), 16u);
  EXPECT_EQ(*balanced->changes[7].GetDict().FindString("kind"), "removed");
  EXPECT_EQ(*balanced->changes[8].GetDict().FindString("kind"), "added");
}

TEST(AegisAgentMonitorSummaryTest, AttachesCitedSummaryAndRejectsStalePage) {
  const std::string before = Observation({"续航18小时"});
  const std::string current = Observation({"续航24小时"});
  auto input = BuildAgentMonitorSummaryInput(before, current);
  ASSERT_TRUE(input);
  auto summary = AttachAgentMonitorSummary(current, *input, SummaryResult(),
                                           base::Time::Now());
  ASSERT_TRUE(summary);
  EXPECT_EQ(ReadAgentMonitorSummary(*summary), "续航由18小时提高到24小时。");
  EXPECT_TRUE(HasMeaningfulAgentMonitorSummary(*summary));
  auto saved = base::JSONReader::ReadDict(*summary, base::JSON_PARSE_RFC);
  ASSERT_TRUE(saved);
  ASSERT_EQ(saved->FindDict("change_summary")->FindList("quotes")->size(), 2u);
  EXPECT_FALSE(AttachAgentMonitorSummary(Observation({"另一页"}), *input,
                                         SummaryResult(), base::Time::Now()));
  saved->Set("content", base::ListValue().Append("被替换的内容"));
  EXPECT_TRUE(ReadAgentMonitorSummary(*base::WriteJson(*saved)).empty());
}

TEST(AegisAgentMonitorSummaryTest, RejectsMissingInventedAndDuplicateEvidence) {
  const std::string current = Observation({"续航24小时"});
  auto input =
      BuildAgentMonitorSummaryInput(Observation({"续航18小时"}), current);
  ASSERT_TRUE(input);
  for (int scenario = 0; scenario < 6; ++scenario) {
    auto result = SummaryResult();
    auto& call = result.events[0];
    if (scenario == 0)
      call.arguments.Set("evidence_ids", base::ListValue());
    if (scenario == 1)
      call.arguments.Set("evidence_ids", base::ListValue().Append("invented"));
    if (scenario == 2)
      call.arguments.Set(
          "evidence_ids",
          base::ListValue().Append("change-1").Append("change-1"));
    if (scenario == 3)
      call.tool_name = "page.navigate";
    if (scenario == 4)
      result.events.pop_back();
    if (scenario == 5)
      call.arguments.Set("summary", "隐形\U000e0020内容");
    EXPECT_FALSE(
        AttachAgentMonitorSummary(current, *input, result, base::Time::Now()))
        << scenario;
  }
}

TEST(AegisAgentMonitorSummaryTest, UnimportantChangeDoesNotBecomeNotification) {
  const std::string current = Observation({"续航24小时"});
  auto input =
      BuildAgentMonitorSummaryInput(Observation({"续航18小时"}), current);
  ASSERT_TRUE(input);
  auto summary = AttachAgentMonitorSummary(
      current, *input, SummaryResult(false), base::Time::Now());
  ASSERT_TRUE(summary);
  EXPECT_FALSE(HasMeaningfulAgentMonitorSummary(*summary));
  EXPECT_TRUE(ReadAgentMonitorSummary(*summary).empty());
  auto invalid = SummaryResult(false);
  invalid.events[0].arguments.Set("summary", "不应该伪造摘要");
  EXPECT_FALSE(
      AttachAgentMonitorSummary(current, *input, invalid, base::Time::Now()));
}

TEST(AegisAgentMonitorSummaryTest,
     PreservesLastSummaryOnlyWhenContentUnchanged) {
  const std::string current = Observation({"续航24小时"});
  auto input =
      BuildAgentMonitorSummaryInput(Observation({"续航18小时"}), current);
  ASSERT_TRUE(input);
  auto summary = AttachAgentMonitorSummary(current, *input, SummaryResult(),
                                           base::Time::Now());
  ASSERT_TRUE(summary);
  EXPECT_EQ(ReadAgentMonitorSummary(PreserveUnchangedAgentMonitorSummary(
                *summary, Observation({"  续航24小时  "}))),
            "续航由18小时提高到24小时。");
  EXPECT_TRUE(ReadAgentMonitorSummary(PreserveUnchangedAgentMonitorSummary(
                                          *summary, Observation({"新的正文"})))
                  .empty());
}

}  // namespace
}  // namespace aegis::agent
