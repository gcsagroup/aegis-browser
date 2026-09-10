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
#include "build/build_config.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/aegis/aegis_service_factory.h"
#include "chrome/browser/aegis/agent/aegis_agent_service.h"
#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"
#include "chrome/browser/aegis/agent/agent_policy_broker.h"
#include "chrome/browser/aegis/agent/agent_monitor_summary.h"
#include "chrome/browser/aegis/agent/agent_workflow.h"
#include "chrome/browser/aegis/model_provider_policy.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "chrome/browser/tab_list/tab_list_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/webui/aegis_agent/aegis_agent_ui.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/search_engines/template_url_service.h"
#include "components/tabs/public/tab_interface.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
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

tabs::TabInterface* ContentTab(BrowserWindowInterface* browser) {
  TabListInterface* tabs = browser ? TabListInterface::From(browser) : nullptr;
  if (!tabs) {
    return nullptr;
  }
  tabs::TabInterface* active = tabs->GetActiveTab();
  if (active && active->GetURL().SchemeIsHTTPOrHTTPS()) {
    return active;
  }
  // 全页 Agent 只沿浏览器保存的直接来源标签读取内容，不能按排列位置猜测。
  // 普通内部页和空白页保持当前目标，使正文任务明确拒绝、书签任务仍可运行。
  if (active && active->GetURL().SchemeIs("chrome-untrusted") &&
      active->GetURL().host() == "aegis-agent") {
    tabs::TabInterface* opener = tabs->GetOpenerForTab(active->GetHandle());
    if (opener && opener->GetURL().SchemeIsHTTPOrHTTPS()) {
      for (tabs::TabInterface* tab : tabs->GetAllTabs()) {
        if (tab == opener) {
          return opener;
        }
      }
    }
  }
  return active;
}

bool WorkflowNeedsWebTarget(AgentWorkflowKind workflow) {
  return workflow != AgentWorkflowKind::kBrowserSteward;
}

// Resolving a deictic page reference belongs to the browser, not the model.
// This keeps common commands reliable and prevents an intent router from
// turning "this page" into a browser-metadata or web-search task.
bool GoalRefersToCurrentPage(std::string_view goal) {
  const std::string lower_goal = base::ToLowerASCII(goal);
  constexpr std::string_view kCurrentPageReferences[] = {
      "当前页",          "当前页面",  "当前网页",     "这个页面",
      "这个网页",        "本页面",    "本网页",       "页面内容",
      "网页内容",        "this page", "current page", "page content",
      "the page content"};
  return std::ranges::any_of(
      kCurrentPageReferences, [&lower_goal](std::string_view reference) {
        return lower_goal.find(reference) != std::string::npos;
      });
}

bool IsValidSchedule(AgentMode mode, int schedule_interval_minutes) {
  if (mode != AgentMode::kAutomate) {
    return schedule_interval_minutes == 0;
  }
  return schedule_interval_minutes >= 15 && schedule_interval_minutes <= 10080;
}

bool GoalRequestsWindowTabMetadata(std::string_view goal) {
  const std::string lower = base::ToLowerASCII(goal);
  if (lower.find("标签") == std::string::npos &&
      lower.find("tab") == std::string::npos) {
    return false;
  }
  constexpr std::string_view references[] = {
      "当前窗口",       "这个窗口",    "本窗口",  "标签页",    "浏览器标签",
      "current window", "this window", "my tabs", "open tabs", "browser tabs"};
  return std::ranges::any_of(references, [&lower](std::string_view reference) {
    return lower.find(reference) != std::string::npos;
  });
}

std::string BindScheduleToGoal(std::string goal,
                               int schedule_interval_minutes) {
  if (schedule_interval_minutes == 0) {
    return goal;
  }
  goal.append(
      "\n\nBrowser-owned schedule: monitor.create must use "
      "interval_minutes=");
  goal.append(base::NumberToString(schedule_interval_minutes));
  goal.append(
      ". The user selected this frequency; do not change it. "
      "[AEGIS_SCHEDULE_INTERVAL_MINUTES=");
  goal.append(base::NumberToString(schedule_interval_minutes));
  goal.push_back(']');
  return goal;
}

