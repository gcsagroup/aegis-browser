// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/aegis_agent_service.h"

#include <algorithm>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

#include "base/check_deref.h"
#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/uuid.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/aegis/agent/agent_model_client.h"
#include "chrome/browser/aegis/model_provider_policy.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/notifications/notification_display_service.h"
#include "chrome/browser/notifications/notification_display_service_factory.h"
#include "chrome/browser/notifications/notification_handler.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/profile_browser_collection.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/os_crypt/async/browser/os_crypt_async.h"
#include "components/os_crypt/async/common/encryptor.h"
#include "components/prefs/pref_service.h"
#include "components/tabs/public/tab_handle_factory.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/storage_partition.h"
#include "crypto/sha2.h"
#include "ui/base/models/image_model.h"
#include "ui/message_center/public/cpp/notification.h"
#include "ui/message_center/public/cpp/notifier_id.h"

namespace aegis::agent {
namespace {

constexpr base::TimeDelta kInvocationContextTtl = base::Minutes(5);
constexpr base::TimeDelta kUnfinishedTaskRetention = base::Days(7);
constexpr base::TimeDelta kCompletedTaskRetention = base::Days(30);
constexpr size_t kMaxInvocationDisplayBytes = 2048;
constexpr size_t kMaxSuggestedGoalBytes = 4096;
constexpr size_t kMaxRuntimeEvidenceItems = 24;

bool SameDocument(const AgentDocumentRef& left, const AgentDocumentRef& right) {
  return left.tab_id == right.tab_id && left.frame_token == right.frame_token &&
         left.document_token == right.document_token &&
         left.committed_url == right.committed_url;
}

bool IsReadOnlyPageTool(std::string_view tool_name) {
  return tool_name == "page.observe" || tool_name == "page.extract";
}

bool IsReadOnlyBrowserTool(std::string_view tool_name) {
  return tool_name == "tab.list" || tool_name == "window.list" ||
         tool_name == "bookmark.list" || tool_name == "bookmark.plan" ||
         tool_name == "bookmark.check_urls" || tool_name == "history.search" ||
         tool_name == "download.find_official" ||
         tool_name == "download.list" || tool_name == "download.verify" ||
         tool_name == "permissions.inspect";
}

bool TaskUsesActor(const AgentTask& task) {
  return std::ranges::any_of(
      task.scope().allowed_tools, [](const std::string& tool_name) {
        return base::StartsWith(tool_name, "page.") ||
               base::StartsWith(tool_name, "auth.") ||
               tool_name == "form.fill" || tool_name == "file.upload";
      });
}

AgentModelProvider ProtocolProvider(ModelProvider provider) {
  switch (provider) {
    case ModelProvider::kOpenAI:
      return AgentModelProvider::kOpenAICompatible;
    case ModelProvider::kAnthropic:
      return AgentModelProvider::kAnthropic;
    case ModelProvider::kGemini:
      return AgentModelProvider::kGemini;
  }
}

bool HasUserSetting(const PrefService* prefs, const char* name) {
  const PrefService::Preference* preference = prefs->FindPreference(name);
  return preference && preference->HasUserSetting();
}

std::optional<std::string> NormalizeAgentModelBaseUrl(
    ModelProvider provider,
    std::string_view candidate) {
  std::string value(base::TrimWhitespaceASCII(candidate, base::TRIM_ALL));
  const GURL parsed(value);
  if (!IsAllowedModelBaseUrl(provider, parsed)) {
    return std::nullopt;
  }
  std::string path(parsed.path());
  while (path.size() > 1 && path.ends_with('/')) {
    path.pop_back();
  }
  if (path == parsed.path()) {
    return parsed.spec();
  }
  GURL::Replacements replacements;
  replacements.SetPathStr(path);
  return parsed.ReplaceComponents(replacements).spec();
}

std::optional<AgentModelDestination> ReadExplicitAgentModelDestination(
    Profile* profile) {
  const PrefService* prefs = profile ? profile->GetPrefs() : nullptr;
  if (!prefs || !HasUserSetting(prefs, aegis::prefs::kModelProvider) ||
      !HasUserSetting(prefs, aegis::prefs::kModelBaseUrl) ||
      !HasUserSetting(prefs, aegis::prefs::kModelName)) {
    return std::nullopt;
  }
  const std::optional<ModelProvider> provider =
      ParseModelProvider(prefs->GetString(aegis::prefs::kModelProvider));
  if (!provider) {
    return std::nullopt;
  }
  const std::optional<std::string> endpoint = NormalizeAgentModelBaseUrl(
      *provider, prefs->GetString(aegis::prefs::kModelBaseUrl));
  const std::string model = prefs->GetString(aegis::prefs::kModelName);
  if (!endpoint || !IsValidModelName(*provider, model)) {
    return std::nullopt;
  }
  return AgentModelDestination{
      .kind = IsLocalModelEndpoint(*provider, GURL(*endpoint))
                  ? AgentModelDestination::Kind::kLoopback
                  : AgentModelDestination::Kind::kCloud,
      .provider = std::string(ModelProviderId(*provider)),
      .endpoint = *endpoint,
      .model = model};
}

std::string ModelCapabilityKey(const AgentModelDestination& destination) {
  return destination.provider + "\n" + destination.endpoint + "\n" +
         destination.model;
}

std::optional<AgentModelClientConfig> ResolveModelConfig(
    Profile* profile,
    const AgentModelDestination& destination,
    std::string* error) {
  if (!error) {
    return std::nullopt;
  }
  error->clear();
  const std::optional<AgentModelDestination> configured =
      ReadExplicitAgentModelDestination(profile);
  if (!configured || *configured != destination) {
    *error = "Agent model destination is not explicitly configured";
    return std::nullopt;
  }
  const std::optional<ModelProvider> provider =
      ParseModelProvider(destination.provider);
  if (!profile || !provider ||
      destination.kind == AgentModelDestination::Kind::kOnDevice) {
    *error = "configured Agent model transport is unavailable";
    return std::nullopt;
  }
  const GURL base_url(destination.endpoint);
  const bool local = IsLocalModelEndpoint(*provider, base_url);
  if (!IsAllowedModelBaseUrl(*provider, base_url) ||
      (destination.kind == AgentModelDestination::Kind::kLoopback && !local) ||
      (destination.kind == AgentModelDestination::Kind::kCloud && local)) {
    *error = "configured Agent model destination does not match its scope";
    return std::nullopt;
  }
  std::string api_key;
  AegisService* settings = AegisService::GetInstance();
  if (settings) {
    std::optional<std::string> stored_key =
        settings->ModelApiKeyForBrowserAgent(profile, destination.provider,
                                             destination.endpoint);
    if (stored_key) {
      api_key = std::move(*stored_key);
    }
  }
  return AgentModelClientConfig{.provider = *provider,
                                .base_url = destination.endpoint,
                                .api_key = std::move(api_key)};
}

AgentToolCall CloneToolCall(const AgentToolCall& source) {
  return {.schema_version = source.schema_version,
          .action_id = source.action_id,
          .tool_name = source.tool_name,
          .arguments = source.arguments.Clone(),
          .committed_url = source.committed_url,
          .document = source.document};
}

AgentToolResult CloneToolResult(const AgentToolResult& source) {
  return {.schema_version = source.schema_version,
          .action_id = source.action_id,
          .ok = source.ok,
          .error = source.error,
          .message = source.message,
          .value = source.value.Clone(),
          .evidence = source.evidence.Clone()};
}

AgentToolResult MonitorError(std::string action_id,
                             AgentErrorCode error,
                             std::string message) {
  return {.action_id = std::move(action_id),
          .ok = false,
          .error = error,
          .message = std::move(message)};
}

std::optional<AgentMonitorKind> ParseMonitorKind(std::string_view value) {
  if (value == "price") {
    return AgentMonitorKind::kPrice;
  }
  if (value == "inventory") {
    return AgentMonitorKind::kInventory;
  }
  if (value == "page_change") {
    return AgentMonitorKind::kPageChange;
  }
  if (value == "url_status") {
    return AgentMonitorKind::kUrlStatus;
  }
  return std::nullopt;
}

std::string_view MonitorKindName(AgentMonitorKind kind) {
  switch (kind) {
    case AgentMonitorKind::kPrice:
      return "price";
    case AgentMonitorKind::kInventory:
      return "inventory";
    case AgentMonitorKind::kPageChange:
      return "page_change";
    case AgentMonitorKind::kUrlStatus:
      return "url_status";
  }
}

std::string Sha256(std::string_view value) {
  return "sha256:" + base::HexEncode(crypto::SHA256HashString(value));
}

GURL MonitorTargetUrl(const GURL& committed_url) {
  if (!committed_url.is_valid() || !committed_url.SchemeIsHTTPOrHTTPS() ||
      !committed_url.username().empty() || !committed_url.password().empty() ||
      committed_url.spec().size() > 8192u) {
    return {};
  }
  GURL::Replacements replacements;
  replacements.ClearRef();
  return committed_url.ReplaceComponents(replacements);
}

base::DictValue PublicMonitorValue(const AgentMonitorDefinition& monitor) {
  base::DictValue value;
  value.Set("monitor_id", monitor.monitor_id);
  value.Set("kind", MonitorKindName(monitor.kind));
  value.Set("origin", monitor.origin.Serialize());
  value.Set("target_hash", monitor.target_hash);
  value.Set("interval_minutes", static_cast<int>(monitor.interval.InMinutes()));
  value.Set("enabled", monitor.enabled);
  value.Set("next_run_us",
            base::NumberToString(
                monitor.next_run.ToDeltaSinceWindowsEpoch().InMicroseconds()));
  value.Set("consecutive_failures", monitor.consecutive_failures);
  return value;
}

std::string MonitorRevision(
    const std::vector<AgentMonitorDefinition>& monitors) {
  base::ListValue values;
  for (const AgentMonitorDefinition& monitor : monitors) {
    values.Append(PublicMonitorValue(monitor));
  }
  std::string serialized;
  if (!base::JSONWriter::Write(values, &serialized)) {
    return "sha256:unavailable";
  }
  return Sha256(serialized);
}

std::optional<std::string> CanonicalMonitorObservation(
    AgentMonitorKind kind,
    const AgentToolResult& result) {
  if (!result.ok) {
    return std::nullopt;
  }
  if (kind == AgentMonitorKind::kUrlStatus) {
    return std::string("reachable");
  }
  const base::ListValue* nodes = result.value.FindList("nodes");
  if (!nodes) {
    return std::nullopt;
  }
  base::ListValue canonical;
  for (const base::Value& node : *nodes) {
    if (!node.is_dict()) {
      continue;
    }
    const base::DictValue& source = node.GetDict();
    const std::string* text_value = source.FindString("text");
    const std::string* label_value = source.FindString("label");
    const std::string text = text_value ? *text_value : std::string();
    const std::string label = label_value ? *label_value : std::string();
    const std::string lowered = base::ToLowerASCII(label + " " + text);
    if (kind == AgentMonitorKind::kPrice && !lowered.contains("price") &&
        !lowered.contains("total") && !lowered.contains("$") &&
        !lowered.contains("€") && !lowered.contains("£") &&
        !lowered.contains("¥")) {
      continue;
    }
    if (kind == AgentMonitorKind::kInventory && !lowered.contains("stock") &&
        !lowered.contains("available") && !lowered.contains("sold out") &&
        !lowered.contains("库存") && !lowered.contains("有货") &&
        !lowered.contains("缺货")) {
      continue;
    }
    base::DictValue item;
    item.Set("kind", source.FindInt("kind").value_or(0));
    item.Set("text", text);
    item.Set("label", label);
    canonical.Append(std::move(item));
  }
  if (canonical.empty()) {
    return std::nullopt;
  }
  std::string serialized;
  return base::JSONWriter::Write(canonical, &serialized)
             ? std::make_optional(std::move(serialized))
             : std::nullopt;
}

}  // namespace

struct AegisAgentService::ExecutionRuntime {
  size_t next_step = 0;
  int attempt = 0;
  int model_failures = 0;
  int refresh_count = 0;
  bool final_user_takeover = false;
  bool needs_fresh_observation = false;
  std::optional<int32_t> last_tab_id;
  std::optional<AgentToolResult> previous_result;
  std::vector<AgentExecutionEvidence> evidence_history;
  std::optional<AgentToolCall> pending_action;
  RunCallback callback;
};

AegisAgentService::AegisAgentService(Profile* profile)
    : profile_(profile),
      task_store_(
          CHECK_DEREF(profile).GetPath().AppendASCII("AegisAgentTasks.sqlite")),
      policy_broker_(&tool_registry_),
      actor_bridge_(profile),
      browser_tools_(profile) {
  actor_bridge_.SetStateEventCallback(base::BindRepeating(
      &AegisAgentService::OnActorStateEvent, weak_ptr_factory_.GetWeakPtr()));
  storage_ready_ = task_store_.Initialize();
  if (storage_ready_) {
    const base::Time now = base::Time::Now();
    storage_ready_ = task_store_.Prune(now - kUnfinishedTaskRetention,
                                       now - kCompletedTaskRetention);
  }
  if (storage_ready_) {
    RestoreUnfinishedTasks();
    RestoreMonitors();
    RestoreMonitorTargets();
  }
}

AegisAgentService::~AegisAgentService() = default;

bool AegisAgentService::IsEnabled() const {
  return !shutting_down_ && profile_ && storage_ready_ &&
         base::FeatureList::IsEnabled(aegis::features::kAegisAgent) &&
         profile_->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled);
}

