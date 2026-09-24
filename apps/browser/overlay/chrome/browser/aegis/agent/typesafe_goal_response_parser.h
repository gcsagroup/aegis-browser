// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_GOAL_RESPONSE_PARSER_H_
#define CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_GOAL_RESPONSE_PARSER_H_

#include <optional>
#include <string>
#include <string_view>

#include "base/time/time.h"
#include "chrome/browser/aegis/agent/agent_model_router.h"
#include "chrome/browser/aegis/agent/agent_planner.h"
#include "chrome/browser/aegis/agent/typesafe_choice_contract.h"

namespace aegis::agent {

inline constexpr double kTypeSafeGoalRouteMinimumConfidence = 0.8;

struct TypeSafeGoalAnalysis {
  AgentGoalRoute route;
  AgentModelRequirements requirements;
  std::string model;
  TypeSafeChoiceValue workflow;
  TypeSafeChoiceValue entry_kind;
  TypeSafeChoiceValue reasoning_need;
  TypeSafeChoiceValue context_need;
  TypeSafeChoiceValue output_need;
  int input_tokens = 0;
  int output_tokens = 0;
  bool usage_present = false;
  base::TimeDelta latency;
};

// Validates the bounded TypeSafe response schema and maps it to an existing
// Aegis workflow. Network request state remains owned by the router client.
class TypeSafeGoalResponseParser {
 public:
  static std::optional<TypeSafeGoalAnalysis> Parse(
      std::string_view body,
      std::string_view original_goal,
      std::string* error);
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_GOAL_RESPONSE_PARSER_H_
