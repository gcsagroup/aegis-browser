// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_task.h"

#include <utility>

#include "base/check.h"
#include "base/uuid.h"

namespace aegis::agent {

AgentTask::AgentTask(std::string task_id,
                     std::string goal,
                     AgentMode mode,
                     AgentTaskScope scope)
    : AgentTask(std::move(task_id),
                std::move(goal),
                mode,
                std::move(scope),
                AgentTaskState::kDraft,
                0,
                0,
                0,
                base::Time::Now()) {}

AgentTask::AgentTask(std::string task_id,
                     std::string goal,
                     AgentMode mode,
                     AgentTaskScope scope,
                     AgentTaskState state,
                     int tool_calls_used,
                     int model_calls_used,
                     int network_requests_used,
                     base::Time created_at)
    : task_id_(std::move(task_id)),
      goal_(std::move(goal)),
      mode_(mode),
      scope_(std::move(scope)),
      state_(state),
      tool_calls_used_(tool_calls_used),
      model_calls_used_(model_calls_used),
      network_requests_used_(network_requests_used),
      created_at_(created_at) {
  CHECK(!task_id_.empty());
  CHECK(!goal_.empty());
  CHECK(scope_.IsValid());
}

AgentTask::~AgentTask() = default;

// static
std::string AgentTask::GenerateTaskId() {
  return base::Uuid::GenerateRandomV4().AsLowercaseString();
}

// static
std::unique_ptr<AgentTask> AgentTask::RestoreForRecovery(
    std::string task_id,
    std::string goal_summary,
    AgentMode mode,
    AgentTaskScope scope,
    AgentTaskState previous_state,
    int tool_calls_used,
    int model_calls_used,
    int network_requests_used,
    base::Time created_at) {
  if (task_id.empty() || goal_summary.empty() || !scope.IsValid() ||
      IsTerminalState(previous_state) || created_at.is_null() ||
      created_at > base::Time::Now() || tool_calls_used < 0 ||
      tool_calls_used > scope.budgets.max_tool_calls || model_calls_used < 0 ||
      model_calls_used > scope.budgets.max_model_calls ||
      network_requests_used < 0 ||
      network_requests_used > scope.budgets.max_network_requests) {
    return nullptr;
  }
  auto task = std::unique_ptr<AgentTask>(new AgentTask(
      std::move(task_id), std::move(goal_summary), mode, std::move(scope),
      AgentTaskState::kRecovering, tool_calls_used, model_calls_used,
      network_requests_used, created_at));
  task->events_.push_back(
      {.from = previous_state,
       .to = AgentTaskState::kRecovering,
       .reason = "browser restarted; external actions were not replayed",
       .timestamp = base::Time::Now()});
  return task;
}

// static
std::unique_ptr<AgentTask> AgentTask::RestoreCompletedMonitorOwner(
    std::string task_id,
    std::string goal_summary,
    AgentMode mode,
    AgentTaskScope scope,
    int tool_calls_used,
    int model_calls_used,
    int network_requests_used,
    base::Time created_at) {
  if (task_id.empty() || goal_summary.empty() || mode != AgentMode::kAutomate ||
      !scope.IsValid() || created_at.is_null() ||
      created_at > base::Time::Now() || tool_calls_used < 0 ||
      tool_calls_used > scope.budgets.max_tool_calls || model_calls_used < 0 ||
      model_calls_used > scope.budgets.max_model_calls ||
      network_requests_used < 0 ||
      network_requests_used > scope.budgets.max_network_requests) {
    return nullptr;
  }
  return std::unique_ptr<AgentTask>(new AgentTask(
      std::move(task_id), std::move(goal_summary), mode, std::move(scope),
      AgentTaskState::kCompleted, tool_calls_used, model_calls_used,
      network_requests_used, created_at));
}

bool AgentTask::TransitionTo(AgentTaskState next, std::string reason) {
  if (!IsAllowedTransition(state_, next)) {
    return false;
  }
  AgentTaskEvent event{.from = state_,
                       .to = next,
                       .reason = std::move(reason),
                       .timestamp = base::Time::Now()};
  state_ = next;
  events_.push_back(event);
  for (AgentTaskObserver& observer : observers_) {
    observer.OnAgentTaskStateChanged(task_id_, events_.back());
  }
  return true;
}

void AgentTask::RecordEvent(std::string title, std::string reason) {
  CHECK(!title.empty());
  events_.push_back({.from = state_,
                     .to = state_,
                     .reason = std::move(reason),
                     .timestamp = base::Time::Now(),
                     .title = std::move(title)});
  for (AgentTaskObserver& observer : observers_) {
    observer.OnAgentTaskStateChanged(task_id_, events_.back());
  }
}

bool AgentTask::AdoptPlanScope(AgentTaskScope scope) {
  if (state_ != AgentTaskState::kPlanning || !scope.IsValid() ||
      !scope.IsNoBroaderThan(scope_) ||
      tool_calls_used_ > scope.budgets.max_tool_calls ||
      model_calls_used_ > scope.budgets.max_model_calls ||
      network_requests_used_ > scope.budgets.max_network_requests) {
    return false;
  }
  scope_ = std::move(scope);
  return true;
}

bool AgentTask::ConsumeToolCall() {
  return Consume(&tool_calls_used_, scope_.budgets.max_tool_calls);
}

bool AgentTask::ConsumeModelCall() {
  return Consume(&model_calls_used_, scope_.budgets.max_model_calls);
}

bool AgentTask::ConsumeNetworkRequest() {
  return Consume(&network_requests_used_, scope_.budgets.max_network_requests);
}

bool AgentTask::AllowsTab(int32_t tab_id) const {
  return scope_.AllowsTab(tab_id) || owned_tab_ids_.contains(tab_id);
}

bool AgentTask::AdoptOwnedTab(int32_t tab_id) {
  if (tab_id <= 0 || AllowsTab(tab_id) ||
      scope_.allowed_tab_ids.size() + owned_tab_ids_.size() >=
          static_cast<size_t>(scope_.budgets.max_tabs)) {
    return false;
  }
  return owned_tab_ids_.insert(tab_id).second;
}

bool AgentTask::ReleaseOwnedTab(int32_t tab_id) {
  return owned_tab_ids_.erase(tab_id) == 1u;
}

bool AgentTask::HasExpired(base::Time now) const {
  return now - created_at_ >= scope_.budgets.max_duration;
}

void AgentTask::AddObserver(AgentTaskObserver* observer) {
  observers_.AddObserver(observer);
}

void AgentTask::RemoveObserver(AgentTaskObserver* observer) {
  observers_.RemoveObserver(observer);
}

// static
bool AgentTask::IsAllowedTransition(AgentTaskState from, AgentTaskState to) {
  if (IsTerminalState(from) || from == to) {
    return false;
  }
  using State = AgentTaskState;
  switch (from) {
    case State::kDraft:
      return to == State::kPlanning || to == State::kCancelled;
    case State::kPlanning:
      return to == State::kAwaitingTaskConsent || to == State::kFailed ||
             to == State::kCancelled;
    case State::kAwaitingTaskConsent:
      return to == State::kRunning || to == State::kCancelled ||
             to == State::kExpired;
    case State::kRunning:
    case State::kReflecting:
      return to == State::kRunning || to == State::kReflecting ||
             to == State::kAwaitingActionApproval ||
             to == State::kPausedByUser || to == State::kUserTakeover ||
             to == State::kRecovering || to == State::kVerifying ||
             to == State::kFailed || to == State::kCancelled ||
             to == State::kExpired;
    case State::kAwaitingActionApproval:
      return to == State::kRunning || to == State::kUserTakeover ||
             to == State::kCancelled || to == State::kExpired;
    case State::kPausedByUser:
      return to == State::kRunning || to == State::kUserTakeover ||
             to == State::kCancelled || to == State::kExpired;
    case State::kUserTakeover:
      return to == State::kRecovering || to == State::kCompleted ||
             to == State::kCancelled || to == State::kExpired;
    case State::kRecovering:
      return to == State::kRunning || to == State::kAwaitingTaskConsent ||
             to == State::kAwaitingActionApproval || to == State::kFailed ||
             to == State::kCancelled || to == State::kExpired;
    case State::kVerifying:
      return to == State::kRunning || to == State::kCompleted ||
             to == State::kFailed || to == State::kCancelled;
    case State::kCompleted:
    case State::kFailed:
    case State::kCancelled:
    case State::kExpired:
      return false;
  }
}

bool AgentTask::Consume(int* used, int maximum) {
  CHECK(used);
  if (*used >= maximum) {
    return false;
  }
  ++*used;
  return true;
}

}  // namespace aegis::agent
