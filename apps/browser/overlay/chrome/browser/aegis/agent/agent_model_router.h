// Copyright 2026 GCSA
// Browser-owned deterministic generation-model routing.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_ROUTER_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_ROUTER_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "chrome/browser/aegis/agent/agent_types.h"

namespace aegis::agent {

enum class AgentReasoningNeed {
  kUnknown = 0,
  kBasic = 1,
  kStrong = 2,
};

enum class AgentContextNeed {
  kUnknown = 0,
  kShort = 1,
  kLong = 2,
};

enum class AgentOutputNeed {
  kUnknown = 0,
  kShortExtraction = 1,
  kComprehensive = 2,
  kMultiStep = 3,
};

struct AgentModelRequirements {
  AgentReasoningNeed reasoning = AgentReasoningNeed::kUnknown;
  AgentContextNeed context = AgentContextNeed::kUnknown;
  AgentOutputNeed output = AgentOutputNeed::kUnknown;
  bool requires_tool_calls = false;
};

struct AgentModelCatalogEntry {
  std::string id;
  AgentModelDestination destination;
  bool enabled = false;
  bool authorized = false;
  bool supports_tool_calls = false;
  bool supports_long_context = false;
  bool supports_strong_reasoning = false;
  int quality_score = 0;  // 0..100, supplied by an evaluated catalog.
  int latency_score = 0;  // 0..100; lower is faster.
  // Unknown cost remains null and is never treated as free.
  std::optional<int64_t> cost_microusd_per_million_tokens;
  int priority = 0;
  AgentGenerationPolicy generation_policy;
  AgentTokenPrices token_prices;

  bool IsValid() const;
};

struct AgentModelSelectionInput {
  AgentModelSelectionMode mode = AgentModelSelectionMode::kFixed;
  std::optional<AgentModelDestination> fixed_destination;
  AgentModelRequirements requirements;
  std::vector<AgentModelCatalogEntry> catalog;
  int catalog_revision = 0;
};

struct AgentModelRoutePlan {
  AgentModelDestination primary;
  std::optional<AgentModelDestination> fallback;
  // Price snapshots travel with the selected route so historical task cost
  // never changes when the mutable catalog is edited later.
  std::optional<int64_t> primary_cost_microusd_per_million_tokens;
  std::optional<int64_t> fallback_cost_microusd_per_million_tokens;
  AgentModelSelectionMode mode = AgentModelSelectionMode::kFixed;
  int catalog_revision = 0;
  std::string reason;
  AgentGenerationProfile primary_profile;
  AgentGenerationProfile fallback_profile;
  AgentTokenPrices primary_token_prices;
  AgentTokenPrices fallback_token_prices;
};

std::optional<AgentModelRoutePlan> SelectAgentModelRoute(
    const AgentModelSelectionInput& input,
    std::string* error);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_ROUTER_H_