std::optional<AgentModelDestination>
AegisAgentService::ConfiguredModelDestination() const {
  return ReadExplicitAgentModelDestination(profile_);
}

bool AegisAgentService::IsToolAvailable(std::string_view tool_name) const {
  if (!IsEnabled() || !tool_registry_.Find(tool_name)) {
    return false;
  }
  if (tool_name == "page.webmcp.list") {
    return base::FeatureList::IsEnabled(aegis::features::kAegisAgentWebMcp);
  }
  if (tool_name == "page.webmcp.invoke") {
    return base::FeatureList::IsEnabled(aegis::features::kAegisAgentWebMcp) &&
           base::FeatureList::IsEnabled(
               aegis::features::kAegisAgentPageActions);
  }
  if (base::StartsWith(tool_name, "page.") ||
      base::StartsWith(tool_name, "auth.") || tool_name == "form.fill" ||
      tool_name == "file.upload") {
    return IsReadOnlyPageTool(tool_name) ||
           base::FeatureList::IsEnabled(
               aegis::features::kAegisAgentPageActions);
  }
  if (browser_tools_.CanHandle(tool_name)) {
    return IsReadOnlyBrowserTool(tool_name) ||
           base::FeatureList::IsEnabled(
               aegis::features::kAegisAgentBrowserTools);
  }
  if (base::StartsWith(tool_name, "monitor.")) {
    return base::FeatureList::IsEnabled(aegis::features::kAegisAgentWorkflows);
  }
  if (tool_name == "shopping.prepare_checkout") {
    return base::FeatureList::IsEnabled(aegis::features::kAegisAgentWorkflows);
  }
  return false;
}

AgentTask* AegisAgentService::CreateTask(std::string goal,
                                         AgentMode mode,
                                         AgentTaskScope scope) {
  if (!IsEnabled() || goal.empty() || goal.size() > 4096u || !scope.IsValid()) {
    return nullptr;
  }
  const std::string task_id = AgentTask::GenerateTaskId();
  auto task = std::make_unique<AgentTask>(task_id, std::move(goal), mode,
                                          std::move(scope));
  AgentTask* result = task.get();
  tasks_.emplace(task_id, std::move(task));
  task_has_external_side_effect_[task_id] = false;
  if (!PersistTask(*result)) {
    task_has_external_side_effect_.erase(task_id);
    tasks_.erase(task_id);
    return nullptr;
  }
  NotifyServiceSnapshotChanged();
  return result;
}

AgentTask* AegisAgentService::GetTask(const std::string& task_id) {
  auto it = tasks_.find(task_id);
  return it == tasks_.end() ? nullptr : it->second.get();
}

const AgentTask* AegisAgentService::GetTask(const std::string& task_id) const {
  auto it = tasks_.find(task_id);
  return it == tasks_.end() ? nullptr : it->second.get();
}

AgentTask* AegisAgentService::MostRecentTask() {
  return const_cast<AgentTask*>(std::as_const(*this).MostRecentTask());
}

const AgentTask* AegisAgentService::MostRecentTask() const {
  const AgentTask* latest = nullptr;
  for (const auto& [task_id, task] : tasks_) {
    if (!latest || task->created_at() > latest->created_at()) {
      latest = task.get();
    }
  }
  return latest;
}

bool AegisAgentService::SetPendingInvocationContext(
    AgentInvocationContext context) {
  if (!IsEnabled() || context.tab_id <= 0 || context.kind.empty() ||
      context.kind.size() > 32u || context.display.empty() ||
      context.display.size() > kMaxInvocationDisplayBytes ||
      context.suggested_goal.empty() ||
      context.suggested_goal.size() > kMaxSuggestedGoalBytes) {
    return false;
  }
  context.created = base::TimeTicks::Now();
  pending_invocation_context_ = std::move(context);
  NotifyServiceSnapshotChanged();
  return true;
}

const AgentInvocationContext* AegisAgentService::PendingInvocationContext()
    const {
  if (!pending_invocation_context_ ||
      base::TimeTicks::Now() - pending_invocation_context_->created >
          kInvocationContextTtl) {
    return nullptr;
  }
  return &*pending_invocation_context_;
}

void AegisAgentService::ClearPendingInvocationContext() {
  if (!pending_invocation_context_) {
    return;
  }
  pending_invocation_context_.reset();
  NotifyServiceSnapshotChanged();
}

void AegisAgentService::AddObserver(AegisAgentServiceObserver* observer) {
  observers_.AddObserver(observer);
}

void AegisAgentService::RemoveObserver(AegisAgentServiceObserver* observer) {
  observers_.RemoveObserver(observer);
}

void AegisAgentService::NotifyServiceSnapshotChanged() {
  for (AegisAgentServiceObserver& observer : observers_) {
    observer.OnAgentServiceSnapshotChanged();
  }
}

bool AegisAgentService::BeginPlanning(const std::string& task_id) {
  return Transition(task_id, AgentTaskState::kPlanning, "planning started");
}

bool AegisAgentService::AcceptModelPlan(const std::string& task_id,
                                        const AgentModelEvent& event,
                                        std::string* error) {
  if (!error) {
    return false;
  }
  error->clear();
  AgentTask* task = GetTask(task_id);
  if (!task || task->state() != AgentTaskState::kPlanning) {
    *error = "task is not accepting a plan";
    return false;
  }
  std::optional<AgentTaskPlan> plan =
      ParseAndValidateTaskPlan(event, task->scope(), tool_registry_, error);
  if (!plan) {
    return false;
  }
  for (const AgentPlanStep& step : plan->steps) {
    if (!IsToolAvailable(step.tool_name) ||
        (task->mode() == AgentMode::kAsk &&
         step.risk != AgentRiskLevel::kR0ReadOnly)) {
      *error = "task plan requests a disabled capability";
      return false;
    }
  }
  if (!task->AdoptPlanScope(plan->scope)) {
    *error = "task plan could not narrow the approved scope";
    return false;
  }
  plans_.insert_or_assign(task_id, std::move(*plan));
  plan_progress_[task_id] = {0u, 0};
  if (!task_store_.SavePlan(task_id, plans_.at(task_id), /*next_step=*/0,
                            /*attempt=*/0)) {
    plans_.erase(task_id);
    plan_progress_.erase(task_id);
    *error = "validated task plan could not be stored";
    return false;
  }
  if (!SetPlanReady(task_id)) {
    *error = "validated task plan could not be persisted";
    return false;
  }
  return true;
}

void AegisAgentService::RequestPlan(const std::string& task_id,
                                    PlanReadyCallback callback) {
  AgentTask* task = GetTask(task_id);
  if (!task || (task->state() != AgentTaskState::kDraft &&
                task->state() != AgentTaskState::kPlanning)) {
    std::move(callback).Run(false, "task is not ready for planning");
    return;
  }
  if (task->state() == AgentTaskState::kDraft && !BeginPlanning(task_id)) {
    std::move(callback).Run(false, "task could not enter planning");
    return;
  }
  const std::string capability_key =
      ModelCapabilityKey(task->scope().model_destination);
  AgentModelCapabilityTracker& capability = model_capabilities_[capability_key];
  if (task->mode() != AgentMode::kAsk &&
      capability.consecutive_schema_failures() >= 2) {
    std::move(callback).Run(
        false, "configured model is limited to Ask mode after schema failures");
    return;
  }
  std::optional<std::string> prompt =
      BuildAgentPlanningPrompt(task->goal(), task->scope());
  std::string config_error;
  std::optional<AgentModelClientConfig> config = ResolveModelConfig(
      profile_, task->scope().model_destination, &config_error);
  if (!prompt || !config) {
    std::move(callback).Run(
        false, !config_error.empty() ? std::move(config_error)
                                     : "planning budget or prompt is invalid");
    return;
  }

  auto client_it = model_clients_.find(task_id);
  if (client_it == model_clients_.end()) {
    auto client = std::make_unique<AgentModelClient>(
        profile_->GetDefaultStoragePartition()
            ->GetURLLoaderFactoryForBrowserProcess());
    client_it = model_clients_.emplace(task_id, std::move(client)).first;
  }
  if (client_it->second->busy()) {
    std::move(callback).Run(false, "task already has a model request");
    return;
  }
  const std::optional<ModelProvider> provider =
      ParseModelProvider(task->scope().model_destination.provider);
  if (!provider) {
    std::move(callback).Run(false, "unsupported model provider");
    return;
  }
  if (!ConsumeModelRequestBudget(task)) {
    std::move(callback).Run(false, "planning model budget is exhausted");
    return;
  }
  AgentModelRequest request;
  request.provider = ProtocolProvider(*provider);
  request.model = task->scope().model_destination.model;
  request.system_prompt = BuildAgentPlannerSystemContract();
  request.user_prompt = std::move(*prompt);
  request.tools.push_back(BuildSubmitPlanToolDefinition());
  request.max_output_tokens = 4096;
  request.stream = false;
  std::optional<AgentModelClient::RequestId> request_id =
      client_it->second->Start(
          std::move(*config), std::move(request),
          base::BindOnce(&AegisAgentService::OnPlanModelResult,
                         weak_ptr_factory_.GetWeakPtr(), task_id,
                         std::move(callback)));
  if (request_id && client_it->second->busy()) {
    model_request_ids_[task_id] = std::move(*request_id);
  }
}

void AegisAgentService::OnPlanModelResult(const std::string& task_id,
                                          PlanReadyCallback callback,
                                          bool ok,
                                          std::string error,
                                          AgentModelParseResult result) {
  model_request_ids_.erase(task_id);
  AgentTask* task = GetTask(task_id);
  if (!task || task->state() != AgentTaskState::kPlanning) {
    std::move(callback).Run(false, "planning task is no longer active");
    return;
  }
  if (!ok) {
    std::move(callback).Run(false, std::move(error));
    return;
  }
  std::string validation_error;
  std::optional<AgentModelEvent> event =
      SelectExecutionToolCall(result, "agent.submit_plan", &validation_error);
  AgentModelCapabilityTracker& capability =
      model_capabilities_[ModelCapabilityKey(task->scope().model_destination)];
  if (!event || !AcceptModelPlan(task_id, *event, &validation_error)) {
    capability.RecordSchemaFailure();
    if (capability.consecutive_schema_failures() >= 2 &&
        task->mode() != AgentMode::kAsk) {
      validation_error =
          "configured model failed the structured-tool contract twice; "
          "only Ask mode is allowed";
    }
    std::move(callback).Run(false, std::move(validation_error));
    return;
  }
  capability.RecordToolProbeSuccess();
  capability.RecordSchemaSuccess();
  std::move(callback).Run(true, std::string());
}

bool AegisAgentService::SetPlanReady(const std::string& task_id) {
  if (!plans_.contains(task_id)) {
    return false;
  }
  return Transition(task_id, AgentTaskState::kAwaitingTaskConsent,
                    "plan validated");
}

const AgentTaskPlan* AegisAgentService::GetPlan(
    const std::string& task_id) const {
  auto it = plans_.find(task_id);
  return it == plans_.end() ? nullptr : &it->second;
}

bool AegisAgentService::GrantTaskConsent(const std::string& task_id) {
  AgentTask* task = GetTask(task_id);
  if (!task || task->state() != AgentTaskState::kAwaitingTaskConsent) {
    return false;
  }
  if (TaskUsesActor(*task) &&
      !actor_bridge_.StartTask(task_id, task->scope())) {
    Transition(task_id, AgentTaskState::kFailed,
               "Actor execution service unavailable");
    return false;
  }
  return Transition(task_id, AgentTaskState::kRunning, "task consent granted");
}

bool AegisAgentService::PauseTask(const std::string& task_id) {
  AgentTask* task = GetTask(task_id);
  if (!task || task->state() != AgentTaskState::kRunning) {
    return false;
  }
  if (TaskUsesActor(*task) &&
      !actor_bridge_.PauseTask(task_id, /*by_user=*/true)) {
    return false;
  }
  auto request = model_request_ids_.find(task_id);
  auto client = model_clients_.find(task_id);
  if (request != model_request_ids_.end() && client != model_clients_.end()) {
    client->second->Cancel(request->second);
    model_request_ids_.erase(request);
  }
  if (auto runtime = executions_.find(task_id); runtime != executions_.end()) {
    runtime->second->needs_fresh_observation = TaskUsesActor(*task);
  }
  if (task->state() == AgentTaskState::kPausedByUser) {
    return true;
  }
  return Transition(task_id, AgentTaskState::kPausedByUser, "paused by user");
}

