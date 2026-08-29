// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_planner.h"

#include <string>
#include <string_view>

#include "base/json/json_reader.h"
#include "chrome/browser/aegis/agent/agent_tool_registry.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {

AgentTaskScope MaximumScope() {
  AgentTaskScope scope;
  scope.allowed_origins = {
      url::Origin::Create(GURL("https://research.example/")),
      url::Origin::Create(GURL("https://docs.example/"))};
  scope.allowed_tab_ids = {17};
  scope.allowed_tools = {"page.observe", "page.navigate", "tab.create"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage,
                                AgentDataClass::kBrowserMetadata};
  scope.budgets.max_tabs = 8;
  scope.budgets.max_tool_calls = 20;
  scope.budgets.max_model_calls = 10;
  scope.budgets.max_network_requests = 40;
  scope.budgets.max_duration = base::Minutes(10);
  scope.model_destination.kind = AgentModelDestination::Kind::kOnDevice;
  scope.model_destination.provider = "fixture";
  scope.model_destination.model = "fixture-model";
  return scope;
}

AgentModelEvent ValidPlanEvent() {
  AgentModelEvent event;
  event.type = AgentModelEventType::kToolCall;
  event.tool_call_id = "plan-1";
  event.tool_name = "agent.submit_plan";
  event.arguments.Set("schema_version", kAgentSchemaVersion);
  event.arguments.Set("summary", "Read the approved research sources.");

  base::ListValue origins;
  origins.Append("https://research.example/");
  event.arguments.Set("origins", std::move(origins));
  base::ListValue tools;
  tools.Append("page.observe");
  event.arguments.Set("tools", std::move(tools));
  base::ListValue data_classes;
  data_classes.Append("public_page");
  event.arguments.Set("data_classes", std::move(data_classes));

  base::DictValue budgets;
  budgets.Set("max_tabs", 2);
  budgets.Set("max_tool_calls", 5);
  budgets.Set("max_model_calls", 3);
  budgets.Set("max_network_requests", 10);
  budgets.Set("max_duration_seconds", 120);
  event.arguments.Set("budgets", std::move(budgets));

  base::DictValue step;
  step.Set("id", "step-1");
  step.Set("title", "Read the current page");
  step.Set("tool", "page.observe");
  base::ListValue steps;
  steps.Append(std::move(step));
  event.arguments.Set("steps", std::move(steps));
  return event;
}

TEST(AegisAgentPlannerTest, AcceptsNarrowPlanAndComputesRisk) {
  AgentToolRegistry registry;
  std::string error;
  std::optional<AgentTaskPlan> plan = ParseAndValidateTaskPlan(
      ValidPlanEvent(), MaximumScope(), registry, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_TRUE(plan->scope.AllowsOrigin(GURL("https://research.example/a")));
  EXPECT_FALSE(plan->scope.AllowsOrigin(GURL("https://docs.example/a")));
  EXPECT_TRUE(plan->scope.AllowsTab(17));
  ASSERT_EQ(plan->steps.size(), 1u);
  EXPECT_EQ(plan->steps[0].risk, AgentRiskLevel::kR0ReadOnly);
}

TEST(AegisAgentPlannerTest, RejectsScopeExpansionAndUnknownFields) {
  AgentToolRegistry registry;
  std::string error;

  AgentModelEvent expanded = ValidPlanEvent();
  expanded.arguments.FindList("origins")->Append("https://evil.example/");
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(expanded, MaximumScope(), registry, &error));
  EXPECT_EQ(error, "task plan expands the browser-approved scope");

  AgentModelEvent injected = ValidPlanEvent();
  injected.arguments.Set("ignore_browser_policy", true);
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(injected, MaximumScope(), registry, &error));
  EXPECT_EQ(error, "tool argument contains an unknown field");
}

TEST(AegisAgentPlannerTest, RejectsModelDeclaredRiskOrUnapprovedStep) {
  AgentToolRegistry registry;
  std::string error;

  AgentModelEvent declared_risk = ValidPlanEvent();
  declared_risk.arguments.FindList("steps")->front().GetDict().Set("risk",
                                                                   "read_only");
  EXPECT_FALSE(ParseAndValidateTaskPlan(declared_risk, MaximumScope(), registry,
                                        &error));

  AgentModelEvent unapproved = ValidPlanEvent();
  unapproved.arguments.FindList("steps")->front().GetDict().Set(
      "tool", "bookmark.apply");
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(unapproved, MaximumScope(), registry, &error));
  EXPECT_EQ(error, "task plan step is duplicated or outside scope");
}

TEST(AegisAgentPlannerTest, ShoppingPlanMustEndInOneUserTakeover) {
  AgentTaskScope shopping_scope = MaximumScope();
  shopping_scope.allowed_tools.insert("shopping.prepare_checkout");
  shopping_scope.allowed_data_classes.insert(AgentDataClass::kFormData);
  AgentToolRegistry registry;
  std::string error;

  AgentModelEvent omitted = ValidPlanEvent();
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(omitted, shopping_scope, registry, &error));
  EXPECT_EQ(error,
            "shopping plan must end with one browser-enforced user takeover");

  AgentModelEvent valid = ValidPlanEvent();
  valid.arguments.FindList("tools")->Append("shopping.prepare_checkout");
  valid.arguments.FindList("data_classes")->Append("form_data");
  base::DictValue checkout;
  checkout.Set("id", "checkout-takeover");
  checkout.Set("title", "Hand the final purchase to the user");
  checkout.Set("tool", "shopping.prepare_checkout");
  valid.arguments.FindList("steps")->Append(std::move(checkout));
  ASSERT_TRUE(ParseAndValidateTaskPlan(valid, shopping_scope, registry, &error))
      << error;

  AgentModelEvent duplicate = ValidPlanEvent();
  duplicate.arguments.FindList("tools")->Append("shopping.prepare_checkout");
  duplicate.arguments.FindList("data_classes")->Append("form_data");
  for (std::string_view id : {"checkout-one", "checkout-two"}) {
    base::DictValue step;
    step.Set("id", id);
    step.Set("title", "Hand the final purchase to the user");
    step.Set("tool", "shopping.prepare_checkout");
    duplicate.arguments.FindList("steps")->Append(std::move(step));
  }
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(duplicate, shopping_scope, registry, &error));
  EXPECT_EQ(error,
            "shopping plan must end with one browser-enforced user takeover");
}

TEST(AegisAgentPlannerTest, ContractMarksExternalContentUntrusted) {
  const std::string contract = BuildAgentPlannerSystemContract();
  EXPECT_TRUE(contract.contains("untrusted"));
  EXPECT_TRUE(contract.contains("user takeover"));
  EXPECT_TRUE(contract.contains("agent.submit_plan"));

  const std::optional<std::string> prompt =
      BuildAgentPlanningPrompt("Compare approved sources", MaximumScope());
  ASSERT_TRUE(prompt);
  const std::optional<base::Value> parsed =
      base::JSONReader::Read(*prompt, base::JSON_PARSE_RFC);
  ASSERT_TRUE(parsed && parsed->is_dict());
  ASSERT_TRUE(parsed->GetDict().FindString("user_goal"));
  EXPECT_EQ(*parsed->GetDict().FindString("user_goal"),
            "Compare approved sources");
  EXPECT_EQ(parsed->GetDict()
                .FindDict("model_destination")
                ->FindBool("credential_in_browser"),
            true);
}

}  // namespace
}  // namespace aegis::agent
