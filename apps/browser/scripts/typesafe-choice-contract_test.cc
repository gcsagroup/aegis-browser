// Copyright 2026 GCSA

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

#include "chrome/browser/aegis/agent/typesafe_choice_contract.h"

namespace {

using aegis::agent::TypeSafeChoiceValue;
using aegis::agent::ValidateTypeSafeChoice;

constexpr std::string_view kOptions[] = {"research", "browser_steward",
                                         "safe_download", "shopping"};

bool Expect(bool condition, std::string_view label) {
  if (!condition) {
    std::cerr << "FAIL: " << label << '\n';
  }
  return condition;
}

TypeSafeChoiceValue ValidChoice() {
  return TypeSafeChoiceValue{
      .choice = "research",
      .confidence = 0.91,
      .probabilities = {{"research", 0.91},
                        {"browser_steward", 0.03},
                        {"safe_download", 0.03},
                        {"shopping", 0.03}}};
}

int TestConfidenceContract() {
  int passed = 0;
  std::string error;
  TypeSafeChoiceValue valid = ValidChoice();
  passed += Expect(ValidateTypeSafeChoice(valid, kOptions, 0.8, &error),
                   "valid complete choice");

  TypeSafeChoiceValue low = valid;
  low.confidence = 0.79;
  passed += Expect(!ValidateTypeSafeChoice(low, kOptions, 0.8, &error),
                   "low confidence falls back");

  TypeSafeChoiceValue threshold = valid;
  threshold.confidence = 0.8;
  passed += Expect(ValidateTypeSafeChoice(threshold, kOptions, 0.8, &error),
                   "confidence threshold is inclusive");
  return passed;
}

int TestChoiceContract() {
  int passed = 0;
  std::string error;
  TypeSafeChoiceValue valid = ValidChoice();

  TypeSafeChoiceValue contradictory = valid;
  contradictory.probabilities = {{"research", 0.03},
                                 {"browser_steward", 0.03},
                                 {"safe_download", 0.03},
                                 {"shopping", 0.91}};
  passed += Expect(
      !ValidateTypeSafeChoice(contradictory, kOptions, 0.8, &error),
      "choice must match highest probability");

  TypeSafeChoiceValue unknown = valid;
  unknown.choice = "unknown";
  passed += Expect(!ValidateTypeSafeChoice(unknown, kOptions, 0.8, &error),
                   "selected option must be offered");
  return passed;
}

int TestDistributionContract() {
  int passed = 0;
  std::string error;
  TypeSafeChoiceValue valid = ValidChoice();

  TypeSafeChoiceValue incomplete = valid;
  incomplete.probabilities.pop_back();
  incomplete.probabilities[0].second = 0.94;
  passed += Expect(!ValidateTypeSafeChoice(incomplete, kOptions, 0.8, &error),
                   "every offered option is required");

  TypeSafeChoiceValue invalid_sum = valid;
  invalid_sum.probabilities[0].second = 0.95;
  passed += Expect(
      !ValidateTypeSafeChoice(invalid_sum, kOptions, 0.8, &error),
      "probabilities must sum to one");

  TypeSafeChoiceValue duplicate = valid;
  duplicate.probabilities[3] = {"research", 0.03};
  passed += Expect(!ValidateTypeSafeChoice(duplicate, kOptions, 0.8, &error),
                   "duplicate option is rejected");

  TypeSafeChoiceValue not_a_number = valid;
  not_a_number.probabilities[0].second =
      std::numeric_limits<double>::quiet_NaN();
  passed += Expect(
      !ValidateTypeSafeChoice(not_a_number, kOptions, 0.8, &error),
      "non-finite probability is rejected");

  TypeSafeChoiceValue out_of_range = valid;
  out_of_range.probabilities = {{"research", 1.01},
                                {"browser_steward", 0.0},
                                {"safe_download", 0.0},
                                {"shopping", -0.01}};
  passed += Expect(
      !ValidateTypeSafeChoice(out_of_range, kOptions, 0.8, &error),
      "out-of-range probability is rejected");
  return passed;
}

}  // namespace

int main() {
  const int passed = TestConfidenceContract() + TestChoiceContract() +
                     TestDistributionContract();
  if (passed != 10) {
    return EXIT_FAILURE;
  }
  std::cout << "PASS: TypeSafe production choice contract 10/10\n";
  return EXIT_SUCCESS;
}
