// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AEGIS_AGENT_SERVICE_H_
#define CHROME_BROWSER_AEGIS_AGENT_AEGIS_AGENT_SERVICE_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/timer/timer.h"
#include "chrome/browser/aegis/agent/aegis_actor_bridge.h"
#include "chrome/browser/aegis/agent/aegis_browser_tools.h"
#include "chrome/browser/aegis/agent/agent_execution.h"
#include "chrome/browser/aegis/agent/agent_planner.h"
#include "chrome/browser/aegis/agent/agent_policy_broker.h"
#include "chrome/browser/aegis/agent/agent_result_verifier.h"
#include "chrome/browser/aegis/agent/agent_service_observer.h"
#include "chrome/browser/aegis/agent/agent_task_store.h"
#include "components/keyed_service/core/keyed_service.h"

class Profile;

namespace os_crypt_async {
class Encryptor;
}  // namespace os_crypt_async

namespace aegis::agent {

class AgentModelClient;

struct AgentInvocationContext {
  int32_t tab_id = 0;
  std::string kind;
  std::string display;
  std::string suggested_goal;
  base::TimeTicks created;
};

class AegisAgentService : public KeyedService {
 public:
  using ToolResultCallback = base::OnceCallback<void(AgentToolResult)>;
  using PlanReadyCallback =
      base::OnceCallback<void(bool ok, std::string error)>;
  using RunCallback = base::OnceCallback<void(
      bool ok,
      std::string error,
      std::optional<AgentCompletionSummary> completion)>;

  explicit AegisAgentService(Profile* profile);
  AegisAgentService(const AegisAgentService&) = delete;
  AegisAgentService& operator=(const AegisAgentService&) = delete;
  ~AegisAgentService() override;

  bool IsEnabled() const;
  bool IsToolAvailable(std::string_view tool_name) const;
  Profile* profile() const { return profile_; }
  std::optional<AgentModelDestination> ConfiguredModelDestination() const;

  AgentTask* CreateTask(std::string goal, AgentMode mode, AgentTaskScope scope);
  AgentTask* GetTask(const std::string& task_id);
  const AgentTask* GetTask(const std::string& task_id) const;
  AgentTask* MostRecentTask();
  const AgentTask* MostRecentTask() const;
  size_t task_count_for_testing() const { return tasks_.size(); }
  bool SetPendingInvocationContext(AgentInvocationContext context);
  const AgentInvocationContext* PendingInvocationContext() const;
  void ClearPendingInvocationContext();
  void AddObserver(AegisAgentServiceObserver* observer);
  void RemoveObserver(AegisAgentServiceObserver* observer);

  bool BeginPlanning(const std::string& task_id);
  bool AcceptModelPlan(const std::string& task_id,
                       const AgentModelEvent& event,
                       std::string* error);
  void RequestPlan(const std::string& task_id, PlanReadyCallback callback);
  bool SetPlanReady(const std::string& task_id);
  const AgentTaskPlan* GetPlan(const std::string& task_id) const;
  bool GrantTaskConsent(const std::string& task_id);
  bool PauseTask(const std::string& task_id);
  bool ResumeTask(const std::string& task_id);
  bool BeginUserTakeover(const std::string& task_id);
  bool FinishUserTakeover(const std::string& task_id);
  bool GrantRecoveryConsent(const std::string& task_id);
  bool CancelTask(const std::string& task_id);
  bool CompleteTask(const std::string& task_id);
  void RunTask(const std::string& task_id, RunCallback callback);
  const AgentToolCall* PendingAction(const std::string& task_id) const;
  bool ApprovePendingAction(const std::string& task_id);
  bool CompleteFinalUserTakeover(const std::string& task_id,
                                 bool user_confirmed_completion);
  // Immediately stops model requests, Actor work, approvals, and monitors
  // when the profile-level Browser Agent switch is turned off. The keyed
  // service remains reusable if the user enables it again later.
  void CancelAllForDisable();
  // Restarts persisted browser-lifetime monitor timers after the profile pref
  // is enabled again. It does not resume or recreate cancelled tasks.
  void ResumeMonitorsAfterEnable();

  AgentPolicyDecision EvaluateToolCall(
      const std::string& task_id,
      const AgentToolCall& call,
      const std::optional<std::string>& approval_id = std::nullopt);
  std::optional<AgentApprovalReceipt> ApproveToolCall(
      const std::string& task_id,
      const AgentToolCall& call);
  void ExecuteTool(
      const std::string& task_id,
      const AgentToolCall& call,
      ToolResultCallback callback,
      const std::optional<std::string>& approval_id = std::nullopt);
  bool RecordToolResult(const std::string& task_id, AgentToolResult result);
  const AgentToolResult* FindRecordedResult(const std::string& task_id,
                                            const std::string& action_id) const;
  bool CanUndoLastBookmarkAction(const std::string& task_id) const;
  void UndoLastBookmarkAction(const std::string& task_id,
                              ToolResultCallback callback);

  bool UpsertMonitor(AgentMonitorDefinition monitor);
  bool SetMonitorPaused(const std::string& task_id,
                        const std::string& monitor_id,
                        bool paused);
  bool RemoveMonitor(const std::string& task_id, const std::string& monitor_id);
  std::vector<AgentMonitorDefinition> ClaimDueMonitors(base::Time now);
  bool MarkMonitorFinished(const std::string& task_id,
                           const std::string& monitor_id,
                           bool success,
                           base::Time now);
  std::vector<AgentMonitorDefinition> GetMonitors(
      const std::string& task_id) const;
  std::vector<AgentMonitorDefinition> GetAllMonitors() const;

