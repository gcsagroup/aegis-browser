// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_CHOICE_CONTRACT_H_
#define CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_CHOICE_CONTRACT_H_

#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace aegis::agent {

// Provider-neutral representation of a TypeSafe Choice answer. Keeping the
// probability checks independent of Chromium lets the exact production
// decision gate run in the repository's lightweight native test harness.
struct TypeSafeChoiceValue {
  std::string choice;
  double confidence = 0.0;
  std::vector<std::pair<std::string, double>> probabilities;
};

// Accepts only a complete, normalized distribution over |allowed_options|.
// The selected choice must be the unique highest-probability option and the
// provider confidence must meet |minimum_confidence|.
bool ValidateTypeSafeChoice(
    const TypeSafeChoiceValue& value,
    std::span<const std::string_view> allowed_options,
    double minimum_confidence,
    std::string* error);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_CHOICE_CONTRACT_H_
