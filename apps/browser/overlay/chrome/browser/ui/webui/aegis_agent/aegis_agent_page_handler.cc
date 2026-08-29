// Copyright 2026 GCSA

#include "chrome/browser/ui/webui/aegis_agent/aegis_agent_page_handler.h"

#include <algorithm>
#include <optional>
#include <utility>

#include "base/containers/flat_set.h"
#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/aegis/agent/aegis_agent_service.h"
#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"
#include "chrome/browser/aegis/agent/agent_policy_broker.h"
#include "chrome/browser/aegis/agent/agent_workflow.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/webui/aegis_agent/aegis_agent_ui.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/search_engines/template_url_service.h"
#include "components/tabs/public/tab_interface.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace {

using aegis::agent::AgentDataClass;
using aegis::agent::AgentMode;
using aegis::agent::AgentRiskLevel;
using aegis::agent::AgentTask;
using aegis::agent::AgentTaskState;
using aegis::agent::AgentWorkflowKind;

const char* ModeName(AgentMode mode) {
  switch (mode) {
    case AgentMode::kAsk:
      return "ask";
    case AgentMode::kAct:
      return "act";
    case AgentMode::kAutomate:
      return "automate";
  }
}

const char* RiskName(AgentRiskLevel risk) {
  switch (risk) {
    case AgentRiskLevel::kR0ReadOnly:
      return "R0 · read only";
    case AgentRiskLevel::kR1Reversible:
      return "R1 · reversible";
    case AgentRiskLevel::kR2ExternalSideEffect:
      return "R2 · approval required";
    case AgentRiskLevel::kR3UserTakeover:
      return "R3 · user takeover";
    case AgentRiskLevel::kBlocked:
      return "blocked";
  }
}

const char* DataClassName(AgentDataClass data_class) {
  switch (data_class) {
    case AgentDataClass::kPublicPage:
      return "public_page";
    case AgentDataClass::kBrowserMetadata:
      return "browser_metadata";
    case AgentDataClass::kBookmarks:
      return "bookmarks";
    case AgentDataClass::kHistory:
      return "history";
    case AgentDataClass::kDownloads:
      return "downloads";
    case AgentDataClass::kFormData:
      return "form_data";
    case AgentDataClass::kSecret:
      return "secret";
  }
}

std::optional<AgentMode> ConvertMode(aegis_agent::mojom::AgentMode mode) {
  switch (mode) {
    case aegis_agent::mojom::AgentMode::kAsk:
      return AgentMode::kAsk;
    case aegis_agent::mojom::AgentMode::kAct:
      return AgentMode::kAct;
    case aegis_agent::mojom::AgentMode::kAutomate:
      return AgentMode::kAutomate;
  }
}

std::optional<AgentWorkflowKind> ConvertWorkflow(
    aegis_agent::mojom::Workflow workflow) {
  switch (workflow) {
    case aegis_agent::mojom::Workflow::kResearch:
      return AgentWorkflowKind::kResearch;
    case aegis_agent::mojom::Workflow::kBrowserSteward:
      return AgentWorkflowKind::kBrowserSteward;
    case aegis_agent::mojom::Workflow::kSafeDownload:
      return AgentWorkflowKind::kSafeDownload;
    case aegis_agent::mojom::Workflow::kShopping:
      return AgentWorkflowKind::kShopping;
  }
}

std::string MonitorKindName(aegis::agent::AgentMonitorKind kind) {
  switch (kind) {
    case aegis::agent::AgentMonitorKind::kPrice:
      return "price";
    case aegis::agent::AgentMonitorKind::kInventory:
      return "inventory";
    case aegis::agent::AgentMonitorKind::kPageChange:
      return "page_change";
    case aegis::agent::AgentMonitorKind::kUrlStatus:
      return "url_status";
  }
}

tabs::TabInterface* ActiveTab(BrowserWindowInterface* browser) {
  return browser ? browser->GetActiveTabInterface() : nullptr;
}

bool WorkflowNeedsWebTarget(AgentWorkflowKind workflow) {
  return workflow != AgentWorkflowKind::kBrowserSteward;
}

