// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_TASK_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_TASK_H_

#include <memory>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/observer_list.h"
#include "base/time/time.h"
#include "chrome/browser/aegis/agent/agent_types.h"

namespace aegis::agent {

struct AgentTaskEvent {
  AgentTaskState from;
  AgentTaskState to;
  std::string reason;
  base::Time timestamp;
  std::string title;
};

class AgentTaskObserver : public base::CheckedObserver {
 public:
  virtual void OnAgentTaskStateChanged(const std::string& task_id,
                                       const AgentTaskEvent& event) = 0;
};

class AgentTask {
 public:
  AgentTask(std::string task_id,
            std::string goal,
            AgentMode mode,
            AgentTaskScope scope);
  AgentTask(const AgentTask&) = delete;
  AgentTask& operator=(const AgentTask&) = delete;
  ~AgentTask();

  static std::string GenerateTaskId();
  static std::unique_ptr<AgentTask> RestoreForRecovery(
      std::string task_id,
      std::string goal_summary,
      AgentMode mode,
      AgentTaskScope scope,
      AgentTaskState previous_state,
      int tool_calls_used,
      int model_calls_used,
      int network_requests_used,
      base::Time created_at);
  static std::unique_ptr<AgentTask> RestoreCompletedMonitorOwner(
      std::string task_id,
      std::string goal_summary,
      AgentMode mode,
      AgentTaskScope scope,
      int tool_calls_used,
      int model_calls_used,
      int network_requests_used,
      base::Time created_at);

  const std::string& id() const { return task_id_; }
  const std::string& goal() const { return goal_; }
  AgentMode mode() const { return mode_; }
  AgentTaskState state() const { return state_; }
  const AgentTaskScope& scope() const { return scope_; }
  int tool_calls_used() const { return tool_calls_used_; }
  int model_calls_used() const { return model_calls_used_; }
  int network_requests_used() const { return network_requests_used_; }
  const base::flat_set<int32_t>& owned_tab_ids() const {
    return owned_tab_ids_;
  }
  base::Time created_at() const { return created_at_; }
  const std::vector<AgentTaskEvent>& events() const { return events_; }

  bool TransitionTo(AgentTaskState next, std::string reason);
  // Records a browser-verified informational event without changing state.
  // This is used for monitor results and other facts that should immediately
  // appear in the task timeline but are not state transitions.
  void RecordEvent(std::string title, std::string reason);
  // The task is created with a browser-approved maximum scope. A validated
  // plan may narrow it exactly once while planning; it can never expand or
  // change after the consent card is shown.
  bool AdoptPlanScope(AgentTaskScope scope);
  bool ConsumeToolCall();
  bool ConsumeModelCall();
  bool ConsumeNetworkRequest();
  bool AllowsTab(int32_t tab_id) const;
  bool AdoptOwnedTab(int32_t tab_id);
  bool ReleaseOwnedTab(int32_t tab_id);
  bool HasExpired(base::Time now) const;

  void AddObserver(AgentTaskObserver* observer);
  void RemoveObserver(AgentTaskObserver* observer);

 private:
  AgentTask(std::string task_id,
            std::string goal,
            AgentMode mode,
            AgentTaskScope scope,
            AgentTaskState state,
            int tool_calls_used,
            int model_calls_used,
            int network_requests_used,
            base::Time created_at);
  static bool IsAllowedTransition(AgentTaskState from, AgentTaskState to);
  bool Consume(int* used, int maximum);

  const std::string task_id_;
  const std::string goal_;
  const AgentMode mode_;
  AgentTaskScope scope_;
  AgentTaskState state_ = AgentTaskState::kDraft;
  int tool_calls_used_ = 0;
  int model_calls_used_ = 0;
  int network_requests_used_ = 0;
  base::flat_set<int32_t> owned_tab_ids_;
  const base::Time created_at_;
  std::vector<AgentTaskEvent> events_;
  base::ObserverList<AgentTaskObserver> observers_;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_TASK_H_
