// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_task_store.h"

#include <memory>
#include <string>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/strings/string_number_conversions.h"
#include "sql/database.h"
#include "sql/meta_table.h"
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

TEST(AegisAgentTaskStoreTest, SavedResearchSurvivesRestartAndExplicitDeletion) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  const auto path = directory.GetPath().AppendASCII("research.sqlite");
  {
    AgentTaskStore store(path);
    EXPECT_FALSE(store.LoadResearch());
    ASSERT_TRUE(store.Initialize());
    EXPECT_FALSE(store.SaveResearch(
        {.id = "empty", .ciphertext = "", .saved_at = base::Time::Now()}));
    for (int i = 0; i < 20; ++i) {
      ASSERT_TRUE(store.SaveResearch(
          {.id = base::NumberToString(i),
           .ciphertext = "合成密文" + base::NumberToString(i),
           .saved_at = base::Time::Now() + base::Seconds(i)}));
    }
    EXPECT_FALSE(store.SaveResearch({.id = "overflow",
                                     .ciphertext = "ciphertext",
                                     .saved_at = base::Time::Now()}));
    EXPECT_TRUE(
        store.SaveResearch({.id = "0",
                            .ciphertext = "replacement",
                            .saved_at = base::Time::Now() + base::Hours(1)}));
  }
  AgentTaskStore store(path);
  ASSERT_TRUE(store.Initialize());
  auto records = store.LoadResearch();
  ASSERT_TRUE(records);
  ASSERT_EQ(records->size(), 20u);
  EXPECT_EQ(records->front().id, "0");
  EXPECT_EQ(records->front().ciphertext, "replacement");
  EXPECT_TRUE(store.DeleteResearch("0"));
  EXPECT_FALSE(store.DeleteResearch("0"));
  EXPECT_EQ(store.LoadResearch()->size(), 19u);
}

TEST(AegisAgentTaskStoreTest, ResearchInMemoryDoesNotCreateDiskState) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  const auto path = directory.GetPath().AppendASCII("private.sqlite");
  {
    AgentTaskStore store(path, true);
    ASSERT_TRUE(store.Initialize());
    ASSERT_TRUE(store.SaveResearch({.id = "private",
                                    .ciphertext = "session-only",
                                    .saved_at = base::Time::Now()}));
    ASSERT_EQ(store.LoadResearch()->size(), 1u);
    EXPECT_FALSE(base::PathExists(path));
  }
  AgentTaskStore next(path, true);
  ASSERT_TRUE(next.Initialize());
  EXPECT_TRUE(next.LoadResearch()->empty());
  EXPECT_FALSE(base::PathExists(path));
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

TEST(AegisAgentTaskStoreTest, InMemoryStoreNeverCreatesOrRecoversDiskState) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const base::FilePath path =
      temp_dir.GetPath().AppendASCII("incognito-tasks.sqlite");
  {
    AgentTaskStore store(path, /*in_memory=*/true);
    EXPECT_TRUE(store.is_in_memory_for_testing());
    ASSERT_TRUE(store.Initialize());
    AgentTask task("incognito-task", "ephemeral goal", AgentMode::kAsk,
                   StoreTestScope());
    ASSERT_TRUE(store.SaveTask(task, "Ephemeral task", false));
    EXPECT_EQ(store.LoadUnfinishedTasks().size(), 1u);
    EXPECT_FALSE(base::PathExists(path));
  }

  AgentTaskStore fresh_store(path, /*in_memory=*/true);
  ASSERT_TRUE(fresh_store.Initialize());
  EXPECT_TRUE(fresh_store.LoadUnfinishedTasks().empty());
  EXPECT_FALSE(base::PathExists(path));
}

