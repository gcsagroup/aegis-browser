// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_task_store.h"

#include <memory>
#include <string>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {

AgentTaskScope StoreTestScope() {
  AgentTaskScope scope;
  scope.allowed_origins = {
      url::Origin::Create(GURL("https://fixture.example/"))};
  scope.allowed_tools = {"page.observe", "bookmark.apply"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage,
                                AgentDataClass::kBookmarks};
  scope.model_destination.provider = "aegis-local";
  scope.model_destination.model = "fixture";
  return scope;
}

TEST(AegisAgentTaskStoreTest, SavesOnlyRedactedMetadataAndRecoversSafely) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const base::FilePath path = temp_dir.GetPath().AppendASCII("tasks.sqlite");
  {
    AgentTaskStore store(path);
    ASSERT_TRUE(store.Initialize());
    AgentTask task("task-1", "goal stays in memory", AgentMode::kAct,
                   StoreTestScope());
    ASSERT_TRUE(task.TransitionTo(AgentTaskState::kPlanning, "test"));
    ASSERT_TRUE(
        task.TransitionTo(AgentTaskState::kAwaitingTaskConsent, "test"));
    ASSERT_TRUE(task.TransitionTo(AgentTaskState::kRunning, "test"));
    EXPECT_TRUE(task.ConsumeToolCall());
    EXPECT_TRUE(task.ConsumeToolCall());
    EXPECT_TRUE(task.ConsumeModelCall());
    EXPECT_TRUE(task.ConsumeNetworkRequest());
    EXPECT_TRUE(store.SaveTask(task, "Organize selected bookmarks",
                               /*has_external_side_effect=*/false));
    EXPECT_TRUE(store.AppendActionSummary(task.id(), "action-1", "page.observe",
                                          AgentRiskLevel::kR0ReadOnly, true,
                                          "Browser verification passed"));
    EXPECT_FALSE(store.AppendActionSummary(
        task.id(), "action-secret", "page.observe", AgentRiskLevel::kR0ReadOnly,
        true, "Authorization: Bearer highly-sensitive-token"));

    std::vector<StoredAgentTask> recovered = store.LoadUnfinishedTasks();
    ASSERT_EQ(recovered.size(), 1u);
    EXPECT_EQ(recovered[0].task_id, task.id());
    EXPECT_EQ(recovered[0].recovery,
              StoredAgentTask::RecoveryDisposition::kResumeReadOnly);
    EXPECT_EQ(recovered[0].tool_calls_used, 2);
    EXPECT_EQ(recovered[0].model_calls_used, 1);
    EXPECT_EQ(recovered[0].network_requests_used, 1);
    std::optional<AgentTaskScope> restored_scope =
        AgentTaskStore::DeserializeScope(recovered[0].scope_json);
    ASSERT_TRUE(restored_scope);
    EXPECT_EQ(restored_scope->allowed_tools, task.scope().allowed_tools);
    EXPECT_EQ(restored_scope->budgets.max_tool_calls,
              task.scope().budgets.max_tool_calls);

    EXPECT_TRUE(store.SaveTask(task, "Bookmark move approved",
                               /*has_external_side_effect=*/true));
    recovered = store.LoadUnfinishedTasks();
    ASSERT_EQ(recovered.size(), 1u);
    EXPECT_EQ(recovered[0].recovery,
              StoredAgentTask::RecoveryDisposition::kRequireActionApproval);
  }

  std::string database_bytes;
  ASSERT_TRUE(base::ReadFileToString(path, &database_bytes));
  EXPECT_EQ(database_bytes.find("highly-sensitive-token"), std::string::npos);
  EXPECT_EQ(database_bytes.find("goal stays in memory"), std::string::npos);
}

TEST(AegisAgentTaskStoreTest, RejectsBroadenedOrMalformedStoredScope) {
  EXPECT_FALSE(AgentTaskStore::DeserializeScope("not-json"));
  EXPECT_FALSE(AgentTaskStore::DeserializeScope(R"({})"));
  EXPECT_FALSE(AgentTaskStore::DeserializeScope(R"({
    "allowed_origins":["https://fixture.example"],
    "allowed_tab_ids":[],
    "allowed_tools":["page.observe"],
    "allowed_data_classes":[6],
    "budgets":{"max_tabs":8,"max_tool_calls":50,"max_model_calls":20,
               "max_network_requests":100,"max_duration_seconds":1800},
    "model_destination":{"kind":0,"provider":"local","endpoint":"",
                         "model":"fixture"}
  })"));
}

