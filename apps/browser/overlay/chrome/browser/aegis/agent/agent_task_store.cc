// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_task_store.h"

#include <algorithm>
#include <cctype>
#include <string_view>
#include <utility>

#include "base/containers/flat_set.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_util.h"
#include "sql/statement.h"
#include "sql/transaction.h"
#include "url/origin.h"

namespace aegis::agent {

namespace {

// v9 增加用户明确保存的加密研究记录，旧版本不能覆写该资料。
constexpr int kCurrentVersion = 9;
constexpr int kCompatibleVersion = 9;
constexpr size_t kMaxSummaryBytes = 4096;

constexpr char kCreateResearchSql[] = R"(
  CREATE TABLE IF NOT EXISTS agent_saved_research(
    id TEXT PRIMARY KEY NOT NULL,
    ciphertext BLOB NOT NULL,
    saved_us INTEGER NOT NULL
  ))";

constexpr char kCreateTasksSql[] = R"(
  CREATE TABLE IF NOT EXISTS agent_tasks(
    task_id TEXT PRIMARY KEY NOT NULL,
    state INTEGER NOT NULL,
    mode INTEGER NOT NULL,
    goal_summary TEXT NOT NULL,
    scope_json TEXT NOT NULL,
    has_external_side_effect INTEGER NOT NULL,
    tool_calls_used INTEGER NOT NULL DEFAULT 0,
    model_calls_used INTEGER NOT NULL DEFAULT 0,
    network_requests_used INTEGER NOT NULL DEFAULT 0,
    created_us INTEGER NOT NULL,
    updated_us INTEGER NOT NULL
  ))";

constexpr char kCreateActionsSql[] = R"(
  CREATE TABLE IF NOT EXISTS agent_action_log(
    task_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    risk INTEGER NOT NULL,
    ok INTEGER NOT NULL,
    redacted_summary TEXT NOT NULL,
    created_us INTEGER NOT NULL,
    PRIMARY KEY(task_id, action_id)
  ))";

constexpr char kCreateMonitorsSql[] = R"(
  CREATE TABLE IF NOT EXISTS agent_monitors(
    monitor_id TEXT PRIMARY KEY NOT NULL,
    task_id TEXT NOT NULL,
    kind INTEGER NOT NULL,
    origin TEXT NOT NULL,
    target_hash TEXT NOT NULL,
    target_ciphertext BLOB NOT NULL DEFAULT X'',
    last_value_hash TEXT NOT NULL DEFAULT '',
    interval_seconds INTEGER NOT NULL,
    next_run_us INTEGER NOT NULL,
    last_run_us INTEGER NOT NULL,
    consecutive_failures INTEGER NOT NULL,
    enabled INTEGER NOT NULL,
    last_check_status INTEGER NOT NULL DEFAULT 0,
    last_http_status INTEGER NOT NULL DEFAULT 0,
    last_observation_ciphertext BLOB NOT NULL DEFAULT X''
  ))";

constexpr char kCreatePlansSql[] = R"(
  CREATE TABLE IF NOT EXISTS agent_plans(
    task_id TEXT PRIMARY KEY NOT NULL,
    schema_version INTEGER NOT NULL,
    redacted_summary TEXT NOT NULL,
    steps_json TEXT NOT NULL,
    next_step INTEGER NOT NULL,
    attempt INTEGER NOT NULL,
    updated_us INTEGER NOT NULL
  ))";

bool IsValidStoredState(int state) {
  return state >= static_cast<int>(AgentTaskState::kDraft) &&
         state <= static_cast<int>(AgentTaskState::kExpired);
}

bool IsValidStoredMode(int mode) {
  return mode >= static_cast<int>(AgentMode::kAsk) &&
         mode <= static_cast<int>(AgentMode::kAutomate);
}

bool IsSafePlanStepId(std::string_view value) {
  return !value.empty() && value.size() <= 64u &&
         std::ranges::all_of(value, [](unsigned char character) {
           return base::IsAsciiAlphaNumeric(character) || character == '-' ||
                  character == '_' || character == '.';
         });
}

std::optional<std::string> SerializePlanSteps(const AgentTaskPlan& plan) {
  if (plan.steps.empty() || plan.steps.size() > 50u) {
    return std::nullopt;
  }
  base::ListValue steps;
  for (const AgentPlanStep& step : plan.steps) {
    if (!IsSafePlanStepId(step.step_id) || step.tool_name.empty() ||
        step.tool_name.size() > 128u) {
      return std::nullopt;
    }
    base::DictValue value;
    value.Set("id", step.step_id);
    value.Set("tool", step.tool_name);
    steps.Append(std::move(value));
  }
  std::string json;
  return base::JSONWriter::Write(steps, &json)
             ? std::make_optional(std::move(json))
             : std::nullopt;
}

}  // namespace