TEST(AegisAgentTaskStoreTest, RoundTripsBrowserBoundWindowMetadataScope) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  AgentTaskStore store(temp_dir.GetPath().AppendASCII("tasks.sqlite"));
  ASSERT_TRUE(store.Initialize());
  AgentTaskScope scope = StoreTestScope();
  scope.allowed_tools.insert("tab.list");
  scope.allowed_data_classes.insert(AgentDataClass::kBrowserMetadata);
  scope.tab_metadata_window_id = 41;
  AgentTask task("window-metadata", "统计当前窗口标签", AgentMode::kAsk, scope);
  ASSERT_TRUE(store.SaveTask(task, "统计当前窗口标签", false));
  const auto tasks = store.LoadUnfinishedTasks();
  ASSERT_EQ(tasks.size(), 1u);
  auto restored = AgentTaskStore::DeserializeScope(tasks[0].scope_json);
  ASSERT_TRUE(restored);
  EXPECT_EQ(restored->tab_metadata_window_id, 41);
  EXPECT_TRUE(restored->IsNoBroaderThan(scope));
  EXPECT_TRUE(scope.IsNoBroaderThan(*restored));
  EXPECT_FALSE(restored->AllowsTab(41));
}

TEST(AegisAgentTaskStoreTest, RoundTripsCurrentPageScopeAndRejectsInvalidFlag) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  AgentTaskStore store(temp_dir.GetPath().AppendASCII("current-page.sqlite"));
  ASSERT_TRUE(store.Initialize());
  auto scope = StoreTestScope();
  scope.allowed_tab_ids = {7};
  scope.allowed_tools = {"page.observe", "page.click"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage};
  scope.budgets.max_tabs = 1;
  scope.restrict_to_current_page = true;
  AgentTask task("current-page", "当前页面操作", AgentMode::kAct, scope);
  ASSERT_TRUE(store.SaveTask(task, "当前页面操作", true));
  const auto tasks = store.LoadUnfinishedTasks();
  ASSERT_EQ(tasks.size(), 1u);
  auto restored = AgentTaskStore::DeserializeScope(tasks[0].scope_json);
  ASSERT_TRUE(restored);
  EXPECT_TRUE(restored->restrict_to_current_page);
  EXPECT_TRUE(restored->IsNoBroaderThan(scope));
  AgentTaskPlan plan;
  plan.summary = "当前页面操作";
  plan.scope = scope;
  plan.steps.push_back({.step_id = "click-1",
                        .title = "点击按钮",
                        .tool_name = "page.click",
                        .risk = AgentRiskLevel::kR2ExternalSideEffect});
  ASSERT_TRUE(store.SavePlan(task.id(), plan, 0, 1));
  AgentToolRegistry registry;
  const auto recovered_plan = store.LoadPlan(task.id(), *restored, registry);
  ASSERT_TRUE(recovered_plan);
  ASSERT_EQ(recovered_plan->plan.steps.size(), 1u);
  EXPECT_EQ(recovered_plan->plan.steps[0].risk,
            AgentRiskLevel::kR2ExternalSideEffect);
  std::string malformed = tasks[0].scope_json;
  const auto flag = malformed.find("\"restrict_to_current_page\":true");
  ASSERT_NE(flag, std::string::npos);
  malformed.replace(flag,
                    std::string("\"restrict_to_current_page\":true").size(),
                    "\"restrict_to_current_page\":\"true\"");
  EXPECT_FALSE(AgentTaskStore::DeserializeScope(malformed));
}

TEST(AegisAgentTaskStoreTest, RoundTripsSelectedResearchAndRejectsFlagType) {
  AgentTaskStore store(base::FilePath(), true);
  ASSERT_TRUE(store.Initialize());
  auto scope = StoreTestScope();
  scope.allowed_tab_ids = {7, 8, 9};
  scope.allowed_tools = {"page.observe"};
  scope.budgets.max_tabs = 3;
  scope.selected_pages_research = true;
  AgentTask task("research", "比较所选文章", AgentMode::kAct, scope);
  ASSERT_TRUE(store.SaveTask(task, "比较所选文章", false));
  const auto tasks = store.LoadUnfinishedTasks();
  ASSERT_EQ(tasks.size(), 1u);
  auto restored = AgentTaskStore::DeserializeScope(tasks[0].scope_json);
  ASSERT_TRUE(restored);
  EXPECT_TRUE(restored->selected_pages_research);
  EXPECT_TRUE(restored->IsNoBroaderThan(scope));
  std::string malformed = tasks[0].scope_json;
  const std::string flag = "\"selected_pages_research\":true";
  const auto offset = malformed.find(flag);
  ASSERT_NE(offset, std::string::npos);
  malformed.replace(offset, flag.size(), "\"selected_pages_research\":1");
  EXPECT_FALSE(AgentTaskStore::DeserializeScope(malformed));
}

