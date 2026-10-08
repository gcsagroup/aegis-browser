// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_RESEARCH_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_RESEARCH_H_

#include <map>
#include <optional>
#include <string>
#include <string_view>

#include "base/containers/span.h"
#include "base/values.h"
#include "chrome/browser/aegis/agent/agent_execution.h"
#include "chrome/browser/aegis/agent/agent_task.h"

namespace aegis::agent {
// 只比较规范化正文，不使用会在重载时变化的节点编号和文档令牌。
std::optional<std::string> AgentResearchContentHash(
    const AgentToolResult& result);
// 原文锚点通过后，仅由浏览器生成分组和计数；自由摘要不能冒充已核验比较。
void NormalizeAgentResearchComparison(
    AgentCompletionSummary* completion,
    const AgentTask& task,
    base::span<const AgentExecutionEvidence> evidence,
    const std::map<int32_t, GURL>& selected_urls);
std::optional<base::DictValue> BuildAgentResearchRecord(
    const AgentTask& task,
    const AgentCompletionSummary& completion,
    base::span<const AgentExecutionEvidence> evidence,
    const std::map<int32_t, GURL>& selected_urls);
// 只有仍获授权的选中页读取重试耗尽，才允许记为部分来源缺失。
bool CanSkipUnreadableResearchSource(const AgentTask& task,
                                     const AgentToolCall& call,
                                     const AgentToolResult& result,
                                     int attempts,
                                     bool selection_matches);
bool IsValidAgentResearchRecord(const base::DictValue& record);
// 只返回浏览器实际取得的摘录，缺失来源不能被模型或旧记忆补齐。
std::optional<AgentCompletionSummary> BuildPartialResearchCompletion(
    const base::DictValue& record);
}  // namespace aegis::agent
#endif