bool AegisAgentService::ResumeTask(const std::string& task_id) {
  AgentTask* task = GetTask(task_id);
  if (!task || task->state() != AgentTaskState::kPausedByUser) {
    return false;
  }
  if (TaskUsesActor(*task) && !actor_bridge_.ResumeTask(task_id)) {
    return false;
  }
  const bool resumed = Transition(task_id, AgentTaskState::kRunning,
                                  "resumed after fresh observation");
  if (resumed && executions_.contains(task_id)) {
    EnsureFreshObservationThenContinue(task_id, /*force_refresh=*/true);
  }
  return resumed;
}

bool AegisAgentService::BeginUserTakeover(const std::string& task_id) {
  AgentTask* task = GetTask(task_id);
  if (!task || (task->state() != AgentTaskState::kRunning &&
                task->state() != AgentTaskState::kAwaitingActionApproval)) {
    return false;
  }
  if (TaskUsesActor(*task)) {
    actor_bridge_.PauseTask(task_id, /*by_user=*/true);
  }
  auto request = model_request_ids_.find(task_id);
  auto client = model_clients_.find(task_id);
  if (request != model_request_ids_.end() && client != model_clients_.end()) {
    client->second->Cancel(request->second);
    model_request_ids_.erase(request);
  }
  policy_broker_.RevokeTaskApprovals(task_id);
  return Transition(task_id, AgentTaskState::kUserTakeover,
                    "user takeover required");
}

bool AegisAgentService::FinishUserTakeover(const std::string& task_id) {
  AgentTask* task = GetTask(task_id);
  if (!task || task->state() != AgentTaskState::kUserTakeover) {
    return false;
  }
  auto runtime = executions_.find(task_id);
  if (runtime != executions_.end() && runtime->second->final_user_takeover) {
    return false;
  }
  if (TaskUsesActor(*task)) {
    actor_bridge_.StopTask(task_id, /*completed=*/false);
  }
  policy_broker_.RevokeTaskApprovals(task_id);
  browser_tools_.ForgetTask(task_id);
  bookmark_undo_tokens_.erase(task_id);
  action_results_.erase(task_id);
  action_tools_.erase(task_id);
  action_hashes_.erase(task_id);
  recovery_dispositions_[task_id] =
      task_has_external_side_effect_[task_id]
          ? StoredAgentTask::RecoveryDisposition::kRequireActionApproval
          : StoredAgentTask::RecoveryDisposition::kRequireFreshConsent;
  const bool recovering =
      Transition(task_id, AgentTaskState::kRecovering,
                 "user takeover ended; fresh consent required");
  if (recovering && executions_.contains(task_id)) {
    FinishRuntime(task_id, false,
                  "execution invalidated by an intermediate user takeover",
                  std::nullopt);
  }
  return recovering;
}

bool AegisAgentService::GrantRecoveryConsent(const std::string& task_id) {
  AgentTask* task = GetTask(task_id);
  if (!task || task->state() != AgentTaskState::kRecovering) {
    return false;
  }
  if (task->HasExpired(base::Time::Now())) {
    recovery_dispositions_.erase(task_id);
    return Transition(task_id, AgentTaskState::kExpired,
                      "recovered task expired before consent");
  }
  policy_broker_.RevokeTaskApprovals(task_id);
  action_results_.erase(task_id);
  action_tools_.erase(task_id);
  action_hashes_.erase(task_id);
  browser_tools_.ForgetTask(task_id);
  bookmark_undo_tokens_.erase(task_id);
  if (TaskUsesActor(*task) &&
      !actor_bridge_.StartTask(task_id, task->scope())) {
    return Transition(task_id, AgentTaskState::kFailed,
                      "Actor execution service unavailable after recovery");
  }
  recovery_dispositions_.erase(task_id);
  return Transition(task_id, AgentTaskState::kRunning,
                    "fresh recovery consent granted; observation required");
}

bool AegisAgentService::CancelTask(const std::string& task_id) {
  AgentTask* task = GetTask(task_id);
  if (!task || IsTerminalState(task->state())) {
    return false;
  }
  auto request = model_request_ids_.find(task_id);
  auto client = model_clients_.find(task_id);
  if (request != model_request_ids_.end() && client != model_clients_.end()) {
    client->second->Cancel(request->second);
    model_request_ids_.erase(request);
  }
  if (TaskUsesActor(*task)) {
    actor_bridge_.StopTask(task_id, /*completed=*/false);
  }
  policy_broker_.RevokeTaskApprovals(task_id);
  browser_tools_.ForgetTask(task_id, /*preserve_bookmark_undo=*/false,
                            /*cancel_active_downloads=*/true);
  bookmark_undo_tokens_.erase(task_id);
  for (const AgentMonitorDefinition& monitor : GetMonitors(task_id)) {
    task_store_.DeleteMonitor(monitor.monitor_id);
    monitor_scheduler_.Remove(monitor.monitor_id);
  }
  ScheduleMonitorTimer();
  const bool cancelled =
      Transition(task_id, AgentTaskState::kCancelled, "cancelled by user");
  if (cancelled && executions_.contains(task_id)) {
    FinishRuntime(task_id, false, "task cancelled by user", std::nullopt);
  }
  return cancelled;
}

void AegisAgentService::CancelAllForDisable() {
  monitor_timer_.Stop();
  pending_invocation_context_.reset();
  std::vector<std::string> active_task_ids;
  active_task_ids.reserve(tasks_.size());
  for (const auto& [task_id, task] : tasks_) {
    if (!IsTerminalState(task->state())) {
      active_task_ids.push_back(task_id);
    }
  }
  for (const std::string& task_id : active_task_ids) {
    CancelTask(task_id);
  }
}

void AegisAgentService::ResumeMonitorsAfterEnable() {
  if (IsEnabled()) {
    ScheduleMonitorTimer();
  }
}

bool AegisAgentService::CompleteTask(const std::string& task_id) {
  AgentTask* task = GetTask(task_id);
  if (!task || task->state() != AgentTaskState::kVerifying) {
    return false;
  }
  if (TaskUsesActor(*task)) {
    actor_bridge_.StopTask(task_id, /*completed=*/true);
  }
  policy_broker_.RevokeTaskApprovals(task_id);
  browser_tools_.ForgetTask(task_id, /*preserve_bookmark_undo=*/true);
  return Transition(task_id, AgentTaskState::kCompleted,
                    "browser verification passed");
}

void AegisAgentService::RunTask(const std::string& task_id,
                                RunCallback callback) {
  AgentTask* task = GetTask(task_id);
  const AgentTaskPlan* plan = GetPlan(task_id);
  if (!task || !plan || task->state() != AgentTaskState::kRunning ||
      executions_.contains(task_id)) {
    std::move(callback).Run(false, "task is not ready to execute",
                            std::nullopt);
    return;
  }
  auto runtime = std::make_unique<ExecutionRuntime>();
  if (auto progress = plan_progress_.find(task_id);
      progress != plan_progress_.end()) {
    runtime->next_step = progress->second.first;
    runtime->attempt = progress->second.second;
  }
  runtime->callback = std::move(callback);
  executions_[task_id] = std::move(runtime);
  EnsureFreshObservationThenContinue(task_id, /*force_refresh=*/false);
}

const AgentToolCall* AegisAgentService::PendingAction(
    const std::string& task_id) const {
  auto it = executions_.find(task_id);
  return it == executions_.end() || !it->second->pending_action
             ? nullptr
             : &*it->second->pending_action;
}

bool AegisAgentService::ApprovePendingAction(const std::string& task_id) {
  auto runtime_it = executions_.find(task_id);
  if (runtime_it == executions_.end() || !runtime_it->second->pending_action ||
      runtime_it->second->final_user_takeover) {
    return false;
  }
  AgentToolCall call = std::move(*runtime_it->second->pending_action);
  runtime_it->second->pending_action.reset();
  std::optional<AgentApprovalReceipt> approval = ApproveToolCall(task_id, call);
  if (!approval) {
    runtime_it->second->pending_action = std::move(call);
    return false;
  }
  ExecuteRuntimeTool(task_id, std::move(call), approval->approval_id);
  return true;
}

bool AegisAgentService::CompleteFinalUserTakeover(
    const std::string& task_id,
    bool user_confirmed_completion) {
  auto runtime_it = executions_.find(task_id);
  AgentTask* task = GetTask(task_id);
  if (!task || task->state() != AgentTaskState::kUserTakeover ||
      runtime_it == executions_.end() ||
      !runtime_it->second->final_user_takeover) {
    return false;
  }
  if (!user_confirmed_completion) {
    const bool cancelled = CancelTask(task_id);
    if (cancelled && executions_.contains(task_id)) {
      FinishRuntime(task_id, false, "final action was cancelled by the user",
                    std::nullopt);
    }
    return cancelled;
  }
  if (TaskUsesActor(*task)) {
    actor_bridge_.StopTask(task_id, /*completed=*/true);
  }
  policy_broker_.RevokeTaskApprovals(task_id);
  browser_tools_.ForgetTask(task_id, /*preserve_bookmark_undo=*/true);
  if (!Transition(task_id, AgentTaskState::kCompleted,
                  "final action completed under user control")) {
    return false;
  }
  AgentCompletionSummary completion{
      .outcome = "completed",
      .summary = "自动化步骤已完成；最终操作由用户接管并确认。"};
  FinishRuntime(task_id, true, std::string(), std::move(completion));
  return true;
}

void AegisAgentService::RequestNextModelTurn(const std::string& task_id) {
  auto runtime_it = executions_.find(task_id);
  AgentTask* task = GetTask(task_id);
  const AgentTaskPlan* plan = GetPlan(task_id);
  if (!task || !plan || runtime_it == executions_.end() ||
      (task->state() != AgentTaskState::kRunning &&
       task->state() != AgentTaskState::kReflecting)) {
    if (runtime_it != executions_.end() &&
        (!task || IsTerminalState(task->state()))) {
      FinishRuntime(task_id, false, "task stopped before the next model turn",
                    std::nullopt);
    }
    return;
  }
  ExecutionRuntime& runtime = *runtime_it->second;
  if (runtime.pending_action || runtime.final_user_takeover) {
    return;
  }
  const std::string expected_tool =
      runtime.next_step < plan->steps.size()
          ? plan->steps[runtime.next_step].tool_name
          : std::string("agent.complete");
  std::optional<AgentModelToolDefinition> tool;
  if (expected_tool == "agent.complete") {
    tool = BuildCompleteTaskToolDefinition();
  } else if (IsToolAvailable(expected_tool)) {
    tool = tool_registry_.ModelToolForName(expected_tool);
  }
  std::string config_error;
  std::optional<AgentModelClientConfig> config = ResolveModelConfig(
      profile_, task->scope().model_destination, &config_error);
  if (!tool || !config) {
    Transition(task_id, AgentTaskState::kFailed,
               "execution model request could not be started");
    FinishRuntime(task_id, false,
                  !config_error.empty()
                      ? std::move(config_error)
                      : "execution model budget or tool is unavailable",
                  std::nullopt);
    return;
  }
  auto client_it = model_clients_.find(task_id);
  if (client_it == model_clients_.end()) {
    auto client = std::make_unique<AgentModelClient>(
        profile_->GetDefaultStoragePartition()
            ->GetURLLoaderFactoryForBrowserProcess());
    client_it = model_clients_.emplace(task_id, std::move(client)).first;
  }
  if (client_it->second->busy()) {
    Transition(task_id, AgentTaskState::kFailed,
               "overlapping model request rejected");
    FinishRuntime(task_id, false, "task model transport is already busy",
                  std::nullopt);
    return;
  }
  const std::optional<ModelProvider> provider =
      ParseModelProvider(task->scope().model_destination.provider);
  if (!provider) {
    Transition(task_id, AgentTaskState::kFailed,
               "unsupported execution model provider");
    FinishRuntime(task_id, false, "unsupported execution model provider",
                  std::nullopt);
    return;
  }
  if (!ConsumeModelRequestBudget(task)) {
    Transition(task_id, AgentTaskState::kFailed,
               "execution model budget exhausted");
    FinishRuntime(task_id, false, "execution model budget is exhausted",
                  std::nullopt);
    return;
  }
  AgentModelRequest request;
  request.provider = ProtocolProvider(*provider);
  request.model = task->scope().model_destination.model;
  request.system_prompt = BuildAgentExecutionSystemContract();
  request.user_prompt = BuildAgentExecutionPrompt(
      *task, *plan, runtime.next_step, runtime.attempt,
      runtime.previous_result ? &*runtime.previous_result : nullptr,
      runtime.evidence_history);
  request.tools.push_back(std::move(*tool));
  request.max_output_tokens = 4096;
  request.stream = false;
  std::optional<AgentModelClient::RequestId> request_id =
      client_it->second->Start(
          std::move(*config), std::move(request),
          base::BindOnce(&AegisAgentService::OnExecutionModelResult,
                         weak_ptr_factory_.GetWeakPtr(), task_id,
                         expected_tool));
  if (request_id && client_it->second->busy()) {
    model_request_ids_[task_id] = std::move(*request_id);
  }
}

