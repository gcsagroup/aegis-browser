// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/aegis_agent_service.h"

#include <algorithm>
#include <memory>
#include <string_view>
#include <utility>

#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/scoped_observation.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/test/bind.h"
#include "base/test/scoped_feature_list.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "build/build_config.h"
#include "chrome/browser/actor/actor_keyed_service.h"
#include "chrome/browser/actor/actor_task.h"
#include "chrome/browser/actor/ui/event_dispatcher.h"
#include "chrome/browser/actor/ui/test_support/mock_actor_ui_state_manager.h"
#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"
#include "chrome/browser/aegis/agent/agent_model_client.h"
#include "chrome/common/actor/action_result.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "chrome/test/base/testing_browser_process.h"
#include "chrome/test/base/testing_profile.h"
#include "chrome/test/base/testing_profile_manager.h"
#include "components/download/public/common/mock_download_item.h"
#include "components/os_crypt/async/browser/os_crypt_async.h"
#include "components/prefs/pref_service.h"
#include "components/undo/undo_manager.h"
#include "content/public/test/browser_task_environment.h"
#include "crypto/sha2.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/test/test_url_loader_factory.h"
#include "services/network/test/test_utils.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {

class AegisAgentServiceTestPeer {
 public:
  static void DeliverBookmarkUndo(
      AegisAgentService* service,
      const std::string& id,
      AgentToolResult result,
      AegisAgentService::ToolResultCallback callback) {
    AgentCompletionSummary summary;
    summary.outcome = "completed";
    summary.summary = "原整理已完成";
    service->completion_summaries_[id] = std::move(summary);
    AgentToolCall call;
    call.action_id = "undo-callback";
    call.tool_name = "bookmark.undo";
    service->action_hashes_[id][call.action_id] = "已授权的测试撤销";
    service->action_tools_[id][call.action_id] = call.tool_name;
    result.action_id = call.action_id;
    service->OnToolExecuted(id, std::move(call), std::move(callback),
                            std::move(result));
  }
  static void SeedResearch(AegisAgentService* service, const std::string& id) {
    base::DictValue record;
    record.Set("version", 1);
    record.Set("id", id);
    record.Set("goal", "保存合成研究");
    record.Set("summary", "research-private-canary-never-plaintext");
    record.Set("outcome", "completed");
    record.Set("created_ms", "1789530000000");
    record.Set("unfinished", base::ListValue());
    base::ListValue sources;
    for (int i = 0; i < 3; ++i) {
      sources.Append(
          base::DictValue()
              .Set("url", "https://fixture.example/" + base::NumberToString(i))
              .Set("title", "来源")
              .Set("excerpt", "合成文章正文")
              .Set("content_hash", std::string(64, 'a'))
              .Set("captured_ms", "1789530000000")
              .Set("available", true));
    }
    record.Set("sources", std::move(sources));
    service->research_results_.insert_or_assign(id, std::move(record));
  }
  static void SeedPendingResearchCompletion(AegisAgentService* service,
                                             const AgentTask& task) {
    AgentCompletionSummary completion{.outcome = "completed",
                                      .summary = "三个来源的比较结果。"};
    UpdateAgentResearchSaveCompletion(&completion, task, false);
    service->completion_summaries_[task.id()] = std::move(completion);
  }
  static void WriteResearchCiphertext(AegisAgentService* service,
                                      StoredAgentResearch record,
                                      base::OnceCallback<void(bool)> callback) {
    service->task_store_.AsyncCall(&AgentTaskStore::SaveResearch)
        .WithArgs(std::move(record))
        .Then(std::move(callback));
  }
  static void SeedClickObservation(AegisActorBridge* bridge,
                                   const AgentDocumentRef& document) {
    bridge->last_documents_["click-fixture"][7] = document;
    auto& nodes = bridge->observed_node_text_["click-fixture"][7];
    nodes[15] = {.text = "执行操作", .click_target_node_id = 15};
    nodes[3] = {.text = "执行操作", .click_target_node_id = 15};
    nodes[4] = {.text = "执行操作"};
    nodes[9] = {.text = "秘密",
                .click_target_node_id = 15,
                .is_sensitive_control = true};
  }
  static void SeedDownloadLink(AegisActorBridge* bridge,
                               int node_id,
                               const GURL& url) {
    bridge->observed_node_text_["click-fixture"][7][node_id].download_url = url;
  }
  static bool HasRuntime(AegisAgentService* service, const std::string& id) {
    return service->executions_.contains(id);
  }
  static std::pair<size_t, int> Progress(AegisAgentService* service,
                                         const std::string& id) {
    return service->plan_progress_.at(id);
  }
  static void DeliverRuntimeResult(AegisAgentService* service,
                                   const std::string& id,
                                   std::string tool,
                                   bool ok,
                                   base::DictValue value = base::DictValue()) {
    // 模拟模型响应已结束、原生工具回调到达；不创建额外生产测试接口。
    if (auto request = service->model_request_ids_.find(id);
        request != service->model_request_ids_.end()) {
      auto request_id = request->second;
      service->model_request_ids_.erase(request);
      service->model_clients_.at(id)->Cancel(request_id);
    }
    AgentToolCall call;
    call.action_id = "callback-fixture";
    call.tool_name = std::move(tool);
    AgentToolResult result;
    result.action_id = call.action_id;
    result.ok = ok;
    result.error =
        ok ? AgentErrorCode::kNone : AgentErrorCode::kVerificationFailed;
    result.message = "原生测试回调";
    result.value = std::move(value);
    service->OnRuntimeToolResult(id, std::move(call), std::move(result));
  }
  static void DeliverPendingApproval(AegisAgentService* service,
                                     const std::string& id) {
    if (auto request = service->model_request_ids_.find(id);
        request != service->model_request_ids_.end()) {
      const auto request_id = request->second;
      service->model_request_ids_.erase(request);
      service->model_clients_.at(id)->Cancel(request_id);
    }
    ASSERT_TRUE(service->Transition(id, AgentTaskState::kAwaitingActionApproval,
                                    "等待合成点击批准"));
    AgentToolCall call;
    call.action_id = "pending-click";
    call.tool_name = "page.click";
    AgentToolResult result;
    result.action_id = call.action_id;
    result.ok = false;
    result.error = AgentErrorCode::kApprovalRequired;
    service->OnRuntimeToolResult(id, std::move(call), std::move(result));
  }
  static void InvalidatePendingPage(AegisAgentService* service, const std::string& id) {
    service->InvalidatePendingActionForPageChange(id);
  }
  static void FailRuntime(AegisAgentService* service, const std::string& id) {
    service->Transition(id, AgentTaskState::kFailed, "测试不可恢复失败");
    service->FinishRuntime(id, false, "测试不可恢复失败", std::nullopt);
  }
  static void FinishMonitorDecryption(
      AegisAgentService* service,
      const std::string& monitor_id,
      scoped_refptr<os_crypt_async::Encryptor> encryptor) {
    service->OnMonitorTargetsDecryptorReady(monitor_id, std::move(encryptor));
  }
};

class AegisBrowserToolsTestPeer {
 public:
  static void SeedUndoReceipt(AegisBrowserTools* tools,
                              UndoManager* undo_manager) {
    AegisBrowserTools::BookmarkUndoReceipt receipt{.task_id = "task-bookmarks",
                                                   .token = "undo-token",
                                                   .before_hash = "before",
                                                   .after_hash = "after",
                                                   .undo_count = 1};
    tools->bookmark_undo_receipts_.emplace(receipt.token, std::move(receipt));
    tools->ObserveBookmarkUndoManager(undo_manager);
  }

  static size_t UndoReceiptCount(const AegisBrowserTools& tools) {
    return tools.bookmark_undo_receipts_.size();
  }

  static bool IsObserving(const AegisBrowserTools& tools,
                          const UndoManager* undo_manager) {
    return tools.bookmark_undo_manager_ == undo_manager;
  }

  static bool ShouldWaitForDownloadVerification(download::DownloadItem* item) {
    return AegisBrowserTools::ShouldWaitForDownloadVerification(item);
  }
};

namespace {

using ::testing::_;
using ::testing::HasSubstr;
using ::testing::Return;
using ::testing::SizeIs;

std::unique_ptr<actor::ui::ActorUiStateManagerInterface>
BuildActorUiStateManagerMock() {
  auto manager = std::make_unique<actor::ui::MockActorUiStateManager>();
  ON_CALL(*manager, OnUiEvent(_, _))
      .WillByDefault(
          [](actor::ui::AsyncUiEvent, actor::ui::UiCompleteCallback callback) {
            std::move(callback).Run(actor::MakeOkResult());
          });
  return manager;
}

AgentTaskScope ServiceTestScope() {
  AgentTaskScope scope;
  scope.allowed_origins = {
      url::Origin::Create(GURL("https://fixture.example/"))};
  scope.allowed_tools = {"page.observe", "page.click"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage};
  scope.model_destination.provider = "aegis-local";
  scope.model_destination.model = "fixture";
  return scope;
}

AgentModelEvent ServicePlanEvent() {
  AgentModelEvent event;
  event.type = AgentModelEventType::kToolCall;
  event.tool_call_id = "plan-call";
  event.tool_name = "agent.submit_plan";
  event.arguments.Set("schema_version", kAgentSchemaVersion);
  event.arguments.Set("summary", "Use one bounded page observation");
  base::DictValue step;
  step.Set("id", "observe");
  step.Set("title", "Observe the approved fixture");
  step.Set("tool", "page.observe");
  base::ListValue steps;
  steps.Append(std::move(step));
  event.arguments.Set("steps", std::move(steps));
  return event;
}

AgentModelEvent ServiceAutomationPlanEvent() {
  AgentModelEvent event = ServicePlanEvent();
  base::DictValue monitor;
  monitor.Set("id", "monitor");
  monitor.Set("title", "Create the approved fixture monitor");
  monitor.Set("tool", "monitor.create");
  event.arguments.FindList("steps")->Append(std::move(monitor));
  return event;
}

bool InstallServicePlan(AegisAgentService* service, AgentTask* task) {
  if (!service || !task || !service->BeginPlanning(task->id())) {
    return false;
  }
  const AgentModelEvent event = ServicePlanEvent();
  std::string error;
  return service->AcceptModelPlan(task->id(), event, &error);
}

constexpr char kRecoveryObservation[] =
    R"({"version":1,"kind":2,"content":["恢复测试的有效历史结果"]})";

scoped_refptr<os_crypt_async::Encryptor> RecoveryTestEncryptor() {
  base::test::TestFuture<scoped_refptr<os_crypt_async::Encryptor>> ready;
  TestingBrowserProcess::GetGlobal()->os_crypt_async()->GetInstance(
      ready.GetCallback());
  return ready.Get();
}

std::optional<AgentMonitorDefinition> MakeRecoveryMonitor(
    AegisAgentService* service,
    const std::string& monitor_id,
    os_crypt_async::Encryptor* encryptor) {
  AgentTask* task = service->CreateTask(
      "恢复加密监控", AgentMode::kAutomate, ServiceTestScope());
  if (!task || !encryptor) {
    return std::nullopt;
  }
  const auto hash = [](std::string_view value) {
    return "sha256:" + base::HexEncode(crypto::SHA256HashString(value));
  };
  const GURL target("https://fixture.example/recovery-monitor");
  AgentMonitorDefinition monitor;
  monitor.monitor_id = monitor_id;
  monitor.task_id = task->id();
  monitor.kind = AgentMonitorKind::kPageChange;
  monitor.origin = url::Origin::Create(target);
  monitor.target_hash = hash(target.spec());
  monitor.last_value_hash = hash(kRecoveryObservation);
  monitor.next_run = base::Time::Now() + base::Hours(1);
  monitor.enabled = false;
  monitor.last_check_status = AgentMonitorCheckStatus::kSecureStorageUnavailable;
  base::DictValue envelope;
  envelope.Set("version", 1);
  envelope.Set("monitor_id", monitor_id);
  envelope.Set("task_id", task->id());
  envelope.Set("target_hash", monitor.target_hash);
  envelope.Set("observation", kRecoveryObservation);
  const auto plaintext = base::WriteJson(envelope);
  if (!plaintext ||
      !encryptor->EncryptString(target.spec(), &monitor.target_ciphertext) ||
      !encryptor->EncryptString(*plaintext, &monitor.last_observation_ciphertext)) {
    return std::nullopt;
  }
  return monitor;
}

class RecoverySnapshotObserver : public AegisAgentServiceObserver {
 public:
  explicit RecoverySnapshotObserver(AegisAgentService* service) {
    observation_.Observe(service);
  }
  void OnAgentServiceSnapshotChanged() override { ++notifications; }
  int notifications = 0;

 private:
  base::ScopedObservation<AegisAgentService, AegisAgentServiceObserver>
      observation_{this};
};

class AegisAgentServiceTest : public testing::Test {
 public:
  AegisAgentServiceTest()
      : task_environment_(base::test::TaskEnvironment::TimeSource::MOCK_TIME),
        profile_manager_(TestingBrowserProcess::GetGlobal()) {
    features_.InitWithFeatures(
        {aegis::features::kAegisAgent, aegis::features::kAegisAgentPageActions,
         aegis::features::kAegisAgentBrowserTools,
         aegis::features::kAegisAgentWebMcp,
         aegis::features::kAegisAgentWorkflows},
        {});
  }

  void SetUp() override {
    ASSERT_TRUE(profile_manager_.SetUp());
    profile_ = profile_manager_.CreateTestingProfile("agent-profile");
    profile_->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, true);
    actor::ActorKeyedService::Get(profile_)->SetActorUiStateManagerForTesting(
        BuildActorUiStateManagerMock());
  }

  void TearDown() override { profile_ = nullptr; }

 protected:
  void FlushTaskStore(AegisAgentService* service) {
    base::test::TestFuture<bool> flushed;
    service->FlushTaskStoreForTesting(flushed.GetCallback());
    ASSERT_TRUE(flushed.Get());
  }