TEST(AegisAgentTaskStoreTest, RoundTripsSelectedTabGroupAndRejectsFlagType) {
  auto scope = StoreTestScope();
  scope.allowed_origins.clear();
  scope.allowed_tab_ids = {7, 8, 9};
  scope.allowed_tools = {"tab.list", "tab.group"};
  scope.allowed_data_classes = {AgentDataClass::kBrowserMetadata};
  scope.budgets.max_tabs = 3;
  scope.selected_tab_group = true;
  ASSERT_TRUE(scope.IsValid());
  AgentTaskStore store(base::FilePath(), true);
  ASSERT_TRUE(store.Initialize());
  AgentTask task("group", "将所选标签分组", AgentMode::kAct, scope);
  ASSERT_TRUE(store.SaveTask(task, "将所选标签分组", false));
  const auto tasks = store.LoadUnfinishedTasks();
  ASSERT_EQ(tasks.size(), 1u);
  const auto& encoded = tasks[0].scope_json;
  auto restored = AgentTaskStore::DeserializeScope(encoded);
  ASSERT_TRUE(restored);
  EXPECT_TRUE(restored->selected_tab_group);
  EXPECT_TRUE(restored->IsNoBroaderThan(scope));
  std::string malformed = encoded;
  const std::string flag = "\"selected_tab_group\":true";
  const auto offset = malformed.find(flag);
  ASSERT_NE(offset, std::string::npos);
  malformed.replace(offset, flag.size(), "\"selected_tab_group\":1");
  EXPECT_FALSE(AgentTaskStore::DeserializeScope(malformed));
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
    monitor.last_check_status = AgentMonitorCheckStatus::kRateLimited;
    monitor.last_http_status = 429;
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
  EXPECT_EQ(recovered[0].last_check_status,
            AgentMonitorCheckStatus::kRateLimited);
  EXPECT_EQ(recovered[0].last_http_status, 429);
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
     MigratesVersionFiveMonitorWithoutLosingEncryptedTarget) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const auto path = temp_dir.GetPath().AppendASCII("version-five.sqlite");
  {
    AgentTaskStore store(path);
    ASSERT_TRUE(store.Initialize());
    AgentMonitorDefinition monitor;
    monitor.monitor_id = "migrate-monitor";
    monitor.task_id = "migrate-owner";
    monitor.origin = url::Origin::Create(GURL("https://fixture.example/"));
    monitor.target_hash = "target-hash";
    monitor.target_ciphertext = "encrypted-private-path";
    monitor.last_value_hash = "previous-result";
    monitor.next_run = base::Time::Now();
    ASSERT_TRUE(store.SaveMonitor(monitor));
  }
  {
    // 还原旧版实际没有结果状态列的数据库结构。
    sql::Database legacy("AegisAgent");
    ASSERT_TRUE(legacy.Open(path));
    ASSERT_TRUE(legacy.Execute(
        "ALTER TABLE agent_monitors DROP COLUMN last_check_status"));
    ASSERT_TRUE(legacy.Execute(
        "ALTER TABLE agent_monitors DROP COLUMN last_http_status"));
    ASSERT_TRUE(legacy.Execute(
        "ALTER TABLE agent_monitors DROP COLUMN last_observation_ciphertext"));
    sql::MetaTable meta;
    ASSERT_TRUE(meta.Init(&legacy, 5, 1));
    ASSERT_TRUE(meta.SetVersionNumber(5));
    ASSERT_TRUE(meta.SetCompatibleVersionNumber(1));
  }
  AgentTaskStore migrated(path);
  ASSERT_TRUE(migrated.Initialize());
  const auto monitors = migrated.LoadMonitors();
  ASSERT_EQ(monitors.size(), 1u);
  EXPECT_EQ(monitors[0].target_ciphertext, "encrypted-private-path");
  EXPECT_EQ(monitors[0].last_value_hash, "previous-result");
  EXPECT_EQ(monitors[0].last_check_status,
            AgentMonitorCheckStatus::kNotChecked);
  EXPECT_EQ(monitors[0].last_http_status, 0);
  EXPECT_TRUE(monitors[0].last_observation_ciphertext.empty());
}

