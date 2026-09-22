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
#include "base/threading/sequence_bound.h"
#include "base/timer/timer.h"
#include "chrome/browser/aegis/agent/aegis_actor_bridge.h"
#include "chrome/browser/aegis/agent/aegis_browser_tools.h"
#include "chrome/browser/aegis/agent/agent_execution.h"
#include "chrome/browser/aegis/agent/agent_model_client.h"
#include "chrome/browser/aegis/agent/agent_model_router.h"
#include "chrome/browser/aegis/agent/agent_planner.h"
#include "chrome/browser/aegis/agent/agent_policy_broker.h"
#include "chrome/browser/aegis/agent/agent_result_verifier.h"
#include "chrome/browser/aegis/agent/agent_service_observer.h"
#include "chrome/browser/aegis/agent/agent_task_store.h"
#include "chrome/browser/aegis/agent/typesafe_goal_response_parser.h"
#include "components/keyed_service/core/keyed_service.h"

class Profile;

namespace net {
class HttpResponseHeaders;
struct RedirectInfo;
}  // namespace net

namespace network::mojom {
class URLResponseHead;
}

namespace os_crypt_async {
class Encryptor;
}  // namespace os_crypt_async

namespace aegis::agent {

class AgentModelClient;
class TypeSafeGoalRouterClient;

// System notification centers outlive Incognito windows, so only regular
// Profiles may export Agent monitor events to that surface.
bool AreAgentSystemNotificationsAllowed(const Profile* profile);

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
  using GoalRouteCallback = base::OnceCallback<
      void(bool ok, std::string error, std::optional<AgentGoalRoute> route)>;
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
  std::optional<AgentModelRoutePlan> SelectModelRoute(
      const AgentModelRequirements& requirements,
      std::string* error) const;
  const AgentModelRequirements& LastGoalModelRequirements() const {
    return last_goal_model_requirements_;
  }
  AgentModelRoutingMetrics CurrentGoalRoutingMetrics(
      bool route_was_required) const;
  std::string UnboundGoalRouteObservationsJson() const;

  AgentTask* CreateTask(
      std::string goal,
      AgentMode mode,
      AgentTaskScope scope,
      AgentModelRoutingMetrics routing_metrics = AgentModelRoutingMetrics(),
      bool bind_current_goal_route = false);
  AgentTask* GetTask(const std::string& task_id);
  const AgentTask* GetTask(const std::string& task_id) const;
  AgentTask* MostRecentTask();
  const AgentTask* MostRecentTask() const;
  size_t task_count_for_testing() const { return tasks_.size(); }
  void FlushTaskStoreForTesting(base::OnceCallback<void(bool)> callback);
  bool SetPendingInvocationContext(AgentInvocationContext context);
  const AgentInvocationContext* PendingInvocationContext() const;
  void ClearPendingInvocationContext();
  void AddObserver(AegisAgentServiceObserver* observer);
  void RemoveObserver(AegisAgentServiceObserver* observer);

  bool BeginPlanning(const std::string& task_id);
  void RouteGoal(std::string goal,
                 AgentWorkflowKind requested_workflow,
                 GoalRouteCallback callback);
  void SetGoalRouteForTesting(std::optional<AgentGoalRoute> route);
  void SetGoalRouterClientForTesting(std::unique_ptr<AgentModelClient> client);
  void SetTypeSafeGoalRouterClientForTesting(
      std::unique_ptr<TypeSafeGoalRouterClient> client);
  void CancelPendingGoalRouting();
  void InvalidatePendingModelDispatches();
  void SetTaskModelClientForTesting(const std::string& task_id,
                                    std::unique_ptr<AgentModelClient> client);
  bool AcceptModelPlan(const std::string& task_id,
                       const AgentModelEvent& event,
                       std::string* error);
  void RequestPlan(const std::string& task_id, PlanReadyCallback callback);
  bool SetPlanReady(const std::string& task_id);
  const AgentTaskPlan* GetPlan(const std::string& task_id) const;
  const AgentCompletionSummary* GetCompletionSummary(
      const std::string& task_id) const;
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
  bool MarkMonitorFinished(
      const std::string& task_id,
      const std::string& monitor_id,
      bool success,
      base::Time now,
      AgentMonitorCheckStatus status = AgentMonitorCheckStatus::kNotChecked,
      int http_status = 0);
  std::vector<AgentMonitorDefinition> GetMonitors(
      const std::string& task_id) const;
  std::vector<AgentMonitorDefinition> GetAllMonitors() const;

  const AgentToolRegistry& tool_registry() const { return tool_registry_; }
  bool task_store_is_in_memory_for_testing() const {
    return task_store_is_in_memory_;
  }
  std::optional<StoredAgentTask::RecoveryDisposition> recovery_disposition(
      const std::string& task_id) const;
  AegisActorBridge& actor_bridge_for_testing() { return actor_bridge_; }

  // KeyedService:
  void Shutdown() override;

 private:
  friend class AegisAgentServiceTestPeer;

  struct ExecutionRuntime;
  struct MonitorUrlCheck;
  struct MonitorPageCheck;
  using ActionResults = std::map<std::string, AgentToolResult>;

