// Copyright 2026 GCSA
// Built-in workflow contracts for Aegis Browser Agent.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_WORKFLOW_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_WORKFLOW_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "chrome/browser/aegis/agent/agent_types.h"

namespace aegis::agent {

enum class AgentWorkflowKind {
  kResearch = 0,
  kBrowserSteward = 1,
  kSafeDownload = 2,
  kShopping = 3,
};

struct AgentWorkflowTemplate {
  AgentWorkflowKind kind = AgentWorkflowKind::kResearch;
  std::string id;
  std::string title;
  std::string purpose;
  base::flat_set<std::string> tools;
  base::flat_set<AgentDataClass> data_classes;
  AgentBudgets budgets;
  bool supports_monitoring = false;
  bool always_user_takeover_for_final_action = false;
};

const AgentWorkflowTemplate& GetAgentWorkflowTemplate(AgentWorkflowKind kind);

// Builds the maximum scope shown on the task consent card. Origins and tab
// handles are browser-issued inputs; workflow templates can only narrow tools,
// data classes, and budgets.
std::optional<AgentTaskScope> BuildAgentWorkflowScope(
    AgentWorkflowKind kind,
    std::vector<url::Origin> origins,
    base::flat_set<int32_t> tab_ids,
    AgentModelDestination destination);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_WORKFLOW_H_