AgentTaskStore::AgentTaskStore(base::FilePath database_path, bool in_memory)
    : database_path_(std::move(database_path)),
      in_memory_(in_memory),
      database_("AegisAgent") {}

AgentTaskStore::~AgentTaskStore() = default;

bool AgentTaskStore::Initialize() {
  if (initialized_) {
    return true;
  }
  if (!(in_memory_ ? database_.OpenInMemory()
                   : database_.Open(database_path_))) {
    return false;
  }
  sql::Transaction transaction(&database_);
  if (!transaction.Begin() ||
      !meta_table_.Init(&database_, kCurrentVersion, kCompatibleVersion) ||
      meta_table_.GetVersionNumber() > kCurrentVersion ||
      meta_table_.GetCompatibleVersionNumber() > kCurrentVersion ||
      !database_.Execute(kCreateTasksSql) ||
      !database_.Execute(kCreateActionsSql) ||
      !database_.Execute(kCreateMonitorsSql) ||
      !database_.Execute(kCreatePlansSql) ||
      !database_.Execute(kCreateResearchSql)) {
    database_.Close();
    return false;
  }
  if (meta_table_.GetVersionNumber() == 1 &&
      (!database_.Execute(
           "ALTER TABLE agent_tasks ADD COLUMN tool_calls_used INTEGER NOT "
           "NULL DEFAULT 0") ||
       !database_.Execute(
           "ALTER TABLE agent_tasks ADD COLUMN model_calls_used INTEGER NOT "
           "NULL DEFAULT 0") ||
       !database_.Execute(
           "ALTER TABLE agent_tasks ADD COLUMN network_requests_used INTEGER "
           "NOT NULL DEFAULT 0") ||
       !meta_table_.SetVersionNumber(2))) {
    database_.Close();
    return false;
  }
  if (meta_table_.GetVersionNumber() == 2 && !meta_table_.SetVersionNumber(3)) {
    database_.Close();
    return false;
  }
  if (meta_table_.GetVersionNumber() == 3 && !meta_table_.SetVersionNumber(4)) {
    database_.Close();
    return false;
  }
  if (meta_table_.GetVersionNumber() == 4 &&
      (!database_.Execute(
           "ALTER TABLE agent_monitors ADD COLUMN target_ciphertext BLOB NOT "
           "NULL DEFAULT X''") ||
       !database_.Execute(
           "ALTER TABLE agent_monitors ADD COLUMN last_value_hash TEXT NOT "
           "NULL DEFAULT ''") ||
       !meta_table_.SetVersionNumber(5))) {
    database_.Close();
    return false;
  }
  if (meta_table_.GetVersionNumber() == 5 &&
      (!database_.Execute(
           "ALTER TABLE agent_monitors ADD COLUMN last_check_status INTEGER "
           "NOT NULL DEFAULT 0") ||
       !database_.Execute(
           "ALTER TABLE agent_monitors ADD COLUMN last_http_status INTEGER "
           "NOT NULL DEFAULT 0") ||
       !meta_table_.SetVersionNumber(6))) {
    database_.Close();
    return false;
  }
  if (meta_table_.GetVersionNumber() == 6 &&
      (!database_.Execute(
           "ALTER TABLE agent_monitors ADD COLUMN last_observation_ciphertext "
           "BLOB NOT NULL DEFAULT X''") ||
       !meta_table_.SetVersionNumber(7))) {
    database_.Close();
    return false;
  }
  if ((meta_table_.GetVersionNumber() == 7 ||
       meta_table_.GetVersionNumber() == 8) &&
      (!meta_table_.SetVersionNumber(kCurrentVersion) ||
       !meta_table_.SetCompatibleVersionNumber(kCompatibleVersion))) {
    database_.Close();
    return false;
  }
  if (meta_table_.GetVersionNumber() != kCurrentVersion ||
      !transaction.Commit()) {
    database_.Close();
    return false;
  }
  initialized_ = true;
  return true;
}

std::optional<StoredAgentState> AgentTaskStore::InitializeAndLoad(
    base::Time unfinished_before,
    base::Time completed_before) {
  if (!Initialize() || !Prune(unfinished_before, completed_before)) {
    return std::nullopt;
  }

  StoredAgentState state;
  state.tasks = LoadUnfinishedTasks();
  AgentToolRegistry registry;
  for (const StoredAgentTask& task : state.tasks) {
    if (task.state == AgentTaskState::kCompleted) {
      continue;
    }
    std::optional<AgentTaskScope> scope = DeserializeScope(task.scope_json);
    if (!scope) {
      continue;
    }
    std::optional<StoredAgentPlan> plan =
        LoadPlan(task.task_id, *scope, registry);
    if (plan) {
      state.plans.push_back(
          {.task_id = task.task_id, .stored_plan = std::move(*plan)});
    }
  }
  state.monitors = LoadMonitors();
  return state;
}

