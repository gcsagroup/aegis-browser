// Copyright 2026 GCSA
#include <cassert>
#include <iostream>
#include "chrome/browser/aegis/agent/agent_generation_profile.h"
#include "chrome/browser/aegis/agent/agent_model_accounting.h"

int main() {
  using namespace aegis::agent;
  AgentGenerationPolicy policy{
      .supported_efforts = {"low", "medium", "high", "xhigh"},
      .default_profile = {"medium", 8192},
      .basic_profile = {"low", 2048},
      .strong_profile = {"high", 16384}};
  assert(policy.IsValid("openai"));
  assert(!policy.IsValid("anthropic"));
  assert(policy.Select(true, true, false).effort == "medium");
  assert(policy.Select(false, true, false).effort == "low");
  assert(policy.Select(false, false, true).max_output_tokens == 16384);
  assert(policy.Select(false, false, false).effort == "medium");
  assert(AgentGenerationOutputLimit(policy.strong_profile, 512) == 16384);
  policy.basic_profile.effort = "none";
  assert(!policy.IsValid("openai"));
  policy.basic_profile.effort = "xhigh";
  assert(policy.IsValid("openai"));
  AgentGenerationPolicy legacy;
  assert(legacy.IsValid("custom"));
  assert(legacy.Select(false, true, false).effort.empty());
  assert(AgentGenerationOutputLimit({}, 1024) == 1024);
  AgentModelAttempt attempt{.model = "model", .input_tokens = 1000,
      .cached_input_tokens = 400, .output_tokens = 200, .reasoning_tokens = 150,
      .prices = {.input = 2000000, .cached_input = 500000, .output = 8000000}};
  assert(EstimateAgentAttemptMicrousd(attempt) == 3000.L);
  attempt.observation_id = "pending";
  attempt.completed = false;
  assert(!EstimateAgentAttemptMicrousd(attempt));
  attempt.completed = true;
  attempt.reasoning_tokens = 0;
  assert(EstimateAgentAttemptMicrousd(attempt) == 3000.L);
  attempt.cached_input_tokens.reset();
  assert(!EstimateAgentAttemptMicrousd(attempt));
  attempt.prices.cached_input = attempt.prices.input;
  assert(EstimateAgentAttemptMicrousd(attempt) == 3600.L);
  attempt.output_tokens.reset();
  assert(!EstimateAgentAttemptMicrousd(attempt));
  attempt.input_tokens = 0;
  attempt.output_tokens = 0;
  assert(EstimateAgentAttemptMicrousd(attempt) == 0.L);
  attempt.prices.output.reset();
  assert(!EstimateAgentAttemptMicrousd(attempt));
  std::cout << "Agent generation profile and split-token accounting PASS\n";
}
