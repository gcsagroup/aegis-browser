// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/aegis_agent_service.h"

#include <memory>
#include <string_view>
#include <utility>

#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/strings/strcat.h"
#include "base/test/scoped_feature_list.h"
#include "base/test/test_future.h"
#include "build/build_config.h"
#include "chrome/browser/actor/actor_keyed_service.h"
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
#include "components/prefs/pref_service.h"
#include "components/undo/undo_manager.h"
#include "content/public/test/browser_task_environment.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/test/test_url_loader_factory.h"
#include "services/network/test/test_utils.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {

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

 protected:
  TestingProfileManager& profile_manager() { return profile_manager_; }
  raw_ptr<TestingProfile> profile_ = nullptr;

 private:
  base::test::ScopedFeatureList features_;
  content::BrowserTaskEnvironment task_environment_;
  TestingProfileManager profile_manager_;
};

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
  }

  AegisAgentService recovered(profile_);
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
    monitor.interval = base::Minutes(15);
    monitor.next_run = base::Time::Now() + base::Hours(1);
    ASSERT_TRUE(original.UpsertMonitor(std::move(monitor)));
    ASSERT_TRUE(task->TransitionTo(AgentTaskState::kVerifying, "verified"));
    ASSERT_TRUE(original.CompleteTask(task_id));
    original.Shutdown();
  }

  AegisAgentService recovered(profile_);
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

}  // namespace
}  // namespace aegis::agent