std::optional<GURL> ExplicitUrlFromGoal(std::string_view goal) {
  const std::string lower_goal = base::ToLowerASCII(goal);
  const size_t https = lower_goal.find("https://");
  const size_t http = lower_goal.find("http://");
  const size_t www = lower_goal.find("www.");
  const size_t start = std::min({https, http, www});
  if (start == std::string_view::npos) {
    return std::nullopt;
  }
  size_t end = goal.size();
  for (size_t index = start; index < goal.size(); ++index) {
    if (static_cast<unsigned char>(goal[index]) >= 0x80) {
      end = index;
      break;
    }
  }
  const bool bare_domain = start == www && www < https && www < http;
  if (bare_domain) {
    constexpr std::string_view kBareUrlCharacters = "-._~:/?#[]@!$&'()*+,;=%";
    for (size_t index = start; index < goal.size(); ++index) {
      const unsigned char character = goal[index];
      if (!base::IsAsciiAlphaNumeric(character) &&
          kBareUrlCharacters.find(character) == std::string_view::npos) {
        end = std::min(end, index);
        break;
      }
    }
  }
  constexpr std::string_view kUrlDelimiters[] = {
      " ",  "\t", "\r", "\n", ",",  ";",  "!",  "?",  ")",  "]",  "}", "'",
      "\"", "，", "。", "；", "：", "！", "？", "）", "】", "》", "、"};
  for (std::string_view delimiter : kUrlDelimiters) {
    const size_t position = goal.find(delimiter, start);
    if (position != std::string_view::npos) {
      end = std::min(end, position);
    }
  }
  std::string candidate(goal.substr(start, end - start));
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
  const std::string lower_candidate = base::ToLowerASCII(candidate);
  const bool has_scheme = base::StartsWith(lower_candidate, "https://") ||
                          base::StartsWith(lower_candidate, "http://");
  const GURL url(has_scheme ? candidate : "https://" + candidate);
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() &&
                 url.username().empty() && url.password().empty()
             ? std::make_optional(url)
             : std::nullopt;
}

std::vector<url::Origin> AutomaticTaskOrigins(const GURL& task_url) {
  std::vector<url::Origin> origins{url::Origin::Create(task_url)};
  const std::string registrable =
      net::registry_controlled_domains::GetDomainAndRegistry(
          task_url,
          net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  if (registrable.empty()) {
    return origins;
  }
  const std::string host(task_url.host());
  std::string sibling;
  if (host == registrable) {
    sibling = "www." + registrable;
  } else if (host == "www." + registrable) {
    sibling = registrable;
  } else {
    return origins;
  }
  GURL::Replacements replacements;
  replacements.SetHostStr(sibling);
  const GURL sibling_url =
      url::Origin::Create(task_url).GetURL().ReplaceComponents(replacements);
  const url::Origin sibling_origin = url::Origin::Create(sibling_url);
  if (sibling_url.is_valid() && !sibling_origin.opaque()) {
    origins.push_back(sibling_origin);
  }
  return origins;
}

std::optional<GURL> SearchUrlForQuery(Profile* profile,
                                      std::string_view query) {
  TemplateURLService* search =
      profile ? TemplateURLServiceFactory::GetForProfile(profile) : nullptr;
  if (!search || query.empty()) {
    return std::nullopt;
  }
  const GURL url = search->GenerateSearchURLForDefaultSearchProvider(
      base::UTF8ToUTF16(query));
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() ? std::make_optional(url)
                                                     : std::nullopt;
}

tabs::TabInterface* OpenAutomaticTaskTab(BrowserWindowInterface* browser,
                                         const GURL& url) {
  TabListInterface* tabs = browser ? TabListInterface::From(browser) : nullptr;
  if (!tabs || !url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return nullptr;
  }
  return tabs->OpenTab(url, tabs->GetTabCount(), /*foreground=*/true);
}

std::optional<std::vector<url::Origin>> ParseApprovedOrigins(
    const std::vector<std::string>& values) {
  constexpr size_t kMaxApprovedOrigins = 20;
  constexpr size_t kMaxOriginBytes = 2048;
  if (values.empty() || values.size() > kMaxApprovedOrigins) {
    return std::nullopt;
  }

  base::flat_set<std::string> seen;
  std::vector<url::Origin> origins;
  origins.reserve(values.size());
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
    origins.push_back(origin);
  }
  return origins;
}

bool IncludesOrigin(const std::vector<url::Origin>& origins, const GURL& url) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  const url::Origin active_origin = url::Origin::Create(url);
  return std::ranges::any_of(origins, [&](const url::Origin& origin) {
    return origin == active_origin;
  });
}

