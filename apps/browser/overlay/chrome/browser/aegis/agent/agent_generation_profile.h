// Copyright 2026 GCSA
// Pure routing policy, shared by production and the standalone contract test.
#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_GENERATION_PROFILE_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_GENERATION_PROFILE_H_

#include <algorithm>
#include <string>
#include <string_view>
#include <vector>

namespace aegis::agent {

inline bool IsAgentReasoningEffort(std::string_view effort) {
  return effort.empty() || effort == "none" || effort == "minimal" ||
         effort == "low" || effort == "medium" || effort == "high" ||
         effort == "xhigh";
}

struct AgentGenerationProfile {
  // Empty means leave the provider default alone. Zero preserves the legacy
  // tool-specific output limit for old tasks and unconfigured custom models.
  std::string effort;
  int max_output_tokens = 0;

  bool IsValid() const {
    return IsAgentReasoningEffort(effort) && max_output_tokens >= 0 &&
           max_output_tokens <= 32768;
  }
  bool operator==(const AgentGenerationProfile&) const = default;
};

struct AgentGenerationPolicy {
  std::vector<std::string> supported_efforts;
  AgentGenerationProfile default_profile;
  AgentGenerationProfile basic_profile;
  AgentGenerationProfile strong_profile;

  bool Supports(const AgentGenerationProfile& profile) const {
    return profile.IsValid() &&
           (profile.effort.empty() ||
            std::ranges::find(supported_efforts, profile.effort) !=
                supported_efforts.end());
  }

  bool IsValid(std::string_view provider) const {
    if (supported_efforts.size() > 6 || !Supports(default_profile) ||
        !Supports(basic_profile) || !Supports(strong_profile)) {
      return false;
    }
    std::vector<std::string> unique;
    for (const auto& effort : supported_efforts) {
      if (effort.empty() || !IsAgentReasoningEffort(effort) ||
          std::ranges::find(unique, effort) != unique.end()) {
        return false;
      }
      unique.push_back(effort);
    }
    // Other adapters have different reasoning controls. Never silently accept
    // an OpenAI effort that Anthropic/Gemini would ignore.
    return (provider != "anthropic" && provider != "gemini") ||
           supported_efforts.empty();
  }

  AgentGenerationProfile Select(bool fixed, bool basic, bool strong) const {
    if (fixed || (!basic && !strong)) {
      return default_profile;
    }
    const auto& selected = basic ? basic_profile : strong_profile;
    return selected == AgentGenerationProfile{} ? default_profile : selected;
  }
};

inline int AgentGenerationOutputLimit(const AgentGenerationProfile& profile,
                                      int legacy_limit) {
  // Reasoning consumes the same output budget; do not cap a high-effort
  // profile to a tiny tool-argument-only limit.
  return profile.max_output_tokens > 0 ? profile.max_output_tokens
                                       : legacy_limit;
}

}  // namespace aegis::agent
#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_GENERATION_PROFILE_H_
