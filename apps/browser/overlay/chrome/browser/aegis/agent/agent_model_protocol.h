// Copyright 2026 GCSA
// Provider-neutral structured model protocol for Aegis Browser Agent.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_PROTOCOL_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_PROTOCOL_H_

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/values.h"

namespace aegis::agent {

enum class AgentModelProvider {
  kOpenAICompatible = 0,
  kAnthropic = 1,
  kGemini = 2,
};

enum class AgentModelEventType {
  kMessageDelta = 0,
  kToolCall = 1,
  kUsage = 2,
  kCompleted = 3,
  kRefused = 4,
};

struct AgentModelToolDefinition {
  std::string name;
  std::string description;
  base::DictValue input_schema;
};

struct AgentModelRequest {
  AgentModelProvider provider = AgentModelProvider::kOpenAICompatible;
  std::string model;
  std::string system_prompt;
  std::string user_prompt;
  std::vector<AgentModelToolDefinition> tools;
  // Agent turns expose one browser-selected tool at a time. Requiring it at
  // the provider layer avoids models returning prose instead of acting.
  std::string required_tool_name;
  // Keep tightly scoped tool turns action-first on compatible reasoning
  // endpoints. Other provider adapters may ignore this preference.
  std::string reasoning_effort;
  // Numeric-loopback OpenAI-compatible Qwen servers commonly expose the
  // model's chat-template switch directly. The service enables this only for
  // that local combination; cloud and unrelated custom providers never see
  // the compatibility field.
  bool disable_model_thinking = false;
  int max_output_tokens = 2048;
  bool stream = true;
};

// 识别本地服务常见的仓库/发布者前缀；调用者仍须验证本地端点与协议。
bool IsQwenModelName(std::string_view model);

// 路由与读取动作只生成短参数，不使用正文生成所需的大输出预算。
int AgentModelToolOutputTokenLimit(std::string_view tool_name);

struct AgentModelUsage {
  int64_t input_tokens = 0;
  int64_t output_tokens = 0;
};

struct AgentModelEvent {
  AgentModelEventType type = AgentModelEventType::kMessageDelta;
  std::string text;
  std::string tool_call_id;
  std::string tool_name;
  base::DictValue arguments;
  AgentModelUsage usage;
};

struct AgentModelParseResult {
  std::vector<AgentModelEvent> events;
  std::string error;

  bool ok() const { return error.empty(); }
};

// Builds a provider request using only custom function tools. It never enables
// provider-hosted browser, code execution, retrieval, or computer tools.
std::optional<std::string> BuildAgentModelRequestBody(
    const AgentModelRequest& request,
    std::string* error);

// Parses either one non-streaming JSON response or a complete SSE transcript.
// Tool calls are accepted only from provider-native structured fields. JSON in
// assistant text is intentionally never promoted to a tool call.
AgentModelParseResult ParseAgentModelResponse(
    AgentModelProvider provider,
    std::string_view body,
    bool is_stream,
    const std::vector<AgentModelToolDefinition>& allowed_tools);

// Validates a tool call against its fixed input schema. Supported schema
// keywords are deliberately small: type, properties, required,
// additionalProperties, items, enum, minLength, maxLength, minimum, maximum.
bool ValidateAgentToolArguments(const AgentModelToolDefinition& tool,
                                const base::DictValue& arguments,
                                std::string* error);

class AgentModelCapabilityTracker {
 public:
  void RecordToolProbeSuccess();
  void RecordSchemaSuccess();
  void RecordSchemaFailure();

  bool AllowsActionModes() const;
  int consecutive_schema_failures() const {
    return consecutive_schema_failures_;
  }

 private:
  bool tool_probe_succeeded_ = false;
  int consecutive_schema_failures_ = 0;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_PROTOCOL_H_