bool HasUserSetting(PrefService* prefs, const char* name) {
  const PrefService::Preference* preference =
      prefs ? prefs->FindPreference(name) : nullptr;
  return preference && preference->HasUserSetting();
}

aegis::AegisService* CoreServiceForProfile(Profile* profile) {
  return aegis::AegisServiceFactory::GetForProfile(profile);
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
#if !BUILDFLAG(IS_ANDROID)
    active_tab_subscription_ = browser_->RegisterActiveTabDidChange(
        base::BindRepeating(&AegisAgentPageHandler::OnActiveTabDidChange,
                            weak_ptr_factory_.GetWeakPtr()));
#endif
  }
  service_ =
      profile && profile->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled)
          ? aegis::agent::AegisAgentServiceFactory::GetForProfile(profile)
          : aegis::agent::AegisAgentServiceFactory::GetForProfileIfExists(
                profile);
  ObserveService(service_);
  if (service_) {
    ObserveTask(service_->MostRecentTask());
  }
}

void AegisAgentPageHandler::ShowUI() {
#if !BUILDFLAG(IS_ANDROID)
  if (ui_ && ui_->embedder()) {
    ui_->embedder()->ShowUI();
  }
#endif
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

void AegisAgentPageHandler::ConfigureModel(const std::string& provider,
                                           const std::string& base_url,
                                           const std::string& model,
                                           const std::string& api_key,
                                           bool clear_api_key,
                                           ConfigureModelCallback callback) {
  last_error_.clear();
  aegis::AegisService* core_service = CoreServiceForProfile(profile_);
  if (!core_service) {
    last_error_ = "Model settings are unavailable for this profile";
    std::move(callback).Run(BuildSnapshot());
    return;
  }
  core_service->SetModelSettings(
      provider, base_url, model, api_key, clear_api_key,
      base::BindOnce(&AegisAgentPageHandler::OnModelConfigured,
                     weak_ptr_factory_.GetWeakPtr(), std::move(callback)));
}

void AegisAgentPageHandler::ListModels(const std::string& provider,
                                       const std::string& base_url,
                                       const std::string& api_key,
                                       ListModelsCallback callback) {
  aegis::AegisService* core_service = CoreServiceForProfile(profile_);
  if (!core_service) {
    std::move(callback).Run(
        false, "Model discovery is unavailable for this profile", {});
    return;
  }
  core_service->ListModels(
      provider, base_url, api_key,
      base::BindOnce(&AegisAgentPageHandler::OnModelsListed,
                     weak_ptr_factory_.GetWeakPtr(), std::move(callback)));
}

void AegisAgentPageHandler::CreateTask(
    const std::string& goal,
    aegis_agent::mojom::AgentMode mode,
    aegis_agent::mojom::Workflow workflow,
    const std::vector<std::string>& approved_origins,
    int32_t schedule_interval_minutes,
    CreateTaskCallback callback) {
  last_error_.clear();
  if (profile_ && profile_->GetPrefs() &&
      base::FeatureList::IsEnabled(aegis::features::kAegisAgent) &&
      !profile_->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled)) {
    // Pressing the primary start button is an explicit per-Profile opt-in.
    // Merely opening the panel still leaves the Agent disabled.
    profile_->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, true);
  }
  service_ =
      profile_ ? aegis::agent::AegisAgentServiceFactory::GetForProfile(profile_)
               : nullptr;
  ObserveService(service_);
  const std::optional<AgentMode> converted_mode = ConvertMode(mode);
  const std::optional<AgentWorkflowKind> converted_workflow =
      ConvertWorkflow(workflow);
  const std::optional<aegis::agent::AgentModelDestination> model_destination =
      service_ ? service_->ConfiguredModelDestination() : std::nullopt;
  std::optional<std::vector<url::Origin>> requested_origins;
  if (!approved_origins.empty()) {
    requested_origins = ParseApprovedOrigins(approved_origins);
  }
  const bool invalid_explicit_origins =
      !approved_origins.empty() && !requested_origins;
  std::string resolved_goal =
      converted_mode ? BindScheduleToGoal(goal, schedule_interval_minutes)
                     : goal;
  if (!service_ || !service_->IsEnabled()) {
    last_error_ = "Browser Agent is disabled";
  } else if (!converted_mode || !converted_workflow || goal.empty() ||
             resolved_goal.size() > 4096u || invalid_explicit_origins ||
             !IsValidSchedule(*converted_mode, schedule_interval_minutes)) {
    last_error_ = "Task input is invalid";
  } else if (!model_destination) {
    last_error_ = "Configure a valid Agent model provider before planning";
  } else {
    const AgentWorkflowKind resolved_workflow =
        aegis::agent::ConstrainWorkflowToUserIntent(resolved_goal,
                                                    *converted_workflow);
    const std::optional<GURL> explicit_url = ExplicitUrlFromGoal(resolved_goal);
    const bool use_current_page = !requested_origins && !explicit_url &&
                                  GoalRefersToCurrentPage(resolved_goal);
    const bool browser_only = !requested_origins && !explicit_url &&
                              !use_current_page &&
                              !WorkflowNeedsWebTarget(resolved_workflow);
    if (!requested_origins && !explicit_url && !use_current_page &&
        !browser_only) {
      service_->RouteGoal(
          resolved_goal, resolved_workflow,
          base::BindOnce(&AegisAgentPageHandler::OnGoalRouted,
                         weak_ptr_factory_.GetWeakPtr(), resolved_goal,
                         *converted_mode, std::move(requested_origins),
                         std::move(callback)));
      return;
    }
    CreateResolvedTask(std::move(resolved_goal), *converted_mode,
                       resolved_workflow, std::move(requested_origins),
                       explicit_url, browser_only, use_current_page,
                       std::move(callback));
    return;
  }
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::OnGoalRouted(
    std::string goal,
    AgentMode mode,
    std::optional<std::vector<url::Origin>> requested_origins,
    CreateTaskCallback callback,
    bool ok,
    std::string error,
    std::optional<aegis::agent::AgentGoalRoute> route) {
  if (!ok || !route) {
    last_error_ = !error.empty() ? std::move(error)
                                 : "AI could not understand the browser goal";
    std::move(callback).Run(BuildSnapshot());
    return;
  }
  *route =
      aegis::agent::ConstrainGoalRouteToUserIntent(goal, std::move(*route));
  std::optional<GURL> routed_url;
  bool browser_only = false;
  bool use_current_page = false;
  switch (route->entry_kind) {
    case aegis::agent::AgentGoalEntryKind::kBrowserOnly:
      // browser_only means no new navigation. Native browser-data workflows
      // need no page origin; all other workflows bind the public content tab
      // that was active when the user opened Agent.
      browser_only = route->workflow == AgentWorkflowKind::kBrowserSteward;
      use_current_page = !browser_only;
      break;
    case aegis::agent::AgentGoalEntryKind::kOpenUrl:
      routed_url = GURL(route->target);
      break;
    case aegis::agent::AgentGoalEntryKind::kWebSearch:
      routed_url = SearchUrlForQuery(profile_, route->target);
      break;
  }
  if (!browser_only && !use_current_page && !routed_url) {
    last_error_ = "AI selected a browser target that could not be opened";
    std::move(callback).Run(BuildSnapshot());
    return;
  }
  CreateResolvedTask(std::move(goal), mode, route->workflow,
                     std::move(requested_origins), std::move(routed_url),
                     browser_only, use_current_page,
                     std::move(callback));
}

