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

// 同一维度使用相同原文前后缀；浏览器据此核对值，再自行分组。
struct AgentResearchComparisonValue {
  std::string source_url;
  std::string value;
};
struct AgentResearchComparison {
  std::string label;
  std::string prefix;
  std::string suffix;
  std::vector<AgentResearchComparisonValue> values;
};

struct AgentCompletionSummary {
  std::string outcome;
  std::string summary;
  std::vector<std::string> source_urls;
  std::vector<std::string> unfinished_items;
  std::vector<AgentTranslationSegment> translation_segments;
  std::vector<AgentResearchComparison> research_comparisons;
};

struct AgentExecutionEvidence {
  std::string tool_name;
  AgentToolResult result;
};

// 仅对疑似重复汉字追加一次短校对；不让校对修改事实、数字、网址或引文。
bool AgentSummaryNeedsTextReview(std::string_view summary);
AgentModelToolDefinition BuildReviewSummaryToolDefinition();
bool ApplyAgentSummaryTextReview(AgentCompletionSummary *completion,
                                 const AgentModelEvent *event);

// 研究模型没有保存权限；保存状态只能由用户操作后的原生存储回执确认。
bool AgentResearchCompletionClaimsSave(const AgentCompletionSummary& completion);
// 只规范已知的存储待办和独立状态行；未知或内容未完成事项保持不变。
void NormalizeAgentResearchSaveContent(AgentCompletionSummary* completion,
                                      const AgentTask& task);
void UpdateAgentResearchSaveCompletion(AgentCompletionSummary* completion,
                                      const AgentTask& task,
                                      bool saved);

// 原生下载回执投影给界面的有限字段，不包含路径、凭据或模型身份判断。
base::DictValue BuildAgentDownloadEvidence(
    base::span<const AgentExecutionEvidence> history);

// 下载结果只按原生回执描述，页面按钮文案和模型文字不能证明已经开始或取消。
void NormalizeAgentDownloadCompletion(
    AgentCompletionSummary* completion,
    std::string_view user_goal,
    const AgentTaskScope& scope,
    base::span<const AgentExecutionEvidence> history,
    base::span<const AgentExecutionEvidence> page_history = {});

// 分组的数量来自原生回读；模型声称“三个”不能替代实际只分组一个的结果。
void NormalizeAgentTabGroupCompletion(
    AgentCompletionSummary* completion,
    const AgentTask& task,
    base::span<const AgentExecutionEvidence> history);

// history 仅接收本任务通过权限、批准与写入后回读核验的工具回执。
void NormalizeAgentBookmarkApplyCompletion(
    AgentCompletionSummary* completion,
    const AgentTask& task,
    base::span<const AgentExecutionEvidence> history);

// 原文范围在生成译文前独立确定，并绑定完整的目标、文档身份和原文。
struct AgentTranslationSelection {
  std::string source_prompt;
  std::vector<int> selected_source_ids;
};

// 下载步骤读取有界正文；链接与摘要由独立下载工具核验，避免自造提取字段。
void ConstrainDownloadExtractionTool(AgentModelToolDefinition* tool,
                                     const AgentTaskScope& scope,
                                     std::string_view user_goal = {});

// 用户要求完整性核对时，开始下载前必须提供预期摘要，不能事后猜测。
bool AgentGoalRequestsDownloadIntegrity(std::string_view goal);
void ConstrainDownloadIntegrityTool(AgentModelToolDefinition* tool,
                                    std::string_view user_goal);

// 只提供最近原生观察实际支持的字段；空正文不会被要求重复提取。
void ConstrainObservedExtractionTool(AgentModelToolDefinition* tool,
                                    const AgentToolResult* observation);

// 当原生观察只允许标题时，直接执行该只读提取，不让模型反复猜不存在的正文。
std::optional<AgentToolCall> BuildTitleOnlyExtractionCall(
    const AgentTask& task,
    const AgentPlanStep& step,
    int attempt,
    const AgentDocumentRef& document,
    const AgentModelToolDefinition& constrained_tool);

// 普通两步只读计划可直接读取已观察到的标题与正文，翻译和恢复仍由模型规划。
std::optional<AgentToolCall> BuildReadOnlyArticleExtractionCall(
    const AgentTask& task,
    const AgentTaskPlan& plan,
    size_t next_step,
    int attempt,
    const AgentDocumentRef& document,
    const AgentModelToolDefinition& constrained_tool);

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
    bool translation = false, bool research = false);
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
std::string BuildAgentExecutionSystemContractForTask(
    const AgentTask& task,
    const AgentTaskPlan& plan,
    std::string_view tool_name);
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
    bool translation = false, bool research = false);
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