bool AgentTaskStore::SaveTask(const AgentTask& task,
                              std::string goal_summary,
                              bool has_external_side_effect) {
  AgentTaskStoreRecord record{
      .task_id = task.id(),
      .state = task.state(),
      .mode = task.mode(),
      .goal_summary = std::move(goal_summary),
      .scope = task.scope(),
      .has_external_side_effect = has_external_side_effect,
      .tool_calls_used = task.tool_calls_used(),
      .model_calls_used = task.model_calls_used(),
      .network_requests_used = task.network_requests_used(),
      .created_at = task.created_at(),
  };
  return SaveTaskRecord(std::move(record));
}

bool AgentTaskStore::SaveTaskRecord(AgentTaskStoreRecord record) {
  if (!initialized_ || record.task_id.empty() ||
      !IsSafeSummary(record.goal_summary)) {
    return false;
  }
  const std::string scope_json = SerializeScope(record.scope);
  if (scope_json.empty()) {
    return false;
  }
  sql::Transaction transaction(&database_);
  if (!transaction.Begin()) {
    return false;
  }

  sql::Statement update(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "UPDATE agent_tasks SET state=?,mode=?,goal_summary=?,scope_json=?,"
      "has_external_side_effect=?,tool_calls_used=?,model_calls_used=?,"
      "network_requests_used=?,updated_us=? WHERE task_id=?"));
  update.BindInt(0, static_cast<int>(record.state));
  update.BindInt(1, static_cast<int>(record.mode));
  update.BindString(2, record.goal_summary);
  update.BindString(3, scope_json);
  update.BindBool(4, record.has_external_side_effect);
  update.BindInt(5, record.tool_calls_used);
  update.BindInt(6, record.model_calls_used);
  update.BindInt(7, record.network_requests_used);
  update.BindInt64(8, SerializeTime(base::Time::Now()));
  update.BindString(9, record.task_id);
  if (!update.Run()) {
    return false;
  }
  if (database_.GetLastChangeCount() == 1) {
    return transaction.Commit();
  }

  sql::Statement insert(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "INSERT INTO agent_tasks(task_id,state,mode,goal_summary,scope_json,"
      "has_external_side_effect,tool_calls_used,model_calls_used,"
      "network_requests_used,created_us,updated_us) "
      "VALUES(?,?,?,?,?,?,?,?,?,?,?)"));
  insert.BindString(0, record.task_id);
  insert.BindInt(1, static_cast<int>(record.state));
  insert.BindInt(2, static_cast<int>(record.mode));
  insert.BindString(3, record.goal_summary);
  insert.BindString(4, scope_json);
  insert.BindBool(5, record.has_external_side_effect);
  insert.BindInt(6, record.tool_calls_used);
  insert.BindInt(7, record.model_calls_used);
  insert.BindInt(8, record.network_requests_used);
  insert.BindInt64(9, SerializeTime(record.created_at));
  insert.BindInt64(10, SerializeTime(base::Time::Now()));
  return insert.Run() && transaction.Commit();
}

bool AgentTaskStore::AppendActionSummary(const std::string& task_id,
                                         const std::string& action_id,
                                         const std::string& tool_name,
                                         AgentRiskLevel risk,
                                         bool ok,
                                         const std::string& redacted_summary) {
  if (!initialized_ || task_id.empty() || action_id.empty() ||
      tool_name.empty() || !IsSafeSummary(redacted_summary)) {
    return false;
  }
  sql::Statement statement(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "INSERT OR IGNORE INTO agent_action_log(task_id,action_id,tool_name,"
      "risk,ok,redacted_summary,created_us) VALUES(?,?,?,?,?,?,?)"));
  statement.BindString(0, task_id);
  statement.BindString(1, action_id);
  statement.BindString(2, tool_name);
  statement.BindInt(3, static_cast<int>(risk));
  statement.BindBool(4, ok);
  statement.BindString(5, redacted_summary);
  statement.BindInt64(6, SerializeTime(base::Time::Now()));
  return statement.Run() && database_.GetLastChangeCount() == 1;
}

