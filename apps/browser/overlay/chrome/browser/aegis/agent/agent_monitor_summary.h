// Copyright 2026 GCSA
// 网页变化摘要只处理已核验的观察结果，不赋予模型任何浏览器操作权限。

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_MONITOR_SUMMARY_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_MONITOR_SUMMARY_H_

#include <optional>
#include <string>
#include <string_view>

#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/aegis/agent/agent_model_protocol.h"

namespace aegis::agent {

struct AgentMonitorSummaryInput {
  std::string current_content_hash;
  base::ListValue changes;
  bool truncated = false;
};

// 首次观察或无有效基线返回 nullopt；仅顺序/空白变化返回空 changes。
std::optional<AgentMonitorSummaryInput> BuildAgentMonitorSummaryInput(
    std::string_view previous,
    std::string_view current);
AgentModelToolDefinition BuildAgentMonitorSummaryTool();
std::string AgentMonitorSummarySystemPrompt();
std::string BuildAgentMonitorSummaryPrompt(
    const AgentMonitorSummaryInput& input,
    std::string_view locale);

// 仅一对完整纯数字片段时直接陈述增删，不让模型猜测字段含义。
std::optional<std::string> BuildAgentMonitorNumericSummary(
    std::string_view current,
    const AgentMonitorSummaryInput& input,
    std::string_view locale,
    base::Time now);

// 只接受唯一的原生摘要工具调用及有效证据引用。结果仍需走既有系统加密持久化。
std::optional<std::string> AttachAgentMonitorSummary(
    std::string_view current,
    const AgentMonitorSummaryInput& input,
    const AgentModelParseResult& result,
    base::Time now);
std::string ReadAgentMonitorSummary(std::string_view observation);
bool HasMeaningfulAgentMonitorSummary(std::string_view observation);
bool IsPartialAgentMonitorSummary(std::string_view observation);
std::string PreserveUnchangedAgentMonitorSummary(std::string_view previous,
                                                 std::string_view current);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_MONITOR_SUMMARY_H_
