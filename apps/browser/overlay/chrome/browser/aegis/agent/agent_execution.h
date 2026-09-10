// Copyright 2026 GCSA
// Deterministic model-turn contract for executing one validated plan step.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_EXECUTION_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_EXECUTION_H_

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/containers/span.h"
#include "chrome/browser/aegis/agent/agent_planner.h"
#include "chrome/browser/aegis/agent/agent_task.h"

namespace aegis::agent {

struct AgentTranslationSegment {
  int source_id = 0;
  std::string translated_text;
  std::string omission_reason;
};

struct AgentCompletionSummary {
  std::string outcome;
  std::string summary;
  std::vector<std::string> source_urls;
  std::vector<std::string> unfinished_items;
  std::vector<AgentTranslationSegment> translation_segments;
};

struct AgentExecutionEvidence {
  std::string tool_name;
  AgentToolResult result;
};

// 原文范围在生成译文前独立确定，并绑定完整的目标、文档身份和原文。
struct AgentTranslationSelection {
  std::string source_prompt;
  std::vector<int> selected_source_ids;
};

AgentModelToolDefinition BuildSelectTranslationToolDefinition();
std::string BuildAgentTranslationSelectionSystemContract();
std::optional<std::string> BuildAgentTranslationSelectionPrompt(
    const AgentTask& task,
    base::span<const AgentExecutionEvidence> evidence_history,
    bool evidence_history_complete = true);
std::optional<AgentTranslationSelection> ParseAgentTranslationSelection(
    const AgentModelEvent& event,
    const AgentTask& task,
    base::span<const AgentExecutionEvidence> evidence_history,
    std::string* error,
    bool evidence_history_complete = true);

AgentModelToolDefinition BuildCompleteTaskToolDefinition(
    bool translation = false);
// 译文按浏览器原文编号重组；明确排除的片段仍需保留编号及理由，交独立复核判断。
bool NormalizeAgentTranslationCompletion(
    const AgentTask& task,
    AgentCompletionSummary* completion,
    base::span<const AgentExecutionEvidence> evidence_history,
    std::string* error,
    bool evidence_history_complete = true,
    const AgentTranslationSelection* selection = nullptr);
// 翻译复核是内部模型判定，不授予浏览器动作权限。格式无效和语义不符分别返回。
AgentModelToolDefinition BuildVerifyTranslationToolDefinition();
std::string BuildAgentTranslationReviewSystemContract();
std::optional<bool> ParseAgentTranslationReview(const AgentModelEvent& event,
                                               std::string* error);
// 只从最新、完整的已验证页面读取构造有界输入；缺正文/身份/完整性时拒绝。
std::optional<std::string> BuildAgentTranslationReviewPrompt(
    const AgentTask& task,
    const AgentCompletionSummary& completion,
    base::span<const AgentExecutionEvidence> evidence_history,
    std::string_view model_correction = {},
    bool evidence_history_complete = true,
    const AgentTranslationSelection* selection = nullptr);
std::string BuildAgentExecutionSystemContract();
std::string BuildAgentExecutionPrompt(
    const AgentTask& task,
    const AgentTaskPlan& plan,
    size_t next_step,
    int attempt,
    const AgentToolResult* previous_result = nullptr,
    base::span<const AgentExecutionEvidence> evidence_history = {},
    std::string_view model_correction = {},
    const AgentTranslationSelection* selection = nullptr);

// Tab and document identifiers are browser-issued capabilities rather than
// model-authored intent. Keep an already valid model selection, otherwise
// bind a browser-verified preferred tab or the only live scoped tab. Ambiguous
// scopes fail closed.
std::optional<int32_t> SelectBrowserBoundExecutionTab(
    std::optional<int32_t> requested_tab_id,
    std::optional<int32_t> preferred_tab_id,
    base::span<const int32_t> live_scoped_tab_ids);

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
    std::string* error,
    bool translation = false);
bool AgentCompletionSourcesMatchEvidence(
    const AgentCompletionSummary& completion,
    base::span<const AgentExecutionEvidence> evidence_history);
// 原始目标或已绑定的网页范围要求读取时，来源列表或模型文字不能替代原生回执。
bool AgentCompletionHasRequiredPageEvidence(
    std::string_view user_goal,
    const AgentTaskScope& scope,
    base::span<const AgentExecutionEvidence> evidence_history);
// Browser-native tasks such as bookmark checks have no page citation source.
// Drop model-invented source URLs for those tasks while keeping page-based
// completions strict and evidence-backed.
bool NormalizeAgentCompletionSourcesForEvidence(
    AgentCompletionSummary* completion,
    base::span<const AgentExecutionEvidence> evidence_history);

// 统一规范化纯收藏预览、链接检查及两者组合（包括模型失败后的完成回退）。
// 分类计数与代表标题仅来自完整 moves；不改变原生分类规则或已应用/撤销结果。
// 无效预览或混合任务只能部分完成；保留来源及所有未完成项，不外露原始回执。
void NormalizeAgentBookmarkCheckCompletion(
    AgentCompletionSummary* completion,
    base::span<const AgentExecutionEvidence> evidence_history,
    bool preserve_verified_content = false);

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