std::vector<StoredAgentTask> AgentTaskStore::LoadUnfinishedTasks() {
  std::vector<StoredAgentTask> tasks;
  if (!initialized_) {
    return tasks;
  }
  sql::Statement statement(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "SELECT task_id,state,mode,goal_summary,scope_json,"
      "has_external_side_effect,tool_calls_used,model_calls_used,"
      "network_requests_used,created_us,updated_us FROM agent_tasks "
      "WHERE state NOT IN (10,11,12,13) OR "
      "(state=10 AND EXISTS(SELECT 1 FROM agent_monitors "
      "WHERE agent_monitors.task_id=agent_tasks.task_id)) "
      "ORDER BY updated_us ASC"));
  while (statement.Step()) {
    const int state_value = statement.ColumnInt(1);
    const int mode_value = statement.ColumnInt(2);
    if (!IsValidStoredState(state_value) || !IsValidStoredMode(mode_value)) {
      tasks.clear();
      return tasks;
    }
    StoredAgentTask task;
    task.task_id = statement.ColumnString(0);
    task.state = static_cast<AgentTaskState>(state_value);
    task.mode = static_cast<AgentMode>(mode_value);
    task.goal_summary = statement.ColumnString(3);
    task.scope_json = statement.ColumnString(4);
    task.has_external_side_effect = statement.ColumnBool(5);
    task.tool_calls_used = statement.ColumnInt(6);
    task.model_calls_used = statement.ColumnInt(7);
    task.network_requests_used = statement.ColumnInt(8);
    task.created_at = DeserializeTime(statement.ColumnInt64(9));
    task.updated_at = DeserializeTime(statement.ColumnInt64(10));
    if (task.has_external_side_effect ||
        task.state == AgentTaskState::kAwaitingActionApproval ||
        task.state == AgentTaskState::kUserTakeover) {
      task.recovery =
          StoredAgentTask::RecoveryDisposition::kRequireActionApproval;
    } else if (task.state == AgentTaskState::kAwaitingTaskConsent ||
               task.state == AgentTaskState::kPlanning ||
               task.state == AgentTaskState::kDraft) {
      task.recovery =
          StoredAgentTask::RecoveryDisposition::kRequireFreshConsent;
    } else {
      task.recovery = StoredAgentTask::RecoveryDisposition::kResumeReadOnly;
    }
    tasks.push_back(std::move(task));
  }
  if (!statement.Succeeded()) {
    tasks.clear();
  }
  return tasks;
}

bool AgentTaskStore::SavePlan(const std::string& task_id,
                              const AgentTaskPlan& plan,
                              size_t next_step,
                              int attempt) {
  if (!initialized_ || task_id.empty() ||
      plan.schema_version != kAgentSchemaVersion || !plan.scope.IsValid() ||
      next_step > plan.steps.size() || attempt < 0 || attempt > 3) {
    return false;
  }
  const std::optional<std::string> steps_json = SerializePlanSteps(plan);
  if (!steps_json) {
    return false;
  }
  const std::string summary =
      IsSafeSummary(plan.summary) ? plan.summary : "Validated task plan";
  sql::Statement statement(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "INSERT OR REPLACE INTO agent_plans("
      "task_id,schema_version,redacted_summary,steps_json,next_step,attempt,"
      "updated_us) VALUES(?,?,?,?,?,?,?)"));
  statement.BindString(0, task_id);
  statement.BindInt(1, plan.schema_version);
  statement.BindString(2, summary);
  statement.BindString(3, *steps_json);
  statement.BindInt64(4, static_cast<int64_t>(next_step));
  statement.BindInt(5, attempt);
  statement.BindInt64(6, SerializeTime(base::Time::Now()));
  return statement.Run();
}

std::optional<StoredAgentPlan> AgentTaskStore::LoadPlan(
    const std::string& task_id,
    const AgentTaskScope& scope,
    const AgentToolRegistry& registry) {
  if (!initialized_ || task_id.empty() || !scope.IsValid()) {
    return std::nullopt;
  }
  sql::Statement statement(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "SELECT schema_version,redacted_summary,steps_json,next_step,attempt "
      "FROM agent_plans WHERE task_id=?"));
  statement.BindString(0, task_id);
  if (!statement.Step()) {
    return std::nullopt;
  }
  const int schema_version = statement.ColumnInt(0);
  const std::string summary = statement.ColumnString(1);
  const std::string steps_json = statement.ColumnString(2);
  const int64_t next_step = statement.ColumnInt64(3);
  const int attempt = statement.ColumnInt(4);
  std::optional<base::Value> parsed =
      base::JSONReader::Read(steps_json, base::JSON_PARSE_RFC);
  if (schema_version != kAgentSchemaVersion || !IsSafeSummary(summary) ||
      !parsed || !parsed->is_list() || parsed->GetList().empty() ||
      parsed->GetList().size() > 50u || next_step < 0 ||
      next_step > static_cast<int64_t>(parsed->GetList().size()) ||
      attempt < 0 || attempt > 3) {
    return std::nullopt;
  }

  StoredAgentPlan stored;
  stored.plan.schema_version = schema_version;
  stored.plan.summary = summary;
  stored.plan.scope = scope;
  base::flat_set<std::string> step_ids;
  for (const base::Value& item : parsed->GetList()) {
    if (!item.is_dict() || item.GetDict().size() != 2u) {
      return std::nullopt;
    }
    const std::string* id = item.GetDict().FindString("id");
    const std::string* tool_name = item.GetDict().FindString("tool");
    const AgentToolDescriptor* descriptor =
        tool_name ? registry.Find(*tool_name) : nullptr;
    if (!id || !tool_name || !descriptor || !IsSafePlanStepId(*id) ||
        !step_ids.insert(*id).second || !scope.AllowsTool(*tool_name) ||
        !scope.AllowsDataClass(descriptor->data_class)) {
      return std::nullopt;
    }
    stored.plan.steps.push_back(AgentPlanStep{
        .step_id = *id,
        .title = "Recovered validated step",
        .tool_name = *tool_name,
        .risk = scope.restrict_to_current_page && *tool_name == "page.click"
                    ? AgentRiskLevel::kR2ExternalSideEffect
                    : descriptor->risk});
  }
  stored.next_step = static_cast<size_t>(next_step);
  stored.attempt = attempt;
  return stored;
}