void AegisAgentService::EnsureFreshObservationThenContinue(
    const std::string& task_id,
    bool force_refresh) {
  auto runtime_it = executions_.find(task_id);
  AgentTask* task = GetTask(task_id);
  const AgentTaskPlan* plan = GetPlan(task_id);
  if (!task || !plan || runtime_it == executions_.end() ||
      task->state() != AgentTaskState::kRunning) {
    return;
  }
  ExecutionRuntime& runtime = *runtime_it->second;
  if (runtime.pending_action || runtime.final_user_takeover) {
    return;
  }
  const AgentToolDescriptor* next_descriptor =
      runtime.next_step < plan->steps.size()
          ? tool_registry_.Find(plan->steps[runtime.next_step].tool_name)
          : nullptr;
  const bool document_needed =
      next_descriptor && next_descriptor->requires_document;
  if (!TaskUsesActor(*task) ||
      (!force_refresh && !runtime.needs_fresh_observation &&
       !document_needed)) {
    RequestNextModelTurn(task_id);
    return;
  }

  const std::optional<int32_t> tab_id =
      SelectRuntimeObservationTab(*task, runtime);
  if (!tab_id) {
    if (!document_needed && !runtime.last_tab_id) {
      RequestNextModelTurn(task_id);
      return;
    }
    Transition(task_id, AgentTaskState::kFailed,
               "no live scoped tab was available for a fresh observation");
    FinishRuntime(task_id, false,
                  "execution stopped because browser context changed",
                  std::nullopt);
    return;
  }
  tabs::TabInterface* tab = tabs::TabHandle(*tab_id).Get();
  if (!tab) {
    Transition(task_id, AgentTaskState::kFailed,
               "fresh observation tab disappeared");
    FinishRuntime(task_id, false, "fresh browser observation failed",
                  std::nullopt);
    return;
  }
  runtime.last_tab_id = *tab_id;
  runtime.needs_fresh_observation = true;
  AgentToolCall observe;
  observe.action_id =
      task_id + ":refresh:" + std::to_string(++runtime.refresh_count);
  observe.tool_name = "page.observe";
  observe.arguments.Set("tab_id", *tab_id);
  observe.arguments.Set("query", "refresh task context after user control");
  observe.committed_url = tab->GetURL();
  ExecuteTool(task_id, observe,
              base::BindOnce(&AegisAgentService::OnRuntimeFreshObservation,
                             weak_ptr_factory_.GetWeakPtr(), task_id));
}

void AegisAgentService::OnRuntimeFreshObservation(const std::string& task_id,
                                                  AgentToolResult result) {
  auto runtime_it = executions_.find(task_id);
  AgentTask* task = GetTask(task_id);
  if (!task || runtime_it == executions_.end()) {
    return;
  }
  ExecutionRuntime& runtime = *runtime_it->second;
  if (task->state() == AgentTaskState::kPausedByUser) {
    runtime.needs_fresh_observation = true;
    return;
  }
  if (task->state() != AgentTaskState::kRunning || !result.ok) {
    if (task->state() == AgentTaskState::kRunning) {
      Transition(task_id, AgentTaskState::kFailed,
                 "fresh browser observation was rejected");
      FinishRuntime(task_id, false, result.message, std::nullopt);
    }
    return;
  }
  runtime.needs_fresh_observation = false;
  if (const std::optional<int> tab_id = result.value.FindInt("tab_id")) {
    runtime.last_tab_id = *tab_id;
  }
  runtime.previous_result = CloneToolResult(result);
  runtime.evidence_history.push_back(
      {.tool_name = "page.observe", .result = CloneToolResult(result)});
  if (runtime.evidence_history.size() > kMaxRuntimeEvidenceItems) {
    runtime.evidence_history.erase(runtime.evidence_history.begin());
  }
  RequestNextModelTurn(task_id);
}

std::optional<int32_t> AegisAgentService::SelectRuntimeObservationTab(
    const AgentTask& task,
    const ExecutionRuntime& runtime) const {
  auto valid_tab = [&](int32_t tab_id) {
    tabs::TabInterface* tab = tabs::TabHandle(tab_id).Get();
    return tab && tab->GetProfile() == profile_ && task.AllowsTab(tab_id) &&
           task.scope().AllowsOrigin(tab->GetURL());
  };
  if (runtime.last_tab_id && valid_tab(*runtime.last_tab_id)) {
    return runtime.last_tab_id;
  }
  for (int32_t tab_id : task.scope().allowed_tab_ids) {
    if (valid_tab(tab_id)) {
      return tab_id;
    }
  }
  for (int32_t tab_id : task.owned_tab_ids()) {
    if (valid_tab(tab_id)) {
      return tab_id;
    }
  }
  return std::nullopt;
}

void AegisAgentService::OnExecutionModelResult(const std::string& task_id,
                                               std::string expected_tool,
                                               bool ok,
                                               std::string error,
                                               AgentModelParseResult result) {
  model_request_ids_.erase(task_id);
  auto runtime_it = executions_.find(task_id);
  AgentTask* task = GetTask(task_id);
  const AgentTaskPlan* plan = GetPlan(task_id);
  if (!task || !plan || runtime_it == executions_.end() ||
      (task->state() != AgentTaskState::kRunning &&
       task->state() != AgentTaskState::kReflecting)) {
    return;
  }
  ExecutionRuntime& runtime = *runtime_it->second;
  if (!ok) {
    ++runtime.model_failures;
    if (runtime.model_failures < 2) {
      RequestNextModelTurn(task_id);
      return;
    }
    Transition(task_id, AgentTaskState::kFailed,
               "execution model failed twice");
    FinishRuntime(task_id, false, std::move(error), std::nullopt);
    return;
  }
  std::string validation_error;
  std::optional<AgentModelEvent> event =
      SelectExecutionToolCall(result, expected_tool, &validation_error);
  if (!event) {
    ++runtime.model_failures;
    model_capabilities_[ModelCapabilityKey(task->scope().model_destination)]
        .RecordSchemaFailure();
    if (runtime.model_failures < 2) {
      RequestNextModelTurn(task_id);
      return;
    }
    Transition(task_id, AgentTaskState::kFailed,
               "execution schema failed twice");
    FinishRuntime(task_id, false, std::move(validation_error), std::nullopt);
    return;
  }
  runtime.model_failures = 0;
  model_capabilities_[ModelCapabilityKey(task->scope().model_destination)]
      .RecordSchemaSuccess();
  if (expected_tool == "agent.complete") {
    std::optional<AgentCompletionSummary> completion =
        ParseCompletionSummary(*event, &validation_error);
    if (!completion ||
        !AgentCompletionSourcesMatchEvidence(*completion,
                                             runtime.evidence_history) ||
        std::ranges::any_of(completion->source_urls,
                            [&](const std::string& source) {
                              return !task->scope().AllowsOrigin(GURL(source));
                            })) {
      Transition(task_id, AgentTaskState::kFailed,
                 "completion evidence was rejected");
      FinishRuntime(task_id, false,
                    validation_error.empty()
                        ? "completion source is outside task scope"
                        : std::move(validation_error),
                    std::nullopt);
      return;
    }
    const std::vector<AgentMonitorDefinition> monitors = GetMonitors(task_id);
    const bool monitoring =
        task->mode() == AgentMode::kAutomate &&
        std::ranges::any_of(
            monitors, [](const auto& monitor) { return monitor.enabled; });
    if (monitoring) {
      completion->outcome = "monitoring";
      completion->summary =
          "计划步骤已完成；浏览器会在运行期间按已同意的计划继续监控。";
      FinishRuntime(task_id, true, std::string(), std::move(completion));
      ScheduleMonitorTimer();
      return;
    }
    if (!Transition(task_id, AgentTaskState::kVerifying,
                    "all planned actions have browser results") ||
        !CompleteTask(task_id)) {
      FinishRuntime(task_id, false,
                    "task completion could not be browser-verified",
                    std::nullopt);
      return;
    }
    FinishRuntime(task_id, true, std::string(), std::move(completion));
    return;
  }
  if (runtime.next_step >= plan->steps.size()) {
    Transition(task_id, AgentTaskState::kFailed,
               "model requested an action after the plan ended");
    FinishRuntime(task_id, false, "model action is outside the plan",
                  std::nullopt);
    return;
  }
  std::optional<AgentToolCall> call =
      BindExecutionToolCall(*task, plan->steps[runtime.next_step],
                            runtime.attempt, *event, &validation_error);
  if (call && call->tool_name == "shopping.prepare_checkout" &&
      (!runtime.previous_result ||
       !ValidateAgentCheckoutSummary(*call, *runtime.previous_result,
                                     &validation_error))) {
    call.reset();
  }
  if (!call) {
    ++runtime.attempt;
    if (!PersistPlanProgress(task_id, runtime.next_step, runtime.attempt)) {
      Transition(task_id, AgentTaskState::kFailed,
                 "execution cursor could not be persisted");
      FinishRuntime(task_id, false,
                    "execution stopped to prevent action replay", std::nullopt);
      return;
    }
    if (runtime.attempt < 3) {
      if (task->state() == AgentTaskState::kRunning) {
        Transition(task_id, AgentTaskState::kReflecting,
                   "tool context changed before execution");
      }
      RequestNextModelTurn(task_id);
      return;
    }
    Transition(task_id, AgentTaskState::kFailed,
               "tool context could not be rebound");
    FinishRuntime(task_id, false, std::move(validation_error), std::nullopt);
    return;
  }
  if (const std::optional<int> tab_id = call->arguments.FindInt("tab_id")) {
    runtime.last_tab_id = *tab_id;
  }
  if (call->tool_name == "shopping.prepare_checkout") {
    VerifyCheckoutBeforeTakeover(task_id, std::move(*call),
                                 CloneToolResult(*runtime.previous_result));
    return;
  }
  ExecuteRuntimeTool(task_id, std::move(*call), std::nullopt);
}

void AegisAgentService::VerifyCheckoutBeforeTakeover(
    const std::string& task_id,
    AgentToolCall call,
    AgentToolResult expected_observation) {
  auto runtime_it = executions_.find(task_id);
  AgentTask* task = GetTask(task_id);
  const std::optional<int> tab_id = call.arguments.FindInt("tab_id");
  tabs::TabInterface* tab = tab_id ? tabs::TabHandle(*tab_id).Get() : nullptr;
  if (!task || runtime_it == executions_.end() ||
      (task->state() != AgentTaskState::kRunning &&
       task->state() != AgentTaskState::kReflecting) ||
      !tab || tab->GetProfile() != profile_ ||
      tab->GetURL() != call.committed_url) {
    OnCheckoutPreflight(
        task_id, std::move(call), std::move(expected_observation),
        AgentToolResult{.action_id = task_id + ":checkout-preflight",
                        .ok = false,
                        .error = AgentErrorCode::kStaleDocument,
                        .message = "checkout tab changed before revalidation"});
    return;
  }
  ExecutionRuntime& runtime = *runtime_it->second;
  runtime.needs_fresh_observation = true;
  AgentToolCall observe;
  observe.action_id = task_id + ":checkout-preflight:" +
                      std::to_string(++runtime.refresh_count);
  observe.tool_name = "page.observe";
  observe.arguments.Set("tab_id", *tab_id);
  observe.arguments.Set("query",
                        "re-read merchant product quantity price currency "
                        "delivery and returns before user takeover");
  observe.committed_url = tab->GetURL();
  ExecuteTool(task_id, observe,
              base::BindOnce(&AegisAgentService::OnCheckoutPreflight,
                             weak_ptr_factory_.GetWeakPtr(), task_id,
                             std::move(call), std::move(expected_observation)));
}

void AegisAgentService::OnCheckoutPreflight(
    const std::string& task_id,
    AgentToolCall call,
    AgentToolResult expected_observation,
    AgentToolResult fresh_observation) {
  auto runtime_it = executions_.find(task_id);
  AgentTask* task = GetTask(task_id);
  if (!task || runtime_it == executions_.end()) {
    return;
  }
  ExecutionRuntime& runtime = *runtime_it->second;
  if (task->state() == AgentTaskState::kPausedByUser) {
    runtime.needs_fresh_observation = true;
    return;
  }
  if (task->state() != AgentTaskState::kRunning &&
      task->state() != AgentTaskState::kReflecting) {
    return;
  }

  std::string validation_error;
  const bool unchanged =
      IsSameAgentCheckoutObservation(expected_observation, fresh_observation);
  if (fresh_observation.ok) {
    runtime.previous_result = CloneToolResult(fresh_observation);
    runtime.needs_fresh_observation = false;
  }
  if (!fresh_observation.ok || !unchanged) {
    ++runtime.attempt;
    if (!PersistPlanProgress(task_id, runtime.next_step, runtime.attempt)) {
      Transition(task_id, AgentTaskState::kFailed,
                 "checkout revalidation cursor could not be persisted");
      FinishRuntime(task_id, false,
                    "checkout stopped to prevent stale takeover replay",
                    std::nullopt);
      return;
    }
    if (runtime.attempt < 3 && fresh_observation.ok) {
      if (task->state() == AgentTaskState::kRunning) {
        Transition(task_id, AgentTaskState::kReflecting,
                   "checkout facts changed; old summary invalidated");
      }
      RequestNextModelTurn(task_id);
      return;
    }
    Transition(task_id, AgentTaskState::kFailed,
               fresh_observation.ok
                   ? "checkout facts changed repeatedly before takeover"
                   : "checkout facts could not be re-read before takeover");
    FinishRuntime(task_id, false,
                  fresh_observation.ok
                      ? "checkout summary became stale before user takeover"
                      : fresh_observation.message,
                  std::nullopt);
    return;
  }

  const std::optional<int> tab_id = call.arguments.FindInt("tab_id");
  const std::optional<AgentDocumentRef> latest =
      tab_id ? actor_bridge_.LastDocument(task_id, *tab_id) : std::nullopt;
  if (!latest) {
    Transition(task_id, AgentTaskState::kFailed,
               "checkout document disappeared after revalidation");
    FinishRuntime(task_id, false, "checkout document is no longer available",
                  std::nullopt);
    return;
  }
  call.document = *latest;
  call.committed_url = latest->committed_url;
  call.arguments.Set("document_token", latest->document_token);
  if (const std::string* fingerprint =
          fresh_observation.value.FindString("observation_fingerprint")) {
    call.arguments.Set("observation_fingerprint", *fingerprint);
  }
  if (!ValidateAgentCheckoutSummary(call, fresh_observation,
                                    &validation_error)) {
    Transition(task_id, AgentTaskState::kFailed,
               "checkout summary failed browser source validation");
    FinishRuntime(task_id, false, std::move(validation_error), std::nullopt);
    return;
  }
  ExecuteRuntimeTool(task_id, std::move(call), std::nullopt);
}