  TestingProfileManager& profile_manager() { return profile_manager_; }
  // SequenceBound 的析构异步关闭数据库；重启对照必须等待旧进程资源全部释放。
  void DrainTaskRunners() { task_environment_.RunUntilIdle(); }
  AgentTask* StartHeldRuntime(network::TestURLLoaderFactory* factory,
                              AegisAgentService::RunCallback callback,
                              const std::string& second_tool = "page.observe") {
    constexpr char kBaseUrl[] = "http://127.0.0.1:8765/v1";
    profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
    profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl, kBaseUrl);
    profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "fixture-model");
    auto scope = ServiceTestScope();
    scope.allowed_tools.insert("tab.list");
    scope.allowed_tools.insert(second_tool);
    if (second_tool.starts_with("download.")) {
      scope.allowed_data_classes.insert(AgentDataClass::kDownloads);
      scope.allowed_tools.insert("download.find_official");
      scope.allowed_tools.insert("download.start");
    }
    scope.allowed_data_classes.insert(AgentDataClass::kBrowserMetadata);
    scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
    scope.model_destination.provider = "openai";
    scope.model_destination.endpoint = kBaseUrl;
    scope.model_destination.model = "fixture-model";
    auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
    auto* task =
        service->CreateTask("执行测试步骤", AgentMode::kAct, std::move(scope));
    if (!task || !service->BeginPlanning(task->id())) {
      return nullptr;
    }
    auto plan = ServicePlanEvent();
    plan.arguments.Set("steps", base::ListValue()
                                    .Append(base::DictValue()
                                                .Set("id", "tabs")
                                                .Set("title", "读取标签")
                                                .Set("tool", "tab.list"))
                                    .Append(base::DictValue()
                                                .Set("id", "page")
                                                .Set("title", "页面操作")
                                                .Set("tool", second_tool)));
    if (second_tool == "download.verify") {
      // 下载核验必须先有来源检查和原生下载，不绕过产品的计划依赖校验。
      base::ListValue steps;
      for (const auto* tool : {"tab.list", "download.find_official",
                               "download.start", "download.verify"}) {
        steps.Append(base::DictValue()
                         .Set("id", tool)
                         .Set("title", tool)
                         .Set("tool", tool));
      }
      plan.arguments.Set("steps", std::move(steps));
    }
    std::string error;
    if (!service->AcceptModelPlan(task->id(), plan, &error) ||
        !service->GrantTaskConsent(task->id())) {
      ADD_FAILURE() << error;
      return nullptr;
    }
    service->SetTaskModelClientForTesting(
        task->id(),
        std::make_unique<AgentModelClient>(factory->GetSafeWeakWrapper()));
    service->RunTask(task->id(), std::move(callback));
    if (!AegisAgentServiceTestPeer::HasRuntime(service, task->id())) {
      ADD_FAILURE() << "运行未启动，不能等待不存在的模型请求";
      return nullptr;
    }
    factory->WaitForRequest(GURL("http://127.0.0.1:8765/v1/responses"));
    return task;
  }
  raw_ptr<TestingProfile> profile_ = nullptr;

 private:
  base::test::ScopedFeatureList features_;
  content::BrowserTaskEnvironment task_environment_;
  TestingProfileManager profile_manager_;
};

TEST_F(AegisAgentServiceTest, ResearchCompletionWaitsForStorageSuccess) {
  AegisAgentService service(profile_);
  FlushTaskStore(&service);
  auto scope = ServiceTestScope();
  scope.selected_pages_research = true;
  scope.allowed_tab_ids = {7, 8, 9};
  scope.allowed_tools = {"page.observe"};
  scope.budgets.max_tabs = 3;
  ASSERT_TRUE(scope.IsValid());
  auto* task = service.CreateTask("比较来源并保存研究", AgentMode::kAct, scope);
  ASSERT_TRUE(task);
  const std::string id = task->id();
  AegisAgentServiceTestPeer::SeedResearch(&service, id);
  AegisAgentServiceTestPeer::SeedPendingResearchCompletion(&service, *task);
  ASSERT_TRUE(service.GetCompletionSummary(id));
  EXPECT_EQ(service.GetCompletionSummary(id)->outcome, "partial");
  profile_->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, false);
  base::test::TestFuture<std::string> rejected;
  service.SaveResearch(id, rejected.GetCallback());
  EXPECT_EQ(rejected.Get(), "research_unavailable");
  profile_->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, true);
  EXPECT_EQ(service.GetCompletionSummary(id)->outcome, "partial");
  base::test::TestFuture<std::string> saved;
  service.SaveResearch(id, saved.GetCallback());
  EXPECT_EQ(service.GetCompletionSummary(id)->outcome, "partial");
  ASSERT_EQ(saved.Get(), "");
  EXPECT_EQ(service.GetCompletionSummary(id)->outcome, "completed");
  EXPECT_TRUE(service.GetCompletionSummary(id)->unfinished_items.empty());
  base::test::TestFuture<base::ListValue, std::string> loaded;
  service.LoadSavedResearch(loaded.GetCallback());
  EXPECT_EQ(loaded.Get<1>(), "");
  ASSERT_EQ(loaded.Get<0>().size(), 1u);
  EXPECT_EQ(*loaded.Get<0>()[0].GetDict().FindString("id"), id);
  service.Shutdown();
  FlushTaskStore(&service);
}

TEST_F(AegisAgentServiceTest, EncryptsResearchAndRestoresAfterRestart) {
  {
    AegisAgentService service(profile_);
    FlushTaskStore(&service);
    AegisAgentServiceTestPeer::SeedResearch(&service, "saved-fixture");
    base::test::TestFuture<std::string> saved;
    service.SaveResearch("saved-fixture", saved.GetCallback());
    ASSERT_EQ(saved.Get(), "");
    service.Shutdown();
    FlushTaskStore(&service);
  }
  DrainTaskRunners();
  std::string bytes;
  ASSERT_TRUE(base::ReadFileToString(
      profile_->GetPath().AppendASCII("AegisAgentTasks.sqlite"), &bytes));
  EXPECT_EQ(bytes.find("research-private-canary-never-plaintext"),
            std::string::npos);
  {
    AegisAgentService recovered(profile_);
    FlushTaskStore(&recovered);
    base::test::TestFuture<base::ListValue, std::string> loaded;
    recovered.LoadSavedResearch(loaded.GetCallback());
    ASSERT_EQ(loaded.Get<1>(), "");
    ASSERT_EQ(loaded.Get<0>().size(), 1u);
    EXPECT_EQ(*loaded.Get<0>().front().GetDict().FindString("summary"),
              "research-private-canary-never-plaintext");
    EXPECT_TRUE(recovered.GetResearchRecord("saved-fixture"));
    base::test::TestFuture<std::string> removed;
    recovered.DeleteSavedResearch("saved-fixture", removed.GetCallback());
    EXPECT_EQ(removed.Get(), "");
    EXPECT_FALSE(recovered.GetResearchRecord("saved-fixture"));
    base::test::TestFuture<base::ListValue, std::string> empty;
    recovered.LoadSavedResearch(empty.GetCallback());
    EXPECT_EQ(empty.Get<1>(), "");
    EXPECT_TRUE(empty.Get<0>().empty());
    recovered.Shutdown();
  }
}

TEST_F(AegisAgentServiceTest,
       CorruptResearchFailsClosedAndDisabledServiceRejectsSave) {
  AegisAgentService service(profile_);
  FlushTaskStore(&service);
  base::test::TestFuture<bool> written;
  AegisAgentServiceTestPeer::WriteResearchCiphertext(
      &service,
      {.id = "corrupt",
       .ciphertext = "not-encrypted",
       .saved_at = base::Time::Now()},
      written.GetCallback());
  ASSERT_TRUE(written.Get());
  base::test::TestFuture<base::ListValue, std::string> loaded;
  service.LoadSavedResearch(loaded.GetCallback());
  EXPECT_EQ(loaded.Get<1>(), "stored_research_unreadable");
  EXPECT_TRUE(loaded.Get<0>().empty());
  EXPECT_FALSE(service.GetResearchRecord("corrupt"));
  AegisAgentServiceTestPeer::SeedResearch(&service, "disabled");
  profile_->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, false);
  base::test::TestFuture<std::string> saved;
  service.SaveResearch("disabled", saved.GetCallback());
  EXPECT_EQ(saved.Get(), "research_unavailable");
  service.Shutdown();
}

TEST_F(AegisAgentServiceTest, PrivateResearchIsSessionOnlyAndIsolated) {
  Profile* otr = profile_->GetPrimaryOTRProfile(true);
  ASSERT_TRUE(otr);
  {
    AegisAgentService service(otr);
    FlushTaskStore(&service);
    AegisAgentServiceTestPeer::SeedResearch(&service, "private");
    base::test::TestFuture<std::string> saved;
    service.SaveResearch("private", saved.GetCallback());
    EXPECT_EQ(saved.Get(), "");
    base::test::TestFuture<base::ListValue, std::string> loaded;
    service.LoadSavedResearch(loaded.GetCallback());
    EXPECT_EQ(loaded.Get<1>(), "");
    EXPECT_EQ(loaded.Get<0>().size(), 1u);
    EXPECT_FALSE(base::PathExists(
        profile_->GetPath().AppendASCII("AegisAgentTasks.sqlite")));
    service.Shutdown();
  }
  DrainTaskRunners();
  AegisAgentService next(otr);
  FlushTaskStore(&next);
  base::test::TestFuture<base::ListValue, std::string> empty;
  next.LoadSavedResearch(empty.GetCallback());
  EXPECT_EQ(empty.Get<1>(), "");
  EXPECT_TRUE(empty.Get<0>().empty());
  next.Shutdown();
}

TEST_F(AegisAgentServiceTest, ClickTargetUsesObservedAncestryAndDocument) {
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  auto& bridge = service->actor_bridge_for_testing();
  AgentDocumentRef document{.tab_id = 7,
                            .frame_token = "frame-fixture",
                            .document_token = "document-fixture",
                            .committed_url = GURL("https://fixture.example/")};
  AegisAgentServiceTestPeer::SeedClickObservation(&bridge, document);
  AgentToolCall call;
  call.tool_name = "page.click";
  call.arguments.Set("tab_id", 7);
  call.arguments.Set("node_id", 3);
  call.document = document;
  EXPECT_EQ(bridge.ResolveObservedClickTarget("click-fixture", call), 15);
  EXPECT_EQ(bridge.DescribeObservedClickTarget("click-fixture", call),
            "执行操作");
  call.arguments.Set("node_id", 15);
  EXPECT_EQ(bridge.ResolveObservedClickTarget("click-fixture", call), 15);
  for (int node : {4, 9, 99}) {
    call.arguments.Set("node_id", node);
    EXPECT_FALSE(bridge.ResolveObservedClickTarget("click-fixture", call));
  }
  call.arguments.Set("node_id", 3);
  call.document->document_token = "changed-document";
  EXPECT_FALSE(bridge.ResolveObservedClickTarget("click-fixture", call));
  call.document = document;
  call.arguments.Set("tab_id", 8);
  EXPECT_FALSE(bridge.ResolveObservedClickTarget("click-fixture", call));
}

TEST_F(AegisAgentServiceTest, DownloadUrlBindsUniqueCurrentObservedLink) {
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  auto& bridge = service->actor_bridge_for_testing();
  AgentDocumentRef document{.tab_id = 7,
                            .frame_token = "frame",
                            .document_token = "doc",
                            .committed_url = GURL("https://fixture.example/")};
  AegisAgentServiceTestPeer::SeedClickObservation(&bridge, document);
  AegisAgentServiceTestPeer::SeedDownloadLink(
      &bridge, 17, GURL("https://fixture.example/file?chunk_delay_ms=1000"));
  AgentToolCall call;
  call.tool_name = "download.start";
  call.document = document;
  call.arguments.Set("tab_id", 7);
  call.arguments.Set("url", "https://fixture.example/file");
  auto bound = bridge.ResolveObservedDownloadUrl("click-fixture", call);
  ASSERT_TRUE(bound);
  EXPECT_EQ(bound->spec(), "https://fixture.example/file?chunk_delay_ms=1000");
  EXPECT_FALSE(bridge.ResolveObservedDownloadUrl("other-task", call));
  call.document->document_token = "stale";
  EXPECT_FALSE(bridge.ResolveObservedDownloadUrl("click-fixture", call));
  call.document = document;
  call.arguments.Set("url", "https://fixture.example/unobserved");
  EXPECT_FALSE(bridge.ResolveObservedDownloadUrl("click-fixture", call));
  call.arguments.Set("url", "https://fixture.example/file");
  AegisAgentServiceTestPeer::SeedDownloadLink(
      &bridge, 18, GURL("https://fixture.example/file?chunk_delay_ms=1"));
  EXPECT_FALSE(bridge.ResolveObservedDownloadUrl("click-fixture", call));
  call.arguments.Set("url", "https://fixture.example/file?chunk_delay_ms=1000");
  EXPECT_TRUE(bridge.ResolveObservedDownloadUrl("click-fixture", call));
  AegisAgentServiceTestPeer::SeedDownloadLink(&bridge, 17, GURL());
  EXPECT_FALSE(bridge.ResolveObservedDownloadUrl("click-fixture", call));
}

TEST_F(AegisAgentServiceTest, CurrentPageConsentRejectsMissingOriginalBinding) {
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  auto scope = ServiceTestScope();
  scope.allowed_tab_ids = {7};
  scope.budgets.max_tabs = 1;
  scope.restrict_to_current_page = true;
  for (bool recovering : {false, true}) {
    auto* task = service->CreateTask("当前页面操作", AgentMode::kAct, scope);
    ASSERT_TRUE(task);
    ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "fixture"));
    ASSERT_TRUE(
        task->TransitionTo(AgentTaskState::kAwaitingTaskConsent, "fixture"));
    if (recovering) {
      ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRunning, "fixture"));
      ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRecovering, "fixture"));
      EXPECT_FALSE(service->GrantRecoveryConsent(task->id()));
    } else {
      EXPECT_FALSE(service->GrantTaskConsent(task->id()));
    }
    EXPECT_EQ(task->state(), AgentTaskState::kFailed);
    EXPECT_EQ(
        service->actor_bridge_for_testing().active_task_count_for_testing(),
        0u);
  }
}