bool AgentTaskStore::SaveMonitor(const AgentMonitorDefinition& monitor) {
  if (!initialized_ || !monitor.IsValid() || monitor.session_only ||
      (!monitor.last_observation.empty() &&
       monitor.last_observation_ciphertext.empty())) {
    return false;
  }
  sql::Statement statement(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "INSERT OR REPLACE INTO agent_monitors("
      "monitor_id,task_id,kind,origin,target_hash,target_ciphertext,"
      "last_value_hash,interval_seconds,next_run_us,last_run_us,"
      "consecutive_failures,enabled,last_check_status,last_http_status,"
      "last_observation_ciphertext) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"));
  statement.BindString(0, monitor.monitor_id);
  statement.BindString(1, monitor.task_id);
  statement.BindInt(2, static_cast<int>(monitor.kind));
  statement.BindString(3, monitor.origin.Serialize());
  statement.BindString(4, monitor.target_hash);
  statement.BindBlob(5, monitor.target_ciphertext);
  statement.BindString(6, monitor.last_value_hash);
  statement.BindInt64(7, monitor.interval.InSeconds());
  statement.BindInt64(8, SerializeTime(monitor.next_run));
  statement.BindInt64(9, SerializeTime(monitor.last_run));
  statement.BindInt(10, monitor.consecutive_failures);
  statement.BindBool(11, monitor.enabled);
  statement.BindInt(12, static_cast<int>(monitor.last_check_status));
  statement.BindInt(13, monitor.last_http_status);
  statement.BindBlob(14, monitor.last_observation_ciphertext);
  return statement.Run();
}

std::vector<AgentMonitorDefinition> AgentTaskStore::LoadMonitors() {
  std::vector<AgentMonitorDefinition> monitors;
  if (!initialized_) {
    return monitors;
  }
  sql::Statement statement(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "SELECT monitor_id,task_id,kind,origin,target_hash,target_ciphertext,"
      "last_value_hash,interval_seconds,next_run_us,last_run_us,"
      "consecutive_failures,enabled,last_check_status,last_http_status,"
      "last_observation_ciphertext "
      "FROM agent_monitors ORDER BY monitor_id ASC"));
  while (statement.Step()) {
    const int kind = statement.ColumnInt(2);
    if (kind < static_cast<int>(AgentMonitorKind::kPrice) ||
        kind > static_cast<int>(AgentMonitorKind::kUrlStatus)) {
      monitors.clear();
      return monitors;
    }
    AgentMonitorDefinition monitor;
    monitor.monitor_id = statement.ColumnString(0);
    monitor.task_id = statement.ColumnString(1);
    monitor.kind = static_cast<AgentMonitorKind>(kind);
    monitor.origin = url::Origin::Create(GURL(statement.ColumnString(3)));
    monitor.target_hash = statement.ColumnString(4);
    monitor.target_ciphertext = statement.ColumnBlobAsString(5);
    monitor.last_value_hash = statement.ColumnString(6);
    monitor.interval = base::Seconds(statement.ColumnInt64(7));
    monitor.next_run = DeserializeTime(statement.ColumnInt64(8));
    monitor.last_run = DeserializeTime(statement.ColumnInt64(9));
    monitor.consecutive_failures = statement.ColumnInt(10);
    monitor.enabled = statement.ColumnBool(11);
    monitor.last_check_status =
        static_cast<AgentMonitorCheckStatus>(statement.ColumnInt(12));
    monitor.last_http_status = statement.ColumnInt(13);
    monitor.last_observation_ciphertext = statement.ColumnBlobAsString(14);
    if (!monitor.IsValid()) {
      monitors.clear();
      return monitors;
    }
    monitors.push_back(std::move(monitor));
  }
  if (!statement.Succeeded()) {
    monitors.clear();
  }
  return monitors;
}

bool AgentTaskStore::DeleteMonitor(const std::string& monitor_id) {
  if (!initialized_ || monitor_id.empty()) {
    return false;
  }
  sql::Statement statement(database_.GetCachedStatement(
      SQL_FROM_HERE, "DELETE FROM agent_monitors WHERE monitor_id=?"));
  statement.BindString(0, monitor_id);
  return statement.Run() && database_.GetLastChangeCount() == 1;
}

