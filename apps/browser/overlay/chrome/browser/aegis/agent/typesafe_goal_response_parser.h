// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_GOAL_RESPONSE_PARSER_H_
#define CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_GOAL_RESPONSE_PARSER_H_

#include <optional>
#include <string>
#include <string_view>

#include "chrome/browser/aegis/agent/agent_planner.h"

namespace aegis::agent {

inline constexpr double kTypeSafeGoalRouteMinimumConfidence = 0.8;

// Validates the bounded TypeSafe response schema and maps it to an existing
// Aegis workflow. Network request state remains owned by the router client.
class TypeSafeGoalResponseParser {
 public:
  static std::optional<AgentGoalRoute> Parse(std::string_view body,
                                             std::string_view original_goal,
                                             std::string* error);
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_GOAL_RESPONSE_PARSER_H_
