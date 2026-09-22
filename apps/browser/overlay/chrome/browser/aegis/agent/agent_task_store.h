// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_TASK_STORE_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_TASK_STORE_H_

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/time/time.h"
#include "chrome/browser/aegis/agent/agent_monitor_scheduler.h"
#include "chrome/browser/aegis/agent/agent_planner.h"
#include "chrome/browser/aegis/agent/agent_task.h"
#include "chrome/browser/aegis/agent/agent_tool_registry.h"
#include "sql/database.h"
#include "sql/meta_table.h"

namespace aegis::agent {

struct StoredAgentTask {
  enum class RecoveryDisposition {
    kResumeReadOnly = 0,
    kRequireFreshConsent = 1,
    kRequireActionApproval = 2,
  };

  std::string task_id;
  AgentTaskState state = AgentTaskState::kFailed;
  AgentMode mode = AgentMode::kAsk;
  std::string goal_summary;
  std::string scope_json;
  bool has_external_side_effect = false;
  int tool_calls_used = 0;
  int model_calls_used = 0;
  int network_requests_used = 0;
  AgentModelRoutingMetrics model_routing_metrics;
  base::Time created_at;
  base::Time updated_at;
  RecoveryDisposition recovery = RecoveryDisposition::kRequireFreshConsent;
};

struct StoredAgentPlan {
  AgentTaskPlan plan;
  size_t next_step = 0;
  int attempt = 0;
};

// Copyable task metadata queued from the UI sequence to the storage sequence.
// It intentionally has no fields for page content, form values, cookies,
// credentials, screenshots, or full local paths.
struct AgentTaskStoreRecord {
  std::string task_id;
  AgentTaskState state = AgentTaskState::kDraft;
  AgentMode mode = AgentMode::kAsk;
  std::string goal_summary;
  AgentTaskScope scope;
  bool has_external_side_effect = false;
  int tool_calls_used = 0;
  int model_calls_used = 0;
  int network_requests_used = 0;
  AgentModelRoutingMetrics model_routing_metrics;
  base::Time created_at;
};

struct StoredAgentPlanEntry {
  std::string task_id;
  StoredAgentPlan stored_plan;
};

enum class AgentGoalRouteStatus {
  kPending = 0,
  kCompleted = 1,
  kCancelled = 2,
};

// Redacted accounting for goal screening that exists before a task. It never
// stores the goal, prompt, provider endpoint, credentials, or model response.
struct AgentGoalRouteObservation {
  std::string route_id;
  std::string task_id;
  AgentGoalRouteStatus status = AgentGoalRouteStatus::kPending;
  AgentModelRoutingMetrics metrics;
  base::Time created_at;
  base::Time updated_at;
};

struct StoredAgentState {
  std::vector<StoredAgentTask> tasks;
  std::vector<StoredAgentPlanEntry> plans;
  std::vector<AgentMonitorDefinition> monitors;
  std::vector<AgentGoalRouteObservation> goal_routes;
};

// Profile-local storage for resumable metadata and redacted action summaries.
// Page bodies, screenshots, secrets, form values, cookies and full local paths
// have no column in this schema.
class AgentTaskStore {
 public:
  explicit AgentTaskStore(base::FilePath database_path, bool in_memory = false);
  AgentTaskStore(const AgentTaskStore&) = delete;
  AgentTaskStore& operator=(const AgentTaskStore&) = delete;
  ~AgentTaskStore();

  bool Initialize();
  std::optional<StoredAgentState> InitializeAndLoad(
      base::Time unfinished_before,
      base::Time completed_before);
  bool SaveTask(const AgentTask& task,
                std::string goal_summary,
                bool has_external_side_effect);
  bool SaveTaskRecord(AgentTaskStoreRecord record);
  bool SaveTaskRecordAndBindGoalRoute(AgentTaskStoreRecord record,
                                      const std::string& route_id);
  bool SaveGoalRouteObservation(AgentGoalRouteObservation observation);
  std::vector<AgentGoalRouteObservation> LoadGoalRouteObservations();
  bool AppendActionSummary(const std::string& task_id,
                           const std::string& action_id,
                           const std::string& tool_name,
                           AgentRiskLevel risk,
                           bool ok,
                           const std::string& redacted_summary);
  // Loads unfinished tasks plus completed Automate tasks that still own a
  // persisted monitor. The latter are restored only as inert monitor owners.
  std::vector<StoredAgentTask> LoadUnfinishedTasks();
  bool SavePlan(const std::string& task_id,
                const AgentTaskPlan& plan,
                size_t next_step,
                int attempt);
  std::optional<StoredAgentPlan> LoadPlan(const std::string& task_id,
                                          const AgentTaskScope& scope,
                                          const AgentToolRegistry& registry);
  bool SaveMonitor(const AgentMonitorDefinition& monitor);
  std::vector<AgentMonitorDefinition> LoadMonitors();
  bool DeleteMonitor(const std::string& monitor_id);
  bool DeleteTask(const std::string& task_id);
  bool Prune(base::Time unfinished_before, base::Time completed_before);

  static std::optional<AgentTaskScope> DeserializeScope(
      std::string_view scope_json);
  static std::optional<AgentModelRoutingMetrics>
  DeserializeModelRoutingMetrics(std::string_view metrics_json);
  // Redacted allowlisted observations, also exposed for local evaluation.
  static std::string SerializeModelRoutingMetrics(
      const AgentModelRoutingMetrics& metrics);
  // Goals and persisted summaries share the same secret/control-character
  // boundary. Callers must reject unsafe values before queueing asynchronous
  // storage work so an invalid task is never exposed to the UI.
  static bool IsSafeSummary(const std::string& value);

  const base::FilePath& database_path_for_testing() const {
    return database_path_;
  }
  bool is_in_memory_for_testing() const { return in_memory_; }
  bool IsInitializedForTesting() const { return initialized_; }

 private:
  bool SaveTaskRecordInternal(AgentTaskStoreRecord record,
                              std::optional<std::string> route_id);
  static std::string SerializeScope(const AgentTaskScope& scope);
  static int64_t SerializeTime(base::Time time);
  static base::Time DeserializeTime(int64_t value);

  const base::FilePath database_path_;
  const bool in_memory_;
  sql::Database database_;
  sql::MetaTable meta_table_;
  bool initialized_ = false;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_TASK_STORE_H_