TEST(AegisAgentTaskStoreTest, CorruptDatabaseFailsClosed) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const base::FilePath path = temp_dir.GetPath().AppendASCII("tasks.sqlite");
  ASSERT_TRUE(base::WriteFile(path, "not a sqlite database"));

  AgentTaskStore store(path);
  EXPECT_FALSE(store.Initialize());
  EXPECT_TRUE(store.LoadUnfinishedTasks().empty());
}

TEST(AegisAgentTaskStoreTest, PrunesExpiredTaskPlanAndActionMetadata) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  AgentTaskStore store(
      temp_dir.GetPath().AppendASCII("retention-tasks.sqlite"));
  ASSERT_TRUE(store.Initialize());
  AgentTask task("task-retention", "retention fixture", AgentMode::kAsk,
                 StoreTestScope());
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kPlanning, "test"));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kAwaitingTaskConsent, "test"));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kRunning, "test"));
  ASSERT_TRUE(store.SaveTask(task, task.goal(), false));
  AgentTaskPlan plan;
  plan.summary = "Retention plan";
  plan.scope = task.scope();
  plan.steps.push_back({.step_id = "observe",
                        .title = "Observe",
                        .tool_name = "page.observe",
                        .risk = AgentRiskLevel::kR0ReadOnly});
  ASSERT_TRUE(store.SavePlan(task.id(), plan, 0, 0));
  ASSERT_TRUE(store.AppendActionSummary(
      task.id(), "action-retention", "page.observe",
      AgentRiskLevel::kR0ReadOnly, true, "Browser verified"));

  const base::Time future = base::Time::Now() + base::Days(1);
  EXPECT_TRUE(store.Prune(future, future));
  EXPECT_TRUE(store.LoadUnfinishedTasks().empty());
  AgentToolRegistry registry;
  EXPECT_FALSE(store.LoadPlan(task.id(), task.scope(), registry));
}

TEST(AegisAgentTaskStoreTest,
     PersistsEncryptedMonitorTargetsAndRestoresSingleCatchup) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const base::FilePath path = temp_dir.GetPath().AppendASCII("tasks.sqlite");
  const base::Time scheduled_at = base::Time::Now() - base::Hours(2);
  {
    AgentTaskStore store(path);
    ASSERT_TRUE(store.Initialize());
    AgentMonitorDefinition monitor;
    monitor.monitor_id = "monitor-1";
    monitor.task_id = "task-1";
    monitor.kind = AgentMonitorKind::kUrlStatus;
    monitor.origin =
        url::Origin::Create(GURL("https://fixture.example/private/path"));
    monitor.target_hash =
        "sha256:6ef20e80f85c7cf67020e74bcb78091f43be70e2e29b4314b27e5959"
        "5064bb88";
    monitor.target_ciphertext = "fixture-encrypted-bytes";
    monitor.last_value_hash = "sha256:baseline";
    monitor.interval = base::Minutes(30);
    monitor.next_run = scheduled_at;
    ASSERT_TRUE(store.SaveMonitor(monitor));
  }

  AgentTaskStore recovered_store(path);
  ASSERT_TRUE(recovered_store.Initialize());
  std::vector<AgentMonitorDefinition> recovered =
      recovered_store.LoadMonitors();
  ASSERT_EQ(recovered.size(), 1u);
  EXPECT_EQ(recovered[0].monitor_id, "monitor-1");
  EXPECT_EQ(recovered[0].origin.Serialize(), "https://fixture.example");
  EXPECT_EQ(recovered[0].target_ciphertext, "fixture-encrypted-bytes");
  EXPECT_EQ(recovered[0].last_value_hash, "sha256:baseline");
  EXPECT_EQ(recovered[0].next_run, scheduled_at);

  const base::Time restarted_at = base::Time::Now();
  AgentMonitorScheduler scheduler;
  scheduler.Restore(std::move(recovered), restarted_at);
  std::vector<AgentMonitorDefinition> claimed =
      scheduler.ClaimDue(restarted_at);
  ASSERT_EQ(claimed.size(), 1u);
  EXPECT_EQ(claimed[0].last_run, restarted_at);
  EXPECT_EQ(scheduler.ClaimDue(restarted_at).size(), 0u);

  EXPECT_TRUE(recovered_store.DeleteMonitor("monitor-1"));
  EXPECT_TRUE(recovered_store.LoadMonitors().empty());

  std::string database_bytes;
  ASSERT_TRUE(base::ReadFileToString(path, &database_bytes));
  EXPECT_EQ(database_bytes.find("/private/path"), std::string::npos);
}

