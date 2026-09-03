// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_PLANNER_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_PLANNER_H_

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "chrome/browser/aegis/agent/agent_model_protocol.h"
#include "chrome/browser/aegis/agent/agent_types.h"
#include "chrome/browser/aegis/agent/agent_workflow.h"

namespace aegis::agent {

class AgentToolRegistry;

struct AgentPlanStep {
  std::string step_id;
  std::string title;
  std::string tool_name;
  AgentRiskLevel risk = AgentRiskLevel::kBlocked;
};

struct AgentTaskPlan {
  int schema_version = kAgentSchemaVersion;
  std::string summary;
  AgentTaskScope scope;
  std::vector<AgentPlanStep> steps;
};

enum class AgentGoalEntryKind {
  kBrowserOnly = 0,
  kOpenUrl = 1,
  kWebSearch = 2,
};

// The model proposes how a goal should enter the browser. The browser still
// validates this route and creates the actual tab and authorization scope.
struct AgentGoalRoute {
  AgentWorkflowKind workflow = AgentWorkflowKind::kResearch;
  AgentGoalEntryKind entry_kind = AgentGoalEntryKind::kWebSearch;
  std::string target;
  std::string summary;
};

AgentModelToolDefinition BuildRouteGoalToolDefinition();
std::string BuildAgentGoalRouterSystemContract();
std::optional<std::string> BuildAgentGoalRoutingPrompt(
    std::string_view user_goal,
    AgentWorkflowKind requested_workflow);
std::optional<AgentGoalRoute> ParseAndValidateGoalRoute(
    const AgentModelEvent& event,
    std::string* error);

// Narrows a model-proposed route using intent that must remain browser-owned.
// Product discovery cannot silently gain shopping authority, and a named-site
// request cannot be redirected to a general search engine or unrelated host.
AgentGoalRoute ConstrainGoalRouteToUserIntent(std::string_view user_goal,
                                              AgentGoalRoute route);

AgentModelToolDefinition BuildSubmitPlanToolDefinition();

// Fixed contract placed before the user goal. Page text and prior tool results
// remain quoted untrusted inputs and cannot amend this contract.
std::string BuildAgentPlannerSystemContract();
std::optional<std::string> BuildAgentPlanningPrompt(
    std::string_view user_goal,
    const AgentTaskScope& maximum_scope,
    const AgentToolRegistry& registry);

// Builds a browser-authored, read-only recovery plan after the configured
// model has failed its single bounded format repair. This never adds a tool,
// origin, tab, data class, or budget and is unavailable for shopping scopes.
std::optional<AgentModelEvent> BuildBrowserReadOnlyRecoveryPlan(
    std::string_view user_goal,
    const AgentTaskScope& maximum_scope,
    const AgentToolRegistry& registry);

std::optional<AgentTaskPlan> ParseAndValidateTaskPlan(
    const AgentModelEvent& event,
    const AgentTaskScope& maximum_scope,
    const AgentToolRegistry& registry,
    std::string* error);

// Enforces lifecycle rules that depend on the user-selected task mode rather
// than model-owned plan fields. Scheduled tasks must create one durable
// monitor, while one-shot tasks may not create one implicitly.
bool ValidateTaskPlanForMode(const AgentTaskPlan& plan,
                             AgentMode mode,
                             std::string* error);

// Ensures that structurally valid bookmark plans still cover each explicit
// user intent. Missing read-only steps are repairable, while a no-change or
// preview-only goal can never smuggle bookmark.apply into the plan.
bool ValidateTaskPlanForGoal(const AgentTaskPlan& plan,
                             std::string_view user_goal,
                             std::string* error);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_PLANNER_H_
