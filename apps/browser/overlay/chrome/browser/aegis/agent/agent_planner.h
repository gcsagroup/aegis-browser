// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_PLANNER_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_PLANNER_H_

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "chrome/browser/aegis/agent/agent_model_protocol.h"
#include "chrome/browser/aegis/agent/agent_types.h"

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

AgentModelToolDefinition BuildSubmitPlanToolDefinition();

// Fixed contract placed before the user goal. Page text and prior tool results
// remain quoted untrusted inputs and cannot amend this contract.
std::string BuildAgentPlannerSystemContract();
std::optional<std::string> BuildAgentPlanningPrompt(
    std::string_view user_goal,
    const AgentTaskScope& maximum_scope);

std::optional<AgentTaskPlan> ParseAndValidateTaskPlan(
    const AgentModelEvent& event,
    const AgentTaskScope& maximum_scope,
    const AgentToolRegistry& registry,
    std::string* error);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_PLANNER_H_