bool AgentTaskStore::SaveResearch(StoredAgentResearch research) {
  if (!initialized_ || research.id.empty() || research.id.size() > 64u ||
      research.ciphertext.empty() || research.ciphertext.size() > 69632u ||
      research.saved_at.is_null()) {
    return false;
  }
  sql::Transaction transaction(&database_);
  if (!transaction.Begin()) {
    return false;
  }
  sql::Statement count(database_.GetCachedStatement(
      SQL_FROM_HERE, "SELECT count(*) FROM agent_saved_research WHERE id<>?"));
  count.BindString(0, research.id);
  // 达到容量后要求用户删除旧项目，不静默覆盖其他已保存结果。
  if (!count.Step() || count.ColumnInt(0) >= 20) {
    return false;
  }
  count.Reset(true);
  sql::Statement write(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "INSERT OR REPLACE INTO agent_saved_research(id,ciphertext,saved_us) "
      "VALUES(?,?,?)"));
  write.BindString(0, research.id);
  write.BindBlob(1, research.ciphertext);
  write.BindInt64(2, SerializeTime(research.saved_at));
  return write.Run() && transaction.Commit();
}

std::optional<std::vector<StoredAgentResearch>> AgentTaskStore::LoadResearch() {
  std::vector<StoredAgentResearch> result;
  if (!initialized_) {
    return std::nullopt;
  }
  sql::Statement read(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "SELECT id,ciphertext,saved_us FROM agent_saved_research ORDER BY "
      "saved_us DESC LIMIT 20"));
  while (read.Step()) {
    auto id = read.ColumnString(0);
    auto ciphertext = read.ColumnBlobAsString(1);
    if (id.empty() || id.size() > 64u || ciphertext.empty() ||
        ciphertext.size() > 69632u) {
      return std::nullopt;
    }
    result.push_back({.id = std::move(id),
                      .ciphertext = std::move(ciphertext),
                      .saved_at = DeserializeTime(read.ColumnInt64(2))});
  }
  if (!read.Succeeded()) {
    return std::nullopt;
  }
  return result;
}

bool AgentTaskStore::DeleteResearch(const std::string& id) {
  if (!initialized_ || id.empty() || id.size() > 64u) {
    return false;
  }
  sql::Statement statement(database_.GetCachedStatement(
      SQL_FROM_HERE, "DELETE FROM agent_saved_research WHERE id=?"));
  statement.BindString(0, id);
  return statement.Run() && database_.GetLastChangeCount() == 1;
}

// static
std::optional<AgentTaskScope> AgentTaskStore::DeserializeScope(
    std::string_view scope_json) {
  std::optional<base::Value> parsed =
      base::JSONReader::Read(scope_json, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    return std::nullopt;
  }
  const base::DictValue& value = parsed->GetDict();
  const base::ListValue* origins = value.FindList("allowed_origins");
  const base::ListValue* tab_ids = value.FindList("allowed_tab_ids");
  const base::ListValue* tools = value.FindList("allowed_tools");
  const base::ListValue* data_classes = value.FindList("allowed_data_classes");
  const base::DictValue* budgets = value.FindDict("budgets");
  const base::DictValue* destination = value.FindDict("model_destination");
  const base::Value* metadata_window = value.Find("tab_metadata_window_id");
  const base::Value* current_page = value.Find("restrict_to_current_page");
  const base::Value* selected_pages = value.Find("selected_pages_research");
  const base::Value* selected_group = value.Find("selected_tab_group");
  if (value.size() !=
          6u + (metadata_window ? 1u : 0u) + (current_page ? 1u : 0u) +
              (selected_pages ? 1u : 0u) + (selected_group ? 1u : 0u) ||
      (current_page && !current_page->is_bool()) ||
      (selected_pages && !selected_pages->is_bool()) ||
      (selected_group && !selected_group->is_bool()) ||
      (metadata_window && !metadata_window->is_int()) || !origins || !tab_ids ||
      !tools || !data_classes || !budgets || !destination ||
      budgets->size() != 5u || destination->size() != 4u ||
      origins->size() > 64u || tab_ids->size() > 20u || tools->size() > 128u ||
      data_classes->size() > 7u) {
    return std::nullopt;
  }

  AgentTaskScope scope;
  scope.tab_metadata_window_id =
      metadata_window ? metadata_window->GetInt() : 0;
  scope.restrict_to_current_page = current_page && current_page->GetBool();
  scope.selected_pages_research = selected_pages && selected_pages->GetBool();
  scope.selected_tab_group = selected_group && selected_group->GetBool();
  for (const base::Value& item : *origins) {
    if (!item.is_string()) {
      return std::nullopt;
    }
    const url::Origin origin = url::Origin::Create(GURL(item.GetString()));
    if (origin.opaque() || std::ranges::find(scope.allowed_origins, origin) !=
                               scope.allowed_origins.end()) {
      return std::nullopt;
    }
    scope.allowed_origins.push_back(origin);
  }
  for (const base::Value& item : *tab_ids) {
    if (!item.is_int() || !scope.allowed_tab_ids.insert(item.GetInt()).second) {
      return std::nullopt;
    }
  }
  for (const base::Value& item : *tools) {
    if (!item.is_string() || item.GetString().empty() ||
        !scope.allowed_tools.insert(item.GetString()).second) {
      return std::nullopt;
    }
  }
  for (const base::Value& item : *data_classes) {
    if (!item.is_int() || item.GetInt() < 0 ||
        item.GetInt() > static_cast<int>(AgentDataClass::kSecret) ||
        !scope.allowed_data_classes
             .insert(static_cast<AgentDataClass>(item.GetInt()))
             .second) {
      return std::nullopt;
    }
  }

  const std::optional<int> max_tabs = budgets->FindInt("max_tabs");
  const std::optional<int> max_tool_calls = budgets->FindInt("max_tool_calls");
  const std::optional<int> max_model_calls =
      budgets->FindInt("max_model_calls");
  const std::optional<int> max_network_requests =
      budgets->FindInt("max_network_requests");
  const std::optional<int> max_duration_seconds =
      budgets->FindInt("max_duration_seconds");
  const std::optional<int> destination_kind = destination->FindInt("kind");
  const std::string* provider = destination->FindString("provider");
  const std::string* endpoint = destination->FindString("endpoint");
  const std::string* model = destination->FindString("model");
  if (!max_tabs || !max_tool_calls || !max_model_calls ||
      !max_network_requests || !max_duration_seconds || !destination_kind ||
      *destination_kind < 0 ||
      *destination_kind >
          static_cast<int>(AgentModelDestination::Kind::kCloud) ||
      !provider || !endpoint || !model) {
    return std::nullopt;
  }
  scope.budgets.max_tabs = *max_tabs;
  scope.budgets.max_tool_calls = *max_tool_calls;
  scope.budgets.max_model_calls = *max_model_calls;
  scope.budgets.max_network_requests = *max_network_requests;
  scope.budgets.max_duration = base::Seconds(*max_duration_seconds);
  scope.model_destination.kind =
      static_cast<AgentModelDestination::Kind>(*destination_kind);
  scope.model_destination.provider = *provider;
  scope.model_destination.endpoint = *endpoint;
  scope.model_destination.model = *model;
  return scope.IsValid() ? std::make_optional(std::move(scope)) : std::nullopt;
}

