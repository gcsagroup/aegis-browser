// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/typesafe_choice_contract.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <optional>

namespace aegis::agent {
namespace {

using ProbabilityDistribution = std::map<std::string_view, double>;

bool IsUnitInterval(double value) {
  return std::isfinite(value) && value >= 0.0 && value <= 1.0;
}

bool HasValidContract(std::span<const std::string_view> allowed_options,
                      double minimum_confidence,
                      double confidence) {
  return allowed_options.size() >= 2u &&
         IsUnitInterval(minimum_confidence) && IsUnitInterval(confidence);
}

std::optional<ProbabilityDistribution> ParseDistribution(
    const TypeSafeChoiceValue& value,
    std::span<const std::string_view> allowed_options,
    double* total,
    std::string* error) {
  ProbabilityDistribution distribution;
  *total = 0.0;
  for (const auto& item : value.probabilities) {
    const std::string& name = item.first;
    const double probability = item.second;
    const bool allowed =
        std::ranges::find(allowed_options, name) != allowed_options.end();
    if (!allowed || distribution.contains(name) ||
        !IsUnitInterval(probability)) {
      *error = "invalid TypeSafe probability distribution";
      return std::nullopt;
    }
    distribution.emplace(name, probability);
    *total += probability;
  }
  return distribution;
}

bool IsCompleteDistribution(const ProbabilityDistribution& distribution,
                            size_t option_count,
                            double total) {
  return distribution.size() == option_count &&
         std::abs(total - 1.0) <= 0.000001;
}

bool ChoiceMatchesUniqueMaximum(const ProbabilityDistribution& distribution,
                                std::string_view choice,
                                std::string* error) {
  auto selected = distribution.find(choice);
  if (selected == distribution.end()) {
    *error = "unknown TypeSafe choice";
    return false;
  }
  for (const auto& item : distribution) {
    if (item.first != selected->first && item.second >= selected->second) {
      *error = "TypeSafe choice contradicts its probability distribution";
      return false;
    }
  }
  return true;
}

}  // namespace

bool ValidateTypeSafeChoice(
    const TypeSafeChoiceValue& value,
    std::span<const std::string_view> allowed_options,
    double minimum_confidence,
    std::string* error) {
  if (!error) {
    return false;
  }
  error->clear();
  if (!HasValidContract(allowed_options, minimum_confidence,
                        value.confidence)) {
    *error = "invalid TypeSafe choice contract";
    return false;
  }

  double total = 0.0;
  std::optional<ProbabilityDistribution> distribution =
      ParseDistribution(value, allowed_options, &total, error);
  if (!distribution) {
    return false;
  }
  if (!IsCompleteDistribution(*distribution, allowed_options.size(), total)) {
    *error = "incomplete TypeSafe probability distribution";
    return false;
  }
  if (!ChoiceMatchesUniqueMaximum(*distribution, value.choice, error)) {
    return false;
  }
  if (value.confidence < minimum_confidence) {
    *error = "TypeSafe choice confidence is below the routing threshold";
    return false;
  }
  return true;
}

}  // namespace aegis::agent