std::optional<GURL> ExplicitUrlFromGoal(std::string_view goal) {
  const size_t https = goal.find("https://");
  const size_t http = goal.find("http://");
  const size_t start = std::min(https, http);
  if (start == std::string_view::npos) {
    return std::nullopt;
  }
  size_t end = goal.find_first_of(" \t\r\n", start);
  std::string candidate(goal.substr(start, end == std::string_view::npos
                                               ? goal.size() - start
                                               : end - start));
  constexpr std::string_view kTrailingPunctuation[] = {
      ".",  ",",  ";",  ":",  "!",  "?",  ")",  "]",  "}",  "'",
      "\"", "，", "。", "；", "：", "！", "？", "）", "】", "》"};
  bool trimmed = true;
  while (trimmed && !candidate.empty()) {
    trimmed = false;
    for (std::string_view punctuation : kTrailingPunctuation) {
      if (base::EndsWith(candidate, punctuation)) {
        candidate.resize(candidate.size() - punctuation.size());
        trimmed = true;
        break;
      }
    }
  }
  const GURL url(candidate);
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() ? std::make_optional(url)
                                                     : std::nullopt;
}

std::optional<GURL> ResolveAutomaticTaskUrl(Profile* profile,
                                            std::string_view goal) {
  if (std::optional<GURL> explicit_url = ExplicitUrlFromGoal(goal)) {
    return explicit_url;
  }
  TemplateURLService* search =
      profile ? TemplateURLServiceFactory::GetForProfile(profile) : nullptr;
  if (!search) {
    return std::nullopt;
  }
  const GURL url = search->GenerateSearchURLForDefaultSearchProvider(
      base::UTF8ToUTF16(goal));
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() ? std::make_optional(url)
                                                     : std::nullopt;
}

tabs::TabInterface* OpenAutomaticTaskTab(BrowserWindowInterface* browser,
                                         const GURL& url) {
  if (!browser || !url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return nullptr;
  }
  NavigateParams params(browser, url, ui::PAGE_TRANSITION_GENERATED);
  params.disposition = WindowOpenDisposition::NEW_FOREGROUND_TAB;
  Navigate(&params);
  return params.navigated_or_inserted_contents
             ? tabs::TabInterface::GetFromContents(
                   params.navigated_or_inserted_contents)
             : nullptr;
}

std::optional<std::vector<url::Origin>> ParseApprovedOrigins(
    const GURL& active_url,
    const std::vector<std::string>& values) {
  constexpr size_t kMaxApprovedOrigins = 20;
  constexpr size_t kMaxOriginBytes = 2048;
  if (!active_url.is_valid() || !active_url.SchemeIsHTTPOrHTTPS() ||
      values.empty() || values.size() > kMaxApprovedOrigins) {
    return std::nullopt;
  }

  const url::Origin active_origin = url::Origin::Create(active_url);
  base::flat_set<std::string> seen;
  std::vector<url::Origin> origins;
  origins.reserve(values.size());
  bool includes_active_origin = false;
  for (const std::string& value : values) {
    if (value.empty() || value.size() > kMaxOriginBytes) {
      return std::nullopt;
    }
    const GURL url(value);
    const url::Origin origin = url::Origin::Create(url);
    if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || origin.opaque() ||
        url != origin.GetURL()) {
      return std::nullopt;
    }
    const std::string serialized = origin.Serialize();
    if (!seen.insert(serialized).second) {
      return std::nullopt;
    }
    includes_active_origin |= origin == active_origin;
    origins.push_back(origin);
  }
  return includes_active_origin
             ? std::optional<std::vector<url::Origin>>(std::move(origins))
             : std::nullopt;
}

}  // namespace