  bool Transition(const std::string& task_id,
                  AgentTaskState state,
                  std::string reason);
  void FailPlanning(const std::string& task_id,
                    PlanReadyCallback callback,
                    std::string error);
  bool TryReadOnlyPlanningRecovery(const std::string& task_id,
                                   std::string* error);
  bool PersistTask(const AgentTask& task);
  bool PersistTaskAndBindGoalRoute(const AgentTask& task,
                                   const std::string& route_id);
  void StartObservedModelRequest(AgentTask* task,
                                 AgentModelClient* client,
                                 AgentModelClientConfig config,
                                 AgentModelRequest request,
                                 AgentModelClient::Callback callback);
  void OnModelAttemptStored(std::string task_id,
                            std::string observation_id,
                            std::pair<uint64_t, uint64_t> dispatch_token,
                            base::WeakPtr<AgentModelClient> client,
                            AgentModelClientConfig config,
                            AgentModelRequest request,
                            AgentModelClient::Callback callback,
                            bool saved);
  void StopDispatchForConfigurationChange(const std::string& task_id);
  void OnObservedModelResult(std::string task_id,
                             std::string observation_id,
                             uint64_t task_generation,
                             base::TimeTicks started,
                             AgentModelClient::Callback callback,
                             bool ok,
                             std::string error,
                             AgentModelParseResult result);
  AgentTaskStoreRecord MakeTaskStoreRecord(const AgentTask& task) const;
  bool PersistPlan(const std::string& task_id,
                   const AgentTaskPlan& plan,
                   size_t next_step,
                   int attempt);
  bool PersistPlanProgress(const std::string& task_id,
                           size_t next_step,
                           int attempt);
  bool PersistMonitor(const AgentMonitorDefinition& monitor);
  bool DeletePersistedMonitor(const std::string& monitor_id);
  void AppendPersistedActionSummary(const std::string& task_id,
                                    const std::string& action_id,
                                    const std::string& tool_name,
                                    AgentRiskLevel risk,
                                    bool ok,
                                    const std::string& redacted_summary);
  void OnTaskStoreLoaded(std::optional<StoredAgentState> state);
  void OnCriticalStoreWriteFinished(bool ok);
  bool ConsumeModelRequestBudget(AgentTask* task);
  void RestoreUnfinishedTasks(StoredAgentState state);
  void RestoreMonitors(std::vector<AgentMonitorDefinition> monitors);
  void RestoreMonitorTargets(const std::string& monitor_id = {});
  void OnMonitorTargetsDecryptorReady(
      const std::string& monitor_id,
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
  void StartMonitorUrlRequest(const std::string& monitor_id);
  void OnMonitorUrlRedirect(const std::string& monitor_id,
                            const std::string& request_id,
                            const GURL& previous_url,
                            const net::RedirectInfo& redirect,
                            const network::mojom::URLResponseHead& response,
                            std::vector<std::string>* removed_headers);
  void OnMonitorUrlHeaders(const std::string& monitor_id,
                           const std::string& request_id,
                           scoped_refptr<net::HttpResponseHeaders> headers);
  void FinishMonitorUrlCheck(const std::string& monitor_id,
                             AgentMonitorCheckStatus status,
                             int http_status = 0);
  void StartMonitorPageCheck(AgentMonitorDefinition monitor);
  void AttachMonitorPage(const std::string& monitor_id,
                         const std::string& request_id);
  void OnMonitorPageAttached(const std::string& monitor_id,
                            const std::string& request_id,
                            bool attached);
  void OnMonitorPageLoaded(const std::string& monitor_id,
                          const std::string& request_id);
  void OnMonitorPageObserved(const std::string& monitor_id,
                            const std::string& request_id,
                            AgentToolCall call,
                            AgentToolResult result);
  void OnMonitorObservationEncryptorReady(
      const std::string& monitor_id,
      const std::string& request_id,
      std::string observation,
      scoped_refptr<os_crypt_async::Encryptor> encryptor);
  void RequestMonitorSummary(const std::string& monitor_id,
                             const std::string& request_id);
  void OnMonitorSummaryResult(const std::string& monitor_id,
                              const std::string& request_id,
                              bool ok,
                              std::string error,
                              AgentModelParseResult result);
  void PersistMonitorObservation(const std::string& monitor_id,
                                 const std::string& request_id,
                                 std::string observation);
  void FinishMonitorPageCheck(
      const std::string& monitor_id,
      const std::string& request_id,
      AgentMonitorCheckStatus status,
      std::optional<std::string> observation = std::nullopt);
  void ShowMonitorChangeNotification(
      const AgentMonitorDefinition& monitor) const;
  void RequestPlanAttempt(const std::string& task_id,
                          int repair_attempt,
                          bool using_fallback,
                          std::string previous_error,
                          PlanReadyCallback callback);
  void OnPlanModelResult(const std::string& task_id,
                         int repair_attempt,
                         bool using_fallback,
                         PlanReadyCallback callback,
                         bool ok,
                         std::string error,
                         AgentModelParseResult result);
  void RouteGoalAttempt(std::string goal,
                        AgentWorkflowKind requested_workflow,
                        uint64_t route_generation,
                        int repair_attempt,
                        std::string previous_error,
                        GoalRouteCallback callback);
  void OnInitialGoalRouteStored(uint64_t generation,
                                std::string goal,
                                AgentWorkflowKind requested_workflow,
                                bool saved);
  void OnTypeSafeGoalRouteAttemptStored(
      uint64_t generation,
      uint64_t settings_generation,
      std::string observation_id,
      std::string goal,
      AgentWorkflowKind requested_workflow,
      std::string api_key,
      bool saved);
  void OnGoalRouteModelAttemptStored(
      uint64_t generation,
      std::string observation_id,
      std::string goal,
      AgentWorkflowKind requested_workflow,
      int repair_attempt,
      AgentModelClientConfig config,
      AgentModelRequest request,
      GoalRouteCallback callback,
      bool saved);
  void OnGoalRouteModelResult(uint64_t generation,
                              std::string observation_id,
                              std::string goal,
                              AgentWorkflowKind requested_workflow,
                              int repair_attempt,
                              GoalRouteCallback callback,
                              bool ok,
                              std::string error,
                              AgentModelParseResult result);
  void OnTypeSafeGoalRouteResult(
      uint64_t generation,
      uint64_t settings_generation,
      std::string observation_id,
      std::string goal,
      AgentWorkflowKind requested_workflow,
      bool ok,
      std::string error,
      std::optional<TypeSafeGoalAnalysis> analysis);
  void CompleteGoalRouting(uint64_t generation,
                           bool ok,
                           std::string error,
                           std::optional<AgentGoalRoute> route);
  void OnGoalRoutingFinalized(uint64_t generation,
                              bool ok,
                              std::string error,
                              std::optional<AgentGoalRoute> route,
                              bool saved);
  void PersistCurrentGoalRouteObservation(
      AgentGoalRouteStatus status,
      base::OnceCallback<void(bool)> callback);
  bool CompleteGoalRouteAttempt(std::string_view observation_id,
                                AgentModelAttempt completion);
  void OnGoalRouteObservationBound(std::string route_id,
                                   std::string task_id,
                                   bool bound);
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
      std::optional<int32_t> preferred_tab_id,
      int attempt,
      const AgentModelEvent& event,
      std::string* error) const;
  void ExecuteRuntimeTool(const std::string& task_id,
                          AgentToolCall call,
                          const std::optional<std::string>& approval_id);
  void OnRuntimeToolResult(const std::string& task_id,
                           AgentToolCall attempted_call,
                           AgentToolResult result);
  bool FinishWithBrowserVerifiedFallback(const std::string& task_id);
  void FinishValidatedRuntimeCompletion(const std::string& task_id,
                                        AgentCompletionSummary completion);
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
  const bool task_store_is_in_memory_;
  base::SequenceBound<AgentTaskStore> task_store_;
  AgentToolRegistry tool_registry_;
  AgentPolicyBroker policy_broker_;
  AgentResultVerifier result_verifier_;
  AgentMonitorScheduler monitor_scheduler_;
  std::map<std::string, std::unique_ptr<MonitorUrlCheck>> monitor_url_checks_;
  AegisActorBridge actor_bridge_;
  AegisBrowserTools browser_tools_;
  std::map<std::string, std::unique_ptr<MonitorPageCheck>> monitor_page_checks_;
  std::map<std::string, std::unique_ptr<AgentTask>> tasks_;
  std::map<std::string, AgentTaskPlan> plans_;
  std::map<std::string, AgentCompletionSummary> completion_summaries_;
  std::map<std::string, std::pair<size_t, int>> plan_progress_;
  std::map<std::string, std::unique_ptr<AgentModelClient>> model_clients_;
  std::map<std::string, std::string> model_request_ids_;
  uint64_t model_dispatch_generation_ = 0;
  std::map<std::string, uint64_t> task_dispatch_generations_;
  std::unique_ptr<AgentModelClient> goal_router_client_;
  std::string goal_router_request_id_;
  std::unique_ptr<TypeSafeGoalRouterClient> typesafe_goal_router_client_;
  std::string typesafe_goal_router_request_id_;
  uint64_t goal_route_generation_ = 0;
  GoalRouteCallback pending_goal_route_callback_;
  std::optional<AgentGoalRoute> goal_route_for_testing_;
  AgentModelRequirements last_goal_model_requirements_;
  AgentModelRoutingMetrics last_goal_routing_metrics_;
  std::string current_goal_route_id_;
  std::vector<AgentGoalRouteObservation> goal_route_observations_;
  std::map<std::string, base::TimeTicks> goal_route_attempt_started_at_;
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
  // The store accepts queued work immediately. Initialization and every
  // database operation run in order on a dedicated MayBlock sequence.
  bool storage_ready_ = true;
  bool shutting_down_ = false;
  base::WeakPtrFactory<AegisAgentService> weak_ptr_factory_{this};
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AEGIS_AGENT_SERVICE_H_
