// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AGENT_AEGIS_AGENT_PAGE_HANDLER_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AGENT_AEGIS_AGENT_PAGE_HANDLER_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/callback_list.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "chrome/browser/aegis/agent/agent_execution.h"
#include "chrome/browser/aegis/agent/agent_planner.h"
#include "chrome/browser/aegis/agent/agent_service_observer.h"
#include "chrome/browser/aegis/agent/agent_task.h"
#include "chrome/browser/ui/webui/aegis_agent/aegis_agent.mojom.h"
#include "components/prefs/pref_change_registrar.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "url/gurl.h"
#include "url/origin.h"

class Profile;
class BrowserWindowInterface;
class AegisAgentUI;
class AegisAgentCoreServiceObserver;

namespace aegis::agent {
class AegisAgentService;
}

class AegisAgentPageHandler : public aegis_agent::mojom::PageHandler,
                              public aegis::agent::AgentTaskObserver,
                              public aegis::agent::AegisAgentServiceObserver {
 public:
  AegisAgentPageHandler(
      Profile* profile,
      BrowserWindowInterface* browser,
      AegisAgentUI* ui,
      mojo::PendingRemote<aegis_agent::mojom::Page> page,
      mojo::PendingReceiver<aegis_agent::mojom::PageHandler> receiver);
  AegisAgentPageHandler(const AegisAgentPageHandler&) = delete;
  AegisAgentPageHandler& operator=(const AegisAgentPageHandler&) = delete;
  ~AegisAgentPageHandler() override;

  void ShowUI() override;
  void GetSnapshot(GetSnapshotCallback callback) override;
  void ConfigureModel(const std::string& provider,
                      const std::string& base_url,
                      const std::string& model,
                      const std::string& api_key,
                      bool clear_api_key,
                      ConfigureModelCallback callback) override;
  void ConfigureTypeSafe(bool enabled,
                         const std::string& api_key,
                         bool clear_api_key,
                         ConfigureTypeSafeCallback callback) override;
  void ListModels(const std::string& provider,
                  const std::string& base_url,
                  const std::string& api_key,
                  ListModelsCallback callback) override;
  void CreateTask(const std::string& goal,
                  aegis_agent::mojom::AgentMode mode,
                  aegis_agent::mojom::Workflow workflow,
                  const std::vector<std::string>& approved_origins,
                  int32_t schedule_interval_minutes,
                  CreateTaskCallback callback) override;
  void RequestPlan(const std::string& task_id,
                   RequestPlanCallback callback) override;
  void ConsentAndRun(const std::string& task_id,
                     ConsentAndRunCallback callback) override;
  void Pause(const std::string& task_id, PauseCallback callback) override;
  void Resume(const std::string& task_id, ResumeCallback callback) override;
  void TakeOver(const std::string& task_id, TakeOverCallback callback) override;
  void FinishTakeOver(const std::string& task_id,
                      bool completed,
                      FinishTakeOverCallback callback) override;
  void Stop(const std::string& task_id, StopCallback callback) override;
  void Approve(const std::string& task_id,
               const std::string& action_id,
               ApproveCallback callback) override;
  void Undo(const std::string& task_id, UndoCallback callback) override;
  void SetMonitorPaused(const std::string& task_id,
                        const std::string& monitor_id,
                        bool paused,
                        SetMonitorPausedCallback callback) override;
  void DeleteMonitor(const std::string& task_id,
                     const std::string& monitor_id,
                     DeleteMonitorCallback callback) override;

  void OnAgentTaskStateChanged(
      const std::string& task_id,
      const aegis::agent::AgentTaskEvent& event) override;
  void OnAgentServiceSnapshotChanged() override;

 private:
  aegis_agent::mojom::TaskSnapshotPtr BuildSnapshot();
  void ObserveTask(aegis::agent::AgentTask* task);
  void ObserveService(aegis::agent::AegisAgentService* service);
  void PushSnapshot();
  void OnAgentEnabledChanged();
  void OnActiveTabDidChange(BrowserWindowInterface* browser);
  void OnGoalRouted(std::string goal,
                    aegis::agent::AgentMode mode,
                    std::optional<std::vector<url::Origin>> requested_origins,
                    CreateTaskCallback callback,
                    bool ok,
                    std::string error,
                    std::optional<aegis::agent::AgentGoalRoute> route);
  void CreateResolvedTask(
      std::string goal,
      aegis::agent::AgentMode mode,
      aegis::agent::AgentWorkflowKind workflow,
      std::optional<std::vector<url::Origin>> requested_origins,
      std::optional<GURL> routed_url,
      bool browser_only,
      bool use_current_page,
      CreateTaskCallback callback);
  void OnPlanReady(const std::string& task_id, bool ok, std::string error);
  void OnModelConfigured(ConfigureModelCallback callback,
                         bool ok,
                         std::string error);
  void OnTypeSafeConfigured(ConfigureTypeSafeCallback callback,
                            bool ok,
                            std::string error);
  void OnModelsListed(ListModelsCallback callback,
                      bool ok,
                      std::string error,
                      std::vector<std::string> models);
  void OnRunFinished(
      const std::string& task_id,
      bool ok,
      std::string error,
      std::optional<aegis::agent::AgentCompletionSummary> completion);
  void OnUndoFinished(const std::string& task_id,
                      UndoCallback callback,
                      aegis::agent::AgentToolResult result);

  raw_ptr<Profile> profile_;
  raw_ptr<BrowserWindowInterface> browser_ = nullptr;
  raw_ptr<AegisAgentUI> ui_ = nullptr;
  raw_ptr<aegis::agent::AegisAgentService> service_ = nullptr;
  std::string active_task_id_;
  std::string last_error_;
  mojo::Remote<aegis_agent::mojom::Page> page_;
  mojo::Receiver<aegis_agent::mojom::PageHandler> receiver_;
  PrefChangeRegistrar pref_change_registrar_;
  base::CallbackListSubscription active_tab_subscription_;
  base::ScopedObservation<aegis::agent::AgentTask,
                          aegis::agent::AgentTaskObserver>
      task_observation_{this};
  base::ScopedObservation<aegis::agent::AegisAgentService,
                          aegis::agent::AegisAgentServiceObserver>
      service_observation_{this};
  std::unique_ptr<AegisAgentCoreServiceObserver> core_service_observer_;
  base::WeakPtrFactory<AegisAgentPageHandler> weak_ptr_factory_{this};
};

#endif  // CHROME_BROWSER_UI_WEBUI_AEGIS_AGENT_AEGIS_AGENT_PAGE_HANDLER_H_