std::optional<AgentToolCall> AegisAgentService::BindExecutionToolCall(
    const AgentTask& task,
    const AgentPlanStep& step,
    int attempt,
    const AgentModelEvent& event,
    std::string* error) const {
  if (!error) {
    return std::nullopt;
  }
  error->clear();
  const AgentToolDescriptor* descriptor = tool_registry_.Find(step.tool_name);
  if (!descriptor || event.type != AgentModelEventType::kToolCall ||
      event.tool_name != step.tool_name || attempt < 0 || attempt >= 3) {
    *error = "model tool call does not match the current plan step";
    return std::nullopt;
  }
  AgentToolCall call;
  call.action_id =
      task.id() + ":" + step.step_id + ":" + std::to_string(attempt + 1);
  if (call.action_id.size() > 128u) {
    *error = "browser-generated action id exceeds its bound";
    return std::nullopt;
  }
  call.tool_name = step.tool_name;
  call.arguments = event.arguments.Clone();

  const std::optional<int> tab_id = call.arguments.FindInt("tab_id");
  if (tab_id) {
    tabs::TabInterface* tab = tabs::TabHandle(*tab_id).Get();
    if (!tab || tab->GetProfile() != profile_ || !task.AllowsTab(*tab_id) ||
        !task.scope().AllowsOrigin(tab->GetURL())) {
      *error = "model referenced a tab outside the live task scope";
      return std::nullopt;
    }
    call.committed_url = tab->GetURL();
    if (descriptor->requires_document) {
      const std::optional<AgentDocumentRef> document =
          actor_bridge_.LastDocument(task.id(), *tab_id);
      const std::string* requested_token =
          call.arguments.FindString("document_token");
      if (!document || !requested_token ||
          document->document_token != *requested_token ||
          document->committed_url != call.committed_url) {
        *error = "model referenced a stale browser document";
        return std::nullopt;
      }
      call.document = *document;
    }
  } else if (const std::string* target = call.arguments.FindString("url")) {
    call.committed_url = GURL(*target);
  } else if (const std::string* candidate =
                 call.arguments.FindString("candidate_url")) {
    call.committed_url = GURL(*candidate);
  }
  if (descriptor->requires_origin &&
      (!call.committed_url.is_valid() ||
       !task.scope().AllowsOrigin(call.committed_url))) {
    *error = "tool call has no live approved origin";
    return std::nullopt;
  }
  return call;
}

void AegisAgentService::ExecuteRuntimeTool(
    const std::string& task_id,
    AgentToolCall call,
    const std::optional<std::string>& approval_id) {
  AgentToolCall callback_call = CloneToolCall(call);
  ExecuteTool(task_id, call,
              base::BindOnce(&AegisAgentService::OnRuntimeToolResult,
                             weak_ptr_factory_.GetWeakPtr(), task_id,
                             std::move(callback_call)),
              approval_id);
}

void AegisAgentService::OnRuntimeToolResult(const std::string& task_id,
                                            AgentToolCall attempted_call,
                                            AgentToolResult result) {
  auto runtime_it = executions_.find(task_id);
  AgentTask* task = GetTask(task_id);
  const AgentTaskPlan* plan = GetPlan(task_id);
  if (!task || !plan || runtime_it == executions_.end()) {
    return;
  }
  ExecutionRuntime& runtime = *runtime_it->second;
  if (const std::optional<int> tab_id =
          attempted_call.arguments.FindInt("tab_id")) {
    runtime.last_tab_id = *tab_id;
  }
  const AgentToolDescriptor* descriptor =
      tool_registry_.Find(attempted_call.tool_name);
  if (!result.ok && result.error == AgentErrorCode::kApprovalRequired &&
      descriptor) {
    runtime.pending_action = std::move(attempted_call);
    runtime.final_user_takeover =
        descriptor->risk == AgentRiskLevel::kR3UserTakeover &&
        runtime.next_step + 1 == plan->steps.size();
    NotifyServiceSnapshotChanged();
    return;
  }

  runtime.pending_action.reset();
  runtime.previous_result = CloneToolResult(result);
  if (result.ok) {
    runtime.evidence_history.push_back({.tool_name = attempted_call.tool_name,
                                        .result = CloneToolResult(result)});
    if (runtime.evidence_history.size() > kMaxRuntimeEvidenceItems) {
      runtime.evidence_history.erase(runtime.evidence_history.begin());
    }
    ++runtime.next_step;
    runtime.attempt = 0;
    if (!PersistPlanProgress(task_id, runtime.next_step, runtime.attempt)) {
      Transition(task_id, AgentTaskState::kFailed,
                 "verified action cursor could not be persisted");
      FinishRuntime(task_id, false,
                    "execution stopped to prevent verified action replay",
                    std::nullopt);
      return;
    }
    if (task->state() == AgentTaskState::kReflecting) {
      Transition(task_id, AgentTaskState::kRunning,
                 "browser verified the retried action");
    }
    if (task->state() == AgentTaskState::kRunning) {
      RequestNextModelTurn(task_id);
    }
    return;
  }
  if (task->state() != AgentTaskState::kRunning &&
      task->state() != AgentTaskState::kReflecting) {
    return;
  }
  ++runtime.attempt;
  if (!PersistPlanProgress(task_id, runtime.next_step, runtime.attempt)) {
    Transition(task_id, AgentTaskState::kFailed,
               "failed action cursor could not be persisted");
    FinishRuntime(task_id, false, "execution cursor storage failed",
                  std::nullopt);
    return;
  }
  if (runtime.attempt < 3) {
    if (task->state() == AgentTaskState::kRunning) {
      Transition(task_id, AgentTaskState::kReflecting,
                 "browser rejected the action; bounded retry requested");
    }
    RequestNextModelTurn(task_id);
    return;
  }
  Transition(task_id, AgentTaskState::kFailed,
             "browser action failed after bounded retries");
  FinishRuntime(task_id, false, result.message, std::nullopt);
}

void AegisAgentService::FinishRuntime(
    const std::string& task_id,
    bool ok,
    std::string error,
    std::optional<AgentCompletionSummary> completion) {
  model_request_ids_.erase(task_id);
  auto it = executions_.find(task_id);
  if (it == executions_.end()) {
    return;
  }
  RunCallback callback = std::move(it->second->callback);
  executions_.erase(it);
  if (callback) {
    std::move(callback).Run(ok, std::move(error), std::move(completion));
  }
}

AgentPolicyDecision AegisAgentService::EvaluateToolCall(
    const std::string& task_id,
    const AgentToolCall& call,
    const std::optional<std::string>& approval_id) {
  AgentTask* task = GetTask(task_id);
  if (!task) {
    return {.disposition = AgentPolicyDisposition::kDeny,
            .risk = AgentRiskLevel::kBlocked,
            .error = AgentErrorCode::kInvalidRequest,
            .reason = "unknown task"};
  }
  if (!IsToolAvailable(call.tool_name)) {
    return {.disposition = AgentPolicyDisposition::kDeny,
            .risk = AgentRiskLevel::kBlocked,
            .error = AgentErrorCode::kToolUnavailable,
            .reason = "tool capability is disabled"};
  }
  const std::string action_hash = AgentPolicyBroker::ActionHash(call);
  auto task_hashes = action_hashes_.find(task_id);
  auto existing_hash = task_hashes == action_hashes_.end()
                           ? std::map<std::string, std::string>::iterator()
                           : task_hashes->second.find(call.action_id);
  if (FindRecordedResult(task_id, call.action_id)) {
    if (task_hashes == action_hashes_.end() ||
        existing_hash == task_hashes->second.end() ||
        existing_hash->second != action_hash) {
      return {.disposition = AgentPolicyDisposition::kDeny,
              .risk = AgentRiskLevel::kBlocked,
              .error = AgentErrorCode::kInvalidRequest,
              .reason = "action id is bound to a different exact call"};
    }
    return {.disposition = AgentPolicyDisposition::kAllow,
            .risk = AgentRiskLevel::kR0ReadOnly,
            .error = AgentErrorCode::kNone,
            .reason = "idempotent result already recorded"};
  }
  if (task_hashes != action_hashes_.end() &&
      existing_hash != task_hashes->second.end()) {
    return {.disposition = AgentPolicyDisposition::kDeny,
            .risk = AgentRiskLevel::kBlocked,
            .error = AgentErrorCode::kInvalidRequest,
            .reason = existing_hash->second == action_hash
                          ? "exact action is already executing"
                          : "action id is bound to a different exact call"};
  }
  AgentPolicyDecision decision =
      policy_broker_.Evaluate(*task, call, approval_id);
  if (decision.disposition == AgentPolicyDisposition::kAllow &&
      !task->ConsumeToolCall()) {
    return {.disposition = AgentPolicyDisposition::kDeny,
            .risk = AgentRiskLevel::kBlocked,
            .error = AgentErrorCode::kBudgetExhausted,
            .reason = "tool-call budget exhausted"};
  }
  if (decision.disposition == AgentPolicyDisposition::kAllow) {
    action_tools_[task_id][call.action_id] = call.tool_name;
    action_hashes_[task_id][call.action_id] = action_hash;
    const AgentToolDescriptor* descriptor = tool_registry_.Find(call.tool_name);
    if (descriptor && (descriptor->has_external_side_effect ||
                       descriptor->risk != AgentRiskLevel::kR0ReadOnly)) {
      task_has_external_side_effect_[task_id] = true;
    }
    if (!PersistTask(*task)) {
      action_tools_[task_id].erase(call.action_id);
      action_hashes_[task_id].erase(call.action_id);
      return {.disposition = AgentPolicyDisposition::kDeny,
              .risk = AgentRiskLevel::kBlocked,
              .error = AgentErrorCode::kInternal,
              .reason = "tool budget could not be persisted"};
    }
  }
  return decision;
}

std::optional<AgentApprovalReceipt> AegisAgentService::ApproveToolCall(
    const std::string& task_id,
    const AgentToolCall& call) {
  AgentTask* task = GetTask(task_id);
  return task && IsToolAvailable(call.tool_name)
             ? policy_broker_.IssueApproval(*task, call)
             : std::nullopt;
}