TEST(AegisAgentTaskStoreTest,
     LoadsCompletedAutomateOwnerOnlyWhileMonitorExists) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  AgentTaskStore store(
      temp_dir.GetPath().AppendASCII("completed-monitor.sqlite"));
  ASSERT_TRUE(store.Initialize());

  AgentTask task("task-completed-monitor", "monitor selected page",
                 AgentMode::kAutomate, StoreTestScope());
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kPlanning, "test"));
  ASSERT_TRUE(
      task.TransitionTo(AgentTaskState::kAwaitingTaskConsent, "test"));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kRunning, "test"));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kVerifying, "test"));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kCompleted, "test"));
  ASSERT_TRUE(store.SaveTask(task, "Completed monitor owner", false));
  EXPECT_TRUE(store.LoadUnfinishedTasks().empty());

  AgentMonitorDefinition monitor;
  monitor.monitor_id = "monitor-completed-owner";
  monitor.task_id = task.id();
  monitor.kind = AgentMonitorKind::kUrlStatus;
  monitor.origin = url::Origin::Create(GURL("https://fixture.example/path"));
  monitor.target_hash = "sha256:completed-monitor-target";
  monitor.target_ciphertext = "encrypted-target";
  monitor.interval = base::Minutes(15);
  monitor.next_run = base::Time::Now() + monitor.interval;
  ASSERT_TRUE(store.SaveMonitor(monitor));

  std::vector<StoredAgentTask> recovered = store.LoadUnfinishedTasks();
  ASSERT_EQ(recovered.size(), 1u);
  EXPECT_EQ(recovered[0].state, AgentTaskState::kCompleted);
  EXPECT_EQ(recovered[0].mode, AgentMode::kAutomate);
  std::optional<AgentTaskScope> scope =
      AgentTaskStore::DeserializeScope(recovered[0].scope_json);
  ASSERT_TRUE(scope);
  std::unique_ptr<AgentTask> owner = AgentTask::RestoreCompletedMonitorOwner(
      recovered[0].task_id, recovered[0].goal_summary, recovered[0].mode,
      std::move(*scope), recovered[0].tool_calls_used,
      recovered[0].model_calls_used, recovered[0].network_requests_used,
      recovered[0].created_at);
  ASSERT_TRUE(owner);
  EXPECT_EQ(owner->state(), AgentTaskState::kCompleted);

  EXPECT_TRUE(store.DeleteMonitor(monitor.monitor_id));
  EXPECT_TRUE(store.LoadUnfinishedTasks().empty());
}

TEST(AegisAgentTaskStoreTest, PersistsRedactedPlanAndExecutionCursor) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const base::FilePath path = temp_dir.GetPath().AppendASCII("tasks.sqlite");
  AgentTaskStore store(path);
  ASSERT_TRUE(store.Initialize());
  AgentTask task("task-plan", "goal stays in memory", AgentMode::kAct,
                 StoreTestScope());
  ASSERT_TRUE(store.SaveTask(task, "Redacted task", false));

  AgentTaskPlan plan;
  plan.summary = "password must never persist";
  plan.scope = StoreTestScope();
  plan.steps.push_back({.step_id = "observe-1",
                        .title = "Sensitive user-authored step title",
                        .tool_name = "page.observe",
                        .risk = AgentRiskLevel::kR0ReadOnly});
  ASSERT_TRUE(store.SavePlan(task.id(), plan, /*next_step=*/0,
                             /*attempt=*/1));
  AgentToolRegistry registry;
  std::optional<StoredAgentPlan> recovered =
      store.LoadPlan(task.id(), plan.scope, registry);
  ASSERT_TRUE(recovered);
  EXPECT_EQ(recovered->plan.summary, "Validated task plan");
  EXPECT_EQ(recovered->next_step, 0u);
  EXPECT_EQ(recovered->attempt, 1);
  ASSERT_EQ(recovered->plan.steps.size(), 1u);
  EXPECT_EQ(recovered->plan.steps[0].tool_name, "page.observe");

  std::string database_bytes;
  ASSERT_TRUE(base::ReadFileToString(path, &database_bytes));
  EXPECT_EQ(database_bytes.find("password must never persist"),
            std::string::npos);
  EXPECT_EQ(database_bytes.find("Sensitive user-authored step title"),
            std::string::npos);
  EXPECT_TRUE(store.DeleteTask(task.id()));
  EXPECT_FALSE(store.LoadPlan(task.id(), plan.scope, registry));
}

}  // namespace
}  // namespace aegis::agent
