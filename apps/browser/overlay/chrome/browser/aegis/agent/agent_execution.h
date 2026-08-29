// Copyright 2026 GCSA
// Deterministic model-turn contract for executing one validated plan step.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_EXECUTION_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_EXECUTION_H_

#include <optional>
#include <string>
#include <vector>

#include "base/containers/span.h"
#include "chrome/browser/aegis/agent/agent_planner.h"
#include "chrome/browser/aegis/agent/agent_task.h"

namespace aegis::agent {

struct AgentCompletionSummary {
  std::string outcome;
  std::string summary;
  std::vector<std::string> source_urls;
  std::vector<std::string> unfinished_items;
};

struct AgentExecutionEvidence {
  std::string tool_name;
  AgentToolResult result;
};

AgentModelToolDefinition BuildCompleteTaskToolDefinition();
std::string BuildAgentExecutionSystemContract();
std::string BuildAgentExecutionPrompt(
    const AgentTask& task,
    const AgentTaskPlan& plan,
    size_t next_step,
    int attempt,
    const AgentToolResult* previous_result = nullptr,
    base::span<const AgentExecutionEvidence> evidence_history = {});

// A model turn may contain text for the timeline, but it must contain exactly
// one native tool call and a completed event. The requested tool must match the
// browser-selected plan step; model prose or JSON text can never become an
// action.
std::optional<AgentModelEvent> SelectExecutionToolCall(
    const AgentModelParseResult& result,
    std::string_view expected_tool,
    std::string* error);

std::optional<AgentCompletionSummary> ParseCompletionSummary(
    const AgentModelEvent& event,
    std::string* error);
bool AgentCompletionSourcesMatchEvidence(
    const AgentCompletionSummary& completion,
    base::span<const AgentExecutionEvidence> evidence_history);

// A checkout summary is accepted only when its arithmetic and source node
// references match the browser's latest bounded observation. The observation
// fingerprint is checked again immediately before control is handed to the
// user so a DOM or price change invalidates the old summary.
bool ValidateAgentCheckoutSummary(const AgentToolCall& call,
                                  const AgentToolResult& observation,
                                  std::string* error);
bool IsSameAgentCheckoutObservation(const AgentToolResult& expected,
                                    const AgentToolResult& fresh);
bool IsAegisFinalTransactionControlText(std::string_view text);
bool IsAegisShoppingIntermediateControlText(std::string_view text);
bool ShouldAegisRequireUserTakeoverForClick(std::string_view text,
                                            bool is_submit_control);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_EXECUTION_H_
