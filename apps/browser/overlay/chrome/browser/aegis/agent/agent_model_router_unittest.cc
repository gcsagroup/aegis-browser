// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_model_router.h"

#include <optional>
#include <string>

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::agent {
namespace {

AgentModelDestination Destination(std::string model,
                                  AgentModelDestination::Kind kind =
                                      AgentModelDestination::Kind::kCloud) {
  return {.kind = kind,
          .provider = "openai",
          .endpoint = kind == AgentModelDestination::Kind::kCloud
                          ? "https://models.example.test/v1"
                          : kind == AgentModelDestination::Kind::kLoopback
                                ? "http://127.0.0.1:8765/v1"
                                : "",
          .model = std::move(model)};
}

AgentModelCatalogEntry Entry(std::string id,
                             AgentModelDestination destination,
                             int quality,
                             int latency,
                             std::optional<int64_t> cost,
                             int priority = 0) {
  return {.id = std::move(id),
          .destination = std::move(destination),
          .enabled = true,
          .authorized = true,
          .supports_tool_calls = true,
          .supports_long_context = true,
          .supports_strong_reasoning = true,
          .quality_score = quality,
          .latency_score = latency,
          .cost_microusd_per_million_tokens = cost,
          .priority = priority};
}

TEST(AgentModelRouterTest, FixedModePreservesExistingDestination) {
  AgentModelSelectionInput input;
  input.fixed_destination = Destination("fixed");
  input.catalog = {
      Entry("fixed", *input.fixed_destination, 80, 20, 42)};
  std::string error;
  auto plan = SelectAgentModelRoute(input, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->primary.model, "fixed");
  EXPECT_FALSE(plan->fallback);
  EXPECT_EQ(plan->mode, AgentModelSelectionMode::kFixed);
  EXPECT_EQ(plan->primary_cost_microusd_per_million_tokens, 42);
}

TEST(AgentModelRouterTest, CostPolicyUsesSplitRatesAndSelectedBudget) {
  AgentModelSelectionInput input;
  input.mode = AgentModelSelectionMode::kCost;
  input.requirements.reasoning = AgentReasoningNeed::kBasic;
  auto expensive =
      Entry("expensive", Destination("expensive"), 100, 1, std::nullopt);
  expensive.token_prices = {.input = 100, .cached_input = 10, .output = 500};
  expensive.generation_policy.basic_profile.max_output_tokens = 16000;
  auto cheap = Entry("cheap", Destination("cheap"), 70, 50, std::nullopt);
  cheap.token_prices = {.input = 100, .cached_input = 10, .output = 500};
  cheap.generation_policy.basic_profile.max_output_tokens = 2000;
  input.catalog = {expensive, cheap};
  std::string error;
  auto plan = SelectAgentModelRoute(input, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->primary.model, "cheap");
  input.catalog[1].token_prices.output.reset();
  plan = SelectAgentModelRoute(input, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->primary.model, "expensive");
}

TEST(AgentModelRouterTest, RejectsEmptyOrUnauthorizedPool) {
  AgentModelSelectionInput input;
  input.mode = AgentModelSelectionMode::kBalanced;
  input.catalog.push_back(Entry("disabled", Destination("disabled"), 90, 1,
                                1));
  input.catalog[0].enabled = false;
  std::string error;
  EXPECT_FALSE(SelectAgentModelRoute(input, &error));
  EXPECT_EQ(error, "no authorized model satisfies the task requirements");
  input.catalog[0].enabled = true;
  input.catalog[0].authorized = false;
  EXPECT_FALSE(SelectAgentModelRoute(input, &error));
}

TEST(AgentModelRouterTest, FiltersCapabilitiesBeforeScoring) {
  AgentModelSelectionInput input;
  input.mode = AgentModelSelectionMode::kQuality;
  input.requirements = {.reasoning = AgentReasoningNeed::kStrong,
                        .context = AgentContextNeed::kLong,
                        .output = AgentOutputNeed::kMultiStep,
                        .requires_tool_calls = true};
  input.catalog = {
      Entry("incapable", Destination("incapable"), 100, 1, 1),
      Entry("capable", Destination("capable"), 70, 50, 50)};
  input.catalog[0].supports_tool_calls = false;
  std::string error;
  auto plan = SelectAgentModelRoute(input, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->primary.model, "capable");
  EXPECT_FALSE(plan->fallback);
}

TEST(AgentModelRouterTest, CostPolicyDoesNotTreatUnknownCostAsFree) {
  AgentModelSelectionInput input;
  input.mode = AgentModelSelectionMode::kCost;
  input.catalog = {
      Entry("unknown", Destination("unknown"), 99, 1, std::nullopt),
      Entry("known", Destination("known"), 60, 80, 25)};
  std::string error;
  auto plan = SelectAgentModelRoute(input, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->primary.model, "known");
  EXPECT_EQ(plan->primary_cost_microusd_per_million_tokens, 25);
  ASSERT_TRUE(plan->fallback);
  EXPECT_EQ(plan->fallback->model, "unknown");
  EXPECT_FALSE(plan->fallback_cost_microusd_per_million_tokens);
}

TEST(AgentModelRouterTest, LocalOnlyNeverReturnsCloudOrCallsJev) {
  AgentModelSelectionInput input;
  input.mode = AgentModelSelectionMode::kLocalOnly;
  input.catalog = {
      Entry("cloud", Destination("cloud"), 100, 1, 1),
      Entry("local", Destination("local",
                                  AgentModelDestination::Kind::kLoopback),
            50, 50, std::nullopt)};
  std::string error;
  auto plan = SelectAgentModelRoute(input, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->primary.kind, AgentModelDestination::Kind::kLoopback);
  EXPECT_FALSE(plan->fallback);
}

TEST(AgentModelRouterTest, StableIdBreaksOtherwiseEqualScores) {
  AgentModelSelectionInput input;
  input.mode = AgentModelSelectionMode::kBalanced;
  input.catalog = {Entry("z-last", Destination("z"), 80, 20, 10),
                   Entry("a-first", Destination("a"), 80, 20, 10)};
  std::string error;
  auto plan = SelectAgentModelRoute(input, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->primary.model, "a");
  ASSERT_TRUE(plan->fallback);
  EXPECT_EQ(plan->fallback->model, "z");
}

}  // namespace
}  // namespace aegis::agent