TEST_F(AegisAgentServiceTest, KeepsPrimaryIncognitoTasksAndPrefsIsolated) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  EXPECT_TRUE(service->IsEnabled());
  EXPECT_TRUE(AreAgentSystemNotificationsAllowed(profile_));
  EXPECT_FALSE(service->task_store_is_in_memory_for_testing());

  AgentTask* regular_task =
      service->CreateTask("regular task", AgentMode::kAsk, ServiceTestScope());
  ASSERT_TRUE(regular_task);
  FlushTaskStore(service);
  const base::FilePath regular_database =
      profile_->GetPath().AppendASCII("AegisAgentTasks.sqlite");
  ASSERT_TRUE(base::PathExists(regular_database));
  std::string database_before_incognito_task;
  ASSERT_TRUE(base::ReadFileToString(regular_database,
                                     &database_before_incognito_task));
  base::DictValue regular_workspaces;
  regular_workspaces.Set("regular-workspace", base::DictValue());
  profile_->GetPrefs()->SetDict(aegis::prefs::kAgentWorkspaces,
                                regular_workspaces.Clone());

  Profile* otr = profile_->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_TRUE(otr);
  AegisAgentService* otr_service = AegisAgentServiceFactory::GetForProfile(otr);
  ASSERT_TRUE(otr_service);
  EXPECT_NE(otr_service, service);
  EXPECT_TRUE(otr_service->IsEnabled());
  EXPECT_FALSE(AreAgentSystemNotificationsAllowed(otr));
  EXPECT_TRUE(otr_service->task_store_is_in_memory_for_testing());
  EXPECT_EQ(otr_service->task_count_for_testing(), 0u);
  EXPECT_TRUE(otr->GetPrefs()->GetDict(aegis::prefs::kAgentWorkspaces).empty());
  EXPECT_TRUE(profile_->GetPrefs()
                  ->GetDict(aegis::prefs::kAgentWorkspaces)
                  .contains("regular-workspace"));

  AgentTask* otr_task = otr_service->CreateTask(
      "incognito task", AgentMode::kAsk, ServiceTestScope());
  ASSERT_TRUE(otr_task);
  EXPECT_EQ(service->task_count_for_testing(), 1u);
  EXPECT_EQ(otr_service->task_count_for_testing(), 1u);
  EXPECT_NE(regular_task->id(), otr_task->id());

  std::string database_after_incognito_task;
  ASSERT_TRUE(
      base::ReadFileToString(regular_database, &database_after_incognito_task));
  EXPECT_EQ(database_after_incognito_task, database_before_incognito_task);

  otr->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, false);
  EXPECT_FALSE(otr_service->IsEnabled());
  EXPECT_TRUE(profile_->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled));
  otr->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, true);
  EXPECT_TRUE(otr_service->IsEnabled());
}

TEST_F(AegisAgentServiceTest,
       OpensAndQueuesTaskStorageWhileUiBlockingIsDisallowed) {
  base::ScopedDisallowBlocking disallow_blocking;
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  ASSERT_TRUE(service->IsEnabled());

  AgentTask* task = service->CreateTask("summarize the approved fixture",
                                        AgentMode::kAsk, ServiceTestScope());
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task->id()));
  std::string error;
  EXPECT_TRUE(service->AcceptModelPlan(task->id(), ServicePlanEvent(), &error))
      << error;
  EXPECT_TRUE(service->GrantTaskConsent(task->id()));
}

TEST_F(AegisAgentServiceTest, RejectsUnsupportedProfileTypes) {
  Profile* auxiliary_otr = profile_->GetOffTheRecordProfile(
      Profile::OTRProfileID::CreateUniqueForTesting(),
      /*create_if_needed=*/true);
  ASSERT_TRUE(auxiliary_otr);
  EXPECT_EQ(AegisAgentServiceFactory::GetForProfile(auxiliary_otr), nullptr);

  TestingProfile* guest = profile_manager().CreateGuestProfile();
  ASSERT_TRUE(guest);
  EXPECT_EQ(AegisAgentServiceFactory::GetForProfile(guest), nullptr);

#if !BUILDFLAG(IS_CHROMEOS) && !BUILDFLAG(IS_ANDROID)
  TestingProfile* system = profile_manager().CreateSystemProfile();
  ASSERT_TRUE(system);
  EXPECT_EQ(AegisAgentServiceFactory::GetForProfile(system), nullptr);
#endif
}

TEST_F(AegisAgentServiceTest, IsolatedAcrossRegularProfiles) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);

  TestingProfile* second =
      profile_manager().CreateTestingProfile("second-profile");
  second->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, true);
  actor::ActorKeyedService::Get(second)->SetActorUiStateManagerForTesting(
      BuildActorUiStateManagerMock());
  AegisAgentService* second_service =
      AegisAgentServiceFactory::GetForProfile(second);
  ASSERT_TRUE(second_service);
  EXPECT_NE(second_service, service);
  EXPECT_EQ(second_service->task_count_for_testing(), 0u);

  TestingProfile* disabled =
      profile_manager().CreateTestingProfile("disabled-profile");
  const base::FilePath disabled_database =
      disabled->GetPath().AppendASCII("AegisAgentTasks.sqlite");
  EXPECT_EQ(AegisAgentServiceFactory::GetForProfile(disabled), nullptr);
  EXPECT_FALSE(base::PathExists(disabled_database));
}

TEST_F(AegisAgentServiceTest, ResolvesModelDestinationFromTheOwningProfile) {
  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl,
                                  "http://127.0.0.1:4111/v1/");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "profile-one");
  AegisAgentService* first = AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(first);

  TestingProfile* second =
      profile_manager().CreateTestingProfile("model-profile-two");
  second->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, true);
  second->GetPrefs()->SetString(aegis::prefs::kModelProvider, "gemini");
  second->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl,
                                "https://models.example.test/v1beta/");
  second->GetPrefs()->SetString(aegis::prefs::kModelName, "models/profile-two");
  actor::ActorKeyedService::Get(second)->SetActorUiStateManagerForTesting(
      BuildActorUiStateManagerMock());
  AegisAgentService* second_service =
      AegisAgentServiceFactory::GetForProfile(second);
  ASSERT_TRUE(second_service);

  const std::optional<AgentModelDestination> first_destination =
      first->ConfiguredModelDestination();
  const std::optional<AgentModelDestination> second_destination =
      second_service->ConfiguredModelDestination();
  ASSERT_TRUE(first_destination);
  ASSERT_TRUE(second_destination);
  EXPECT_EQ(first_destination->kind, AgentModelDestination::Kind::kLoopback);
  EXPECT_EQ(first_destination->provider, "openai");
  EXPECT_EQ(first_destination->endpoint, "http://127.0.0.1:4111/v1");
  EXPECT_EQ(first_destination->model, "profile-one");
  EXPECT_EQ(second_destination->kind, AgentModelDestination::Kind::kCloud);
  EXPECT_EQ(second_destination->provider, "gemini");
  EXPECT_EQ(second_destination->endpoint, "https://models.example.test/v1beta");
  EXPECT_EQ(second_destination->model, "models/profile-two");
}

TEST_F(AegisAgentServiceTest,
       LocalQwenAliasesDisableThinkingInActualGoalRequests) {
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl,
                                "http://127.0.0.1:8765/v1");
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  for (const auto& [model, expected] :
       std::vector<std::pair<std::string, bool>>{
           {"Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit", true},
           {"Huihui-Qwen3.5-9B-abliterated-mlx-4bit", true},
           {"huihui-ai/Huihui-Qwen3.5-9B-abliterated-mlx-4bit", true},
           {"notqwen3", false}, {"llama-3", false}}) {
    SCOPED_TRACE(model);
    profile_->GetPrefs()->SetString(aegis::prefs::kModelName, model);
    network::TestURLLoaderFactory factory;
    service->SetGoalRouterClientForTesting(
        std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
    base::test::TestFuture<bool, std::string, std::optional<AgentGoalRoute>> result;
    service->RouteGoal("整理收藏夹", AgentWorkflowKind::kResearch,
                       result.GetCallback());
    factory.WaitForRequest(endpoint);
    ASSERT_EQ(factory.NumPending(), 1);
    const auto payload = base::JSONReader::ReadDict(
        network::GetUploadData(factory.GetPendingRequest(0)->request),
        base::JSON_PARSE_RFC);
    ASSERT_TRUE(payload);
    EXPECT_EQ(payload->FindInt("max_output_tokens"), 1024);
    const auto* kwargs = payload->FindDict("chat_template_kwargs");
    if (expected) {
      ASSERT_TRUE(kwargs);
      EXPECT_EQ(kwargs->FindBool("enable_thinking"), false);
    } else {
      EXPECT_FALSE(kwargs);
    }
    EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
        endpoint.spec(),
        R"({"status":"completed","output":[{"type":"function_call","call_id":"route","name":"agent.route_goal","arguments":"{\"schema_version\":1,\"workflow\":\"browser_steward\",\"entry_kind\":\"browser_only\",\"target\":\"\",\"summary\":\"整理收藏夹\"}"}]})"));
    EXPECT_TRUE(result.Get<0>()) << result.Get<1>();
  }
}

TEST_F(AegisAgentServiceTest,
       RepairsOneMalformedGoalRouteWithoutBroadeningScope) {
  constexpr std::string_view kBaseUrl = "http://127.0.0.1:8765/v1";
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl, kBaseUrl);
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "fixture-model");

  network::TestURLLoaderFactory factory;
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  service->SetGoalRouterClientForTesting(
      std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));

  base::test::TestFuture<bool, std::string, std::optional<AgentGoalRoute>>
      route_result;
  service->RouteGoal("整理并检查失效收藏夹", AgentWorkflowKind::kResearch,
                     route_result.GetCallback());
  factory.WaitForRequest(endpoint);
  EXPECT_THAT(*factory.pending_requests(), SizeIs(1));
  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"bad-route","name":"agent.route_goal","arguments":"{\"schema_version\":1,\"workflow\":\"browser_steward\",\"target\":\"\",\"summary\":\"整理收藏夹\"}"}]})"));

  factory.WaitForRequest(endpoint);
  EXPECT_THAT(*factory.pending_requests(), SizeIs(1));
  const network::ResourceRequest& repair_request =
      factory.GetPendingRequest(0)->request;
  const std::optional<base::Value> repair_payload = base::JSONReader::Read(
      network::GetUploadData(repair_request), base::JSON_PARSE_RFC);
  ASSERT_TRUE(repair_payload && repair_payload->is_dict());
  const std::string* repair_instructions =
      repair_payload->GetDict().FindString("instructions");
  ASSERT_TRUE(repair_instructions);
  EXPECT_THAT(*repair_instructions,
              HasSubstr("single browser-approved format repair"));
  EXPECT_THAT(*repair_instructions,
              HasSubstr("Do not broaden the target, tools, origins"));

  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"fixed-route","name":"agent.route_goal","arguments":"{\"schema_version\":1,\"workflow\":\"browser_steward\",\"entry_kind\":\"browser_only\",\"target\":\"\",\"summary\":\"先读取收藏夹，再生成分类与失效链接预览\"}"}]})"));
  EXPECT_TRUE(route_result.Get<0>()) << route_result.Get<1>();
  ASSERT_TRUE(route_result.Get<2>());
  EXPECT_EQ(route_result.Get<2>()->workflow,
            AgentWorkflowKind::kBrowserSteward);
  EXPECT_EQ(route_result.Get<2>()->entry_kind,
            AgentGoalEntryKind::kBrowserOnly);
  EXPECT_TRUE(route_result.Get<2>()->target.empty());
}

TEST_F(AegisAgentServiceTest,
       RepairsOneMalformedPlanAndKeepsBrowserOwnedScope) {
  constexpr std::string_view kBaseUrl = "http://127.0.0.1:8765/v1";
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl, kBaseUrl);
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "fixture-model");

  AgentTaskScope scope = ServiceTestScope();
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = std::string(kBaseUrl);
  scope.model_destination.model = "fixture-model";

  network::TestURLLoaderFactory factory;
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTask* task =
      service->CreateTask("总结公开测试页", AgentMode::kAsk, std::move(scope));
  ASSERT_TRUE(task);
  service->SetTaskModelClientForTesting(
      task->id(),
      std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));

  base::test::TestFuture<bool, std::string> plan_result;
  service->RequestPlan(task->id(), plan_result.GetCallback());
  factory.WaitForRequest(endpoint);
  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"bad-plan","name":"agent.submit_plan","arguments":"{\"schema_version\":1,\"summary\":\"总结页面\"}"}]})"));

  factory.WaitForRequest(endpoint);
  const network::ResourceRequest& repair_request =
      factory.GetPendingRequest(0)->request;
  const std::optional<base::Value> repair_payload = base::JSONReader::Read(
      network::GetUploadData(repair_request), base::JSON_PARSE_RFC);
  ASSERT_TRUE(repair_payload && repair_payload->is_dict());
  const std::string* repair_instructions =
      repair_payload->GetDict().FindString("instructions");
  ASSERT_TRUE(repair_instructions);
  EXPECT_THAT(*repair_instructions,
              HasSubstr("single browser-approved format repair"));
  EXPECT_THAT(*repair_instructions, HasSubstr("task plan"));

  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"fixed-plan","name":"agent.submit_plan","arguments":"{\"schema_version\":1,\"summary\":\"读取并总结公开测试页\",\"steps\":[{\"id\":\"observe\",\"title\":\"读取公开页面\",\"tool\":\"page.observe\"}]}"}]})"));
  EXPECT_TRUE(plan_result.Get<0>()) << plan_result.Get<1>();
  const AgentTaskPlan* plan = service->GetPlan(task->id());
  ASSERT_TRUE(plan);
  ASSERT_EQ(plan->steps.size(), 1u);
  EXPECT_EQ(plan->steps[0].tool_name, "page.observe");
  EXPECT_EQ(plan->scope.allowed_origins, ServiceTestScope().allowed_origins);
  EXPECT_TRUE(plan->scope.AllowsTool("page.observe"));
  EXPECT_FALSE(plan->scope.AllowsTool("page.click"));
}

TEST_F(AegisAgentServiceTest,
       UsesApprovedReadOnlyRecoveryAfterTwoMalformedPlans) {
  constexpr std::string_view kBaseUrl = "http://127.0.0.1:8765/v1";
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl, kBaseUrl);
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "fixture-model");

  AgentTaskScope scope = ServiceTestScope();
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = std::string(kBaseUrl);
  scope.model_destination.model = "fixture-model";

  network::TestURLLoaderFactory factory;
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTask* task =
      service->CreateTask("总结公开测试页", AgentMode::kAsk, std::move(scope));
  ASSERT_TRUE(task);
  service->SetTaskModelClientForTesting(
      task->id(),
      std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));

  base::test::TestFuture<bool, std::string> plan_result;
  service->RequestPlan(task->id(), plan_result.GetCallback());
  for (std::string_view call_id : {"bad-plan-one", "bad-plan-two"}) {
    factory.WaitForRequest(endpoint);
    const std::string response = base::StrCat(
        {R"({"status":"completed","output":[{"type":"function_call","call_id":")",
         call_id,
         R"(","name":"agent.submit_plan","arguments":"{\"schema_version\":1,\"summary\":\"缺少步骤\"}"}]})"});
    EXPECT_TRUE(
        factory.SimulateResponseForPendingRequest(endpoint.spec(), response));
  }

  EXPECT_TRUE(plan_result.Get<0>()) << plan_result.Get<1>();
  EXPECT_EQ(task->state(), AgentTaskState::kAwaitingTaskConsent);
  const AgentTaskPlan* plan = service->GetPlan(task->id());
  ASSERT_TRUE(plan);
  ASSERT_EQ(plan->steps.size(), 1u);
  EXPECT_EQ(plan->steps[0].tool_name, "page.observe");
  EXPECT_EQ(plan->steps[0].risk, AgentRiskLevel::kR0ReadOnly);
  EXPECT_FALSE(plan->scope.AllowsTool("page.click"));
  EXPECT_TRUE(std::ranges::any_of(task->events(), [](const AgentTaskEvent& event) {
    return event.title == "planning recovery";
  }));
}

