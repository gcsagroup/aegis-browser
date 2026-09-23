// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_ACCOUNTING_JSON_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_ACCOUNTING_JSON_H_

#include "base/strings/string_number_conversions.h"
#include "base/values.h"
#include "chrome/browser/aegis/agent/agent_model_accounting.h"

namespace aegis::agent {
inline void WriteOptionalTokenValue(base::DictValue* value,
                                    std::string_view key,
                                    const std::optional<int64_t>& number) {
  if (number) {
    value->Set(key, base::NumberToString(*number));
  } else {
    value->Set(key, base::Value());
  }
}

inline bool ReadOptionalTokenValue(const base::DictValue& value,
                                   std::string_view key,
                                   std::optional<int64_t>* number) {
  const auto* field = value.Find(key);
  if (!field || field->is_none()) {
    number->reset();
    return true;
  }
  int64_t parsed = 0;
  if (!field->is_string() ||
      !base::StringToInt64(field->GetString(), &parsed) || parsed < 0) {
    return false;
  }
  *number = parsed;
  return true;
}

inline base::DictValue SerializeTokenPrices(const AgentTokenPrices& prices) {
  base::DictValue value;
  WriteOptionalTokenValue(&value, "input", prices.input);
  WriteOptionalTokenValue(&value, "cached_input", prices.cached_input);
  WriteOptionalTokenValue(&value, "output", prices.output);
  return value;
}

inline bool ReadTokenPrices(const base::DictValue& parent,
                            std::string_view key,
                            AgentTokenPrices* prices) {
  if (!parent.contains(key)) {
    return true;
  }
  const auto* value = parent.FindDict(key);
  return value && ReadOptionalTokenValue(*value, "input", &prices->input) &&
         ReadOptionalTokenValue(*value, "cached_input",
                                &prices->cached_input) &&
         ReadOptionalTokenValue(*value, "output", &prices->output) &&
         prices->IsValid();
}

inline base::DictValue SerializeModelAttempt(const AgentModelAttempt& attempt) {
  base::DictValue value;
  value.Set("kind", attempt.kind);
  value.Set("model", attempt.model);
  value.Set("effort", attempt.effort);
  value.Set("succeeded", attempt.succeeded);
  value.Set("phase", attempt.phase);
  value.Set("observation_id", attempt.observation_id);
  value.Set("completed", attempt.completed);
  value.Set("latency_ms", base::NumberToString(attempt.latency_ms));
  value.Set("prices", SerializeTokenPrices(attempt.prices));
  WriteOptionalTokenValue(&value, "input_tokens", attempt.input_tokens);
  WriteOptionalTokenValue(&value, "cached_input_tokens",
                          attempt.cached_input_tokens);
  WriteOptionalTokenValue(&value, "output_tokens", attempt.output_tokens);
  WriteOptionalTokenValue(&value, "reasoning_tokens", attempt.reasoning_tokens);
  return value;
}

inline std::optional<AgentModelAttempt> ReadModelAttempt(
    const base::Value& item) {
  const auto* value = item.GetIfDict();
  if (!value) {
    return std::nullopt;
  }
  const auto* kind = value->FindString("kind");
  const auto* model = value->FindString("model");
  const auto* effort = value->FindString("effort");
  const auto* latency = value->FindString("latency_ms");
  const auto succeeded = value->FindBool("succeeded");
  AgentModelAttempt attempt;
  if (!kind || !model || !effort || !latency || !succeeded ||
      !base::StringToInt64(*latency, &attempt.latency_ms) ||
      !ReadOptionalTokenValue(*value, "input_tokens", &attempt.input_tokens) ||
      !ReadOptionalTokenValue(*value, "cached_input_tokens",
                              &attempt.cached_input_tokens) ||
      !ReadOptionalTokenValue(*value, "output_tokens",
                              &attempt.output_tokens) ||
      !ReadOptionalTokenValue(*value, "reasoning_tokens",
                              &attempt.reasoning_tokens) ||
      !ReadTokenPrices(*value, "prices", &attempt.prices)) {
    return std::nullopt;
  }
  attempt.kind = *kind;
  attempt.model = *model;
  attempt.effort = *effort;
  attempt.succeeded = *succeeded;
  if (const auto* phase = value->FindString("phase")) {
    attempt.phase = *phase;
  }
  if (const auto* id = value->FindString("observation_id")) {
    attempt.observation_id = *id;
  }
  if (value->contains("completed")) {
    const auto completed = value->FindBool("completed");
    if (!completed) {
      return std::nullopt;
    }
    attempt.completed = *completed;
  }
  return attempt.IsValid() ? std::make_optional(attempt) : std::nullopt;
}
}  // namespace aegis::agent
#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_ACCOUNTING_JSON_H_