  const AgentToolRegistry& tool_registry() const { return tool_registry_; }
  std::optional<StoredAgentTask::RecoveryDisposition> recovery_disposition(
      const std::string& task_id) const;
  AegisActorBridge& actor_bridge_for_testing() { return actor_bridge_; }

  // KeyedService:
  void Shutdown() override;

 private:
  struct ExecutionRuntime;
  using ActionResults = std::map<std::string, AgentToolResult>;

  bool Transition(const std::string& task_id,
                  AgentTaskState state,
                  std::string reason);
  bool PersistTask(const AgentTask& task);
  bool PersistPlanProgress(const std::string& task_id,
                           size_t next_step,
                           int attempt);
  bool ConsumeModelRequestBudget(AgentTask* task);
  void RestoreUnfinishedTasks();
  void RestoreMonitors();
  void RestoreMonitorTargets();
  void OnMonitorTargetsDecryptorReady(
      scoped_refptr<os_crypt_async::Encryptor> encryptor);
  void ExecuteMonitorTool(AgentTask* task,
                          const AgentToolCall& call,
                          ToolResultCallback callback);
  void OnMonitorCreateEncryptorReady(
      std::string task_id,
      AgentToolCall call,
      ToolResultCallback callback,
      scoped_refptr<os_crypt_async::Encryptor> encryptor);
  void ScheduleMonitorTimer();
  void OnMonitorTimer();
  void ExecuteDueMonitor(AgentMonitorDefinition monitor);
  void CleanupDueMonitorActor(const std::string& task_id,
                              int32_t tab_id,
                              bool actor_started,
                              bool task_adopted);
  void OnDueMonitorObserved(AgentMonitorDefinition monitor,
                            AgentToolCall call,
                            int32_t tab_id,
                            bool actor_started,
                            bool task_adopted,
                            AgentToolResult result);
  void ShowMonitorChangeNotification(
      const AgentMonitorDefinition& monitor) const;
  void OnPlanModelResult(const std::string& task_id,
                         PlanReadyCallback callback,
                         bool ok,
                         std::string error,
                         AgentModelParseResult result);
  void RequestNextModelTurn(const std::string& task_id);
  void EnsureFreshObservationThenContinue(const std::string& task_id,
                                          bool force_refresh);
  void OnRuntimeFreshObservation(const std::string& task_id,
                                 AgentToolResult result);
  void VerifyCheckoutBeforeTakeover(const std::string& task_id,
                                    AgentToolCall call,
                                    AgentToolResult expected_observation);
  void OnCheckoutPreflight(const std::string& task_id,
                           AgentToolCall call,
                           AgentToolResult expected_observation,
                           AgentToolResult fresh_observation);
  std::optional<int32_t> SelectRuntimeObservationTab(
      const AgentTask& task,
      const ExecutionRuntime& runtime) const;
  void OnExecutionModelResult(const std::string& task_id,
                              std::string expected_tool,
                              bool ok,
                              std::string error,
                              AgentModelParseResult result);
  std::optional<AgentToolCall> BindExecutionToolCall(
      const AgentTask& task,
      const AgentPlanStep& step,
      int attempt,
      const AgentModelEvent& event,
      std::string* error) const;
  void ExecuteRuntimeTool(const std::string& task_id,
                          AgentToolCall call,
                          const std::optional<std::string>& approval_id);
  void OnRuntimeToolResult(const std::string& task_id,
                           AgentToolCall attempted_call,
                           AgentToolResult result);
  void FinishRuntime(const std::string& task_id,
                     bool ok,
                     std::string error,
                     std::optional<AgentCompletionSummary> completion);
  void OnToolExecuted(const std::string& task_id,
                      std::string tool_name,
                      ToolResultCallback callback,
                      AgentToolResult result);
  void OnActorStateEvent(const std::string& task_id,
                         AegisActorBridge::StateEvent event);
  void NotifyServiceSnapshotChanged();

  raw_ptr<Profile> profile_;
  AgentTaskStore task_store_;
  AgentToolRegistry tool_registry_;
  AgentPolicyBroker policy_broker_;
  AgentResultVerifier result_verifier_;
  AgentMonitorScheduler monitor_scheduler_;
  AegisActorBridge actor_bridge_;
  AegisBrowserTools browser_tools_;
  std::map<std::string, std::unique_ptr<AgentTask>> tasks_;
  std::map<std::string, AgentTaskPlan> plans_;
  std::map<std::string, std::pair<size_t, int>> plan_progress_;
  std::map<std::string, std::unique_ptr<AgentModelClient>> model_clients_;
  std::map<std::string, std::string> model_request_ids_;
  std::map<std::string, std::unique_ptr<ExecutionRuntime>> executions_;
  std::map<std::string, AgentModelCapabilityTracker> model_capabilities_;
  std::map<std::string, ActionResults> action_results_;
  std::map<std::string, std::map<std::string, std::string>> action_tools_;
  std::map<std::string, std::map<std::string, std::string>> action_hashes_;
  std::map<std::string, bool> task_has_external_side_effect_;
  std::map<std::string, std::string> bookmark_undo_tokens_;
  std::map<std::string, StoredAgentTask::RecoveryDisposition>
      recovery_dispositions_;
  std::optional<AgentInvocationContext> pending_invocation_context_;
  base::ObserverList<AegisAgentServiceObserver> observers_;
  base::OneShotTimer monitor_timer_;
  bool storage_ready_ = false;
  bool shutting_down_ = false;
  base::WeakPtrFactory<AegisAgentService> weak_ptr_factory_{this};
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AEGIS_AGENT_SERVICE_H_