TEST_F(AegisAgentServiceTest,
       RejectedAutomationRecoveryDoesNotClaimReadOnlySuccess) {
  constexpr std::string_view kBaseUrl = "http://127.0.0.1:8765/v1";
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl, kBaseUrl);
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "fixture-model");
  AgentTaskScope scope = ServiceTestScope();
  scope.allowed_tools.insert("monitor.create");
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = std::string(kBaseUrl);
  scope.model_destination.model = "fixture-model";
  network::TestURLLoaderFactory factory;
  AegisAgentService* service = AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTask* task = service->CreateTask(
      "每15分钟监控公开页面，只读取并提醒变化", AgentMode::kAutomate,
      std::move(scope));
  ASSERT_TRUE(task);
  service->SetTaskModelClientForTesting(
      task->id(), std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
  base::test::TestFuture<bool, std::string> plan_result;
  service->RequestPlan(task->id(), plan_result.GetCallback());
  for (std::string_view call_id : {"bad-plan-one", "bad-plan-two"}) {
    factory.WaitForRequest(endpoint);
    const std::string response = base::StrCat(
        {R"({"status":"completed","output":[{"type":"function_call","call_id":")",
         call_id,
         R"(","name":"agent.submit_plan","arguments":"{\"schema_version\":1,\"summary\":\"缺少步骤\"}"}]})"});
    EXPECT_TRUE(factory.SimulateResponseForPendingRequest(endpoint.spec(), response));
  }
  EXPECT_FALSE(plan_result.Get<0>());
  EXPECT_EQ(task->state(), AgentTaskState::kFailed);
  EXPECT_FALSE(service->GetPlan(task->id()));
  for (const AgentTaskEvent& event : task->events()) {
    EXPECT_NE(event.title, "planning recovery");
  }
  EXPECT_TRUE(service->GetAllMonitors().empty());
}

TEST_F(AegisAgentServiceTest,
       RepairsBookmarkPlanThatOmitsAnExplicitUserRequirement) {
  constexpr std::string_view kBaseUrl = "http://127.0.0.1:8765/v1";
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl, kBaseUrl);
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "fixture-model");

  AgentTaskScope scope;
  scope.allowed_tools = {"bookmark.list", "bookmark.check_urls",
                         "bookmark.plan", "bookmark.apply"};
  scope.allowed_data_classes = {AgentDataClass::kBookmarks};
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = std::string(kBaseUrl);
  scope.model_destination.model = "fixture-model";
  ASSERT_TRUE(scope.IsValid());

  network::TestURLLoaderFactory factory;
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTask* task =
      service->CreateTask("检查收藏夹失效 URL，并给出分类预览，不要修改",
                          AgentMode::kAct, std::move(scope));
  ASSERT_TRUE(task);
  service->SetTaskModelClientForTesting(
      task->id(),
      std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));

  base::test::TestFuture<bool, std::string> plan_result;
  service->RequestPlan(task->id(), plan_result.GetCallback());
  factory.WaitForRequest(endpoint);
  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"incomplete-bookmark-plan","name":"agent.submit_plan","arguments":"{\"schema_version\":1,\"summary\":\"检查失效链接\",\"steps\":[{\"id\":\"list\",\"title\":\"读取收藏夹\",\"tool\":\"bookmark.list\"},{\"id\":\"check\",\"title\":\"检查链接\",\"tool\":\"bookmark.check_urls\"}]}"}]})"));

  factory.WaitForRequest(endpoint);
  const network::ResourceRequest& repair_request =
      factory.GetPendingRequest(0)->request;
  const std::optional<base::Value> repair_payload = base::JSONReader::Read(
      network::GetUploadData(repair_request), base::JSON_PARSE_RFC);
  ASSERT_TRUE(repair_payload && repair_payload->is_dict());
  const std::string* repair_instructions =
      repair_payload->GetDict().FindString("instructions");
  ASSERT_TRUE(repair_instructions);
  EXPECT_THAT(*repair_instructions,
              HasSubstr("omitted required bookmark.plan step"));

  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"complete-bookmark-plan","name":"agent.submit_plan","arguments":"{\"schema_version\":1,\"summary\":\"检查失效链接并生成分类预览\",\"steps\":[{\"id\":\"list\",\"title\":\"读取收藏夹\",\"tool\":\"bookmark.list\"},{\"id\":\"check\",\"title\":\"检查链接\",\"tool\":\"bookmark.check_urls\"},{\"id\":\"preview\",\"title\":\"生成分类预览\",\"tool\":\"bookmark.plan\"}]}"}]})"));
  EXPECT_TRUE(plan_result.Get<0>()) << plan_result.Get<1>();
  const AgentTaskPlan* plan = service->GetPlan(task->id());
  ASSERT_TRUE(plan);
  ASSERT_EQ(plan->steps.size(), 3u);
  EXPECT_EQ(plan->steps[0].tool_name, "bookmark.list");
  EXPECT_EQ(plan->steps[1].tool_name, "bookmark.check_urls");
  EXPECT_EQ(plan->steps[2].tool_name, "bookmark.plan");
  EXPECT_FALSE(plan->scope.AllowsTool("bookmark.apply"));
}

TEST_F(AegisAgentServiceTest,
       RepairsOneMalformedExecutionTurnAndNormalizesNativeCompletion) {
  constexpr std::string_view kBaseUrl = "http://127.0.0.1:8765/v1";
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl, kBaseUrl);
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "fixture-model");

  AgentTaskScope scope;
  scope.allowed_tools = {"tab.list"};
  scope.allowed_data_classes = {AgentDataClass::kBrowserMetadata};
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = std::string(kBaseUrl);
  scope.model_destination.model = "fixture-model";

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTask* task =
      service->CreateTask("列出当前标签页", AgentMode::kAct, std::move(scope));
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task->id()));
  AgentModelEvent plan_event;
  plan_event.type = AgentModelEventType::kToolCall;
  plan_event.tool_call_id = "tab-list-plan";
  plan_event.tool_name = "agent.submit_plan";
  plan_event.arguments.Set("schema_version", kAgentSchemaVersion);
  plan_event.arguments.Set("summary", "列出浏览器允许查看的标签页");
  base::DictValue step;
  step.Set("id", "list-tabs");
  step.Set("title", "读取当前标签页");
  step.Set("tool", "tab.list");
  base::ListValue steps;
  steps.Append(std::move(step));
  plan_event.arguments.Set("steps", std::move(steps));
  std::string plan_error;
  ASSERT_TRUE(service->AcceptModelPlan(task->id(), plan_event, &plan_error))
      << plan_error;
  ASSERT_TRUE(service->GrantTaskConsent(task->id()));

  network::TestURLLoaderFactory factory;
  service->SetTaskModelClientForTesting(
      task->id(),
      std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>>
      run_result;
  service->RunTask(task->id(), run_result.GetCallback());

  factory.WaitForRequest(endpoint);
  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"bad-execution","name":"tab.list","arguments":"{\"unexpected\":true}"}]})"));

  factory.WaitForRequest(endpoint);
  const network::ResourceRequest& repair_request =
      factory.GetPendingRequest(0)->request;
  const std::optional<base::Value> repair_payload = base::JSONReader::Read(
      network::GetUploadData(repair_request), base::JSON_PARSE_RFC);
  ASSERT_TRUE(repair_payload && repair_payload->is_dict());
  const std::string* repair_input =
      repair_payload->GetDict().FindString("input");
  ASSERT_TRUE(repair_input);
  EXPECT_THAT(*repair_input, HasSubstr("previous_model_call_rejected_because"));
  EXPECT_THAT(*repair_input,
              HasSubstr("tool argument contains an unknown field"));
  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"fixed-execution","name":"tab.list","arguments":"{}"}]})"));

  factory.WaitForRequest(endpoint);
  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"native-completion","name":"agent.complete","arguments":"{\"outcome\":\"completed\",\"summary\":\"已列出当前标签页。\",\"source_urls\":[\"https://fixture.example/\"],\"unfinished_items\":[]}"}]})"));

  EXPECT_TRUE(run_result.Get<0>()) << run_result.Get<1>();
  ASSERT_TRUE(run_result.Get<2>());
  EXPECT_EQ(run_result.Get<2>()->outcome, "completed");
  EXPECT_TRUE(run_result.Get<2>()->source_urls.empty());
  EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
  EXPECT_EQ(task->model_calls_used(), 3);
}

TEST_F(AegisAgentServiceTest,
       KeepsVerifiedTaskCompletedWhenFinalModelFormatFailsTwice) {
  constexpr std::string_view kBaseUrl = "http://127.0.0.1:8765/v1";
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl, kBaseUrl);
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "fixture-model");

  AgentTaskScope scope;
  scope.allowed_tools = {"tab.list"};
  scope.allowed_data_classes = {AgentDataClass::kBrowserMetadata};
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = std::string(kBaseUrl);
  scope.model_destination.model = "fixture-model";

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTask* task =
      service->CreateTask("列出当前标签页", AgentMode::kAct, std::move(scope));
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task->id()));
  AgentModelEvent plan_event;
  plan_event.type = AgentModelEventType::kToolCall;
  plan_event.tool_call_id = "tab-list-plan";
  plan_event.tool_name = "agent.submit_plan";
  plan_event.arguments.Set("schema_version", kAgentSchemaVersion);
  plan_event.arguments.Set("summary", "列出浏览器允许查看的标签页");
  base::DictValue step;
  step.Set("id", "list-tabs");
  step.Set("title", "读取当前标签页");
  step.Set("tool", "tab.list");
  base::ListValue steps;
  steps.Append(std::move(step));
  plan_event.arguments.Set("steps", std::move(steps));
  std::string plan_error;
  ASSERT_TRUE(service->AcceptModelPlan(task->id(), plan_event, &plan_error))
      << plan_error;
  ASSERT_TRUE(service->GrantTaskConsent(task->id()));

  network::TestURLLoaderFactory factory;
  service->SetTaskModelClientForTesting(
      task->id(),
      std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>>
      run_result;
  service->RunTask(task->id(), run_result.GetCallback());

  factory.WaitForRequest(endpoint);
  EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"list-tabs","name":"tab.list","arguments":"{}"}]})"));

  for (int attempt = 0; attempt < 2; ++attempt) {
    factory.WaitForRequest(endpoint);
    EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
        endpoint.spec(),
        R"({"status":"completed","output":[{"type":"function_call","call_id":"wrong-final","name":"tab.list","arguments":"{}"}]})"));
  }

  EXPECT_TRUE(run_result.Get<0>()) << run_result.Get<1>();
  ASSERT_TRUE(run_result.Get<2>());
  EXPECT_EQ(run_result.Get<2>()->outcome, "completed");
  EXPECT_THAT(run_result.Get<2>()->summary,
              HasSubstr("浏览器操作均已完成并通过核对"));
  EXPECT_TRUE(run_result.Get<2>()->source_urls.empty());
  EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
  EXPECT_EQ(task->model_calls_used(), 3);
}

TEST_F(AegisAgentServiceTest, RejectsImplicitOrInvalidCloudFallback) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  EXPECT_FALSE(service->ConfiguredModelDestination());

  AgentTask* task = service->CreateTask("must stay local", AgentMode::kAsk,
                                        ServiceTestScope());
  ASSERT_TRUE(task);
  base::test::TestFuture<bool, std::string> planning;
  service->RequestPlan(task->id(), planning.GetCallback());
  EXPECT_FALSE(planning.Get<0>());
  EXPECT_EQ(planning.Get<1>(),
            "Agent model destination is not explicitly configured");
  EXPECT_EQ(task->state(), AgentTaskState::kFailed);

  profile_->GetPrefs()->SetString(aegis::prefs::kModelProvider, "openai");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelBaseUrl,
                                  "not-a-model-endpoint");
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "fixture-model");
  EXPECT_FALSE(service->ConfiguredModelDestination());
}

TEST_F(AegisAgentServiceTest, RejectsGoalsThatCannotBeSafelyPersisted) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  EXPECT_EQ(service->CreateTask("password=fixture-secret", AgentMode::kAsk,
                                ServiceTestScope()),
            nullptr);
  EXPECT_EQ(service->CreateTask("access_token=fixture-secret", AgentMode::kAsk,
                                ServiceTestScope()),
            nullptr);
  EXPECT_EQ(service->CreateTask(std::string("line\0secret", 11),
                                AgentMode::kAsk, ServiceTestScope()),
            nullptr);
  EXPECT_EQ(service->CreateTask(std::string(4097, 'x'), AgentMode::kAsk,
                                ServiceTestScope()),
            nullptr);
  EXPECT_EQ(service->task_count_for_testing(), 0u);
}

TEST_F(AegisAgentServiceTest, BookmarkUrlChecksRejectLocalNetworkTargets) {
  AgentTaskScope scope = ServiceTestScope();
  const GURL public_url("https://public.example/path");
  scope.allowed_origins.push_back(url::Origin::Create(public_url));
  EXPECT_TRUE(
      IsAegisBookmarkUrlCheckTargetAllowed(scope, public_url, public_url));
  EXPECT_FALSE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, GURL("http://localhost/status"), GURL("http://localhost/status")));
  EXPECT_FALSE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, GURL("http://127.0.0.1/status"), GURL("http://127.0.0.1/status")));
  EXPECT_FALSE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, GURL("http://10.0.0.7/status"), GURL("http://10.0.0.7/status")));
  EXPECT_FALSE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, GURL("http://[::1]/status"), GURL("http://[::1]/status")));
  EXPECT_FALSE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, public_url, GURL("http://localhost/redirected")));
}

TEST_F(AegisAgentServiceTest,
       BookmarkUrlChecksAllowOnlyExactNumericLoopbackFixtureOrigin) {
  AgentTaskScope scope = ServiceTestScope();
  const GURL ipv4_fixture("http://127.0.0.1:18765/live");
  const GURL ipv6_fixture("http://[::1]:18765/live");
  EXPECT_TRUE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, ipv4_fixture, GURL("http://127.0.0.1:18765/redirected"), true));
  EXPECT_TRUE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, ipv6_fixture, GURL("http://[::1]:18765/redirected"), true));
  EXPECT_FALSE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, ipv4_fixture, GURL("http://127.0.0.1:18766/redirected"), true));
  EXPECT_FALSE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, ipv4_fixture, GURL("http://localhost:18765/redirected"), true));
  EXPECT_FALSE(IsAegisBookmarkUrlCheckTargetAllowed(
      scope, GURL("http://10.0.0.7:18765/live"),
      GURL("http://10.0.0.7:18765/redirected"), true));
}