void AegisAgentPageHandler::CreateResolvedTask(
    std::string goal,
    AgentMode mode,
    AgentWorkflowKind workflow,
    std::optional<std::vector<url::Origin>> requested_origins,
    std::optional<GURL> routed_url,
    bool browser_only,
    bool use_current_page,
    CreateTaskCallback callback) {
  const std::optional<aegis::agent::AgentModelDestination> model_destination =
      service_ ? service_->ConfiguredModelDestination() : std::nullopt;
  tabs::TabInterface* tab = ContentTab(browser_);
  GURL task_url = tab ? tab->GetURL() : GURL();
  std::optional<std::vector<url::Origin>> origins;
  if (use_current_page) {
    if (!tab || !task_url.is_valid() || !task_url.SchemeIsHTTPOrHTTPS()) {
      last_error_ = "The current public page is unavailable for this task";
      std::move(callback).Run(BuildSnapshot());
      return;
    }
    origins = AutomaticTaskOrigins(task_url);
  } else if (browser_only) {
    origins.emplace();
  } else {
    const bool use_approved_current_page =
        tab && requested_origins &&
        IncludesOrigin(*requested_origins, tab->GetURL());
    if (!use_approved_current_page) {
      std::optional<GURL> target =
          requested_origins
              ? std::make_optional(requested_origins->front().GetURL())
              : std::move(routed_url);
      tab = target ? OpenAutomaticTaskTab(browser_, *target) : nullptr;
      if (tab) {
        task_url = *target;
      }
    }
    if (requested_origins) {
      origins = std::move(requested_origins);
    } else if (tab && task_url.is_valid() && task_url.SchemeIsHTTPOrHTTPS()) {
      origins = AutomaticTaskOrigins(task_url);
    }
  }
  if (!tab || !origins || !model_destination) {
    last_error_ = "A related page could not be opened for this task";
    std::move(callback).Run(BuildSnapshot());
    return;
  }
  std::optional<aegis::agent::AgentTaskScope> scope =
      mode == AgentMode::kAutomate
          ? aegis::agent::BuildAgentAutomationScope(
                workflow, std::move(*origins), {tab->GetHandle().raw_value()},
                *model_destination)
          : aegis::agent::BuildAgentWorkflowScope(
                workflow, std::move(*origins), {tab->GetHandle().raw_value()},
                *model_destination);
  if (scope && browser_only && GoalRequestsWindowTabMetadata(goal) &&
      browser_ && browser_->GetProfile() == profile_ &&
      !profile_->IsOffTheRecord() &&
      browser_->GetType() == BrowserWindowInterface::TYPE_NORMAL &&
      !browser_->IsDeleteScheduled()) {
    scope->tab_metadata_window_id = browser_->GetSessionID().id();
  }
  AgentTask* task =
      scope ? service_->CreateTask(std::move(goal), mode, std::move(*scope))
            : nullptr;
  if (!task) {
    last_error_ = "Task scope could not be created";
  } else {
    service_->ClearPendingInvocationContext();
    active_task_id_ = task->id();
    ObserveTask(task);
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

void AegisAgentPageHandler::OnModelConfigured(ConfigureModelCallback callback,
                                              bool ok,
                                              std::string error) {
  last_error_ = ok ? std::string() : std::move(error);
  std::move(callback).Run(BuildSnapshot());
}

void AegisAgentPageHandler::OnModelsListed(ListModelsCallback callback,
                                           bool ok,
                                           std::string error,
                                           std::vector<std::string> models) {
  std::move(callback).Run(ok, std::move(error), std::move(models));
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
  aegis::AegisService* core_service = CoreServiceForProfile(profile_);
  if (core_service) {
    snapshot->model_provider = core_service->ConfiguredModelProvider();
    snapshot->model_base_url = core_service->ConfiguredModelBaseUrl();
    snapshot->model_name = core_service->ConfiguredModelName();
    PrefService* prefs = profile_->GetPrefs();
    const std::optional<aegis::ModelProvider> provider =
        aegis::ParseModelProvider(snapshot->model_provider);
    snapshot->model_configured =
        HasUserSetting(prefs, aegis::prefs::kModelProvider) &&
        HasUserSetting(prefs, aegis::prefs::kModelBaseUrl) &&
        HasUserSetting(prefs, aegis::prefs::kModelName) && provider &&
        core_service
            ->ResolveModelBaseUrl(snapshot->model_provider,
                                  snapshot->model_base_url)
            .has_value() &&
        aegis::IsValidModelName(*provider, snapshot->model_name);
  }
  tabs::TabInterface* tab = ContentTab(browser_);
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
      value->session_only = monitor.session_only;
      value->failures = monitor.consecutive_failures;
      value->last_check_status = static_cast<int>(monitor.last_check_status);
      value->last_http_status = monitor.last_http_status;
      value->change_summary =
          aegis::agent::ReadAgentMonitorSummary(monitor.last_observation);
      value->change_summary_partial =
          aegis::agent::IsPartialAgentMonitorSummary(monitor.last_observation);
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

  if (const aegis::agent::AgentCompletionSummary* completion =
          service_->GetCompletionSummary(task->id())) {
    snapshot->result_summary = completion->summary;
    snapshot->result_outcome = completion->outcome;
    snapshot->result_sources = completion->source_urls;
    snapshot->unfinished_items = completion->unfinished_items;
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