TEST(AegisAgentTaskStoreTest, MigratesVersionSixWithoutInventingBaseline) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const auto path = temp_dir.GetPath().AppendASCII("version-six.sqlite");
  {
    AgentTaskStore store(path);
    ASSERT_TRUE(store.Initialize());
    AgentMonitorDefinition monitor;
    monitor.monitor_id = "version-six-monitor";
    monitor.task_id = "version-six-owner";
    monitor.origin = url::Origin::Create(GURL("https://fixture.example/"));
    monitor.target_hash = "target-hash";
    monitor.target_ciphertext = "encrypted-target";
    monitor.last_value_hash = "old-hash-without-measured-content";
    monitor.last_check_status = AgentMonitorCheckStatus::kSucceeded;
    monitor.last_http_status = 200;
    ASSERT_TRUE(store.SaveMonitor(monitor));
  }
  {
    sql::Database legacy("AegisAgent");
    ASSERT_TRUE(legacy.Open(path));
    ASSERT_TRUE(legacy.Execute(
        "ALTER TABLE agent_monitors DROP COLUMN last_observation_ciphertext"));
    sql::MetaTable meta;
    ASSERT_TRUE(meta.Init(&legacy, 6, 1));
    ASSERT_TRUE(meta.SetVersionNumber(6));
    ASSERT_TRUE(meta.SetCompatibleVersionNumber(1));
  }
  AgentTaskStore migrated(path);
  ASSERT_TRUE(migrated.Initialize());
  const auto monitors = migrated.LoadMonitors();
  ASSERT_EQ(monitors.size(), 1u);
  EXPECT_EQ(monitors[0].target_ciphertext, "encrypted-target");
  EXPECT_EQ(monitors[0].last_check_status, AgentMonitorCheckStatus::kSucceeded);
  EXPECT_EQ(monitors[0].last_http_status, 200);
  EXPECT_EQ(monitors[0].last_value_hash, "old-hash-without-measured-content");
  EXPECT_TRUE(monitors[0].last_observation.empty());
  EXPECT_TRUE(monitors[0].last_observation_ciphertext.empty());
}

TEST(AegisAgentTaskStoreTest, MigratesVersionEightAndCreatesResearchTable) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  const auto path = directory.GetPath().AppendASCII("version-eight.sqlite");
  {
    AgentTaskStore store(path);
    ASSERT_TRUE(store.Initialize());
    AgentTask task("retained-task", "保留旧任务", AgentMode::kAsk,
                   StoreTestScope());
    ASSERT_TRUE(store.SaveTask(task, task.goal(), false));
  }
  {
    sql::Database legacy("AegisAgent");
    ASSERT_TRUE(legacy.Open(path));
    ASSERT_TRUE(legacy.Execute("DROP TABLE agent_saved_research"));
    sql::MetaTable meta;
    ASSERT_TRUE(meta.Init(&legacy, 8, 8));
    ASSERT_TRUE(meta.SetVersionNumber(8));
    ASSERT_TRUE(meta.SetCompatibleVersionNumber(8));
  }
  for (int reopen = 0; reopen < 2; ++reopen) {
    AgentTaskStore migrated(path);
    ASSERT_TRUE(migrated.Initialize());
    ASSERT_EQ(migrated.LoadUnfinishedTasks().size(), 1u);
    EXPECT_EQ(migrated.LoadUnfinishedTasks()[0].task_id, "retained-task");
    ASSERT_TRUE(migrated.SaveResearch({.id = "research",
                                       .ciphertext = "合成密文",
                                       .saved_at = base::Time::Now()}));
    ASSERT_TRUE(migrated.LoadResearch());
    EXPECT_EQ(migrated.LoadResearch()->size(), 1u);
  }
}