TEST_F(AegisAgentServiceTest, LaterBookmarkEditInvalidatesUndoReceipt) {
  AegisBrowserTools tools(profile_);
  UndoManager undo_manager;
  AegisBrowserToolsTestPeer::SeedUndoReceipt(&tools, &undo_manager);
  EXPECT_EQ(AegisBrowserToolsTestPeer::UndoReceiptCount(tools), 1u);
  EXPECT_TRUE(AegisBrowserToolsTestPeer::IsObserving(tools, &undo_manager));

  undo_manager.Shutdown();
  EXPECT_EQ(AegisBrowserToolsTestPeer::UndoReceiptCount(tools), 0u);
  EXPECT_FALSE(AegisBrowserToolsTestPeer::IsObserving(tools, &undo_manager));
}

TEST_F(AegisAgentServiceTest, DownloadReviewReadsCurrentFileAndRejectsChanges) {
  base::ScopedAllowBlockingForTesting allow_blocking;
  base::ScopedTempDir temporary;
  ASSERT_TRUE(temporary.CreateUniqueTempDir());
  const auto file = temporary.GetPath().AppendASCII("download.bin");
  const std::string sha =
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  ASSERT_TRUE(base::WriteFile(file, "abc"));
  auto result = ReviewAegisDownloadedFile(file, sha);
  EXPECT_EQ(*result.FindString("status"), "match");
  EXPECT_EQ(*result.FindString("sha256"), sha);
  ASSERT_TRUE(base::WriteFile(file, "changed"));
  EXPECT_EQ(*ReviewAegisDownloadedFile(file, sha).FindString("status"),
            "changed");
  const auto missing = temporary.GetPath().AppendASCII("missing.bin");
  EXPECT_EQ(*ReviewAegisDownloadedFile(missing, sha).FindString("status"),
            "missing");
  EXPECT_FALSE(ReviewAegisDownloadedFile(file, "invalid").contains("sha256"));
  base::File oversized(temporary.GetPath().AppendASCII("large.bin"),
                       base::File::FLAG_CREATE | base::File::FLAG_WRITE);
  ASSERT_TRUE(oversized.SetLength(1024LL * 1024 * 1024 + 1));
  oversized.Close();
  EXPECT_EQ(*ReviewAegisDownloadedFile(
                 temporary.GetPath().AppendASCII("large.bin"), sha)
                 .FindString("status"),
            "too_large");
}

TEST_F(AegisAgentServiceTest, DownloadReviewRejectsTaskWithoutNativeReceipt) {
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  base::test::TestFuture<base::DictValue> result;
  service->ReviewDownload("unknown-task", result.GetCallback());
  EXPECT_EQ(*result.Get().FindString("status"), "unavailable");
}

TEST_F(AegisAgentServiceTest, TaskStopCancelsOnlyActiveOwnedDownloads) {
  download::MockDownloadItem active;
  EXPECT_CALL(active, GetState())
      .WillOnce(Return(download::DownloadItem::IN_PROGRESS));
  EXPECT_CALL(active, Cancel(true));
  CancelAegisOwnedDownloadOnTaskStop(&active);

  download::MockDownloadItem interrupted;
  EXPECT_CALL(interrupted, GetState())
      .WillOnce(Return(download::DownloadItem::INTERRUPTED));
  EXPECT_CALL(interrupted, Cancel(true));
  CancelAegisOwnedDownloadOnTaskStop(&interrupted);

  download::MockDownloadItem complete;
  EXPECT_CALL(complete, GetState())
      .WillOnce(Return(download::DownloadItem::COMPLETE));
  EXPECT_CALL(complete, Cancel(true)).Times(0);
  CancelAegisOwnedDownloadOnTaskStop(&complete);
}

TEST_F(AegisAgentServiceTest,
       DownloadVerificationWaitsOnlyWhileAnActiveDownloadProgresses) {
  download::MockDownloadItem active;
  EXPECT_CALL(active, GetState())
      .WillOnce(Return(download::DownloadItem::IN_PROGRESS));
  EXPECT_CALL(active, IsPaused()).WillOnce(Return(false));
  EXPECT_TRUE(
      AegisBrowserToolsTestPeer::ShouldWaitForDownloadVerification(&active));

  download::MockDownloadItem paused;
  EXPECT_CALL(paused, GetState())
      .WillOnce(Return(download::DownloadItem::IN_PROGRESS));
  EXPECT_CALL(paused, IsPaused()).WillOnce(Return(true));
  EXPECT_FALSE(
      AegisBrowserToolsTestPeer::ShouldWaitForDownloadVerification(&paused));

  download::MockDownloadItem complete;
  EXPECT_CALL(complete, GetState())
      .WillOnce(Return(download::DownloadItem::COMPLETE));
  EXPECT_CALL(complete, IsPaused()).Times(0);
  EXPECT_FALSE(
      AegisBrowserToolsTestPeer::ShouldWaitForDownloadVerification(&complete));
}

TEST_F(AegisAgentServiceTest, IdempotentActionIdsBindTheExactCall) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTaskScope scope = ServiceTestScope();
  scope.allowed_tools = {"tab.list", "page.observe"};
  scope.allowed_data_classes.insert(AgentDataClass::kBrowserMetadata);
  AgentTask* task =
      service->CreateTask("list tabs once", AgentMode::kAct, std::move(scope));
  ASSERT_TRUE(task);
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "test"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kAwaitingTaskConsent, "test"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRunning, "test"));

  AgentToolCall call;
  call.action_id = "exact-action-1";
  call.tool_name = "tab.list";
  EXPECT_EQ(service->EvaluateToolCall(task->id(), call).disposition,
            AgentPolicyDisposition::kAllow);
  EXPECT_EQ(task->tool_calls_used(), 1);
  EXPECT_EQ(service->EvaluateToolCall(task->id(), call).error,
            AgentErrorCode::kInvalidRequest);
  EXPECT_EQ(task->tool_calls_used(), 1);
  AgentToolResult result;
  result.action_id = call.action_id;
  result.ok = true;
  result.message = "browser result";
  ASSERT_TRUE(service->RecordToolResult(task->id(), std::move(result)));

  EXPECT_EQ(service->EvaluateToolCall(task->id(), call).disposition,
            AgentPolicyDisposition::kAllow);
  EXPECT_EQ(task->tool_calls_used(), 1);
  AgentToolCall mismatch;
  mismatch.action_id = call.action_id;
  mismatch.tool_name = "page.observe";
  mismatch.arguments.Set("tab_id", 7);
  EXPECT_EQ(service->EvaluateToolCall(task->id(), mismatch).error,
            AgentErrorCode::kInvalidRequest);
}

TEST_F(AegisAgentServiceTest, CreatesPausesResumesAndStopsOwnedActorTask) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTask* task = service->CreateTask("operate local fixture",
                                        AgentMode::kAct, ServiceTestScope());
  ASSERT_TRUE(task);
  const std::string task_id = task->id();
  EXPECT_TRUE(InstallServicePlan(service, task));
  EXPECT_TRUE(service->GrantTaskConsent(task_id));
  EXPECT_TRUE(service->actor_bridge_for_testing().HasTask(task_id));
  EXPECT_TRUE(service->PauseTask(task_id));
  EXPECT_TRUE(service->ResumeTask(task_id));
  EXPECT_TRUE(service->CancelTask(task_id));
  EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task_id));
  EXPECT_EQ(task->state(), AgentTaskState::kCancelled);
}

TEST_F(AegisAgentServiceTest,
       BookmarkUndoUpdatesSummaryOnlyAfterVerifiedRestore) {
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  for (int scenario = 0; scenario < 3; ++scenario) {
    SCOPED_TRACE(scenario);
    auto scope = ServiceTestScope();
    scope.allowed_tools.insert("bookmark.undo");
    auto* task = service->CreateTask("撤销收藏整理", AgentMode::kAct, scope);
    ASSERT_TRUE(task);
    for (auto state :
         {AgentTaskState::kPlanning, AgentTaskState::kAwaitingTaskConsent,
          AgentTaskState::kRunning, AgentTaskState::kVerifying,
          AgentTaskState::kCompleted}) {
      ASSERT_TRUE(task->TransitionTo(state, "准备已完成的整理任务"));
    }
    AgentToolResult result;
    result.ok = scenario != 2;
    result.error =
        result.ok ? AgentErrorCode::kNone : AgentErrorCode::kVerificationFailed;
    result.message = "原生撤销回调";
    if (scenario != 1) {
      result.value.Set("snapshot_hash", "恢复树的原生回读摘要");
    }
    base::test::TestFuture<AgentToolResult> completed;
    AegisAgentServiceTestPeer::DeliverBookmarkUndo(
        service, task->id(), std::move(result), completed.GetCallback());
    EXPECT_EQ(completed.Get().ok, scenario == 0);
    const auto* summary = service->GetCompletionSummary(task->id());
    ASSERT_TRUE(summary);
    if (scenario == 0) {
      EXPECT_THAT(summary->summary, HasSubstr("已撤销本次收藏整理"));
    } else {
      EXPECT_EQ(summary->summary, "原整理已完成");
    }
  }
}

TEST_F(AegisAgentServiceTest, IntermediateTakeoverRevokesPendingAction) {
  network::TestURLLoaderFactory factory;
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>>
      done;
  auto* task = StartHeldRuntime(&factory, done.GetCallback(), "page.click");
  ASSERT_TRUE(task);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  AegisAgentServiceTestPeer::DeliverPendingApproval(service, task->id());
  ASSERT_TRUE(service->PendingAction(task->id()));
  const auto calls = task->model_calls_used();
  ASSERT_TRUE(service->BeginUserTakeover(task->id()));
  EXPECT_EQ(task->state(), AgentTaskState::kUserTakeover);
  EXPECT_FALSE(service->PendingAction(task->id()));
  EXPECT_FALSE(service->ApprovePendingAction(task->id()));
  EXPECT_EQ(task->model_calls_used(), calls);
  EXPECT_FALSE(done.IsReady());
  ASSERT_TRUE(service->FinishUserTakeover(task->id()));
  EXPECT_EQ(task->state(), AgentTaskState::kRecovering);
  EXPECT_FALSE(service->PendingAction(task->id()));
  EXPECT_FALSE(service->ApprovePendingAction(task->id()));
  EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task->id()));
  EXPECT_FALSE(done.Get<0>());
  EXPECT_EQ(task->model_calls_used(), calls);
  EXPECT_TRUE(service->CancelTask(task->id()));
}

TEST_F(AegisAgentServiceTest, PageChangeRevokesPendingApprovalImmediately) {
  network::TestURLLoaderFactory factory;
  base::test::TestFuture<bool, std::string, std::optional<AgentCompletionSummary>> done;
  auto* task = StartHeldRuntime(&factory, done.GetCallback(), "page.click");
  ASSERT_TRUE(task);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  AegisAgentServiceTestPeer::DeliverPendingApproval(service, task->id());
  ASSERT_TRUE(service->PendingAction(task->id()));
  const auto calls = task->model_calls_used();
  AegisAgentServiceTestPeer::InvalidatePendingPage(service, task->id());
  EXPECT_EQ(task->state(), AgentTaskState::kExpired);
  EXPECT_FALSE(service->PendingAction(task->id()));
  EXPECT_FALSE(service->ApprovePendingAction(task->id()));
  EXPECT_EQ(task->model_calls_used(), calls);
  ASSERT_TRUE(done.IsReady());
  EXPECT_FALSE(done.Get<0>());
  EXPECT_TRUE(done.Get<1>().contains("原操作已失效"));
  AegisAgentServiceTestPeer::InvalidatePendingPage(service, task->id());
}

TEST_F(AegisAgentServiceTest, StalePageEvidenceCannotReachCompletion) {
  network::TestURLLoaderFactory factory;
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>> done;
  auto* task = StartHeldRuntime(&factory, done.GetCallback());
  ASSERT_TRUE(task);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  AegisAgentServiceTestPeer::DeliverRuntimeResult(service, task->id(),
                                                 "tab.list", true);
  const int calls = task->model_calls_used();
  base::DictValue value;
  value.Set("tab_id", 7);
  value.Set("document_token", "expired-document");
  value.Set("url", "https://fixture.example/old");
  value.Set("visible_text_untrusted", "旧文档的事实");
  AegisAgentServiceTestPeer::DeliverRuntimeResult(
      service, task->id(), "page.observe", true, std::move(value));
  EXPECT_EQ(task->state(), AgentTaskState::kFailed);
  EXPECT_FALSE(done.Get<0>());
  EXPECT_FALSE(done.Get<2>().has_value());
  EXPECT_EQ(task->model_calls_used(), calls);
  EXPECT_FALSE(AegisAgentServiceTestPeer::HasRuntime(service, task->id()));
}

TEST_F(AegisAgentServiceTest, CancelRejectsSynchronousActorStopResult) {
  network::TestURLLoaderFactory factory;
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>>
      done;
  auto* task = StartHeldRuntime(&factory, done.GetCallback());
  ASSERT_TRUE(task);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service->actor_bridge_for_testing().HasTask(task->id()));
  const auto before = AegisAgentServiceTestPeer::Progress(service, task->id());
  const auto calls = task->model_calls_used();
  bool synchronous_result_delivered = false;
  auto subscription =
      actor::ActorKeyedService::Get(profile_)->AddTaskStateChangedCallback(
          base::BindLambdaForTesting([&](actor::ActorTask& actor_task) {
            if (!actor_task.IsCompleted()) {
              return;
            }
            synchronous_result_delivered = true;
            EXPECT_TRUE(
                AegisAgentServiceTestPeer::HasRuntime(service, task->id()));
            AegisAgentServiceTestPeer::DeliverRuntimeResult(service, task->id(),
                                                            "tab.list", true);
          }));
  EXPECT_TRUE(service->CancelTask(task->id()));
  EXPECT_TRUE(synchronous_result_delivered);
  EXPECT_EQ(AegisAgentServiceTestPeer::Progress(service, task->id()), before);
  EXPECT_EQ(task->model_calls_used(), calls);
  EXPECT_FALSE(done.Get<0>());
  EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task->id()));
  EXPECT_FALSE(AegisAgentServiceTestPeer::HasRuntime(service, task->id()));
}

