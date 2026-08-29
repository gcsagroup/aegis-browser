// Copyright 2026 GCSA
// Provider-neutral structured model protocol for Aegis Browser Agent.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_PROTOCOL_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_PROTOCOL_H_

#include <cstdint>
#include <optional>
#include <string>
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
  int max_output_tokens = 2048;
  bool stream = true;
};

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