void AegisAgentService::ExecuteTool(
    const std::string& task_id,
    const AgentToolCall& call,
    ToolResultCallback callback,
    const std::optional<std::string>& approval_id) {
  if (const AgentToolResult* recorded =
          FindRecordedResult(task_id, call.action_id)) {
    auto task_hashes = action_hashes_.find(task_id);
    auto action_hash = task_hashes == action_hashes_.end()
                           ? std::map<std::string, std::string>::iterator()
                           : task_hashes->second.find(call.action_id);
    if (task_hashes == action_hashes_.end() ||
        action_hash == task_hashes->second.end() ||
        action_hash->second != AgentPolicyBroker::ActionHash(call)) {
      std::move(callback).Run(AgentToolResult{
          .action_id = call.action_id,
          .ok = false,
          .error = AgentErrorCode::kInvalidRequest,
          .message = "action id is bound to a different exact call"});
      return;
    }
    AgentToolResult copy{.schema_version = recorded->schema_version,
                         .action_id = recorded->action_id,
                         .ok = recorded->ok,
                         .error = recorded->error,
                         .message = recorded->message,
                         .value = recorded->value.Clone(),
                         .evidence = recorded->evidence.Clone()};
    std::move(callback).Run(std::move(copy));
    return;
  }

  AgentTask* task = GetTask(task_id);
  const AgentToolDescriptor* descriptor = tool_registry_.Find(call.tool_name);
  if (task && descriptor && descriptor->requires_document && call.document &&
      TaskUsesActor(*task)) {
    const std::optional<AgentDocumentRef> latest =
        actor_bridge_.LastDocument(task_id, call.document->tab_id);
    if (!latest || !SameDocument(*latest, *call.document)) {
      std::move(callback).Run(AgentToolResult{
          .action_id = call.action_id,
          .ok = false,
          .error = AgentErrorCode::kStaleDocument,
          .message = "tool requires the latest browser observation"});
      return;
    }
  }

  AgentPolicyDecision decision = EvaluateToolCall(task_id, call, approval_id);
  if (decision.disposition != AgentPolicyDisposition::kAllow) {
    if (decision.disposition ==
        AgentPolicyDisposition::kRequireActionApproval) {
      if (task && task->state() == AgentTaskState::kRunning) {
        Transition(task_id, AgentTaskState::kAwaitingActionApproval,
                   "exact action approval required");
      }
    } else if (decision.disposition ==
               AgentPolicyDisposition::kRequireUserTakeover) {
      BeginUserTakeover(task_id);
    }
    std::move(callback).Run(
        AgentToolResult{.action_id = call.action_id,
                        .ok = false,
                        .error = decision.error,
                        .message = std::move(decision.reason)});
    return;
  }

  task = GetTask(task_id);
  if (!task) {
    std::move(callback).Run(
        AgentToolResult{.action_id = call.action_id,
                        .ok = false,
                        .error = AgentErrorCode::kInvalidRequest,
                        .message = "task disappeared before execution"});
    return;
  }
  if (task->state() == AgentTaskState::kAwaitingActionApproval) {
    Transition(task_id, AgentTaskState::kRunning,
               "exact action approval consumed");
  }

  auto result_callback = base::BindOnce(&AegisAgentService::OnToolExecuted,
                                        weak_ptr_factory_.GetWeakPtr(), task_id,
                                        call.tool_name, std::move(callback));
  if (base::StartsWith(call.tool_name, "page.") ||
      base::StartsWith(call.tool_name, "auth.") ||
      call.tool_name == "form.fill") {
    actor_bridge_.ExecutePageTool(task_id, call, std::move(result_callback));
    return;
  }
  if (browser_tools_.CanHandle(call.tool_name)) {
    browser_tools_.Execute(task, call, std::move(result_callback));
    return;
  }
  if (base::StartsWith(call.tool_name, "monitor.")) {
    ExecuteMonitorTool(task, call, std::move(result_callback));
    return;
  }
  std::move(result_callback)
      .Run(AgentToolResult{.action_id = call.action_id,
                           .ok = false,
                           .error = AgentErrorCode::kToolUnavailable,
                           .message = "tool has no browser implementation"});
}

bool AegisAgentService::RecordToolResult(const std::string& task_id,
                                         AgentToolResult result) {
  if (!GetTask(task_id) || result.schema_version != kAgentSchemaVersion ||
      result.action_id.empty() || result.action_id.size() > 128u) {
    return false;
  }
  auto task_hashes = action_hashes_.find(task_id);
  auto task_tools = action_tools_.find(task_id);
  if (task_hashes == action_hashes_.end() ||
      !task_hashes->second.contains(result.action_id) ||
      task_tools == action_tools_.end() ||
      !task_tools->second.contains(result.action_id)) {
    return false;
  }
  ActionResults& results = action_results_[task_id];
  const std::string action_id = result.action_id;
  auto inserted = results.emplace(action_id, std::move(result));
  if (!inserted.second) {
    return false;
  }
  if (task_tools != action_tools_.end()) {
    auto tool = task_tools->second.find(action_id);
    if (tool != task_tools->second.end()) {
      const AgentToolDescriptor* descriptor = tool_registry_.Find(tool->second);
      task_store_.AppendActionSummary(
          task_id, action_id, tool->second,
          descriptor ? descriptor->risk : AgentRiskLevel::kBlocked,
          inserted.first->second.ok,
          inserted.first->second.ok ? "browser verification passed"
                                    : "browser verification failed");
    }
  }
  return true;
}

const AgentToolResult* AegisAgentService::FindRecordedResult(
    const std::string& task_id,
    const std::string& action_id) const {
  auto task_it = action_results_.find(task_id);
  if (task_it == action_results_.end()) {
    return nullptr;
  }
  auto action_it = task_it->second.find(action_id);
  return action_it == task_it->second.end() ? nullptr : &action_it->second;
}

bool AegisAgentService::CanUndoLastBookmarkAction(
    const std::string& task_id) const {
  const AgentTask* task = GetTask(task_id);
  return IsEnabled() && task && task->scope().AllowsTool("bookmark.undo") &&
         bookmark_undo_tokens_.contains(task_id);
}

void AegisAgentService::UndoLastBookmarkAction(const std::string& task_id,
                                               ToolResultCallback callback) {
  auto token = bookmark_undo_tokens_.find(task_id);
  if (!CanUndoLastBookmarkAction(task_id) ||
      token == bookmark_undo_tokens_.end()) {
    std::move(callback).Run(AgentToolResult{
        .action_id = "ui-bookmark-undo",
        .ok = false,
        .error = AgentErrorCode::kInvalidRequest,
        .message = "no verified bookmark action can be undone"});
    return;
  }
  AgentToolCall call;
  call.action_id =
      "ui-undo-" + base::Uuid::GenerateRandomV4().AsLowercaseString();
  call.tool_name = "bookmark.undo";
  call.arguments.Set("undo_token", token->second);
  ExecuteTool(task_id, call, std::move(callback));
}

bool AegisAgentService::UpsertMonitor(AgentMonitorDefinition monitor) {
  AgentTask* task = GetTask(monitor.task_id);
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgentWorkflows) ||
      !task || task->mode() != AgentMode::kAutomate ||
      IsTerminalState(task->state()) || !monitor.IsValid() ||
      std::ranges::find(task->scope().allowed_origins, monitor.origin) ==
          task->scope().allowed_origins.end()) {
    return false;
  }
  const std::vector<AgentMonitorDefinition> existing =
      monitor_scheduler_.Snapshot();
  auto existing_it = std::ranges::find_if(existing, [&](const auto& candidate) {
    return candidate.monitor_id == monitor.monitor_id;
  });
  if (existing_it != existing.end() &&
      existing_it->task_id != monitor.task_id) {
    return false;
  }
  if (monitor.next_run.is_null()) {
    monitor.next_run = base::Time::Now() + monitor.interval;
  }
  if (!task_store_.SaveMonitor(monitor)) {
    return false;
  }
  const bool upserted = monitor_scheduler_.Upsert(std::move(monitor));
  if (upserted) {
    ScheduleMonitorTimer();
    NotifyServiceSnapshotChanged();
  }
  return upserted;
}

bool AegisAgentService::SetMonitorPaused(const std::string& task_id,
                                         const std::string& monitor_id,
                                         bool paused) {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgentWorkflows)) {
    return false;
  }
  const AgentTask* task = GetTask(task_id);
  if (!task || task->mode() != AgentMode::kAutomate) {
    return false;
  }
  std::vector<AgentMonitorDefinition> monitors = monitor_scheduler_.Snapshot();
  auto it = std::ranges::find_if(monitors, [&](const auto& monitor) {
    return monitor.monitor_id == monitor_id && monitor.task_id == task_id;
  });
  if (it == monitors.end()) {
    return false;
  }
  it->enabled = !paused;
  if (it->enabled) {
    it->next_run = base::Time::Now() + it->interval;
  }
  if (!task_store_.SaveMonitor(*it) ||
      !monitor_scheduler_.Upsert(std::move(*it))) {
    return false;
  }
  ScheduleMonitorTimer();
  NotifyServiceSnapshotChanged();
  return true;
}

bool AegisAgentService::RemoveMonitor(const std::string& task_id,
                                      const std::string& monitor_id) {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgentWorkflows)) {
    return false;
  }
  const std::vector<AgentMonitorDefinition> monitors =
      monitor_scheduler_.Snapshot();
  auto it = std::ranges::find_if(monitors, [&](const auto& monitor) {
    return monitor.monitor_id == monitor_id && monitor.task_id == task_id;
  });
  if (it == monitors.end() || !task_store_.DeleteMonitor(monitor_id)) {
    return false;
  }
  const bool removed = monitor_scheduler_.Remove(monitor_id);
  if (removed) {
    ScheduleMonitorTimer();
    NotifyServiceSnapshotChanged();
  }
  return removed;
}

std::vector<AgentMonitorDefinition> AegisAgentService::ClaimDueMonitors(
    base::Time now) {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgentWorkflows)) {
    return {};
  }
  std::vector<AgentMonitorDefinition> runnable;
  for (AgentMonitorDefinition& monitor : monitor_scheduler_.ClaimDue(now)) {
    AgentTask* task = GetTask(monitor.task_id);
    if (!task || task->mode() != AgentMode::kAutomate ||
        task->state() == AgentTaskState::kFailed ||
        task->state() == AgentTaskState::kCancelled ||
        task->state() == AgentTaskState::kExpired ||
        std::ranges::find(task->scope().allowed_origins, monitor.origin) ==
            task->scope().allowed_origins.end()) {
      monitor_scheduler_.Remove(monitor.monitor_id);
      task_store_.DeleteMonitor(monitor.monitor_id);
      continue;
    }
    if (!task->ConsumeNetworkRequest()) {
      monitor.enabled = false;
      monitor_scheduler_.Upsert(monitor);
      task_store_.SaveMonitor(monitor);
      continue;
    }
    if (!PersistTask(*task) || !task_store_.SaveMonitor(monitor)) {
      monitor.enabled = false;
      monitor_scheduler_.Upsert(monitor);
      task_store_.SaveMonitor(monitor);
      continue;
    }
    runnable.push_back(std::move(monitor));
  }
  return runnable;
}

bool AegisAgentService::MarkMonitorFinished(const std::string& task_id,
                                            const std::string& monitor_id,
                                            bool success,
                                            base::Time now) {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgentWorkflows)) {
    return false;
  }
  const AgentTask* task = GetTask(task_id);
  const std::vector<AgentMonitorDefinition> before =
      monitor_scheduler_.Snapshot();
  auto before_it = std::ranges::find_if(before, [&](const auto& monitor) {
    return monitor.monitor_id == monitor_id && monitor.task_id == task_id;
  });
  if (!task || before_it == before.end() ||
      !monitor_scheduler_.MarkFinished(monitor_id, success, now)) {
    return false;
  }
  const std::vector<AgentMonitorDefinition> monitors =
      monitor_scheduler_.Snapshot();
  auto it = std::ranges::find_if(monitors, [&](const auto& monitor) {
    return monitor.monitor_id == monitor_id && monitor.task_id == task_id;
  });
  const bool persisted = it != monitors.end() && task_store_.SaveMonitor(*it);
  if (persisted) {
    ScheduleMonitorTimer();
    NotifyServiceSnapshotChanged();
  }
  return persisted;
}

std::vector<AgentMonitorDefinition> AegisAgentService::GetMonitors(
    const std::string& task_id) const {
  std::vector<AgentMonitorDefinition> result;
  for (const AgentMonitorDefinition& monitor : monitor_scheduler_.Snapshot()) {
    if (monitor.task_id == task_id) {
      result.push_back(monitor);
    }
  }
  return result;
}

std::vector<AgentMonitorDefinition> AegisAgentService::GetAllMonitors() const {
  return monitor_scheduler_.Snapshot();
}

