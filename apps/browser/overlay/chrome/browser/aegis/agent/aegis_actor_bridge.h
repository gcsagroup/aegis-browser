// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AEGIS_ACTOR_BRIDGE_H_
#define CHROME_BROWSER_AEGIS_AGENT_AEGIS_ACTOR_BRIDGE_H_

#include <map>
#include <optional>
#include <string>

#include "base/callback_list.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/actor/actor_keyed_service.h"
#include "chrome/browser/actor/tab_observation_strategy.h"
#include "chrome/browser/aegis/agent/agent_types.h"
#include "components/actor/core/task_id.h"

class Profile;

namespace actor {
class ActorTask;
}  // namespace actor

namespace aegis::agent {

// Owns the Aegis-to-Actor lifecycle and page-tool translation. Model traffic
// and Glic UI are deliberately outside this adapter.
class AegisActorBridge {
 public:
  using ToolResultCallback = base::OnceCallback<void(AgentToolResult)>;
  enum class StateEvent {
    kPausedByUser,
    kWaitingOnUser,
  };
  using StateEventCallback =
      base::RepeatingCallback<void(const std::string&, StateEvent)>;

  explicit AegisActorBridge(Profile* profile);
  AegisActorBridge(const AegisActorBridge&) = delete;
  AegisActorBridge& operator=(const AegisActorBridge&) = delete;
  ~AegisActorBridge();

  bool IsAvailable() const;
  void SetStateEventCallback(StateEventCallback callback);
  std::optional<actor::TaskId> StartTask(const std::string& agent_task_id,
                                         const AgentTaskScope& scope);
  bool PauseTask(const std::string& agent_task_id, bool by_user);
  bool ResumeTask(const std::string& agent_task_id);
  bool StopTask(const std::string& agent_task_id, bool completed);
  bool HasTask(const std::string& agent_task_id) const;
  bool AdoptTab(const std::string& agent_task_id, int32_t tab_id);
  bool ReleaseTab(const std::string& agent_task_id, int32_t tab_id);
  void ExecutePageTool(const std::string& agent_task_id,
                       const AgentToolCall& call,
                       ToolResultCallback callback);
  std::optional<AgentDocumentRef> LastDocument(const std::string& agent_task_id,
                                               int32_t tab_id) const;
  size_t active_task_count_for_testing() const { return actor_tasks_.size(); }

 private:
  struct WebMcpToolMetadata {
    std::string revision;
    base::DictValue input_schema;
    bool read_only = false;
  };

  struct WebMcpDocument {
    std::string document_token;
    std::map<std::string, WebMcpToolMetadata> tools;
  };

  struct ObservedNodeMetadata {
    std::string text;
    bool is_submit_control = false;
    bool is_sensitive_control = false;
  };

  void ObservePage(const std::string& agent_task_id,
                   std::string action_id,
                   int32_t tab_id,
                   std::optional<GURL> expected_url,
                   bool post_action,
                   ToolResultCallback callback);
  void OnObservation(
      const std::string& agent_task_id,
      std::string action_id,
      int32_t tab_id,
      std::optional<GURL> expected_url,
      bool post_action,
      ToolResultCallback callback,
      actor::ActorKeyedService::TabObservationResult observation_result);
  void OnActionsPerformed(
      const std::string& agent_task_id,
      std::string action_id,
      int32_t tab_id,
      ToolResultCallback callback,
      std::vector<actor::ActionResultWithLatencyInfo> action_results,
      actor::TabObservationStrategy observation_strategy);
  actor::ActorTask* GetActorTask(const std::string& agent_task_id) const;
  void OnActorTaskStateChanged(actor::ActorTask& task);

  const raw_ptr<Profile> profile_;
  const raw_ptr<actor::ActorKeyedService> actor_service_;
  std::map<std::string, actor::TaskId> actor_tasks_;
  std::map<std::string, AgentTaskScope> task_scopes_;
  std::map<std::string, std::map<int32_t, AgentDocumentRef>> last_documents_;
  std::map<std::string, std::map<int32_t, std::map<int, ObservedNodeMetadata>>>
      observed_node_text_;
  std::map<std::string, std::map<int32_t, WebMcpDocument>> webmcp_documents_;
  base::CallbackListSubscription actor_state_subscription_;
  StateEventCallback state_event_callback_;
  base::WeakPtrFactory<AegisActorBridge> weak_ptr_factory_{this};
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AEGIS_ACTOR_BRIDGE_H_