TEST(AegisAgentTaskStoreTest, MigratesVersionSevenWithoutLosingMonitorState) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const auto path = temp_dir.GetPath().AppendASCII("version-seven.sqlite");
  AgentMonitorDefinition monitor;
  monitor.monitor_id = "version-seven-monitor";
  monitor.task_id = "version-seven-owner";
  monitor.origin = url::Origin::Create(GURL("https://fixture.example/"));
  monitor.target_hash = "target-hash";
  monitor.target_ciphertext = std::string("target\0cipher", 13);
  monitor.last_value_hash = "previous-result-hash";
  monitor.last_observation_ciphertext = std::string("observation\0cipher", 18);
  monitor.last_check_status =
      AgentMonitorCheckStatus::kSecureStorageUnavailable;
  monitor.last_http_status = 200;
  monitor.last_run = base::Time::Now();
  monitor.next_run = monitor.last_run + base::Hours(1);
  monitor.consecutive_failures = 2;
  monitor.enabled = false;
  {
    AgentTaskStore store(path);
    ASSERT_TRUE(store.Initialize());
    ASSERT_TRUE(store.SaveMonitor(monitor));
  }
  {
    sql::Database legacy("AegisAgent");
    ASSERT_TRUE(legacy.Open(path));
    sql::MetaTable meta;
    ASSERT_TRUE(meta.Init(&legacy, 7, 1));
    ASSERT_TRUE(meta.SetVersionNumber(7));
    ASSERT_TRUE(meta.SetCompatibleVersionNumber(1));
  }
  // 迁移后再次打开，验证迁移是幂等的，暂停状态和密文字节均未丢失。
  for (int reopen = 0; reopen < 2; ++reopen) {
    AgentTaskStore migrated(path);
    ASSERT_TRUE(migrated.Initialize());
    const auto monitors = migrated.LoadMonitors();
    ASSERT_EQ(monitors.size(), 1u);
    EXPECT_EQ(monitors[0].target_ciphertext, monitor.target_ciphertext);
    EXPECT_EQ(monitors[0].last_observation_ciphertext,
              monitor.last_observation_ciphertext);
    EXPECT_EQ(monitors[0].last_value_hash, monitor.last_value_hash);
    EXPECT_EQ(monitors[0].last_check_status, monitor.last_check_status);
    EXPECT_EQ(monitors[0].last_http_status, 200);
    EXPECT_EQ(monitors[0].last_run, monitor.last_run);
    EXPECT_EQ(monitors[0].next_run, monitor.next_run);
    EXPECT_EQ(monitors[0].consecutive_failures, 2);
    EXPECT_FALSE(monitors[0].enabled);
    EXPECT_TRUE(monitors[0].last_observation.empty());
  }
  sql::Database inspected("AegisAgent");
  ASSERT_TRUE(inspected.Open(path));
  sql::MetaTable meta;
  ASSERT_TRUE(meta.Init(&inspected, 9, 9));
  EXPECT_EQ(meta.GetVersionNumber(), 9);
  EXPECT_EQ(meta.GetCompatibleVersionNumber(), 9);
}

