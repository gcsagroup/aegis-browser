// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_ACCOUNTING_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_ACCOUNTING_H_

#include <cmath>
#include <cstdint>
#include <optional>
#include <string>

namespace aegis::agent {
struct AgentTokenPrices {
  std::optional<int64_t> input;
  std::optional<int64_t> cached_input;
  std::optional<int64_t> output;
  bool IsValid() const {
    return (!input || *input >= 0) && (!cached_input || *cached_input >= 0) &&
           (!output || *output >= 0);
  }
  bool operator==(const AgentTokenPrices&) const = default;
};

struct AgentModelAttempt {
  std::string kind = "generation";
  std::string model;
  std::string effort;
  std::optional<int64_t> input_tokens;
  std::optional<int64_t> cached_input_tokens;
  std::optional<int64_t> output_tokens;
  std::optional<int64_t> reasoning_tokens;
  AgentTokenPrices prices;
  int64_t latency_ms = 0;
  bool succeeded = false;
  std::string phase = "task";
  std::string observation_id;
  bool completed = true;

  bool IsValid() const {
    constexpr int64_t kMax = 9007199254740991LL;
    const auto valid = [](const auto& value) {
      return !value || (*value >= 0 && *value <= kMax);
    };
    return observation_id.size() <= 64 &&
           (completed || !observation_id.empty()) &&
           (phase == "task" || phase == "screening") &&
           (kind == "generation" || kind == "typesafe") &&
           model.size() <= 256 && effort.size() <= 16 && latency_ms >= 0 &&
           valid(input_tokens) && valid(cached_input_tokens) &&
           valid(output_tokens) && valid(reasoning_tokens) &&
           prices.IsValid() &&
           (!cached_input_tokens || !input_tokens ||
            *cached_input_tokens <= *input_tokens) &&
           (!reasoning_tokens || !output_tokens ||
            *reasoning_tokens <= *output_tokens);
  }
};

inline std::optional<long double> EstimateAgentAttemptMicrousd(
    const AgentModelAttempt& attempt) {
  if (!attempt.IsValid() || !attempt.completed || !attempt.input_tokens ||
      !attempt.output_tokens || !attempt.prices.input ||
      !attempt.prices.output) {
    return std::nullopt;
  }
  // Missing cache detail is safe only when caching cannot affect the price.
  if ((!attempt.cached_input_tokens &&
       attempt.prices.cached_input != attempt.prices.input) ||
      (attempt.cached_input_tokens.value_or(0) > 0 &&
       !attempt.prices.cached_input)) {
    return std::nullopt;
  }
  const int64_t cached = attempt.cached_input_tokens.value_or(0);
  const long double input =
      static_cast<long double>(*attempt.input_tokens - cached);
  const long double cost =
      input * *attempt.prices.input +
      static_cast<long double>(cached) *
          attempt.prices.cached_input.value_or(0) +
      static_cast<long double>(*attempt.output_tokens) * *attempt.prices.output;
  // Reasoning tokens are already included in output_tokens.
  return std::isfinite(cost) ? std::make_optional(cost / 1000000.L)
                             : std::nullopt;
}
}  // namespace aegis::agent
#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_ACCOUNTING_H_