bool AgentTaskStore::DeleteTask(const std::string& task_id) {
  if (!initialized_ || task_id.empty()) {
    return false;
  }
  sql::Transaction transaction(&database_);
  if (!transaction.Begin()) {
    return false;
  }
  sql::Statement delete_actions(database_.GetCachedStatement(
      SQL_FROM_HERE, "DELETE FROM agent_action_log WHERE task_id=?"));
  delete_actions.BindString(0, task_id);
  sql::Statement delete_monitors(database_.GetCachedStatement(
      SQL_FROM_HERE, "DELETE FROM agent_monitors WHERE task_id=?"));
  delete_monitors.BindString(0, task_id);
  sql::Statement delete_plan(database_.GetCachedStatement(
      SQL_FROM_HERE, "DELETE FROM agent_plans WHERE task_id=?"));
  delete_plan.BindString(0, task_id);
  sql::Statement delete_task(database_.GetCachedStatement(
      SQL_FROM_HERE, "DELETE FROM agent_tasks WHERE task_id=?"));
  delete_task.BindString(0, task_id);
  return delete_actions.Run() && delete_monitors.Run() && delete_plan.Run() &&
         delete_task.Run() && transaction.Commit();
}

bool AgentTaskStore::Prune(base::Time unfinished_before,
                           base::Time completed_before) {
  if (!initialized_) {
    return false;
  }
  sql::Transaction transaction(&database_);
  if (!transaction.Begin()) {
    return false;
  }
  sql::Statement delete_actions(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "DELETE FROM agent_action_log WHERE task_id IN (SELECT task_id FROM "
      "agent_tasks WHERE (state IN (10,11,12,13) AND updated_us < ?) OR "
      "(state NOT IN (10,11,12,13) AND updated_us < ?))"));
  delete_actions.BindInt64(0, SerializeTime(completed_before));
  delete_actions.BindInt64(1, SerializeTime(unfinished_before));
  sql::Statement delete_monitors(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "DELETE FROM agent_monitors WHERE task_id IN (SELECT task_id FROM "
      "agent_tasks WHERE (state IN (10,11,12,13) AND updated_us < ?) OR "
      "(state NOT IN (10,11,12,13) AND updated_us < ?))"));
  delete_monitors.BindInt64(0, SerializeTime(completed_before));
  delete_monitors.BindInt64(1, SerializeTime(unfinished_before));
  sql::Statement delete_plans(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "DELETE FROM agent_plans WHERE task_id IN (SELECT task_id FROM "
      "agent_tasks WHERE (state IN (10,11,12,13) AND updated_us < ?) OR "
      "(state NOT IN (10,11,12,13) AND updated_us < ?))"));
  delete_plans.BindInt64(0, SerializeTime(completed_before));
  delete_plans.BindInt64(1, SerializeTime(unfinished_before));
  sql::Statement delete_tasks(database_.GetCachedStatement(
      SQL_FROM_HERE,
      "DELETE FROM agent_tasks WHERE (state IN (10,11,12,13) AND "
      "updated_us < ?) OR (state NOT IN (10,11,12,13) AND updated_us < ?)"));
  delete_tasks.BindInt64(0, SerializeTime(completed_before));
  delete_tasks.BindInt64(1, SerializeTime(unfinished_before));
  return delete_actions.Run() && delete_monitors.Run() && delete_plans.Run() &&
         delete_tasks.Run() && transaction.Commit();
}

