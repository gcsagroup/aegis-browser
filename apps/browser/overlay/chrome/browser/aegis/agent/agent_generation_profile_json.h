// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_GENERATION_PROFILE_JSON_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_GENERATION_PROFILE_JSON_H_

#include "base/values.h"
#include "chrome/browser/aegis/agent/agent_generation_profile.h"

namespace aegis::agent {

inline base::DictValue SerializeGenerationProfile(
    const AgentGenerationProfile& profile) {
  base::DictValue value;
  value.Set("effort", profile.effort);
  value.Set("max_output_tokens", profile.max_output_tokens);
  return value;
}

inline bool ReadGenerationProfile(const base::DictValue& parent,
                                  std::string_view key,
                                  AgentGenerationProfile* profile) {
  if (!parent.contains(key)) {
    return true;
  }
  const auto* value = parent.FindDict(key);
  const auto* effort = value ? value->FindString("effort") : nullptr;
  const auto budget =
      value ? value->FindInt("max_output_tokens") : std::nullopt;
  if (!effort || !budget) {
    return false;
  }
  *profile = {.effort = *effort, .max_output_tokens = *budget};
  return profile->IsValid();
}

inline bool ReadGenerationPolicy(const base::DictValue& value,
                                 AgentGenerationPolicy* policy) {
  if (value.contains("supported_efforts")) {
    const auto* efforts = value.FindList("supported_efforts");
    if (!efforts) {
      return false;
    }
    for (const auto& effort : *efforts) {
      if (!effort.is_string()) {
        return false;
      }
      policy->supported_efforts.push_back(effort.GetString());
    }
  }
  return ReadGenerationProfile(value, "default_profile",
                               &policy->default_profile) &&
         ReadGenerationProfile(value, "basic_profile",
                               &policy->basic_profile) &&
         ReadGenerationProfile(value, "strong_profile",
                               &policy->strong_profile);
}

inline void WriteGenerationPolicy(const AgentGenerationPolicy& policy,
                                  base::DictValue* value) {
  base::ListValue efforts;
  for (const auto& effort : policy.supported_efforts) {
    efforts.Append(effort);
  }
  value->Set("supported_efforts", std::move(efforts));
  value->Set("default_profile",
             SerializeGenerationProfile(policy.default_profile));
  value->Set("basic_profile", SerializeGenerationProfile(policy.basic_profile));
  value->Set("strong_profile",
             SerializeGenerationProfile(policy.strong_profile));
}
}  // namespace aegis::agent
#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_GENERATION_PROFILE_JSON_H_