TEST_F(AegisAgentServiceTest, FailedRuntimeDetachesBeforeActorStops) {
  network::TestURLLoaderFactory factory;
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>>
      done;
  auto* task = StartHeldRuntime(&factory, done.GetCallback());
  ASSERT_TRUE(task);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  bool stopped = false;
  auto subscription =
      actor::ActorKeyedService::Get(profile_)->AddTaskStateChangedCallback(
          base::BindLambdaForTesting([&](actor::ActorTask& actor_task) {
            if (!actor_task.IsCompleted()) {
              return;
            }
            stopped = true;
            EXPECT_FALSE(
                AegisAgentServiceTestPeer::HasRuntime(service, task->id()));
          }));
  AegisAgentServiceTestPeer::FailRuntime(service, task->id());
  EXPECT_TRUE(stopped);
  EXPECT_FALSE(done.Get<0>());
  EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task->id()));
}

TEST_F(AegisAgentServiceTest, ReadOnlyFailureHasAtMostTwoRecoveries) {
  network::TestURLLoaderFactory factory;
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>>
      done;
  auto* task = StartHeldRuntime(&factory, done.GetCallback());
  ASSERT_TRUE(task);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  const auto initial_calls = task->model_calls_used();
  for (int attempt = 1; attempt <= 3; ++attempt) {
    AegisAgentServiceTestPeer::DeliverRuntimeResult(service, task->id(),
                                                    "tab.list", false);
    EXPECT_EQ(AegisAgentServiceTestPeer::Progress(service, task->id()).second,
              attempt);
    EXPECT_EQ(task->model_calls_used(), initial_calls + std::min(attempt, 2));
    if (attempt < 3) {
      EXPECT_FALSE(done.IsReady());
    }
  }
  EXPECT_FALSE(done.Get<0>());
  EXPECT_EQ(task->state(), AgentTaskState::kFailed);
  EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task->id()));
}

TEST_F(AegisAgentServiceTest, ChangedModelDestinationStopsRecovery) {
  network::TestURLLoaderFactory factory;
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>>
      done;
  auto* task = StartHeldRuntime(&factory, done.GetCallback());
  ASSERT_TRUE(task);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  const auto calls = task->model_calls_used();
  profile_->GetPrefs()->SetString(aegis::prefs::kModelName, "changed-model");
  AegisAgentServiceTestPeer::DeliverRuntimeResult(service, task->id(),
                                                  "tab.list", false);
  EXPECT_EQ(task->model_calls_used(), calls);
  EXPECT_EQ(task->state(), AgentTaskState::kFailed);
  EXPECT_FALSE(done.Get<0>());
  EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task->id()));
}

TEST_F(AegisAgentServiceTest, DisabledWebMcpRejectsDirectBridgeCalls) {
  base::test::ScopedFeatureList disabled;
  disabled.InitAndDisableFeature(aegis::features::kAegisAgentWebMcp);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  for (const char* tool : {"page.webmcp.list", "page.webmcp.invoke"}) {
    AgentToolCall call;
    call.action_id = "disabled-webmcp";
    call.tool_name = tool;
    base::test::TestFuture<AgentToolResult> result;
    service->actor_bridge_for_testing().ExecutePageTool("missing-task", call,
                                                        result.GetCallback());
    EXPECT_FALSE(result.Get().ok);
    EXPECT_EQ(result.Get().error, AgentErrorCode::kToolUnavailable);
    EXPECT_EQ(result.Get().message, "WebMCP is disabled");
  }
}

TEST_F(AegisAgentServiceTest, UncertainR1AndR2ResultsAreNotReplayed) {
  for (const auto* tool : {"page.navigate", "page.click"}) {
    SCOPED_TRACE(tool);
    network::TestURLLoaderFactory factory;
    base::test::TestFuture<bool, std::string,
                           std::optional<AgentCompletionSummary>>
        done;
    auto* task = StartHeldRuntime(&factory, done.GetCallback(), tool);
    ASSERT_TRUE(task);
    auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
    AegisAgentServiceTestPeer::DeliverRuntimeResult(service, task->id(),
                                                    "tab.list", true);
    const auto calls = task->model_calls_used();
    ASSERT_TRUE(AegisAgentServiceTestPeer::HasRuntime(service, task->id()));
    AegisAgentServiceTestPeer::DeliverRuntimeResult(service, task->id(), tool,
                                                    false);
    EXPECT_EQ(task->model_calls_used(), calls);
    EXPECT_EQ(task->state(), AgentTaskState::kFailed);
    EXPECT_FALSE(done.Get<0>());
    EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task->id()));
  }
}

TEST_F(AegisAgentServiceTest, FailedDownloadRetainsActualEvidenceAfterRetries) {
  network::TestURLLoaderFactory factory;
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>>
      done;
  auto* task =
      StartHeldRuntime(&factory, done.GetCallback(), "download.verify");
  ASSERT_TRUE(task);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  const std::string id = task->id();
  AegisAgentServiceTestPeer::DeliverRuntimeResult(service, id, "tab.list",
                                                  true);
  AegisAgentServiceTestPeer::DeliverRuntimeResult(
      service, id, "download.find_official", true);
  AegisAgentServiceTestPeer::DeliverRuntimeResult(service, id, "download.start",
                                                  true);
  for (int attempt = 0; attempt < 3; ++attempt) {
    base::DictValue value;
    value.Set("download_id", "fixture-download");
    value.Set("file_name", "incomplete.bin");
    value.Set("state", "interrupted");
    value.Set("received_bytes", "42");
    value.Set("verified", false);
    value.Set("integrity", "not_matched");
    AegisAgentServiceTestPeer::DeliverRuntimeResult(
        service, id, "download.verify", false, std::move(value));
  }
  EXPECT_FALSE(done.Get<0>());
  EXPECT_EQ(task->state(), AgentTaskState::kFailed);
  const auto evidence = service->GetDownloadEvidence(id);
  ASSERT_TRUE(evidence.FindString("file_name"));
  EXPECT_EQ(*evidence.FindString("file_name"), "incomplete.bin");
  EXPECT_EQ(*evidence.FindString("verified"), "no");
  EXPECT_EQ(*evidence.FindString("received_bytes"), "42");
  EXPECT_EQ(*evidence.FindString("signature"), "not_verified");
  EXPECT_FALSE(evidence.contains("sha256"));
}

TEST_F(AegisAgentServiceTest,
       NewUrlApprovalBlocksDispatchWithoutSpendingBudget) {
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  auto scope = ServiceTestScope();
  scope.allowed_tools.insert("tab.create");
  scope.allowed_data_classes.insert(AgentDataClass::kBrowserMetadata);
  auto* task = service->CreateTask("检查新地址审批", AgentMode::kAct, scope);
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task->id()));
  auto event = ServicePlanEvent();
  event.arguments.Set("steps",
                      base::ListValue().Append(base::DictValue()
                                                   .Set("id", "open")
                                                   .Set("title", "打开新地址")
                                                   .Set("tool", "tab.create")));
  std::string error;
  ASSERT_TRUE(service->AcceptModelPlan(task->id(), event, &error)) << error;
  ASSERT_TRUE(service->GrantTaskConsent(task->id()));
  AgentToolCall call;
  call.action_id = "url-call";
  call.tool_name = "tab.create";
  call.committed_url = GURL("https://fixture.example/current");
  call.arguments.Set("url", "https://fixture.example/new?synthetic=private");
  const int before = task->tool_calls_used();
  base::test::TestFuture<AgentToolResult> blocked;
  service->ExecuteTool(task->id(), call, blocked.GetCallback());
  EXPECT_EQ(blocked.Get().error, AgentErrorCode::kApprovalRequired)
      << blocked.Get().message;
  EXPECT_EQ(task->state(), AgentTaskState::kAwaitingActionApproval);
  EXPECT_EQ(task->tool_calls_used(), before);
  EXPECT_TRUE(task->owned_tab_ids().empty());
  EXPECT_EQ(service->ToolCallRisk(task->id(), call),
            AgentRiskLevel::kR2ExternalSideEffect);
  EXPECT_EQ(service->TaskMaxRisk(task->id()),
            AgentRiskLevel::kR2ExternalSideEffect);
  const auto receipt = service->ApproveToolCall(task->id(), call);
  ASSERT_TRUE(receipt);
  EXPECT_EQ(service->EvaluateToolCall(task->id(), call, receipt->approval_id)
                .disposition,
            AgentPolicyDisposition::kAllow);
  EXPECT_EQ(task->tool_calls_used(), before + 1);
  EXPECT_EQ(service->TaskMaxRisk(task->id()),
            AgentRiskLevel::kR2ExternalSideEffect);
  ASSERT_TRUE(service->CancelTask(task->id()));
  EXPECT_EQ(service->EvaluateToolCall(task->id(), call, receipt->approval_id)
                .disposition,
            AgentPolicyDisposition::kDeny);
}

TEST_F(AegisAgentServiceTest,
       RetryApprovalBlocksDispatchWithoutSpendingBudget) {
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  auto scope = ServiceTestScope();
  scope.allowed_tools.insert("tab.create");
  scope.allowed_data_classes.insert(AgentDataClass::kBrowserMetadata);
  auto* task = service->CreateTask("检查新地址审批", AgentMode::kAct, scope);
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task->id()));
  auto event = ServicePlanEvent();
  event.arguments.Set("steps",
                      base::ListValue().Append(base::DictValue()
                                                   .Set("id", "open")
                                                   .Set("title", "打开新地址")
                                                   .Set("tool", "tab.create")));
  std::string error;
  ASSERT_TRUE(service->AcceptModelPlan(task->id(), event, &error)) << error;
  ASSERT_TRUE(service->GrantTaskConsent(task->id()));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kReflecting,
                                  "绑定失败后的重试"));
  AgentToolCall call;
  call.action_id = "url-call";
  call.tool_name = "tab.create";
  call.committed_url = GURL("https://fixture.example/current");
  call.arguments.Set("url", "https://fixture.example/new?synthetic=private");
  const int before = task->tool_calls_used();
  base::test::TestFuture<AgentToolResult> blocked;
  service->ExecuteTool(task->id(), call, blocked.GetCallback());
  EXPECT_EQ(blocked.Get().error, AgentErrorCode::kApprovalRequired)
      << blocked.Get().message;
  EXPECT_EQ(task->state(), AgentTaskState::kAwaitingActionApproval);
  EXPECT_EQ(task->tool_calls_used(), before);
  EXPECT_TRUE(task->owned_tab_ids().empty());
  EXPECT_EQ(service->ToolCallRisk(task->id(), call),
            AgentRiskLevel::kR2ExternalSideEffect);
  EXPECT_EQ(service->TaskMaxRisk(task->id()),
            AgentRiskLevel::kR2ExternalSideEffect);
  const auto receipt = service->ApproveToolCall(task->id(), call);
  ASSERT_TRUE(receipt);
  EXPECT_EQ(service->EvaluateToolCall(task->id(), call, receipt->approval_id)
                .disposition,
            AgentPolicyDisposition::kAllow);
  EXPECT_EQ(task->tool_calls_used(), before + 1);
  EXPECT_EQ(service->TaskMaxRisk(task->id()),
            AgentRiskLevel::kR2ExternalSideEffect);
  ASSERT_TRUE(service->CancelTask(task->id()));
  EXPECT_EQ(service->EvaluateToolCall(task->id(), call, receipt->approval_id)
                .disposition,
            AgentPolicyDisposition::kDeny);
}

TEST_F(AegisAgentServiceTest, DataSourcesIncludeRetainedFailedReadResults) {
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  auto scope = ServiceTestScope();
  scope.allowed_tab_ids.insert(7);
  auto* task = service->CreateTask("记录已读取来源", AgentMode::kAct, scope);
  ASSERT_TRUE(task);
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "测试"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kAwaitingTaskConsent, "测试"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRunning, "测试"));
  AgentToolCall call;
  call.action_id = "failed-read";
  call.tool_name = "page.observe";
  call.committed_url = GURL("https://fixture.example/source?private=synthetic");
  call.arguments.Set("tab_id", 7);
  ASSERT_EQ(service->EvaluateToolCall(task->id(), call).disposition,
            AgentPolicyDisposition::kAllow);
  AgentToolResult result;
  result.action_id = call.action_id;
  result.error = AgentErrorCode::kVerificationFailed;
  result.message = "字段不全但已保留部分正文";
  result.value.Set("url", "https://fixture.example/source?private=synthetic");
  ASSERT_TRUE(service->RecordToolResult(task->id(), std::move(result)));
  EXPECT_EQ(service->ObservedSourceOrigins(task->id()),
            std::vector<std::string>({"https://fixture.example"}));
  EXPECT_TRUE(service->ObservedSourceOrigins("other-task").empty());
}

TEST_F(AegisAgentServiceTest, AskModeUsesReadOnlyActorObservationTask) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  AgentTask* task = service->CreateTask("summarize fixture", AgentMode::kAsk,
                                        ServiceTestScope());
  ASSERT_TRUE(task);
  EXPECT_TRUE(InstallServicePlan(service, task));
  EXPECT_TRUE(service->GrantTaskConsent(task->id()));
  EXPECT_EQ(service->actor_bridge_for_testing().active_task_count_for_testing(),
            1u);
  EXPECT_TRUE(task->TransitionTo(AgentTaskState::kVerifying, "verified"));
  EXPECT_TRUE(service->CompleteTask(task->id()));
  EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
}

TEST_F(AegisAgentServiceTest,
       RestoresWithoutReplayAndRequiresFreshConsentAndObservation) {
  std::string task_id;
  {
    AegisAgentService original(profile_);
    AgentTask* task = original.CreateTask("recover local fixture",
                                          AgentMode::kAct, ServiceTestScope());
    ASSERT_TRUE(task);
    task_id = task->id();
    ASSERT_TRUE(InstallServicePlan(&original, task));
    ASSERT_TRUE(original.GrantTaskConsent(task_id));
    ASSERT_TRUE(task->ConsumeModelCall());
    original.Shutdown();
    FlushTaskStore(&original);
  }

  DrainTaskRunners();
  AegisAgentService recovered(profile_);
  FlushTaskStore(&recovered);
  AgentTask* task = recovered.GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_EQ(task->goal(), "recover local fixture");
  EXPECT_EQ(task->state(), AgentTaskState::kRecovering);
  EXPECT_EQ(task->model_calls_used(), 1);
  EXPECT_FALSE(recovered.actor_bridge_for_testing().HasTask(task_id));
  EXPECT_EQ(recovered.recovery_disposition(task_id),
            StoredAgentTask::RecoveryDisposition::kResumeReadOnly);

  ASSERT_TRUE(recovered.GrantRecoveryConsent(task_id));
  EXPECT_EQ(task->state(), AgentTaskState::kRunning);
  EXPECT_TRUE(recovered.actor_bridge_for_testing().HasTask(task_id));
  EXPECT_FALSE(recovered.actor_bridge_for_testing()
                   .LastDocument(task_id, /*tab_id=*/1)
                   .has_value());
  recovered.Shutdown();
}