void AegisAgentService::ExecuteMonitorTool(AgentTask* task,
                                           const AgentToolCall& call,
                                           ToolResultCallback callback) {
  if (!task || !base::StartsWith(call.tool_name, "monitor.")) {
    std::move(callback).Run(MonitorError(call.action_id,
                                         AgentErrorCode::kInvalidRequest,
                                         "monitor tool has no active task"));
    return;
  }
  if (call.tool_name == "monitor.create") {
    if (task->mode() != AgentMode::kAutomate || !call.document) {
      std::move(callback).Run(
          MonitorError(call.action_id, AgentErrorCode::kInvalidRequest,
                       "monitor creation requires Automate mode and a fresh "
                       "document"));
      return;
    }
    if (!g_browser_process || !g_browser_process->os_crypt_async()) {
      std::move(callback).Run(
          MonitorError(call.action_id, AgentErrorCode::kToolUnavailable,
                       "secure monitor target storage is unavailable"));
      return;
    }
    g_browser_process->os_crypt_async()->GetInstance(
        base::BindOnce(&AegisAgentService::OnMonitorCreateEncryptorReady,
                       weak_ptr_factory_.GetWeakPtr(), task->id(),
                       CloneToolCall(call), std::move(callback)));
    return;
  }

  if (call.tool_name == "monitor.list") {
    const std::vector<AgentMonitorDefinition> monitors =
        GetMonitors(task->id());
    base::ListValue values;
    for (const AgentMonitorDefinition& monitor : monitors) {
      values.Append(PublicMonitorValue(monitor));
    }
    base::DictValue value;
    value.Set("monitors", std::move(values));
    value.Set("revision", MonitorRevision(monitors));
    std::move(callback).Run(
        AgentToolResult{.action_id = call.action_id,
                        .ok = true,
                        .message = "task-owned monitor snapshot created",
                        .value = std::move(value)});
    return;
  }

  const std::string* monitor_id = call.arguments.FindString("monitor_id");
  std::vector<AgentMonitorDefinition> monitors = GetMonitors(task->id());
  auto monitor_it = monitor_id ? std::ranges::find_if(
                                     monitors,
                                     [&](const auto& monitor) {
                                       return monitor.monitor_id == *monitor_id;
                                     })
                               : monitors.end();
  if (monitor_it == monitors.end()) {
    std::move(callback).Run(MonitorError(call.action_id,
                                         AgentErrorCode::kInvalidRequest,
                                         "monitor is not owned by this task"));
    return;
  }
  if (call.tool_name == "monitor.pause") {
    const std::optional<bool> paused = call.arguments.FindBool("paused");
    if (!paused) {
      std::move(callback).Run(MonitorError(call.action_id,
                                           AgentErrorCode::kInvalidRequest,
                                           "monitor pause state is missing"));
      return;
    }
    if (!SetMonitorPaused(task->id(), *monitor_id, *paused)) {
      std::move(callback).Run(
          MonitorError(call.action_id, AgentErrorCode::kInternal,
                       "monitor pause state could not be persisted"));
      return;
    }
    const std::vector<AgentMonitorDefinition> updated = GetMonitors(task->id());
    base::DictValue value;
    value.Set("monitor_id", *monitor_id);
    value.Set("paused", *paused);
    value.Set("revision", MonitorRevision(updated));
    std::move(callback).Run(AgentToolResult{
        .action_id = call.action_id,
        .ok = true,
        .message = *paused ? "monitor paused" : "monitor resumed",
        .value = std::move(value)});
    return;
  }
  if (call.tool_name == "monitor.delete") {
    if (!RemoveMonitor(task->id(), *monitor_id)) {
      std::move(callback).Run(MonitorError(call.action_id,
                                           AgentErrorCode::kInternal,
                                           "monitor could not be deleted"));
      return;
    }
    const std::vector<AgentMonitorDefinition> updated = GetMonitors(task->id());
    base::DictValue value;
    value.Set("monitor_id", *monitor_id);
    value.Set("deleted", true);
    value.Set("revision", MonitorRevision(updated));
    std::move(callback).Run(AgentToolResult{.action_id = call.action_id,
                                            .ok = true,
                                            .message = "monitor deleted",
                                            .value = std::move(value)});
    return;
  }
  std::move(callback).Run(MonitorError(call.action_id,
                                       AgentErrorCode::kToolUnavailable,
                                       "unknown monitor tool"));
}

void AegisAgentService::OnMonitorCreateEncryptorReady(
    std::string task_id,
    AgentToolCall call,
    ToolResultCallback callback,
    scoped_refptr<os_crypt_async::Encryptor> encryptor) {
  AgentTask* task = GetTask(task_id);
  const std::string* kind_value = call.arguments.FindString("kind");
  const std::optional<int> interval_minutes =
      call.arguments.FindInt("interval_minutes");
  const std::optional<AgentMonitorKind> kind =
      kind_value ? ParseMonitorKind(*kind_value) : std::nullopt;
  const GURL target = MonitorTargetUrl(call.committed_url);
  const std::optional<AgentDocumentRef> latest =
      call.document ? actor_bridge_.LastDocument(task_id, call.document->tab_id)
                    : std::nullopt;
  std::string ciphertext;
  if (!task || task->state() != AgentTaskState::kRunning || !kind ||
      !interval_minutes || *interval_minutes < 15 ||
      *interval_minutes > 10080 || target.is_empty() || !call.document ||
      !latest || !SameDocument(*latest, *call.document) || !encryptor ||
      !encryptor->IsEncryptionAvailable() ||
      !encryptor->EncryptString(target.spec(), &ciphertext)) {
    std::move(callback).Run(
        MonitorError(call.action_id, AgentErrorCode::kInvalidRequest,
                     "monitor target or secure storage is unavailable"));
    return;
  }
  AgentMonitorDefinition monitor;
  monitor.monitor_id = AgentMonitorIdempotencyKey(task_id, call.action_id);
  monitor.task_id = task_id;
  monitor.kind = *kind;
  monitor.origin = url::Origin::Create(target);
  monitor.target_hash = Sha256(target.spec());
  monitor.target_url = target;
  monitor.target_ciphertext = std::move(ciphertext);
  monitor.interval = base::Minutes(*interval_minutes);
  monitor.next_run = base::Time::Now() + monitor.interval;
  if (!UpsertMonitor(monitor)) {
    std::move(callback).Run(
        MonitorError(call.action_id, AgentErrorCode::kInternal,
                     "encrypted monitor could not be persisted"));
    return;
  }
  const std::vector<AgentMonitorDefinition> monitors = GetMonitors(task_id);
  base::DictValue value = PublicMonitorValue(monitor);
  value.Set("revision", MonitorRevision(monitors));
  std::move(callback).Run(
      AgentToolResult{.action_id = call.action_id,
                      .ok = true,
                      .message = "encrypted page monitor created",
                      .value = std::move(value)});
}

void AegisAgentService::RestoreMonitorTargets() {
  const bool has_encrypted_target = std::ranges::any_of(
      monitor_scheduler_.Snapshot(),
      [](const auto& monitor) { return !monitor.target_ciphertext.empty(); });
  if (!has_encrypted_target) {
    return;
  }
  if (!g_browser_process || !g_browser_process->os_crypt_async()) {
    OnMonitorTargetsDecryptorReady(nullptr);
    return;
  }
  g_browser_process->os_crypt_async()->GetInstance(
      base::BindOnce(&AegisAgentService::OnMonitorTargetsDecryptorReady,
                     weak_ptr_factory_.GetWeakPtr()));
}

void AegisAgentService::OnMonitorTargetsDecryptorReady(
    scoped_refptr<os_crypt_async::Encryptor> encryptor) {
  for (AgentMonitorDefinition monitor : monitor_scheduler_.Snapshot()) {
    if (monitor.target_ciphertext.empty()) {
      continue;
    }
    std::string plaintext;
    const bool decrypted =
        encryptor && encryptor->IsDecryptionAvailable() &&
        encryptor->DecryptString(monitor.target_ciphertext, &plaintext);
    const GURL target = decrypted ? MonitorTargetUrl(GURL(plaintext)) : GURL();
    if (target.is_empty() || url::Origin::Create(target) != monitor.origin ||
        Sha256(target.spec()) != monitor.target_hash) {
      monitor.enabled = false;
      monitor.target_url = GURL();
    } else {
      monitor.target_url = target;
    }
    monitor_scheduler_.Upsert(monitor);
    task_store_.SaveMonitor(monitor);
  }
  ScheduleMonitorTimer();
}

void AegisAgentService::ScheduleMonitorTimer() {
  monitor_timer_.Stop();
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgentWorkflows)) {
    return;
  }
  std::optional<base::Time> earliest;
  for (const AgentMonitorDefinition& monitor : monitor_scheduler_.Snapshot()) {
    if (!monitor.enabled || monitor.next_run.is_null() ||
        !monitor.target_url.is_valid()) {
      continue;
    }
    if (!earliest || monitor.next_run < *earliest) {
      earliest = monitor.next_run;
    }
  }
  if (!earliest) {
    return;
  }
  monitor_timer_.Start(
      FROM_HERE, std::max(base::TimeDelta(), *earliest - base::Time::Now()),
      base::BindOnce(&AegisAgentService::OnMonitorTimer,
                     weak_ptr_factory_.GetWeakPtr()));
}

void AegisAgentService::OnMonitorTimer() {
  for (AgentMonitorDefinition monitor : ClaimDueMonitors(base::Time::Now())) {
    if (monitor.target_url.is_valid()) {
      ExecuteDueMonitor(std::move(monitor));
    } else {
      MarkMonitorFinished(monitor.task_id, monitor.monitor_id,
                          /*success=*/false, base::Time::Now());
    }
  }
  ScheduleMonitorTimer();
}

void AegisAgentService::ExecuteDueMonitor(AgentMonitorDefinition monitor) {
  AgentTask* task = GetTask(monitor.task_id);
  if (!task || task->state() == AgentTaskState::kPausedByUser ||
      task->state() == AgentTaskState::kUserTakeover ||
      task->state() == AgentTaskState::kFailed ||
      task->state() == AgentTaskState::kCancelled ||
      task->state() == AgentTaskState::kExpired) {
    MarkMonitorFinished(monitor.task_id, monitor.monitor_id,
                        /*success=*/false, base::Time::Now());
    return;
  }
  tabs::TabInterface* target_tab = nullptr;
  ProfileBrowserCollection::GetForProfile(profile_)->ForEach(
      [&](BrowserWindowInterface* browser) {
        for (tabs::TabInterface* tab : browser->GetAllTabInterfaces()) {
          if (tab && MonitorTargetUrl(tab->GetURL()) == monitor.target_url) {
            target_tab = tab;
            return false;
          }
        }
        return true;
      });
  if (!target_tab) {
    MarkMonitorFinished(monitor.task_id, monitor.monitor_id,
                        /*success=*/false, base::Time::Now());
    return;
  }

  const int32_t tab_id = target_tab->GetHandle().raw_value();
  bool actor_started = false;
  if (!actor_bridge_.HasTask(monitor.task_id)) {
    actor_started =
        actor_bridge_.StartTask(monitor.task_id, task->scope()).has_value();
    if (!actor_started) {
      MarkMonitorFinished(monitor.task_id, monitor.monitor_id,
                          /*success=*/false, base::Time::Now());
      return;
    }
  }
  bool task_adopted = false;
  if (!task->AllowsTab(tab_id)) {
    task_adopted = task->AdoptOwnedTab(tab_id);
    if (!task_adopted) {
      if (actor_started) {
        actor_bridge_.StopTask(monitor.task_id, /*completed=*/false);
      }
      MarkMonitorFinished(monitor.task_id, monitor.monitor_id,
                          /*success=*/false, base::Time::Now());
      return;
    }
  }
  if (!task->scope().AllowsTab(tab_id) && (actor_started || task_adopted) &&
      !actor_bridge_.AdoptTab(monitor.task_id, tab_id)) {
    if (task_adopted) {
      task->ReleaseOwnedTab(tab_id);
    }
    if (actor_started) {
      actor_bridge_.StopTask(monitor.task_id, /*completed=*/false);
    }
    MarkMonitorFinished(monitor.task_id, monitor.monitor_id,
                        /*success=*/false, base::Time::Now());
    return;
  }

  AgentToolCall call;
  call.action_id =
      "monitor:" +
      base::HexEncode(crypto::SHA256HashString(
          monitor.monitor_id +
          base::NumberToString(monitor.last_run.ToInternalValue())));
  call.tool_name = "page.observe";
  call.arguments.Set("tab_id", tab_id);
  call.arguments.Set("query", std::string(MonitorKindName(monitor.kind)));
  call.committed_url = target_tab->GetURL();
  AgentToolCall callback_call = CloneToolCall(call);
  actor_bridge_.ExecutePageTool(
      monitor.task_id, call,
      base::BindOnce(&AegisAgentService::OnDueMonitorObserved,
                     weak_ptr_factory_.GetWeakPtr(), std::move(monitor),
                     std::move(callback_call), tab_id, actor_started,
                     task_adopted));
}

void AegisAgentService::CleanupDueMonitorActor(const std::string& task_id,
                                               int32_t tab_id,
                                               bool actor_started,
                                               bool task_adopted) {
  if (task_adopted && actor_bridge_.HasTask(task_id)) {
    actor_bridge_.ReleaseTab(task_id, tab_id);
  }
  if (actor_started && actor_bridge_.HasTask(task_id)) {
    actor_bridge_.StopTask(task_id, /*completed=*/false);
  }
  if (task_adopted) {
    if (AgentTask* task = GetTask(task_id)) {
      task->ReleaseOwnedTab(tab_id);
    }
  }
}

void AegisAgentService::OnDueMonitorObserved(AgentMonitorDefinition monitor,
                                             AgentToolCall call,
                                             int32_t tab_id,
                                             bool actor_started,
                                             bool task_adopted,
                                             AgentToolResult result) {
  CleanupDueMonitorActor(monitor.task_id, tab_id, actor_started, task_adopted);
  AgentTask* task = GetTask(monitor.task_id);
  const AgentToolDescriptor* descriptor = tool_registry_.Find("page.observe");
  if (!task || !descriptor ||
      !result_verifier_.Verify(*task, call, *descriptor, result).accepted) {
    MarkMonitorFinished(monitor.task_id, monitor.monitor_id,
                        /*success=*/false, base::Time::Now());
    return;
  }
  const std::optional<std::string> observation =
      CanonicalMonitorObservation(monitor.kind, result);
  if (!observation) {
    MarkMonitorFinished(monitor.task_id, monitor.monitor_id,
                        /*success=*/false, base::Time::Now());
    return;
  }
  const std::string next_hash = Sha256(*observation);
  const bool changed =
      !monitor.last_value_hash.empty() && monitor.last_value_hash != next_hash;
  monitor.last_value_hash = next_hash;
  monitor_scheduler_.Upsert(monitor);
  if (!MarkMonitorFinished(monitor.task_id, monitor.monitor_id,
                           /*success=*/true, base::Time::Now())) {
    return;
  }
  if (changed) {
    task_store_.AppendActionSummary(
        monitor.task_id, "monitor:" + monitor.monitor_id, "monitor.check",
        AgentRiskLevel::kR0ReadOnly, true,
        "monitor detected a browser-verified change");
    task->RecordEvent("monitor change",
                      std::string(MonitorKindName(monitor.kind)) +
                          " changed at " + monitor.origin.host());
    ShowMonitorChangeNotification(monitor);
  }
}