TEST(AegisAgentTaskStoreTest,
     RestoresSummaryFailureWithoutDroppingOtherMonitors) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const auto path = temp_dir.GetPath().AppendASCII("summary-status.sqlite");
  AgentMonitorDefinition monitor;
  monitor.monitor_id = "summary-failed";
  monitor.task_id = "summary-owner";
  monitor.origin = url::Origin::Create(GURL("https://fixture.example/"));
  monitor.target_hash = "target-hash";
  monitor.target_ciphertext = "encrypted-target";
  monitor.last_observation_ciphertext = "encrypted-last-good-summary";
  monitor.last_check_status = AgentMonitorCheckStatus::kSummaryUnavailable;
  {
    AgentTaskStore store(path);
    ASSERT_TRUE(store.Initialize());
    ASSERT_TRUE(store.SaveMonitor(monitor));
    monitor.monitor_id = "unrelated";
    monitor.last_check_status = AgentMonitorCheckStatus::kSucceeded;
    ASSERT_TRUE(store.SaveMonitor(monitor));
  }
  AgentTaskStore restarted(path);
  ASSERT_TRUE(restarted.Initialize());
  const auto monitors = restarted.LoadMonitors();
  ASSERT_EQ(monitors.size(), 2u);
  EXPECT_EQ(monitors[0].monitor_id, "summary-failed");
  EXPECT_EQ(monitors[0].last_check_status,
            AgentMonitorCheckStatus::kSummaryUnavailable);
  EXPECT_EQ(monitors[0].last_observation_ciphertext,
            "encrypted-last-good-summary");
  EXPECT_TRUE(monitors[0].last_observation.empty());
  EXPECT_EQ(monitors[1].monitor_id, "unrelated");
  EXPECT_EQ(monitors[1].last_check_status, AgentMonitorCheckStatus::kSucceeded);
}

TEST(AegisAgentTaskStoreTest, RejectsFutureVersionWithoutRewritingDatabase) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const auto path = temp_dir.GetPath().AppendASCII("future.sqlite");
  {
    AgentTaskStore store(path);
    ASSERT_TRUE(store.Initialize());
  }
  {
    sql::Database future("AegisAgent");
    ASSERT_TRUE(future.Open(path));
    sql::MetaTable meta;
    ASSERT_TRUE(meta.Init(&future, 9, 9));
    ASSERT_TRUE(meta.SetVersionNumber(10));
    ASSERT_TRUE(meta.SetCompatibleVersionNumber(10));
  }
  std::string before;
  ASSERT_TRUE(base::ReadFileToString(path, &before));
  {
    AgentTaskStore old_reader(path);
    EXPECT_FALSE(old_reader.Initialize());
    EXPECT_TRUE(old_reader.LoadMonitors().empty());
  }
  std::string after;
  ASSERT_TRUE(base::ReadFileToString(path, &after));
  EXPECT_EQ(after, before);
}

TEST(AegisAgentTaskStoreTest,
     StoresOnlyEncryptedObservationAndRejectsFallback) {
  base::ScopedTempDir temp_dir;
  ASSERT_TRUE(temp_dir.CreateUniqueTempDir());
  const auto path = temp_dir.GetPath().AppendASCII("observation.sqlite");
  AgentMonitorDefinition monitor;
  monitor.monitor_id = "private-observation";
  monitor.task_id = "observation-owner";
  monitor.origin = url::Origin::Create(GURL("https://fixture.example/"));
  monitor.target_hash = "target-hash";
  monitor.target_ciphertext = "encrypted-target";
  monitor.last_observation =
      R"({"version":1,"kind":2,"content":["private-baseline-marker"]})";
  {
    AgentTaskStore store(path);
    ASSERT_TRUE(store.Initialize());
    EXPECT_FALSE(store.SaveMonitor(monitor));
    EXPECT_TRUE(store.LoadMonitors().empty());
    monitor.last_observation_ciphertext = std::string("cipher\0bytes", 12);
    ASSERT_TRUE(store.SaveMonitor(monitor));
    monitor.session_only = true;
    EXPECT_FALSE(store.SaveMonitor(monitor));
  }
  AgentTaskStore recovered(path);
  ASSERT_TRUE(recovered.Initialize());
  const auto monitors = recovered.LoadMonitors();
  ASSERT_EQ(monitors.size(), 1u);
  EXPECT_TRUE(monitors[0].last_observation.empty());
  EXPECT_EQ(monitors[0].last_observation_ciphertext,
            monitor.last_observation_ciphertext);
  std::string bytes;
  ASSERT_TRUE(base::ReadFileToString(path, &bytes));
  EXPECT_EQ(bytes.find("private-baseline-marker"), std::string::npos);
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