TEST_F(AegisAgentServiceTest,
       ImmediateMonitorCheckPreservesOwnershipAndBudget) {
  auto* service = AegisAgentServiceFactory::GetForProfile(profile_);
  auto scope = ServiceTestScope();
  scope.allowed_tools.insert("monitor.create");
  auto* task =
      service->CreateTask("每小时检查页面", AgentMode::kAutomate, scope);
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task->id()));
  std::string error;
  ASSERT_TRUE(service->AcceptModelPlan(task->id(), ServiceAutomationPlanEvent(),
                                       &error))
      << error;
  ASSERT_TRUE(service->GrantTaskConsent(task->id()));
  AgentMonitorDefinition monitor;
  monitor.monitor_id = "manual-check";
  monitor.task_id = task->id();
  monitor.origin = url::Origin::Create(GURL("https://fixture.example/path"));
  monitor.target_url = GURL("https://fixture.example/path");
  monitor.target_hash = "sha256:manual-fixture";
  monitor.session_only = true;
  monitor.interval = base::Hours(1);
  monitor.next_run = base::Time::Now() + monitor.interval;
  ASSERT_TRUE(service->UpsertMonitor(monitor));
  EXPECT_FALSE(service->CheckMonitorNow("another-task", monitor.monitor_id));
  EXPECT_FALSE(service->CheckMonitorNow(task->id(), "unknown-monitor"));
  ASSERT_TRUE(service->SetMonitorPaused(task->id(), monitor.monitor_id, true));
  EXPECT_FALSE(service->CheckMonitorNow(task->id(), monitor.monitor_id));
  EXPECT_EQ(task->network_requests_used(), 0);
  ASSERT_TRUE(service->SetMonitorPaused(task->id(), monitor.monitor_id, false));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kUserTakeover, "用户接管"));
  EXPECT_FALSE(service->CheckMonitorNow(task->id(), monitor.monitor_id));
  EXPECT_EQ(task->network_requests_used(), 0);
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRecovering, "等待重新确认"));
  EXPECT_FALSE(service->CheckMonitorNow(task->id(), monitor.monitor_id));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRunning, "已重新确认"));
  ASSERT_TRUE(service->CheckMonitorNow(task->id(), monitor.monitor_id));
  EXPECT_EQ(task->network_requests_used(), 1);
  // 无实际窗口的单元环境不会声称读取成功，但立即请求仍须扣一次预算。
  EXPECT_FALSE(service->CheckMonitorNow(task->id(), monitor.monitor_id));
  EXPECT_EQ(task->network_requests_used(), 1);
  auto monitors = service->GetMonitors(task->id());
  ASSERT_EQ(monitors.size(), 1u);
  EXPECT_EQ(monitors[0].interval, base::Hours(1));
  EXPECT_GT(monitors[0].next_run, base::Time::Now());
  EXPECT_EQ(monitors[0].last_run, base::Time::Now());
}

TEST_F(AegisAgentServiceTest, PersistsAndBoundsBrowserLifetimeMonitors) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTaskScope scope = ServiceTestScope();
  scope.allowed_tools.insert("monitor.create");
  AgentTask* task = service->CreateTask("monitor fixture", AgentMode::kAutomate,
                                        std::move(scope));
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task->id()));
  const AgentModelEvent plan = ServiceAutomationPlanEvent();
  std::string plan_error;
  ASSERT_TRUE(service->AcceptModelPlan(task->id(), plan, &plan_error))
      << plan_error;
  ASSERT_TRUE(service->GrantTaskConsent(task->id()));

  const base::Time now = base::Time::Now();
  AgentMonitorDefinition monitor;
  monitor.monitor_id = "monitor-service-1";
  monitor.task_id = task->id();
  monitor.kind = AgentMonitorKind::kPageChange;
  monitor.origin = url::Origin::Create(GURL("https://fixture.example/path"));
  monitor.target_hash = "sha256:fixture-target";
  monitor.target_ciphertext = "encrypted-service-fixture";
  monitor.interval = base::Minutes(15);
  monitor.next_run = now;
  ASSERT_TRUE(service->UpsertMonitor(monitor));
  ASSERT_EQ(service->GetMonitors(task->id()).size(), 1u);

  std::vector<AgentMonitorDefinition> due = service->ClaimDueMonitors(now);
  ASSERT_EQ(due.size(), 1u);
  EXPECT_EQ(due[0].monitor_id, monitor.monitor_id);
  EXPECT_EQ(task->network_requests_used(), 1);
  EXPECT_TRUE(service->ClaimDueMonitors(now).empty());

  ASSERT_TRUE(service->MarkMonitorFinished(task->id(), monitor.monitor_id,
                                           /*success=*/false, now));
  ASSERT_EQ(service->GetMonitors(task->id()).size(), 1u);
  EXPECT_GT(service->GetMonitors(task->id())[0].next_run,
            now + monitor.interval);
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kVerifying, "verified"));
  ASSERT_TRUE(service->CompleteTask(task->id()));
  std::vector<AgentMonitorDefinition> completed_due =
      service->ClaimDueMonitors(base::Time::Now() + base::Hours(2));
  ASSERT_EQ(completed_due.size(), 1u);
  EXPECT_EQ(completed_due[0].monitor_id, monitor.monitor_id);
  ASSERT_TRUE(service->MarkMonitorFinished(task->id(), monitor.monitor_id,
                                           /*success=*/true,
                                           base::Time::Now() + base::Hours(2)));
  EXPECT_TRUE(service->SetMonitorPaused(task->id(), monitor.monitor_id, true));
  ASSERT_EQ(service->GetMonitors(task->id()).size(), 1u);
  EXPECT_FALSE(service->GetMonitors(task->id())[0].enabled);
  EXPECT_TRUE(service->SetMonitorPaused(task->id(), monitor.monitor_id, false));
  ASSERT_EQ(service->GetMonitors(task->id()).size(), 1u);
  EXPECT_TRUE(service->GetMonitors(task->id())[0].enabled);
  EXPECT_FALSE(
      service->SetMonitorPaused("other-task", monitor.monitor_id, true));
  AgentMonitorDefinition unexpected = monitor;
  unexpected.monitor_id = "monitor-after-completion";
  EXPECT_FALSE(service->UpsertMonitor(std::move(unexpected)));
  EXPECT_TRUE(service->RemoveMonitor(task->id(), monitor.monitor_id));
  EXPECT_TRUE(service->GetMonitors(task->id()).empty());
}

TEST_F(AegisAgentServiceTest,
       HeldMonitorOwnersDoNotSpendBudgetOrOverwriteLastCheck) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  for (bool takeover : {false, true}) {
    SCOPED_TRACE(takeover);
    AgentTaskScope scope = ServiceTestScope();
    scope.allowed_tools.insert("monitor.create");
    AgentTask* task = service->CreateTask(
        "暂停期间不发起定时检查", AgentMode::kAutomate, std::move(scope));
    ASSERT_TRUE(task);
    ASSERT_TRUE(service->BeginPlanning(task->id()));
    std::string error;
    ASSERT_TRUE(service->AcceptModelPlan(
        task->id(), ServiceAutomationPlanEvent(), &error)) << error;
    ASSERT_TRUE(service->GrantTaskConsent(task->id()));

    const base::Time now = base::Time::Now();
    AgentMonitorDefinition monitor;
    monitor.monitor_id = "held-monitor";
    monitor.task_id = task->id();
    monitor.origin = url::Origin::Create(GURL("https://fixture.example/"));
    monitor.target_hash = "fixture-target";
    monitor.session_only = true;
    monitor.next_run = now;
    monitor.last_run = now - monitor.interval;
    monitor.last_check_status = AgentMonitorCheckStatus::kSucceeded;
    monitor.last_http_status = 200;
    ASSERT_TRUE(service->UpsertMonitor(monitor));
    ASSERT_TRUE(takeover ? service->BeginUserTakeover(task->id())
                         : service->PauseTask(task->id()));

    EXPECT_TRUE(service->ClaimDueMonitors(now).empty());
    EXPECT_EQ(task->network_requests_used(), 0);
    const auto held = service->GetMonitors(task->id());
    ASSERT_EQ(held.size(), 1u);
    EXPECT_TRUE(held[0].enabled);
    EXPECT_EQ(held[0].last_run, monitor.last_run);
    EXPECT_EQ(held[0].last_check_status, AgentMonitorCheckStatus::kSucceeded);
    EXPECT_EQ(held[0].last_http_status, 200);
    EXPECT_EQ(held[0].consecutive_failures, 0);
    EXPECT_GT(held[0].next_run, now);
    EXPECT_TRUE(service->ClaimDueMonitors(now).empty());

    if (!takeover) {
      ASSERT_TRUE(service->ResumeTask(task->id()));
      EXPECT_EQ(service->ClaimDueMonitors(held[0].next_run).size(), 1u);
      EXPECT_EQ(task->network_requests_used(), 1);
    }
    ASSERT_TRUE(service->RemoveMonitor(task->id(), monitor.monitor_id));
    ASSERT_TRUE(service->CancelTask(task->id()));
  }
}

TEST_F(AegisAgentServiceTest,
       MonitorBudgetExhaustionDoesNotReusePreviousHttpStatus) {
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(profile_);
  ASSERT_TRUE(service);
  AgentTaskScope scope = ServiceTestScope();
  scope.allowed_tools.insert("monitor.create");
  scope.budgets.max_network_requests = 1;
  AgentTask* task = service->CreateTask(
      "预算耗尽不是新的 HTTP 检查结果", AgentMode::kAutomate, std::move(scope));
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task->id()));
  std::string error;
  ASSERT_TRUE(service->AcceptModelPlan(
      task->id(), ServiceAutomationPlanEvent(), &error)) << error;
  ASSERT_TRUE(service->GrantTaskConsent(task->id()));

  const base::Time now = base::Time::Now();
  AgentMonitorDefinition monitor;
  monitor.monitor_id = "budget-monitor";
  monitor.task_id = task->id();
  monitor.origin = url::Origin::Create(GURL("https://fixture.example/"));
  monitor.target_hash = "fixture-target";
  monitor.session_only = true;
  monitor.next_run = now;
  ASSERT_TRUE(service->UpsertMonitor(monitor));
  ASSERT_EQ(service->ClaimDueMonitors(now).size(), 1u);
  ASSERT_TRUE(service->MarkMonitorFinished(
      task->id(), monitor.monitor_id, true, now,
      AgentMonitorCheckStatus::kSucceeded, 200));
  EXPECT_TRUE(service->ClaimDueMonitors(now + monitor.interval).empty());
  const auto result = service->GetMonitors(task->id());
  ASSERT_EQ(result.size(), 1u);
  EXPECT_FALSE(result[0].enabled);
  EXPECT_EQ(result[0].last_check_status, AgentMonitorCheckStatus::kBudgetExhausted);
  EXPECT_EQ(result[0].last_http_status, 0);
  EXPECT_EQ(task->network_requests_used(), 1);
  ASSERT_TRUE(service->RemoveMonitor(task->id(), monitor.monitor_id));
  ASSERT_TRUE(service->CancelTask(task->id()));
}

TEST_F(AegisAgentServiceTest,
       RestoresCompletedMonitorOwnerWithoutReplayingTask) {
  std::string task_id;
  {
    AegisAgentService original(profile_);
    AgentTask* task = original.CreateTask(
        "persist completed monitor", AgentMode::kAutomate, ServiceTestScope());
    ASSERT_TRUE(task);
    task_id = task->id();
    ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "test"));
    ASSERT_TRUE(
        task->TransitionTo(AgentTaskState::kAwaitingTaskConsent, "test"));
    ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRunning, "test"));
    AgentMonitorDefinition monitor;
    monitor.monitor_id = "monitor-restart-owner";
    monitor.task_id = task_id;
    monitor.kind = AgentMonitorKind::kUrlStatus;
    monitor.origin =
        url::Origin::Create(GURL("https://fixture.example/status"));
    monitor.target_hash = "sha256:restart-owner";
    monitor.target_ciphertext = "encrypted-restart-fixture";
    monitor.interval = base::Minutes(15);
    monitor.next_run = base::Time::Now() + base::Hours(1);
    ASSERT_TRUE(original.UpsertMonitor(std::move(monitor)));
    ASSERT_TRUE(task->TransitionTo(AgentTaskState::kVerifying, "verified"));
    ASSERT_TRUE(original.CompleteTask(task_id));
    original.Shutdown();
    FlushTaskStore(&original);
  }

  AegisAgentService recovered(profile_);
  FlushTaskStore(&recovered);
  AgentTask* task = recovered.GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
  EXPECT_FALSE(recovered.actor_bridge_for_testing().HasTask(task_id));
  ASSERT_EQ(recovered.GetMonitors(task_id).size(), 1u);
  EXPECT_TRUE(
      recovered.SetMonitorPaused(task_id, "monitor-restart-owner", true));
  EXPECT_FALSE(recovered.GetMonitors(task_id)[0].enabled);
  EXPECT_TRUE(recovered.RemoveMonitor(task_id, "monitor-restart-owner"));
  recovered.Shutdown();
}