AegisAgentPageHandler::AegisAgentPageHandler(
    Profile* profile,
    BrowserWindowInterface* browser,
    AegisAgentUI* ui,
    mojo::PendingRemote<aegis_agent::mojom::Page> page,
    mojo::PendingReceiver<aegis_agent::mojom::PageHandler> receiver)
    : profile_(profile),
      browser_(browser && browser->GetProfile() == profile ? browser : nullptr),
      ui_(ui),
      page_(std::move(page)),
      receiver_(this, std::move(receiver)) {
  if (profile_ && profile_->GetPrefs()) {
    pref_change_registrar_.Init(profile_->GetPrefs());
    pref_change_registrar_.Add(
        aegis::prefs::kAgentEnabled,
        base::BindRepeating(&AegisAgentPageHandler::OnAgentEnabledChanged,
                            weak_ptr_factory_.GetWeakPtr()));
  }
  if (browser_) {
    active_tab_subscription_ = browser_->RegisterActiveTabDidChange(
        base::BindRepeating(&AegisAgentPageHandler::OnActiveTabDidChange,
                            weak_ptr_factory_.GetWeakPtr()));
  }
  service_ =
      profile ? aegis::agent::AegisAgentServiceFactory::GetForProfile(profile)
              : nullptr;
  ObserveService(service_);
  if (service_) {
    ObserveTask(service_->MostRecentTask());
  }
}

void AegisAgentPageHandler::ShowUI() {
  if (ui_ && ui_->embedder()) {
    ui_->embedder()->ShowUI();
  }
}

AegisAgentPageHandler::~AegisAgentPageHandler() = default;

void AegisAgentPageHandler::OnAgentEnabledChanged() {
  if (!profile_) {
    return;
  }
  if (profile_->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled)) {
    service_ = aegis::agent::AegisAgentServiceFactory::GetForProfile(profile_);
  } else {
    service_ =
        aegis::agent::AegisAgentServiceFactory::GetForProfileIfExists(profile_);
  }
  ObserveService(service_);
  ObserveTask(service_ ? service_->MostRecentTask() : nullptr);
  PushSnapshot();
}

void AegisAgentPageHandler::OnActiveTabDidChange(
    BrowserWindowInterface* browser) {
  if (browser == browser_) {
    PushSnapshot();
  }
}

