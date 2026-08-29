// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_model_protocol.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <map>
#include <optional>
#include <string_view>
#include <utility>

#include "base/containers/flat_set.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"

namespace aegis::agent {
namespace {

constexpr size_t kMaxResponseBytes = 2 * 1024 * 1024;
constexpr size_t kMaxToolCount = 64;
constexpr size_t kMaxToolNameBytes = 128;
constexpr size_t kMaxToolDescriptionBytes = 2048;
constexpr size_t kMaxPromptBytes = 64 * 1024;
constexpr size_t kMaxToolArgumentsBytes = 64 * 1024;
constexpr size_t kMaxTextBytes = 256 * 1024;
constexpr size_t kMaxToolCalls = 64;
constexpr size_t kMaxModelEvents = 4096;
constexpr size_t kMaxArrayItems = 256;
constexpr int kMaxSchemaDepth = 16;
constexpr double kMaxSafeInteger = 9007199254740991.0;

struct PendingToolCall {
  std::string id;
  std::string name;
  std::string arguments;
  bool emitted = false;
};

bool HasUnsafeControlCharacter(std::string_view value) {
  return std::ranges::any_of(value, [](unsigned char ch) {
    return (ch < 0x20 && ch != '\t' && ch != '\n' && ch != '\r') || ch == 0x7f;
  });
}

bool IsValidText(std::string_view value, size_t max_bytes, bool allow_empty) {
  return (allow_empty || !value.empty()) && value.size() <= max_bytes &&
         base::IsStringUTF8(value) && !HasUnsafeControlCharacter(value);
}

bool IsValidToolName(std::string_view name) {
  if (name.empty() || name.size() > kMaxToolNameBytes) {
    return false;
  }
  return std::ranges::all_of(name, [](unsigned char ch) {
    return base::IsAsciiAlphaNumeric(ch) || ch == '.' || ch == '_' || ch == '-';
  });
}

bool SerializeValue(const base::ValueView value, std::string* json) {
  return base::JSONWriter::Write(value, json);
}

bool IsSchemaType(const base::Value& value, std::string_view type) {
  if (type == "object") {
    return value.is_dict();
  }
  if (type == "array") {
    return value.is_list();
  }
  if (type == "string") {
    return value.is_string();
  }
  if (type == "boolean") {
    return value.is_bool();
  }
  if (type == "integer") {
    return value.is_int();
  }
  if (type == "number") {
    return value.is_int() || value.is_double();
  }
  if (type == "null") {
    return value.is_none();
  }
  return false;
}

double NumericValue(const base::Value& value) {
  return value.is_int() ? value.GetInt() : value.GetDouble();
}

bool ValidateSchemaNode(const base::Value& value,
                        const base::DictValue& schema,
                        int depth,
                        std::string* error) {
  if (depth > kMaxSchemaDepth) {
    *error = "tool arguments exceed maximum depth";
    return false;
  }
  const std::string* type = schema.FindString("type");
  if (!type || !IsSchemaType(value, *type)) {
    *error = "tool argument has wrong type";
    return false;
  }

  if (const base::ListValue* choices = schema.FindList("enum")) {
    if (std::ranges::none_of(*choices, [&value](const base::Value& choice) {
          return choice == value;
        })) {
      *error = "tool argument is not an allowed enum value";
      return false;
    }
  }

  if (value.is_string()) {
    const std::string& text = value.GetString();
    if (!IsValidText(text, kMaxToolArgumentsBytes, true)) {
      *error = "tool string is invalid";
      return false;
    }
    if (const std::optional<int> min_length = schema.FindInt("minLength");
        min_length && text.size() < static_cast<size_t>(*min_length)) {
      *error = "tool string is too short";
      return false;
    }
    if (const std::optional<int> max_length = schema.FindInt("maxLength");
        max_length && text.size() > static_cast<size_t>(*max_length)) {
      *error = "tool string is too long";
      return false;
    }
  }

  if (value.is_int() || value.is_double()) {
    const double number = NumericValue(value);
    if (!std::isfinite(number) || std::abs(number) > kMaxSafeInteger) {
      *error = "tool number is outside the safe range";
      return false;
    }
    if (const std::optional<double> minimum = schema.FindDouble("minimum");
        minimum && number < *minimum) {
      *error = "tool number is below minimum";
      return false;
    }
    if (const std::optional<double> maximum = schema.FindDouble("maximum");
        maximum && number > *maximum) {
      *error = "tool number exceeds maximum";
      return false;
    }
  }

  if (value.is_list()) {
    const size_t item_count = value.GetList().size();
    if (item_count > kMaxArrayItems) {
      *error = "tool array exceeds browser item limit";
      return false;
    }
    if (const std::optional<int> min_items = schema.FindInt("minItems");
        min_items &&
        (*min_items < 0 || item_count < static_cast<size_t>(*min_items))) {
      *error = "tool array has too few items";
      return false;
    }
    if (const std::optional<int> max_items = schema.FindInt("maxItems");
        max_items &&
        (*max_items < 0 || item_count > static_cast<size_t>(*max_items))) {
      *error = "tool array has too many items";
      return false;
    }
    const base::DictValue* item_schema = schema.FindDict("items");
    if (!item_schema) {
      *error = "array schema has no item contract";
      return false;
    }
    for (const base::Value& item : value.GetList()) {
      if (!ValidateSchemaNode(item, *item_schema, depth + 1, error)) {
        return false;
      }
    }
  }

  if (value.is_dict()) {
    const base::DictValue* properties = schema.FindDict("properties");
    if (!properties) {
      *error = "object schema has no properties contract";
      return false;
    }
    const bool allow_extra =
        schema.FindBool("additionalProperties").value_or(false);
    const base::ListValue* required = schema.FindList("required");
    if (required) {
      for (const base::Value& required_name : *required) {
        if (!required_name.is_string() ||
            !value.GetDict().contains(required_name.GetString())) {
          *error = "required tool argument is missing";
          return false;
        }
      }
    }
    for (const auto [key, child] : value.GetDict()) {
      const base::DictValue* child_schema = properties->FindDict(key);
      if (!child_schema) {
        if (!allow_extra) {
          *error = "tool argument contains an unknown field";
          return false;
        }
        continue;
      }
      if (!ValidateSchemaNode(child, *child_schema, depth + 1, error)) {
        return false;
      }
    }
  }
  return true;
}

const AgentModelToolDefinition* FindTool(
    const std::vector<AgentModelToolDefinition>& tools,
    std::string_view name) {
  auto it = std::ranges::find(tools, name, &AgentModelToolDefinition::name);
  return it == tools.end() ? nullptr : &*it;
}

AgentModelParseResult Fail(std::string error) {
  AgentModelParseResult result;
  result.error = std::move(error);
  return result;
}

bool AppendText(std::string_view text,
                AgentModelParseResult* result,
                size_t* total_text_bytes) {
  if (!IsValidText(text, kMaxTextBytes, true) ||
      *total_text_bytes + text.size() > kMaxTextBytes) {
    result->error = "model text is invalid or too large";
    return false;
  }
  if (text.empty()) {
    return true;
  }
  if (result->events.size() >= kMaxModelEvents) {
    result->error = "too many model events";
    return false;
  }
  *total_text_bytes += text.size();
  AgentModelEvent event;
  event.type = AgentModelEventType::kMessageDelta;
  event.text = std::string(text);
  result->events.push_back(std::move(event));
  return true;
}

bool AppendUsage(int64_t input, int64_t output, AgentModelParseResult* result) {
  if (input < 0 || output < 0 || input > kMaxSafeInteger ||
      output > kMaxSafeInteger) {
    result->error = "model usage is invalid";
    return false;
  }
  if (result->events.size() >= kMaxModelEvents) {
    result->error = "too many model events";
    return false;
  }
  AgentModelEvent event;
  event.type = AgentModelEventType::kUsage;
  event.usage.input_tokens = input;
  event.usage.output_tokens = output;
  result->events.push_back(std::move(event));
  return true;
}

bool AppendToolCall(std::string id,
                    std::string name,
                    const base::Value& raw_arguments,
                    const std::vector<AgentModelToolDefinition>& tools,
                    base::flat_set<std::string>* seen_ids,
                    AgentModelParseResult* result) {
  if (seen_ids->size() >= kMaxToolCalls ||
      result->events.size() >= kMaxModelEvents) {
    result->error = "too many model events";
    return false;
  }
  if (!IsValidToolName(name) || id.empty() || id.size() > 256 ||
      !base::IsStringUTF8(id) || HasUnsafeControlCharacter(id) ||
      seen_ids->contains(id)) {
    result->error = "tool call id or name is invalid or duplicated";
    return false;
  }
  const AgentModelToolDefinition* tool = FindTool(tools, name);
  if (!tool) {
    result->error = "model requested an unapproved tool";
    return false;
  }

  base::DictValue arguments;
  if (raw_arguments.is_string()) {
    if (raw_arguments.GetString().size() > kMaxToolArgumentsBytes) {
      result->error = "tool arguments are too large";
      return false;
    }
    std::optional<base::Value> parsed =
        base::JSONReader::Read(raw_arguments.GetString(), base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) {
      result->error = "tool arguments are not a JSON object";
      return false;
    }
    arguments = std::move(*parsed).TakeDict();
  } else if (raw_arguments.is_dict()) {
    arguments = raw_arguments.GetDict().Clone();
  } else {
    result->error = "tool arguments are not an object";
    return false;
  }

  std::string serialized;
  if (!SerializeValue(arguments, &serialized) ||
      serialized.size() > kMaxToolArgumentsBytes) {
    result->error = "tool arguments are too large";
    return false;
  }
  std::string validation_error;
  if (!ValidateAgentToolArguments(*tool, arguments, &validation_error)) {
    result->error = std::move(validation_error);
    return false;
  }

  seen_ids->insert(id);
  AgentModelEvent event;
  event.type = AgentModelEventType::kToolCall;
  event.tool_call_id = std::move(id);
  event.tool_name = std::move(name);
  event.arguments = std::move(arguments);
  result->events.push_back(std::move(event));
  return true;
}

void AppendCompleted(AgentModelParseResult* result) {
  if (result->events.size() >= kMaxModelEvents) {
    result->error = "too many model events";
    return;
  }
  AgentModelEvent event;
  event.type = AgentModelEventType::kCompleted;
  result->events.push_back(std::move(event));
}

void AppendRefused(std::string_view reason, AgentModelParseResult* result) {
  if (result->events.size() >= kMaxModelEvents) {
    result->error = "too many model events";
    return;
  }
  AgentModelEvent event;
  event.type = AgentModelEventType::kRefused;
  event.text = std::string(reason.substr(0, kMaxToolDescriptionBytes));
  result->events.push_back(std::move(event));
}

bool ReadNonNegativeInteger(const base::DictValue& dict,
                            std::string_view key,
                            int64_t* output) {
  if (const std::optional<int> value = dict.FindInt(key)) {
    if (*value < 0) {
      return false;
    }
    *output = *value;
    return true;
  }
  if (const std::optional<double> value = dict.FindDouble(key)) {
    if (!std::isfinite(*value) || *value < 0 || *value > kMaxSafeInteger ||
        std::floor(*value) != *value) {
      return false;
    }
    *output = static_cast<int64_t>(*value);
    return true;
  }
  return false;
}

AgentModelParseResult ParseOpenAINonStream(
    const base::DictValue& root,
    const std::vector<AgentModelToolDefinition>& tools) {
  AgentModelParseResult result;
  base::flat_set<std::string> seen_ids;
  size_t text_bytes = 0;
  const base::ListValue* output = root.FindList("output");
  if (!output) {
    return Fail("OpenAI response has no output list");
  }
  for (const base::Value& item_value : *output) {
    const base::DictValue* item = item_value.GetIfDict();
    const std::string* type = item ? item->FindString("type") : nullptr;
    if (!type) {
      return Fail("OpenAI response item has no type");
    }
    if (*type == "message") {
      const base::ListValue* content = item->FindList("content");
      if (!content) {
        return Fail("OpenAI message has no content");
      }
      for (const base::Value& part_value : *content) {
        const base::DictValue* part = part_value.GetIfDict();
        const std::string* part_type =
            part ? part->FindString("type") : nullptr;
        if (!part_type) {
          return Fail("OpenAI message part has no type");
        }
        if (*part_type == "output_text") {
          const std::string* text = part->FindString("text");
          if (!text || !AppendText(*text, &result, &text_bytes)) {
            return result;
          }
        } else if (*part_type == "refusal") {
          AppendRefused(part->FindString("refusal")
                            ? *part->FindString("refusal")
                            : "model refused",
                        &result);
        }
      }
    } else if (*type == "function_call") {
      const std::string* id = item->FindString("call_id");
      const std::string* name = item->FindString("name");
      const std::string* arguments = item->FindString("arguments");
      if (!id || !name || !arguments ||
          !AppendToolCall(*id, *name, base::Value(*arguments), tools, &seen_ids,
                          &result)) {
        if (result.error.empty()) {
          result.error = "OpenAI function call is incomplete";
        }
        return result;
      }
    }
  }
  if (const base::DictValue* usage = root.FindDict("usage")) {
    int64_t input = 0;
    int64_t output_tokens = 0;
    if (!ReadNonNegativeInteger(*usage, "input_tokens", &input) ||
        !ReadNonNegativeInteger(*usage, "output_tokens", &output_tokens) ||
        !AppendUsage(input, output_tokens, &result)) {
      if (result.error.empty()) {
        result.error = "OpenAI usage is invalid";
      }
      return result;
    }
  }
  const std::string* status = root.FindString("status");
  if (!status || (*status != "completed" && *status != "incomplete")) {
    return Fail("OpenAI response did not complete");
  }
  AppendCompleted(&result);
  return result;
}

AgentModelParseResult ParseAnthropicNonStream(
    const base::DictValue& root,
    const std::vector<AgentModelToolDefinition>& tools) {
  AgentModelParseResult result;
  base::flat_set<std::string> seen_ids;
  size_t text_bytes = 0;
  const base::ListValue* content = root.FindList("content");
  if (!content) {
    return Fail("Anthropic response has no content list");
  }
  for (const base::Value& block_value : *content) {
    const base::DictValue* block = block_value.GetIfDict();
    const std::string* type = block ? block->FindString("type") : nullptr;
    if (!type) {
      return Fail("Anthropic content block has no type");
    }
    if (*type == "text") {
      const std::string* text = block->FindString("text");
      if (!text || !AppendText(*text, &result, &text_bytes)) {
        return result;
      }
    } else if (*type == "tool_use") {
      const std::string* id = block->FindString("id");
      const std::string* name = block->FindString("name");
      const base::Value* input = block->Find("input");
      if (!id || !name || !input ||
          !AppendToolCall(*id, *name, *input, tools, &seen_ids, &result)) {
        if (result.error.empty()) {
          result.error = "Anthropic tool call is incomplete";
        }
        return result;
      }
    }
  }
  if (const base::DictValue* usage = root.FindDict("usage")) {
    int64_t input = 0;
    int64_t output_tokens = 0;
    if (!ReadNonNegativeInteger(*usage, "input_tokens", &input) ||
        !ReadNonNegativeInteger(*usage, "output_tokens", &output_tokens) ||
        !AppendUsage(input, output_tokens, &result)) {
      if (result.error.empty()) {
        result.error = "Anthropic usage is invalid";
      }
      return result;
    }
  }
  const std::string* stop_reason = root.FindString("stop_reason");
  if (!stop_reason ||
      (*stop_reason != "end_turn" && *stop_reason != "tool_use" &&
       *stop_reason != "max_tokens")) {
    return Fail("Anthropic response did not complete");
  }
  AppendCompleted(&result);
  return result;
}

AgentModelParseResult ParseGeminiChunk(
    const base::DictValue& root,
    const std::vector<AgentModelToolDefinition>& tools,
    int* next_tool_id,
    base::flat_set<std::string>* seen_ids,
    size_t* text_bytes,
    AgentModelParseResult result) {
  const base::ListValue* candidates = root.FindList("candidates");
  if (!candidates || candidates->empty()) {
    return Fail("Gemini response has no candidate");
  }
  const base::DictValue* candidate = (*candidates)[0].GetIfDict();
  const base::DictValue* content =
      candidate ? candidate->FindDict("content") : nullptr;
  const base::ListValue* parts = content ? content->FindList("parts") : nullptr;
  if (!parts) {
    return Fail("Gemini candidate has no content parts");
  }
  for (const base::Value& part_value : *parts) {
    const base::DictValue* part = part_value.GetIfDict();
    if (!part) {
      return Fail("Gemini content part is invalid");
    }
    if (const std::string* text = part->FindString("text")) {
      if (!AppendText(*text, &result, text_bytes)) {
        return result;
      }
    }
    if (const base::DictValue* call = part->FindDict("functionCall")) {
      const std::string* name = call->FindString("name");
      const base::Value* args = call->Find("args");
      const std::string id = "gemini-call-" + std::to_string((*next_tool_id)++);
      if (!name || !args ||
          !AppendToolCall(id, *name, *args, tools, seen_ids, &result)) {
        if (result.error.empty()) {
          result.error = "Gemini function call is incomplete";
        }
        return result;
      }
    }
  }
  if (const base::DictValue* usage = root.FindDict("usageMetadata")) {
    int64_t input = 0;
    int64_t output_tokens = 0;
    if (!ReadNonNegativeInteger(*usage, "promptTokenCount", &input) ||
        !ReadNonNegativeInteger(*usage, "candidatesTokenCount",
                                &output_tokens) ||
        !AppendUsage(input, output_tokens, &result)) {
      if (result.error.empty()) {
        result.error = "Gemini usage is invalid";
      }
      return result;
    }
  }
  return result;
}

AgentModelParseResult ParseGeminiNonStream(
    const base::DictValue& root,
    const std::vector<AgentModelToolDefinition>& tools) {
  int next_tool_id = 1;
  base::flat_set<std::string> seen_ids;
  size_t text_bytes = 0;
  AgentModelParseResult result =
      ParseGeminiChunk(root, tools, &next_tool_id, &seen_ids, &text_bytes, {});
  if (!result.ok()) {
    return result;
  }
  AppendCompleted(&result);
  return result;
}

std::vector<std::string> ExtractSseData(std::string_view body,
                                        std::string* error) {
  std::vector<std::string> payloads;
  std::string current;
  for (std::string_view line : base::SplitStringPiece(
           body, "\n", base::KEEP_WHITESPACE, base::SPLIT_WANT_ALL)) {
    if (line.ends_with('\r')) {
      line.remove_suffix(1);
    }
    if (line.empty()) {
      if (!current.empty()) {
        payloads.push_back(std::move(current));
        current.clear();
      }
      continue;
    }
    if (line.starts_with(':') || line.starts_with("event:") ||
        line.starts_with("id:") || line.starts_with("retry:")) {
      continue;
    }
    if (!line.starts_with("data:")) {
      *error = "stream contains a non-SSE field";
      return {};
    }
    line.remove_prefix(5);
    if (line.starts_with(' ')) {
      line.remove_prefix(1);
    }
    if (!current.empty()) {
      current.push_back('\n');
    }
    current.append(line);
  }
  if (!current.empty()) {
    payloads.push_back(std::move(current));
  }
  return payloads;
}

AgentModelParseResult ParseOpenAIStream(
    const std::vector<std::string>& payloads,
    const std::vector<AgentModelToolDefinition>& tools) {
  AgentModelParseResult result;
  std::map<std::string, PendingToolCall> pending;
  base::flat_set<std::string> seen_ids;
  size_t text_bytes = 0;
  bool completed = false;

  for (const std::string& payload : payloads) {
    if (payload == "[DONE]") {
      continue;
    }
    std::optional<base::Value> parsed =
        base::JSONReader::Read(payload, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) {
      return Fail("OpenAI stream event is not valid JSON");
    }
    const base::DictValue& event = parsed->GetDict();
    const std::string* type = event.FindString("type");
    if (!type) {
      return Fail("OpenAI stream event has no type");
    }
    if (*type == "response.output_text.delta") {
      const std::string* delta = event.FindString("delta");
      if (!delta || !AppendText(*delta, &result, &text_bytes)) {
        if (result.error.empty()) {
          result.error = "OpenAI text delta is invalid";
        }
        return result;
      }
    } else if (*type == "response.refusal.delta") {
      AppendRefused(event.FindString("delta") ? *event.FindString("delta")
                                              : "model refused",
                    &result);
    } else if (*type == "response.output_item.added") {
      const base::DictValue* item = event.FindDict("item");
      const std::string* item_type = item ? item->FindString("type") : nullptr;
      if (item_type && *item_type == "function_call") {
        const std::string* item_id = item->FindString("id");
        const std::string* call_id = item->FindString("call_id");
        const std::string* name = item->FindString("name");
        if (!item_id || !call_id || !name || pending.contains(*item_id)) {
          return Fail("OpenAI tool stream start is invalid or duplicated");
        }
        pending.emplace(*item_id,
                        PendingToolCall{.id = *call_id, .name = *name});
      }
    } else if (*type == "response.function_call_arguments.delta") {
      const std::string* item_id = event.FindString("item_id");
      const std::string* delta = event.FindString("delta");
      auto it = item_id ? pending.find(*item_id) : pending.end();
      if (it == pending.end() || !delta ||
          it->second.arguments.size() + delta->size() >
              kMaxToolArgumentsBytes) {
        return Fail("OpenAI tool argument delta is invalid");
      }
      it->second.arguments.append(*delta);
    } else if (*type == "response.function_call_arguments.done") {
      const std::string* item_id = event.FindString("item_id");
      auto it = item_id ? pending.find(*item_id) : pending.end();
      if (it == pending.end() || it->second.emitted) {
        return Fail("OpenAI tool stream completion is invalid");
      }
      if (const std::string* arguments = event.FindString("arguments")) {
        it->second.arguments = *arguments;
      }
      if (!AppendToolCall(it->second.id, it->second.name,
                          base::Value(it->second.arguments), tools, &seen_ids,
                          &result)) {
        return result;
      }
      it->second.emitted = true;
    } else if (*type == "response.completed") {
      const base::DictValue* response = event.FindDict("response");
      const base::DictValue* usage =
          response ? response->FindDict("usage") : nullptr;
      if (usage) {
        int64_t input = 0;
        int64_t output = 0;
        if (!ReadNonNegativeInteger(*usage, "input_tokens", &input) ||
            !ReadNonNegativeInteger(*usage, "output_tokens", &output) ||
            !AppendUsage(input, output, &result)) {
          if (result.error.empty()) {
            result.error = "OpenAI stream usage is invalid";
          }
          return result;
        }
      }
      completed = true;
    } else if (*type == "error" || *type == "response.failed" ||
               *type == "response.incomplete") {
      return Fail("OpenAI stream reported failure");
    }
  }
  if (!completed || std::ranges::any_of(pending, [](const auto& entry) {
        return !entry.second.emitted;
      })) {
    return Fail("OpenAI stream ended before completion");
  }
  AppendCompleted(&result);
  return result;
}

AgentModelParseResult ParseAnthropicStream(
    const std::vector<std::string>& payloads,
    const std::vector<AgentModelToolDefinition>& tools) {
  AgentModelParseResult result;
  std::map<int, PendingToolCall> pending;
  base::flat_set<std::string> seen_ids;
  size_t text_bytes = 0;
  int64_t input_tokens = 0;
  int64_t output_tokens = 0;
  bool have_input_usage = false;
  bool have_output_usage = false;
  bool completed = false;

  for (const std::string& payload : payloads) {
    std::optional<base::Value> parsed =
        base::JSONReader::Read(payload, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) {
      return Fail("Anthropic stream event is not valid JSON");
    }
    const base::DictValue& event = parsed->GetDict();
    const std::string* type = event.FindString("type");
    if (!type) {
      return Fail("Anthropic stream event has no type");
    }
    if (*type == "message_start") {
      const base::DictValue* message = event.FindDict("message");
      const base::DictValue* usage =
          message ? message->FindDict("usage") : nullptr;
      have_input_usage = usage && ReadNonNegativeInteger(*usage, "input_tokens",
                                                         &input_tokens);
    } else if (*type == "content_block_start") {
      const std::optional<int> index = event.FindInt("index");
      const base::DictValue* block = event.FindDict("content_block");
      const std::string* block_type =
          block ? block->FindString("type") : nullptr;
      if (block_type && *block_type == "tool_use") {
        const std::string* id = block->FindString("id");
        const std::string* name = block->FindString("name");
        if (!index || !id || !name || pending.contains(*index)) {
          return Fail("Anthropic tool stream start is invalid or duplicated");
        }
        pending.emplace(*index, PendingToolCall{.id = *id, .name = *name});
      }
    } else if (*type == "content_block_delta") {
      const std::optional<int> index = event.FindInt("index");
      const base::DictValue* delta = event.FindDict("delta");
      const std::string* delta_type =
          delta ? delta->FindString("type") : nullptr;
      if (!delta_type) {
        return Fail("Anthropic content delta is invalid");
      }
      if (*delta_type == "text_delta") {
        const std::string* text = delta->FindString("text");
        if (!text || !AppendText(*text, &result, &text_bytes)) {
          if (result.error.empty()) {
            result.error = "Anthropic text delta is invalid";
          }
          return result;
        }
      } else if (*delta_type == "input_json_delta") {
        auto it = index ? pending.find(*index) : pending.end();
        const std::string* partial = delta->FindString("partial_json");
        if (it == pending.end() || !partial ||
            it->second.arguments.size() + partial->size() >
                kMaxToolArgumentsBytes) {
          return Fail("Anthropic tool argument delta is invalid");
        }
        it->second.arguments.append(*partial);
      }
    } else if (*type == "content_block_stop") {
      const std::optional<int> index = event.FindInt("index");
      auto it = index ? pending.find(*index) : pending.end();
      if (it != pending.end()) {
        if (it->second.emitted ||
            !AppendToolCall(it->second.id, it->second.name,
                            base::Value(it->second.arguments), tools, &seen_ids,
                            &result)) {
          if (result.error.empty()) {
            result.error = "Anthropic tool stream completion is invalid";
          }
          return result;
        }
        it->second.emitted = true;
      }
    } else if (*type == "message_delta") {
      const base::DictValue* usage = event.FindDict("usage");
      have_output_usage = usage && ReadNonNegativeInteger(
                                       *usage, "output_tokens", &output_tokens);
    } else if (*type == "message_stop") {
      completed = true;
    } else if (*type == "error") {
      return Fail("Anthropic stream reported failure");
    }
  }
  if (!completed || std::ranges::any_of(pending, [](const auto& entry) {
        return !entry.second.emitted;
      })) {
    return Fail("Anthropic stream ended before completion");
  }
  if ((have_input_usage || have_output_usage) &&
      !AppendUsage(input_tokens, output_tokens, &result)) {
    return result;
  }
  AppendCompleted(&result);
  return result;
}

AgentModelParseResult ParseGeminiStream(
    const std::vector<std::string>& payloads,
    const std::vector<AgentModelToolDefinition>& tools) {
  AgentModelParseResult result;
  int next_tool_id = 1;
  base::flat_set<std::string> seen_ids;
  size_t text_bytes = 0;
  bool saw_chunk = false;
  for (const std::string& payload : payloads) {
    std::optional<base::Value> parsed =
        base::JSONReader::Read(payload, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) {
      return Fail("Gemini stream event is not valid JSON");
    }
    result = ParseGeminiChunk(parsed->GetDict(), tools, &next_tool_id,
                              &seen_ids, &text_bytes, std::move(result));
    if (!result.ok()) {
      return result;
    }
    saw_chunk = true;
  }
  if (!saw_chunk) {
    return Fail("Gemini stream is empty");
  }
  AppendCompleted(&result);
  return result;
}

base::DictValue BuildOpenAITool(const AgentModelToolDefinition& tool) {
  base::DictValue value;
  value.Set("type", "function");
  value.Set("name", tool.name);
  value.Set("description", tool.description);
  value.Set("parameters", tool.input_schema.Clone());
  value.Set("strict", true);
  return value;
}

base::DictValue BuildAnthropicTool(const AgentModelToolDefinition& tool) {
  base::DictValue value;
  value.Set("name", tool.name);
  value.Set("description", tool.description);
  value.Set("input_schema", tool.input_schema.Clone());
  return value;
}

base::DictValue BuildGeminiTool(const AgentModelToolDefinition& tool) {
  base::DictValue value;
  value.Set("name", tool.name);
  value.Set("description", tool.description);
  value.Set("parameters", tool.input_schema.Clone());
  return value;
}

bool ValidateRequest(const AgentModelRequest& request, std::string* error) {
  if (!IsValidText(request.model, 256, false) ||
      !IsValidText(request.system_prompt, kMaxPromptBytes, false) ||
      !IsValidText(request.user_prompt, kMaxPromptBytes, false) ||
      request.max_output_tokens <= 0 || request.max_output_tokens > 32768 ||
      request.tools.empty() || request.tools.size() > kMaxToolCount) {
    *error = "invalid model request";
    return false;
  }
  base::flat_set<std::string> names;
  for (const AgentModelToolDefinition& tool : request.tools) {
    std::string schema_json;
    const std::string* schema_type = tool.input_schema.FindString("type");
    if (!IsValidToolName(tool.name) || !names.insert(tool.name).second ||
        !IsValidText(tool.description, kMaxToolDescriptionBytes, false) ||
        !SerializeValue(tool.input_schema, &schema_json) ||
        schema_json.size() > kMaxToolArgumentsBytes || !schema_type ||
        *schema_type != "object" || !tool.input_schema.FindDict("properties")) {
      *error = "invalid or duplicated tool definition";
      return false;
    }
  }
  return true;
}

}  // namespace

std::optional<std::string> BuildAgentModelRequestBody(
    const AgentModelRequest& request,
    std::string* error) {
  if (!error) {
    return std::nullopt;
  }
  error->clear();
  if (!ValidateRequest(request, error)) {
    return std::nullopt;
  }

  base::DictValue payload;
  base::ListValue tools;
  switch (request.provider) {
    case AgentModelProvider::kOpenAICompatible:
      payload.Set("model", request.model);
      payload.Set("instructions", request.system_prompt);
      payload.Set("input", request.user_prompt);
      payload.Set("max_output_tokens", request.max_output_tokens);
      payload.Set("parallel_tool_calls", false);
      payload.Set("store", false);
      payload.Set("stream", request.stream);
      payload.Set("tool_choice", "auto");
      for (const AgentModelToolDefinition& tool : request.tools) {
        tools.Append(BuildOpenAITool(tool));
      }
      payload.Set("tools", std::move(tools));
      break;
    case AgentModelProvider::kAnthropic: {
      payload.Set("model", request.model);
      payload.Set("system", request.system_prompt);
      payload.Set("max_tokens", request.max_output_tokens);
      payload.Set("stream", request.stream);
      base::DictValue message;
      message.Set("role", "user");
      message.Set("content", request.user_prompt);
      base::ListValue messages;
      messages.Append(std::move(message));
      payload.Set("messages", std::move(messages));
      for (const AgentModelToolDefinition& tool : request.tools) {
        tools.Append(BuildAnthropicTool(tool));
      }
      payload.Set("tools", std::move(tools));
      break;
    }
    case AgentModelProvider::kGemini: {
      base::DictValue system_part;
      system_part.Set("text", request.system_prompt);
      base::ListValue system_parts;
      system_parts.Append(std::move(system_part));
      base::DictValue system_instruction;
      system_instruction.Set("parts", std::move(system_parts));
      payload.Set("systemInstruction", std::move(system_instruction));

      base::DictValue user_part;
      user_part.Set("text", request.user_prompt);
      base::ListValue user_parts;
      user_parts.Append(std::move(user_part));
      base::DictValue content;
      content.Set("role", "user");
      content.Set("parts", std::move(user_parts));
      base::ListValue contents;
      contents.Append(std::move(content));
      payload.Set("contents", std::move(contents));

      for (const AgentModelToolDefinition& tool : request.tools) {
        tools.Append(BuildGeminiTool(tool));
      }
      base::DictValue declarations;
      declarations.Set("functionDeclarations", std::move(tools));
      base::ListValue gemini_tools;
      gemini_tools.Append(std::move(declarations));
      payload.Set("tools", std::move(gemini_tools));

      base::DictValue generation_config;
      generation_config.Set("maxOutputTokens", request.max_output_tokens);
      payload.Set("generationConfig", std::move(generation_config));
      break;
    }
  }

  std::string json;
  if (!base::JSONWriter::Write(payload, &json)) {
    *error = "failed to encode model request";
    return std::nullopt;
  }
  return json;
}

AgentModelParseResult ParseAgentModelResponse(
    AgentModelProvider provider,
    std::string_view body,
    bool is_stream,
    const std::vector<AgentModelToolDefinition>& allowed_tools) {
  if (body.empty() || body.size() > kMaxResponseBytes ||
      !base::IsStringUTF8(body)) {
    return Fail("model response is empty, too large, or not UTF-8");
  }
  if (is_stream) {
    std::string error;
    std::vector<std::string> payloads = ExtractSseData(body, &error);
    if (!error.empty()) {
      return Fail(std::move(error));
    }
    switch (provider) {
      case AgentModelProvider::kOpenAICompatible:
        return ParseOpenAIStream(payloads, allowed_tools);
      case AgentModelProvider::kAnthropic:
        return ParseAnthropicStream(payloads, allowed_tools);
      case AgentModelProvider::kGemini:
        return ParseGeminiStream(payloads, allowed_tools);
    }
  }

  std::optional<base::Value> parsed =
      base::JSONReader::Read(body, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    return Fail("model response is not a JSON object");
  }
  switch (provider) {
    case AgentModelProvider::kOpenAICompatible:
      return ParseOpenAINonStream(parsed->GetDict(), allowed_tools);
    case AgentModelProvider::kAnthropic:
      return ParseAnthropicNonStream(parsed->GetDict(), allowed_tools);
    case AgentModelProvider::kGemini:
      return ParseGeminiNonStream(parsed->GetDict(), allowed_tools);
  }
}

bool ValidateAgentToolArguments(const AgentModelToolDefinition& tool,
                                const base::DictValue& arguments,
                                std::string* error) {
  if (!error) {
    return false;
  }
  error->clear();
  std::string serialized;
  if (!SerializeValue(arguments, &serialized) ||
      serialized.size() > kMaxToolArgumentsBytes) {
    *error = "tool arguments are too large";
    return false;
  }
  return ValidateSchemaNode(base::Value(arguments.Clone()), tool.input_schema,
                            0, error);
}

void AgentModelCapabilityTracker::RecordToolProbeSuccess() {
  tool_probe_succeeded_ = true;
  consecutive_schema_failures_ = 0;
}

void AgentModelCapabilityTracker::RecordSchemaSuccess() {
  consecutive_schema_failures_ = 0;
}

void AgentModelCapabilityTracker::RecordSchemaFailure() {
  consecutive_schema_failures_ = std::min(consecutive_schema_failures_ + 1, 2);
}

bool AgentModelCapabilityTracker::AllowsActionModes() const {
  return tool_probe_succeeded_ && consecutive_schema_failures_ < 2;
}

}  // namespace aegis::agent
