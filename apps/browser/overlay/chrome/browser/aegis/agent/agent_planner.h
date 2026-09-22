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

// 前端分类只是提示；显式网址和当前页入口也必须保留原始目标的否定约束。
// 是否明确要求开始文件传输，不含仅寻找来源或讨论下载的目标。
bool AgentGoalRequestsDownloadTransfer(std::string_view goal);

// 当前页指代统一用于入口选择及模型返回校验，显式网址优先。
bool AgentGoalRefersToCurrentPage(std::string_view goal);

// 本任务限定优先于窗口元数据入口，冲突目标取较小范围。
bool AgentGoalRequestsWindowTabMetadata(std::string_view goal);

AgentWorkflowKind ConstrainWorkflowToUserIntent(
    std::string_view user_goal,
    AgentWorkflowKind workflow);

// 网页内容任务不能用标签页、收藏夹等元数据替代页面读取证据。
bool AgentGoalRequiresPageEvidence(std::string_view user_goal);

// 从原始目标的肯定请求判断是否需要翻译产物，不接受页面或模型改写目标。
bool AgentGoalRequestsTranslation(std::string_view user_goal);

// 仅拒绝英文目标下没有英文正文的明显错语结果；明确目标语言及原文另行处理。
bool AgentTextHasWrongDefaultLanguage(std::string_view text,
                                      std::string_view goal);

// 网页任务的统一证据门槛：目标文本要求读页，或浏览器已绑定页面读取范围。
// 与计划解析共用来源、标签页及 page.observe 绑定判断，不增加任何授权。
bool AgentTaskRequiresPageEvidence(std::string_view user_goal,
                                  const AgentTaskScope& scope);

AgentModelToolDefinition BuildSubmitPlanToolDefinition();

// Fixed contract placed before the user goal. Page text and prior tool results
// remain quoted untrusted inputs and cannot amend this contract.
std::string BuildAgentPlannerSystemContract();
std::optional<std::string> BuildAgentPlanningPrompt(
    std::string_view user_goal,
    const AgentTaskScope& maximum_scope,
    const AgentToolRegistry& registry);

// 明确要求“开始下载后取消”时使用固定依赖顺序；仅限已打开页面和现有授权。
// 仍通过普通计划校验，download.start仍须逐次批准。
std::optional<AgentModelEvent> BuildBrowserDownloadCancellationPlan(
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

// 复用规划阶段的否定与收藏意图判断；预览不是写入完成的依据。
bool AgentGoalRequiresBookmarkApply(std::string_view user_goal);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_PLANNER_H_