TEST_F(AegisAgentServiceTest,
       RestoresEncryptedMonitorBaselineOnlyForItsBoundTarget) {
  base::test::TestFuture<scoped_refptr<os_crypt_async::Encryptor>> ready;
  TestingBrowserProcess::GetGlobal()->os_crypt_async()->GetInstance(
      ready.GetCallback());
  const auto encryptor = ready.Get();
  ASSERT_TRUE(encryptor);
  const auto hash = [](std::string_view text) {
    return "sha256:" + base::HexEncode(crypto::SHA256HashString(text));
  };
  const GURL target("https://fixture.example/private-monitor-fixture");
  const std::string observation =
      R"({"version":1,"kind":2,"content":["private-restart-baseline"]})";
  // 每次经过真正的数据库关闭、服务重建和加解密，不把伪密文当作恢复成功。
  for (int variant = 0; variant < 7; ++variant) {
    SCOPED_TRACE(variant);
    std::string task_id;
    AgentMonitorDefinition monitor;
    {
      AegisAgentService original(profile_);
      FlushTaskStore(&original);
      AgentTask* task = original.CreateTask(
          "restart encrypted monitor", AgentMode::kAutomate, ServiceTestScope());
      ASSERT_TRUE(task);
      task_id = task->id();
      ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "测试"));
      ASSERT_TRUE(task->TransitionTo(AgentTaskState::kAwaitingTaskConsent, "测试"));
      ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRunning, "测试"));
      monitor.monitor_id = "encrypted-baseline-" + base::NumberToString(variant);
      monitor.task_id = task_id;
      monitor.origin = url::Origin::Create(target);
      monitor.target_url = target;
      monitor.target_hash = hash(target.spec());
      monitor.last_value_hash = hash(observation);
      monitor.next_run = base::Time::Now() + base::Hours(1);
      // 正常恢复也验证暂停状态不会被重新开启。
      monitor.enabled = variant != 0;
      ASSERT_TRUE(encryptor->EncryptString(target.spec(), &monitor.target_ciphertext));
      base::DictValue envelope;
      envelope.Set("version", 1);
      envelope.Set("monitor_id", variant == 1 ? "other-monitor" : monitor.monitor_id);
      envelope.Set("task_id", variant == 2 ? "other-task" : task_id);
      envelope.Set("target_hash", variant == 3 ? "other-target" : monitor.target_hash);
      envelope.Set("observation", observation);
      ASSERT_TRUE(encryptor->EncryptString(
          *base::WriteJson(envelope), &monitor.last_observation_ciphertext));
      if (variant == 4) {
        monitor.last_value_hash = hash("other-result");
      }
      if (variant == 5) {
        monitor.last_observation_ciphertext = "invalid-ciphertext";
      }
      if (variant == 6) {
        ASSERT_TRUE(encryptor->EncryptString("not-json", &monitor.last_observation_ciphertext));
      }
      ASSERT_TRUE(original.UpsertMonitor(monitor));
      ASSERT_TRUE(task->TransitionTo(AgentTaskState::kVerifying, "测试"));
      ASSERT_TRUE(original.CompleteTask(task_id));
      original.Shutdown();
      FlushTaskStore(&original);
    }
    DrainTaskRunners();
    {
      AegisAgentService recovered(profile_);
      FlushTaskStore(&recovered);
      DrainTaskRunners();
      FlushTaskStore(&recovered);
      const auto result = recovered.GetMonitors(task_id);
      ASSERT_EQ(result.size(), 1u);
      EXPECT_FALSE(result[0].enabled);
      EXPECT_EQ(result[0].target_url, target);
      EXPECT_EQ(result[0].last_observation_ciphertext,
                monitor.last_observation_ciphertext);
      if (variant == 0) {
        EXPECT_EQ(result[0].last_observation, observation);
        EXPECT_NE(result[0].last_check_status,
                  AgentMonitorCheckStatus::kSecureStorageUnavailable);
      } else {
        EXPECT_TRUE(result[0].last_observation.empty());
        EXPECT_EQ(result[0].last_check_status,
                  AgentMonitorCheckStatus::kSecureStorageUnavailable);
      }
      ASSERT_TRUE(recovered.GetTask(task_id));
      EXPECT_EQ(recovered.GetTask(task_id)->state(), AgentTaskState::kCompleted);
      EXPECT_FALSE(recovered.actor_bridge_for_testing().HasTask(task_id));
      ASSERT_TRUE(recovered.RemoveMonitor(task_id, monitor.monitor_id));
      recovered.Shutdown();
      FlushTaskStore(&recovered);
    }
    DrainTaskRunners();
  }
  std::string bytes;
  ASSERT_TRUE(base::ReadFileToString(
      profile_->GetPath().AppendASCII("AegisAgentTasks.sqlite"), &bytes));
  EXPECT_EQ(bytes.find("private-restart-baseline"), std::string::npos);
  EXPECT_EQ(bytes.find("/private-monitor-fixture"), std::string::npos);
}

TEST_F(AegisAgentServiceTest,
       ResumeRetriesOnlyRequestedEncryptedMonitor) {
  AegisAgentService service(profile_);
  FlushTaskStore(&service);
  const auto encryptor = RecoveryTestEncryptor();
  auto monitor = MakeRecoveryMonitor(&service, "retry-requested", encryptor.get());
  auto other = MakeRecoveryMonitor(&service, "retry-unrelated", encryptor.get());
  ASSERT_TRUE(monitor);
  ASSERT_TRUE(other);
  other->target_ciphertext = "损坏的其他监控密文";
  other->last_check_status = AgentMonitorCheckStatus::kNotChecked;
  ASSERT_TRUE(service.UpsertMonitor(*monitor));
  ASSERT_TRUE(service.UpsertMonitor(*other));
  ASSERT_TRUE(service.SetMonitorPaused(monitor->task_id, monitor->monitor_id, false));
  DrainTaskRunners();
  const auto result = service.GetMonitors(monitor->task_id);
  ASSERT_EQ(result.size(), 1u);
  EXPECT_TRUE(result[0].enabled);
  EXPECT_EQ(result[0].target_url, GURL("https://fixture.example/recovery-monitor"));
  EXPECT_EQ(result[0].last_observation, kRecoveryObservation);
  EXPECT_EQ(result[0].last_observation_ciphertext, monitor->last_observation_ciphertext);
  EXPECT_EQ(result[0].last_check_status, AgentMonitorCheckStatus::kNotChecked);
  EXPECT_EQ(result[0].last_http_status, 0);
  const auto unrelated = service.GetMonitors(other->task_id);
  ASSERT_EQ(unrelated.size(), 1u);
  EXPECT_EQ(unrelated[0].last_check_status, AgentMonitorCheckStatus::kNotChecked);
  EXPECT_TRUE(unrelated[0].target_url.is_empty());
  EXPECT_FALSE(unrelated[0].enabled);
  service.Shutdown();
}

TEST_F(AegisAgentServiceTest, RetryKeepsUnreadableMonitorPaused) {
  AegisAgentService service(profile_);
  FlushTaskStore(&service);
  const auto encryptor = RecoveryTestEncryptor();
  for (int variant = 0; variant < 2; ++variant) {
    SCOPED_TRACE(variant);
    auto monitor = MakeRecoveryMonitor(
        &service, "retry-broken-" + base::NumberToString(variant), encryptor.get());
    ASSERT_TRUE(monitor);
    if (variant == 0) {
      monitor->target_ciphertext = "损坏的目标密文";
    } else {
      monitor->last_observation_ciphertext = "损坏的历史密文";
    }
    ASSERT_TRUE(service.UpsertMonitor(*monitor));
    ASSERT_TRUE(service.SetMonitorPaused(monitor->task_id, monitor->monitor_id, false));
    DrainTaskRunners();
    const auto result = service.GetMonitors(monitor->task_id);
    ASSERT_EQ(result.size(), 1u);
    EXPECT_FALSE(result[0].enabled);
    EXPECT_TRUE(result[0].last_observation.empty());
    EXPECT_EQ(result[0].last_check_status,
              AgentMonitorCheckStatus::kSecureStorageUnavailable);
    EXPECT_EQ(result[0].target_ciphertext, monitor->target_ciphertext);
    EXPECT_EQ(result[0].last_observation_ciphertext, monitor->last_observation_ciphertext);
  }
  service.Shutdown();
}

TEST_F(AegisAgentServiceTest,
       DecryptCompletionRefreshesSnapshotWithoutUnpausing) {
  AegisAgentService service(profile_);
  FlushTaskStore(&service);
  const auto encryptor = RecoveryTestEncryptor();
  auto monitor = MakeRecoveryMonitor(&service, "retry-paused", encryptor.get());
  ASSERT_TRUE(monitor);
  ASSERT_TRUE(service.UpsertMonitor(*monitor));
  RecoverySnapshotObserver observer(&service);
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&AegisAgentServiceTestPeer::FinishMonitorDecryption,
                               base::Unretained(&service), monitor->monitor_id,
                               encryptor));
  ASSERT_TRUE(service.SetMonitorPaused(monitor->task_id, monitor->monitor_id, true));
  const int before = observer.notifications;
  DrainTaskRunners();
  EXPECT_EQ(observer.notifications, before + 1);
  const auto result = service.GetMonitors(monitor->task_id);
  ASSERT_EQ(result.size(), 1u);
  EXPECT_FALSE(result[0].enabled);
  EXPECT_EQ(result[0].last_observation, kRecoveryObservation);
  EXPECT_EQ(result[0].last_check_status, AgentMonitorCheckStatus::kNotChecked);
  service.Shutdown();
}

TEST_F(AegisAgentServiceTest,
       LateDecryptCompletionDoesNotResurrectRemovedMonitor) {
  AegisAgentService service(profile_);
  FlushTaskStore(&service);
  const auto encryptor = RecoveryTestEncryptor();
  auto monitor = MakeRecoveryMonitor(&service, "retry-deleted", encryptor.get());
  ASSERT_TRUE(monitor);
  ASSERT_TRUE(service.UpsertMonitor(*monitor));
  RecoverySnapshotObserver observer(&service);
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&AegisAgentServiceTestPeer::FinishMonitorDecryption,
                               base::Unretained(&service), monitor->monitor_id,
                               encryptor));
  ASSERT_TRUE(service.RemoveMonitor(monitor->task_id, monitor->monitor_id));
  const int before = observer.notifications;
  DrainTaskRunners();
  EXPECT_EQ(observer.notifications, before);
  EXPECT_TRUE(service.GetMonitors(monitor->task_id).empty());
  service.Shutdown();
}

TEST_F(AegisAgentServiceTest,
       DisabledAgentIgnoresDecryptCompletionAndRetriesAfterEnable) {
  AegisAgentService service(profile_);
  FlushTaskStore(&service);
  const auto encryptor = RecoveryTestEncryptor();
  auto monitor = MakeRecoveryMonitor(&service, "retry-disabled", encryptor.get());
  ASSERT_TRUE(monitor);
  ASSERT_TRUE(service.UpsertMonitor(*monitor));
  AgentTask* task = service.GetTask(monitor->task_id);
  ASSERT_TRUE(task);
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "测试"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kAwaitingTaskConsent, "测试"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRunning, "测试"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kVerifying, "测试"));
  ASSERT_TRUE(service.CompleteTask(task->id()));
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&AegisAgentServiceTestPeer::FinishMonitorDecryption,
                               base::Unretained(&service), monitor->monitor_id,
                               encryptor));
  profile_->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, false);
  service.CancelAllForDisable();
  DrainTaskRunners();
  const auto disabled = service.GetMonitors(monitor->task_id);
  ASSERT_EQ(disabled.size(), 1u);
  EXPECT_TRUE(disabled[0].target_url.is_empty());
  EXPECT_TRUE(disabled[0].last_observation.empty());
  profile_->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, true);
  service.ResumeMonitorsAfterEnable();
  DrainTaskRunners();
  const auto result = service.GetMonitors(monitor->task_id);
  ASSERT_EQ(result.size(), 1u);
  EXPECT_EQ(result[0].last_observation, kRecoveryObservation);
  EXPECT_EQ(result[0].last_check_status, AgentMonitorCheckStatus::kNotChecked);
  EXPECT_FALSE(result[0].enabled);
  EXPECT_EQ(service.GetTask(monitor->task_id)->state(), AgentTaskState::kCompleted);
  service.Shutdown();
}

TEST_F(AegisAgentServiceTest,
       LateFailedDecryptDoesNotReplaceRecoveredBaseline) {
  AegisAgentService service(profile_);
  FlushTaskStore(&service);
  const auto encryptor = RecoveryTestEncryptor();
  auto monitor = MakeRecoveryMonitor(&service, "retry-late", encryptor.get());
  ASSERT_TRUE(monitor);
  ASSERT_TRUE(service.UpsertMonitor(*monitor));
  ASSERT_TRUE(service.SetMonitorPaused(monitor->task_id, monitor->monitor_id, false));
  DrainTaskRunners();
  RecoverySnapshotObserver observer(&service);
  AegisAgentServiceTestPeer::FinishMonitorDecryption(
      &service, monitor->monitor_id, nullptr);
  EXPECT_EQ(observer.notifications, 0);
  const auto result = service.GetMonitors(monitor->task_id);
  ASSERT_EQ(result.size(), 1u);
  EXPECT_TRUE(result[0].enabled);
  EXPECT_EQ(result[0].last_observation, kRecoveryObservation);
  EXPECT_EQ(result[0].last_check_status, AgentMonitorCheckStatus::kNotChecked);
  service.Shutdown();
}

TEST_F(AegisAgentServiceTest,
       RunsSessionOnlyMonitorWithoutPersistingItsTarget) {
  std::string task_id;
  const base::FilePath database =
      profile_->GetPath().AppendASCII("AegisAgentTasks.sqlite");
  {
    AegisAgentService original(profile_);
    AgentTaskScope scope = ServiceTestScope();
    scope.allowed_tools.insert("monitor.create");
    AgentTask* task = original.CreateTask(
        "session monitor fixture", AgentMode::kAutomate, std::move(scope));
    ASSERT_TRUE(task);
    task_id = task->id();
    ASSERT_TRUE(original.BeginPlanning(task_id));
    std::string plan_error;
    ASSERT_TRUE(original.AcceptModelPlan(task_id, ServiceAutomationPlanEvent(),
                                         &plan_error))
        << plan_error;
    ASSERT_TRUE(original.GrantTaskConsent(task_id));

    const base::Time now = base::Time::Now();
    AgentMonitorDefinition monitor;
    monitor.monitor_id = "monitor-session-only";
    monitor.task_id = task_id;
    monitor.kind = AgentMonitorKind::kUrlStatus;
    monitor.origin =
        url::Origin::Create(GURL("https://fixture.example/private-session-path"));
    monitor.target_hash = "sha256:session-only-target";
    monitor.target_url =
        GURL("https://fixture.example/private-session-path");
    monitor.interval = base::Minutes(15);
    monitor.next_run = now;
    monitor.session_only = true;
    ASSERT_TRUE(original.UpsertMonitor(monitor));
    ASSERT_EQ(original.ClaimDueMonitors(now).size(), 1u);
    ASSERT_TRUE(original.MarkMonitorFinished(task_id, monitor.monitor_id,
                                             /*success=*/true, now));
    FlushTaskStore(&original);
    original.Shutdown();
    FlushTaskStore(&original);
  }

  std::string database_bytes;
  ASSERT_TRUE(base::ReadFileToString(database, &database_bytes));
  EXPECT_EQ(database_bytes.find("/private-session-path"), std::string::npos);

  AegisAgentService recovered(profile_);
  FlushTaskStore(&recovered);
  EXPECT_TRUE(recovered.GetMonitors(task_id).empty());
  recovered.Shutdown();
}

}  // namespace
}  // namespace aegis::agent
