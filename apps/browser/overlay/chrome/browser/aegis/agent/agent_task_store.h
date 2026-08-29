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
  base::Time created_at;
  base::Time updated_at;
  RecoveryDisposition recovery = RecoveryDisposition::kRequireFreshConsent;
};

struct StoredAgentPlan {
  AgentTaskPlan plan;
  size_t next_step = 0;
  int attempt = 0;
};

// Profile-local storage for resumable metadata and redacted action summaries.
// Page bodies, screenshots, secrets, form values, cookies and full local paths
// have no column in this schema.
class AgentTaskStore {
 public:
  explicit AgentTaskStore(base::FilePath database_path);
  AgentTaskStore(const AgentTaskStore&) = delete;
  AgentTaskStore& operator=(const AgentTaskStore&) = delete;
  ~AgentTaskStore();

  bool Initialize();
  bool SaveTask(const AgentTask& task,
                std::string goal_summary,
                bool has_external_side_effect);
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

  const base::FilePath& database_path_for_testing() const {
    return database_path_;
  }

 private:
  static bool IsSafeSummary(const std::string& value);
  static std::string SerializeScope(const AgentTaskScope& scope);
  static int64_t SerializeTime(base::Time time);
  static base::Time DeserializeTime(int64_t value);

  const base::FilePath database_path_;
  sql::Database database_;
  sql::MetaTable meta_table_;
  bool initialized_ = false;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_TASK_STORE_H_
