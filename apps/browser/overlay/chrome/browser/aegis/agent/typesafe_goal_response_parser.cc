// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/typesafe_goal_response_parser.h"

#include <array>
#include <optional>
#include <span>
#include <string_view>
#include <utility>

#include "base/json/json_reader.h"
#include "base/strings/string_util.h"
#include "chrome/browser/aegis/agent/typesafe_choice_contract.h"

namespace aegis::agent {
namespace {

constexpr size_t kMaxGoalBytes = 4096;
constexpr size_t kMaxResponseBytes = 64 * 1024;
constexpr std::array<std::string_view, 4> kWorkflowOptions = {
    "research", "browser_steward", "safe_download", "shopping"};
constexpr std::array<std::string_view, 2> kEntryKindOptions = {
    "browser_only", "web_search"};

bool IsValidGoal(std::string_view goal) {
  return !goal.empty() && goal.size() <= kMaxGoalBytes &&
         base::IsStringUTF8(goal) && goal.find('\0') == std::string_view::npos;
}

std::optional<double> JsonNumber(const base::Value* value) {
  if (!value) {
    return std::nullopt;
  }
  if (value->is_double()) {
    return value->GetDouble();
  }
  if (value->is_int()) {
    return static_cast<double>(value->GetInt());
  }
  return std::nullopt;
}

std::optional<TypeSafeChoiceValue> ParseChoice(
    const base::DictValue* answer,
    std::span<const std::string_view> allowed_options,
    std::string* error) {
  const std::string* type = answer ? answer->FindString("type") : nullptr;
  if (!type || *type != "choice") {
    *error = "TypeSafe returned an invalid answer type";
    return std::nullopt;
  }
  const std::string* choice = answer->FindString("choice");
  const std::optional<double> confidence =
      JsonNumber(answer->Find("confidence"));
  const base::DictValue* probabilities = answer->FindDict("probabilities");
  if (!choice || !confidence || !probabilities) {
    *error = "TypeSafe returned an incomplete choice answer";
    return std::nullopt;
  }
  TypeSafeChoiceValue result{.choice = *choice, .confidence = *confidence};
  for (auto it = probabilities->begin(); it != probabilities->end(); ++it) {
    const std::optional<double> probability = JsonNumber(&it->second);
    if (!probability) {
      *error = "TypeSafe returned a non-numeric probability";
      return std::nullopt;
    }
    result.probabilities.emplace_back(it->first, *probability);
  }
  if (!ValidateTypeSafeChoice(result, allowed_options,
                              kTypeSafeGoalRouteMinimumConfidence, error)) {
    return std::nullopt;
  }
  return result;
}

struct TypeSafeGoalChoices {
  TypeSafeChoiceValue workflow;
  TypeSafeChoiceValue entry_kind;
};

std::optional<TypeSafeGoalChoices> ParseGoalChoices(std::string_view body,
                                                    std::string* error) {
  std::optional<base::DictValue> root =
      base::JSONReader::ReadDict(body, base::JSON_PARSE_RFC);
  if (!root) {
    *error = "TypeSafe returned malformed routing data";
    return std::nullopt;
  }
  const base::DictValue* answers = root->FindDict("answers");
  const std::string* model = root->FindString("model");
  if (!answers || !model || model->empty()) {
    *error = "TypeSafe returned malformed routing data";
    return std::nullopt;
  }
  std::optional<TypeSafeChoiceValue> workflow =
      ParseChoice(answers->FindDict("workflow"), kWorkflowOptions, error);
  if (!workflow) {
    return std::nullopt;
  }
  std::optional<TypeSafeChoiceValue> entry_kind =
      ParseChoice(answers->FindDict("entry_kind"), kEntryKindOptions, error);
  if (!entry_kind) {
    return std::nullopt;
  }
  return TypeSafeGoalChoices{.workflow = std::move(*workflow),
                             .entry_kind = std::move(*entry_kind)};
}

std::optional<AgentWorkflowKind> WorkflowForChoice(std::string_view choice) {
  if (choice == "research") {
    return AgentWorkflowKind::kResearch;
  }
  if (choice == "browser_steward") {
    return AgentWorkflowKind::kBrowserSteward;
  }
  if (choice == "safe_download") {
    return AgentWorkflowKind::kSafeDownload;
  }
  if (choice == "shopping") {
    return AgentWorkflowKind::kShopping;
  }
  return std::nullopt;
}

std::optional<AgentGoalRoute> BuildGoalRoute(
    const TypeSafeGoalChoices& choices,
    std::string_view original_goal,
    std::string* error) {
  std::optional<AgentWorkflowKind> workflow =
      WorkflowForChoice(choices.workflow.choice);
  if (!workflow) {
    *error = "TypeSafe returned an unknown workflow";
    return std::nullopt;
  }
  AgentGoalRoute route;
  route.workflow = *workflow;
  route.entry_kind = choices.entry_kind.choice == "browser_only"
                         ? AgentGoalEntryKind::kBrowserOnly
                         : AgentGoalEntryKind::kWebSearch;
  route.target = route.entry_kind == AgentGoalEntryKind::kWebSearch
                     ? std::string(original_goal)
                     : std::string();
  route.summary = "Use the browser to fulfill the original user goal.";
  if (!ValidateAndNormalizeGoalRoute(&route, error)) {
    return std::nullopt;
  }
  return route;
}

}  // namespace

std::optional<AgentGoalRoute> TypeSafeGoalResponseParser::Parse(
    std::string_view body,
    std::string_view original_goal,
    std::string* error) {
  if (!error) {
    return std::nullopt;
  }
  error->clear();
  if (body.empty() || body.size() > kMaxResponseBytes ||
      !IsValidGoal(original_goal)) {
    *error = "invalid TypeSafe goal routing response";
    return std::nullopt;
  }
  std::optional<TypeSafeGoalChoices> choices = ParseGoalChoices(body, error);
  if (!choices) {
    return std::nullopt;
  }
  // Jev selects only known options. Aegis derives any search query from the
  // user's original text and applies its existing intent constraints later.
  return BuildGoalRoute(*choices, original_goal, error);
}

}  // namespace aegis::agent