void AegisAgentPageHandler::GetSnapshot(GetSnapshotCallback callback) {
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::CreateTask(
    const std::string& goal,
    aegis_agent::mojom::AgentMode mode,
    aegis_agent::mojom::Workflow workflow,
    const std::vector<std::string>& approved_origins,
    CreateTaskCallback callback) {
  last_error_.clear();
  service_ =
      profile_ ? aegis::agent::AegisAgentServiceFactory::GetForProfile(profile_)
               : nullptr;
  ObserveService(service_);
  const std::optional<AgentMode> converted_mode = ConvertMode(mode);
  const std::optional<AgentWorkflowKind> converted_workflow =
      ConvertWorkflow(workflow);
  const std::optional<aegis::agent::AgentModelDestination> model_destination =
      service_ ? service_->ConfiguredModelDestination() : std::nullopt;
  tabs::TabInterface* tab = ActiveTab(browser_);
  GURL task_url = tab ? tab->GetURL() : GURL();
  std::vector<std::string> resolved_origin_values = approved_origins;
  const bool has_current_web_target =
      tab && task_url.is_valid() && task_url.SchemeIsHTTPOrHTTPS();
  const bool invalid_explicit_origins =
      has_current_web_target && !approved_origins.empty() &&
      !ParseApprovedOrigins(task_url, approved_origins);
  const bool browser_only_task = converted_workflow &&
                                 !WorkflowNeedsWebTarget(*converted_workflow) &&
                                 resolved_origin_values.empty();
  if (!service_ || !service_->IsEnabled()) {
    last_error_ = "Browser Agent is disabled";
  } else if (!converted_mode || !converted_workflow || goal.empty() ||
             goal.size() > 4096u || invalid_explicit_origins) {
    last_error_ = "Task input is invalid";
  } else if (!model_destination) {
    last_error_ = "Configure a valid Agent model provider before planning";
  } else {
    const bool has_web_target =
        tab && tab->GetURL().is_valid() && tab->GetURL().SchemeIsHTTPOrHTTPS();
    if (!has_web_target && !browser_only_task) {
      std::optional<GURL> automatic_url;
      if (!resolved_origin_values.empty()) {
        const GURL explicit_origin(resolved_origin_values.front());
        if (explicit_origin.is_valid() &&
            explicit_origin.SchemeIsHTTPOrHTTPS()) {
          automatic_url = explicit_origin;
        }
      } else {
        automatic_url = ResolveAutomaticTaskUrl(profile_, goal);
      }
      tab = automatic_url ? OpenAutomaticTaskTab(browser_, *automatic_url)
                          : nullptr;
      if (tab && resolved_origin_values.empty()) {
        resolved_origin_values.push_back(
            url::Origin::Create(*automatic_url).Serialize());
      }
      if (tab) {
        task_url = *automatic_url;
      }
    } else if (has_web_target && resolved_origin_values.empty() &&
               !browser_only_task) {
      resolved_origin_values.push_back(
          url::Origin::Create(tab->GetURL()).Serialize());
    }

    std::optional<std::vector<url::Origin>> origins;
    if (browser_only_task) {
      origins.emplace();
    } else if (tab) {
      origins = ParseApprovedOrigins(task_url, resolved_origin_values);
    }
    if (!tab || !origins) {
      last_error_ = "A related page could not be opened for this task";
      std::move(callback).Run(BuildSnapshot());
      return;
    }
    std::optional<aegis::agent::AgentTaskScope> scope =
        aegis::agent::BuildAgentWorkflowScope(*converted_workflow, *origins,
                                              {tab->GetHandle().raw_value()},
                                              *model_destination);
    AgentTask* task =
        scope ? service_->CreateTask(goal, *converted_mode, std::move(*scope))
              : nullptr;
    if (!task) {
      last_error_ = "Task scope could not be created";
    } else {
      service_->ClearPendingInvocationContext();
      active_task_id_ = task->id();
      ObserveTask(task);
    }
  }
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::RequestPlan(const std::string& task_id,
                                        RequestPlanCallback callback) {
  last_error_.clear();
  AgentTask* task = service_ ? service_->GetTask(task_id) : nullptr;
  if (!task) {
    last_error_ = "Task is unavailable";
  } else {
    active_task_id_ = task_id;
    ObserveTask(task);
    service_->RequestPlan(
        task_id, base::BindOnce(&AegisAgentPageHandler::OnPlanReady,
                                weak_ptr_factory_.GetWeakPtr(), task_id));
  }
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::ConsentAndRun(const std::string& task_id,
                                          ConsentAndRunCallback callback) {
  last_error_.clear();
  AgentTask* task = service_ ? service_->GetTask(task_id) : nullptr;
  bool ready = false;
  if (task && task->state() == AgentTaskState::kAwaitingTaskConsent) {
    ready = service_->GrantTaskConsent(task_id);
  } else if (task && task->state() == AgentTaskState::kRecovering) {
    ready = service_->GrantRecoveryConsent(task_id);
  } else if (task && task->state() == AgentTaskState::kRunning) {
    ready = true;
  }
  if (!ready) {
    last_error_ = "Task is not ready to run";
  } else {
    active_task_id_ = task_id;
    ObserveTask(task);
    service_->RunTask(task_id,
                      base::BindOnce(&AegisAgentPageHandler::OnRunFinished,
                                     weak_ptr_factory_.GetWeakPtr(), task_id));
  }
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::Pause(const std::string& task_id,
                                  PauseCallback callback) {
  last_error_ = service_ && service_->PauseTask(task_id)
                    ? std::string()
                    : "Task could not be paused";
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::Resume(const std::string& task_id,
                                   ResumeCallback callback) {
  last_error_ = service_ && service_->ResumeTask(task_id)
                    ? std::string()
                    : "Task could not be resumed";
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::TakeOver(const std::string& task_id,
                                     TakeOverCallback callback) {
  last_error_ = service_ && service_->BeginUserTakeover(task_id)
                    ? std::string()
                    : "User takeover could not begin";
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::FinishTakeOver(const std::string& task_id,
                                           bool completed,
                                           FinishTakeOverCallback callback) {
  const AgentTask* task = service_ ? service_->GetTask(task_id) : nullptr;
  bool ok = false;
  if (task && task->state() == AgentTaskState::kUserTakeover) {
    ok = service_->CompleteFinalUserTakeover(task_id, completed);
    if (!ok && !completed) {
      ok = service_->CancelTask(task_id);
    } else if (!ok) {
      ok = service_->FinishUserTakeover(task_id);
    }
  }
  last_error_ = ok ? std::string() : "User takeover could not be finished";
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::Stop(const std::string& task_id,
                                 StopCallback callback) {
  last_error_ = service_ && service_->CancelTask(task_id)
                    ? std::string()
                    : "Task could not be stopped";
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::Approve(const std::string& task_id,
                                    const std::string& action_id,
                                    ApproveCallback callback) {
  const aegis::agent::AgentToolCall* pending =
      service_ ? service_->PendingAction(task_id) : nullptr;
  const bool exact = pending && pending->action_id == action_id;
  last_error_ = exact && service_->ApprovePendingAction(task_id)
                    ? std::string()
                    : "Exact action approval was rejected";
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::Undo(const std::string& task_id,
                                 UndoCallback callback) {
  if (!service_ || !service_->CanUndoLastBookmarkAction(task_id)) {
    last_error_ = "No browser-verified undo receipt is available";
    std::move(callback).Run(BuildSnapshot());
    return;
  }
  service_->UndoLastBookmarkAction(
      task_id, base::BindOnce(&AegisAgentPageHandler::OnUndoFinished,
                              weak_ptr_factory_.GetWeakPtr(), task_id,
                              std::move(callback)));
}

void AegisAgentPageHandler::SetMonitorPaused(
    const std::string& task_id,
    const std::string& monitor_id,
    bool paused,
    SetMonitorPausedCallback callback) {
  AgentTask* task = service_ ? service_->GetTask(task_id) : nullptr;
  const bool ok = task && task->mode() == AgentMode::kAutomate &&
                  service_->SetMonitorPaused(task_id, monitor_id, paused);
  last_error_ =
      ok ? std::string() : "Task-owned monitor state could not be changed";
  if (ok) {
    active_task_id_ = task_id;
    ObserveTask(task);
  }
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::DeleteMonitor(const std::string& task_id,
                                          const std::string& monitor_id,
                                          DeleteMonitorCallback callback) {
  AgentTask* task = service_ ? service_->GetTask(task_id) : nullptr;
  const bool ok = task && task->mode() == AgentMode::kAutomate &&
                  service_->RemoveMonitor(task_id, monitor_id);
  last_error_ = ok ? std::string() : "Task-owned monitor could not be deleted";
  if (ok) {
    active_task_id_ = task_id;
    ObserveTask(task);
  }
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::OnAgentTaskStateChanged(
    const std::string& task_id,
    const aegis::agent::AgentTaskEvent& event) {
  if (task_id == active_task_id_) {
    PushSnapshot();
  }
}

void AegisAgentPageHandler::OnPlanReady(const std::string& task_id,
                                        bool ok,
                                        std::string error) {
  if (task_id != active_task_id_) {
    return;
  }
  last_error_ = ok ? std::string() : std::move(error);
  PushSnapshot();
}

void AegisAgentPageHandler::OnRunFinished(
    const std::string& task_id,
    bool ok,
    std::string error,
    std::optional<aegis::agent::AgentCompletionSummary> completion) {
  if (task_id != active_task_id_) {
    return;
  }
  last_error_ = ok ? std::string() : std::move(error);
  PushSnapshot();
}

void AegisAgentPageHandler::OnUndoFinished(
    const std::string& task_id,
    UndoCallback callback,
    aegis::agent::AgentToolResult result) {
  if (task_id == active_task_id_) {
    last_error_ = result.ok ? std::string() : std::move(result.message);
  }
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::OnAgentServiceSnapshotChanged() {
  PushSnapshot();
}

void AegisAgentPageHandler::ObserveService(
    aegis::agent::AegisAgentService* service) {
  if (service_observation_.GetSource() == service) {
    return;
  }
  service_observation_.Reset();
  if (service) {
    service_observation_.Observe(service);
  }
}

void AegisAgentPageHandler::ObserveTask(AgentTask* task) {
  if (task_observation_.GetSource() == task) {
    if (!task) {
      active_task_id_.clear();
    }
    return;
  }
  task_observation_.Reset();
  if (task) {
    task_observation_.Observe(task);
    active_task_id_ = task->id();
  } else {
    active_task_id_.clear();
  }
}

void AegisAgentPageHandler::PushSnapshot() {
  if (page_.is_bound()) {
    page_->OnSnapshotChanged(BuildSnapshot());
  }
}

aegis_agent::mojom::TaskSnapshotPtr AegisAgentPageHandler::BuildSnapshot() {
  auto snapshot = aegis_agent::mojom::TaskSnapshot::New();
  snapshot->feature_enabled =
      base::FeatureList::IsEnabled(aegis::features::kAegisAgent);
  snapshot->agent_enabled =
      profile_ && profile_->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled);
  tabs::TabInterface* tab = ActiveTab(browser_);
  if (tab) {
    snapshot->active_tab_id = tab->GetHandle().raw_value();
  }
  if (tab && tab->GetURL().is_valid() && tab->GetURL().SchemeIsHTTPOrHTTPS()) {
    snapshot->active_origin = url::Origin::Create(tab->GetURL()).Serialize();
    if (service_) {
      const aegis::agent::AgentInvocationContext* invocation =
          service_->PendingInvocationContext();
      if (invocation && invocation->tab_id == snapshot->active_tab_id) {
        snapshot->invocation_context = invocation->display;
        snapshot->suggested_goal = invocation->suggested_goal;
      }
    }
  }
  snapshot->state = "idle";
  snapshot->last_error = last_error_;
  if (service_) {
    for (const aegis::agent::AgentMonitorDefinition& monitor :
         service_->GetAllMonitors()) {
      auto value = aegis_agent::mojom::MonitorSummary::New();
      value->monitor_id = monitor.monitor_id;
      value->task_id = monitor.task_id;
      value->kind = MonitorKindName(monitor.kind);
      value->origin = monitor.origin.Serialize();
      value->target_hash = monitor.target_hash;
      value->interval =
          base::NumberToString(monitor.interval.InMinutes()) + " min";
      value->next_run = base::NumberToString(
          monitor.next_run.InMillisecondsFSinceUnixEpoch());
      value->paused = !monitor.enabled;
      value->failures = monitor.consecutive_failures;
      snapshot->monitors.push_back(std::move(value));
    }
  }

  AgentTask* task = service_ && !active_task_id_.empty()
                        ? service_->GetTask(active_task_id_)
                        : nullptr;
  if (!task && service_) {
    task = service_->MostRecentTask();
    ObserveTask(task);
  }
  if (!task) {
    return snapshot;
  }
  snapshot->task_id = task->id();
  snapshot->state = aegis::agent::AgentTaskStateToString(task->state());
  snapshot->mode = ModeName(task->mode());
  snapshot->goal = task->goal();
  snapshot->undo_available = service_->CanUndoLastBookmarkAction(task->id());

  if (const aegis::agent::AgentTaskPlan* plan = service_->GetPlan(task->id())) {
    auto plan_value = aegis_agent::mojom::PlanSummary::New();
    plan_value->summary = plan->summary;
    AgentRiskLevel max_risk = AgentRiskLevel::kR0ReadOnly;
    for (const url::Origin& origin : plan->scope.allowed_origins) {
      plan_value->origins.push_back(origin.Serialize());
    }
    for (AgentDataClass data_class : plan->scope.allowed_data_classes) {
      plan_value->data_classes.push_back(DataClassName(data_class));
    }
    for (const std::string& tool : plan->scope.allowed_tools) {
      plan_value->tools.push_back(tool);
    }
    for (const aegis::agent::AgentPlanStep& step : plan->steps) {
      auto step_value = aegis_agent::mojom::PlanStep::New();
      step_value->step_id = step.step_id;
      step_value->title = step.title;
      step_value->tool_name = step.tool_name;
      step_value->risk = RiskName(step.risk);
      max_risk = std::max(max_risk, step.risk);
      plan_value->steps.push_back(std::move(step_value));
    }
    plan_value->max_tabs = plan->scope.budgets.max_tabs;
    plan_value->max_tool_calls = plan->scope.budgets.max_tool_calls;
    plan_value->max_model_calls = plan->scope.budgets.max_model_calls;
    plan_value->max_network_requests = plan->scope.budgets.max_network_requests;
    plan_value->max_duration =
        base::NumberToString(plan->scope.budgets.max_duration.InMinutes()) +
        " min";
    plan_value->provider = plan->scope.model_destination.provider;
    plan_value->model = plan->scope.model_destination.model;
    plan_value->destination =
        plan->scope.model_destination.kind ==
                aegis::agent::AgentModelDestination::Kind::kLoopback
            ? "loopback"
            : "cloud";
    plan_value->max_risk = RiskName(max_risk);
    snapshot->plan = std::move(plan_value);
  }

  if (const aegis::agent::AgentToolCall* pending =
          service_->PendingAction(task->id())) {
    auto approval = aegis_agent::mojom::PendingApproval::New();
    approval->action_id = pending->action_id;
    approval->tool_name = pending->tool_name;
    approval->origin =
        pending->committed_url.is_valid()
            ? url::Origin::Create(pending->committed_url).Serialize()
            : std::string();
    const aegis::agent::AgentToolDescriptor* descriptor =
        service_->tool_registry().Find(pending->tool_name);
    approval->risk = descriptor ? RiskName(descriptor->risk) : "blocked";
    if (!base::JSONWriter::Write(pending->arguments,
                                 &approval->argument_summary)) {
      approval->argument_summary = "{}";
    }
    approval->action_fingerprint =
        aegis::agent::AgentPolicyBroker::ActionHash(*pending);
    approval->requires_user_takeover =
        descriptor &&
        descriptor->risk == aegis::agent::AgentRiskLevel::kR3UserTakeover;
    if (pending->tool_name == "shopping.prepare_checkout") {
      auto checkout = aegis_agent::mojom::CheckoutSummary::New();
      const auto string_argument = [&](std::string_view key) {
        const std::string* value = pending->arguments.FindString(key);
        return value ? *value : std::string();
      };
      const auto integer_argument = [&](std::string_view key) {
        return pending->arguments.FindInt(key).value_or(0);
      };
      checkout->merchant = string_argument("merchant");
      checkout->product = string_argument("product");
      checkout->quantity = integer_argument("quantity");
      checkout->unit_price_minor_units =
          base::NumberToString(integer_argument("unit_price_minor_units"));
      checkout->shipping_minor_units =
          base::NumberToString(integer_argument("shipping_minor_units"));
      checkout->tax_minor_units =
          base::NumberToString(integer_argument("tax_minor_units"));
      checkout->discount_minor_units =
          base::NumberToString(integer_argument("discount_minor_units"));
      checkout->total_minor_units =
          base::NumberToString(integer_argument("total_minor_units"));
      checkout->currency = string_argument("currency");
      checkout->delivery_summary = string_argument("delivery_summary");
      checkout->return_summary = string_argument("return_summary");
      const base::ListValue* source_nodes =
          pending->arguments.FindList("source_node_ids");
      checkout->source_node_count =
          source_nodes ? static_cast<int32_t>(source_nodes->size()) : 0;
      checkout->observation_fingerprint =
          string_argument("observation_fingerprint");
      approval->checkout = std::move(checkout);
    }
    snapshot->pending_approval = std::move(approval);
  }

  const auto& events = task->events();
  const size_t first = events.size() > 50u ? events.size() - 50u : 0u;
  for (size_t index = first; index < events.size(); ++index) {
    const aegis::agent::AgentTaskEvent& event = events[index];
    auto event_value = aegis_agent::mojom::TimelineEvent::New();
    event_value->title = event.title.empty()
                             ? aegis::agent::AgentTaskStateToString(event.to)
                             : event.title;
    event_value->detail = event.reason;
    event_value->timestamp =
        base::NumberToString(event.timestamp.InMillisecondsFSinceUnixEpoch());
    event_value->status =
        aegis::agent::IsTerminalState(event.to) ? "terminal" : "active";
    snapshot->timeline.push_back(std::move(event_value));
  }

  return snapshot;
}
