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
constexpr std::array<std::string_view, 3> kReasoningNeedOptions = {
    "unknown", "basic", "strong"};
constexpr std::array<std::string_view, 3> kContextNeedOptions = {
    "unknown", "short", "long"};
constexpr std::array<std::string_view, 4> kOutputNeedOptions = {
    "unknown", "short_extraction", "comprehensive", "multi_step"};

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
  TypeSafeChoiceValue reasoning_need;
  TypeSafeChoiceValue context_need;
  TypeSafeChoiceValue output_need;
  std::string model;
  int input_tokens = 0;
  int output_tokens = 0;
  bool usage_present = false;
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
  std::optional<TypeSafeChoiceValue> reasoning_need = ParseChoice(
      answers->FindDict("reasoning_need"), kReasoningNeedOptions, error);
  if (!reasoning_need) {
    return std::nullopt;
  }
  std::optional<TypeSafeChoiceValue> context_need = ParseChoice(
      answers->FindDict("context_need"), kContextNeedOptions, error);
  if (!context_need) {
    return std::nullopt;
  }
  std::optional<TypeSafeChoiceValue> output_need = ParseChoice(
      answers->FindDict("output_need"), kOutputNeedOptions, error);
  if (!output_need) {
    return std::nullopt;
  }
  int input_tokens = 0;
  int output_tokens = 0;
  if (const base::DictValue* usage = root->FindDict("usage")) {
    const std::optional<int> parsed_input = usage->FindInt("input_tokens");
    const std::optional<int> parsed_output = usage->FindInt("output_tokens");
    if (!parsed_input || !parsed_output || *parsed_input < 0 ||
        *parsed_output < 0 || *parsed_input > 10000000 ||
        *parsed_output > 10000000) {
      *error = "TypeSafe returned invalid usage data";
      return std::nullopt;
    }
    input_tokens = *parsed_input;
    output_tokens = *parsed_output;
  }
  return TypeSafeGoalChoices{
      .workflow = std::move(*workflow),
      .entry_kind = std::move(*entry_kind),
      .reasoning_need = std::move(*reasoning_need),
      .context_need = std::move(*context_need),
      .output_need = std::move(*output_need),
      .model = *model,
      .input_tokens = input_tokens,
      .output_tokens = output_tokens,
      .usage_present = root->FindDict("usage") != nullptr};
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

AgentModelRequirements BuildRequirements(const TypeSafeGoalChoices& choices) {
  AgentModelRequirements requirements;
  if (choices.reasoning_need.choice == "basic") {
    requirements.reasoning = AgentReasoningNeed::kBasic;
  } else if (choices.reasoning_need.choice == "strong") {
    requirements.reasoning = AgentReasoningNeed::kStrong;
  }
  if (choices.context_need.choice == "short") {
    requirements.context = AgentContextNeed::kShort;
  } else if (choices.context_need.choice == "long") {
    requirements.context = AgentContextNeed::kLong;
  }
  if (choices.output_need.choice == "short_extraction") {
    requirements.output = AgentOutputNeed::kShortExtraction;
  } else if (choices.output_need.choice == "comprehensive") {
    requirements.output = AgentOutputNeed::kComprehensive;
  } else if (choices.output_need.choice == "multi_step") {
    requirements.output = AgentOutputNeed::kMultiStep;
  }
  return requirements;
}

}  // namespace

std::optional<TypeSafeGoalAnalysis> TypeSafeGoalResponseParser::Parse(
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
  std::optional<AgentGoalRoute> route =
      BuildGoalRoute(*choices, original_goal, error);
  if (!route) {
    return std::nullopt;
  }
  return TypeSafeGoalAnalysis{
      .route = std::move(*route),
      .requirements = BuildRequirements(*choices),
      .model = choices->model,
      .workflow = std::move(choices->workflow),
      .entry_kind = std::move(choices->entry_kind),
      .reasoning_need = std::move(choices->reasoning_need),
      .context_need = std::move(choices->context_need),
      .output_need = std::move(choices->output_need),
      .input_tokens = choices->input_tokens,
      .output_tokens = choices->output_tokens,
      .usage_present = choices->usage_present};
}

}  // namespace aegis::agent