// static
bool AgentTaskStore::IsSafeSummary(const std::string& value) {
  if (value.empty() || value.size() > kMaxSummaryBytes ||
      !base::IsStringUTF8(value)) {
    return false;
  }
  const std::string lower = base::ToLowerASCII(value);
  constexpr std::string_view kSecretMarkers[] = {"password",
                                                 "passwd",
                                                 "authorization",
                                                 "bearer ",
                                                 "cookie=",
                                                 "cookie:",
                                                 "set-cookie",
                                                 "api_key",
                                                 "apikey",
                                                 "secret=",
                                                 "secret:",
                                                 "client_secret",
                                                 "token=",
                                                 "token:",
                                                 "access_token",
                                                 "refresh_token",
                                                 "otp=",
                                                 "otp:",
                                                 "private_key",
                                                 "begin private key",
                                                 "sessionid=",
                                                 "session_id=",
                                                 "sk-"};
  if (std::ranges::any_of(kSecretMarkers, [&lower](std::string_view marker) {
        return lower.find(marker) != std::string::npos;
      })) {
    return false;
  }
  int digit_run = 0;
  for (unsigned char character : value) {
    if ((character < 0x20 && character != '\n' && character != '\r' &&
         character != '\t') ||
        character == 0x7f) {
      return false;
    }
    digit_run = std::isdigit(character) ? digit_run + 1 : 0;
    if (digit_run >= 12) {
      return false;
    }
  }
  return true;
}

// static
std::string AgentTaskStore::SerializeScope(const AgentTaskScope& scope) {
  base::DictValue value;
  base::ListValue origins;
  for (const url::Origin& origin : scope.allowed_origins) {
    origins.Append(origin.Serialize());
  }
  value.Set("allowed_origins", std::move(origins));
  base::ListValue tab_ids;
  for (int32_t tab_id : scope.allowed_tab_ids) {
    tab_ids.Append(tab_id);
  }
  value.Set("allowed_tab_ids", std::move(tab_ids));
  if (scope.selected_pages_research) {
    value.Set("selected_pages_research", true);
  }
  if (scope.selected_tab_group) {
    value.Set("selected_tab_group", true);
  }
  if (scope.restrict_to_current_page) {
    value.Set("restrict_to_current_page", true);
  }
  if (scope.tab_metadata_window_id != 0) {
    value.Set("tab_metadata_window_id", scope.tab_metadata_window_id);
  }
  base::ListValue tools;
  for (const std::string& tool : scope.allowed_tools) {
    tools.Append(tool);
  }
  value.Set("allowed_tools", std::move(tools));
  base::ListValue data_classes;
  for (AgentDataClass data_class : scope.allowed_data_classes) {
    data_classes.Append(static_cast<int>(data_class));
  }
  value.Set("allowed_data_classes", std::move(data_classes));
  base::DictValue budgets;
  budgets.Set("max_tabs", scope.budgets.max_tabs);
  budgets.Set("max_tool_calls", scope.budgets.max_tool_calls);
  budgets.Set("max_model_calls", scope.budgets.max_model_calls);
  budgets.Set("max_network_requests", scope.budgets.max_network_requests);
  budgets.Set("max_duration_seconds",
              static_cast<int>(scope.budgets.max_duration.InSeconds()));
  value.Set("budgets", std::move(budgets));
  base::DictValue destination;
  destination.Set("kind", static_cast<int>(scope.model_destination.kind));
  destination.Set("provider", scope.model_destination.provider);
  destination.Set("endpoint", scope.model_destination.endpoint);
  destination.Set("model", scope.model_destination.model);
  value.Set("model_destination", std::move(destination));

  std::string output;
  return base::JSONWriter::Write(value, &output) ? output : std::string();
}

// static
int64_t AgentTaskStore::SerializeTime(base::Time time) {
  return time.ToDeltaSinceWindowsEpoch().InMicroseconds();
}

// static
base::Time AgentTaskStore::DeserializeTime(int64_t value) {
  return base::Time::FromDeltaSinceWindowsEpoch(base::Microseconds(value));
}

}  // namespace aegis::agent