void AegisAgentService::ShowMonitorChangeNotification(
    const AgentMonitorDefinition& monitor) const {
  if (!profile_ || shutting_down_) {
    return;
  }
  NotificationDisplayService* display_service =
      NotificationDisplayServiceFactory::GetForProfile(profile_);
  if (!display_service) {
    return;
  }

  message_center::RichNotificationData notification_data;
  notification_data.renotify = true;
  const std::string detail =
      "Change detected: " + std::string(MonitorKindName(monitor.kind)) + " · " +
      monitor.origin.host();
  message_center::Notification notification(
      message_center::NOTIFICATION_TYPE_SIMPLE,
      "aegis-agent-monitor-" + monitor.monitor_id, u"Aegis Browser Agent",
      base::UTF8ToUTF16(detail), ui::ImageModel(), std::u16string(), GURL(),
      message_center::NotifierId(message_center::NotifierType::SYSTEM_COMPONENT,
                                 "aegis-agent-monitor"),
      notification_data,
      /*delegate=*/nullptr);
  display_service->Display(NotificationHandler::Type::TRANSIENT, notification,
                           /*metadata=*/nullptr);
}

std::optional<StoredAgentTask::RecoveryDisposition>
AegisAgentService::recovery_disposition(const std::string& task_id) const {
  auto it = recovery_dispositions_.find(task_id);
  return it == recovery_dispositions_.end() ? std::nullopt
                                            : std::make_optional(it->second);
}

void AegisAgentService::Shutdown() {
  if (shutting_down_) {
    return;
  }
  shutting_down_ = true;
  monitor_timer_.Stop();
  weak_ptr_factory_.InvalidateWeakPtrs();
  for (const auto& [task_id, request_id] : model_request_ids_) {
    auto client = model_clients_.find(task_id);
    if (client != model_clients_.end()) {
      client->second->Cancel(request_id);
    }
  }
  model_request_ids_.clear();
  std::vector<std::string> running_task_ids;
  running_task_ids.reserve(executions_.size());
  for (const auto& [task_id, runtime] : executions_) {
    running_task_ids.push_back(task_id);
  }
  for (const std::string& task_id : running_task_ids) {
    FinishRuntime(task_id, false, "browser profile is shutting down",
                  std::nullopt);
  }
  for (const auto& [task_id, task] : tasks_) {
    if (!IsTerminalState(task->state())) {
      if (TaskUsesActor(*task)) {
        actor_bridge_.StopTask(task_id, /*completed=*/false);
      }
      policy_broker_.RevokeTaskApprovals(task_id);
      PersistTask(*task);
    }
    browser_tools_.ForgetTask(task_id);
  }
  tasks_.clear();
  plans_.clear();
  plan_progress_.clear();
  model_clients_.clear();
  model_capabilities_.clear();
  action_results_.clear();
  action_tools_.clear();
  action_hashes_.clear();
  task_has_external_side_effect_.clear();
  bookmark_undo_tokens_.clear();
  recovery_dispositions_.clear();
  pending_invocation_context_.reset();
  monitor_scheduler_.Restore({}, base::Time());
  profile_ = nullptr;
}

void AegisAgentService::OnToolExecuted(const std::string& task_id,
                                       std::string tool_name,
                                       ToolResultCallback callback,
                                       AgentToolResult result) {
  AgentTask* task = GetTask(task_id);
  if (result.ok &&
      (tool_name == "tab.create" || tool_name == "window.create" ||
       tool_name == "workspace.restore") &&
      task && TaskUsesActor(*task)) {
    std::vector<int> tab_ids;
    if (const std::optional<int> tab_id = result.value.FindInt("tab_id")) {
      tab_ids.push_back(*tab_id);
    }
    if (const base::ListValue* values = result.value.FindList("tab_ids")) {
      for (const base::Value& value : *values) {
        if (value.is_int()) {
          tab_ids.push_back(value.GetInt());
        }
      }
    }
    bool adopted = !tab_ids.empty();
    size_t adopted_count = 0;
    for (int tab_id : tab_ids) {
      if (!actor_bridge_.AdoptTab(task_id, tab_id)) {
        adopted = false;
        break;
      }
      ++adopted_count;
    }
    if (!adopted) {
      for (size_t index = 0; index < adopted_count; ++index) {
        actor_bridge_.ReleaseTab(task_id, tab_ids[index]);
      }
      for (int tab_id : tab_ids) {
        tabs::TabInterface* tab = tabs::TabHandle(tab_id).Get();
        if (tab && tab->GetProfile() == profile_) {
          tab->Close();
        }
        task->ReleaseOwnedTab(tab_id);
      }
      result.ok = false;
      result.error = AgentErrorCode::kVerificationFailed;
      result.message = "new tabs were not adopted by the Actor task";
      result.value.clear();
    }
  }

  const AgentToolDescriptor* descriptor = tool_registry_.Find(tool_name);
  // The caller-provided tool call is not retained because it can contain form
  // text. Reconstruct only the identity needed by the verifier and validate
  // tool-specific browser evidence below.
  AgentToolCall call_identity;
  call_identity.action_id = result.action_id;
  call_identity.tool_name = tool_name;
  if (!task || !descriptor) {
    result.ok = false;
    result.error = AgentErrorCode::kInternal;
    result.message = "tool result has no active task or descriptor";
    result.value.clear();
    result.evidence.clear();
  } else {
    AgentVerificationDecision verification =
        result_verifier_.Verify(*task, call_identity, *descriptor, result);
    if (!verification.accepted) {
      result.ok = false;
      result.error = verification.error;
      result.message = std::move(verification.reason);
      result.value.clear();
      result.evidence.clear();
    } else if (result.ok && !verification.postcondition_met) {
      result.ok = false;
      result.error = AgentErrorCode::kVerificationFailed;
      result.message = std::move(verification.reason);
    }
  }

  if (result.ok && tool_name == "bookmark.apply") {
    if (const std::string* undo_token = result.value.FindString("undo_token")) {
      bookmark_undo_tokens_[task_id] = *undo_token;
    }
  } else if (result.ok && tool_name == "bookmark.undo") {
    bookmark_undo_tokens_.erase(task_id);
  }

  AgentToolResult callback_result{.schema_version = result.schema_version,
                                  .action_id = result.action_id,
                                  .ok = result.ok,
                                  .error = result.error,
                                  .message = result.message,
                                  .value = result.value.Clone(),
                                  .evidence = result.evidence.Clone()};
  if (!RecordToolResult(task_id, std::move(result))) {
    callback_result.ok = false;
    callback_result.error = AgentErrorCode::kInternal;
    callback_result.message = "tool result could not be recorded";
  }
  if (task) {
    PersistTask(*task);
  }
  std::move(callback).Run(std::move(callback_result));
}

void AegisAgentService::OnActorStateEvent(const std::string& task_id,
                                          AegisActorBridge::StateEvent event) {
  if (shutting_down_) {
    return;
  }
  AgentTask* task = GetTask(task_id);
  if (!task || IsTerminalState(task->state())) {
    return;
  }
  policy_broker_.RevokeTaskApprovals(task_id);
  auto request = model_request_ids_.find(task_id);
  auto client = model_clients_.find(task_id);
  if (request != model_request_ids_.end() && client != model_clients_.end()) {
    client->second->Cancel(request->second);
    model_request_ids_.erase(request);
  }
  if (event == AegisActorBridge::StateEvent::kPausedByUser &&
      (task->state() == AgentTaskState::kRunning ||
       task->state() == AgentTaskState::kReflecting)) {
    Transition(task_id, AgentTaskState::kPausedByUser,
               "user interacted with a controlled tab");
    return;
  }
  if (event == AegisActorBridge::StateEvent::kWaitingOnUser &&
      (task->state() == AgentTaskState::kRunning ||
       task->state() == AgentTaskState::kReflecting ||
       task->state() == AgentTaskState::kAwaitingActionApproval ||
       task->state() == AgentTaskState::kPausedByUser)) {
    Transition(task_id, AgentTaskState::kUserTakeover,
               "browser action requires user control");
  }
}

bool AegisAgentService::Transition(const std::string& task_id,
                                   AgentTaskState state,
                                   std::string reason) {
  AgentTask* task = GetTask(task_id);
  if (!task || !task->TransitionTo(state, std::move(reason))) {
    return false;
  }
  return PersistTask(*task);
}

bool AegisAgentService::PersistTask(const AgentTask& task) {
  auto it = task_has_external_side_effect_.find(task.id());
  return storage_ready_ &&
         task_store_.SaveTask(
             task, task.goal(),
             it != task_has_external_side_effect_.end() && it->second);
}

bool AegisAgentService::PersistPlanProgress(const std::string& task_id,
                                            size_t next_step,
                                            int attempt) {
  auto plan = plans_.find(task_id);
  if (plan == plans_.end() ||
      !task_store_.SavePlan(task_id, plan->second, next_step, attempt)) {
    return false;
  }
  plan_progress_[task_id] = {next_step, attempt};
  return true;
}

bool AegisAgentService::ConsumeModelRequestBudget(AgentTask* task) {
  if (!task ||
      task->model_calls_used() >= task->scope().budgets.max_model_calls ||
      task->network_requests_used() >=
          task->scope().budgets.max_network_requests ||
      !task->ConsumeModelCall() || !task->ConsumeNetworkRequest()) {
    return false;
  }
  return PersistTask(*task);
}

void AegisAgentService::RestoreUnfinishedTasks() {
  for (StoredAgentTask& stored : task_store_.LoadUnfinishedTasks()) {
    std::optional<AgentTaskScope> scope =
        AgentTaskStore::DeserializeScope(stored.scope_json);
    if (!scope) {
      continue;
    }
    std::unique_ptr<AgentTask> task;
    if (stored.state == AgentTaskState::kCompleted) {
      task = AgentTask::RestoreCompletedMonitorOwner(
          stored.task_id, stored.goal_summary, stored.mode, std::move(*scope),
          stored.tool_calls_used, stored.model_calls_used,
          stored.network_requests_used, stored.created_at);
    } else {
      task = AgentTask::RestoreForRecovery(
          stored.task_id, stored.goal_summary, stored.mode, std::move(*scope),
          stored.state, stored.tool_calls_used, stored.model_calls_used,
          stored.network_requests_used, stored.created_at);
    }
    if (!task) {
      continue;
    }
    const std::string task_id = task->id();
    if (stored.state != AgentTaskState::kCompleted &&
        task->HasExpired(base::Time::Now())) {
      task->TransitionTo(AgentTaskState::kExpired,
                         "task expired while browser was closed");
    } else if (stored.state != AgentTaskState::kCompleted) {
      recovery_dispositions_[task_id] = stored.recovery;
    }
    task_has_external_side_effect_[task_id] = stored.has_external_side_effect;
    AgentTask* restored = task.get();
    tasks_.emplace(task_id, std::move(task));
    if (stored.state == AgentTaskState::kCompleted) {
      continue;
    }
    std::optional<StoredAgentPlan> stored_plan =
        task_store_.LoadPlan(task_id, restored->scope(), tool_registry_);
    if (stored_plan) {
      plan_progress_[task_id] = {stored_plan->next_step, stored_plan->attempt};
      plans_[task_id] = std::move(stored_plan->plan);
    } else if (!IsTerminalState(restored->state())) {
      recovery_dispositions_.erase(task_id);
      restored->TransitionTo(AgentTaskState::kFailed,
                             "stored task has no valid execution plan");
    }
    PersistTask(*restored);
  }
}

void AegisAgentService::RestoreMonitors() {
  if (!base::FeatureList::IsEnabled(aegis::features::kAegisAgentWorkflows)) {
    return;
  }
  std::vector<AgentMonitorDefinition> valid;
  for (AgentMonitorDefinition& monitor : task_store_.LoadMonitors()) {
    const AgentTask* task = GetTask(monitor.task_id);
    if (!task || task->mode() != AgentMode::kAutomate ||
        task->state() == AgentTaskState::kFailed ||
        task->state() == AgentTaskState::kCancelled ||
        task->state() == AgentTaskState::kExpired ||
        std::ranges::find(task->scope().allowed_origins, monitor.origin) ==
            task->scope().allowed_origins.end()) {
      task_store_.DeleteMonitor(monitor.monitor_id);
      continue;
    }
    valid.push_back(std::move(monitor));
  }
  monitor_scheduler_.Restore(std::move(valid), base::Time::Now());
  for (const AgentMonitorDefinition& monitor : monitor_scheduler_.Snapshot()) {
    task_store_.SaveMonitor(monitor);
  }
  ScheduleMonitorTimer();
}

}  // namespace aegis::agent
