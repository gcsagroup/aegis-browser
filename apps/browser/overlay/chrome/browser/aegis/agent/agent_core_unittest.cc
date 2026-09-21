// Copyright 2026 GCSA

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/time/time.h"
#include "chrome/browser/aegis/agent/agent_monitor_scheduler.h"
#include "chrome/browser/aegis/agent/agent_policy_broker.h"
#include "chrome/browser/aegis/agent/agent_result_verifier.h"
#include "chrome/browser/aegis/agent/agent_workflow.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {

std::optional<std::string> MonitorObservation(
    AgentMonitorKind kind,
    std::initializer_list<std::string_view> texts) {
  base::ListValue nodes;
  for (const auto text : texts) {
    nodes.Append(base::DictValue().Set("text", text));
  }
  return ReadAgentMonitorObservation(kind, nodes);
}

AgentTaskScope TestScope(int max_tool_calls = 4) {
  AgentTaskScope scope;
  scope.allowed_origins = {
      url::Origin::Create(GURL("https://shop.example/path"))};
  scope.allowed_tab_ids = {7};
  scope.allowed_tools = {"page.observe", "page.navigate", "page.click",
                         "bookmark.apply", "shopping.prepare_checkout"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage,
                                AgentDataClass::kBookmarks,
                                AgentDataClass::kFormData};
  scope.budgets.max_tool_calls = max_tool_calls;
  scope.model_destination.kind = AgentModelDestination::Kind::kOnDevice;
  scope.model_destination.provider = "aegis-local";
  scope.model_destination.model = "fixture";
  return scope;
}

AgentToolCall PageClickCall() {
  AgentToolCall call;
  call.action_id = "action-1";
  call.tool_name = "page.click";
  call.committed_url = GURL("https://shop.example/product");
  call.document = AgentDocumentRef{.tab_id = 7,
                                   .frame_token = "frame-1",
                                   .document_token = "document-1",
                                   .committed_url = call.committed_url};
  call.arguments.Set("tab_id", 7);
  call.arguments.Set("node_id", 42);
  call.arguments.Set("document_token", "document-1");
  return call;
}

AgentToolCall BookmarkApplyCall() {
  AgentToolCall call;
  call.action_id = "action-bookmarks";
  call.tool_name = "bookmark.apply";
  call.arguments.Set("plan_id", "plan-1");
  call.arguments.Set("snapshot_hash", "sha256:fixture");
  return call;
}

AgentToolCall CheckoutCall() {
  AgentToolCall call;
  call.action_id = "checkout";
  call.tool_name = "shopping.prepare_checkout";
  call.committed_url = GURL("https://shop.example/checkout");
  call.document = AgentDocumentRef{.tab_id = 7,
                                   .frame_token = "frame-1",
                                   .document_token = "document-1",
                                   .committed_url = call.committed_url};
  call.arguments.Set("tab_id", 7);
  call.arguments.Set("document_token", "document-1");
  call.arguments.Set("merchant", "Fixture Shop");
  call.arguments.Set("product", "Test Item");
  call.arguments.Set("quantity", 1);
  call.arguments.Set("unit_price_minor_units", 1000);
  call.arguments.Set("shipping_minor_units", 200);
  call.arguments.Set("tax_minor_units", 99);
  call.arguments.Set("discount_minor_units", 0);
  call.arguments.Set("total_minor_units", 1299);
  call.arguments.Set("currency", "USD");
  call.arguments.Set("delivery_summary", "two days");
  call.arguments.Set("return_summary", "thirty days");
  base::ListValue source_node_ids;
  source_node_ids.Append(42);
  call.arguments.Set("source_node_ids", std::move(source_node_ids));
  call.arguments.Set("observation_fingerprint", "fixture-fingerprint");
  return call;
}

void ConsentTask(AgentTask* task) {
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "test"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kAwaitingTaskConsent, "test"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRunning, "test"));
}

TEST(AegisAgentTypesTest, ScopeRejectsExpansionAndSecrets) {
  AgentTaskScope parent = TestScope();
  ASSERT_TRUE(parent.IsValid());

  AgentTaskScope child = parent;
  child.allowed_tools.erase("shopping.prepare_checkout");
  child.allowed_tab_ids.clear();
  child.budgets.max_tabs = 4;
  EXPECT_TRUE(child.IsNoBroaderThan(parent));

  child.allowed_origins.push_back(
      url::Origin::Create(GURL("https://other.example/")));
  EXPECT_FALSE(child.IsNoBroaderThan(parent));
  EXPECT_FALSE(parent.AllowsOrigin(GURL("https://shop.example.evil.test/")));
  EXPECT_TRUE(parent.AllowsTab(7));
  EXPECT_FALSE(parent.AllowsTab(8));
  EXPECT_FALSE(parent.AllowsDataClass(AgentDataClass::kSecret));
}

TEST(AegisAgentTypesTest, WindowMetadataDoesNotGrantTabActionsOrExpandScope) {
  AgentTaskScope parent = TestScope();
  parent.allowed_tools.insert("tab.list");
  parent.allowed_data_classes.insert(AgentDataClass::kBrowserMetadata);
  AgentTaskScope child = parent;
  child.tab_metadata_window_id = 41;
  ASSERT_TRUE(child.IsValid());
  EXPECT_FALSE(child.IsNoBroaderThan(parent));
  parent.tab_metadata_window_id = 41;
  EXPECT_TRUE(child.IsNoBroaderThan(parent));
  EXPECT_FALSE(child.AllowsTab(41));
  child.tab_metadata_window_id = 42;
  EXPECT_FALSE(child.IsNoBroaderThan(parent));
  child.tab_metadata_window_id = 0;
  EXPECT_TRUE(child.IsNoBroaderThan(parent));
  child.tab_metadata_window_id = -1;
  EXPECT_FALSE(child.IsValid());
  child = parent;
  child.allowed_tools.erase("tab.list");
  EXPECT_FALSE(child.IsValid());
  child = parent;
  child.allowed_data_classes.erase(AgentDataClass::kBrowserMetadata);
  EXPECT_FALSE(child.IsValid());
}

TEST(AegisAgentTaskTest, AdoptsOnlyBoundedAgentOwnedTabs) {
  AgentTaskScope scope = TestScope();
  scope.budgets.max_tabs = 2;
  AgentTask task("task-tabs", "open one result", AgentMode::kAct,
                 std::move(scope));

  EXPECT_TRUE(task.AllowsTab(7));
  EXPECT_TRUE(task.AdoptOwnedTab(8));
  EXPECT_TRUE(task.AllowsTab(8));
  EXPECT_FALSE(task.AdoptOwnedTab(8));
  EXPECT_FALSE(task.AdoptOwnedTab(9));
  EXPECT_TRUE(task.ReleaseOwnedTab(8));
  EXPECT_FALSE(task.AllowsTab(8));
  EXPECT_TRUE(task.AdoptOwnedTab(9));
}

TEST(AegisAgentTaskTest, EnforcesTransitionsTerminalStateAndBudgets) {
  AgentTask task("task-1", "organize bookmarks", AgentMode::kAct,
                 TestScope(/*max_tool_calls=*/2));
  EXPECT_FALSE(task.TransitionTo(AgentTaskState::kRunning, "skip consent"));
  ConsentTask(&task);
  EXPECT_TRUE(task.ConsumeToolCall());
  EXPECT_TRUE(task.ConsumeToolCall());
  EXPECT_FALSE(task.ConsumeToolCall());
  EXPECT_TRUE(task.TransitionTo(AgentTaskState::kVerifying, "verify"));
  EXPECT_TRUE(task.TransitionTo(AgentTaskState::kCompleted, "done"));
  EXPECT_FALSE(task.TransitionTo(AgentTaskState::kRunning, "reopen"));
  EXPECT_EQ(task.events().size(), 5u);
}

TEST(AegisAgentTaskTest, RecordsTimelineFactWithoutChangingState) {
  AgentTask task("task-event", "monitor a page", AgentMode::kAutomate,
                 TestScope());
  ConsentTask(&task);

  task.RecordEvent("monitor change", "price changed at shop.example");

  EXPECT_EQ(task.state(), AgentTaskState::kRunning);
  ASSERT_EQ(task.events().size(), 4u);
  const AgentTaskEvent& event = task.events().back();
  EXPECT_EQ(event.from, AgentTaskState::kRunning);
  EXPECT_EQ(event.to, AgentTaskState::kRunning);
  EXPECT_EQ(event.title, "monitor change");
  EXPECT_EQ(event.reason, "price changed at shop.example");
}

TEST(AegisAgentTaskTest, RecoveryRestoresCountersWithoutOwnedTabsOrReplay) {
  AgentTaskScope scope = TestScope();
  std::unique_ptr<AgentTask> recovered = AgentTask::RestoreForRecovery(
      "task-recovery", "redacted goal", AgentMode::kAct, std::move(scope),
      AgentTaskState::kAwaitingActionApproval, 2, 1, 3,
      base::Time::Now() - base::Minutes(1));
  ASSERT_TRUE(recovered);
  EXPECT_EQ(recovered->state(), AgentTaskState::kRecovering);
  EXPECT_EQ(recovered->tool_calls_used(), 2);
  EXPECT_EQ(recovered->model_calls_used(), 1);
  EXPECT_EQ(recovered->network_requests_used(), 3);
  EXPECT_TRUE(recovered->owned_tab_ids().empty());
  ASSERT_EQ(recovered->events().size(), 1u);
  EXPECT_EQ(recovered->events().front().from,
            AgentTaskState::kAwaitingActionApproval);
}

TEST(AegisAgentTaskTest, RestoresOnlyValidCompletedAutomateMonitorOwners) {
  std::unique_ptr<AgentTask> restored = AgentTask::RestoreCompletedMonitorOwner(
      "task-monitor-owner", "completed monitor owner", AgentMode::kAutomate,
      TestScope(), 2, 1, 3, base::Time::Now() - base::Minutes(1));
  ASSERT_TRUE(restored);
  EXPECT_EQ(restored->state(), AgentTaskState::kCompleted);
  EXPECT_EQ(restored->mode(), AgentMode::kAutomate);
  EXPECT_TRUE(restored->events().empty());

  EXPECT_FALSE(AgentTask::RestoreCompletedMonitorOwner(
      "task-act", "not an automate owner", AgentMode::kAct, TestScope(), 0, 0,
      0, base::Time::Now() - base::Minutes(1)));
}

TEST(AegisAgentTaskTest, PlanningCanOnlyNarrowScopeBeforeConsent) {
  AgentTaskScope maximum = TestScope();
  AgentTask task("task-plan", "plan fixture", AgentMode::kAct, maximum);
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kPlanning, "test"));

  AgentTaskScope narrower = maximum;
  narrower.allowed_tools.erase("shopping.prepare_checkout");
  narrower.budgets.max_tool_calls = 2;
  EXPECT_TRUE(task.AdoptPlanScope(narrower));
  EXPECT_EQ(task.scope().allowed_tools, narrower.allowed_tools);

  AgentTaskScope broader = maximum;
  broader.allowed_tools.insert("unknown.tool");
  EXPECT_FALSE(task.AdoptPlanScope(std::move(broader)));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kAwaitingTaskConsent, "test"));
  EXPECT_FALSE(task.AdoptPlanScope(std::move(narrower)));
}

TEST(AegisAgentWorkflowTest, BuiltInsUseBoundedPurposeSpecificScopes) {
  AgentModelDestination destination;
  destination.provider = "aegis-local";
  destination.model = "fixture";
  for (AgentWorkflowKind kind :
       {AgentWorkflowKind::kResearch, AgentWorkflowKind::kBrowserSteward,
        AgentWorkflowKind::kSafeDownload, AgentWorkflowKind::kShopping}) {
    std::optional<AgentTaskScope> scope = BuildAgentWorkflowScope(
        kind, {url::Origin::Create(GURL("https://shop.example/"))}, {7},
        destination);
    ASSERT_TRUE(scope);
    EXPECT_TRUE(scope->IsValid());
    EXPECT_FALSE(scope->allowed_data_classes.contains(AgentDataClass::kSecret));
    EXPECT_LE(scope->budgets.max_tabs, 20);
    EXPECT_FALSE(scope->allowed_tools.contains("script.execute"));
    EXPECT_FALSE(scope->allowed_tools.contains("transaction.submit"));
  }
  const AgentWorkflowTemplate& shopping =
      GetAgentWorkflowTemplate(AgentWorkflowKind::kShopping);
  EXPECT_TRUE(shopping.always_user_takeover_for_final_action);
  EXPECT_TRUE(shopping.tools.contains("shopping.prepare_checkout"));

  std::optional<AgentTaskScope> browser_only = BuildAgentWorkflowScope(
      AgentWorkflowKind::kBrowserSteward, {}, {7}, destination);
  ASSERT_TRUE(browser_only);
  EXPECT_TRUE(browser_only->allowed_tools.contains("bookmark.list"));
  EXPECT_TRUE(browser_only->allowed_tools.contains("bookmark.plan"));
  EXPECT_TRUE(browser_only->allowed_tools.contains("tab.list"));
  EXPECT_FALSE(browser_only->allowed_tools.contains("tab.create"));
  EXPECT_FALSE(browser_only->allowed_tools.contains("window.create"));
}

TEST(AegisAgentWorkflowTest, StewardBudgetCovers500ChecksAndModelRequests) {
  AgentModelDestination destination;
  destination.provider = "aegis-local";
  destination.model = "fixture";
  const auto scope = BuildAgentWorkflowScope(
      AgentWorkflowKind::kBrowserSteward, {}, {7}, destination);
  ASSERT_TRUE(scope);
  AgentTask task("steward-full-budget", "检查500条收藏", AgentMode::kAsk,
                 *scope);
  // 使用真实模板和任务计数：模型请求也计入总网络预算，不能从账目中排除。
  for (int index = 0; index < scope->budgets.max_model_calls; ++index) {
    ASSERT_TRUE(task.ConsumeModelCall());
    ASSERT_TRUE(task.ConsumeNetworkRequest());
  }
  for (int index = 0; index < 500; ++index) {
    ASSERT_TRUE(task.ConsumeNetworkRequest())
        << "模型开销之后只剩 " << index << " 次网址请求";
  }
  EXPECT_EQ(task.network_requests_used(),
            500 + scope->budgets.max_model_calls);
  EXPECT_FALSE(task.ConsumeNetworkRequest());
  EXPECT_FALSE(task.ConsumeModelCall());
}

TEST(AegisAgentWorkflowTest, StewardBudgetNarrowingPreservesExistingCaps) {
  AgentModelDestination destination;
  destination.provider = "aegis-local";
  destination.model = "fixture";
  const auto maximum = BuildAgentWorkflowScope(
      AgentWorkflowKind::kBrowserSteward, {}, {7}, destination);
  ASSERT_TRUE(maximum);
  AgentTask task("steward-narrow-budget", "检查收藏但限制总请求", AgentMode::kAsk,
                 *maximum);
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kPlanning, "测试规划"));
  AgentTaskScope narrower = *maximum;
  narrower.budgets.max_network_requests = 500;
  ASSERT_TRUE(task.AdoptPlanScope(narrower));
  EXPECT_EQ(task.scope().budgets.max_network_requests, 500);
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kAwaitingTaskConsent, "测试授权"));
  EXPECT_FALSE(task.AdoptPlanScope(*maximum));
  for (int index = 0; index < 500; ++index) {
    ASSERT_TRUE(task.ConsumeNetworkRequest());
  }
  EXPECT_FALSE(task.ConsumeNetworkRequest());
  EXPECT_EQ(task.network_requests_used(), 500);
}

TEST(AegisAgentWorkflowTest, AutomationKeepsReadAndMonitorToolsForEveryRoute) {
  AgentModelDestination destination;
  destination.provider = "aegis-local";
  destination.model = "fixture";
  const url::Origin origin = url::Origin::Create(GURL("https://shop.example/"));
  AgentToolRegistry registry;
  for (AgentWorkflowKind kind :
       {AgentWorkflowKind::kResearch, AgentWorkflowKind::kBrowserSteward,
        AgentWorkflowKind::kSafeDownload, AgentWorkflowKind::kShopping}) {
    const auto ordinary = BuildAgentWorkflowScope(kind, {origin}, {7}, destination);
    const auto scope = BuildAgentAutomationScope(kind, {origin}, {7}, destination);
    ASSERT_TRUE(ordinary);
    ASSERT_TRUE(scope);
    EXPECT_EQ(scope->allowed_origins, ordinary->allowed_origins);
    EXPECT_EQ(scope->allowed_tab_ids, ordinary->allowed_tab_ids);
    EXPECT_EQ(scope->model_destination, destination);
    EXPECT_TRUE(scope->budgets.IsNoBroaderThan(ordinary->budgets));
    for (const char* monitor : {"monitor.create", "monitor.list", "monitor.pause",
                                "monitor.delete"}) {
      EXPECT_TRUE(scope->AllowsTool(monitor));
    }
    for (const std::string& tool : scope->allowed_tools) {
      const AgentToolDescriptor* descriptor = registry.Find(tool);
      ASSERT_TRUE(descriptor);
      EXPECT_FALSE(descriptor->has_external_side_effect) << tool;
      EXPECT_TRUE(descriptor->risk == AgentRiskLevel::kR0ReadOnly ||
                  tool == "page.navigate" || tool == "tab.create" ||
                  tool.starts_with("monitor.")) << tool;
      EXPECT_TRUE(scope->AllowsDataClass(descriptor->data_class));
    }
    EXPECT_FALSE(scope->AllowsDataClass(AgentDataClass::kFormData));
    EXPECT_FALSE(scope->AllowsDataClass(AgentDataClass::kSecret));
    for (const char* tool : {"download.start", "download.open", "download.resume",
                             "shopping.prepare_checkout", "form.fill", "page.click",
                             "bookmark.apply", "bookmark.undo", "workspace.restore",
                             "tab.close", "window.close"}) {
      EXPECT_FALSE(scope->AllowsTool(tool)) << tool;
    }
    if (kind == AgentWorkflowKind::kSafeDownload) {
      EXPECT_TRUE(ordinary->AllowsTool("download.start"));
      EXPECT_FALSE(ordinary->AllowsTool("monitor.create"));
      EXPECT_TRUE(scope->AllowsTool("download.find_official"));
    } else if (kind == AgentWorkflowKind::kBrowserSteward) {
      EXPECT_TRUE(scope->AllowsTool("bookmark.list"));
      EXPECT_TRUE(scope->AllowsTool("bookmark.check_urls"));
      EXPECT_TRUE(ordinary->AllowsTool("bookmark.apply"));
    }
  }
}

TEST(AegisAgentWorkflowTest, AutomationDoesNotInventAnOriginOrPrivateDataScope) {
  AgentModelDestination destination;
  destination.provider = "aegis-local";
  destination.model = "fixture";
  const auto scope = BuildAgentAutomationScope(
      AgentWorkflowKind::kResearch, {}, {7}, destination);
  ASSERT_TRUE(scope);
  EXPECT_TRUE(scope->allowed_origins.empty());
  EXPECT_FALSE(scope->AllowsTool("monitor.create"));
  EXPECT_FALSE(scope->AllowsTool("page.navigate"));
  EXPECT_FALSE(scope->AllowsTool("tab.create"));
  EXPECT_FALSE(scope->AllowsDataClass(AgentDataClass::kPublicPage));
  EXPECT_FALSE(scope->AllowsDataClass(AgentDataClass::kBookmarks));
  EXPECT_FALSE(scope->AllowsDataClass(AgentDataClass::kDownloads));
}

TEST(AegisAgentToolRegistryTest, SelectRequiresExactActionApproval) {
  AgentToolRegistry registry;
  const AgentToolDescriptor* select = registry.Find("page.select");
  ASSERT_TRUE(select);
  EXPECT_EQ(select->risk, AgentRiskLevel::kR2ExternalSideEffect);
  EXPECT_TRUE(select->has_external_side_effect);
  EXPECT_TRUE(select->requires_document);
}

TEST(AegisAgentMonitorSchedulerTest,
     UrlResultNotifiesOnFailuresAndRecoveryWithoutRepeatedNoise) {
  AgentMonitorDefinition previous;
  EXPECT_FALSE(ShouldNotifyMonitorUrlResult(
      previous, AgentMonitorCheckStatus::kSucceeded, "http-200"));
  for (AgentMonitorCheckStatus failure : {
           AgentMonitorCheckStatus::kLoginRequired,
           AgentMonitorCheckStatus::kRateLimited,
           AgentMonitorCheckStatus::kNetworkError,
           AgentMonitorCheckStatus::kTimeout}) {
    previous.last_check_status = AgentMonitorCheckStatus::kNotChecked;
    EXPECT_TRUE(ShouldNotifyMonitorUrlResult(previous, failure, ""));
    previous.last_check_status = failure;
    EXPECT_FALSE(ShouldNotifyMonitorUrlResult(previous, failure, ""));
    // 首次检查就失败时没有旧结果哈希，恢复也必须提醒。
    EXPECT_TRUE(ShouldNotifyMonitorUrlResult(
        previous, AgentMonitorCheckStatus::kSucceeded, "http-200"));
    previous.last_value_hash = "http-200";
    // 曾经成功、临时失败、恢复为相同状态码，也不能漏掉恢复通知。
    EXPECT_TRUE(ShouldNotifyMonitorUrlResult(
        previous, AgentMonitorCheckStatus::kSucceeded, "http-200"));
    previous.last_value_hash.clear();
  }
}

TEST(AegisAgentMonitorSchedulerTest,
     UrlResultNotifiesOnHttpChangesAndKeepsStableResultsQuiet) {
  AgentMonitorDefinition previous;
  previous.last_check_status = AgentMonitorCheckStatus::kSucceeded;
  previous.last_value_hash = "http-200";
  EXPECT_FALSE(ShouldNotifyMonitorUrlResult(
      previous, AgentMonitorCheckStatus::kSucceeded, "http-200"));
  EXPECT_TRUE(ShouldNotifyMonitorUrlResult(
      previous, AgentMonitorCheckStatus::kHttpError, "http-404"));
  previous.last_check_status = AgentMonitorCheckStatus::kHttpError;
  previous.last_value_hash = "http-404";
  EXPECT_FALSE(ShouldNotifyMonitorUrlResult(
      previous, AgentMonitorCheckStatus::kHttpError, "http-404"));
  EXPECT_TRUE(ShouldNotifyMonitorUrlResult(
      previous, AgentMonitorCheckStatus::kHttpError, "http-500"));
  EXPECT_TRUE(ShouldNotifyMonitorUrlResult(
      previous, AgentMonitorCheckStatus::kSucceeded, "http-200"));
}

TEST(AegisAgentMonitorObservationTest, PriceDropsOnlyInTheSameCurrency) {
  const auto kind = AgentMonitorKind::kPrice;
  const auto before = MonitorObservation(kind, {"Price USD 1299.00"});
  const auto lower = MonitorObservation(kind, {"Price USD 1,199.99"});
  const auto higher = MonitorObservation(kind, {"Price USD 1399"});
  const auto currency = MonitorObservation(kind, {"Price EUR 999.00"});
  ASSERT_TRUE(before); ASSERT_TRUE(lower); ASSERT_TRUE(higher);
  ASSERT_TRUE(currency);
  EXPECT_TRUE(DidAgentMonitorConditionMatch(kind, *before, *lower));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, *before, *before));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, *before, *higher));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, *before, *currency));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, "", *before));
}

TEST(AegisAgentMonitorObservationTest, PriceFormattingAndDuplicateNodesAreStable) {
  const auto kind = AgentMonitorKind::kPrice;
  // 两边都解析失败不能算格式等价，通过存在性断言防止空值假阳性。
  for (const auto text : {"售价 ￥1,299.00", "售价 ¥1299", "Price EUR 1.299,50",
                          "1299.50 EUR", "现价 1299 元", "CNY 1299.00",
                          "HK$299.00", "HKD 299", "$299", "USD 299"}) {
    SCOPED_TRACE(text);
    ASSERT_TRUE(MonitorObservation(kind, {text}));
  }
  EXPECT_EQ(MonitorObservation(kind, {"售价 ￥1,299.00", "售价 ￥1,299.00"}),
            MonitorObservation(kind, {"售价 ¥1299"}));
  EXPECT_EQ(MonitorObservation(kind, {"Price EUR 1.299,50"}),
            MonitorObservation(kind, {"1299.50 EUR"}));
  EXPECT_EQ(MonitorObservation(kind, {"现价 1299 元"}),
            MonitorObservation(kind, {"CNY 1299.00"}));
  EXPECT_EQ(MonitorObservation(kind, {"HK$299.00"}),
            MonitorObservation(kind, {"HKD 299"}));
  EXPECT_NE(MonitorObservation(kind, {"$299"}),
            MonitorObservation(kind, {"USD 299"}));
}

TEST(AegisAgentMonitorObservationTest, RejectsAmbiguousOrNonProductPrices) {
  const auto kind = AgentMonitorKind::kPrice;
  EXPECT_FALSE(MonitorObservation(kind, {"$10", "$20"}));
  EXPECT_FALSE(MonitorObservation(kind, {"Original price $100"}));
  EXPECT_FALSE(MonitorObservation(kind, {"Shipping $5"}));
  EXPECT_FALSE(MonitorObservation(kind, {"库存 100 件"}));
  EXPECT_FALSE(MonitorObservation(kind, {"Price: unknown"}));
  for (const auto invalid : {"$-1", "-1 USD", "$0", "$12,34,56",
                             "$1.2345", "$100%", "$99999999999999999"}) {
    SCOPED_TRACE(invalid);
    EXPECT_FALSE(MonitorObservation(kind, {invalid}));
  }
  EXPECT_EQ(MonitorObservation(kind, {"原价 ￥199", "现价 ￥99"}),
            MonitorObservation(kind, {"￥99.00"}));
}

TEST(AegisAgentMonitorObservationTest, OnlyRestockTriggersArrival) {
  const auto kind = AgentMonitorKind::kInventory;
  const auto empty = MonitorObservation(kind, {"Out of stock"});
  const auto ready = MonitorObservation(kind, {"In stock"});
  ASSERT_TRUE(empty); ASSERT_TRUE(ready);
  EXPECT_TRUE(DidAgentMonitorConditionMatch(kind, *empty, *ready));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, *ready, *empty));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, *ready, *ready));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, "", *ready));
  EXPECT_EQ(empty, MonitorObservation(kind, {"没有货"}));
  EXPECT_EQ(empty, MonitorObservation(kind, {"Not in stock"}));
  EXPECT_EQ(empty, MonitorObservation(kind, {"Currently unavailable"}));
  EXPECT_EQ(ready, MonitorObservation(kind, {"现货，有货"}));
  EXPECT_EQ(ready, MonitorObservation(kind, {"現貨"}));
}

TEST(AegisAgentMonitorObservationTest, InventoryDoesNotGuessFromConflictingText) {
  const auto kind = AgentMonitorKind::kInventory;
  EXPECT_FALSE(MonitorObservation(kind, {"Out of stock", "In stock"}));
  EXPECT_FALSE(MonitorObservation(kind, {"Out of stock; another item in stock"}));
  EXPECT_FALSE(MonitorObservation(kind, {"预计明天有货"}));
  EXPECT_FALSE(MonitorObservation(kind, {"Pre-order now"}));
  EXPECT_FALSE(MonitorObservation(kind, {"This service is unavailable"}));
  EXPECT_FALSE(MonitorObservation(kind, {"Available coupons"}));
  EXPECT_FALSE(MonitorObservation(kind, {"Made in Stockport"}));
}

TEST(AegisAgentMonitorObservationTest, InputsAndStoredResultsAreBounded) {
  const auto kind = AgentMonitorKind::kPrice;
  EXPECT_EQ(MonitorObservation(kind, {"$1\U000e00209.99"}),
            MonitorObservation(kind, {"$19.99"}));
  EXPECT_FALSE(MonitorObservation(kind, {std::string(32769, 'x')}));
  base::ListValue excessive;
  for (int i = 0; i < 513; ++i) {
    excessive.Append(base::DictValue().Set("text", "$99"));
  }
  EXPECT_FALSE(ReadAgentMonitorObservation(kind, excessive));
  // base::Value 只接受 UTF-8；在原始持久化文本的解析边界验证拒绝。
  EXPECT_FALSE(
      IsValidAgentMonitorObservation(kind, std::string("\xff", 1)));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, "not json", "{}"));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind,
      R"({"version":1,"kind":0,"currency":"USD","amount":"100"})",
      R"({"version":1,"kind":0,"currency":"USD","amount":"-1"})"));
}

TEST(AegisAgentMonitorObservationTest, PageChangeRequiresTwoMeasuredSnapshots) {
  const auto kind = AgentMonitorKind::kPageChange;
  const auto before = MonitorObservation(kind, {"正文第一版"});
  const auto after = MonitorObservation(kind, {"正文第二版"});
  ASSERT_TRUE(before); ASSERT_TRUE(after);
  EXPECT_TRUE(DidAgentMonitorConditionMatch(kind, *before, *after));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, *before, *before));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(kind, "", *before));
  EXPECT_FALSE(DidAgentMonitorConditionMatch(AgentMonitorKind::kPrice,
                                            *before, *after));
  EXPECT_FALSE(MonitorObservation(kind, {}));
}

TEST(AegisAgentMonitorObservationTest, RejectsInvalidPersistentBaseline) {
  const auto valid = MonitorObservation(AgentMonitorKind::kPrice, {"USD 19.99"});
  ASSERT_TRUE(valid);
  EXPECT_TRUE(IsValidAgentMonitorObservation(AgentMonitorKind::kPrice, *valid));
  for (const std::string& invalid : {
      std::string(), std::string("{}"), std::string(32769, 'x'),
      std::string(R"({"version":2,"kind":0,"currency":"USD","amount":"1999"})"),
      std::string(R"({"version":1,"kind":0,"currency":"UNKNOWN","amount":"1999"})"),
      std::string(R"({"version":1,"kind":0,"currency":"USD","amount":"01999"})"),
      std::string(R"({"version":1,"kind":0,"currency":"USD","amount":"100000000000001"})")}) {
    EXPECT_FALSE(IsValidAgentMonitorObservation(AgentMonitorKind::kPrice, invalid));
  }
  EXPECT_FALSE(IsValidAgentMonitorObservation(AgentMonitorKind::kInventory,
      R"({"version":1,"kind":1,"available":"true"})"));
  EXPECT_FALSE(IsValidAgentMonitorObservation(AgentMonitorKind::kPageChange,
      R"({"version":1,"kind":2,"content":[1]})"));
  AgentMonitorDefinition monitor{
      .monitor_id = "bounded-monitor", .task_id = "bounded-owner",
      .kind = AgentMonitorKind::kPrice,
      .origin = url::Origin::Create(GURL("https://fixture.example/")),
      .target_hash = "bounded-target", .last_observation = *valid};
  ASSERT_TRUE(monitor.IsValid());
  monitor.last_observation = "invalid-json";
  EXPECT_FALSE(monitor.IsValid());
  monitor.last_observation.clear();
  monitor.last_observation_ciphertext.assign(131073, 'x');
  EXPECT_FALSE(monitor.IsValid());
}

TEST(AegisAgentMonitorSchedulerTest, ClaimsThreeAndCollapsesRestartCatchup) {
  const base::Time now = base::Time::Now();
  std::vector<AgentMonitorDefinition> stored;
  for (int index = 0; index < 5; ++index) {
    stored.push_back(AgentMonitorDefinition{
        .monitor_id = "monitor-" + std::to_string(index),
        .task_id = "task-monitor",
        .kind = AgentMonitorKind::kPageChange,
        .origin = url::Origin::Create(GURL("https://shop.example/")),
        .target_hash = "fixture-hash-" + std::to_string(index),
        .interval = base::Minutes(15),
        .next_run = now - base::Hours(index + 1)});
  }
  AgentMonitorScheduler scheduler;
  scheduler.Restore(std::move(stored), now);
  std::vector<AgentMonitorDefinition> first = scheduler.ClaimDue(now);
  EXPECT_EQ(first.size(), 3u);
  std::vector<AgentMonitorDefinition> second = scheduler.ClaimDue(now);
  EXPECT_EQ(second.size(), 2u);
  EXPECT_TRUE(scheduler.ClaimDue(now).empty());
}

TEST(AegisAgentMonitorSchedulerTest, ReplayUsesOneStableMonitorIdentity) {
  const std::string first =
      AgentMonitorIdempotencyKey("task-monitor", "create-1");
  EXPECT_EQ(first, AgentMonitorIdempotencyKey("task-monitor", "create-1"));
  EXPECT_NE(first, AgentMonitorIdempotencyKey("task-monitor", "create-2"));
  EXPECT_NE(first, AgentMonitorIdempotencyKey("other-task", "create-1"));

  AgentMonitorScheduler scheduler;
  AgentMonitorDefinition monitor{
      .monitor_id = first,
      .task_id = "task-monitor",
      .kind = AgentMonitorKind::kPrice,
      .origin = url::Origin::Create(GURL("https://shop.example/")),
      .target_hash = "fixture-hash",
      .interval = base::Minutes(15),
      .next_run = base::Time::Now()};
  ASSERT_TRUE(scheduler.Upsert(monitor));
  monitor.interval = base::Minutes(30);
  ASSERT_TRUE(scheduler.Upsert(std::move(monitor)));
  ASSERT_EQ(scheduler.Snapshot().size(), 1u);
  EXPECT_EQ(scheduler.Snapshot()[0].interval, base::Minutes(30));
}

TEST(AegisAgentMonitorSchedulerTest, UsesBoundedExponentialBackoff) {
  const base::Time now = base::Time::Now();
  AgentMonitorScheduler scheduler;
  AgentMonitorDefinition monitor{
      .monitor_id = "monitor-backoff",
      .task_id = "task-monitor",
      .kind = AgentMonitorKind::kInventory,
      .origin = url::Origin::Create(GURL("https://shop.example/")),
      .target_hash = "fixture-hash",
      .interval = base::Minutes(15),
      .next_run = now};
  ASSERT_TRUE(scheduler.Upsert(std::move(monitor)));
  ASSERT_EQ(scheduler.ClaimDue(now).size(), 1u);
  EXPECT_TRUE(scheduler.MarkFinished("monitor-backoff", false, now));
  std::vector<AgentMonitorDefinition> snapshot = scheduler.Snapshot();
  ASSERT_EQ(snapshot.size(), 1u);
  EXPECT_EQ(snapshot[0].consecutive_failures, 1);
  EXPECT_EQ(snapshot[0].next_run, now + base::Minutes(30));
  for (int index = 0; index < 10; ++index) {
    ASSERT_TRUE(scheduler.MarkFinished("monitor-backoff", false, now));
  }
  snapshot = scheduler.Snapshot();
  EXPECT_LE(snapshot[0].next_run, now + base::Hours(24));
}

TEST(AegisAgentMonitorSchedulerTest,
     RetainsBoundedCheckStatusAndRejectsInvalidCodes) {
  const base::Time now = base::Time::Now();
  AgentMonitorScheduler scheduler;
  AgentMonitorDefinition monitor{
      .monitor_id = "status-monitor",
      .task_id = "status-owner",
      .origin = url::Origin::Create(GURL("https://fixture.example/")),
      .target_hash = "fixed-target",
      .next_run = now};
  ASSERT_TRUE(scheduler.Upsert(monitor));
  ASSERT_TRUE(scheduler.MarkFinished(monitor.monitor_id, false, now,
                                     AgentMonitorCheckStatus::kRateLimited,
                                     429));
  auto result = scheduler.Snapshot()[0];
  EXPECT_EQ(result.last_check_status, AgentMonitorCheckStatus::kRateLimited);
  EXPECT_EQ(result.last_http_status, 429);
  EXPECT_EQ(result.consecutive_failures, 1);
  EXPECT_FALSE(scheduler.MarkFinished(
      monitor.monitor_id, true, now, AgentMonitorCheckStatus::kSucceeded, 999));
  EXPECT_FALSE(
      scheduler.MarkFinished(monitor.monitor_id, true, now,
                             static_cast<AgentMonitorCheckStatus>(999)));
  EXPECT_EQ(scheduler.Snapshot()[0].last_http_status, 429);
  ASSERT_TRUE(scheduler.MarkFinished(monitor.monitor_id, true, now,
                                     AgentMonitorCheckStatus::kSucceeded, 200));
  result = scheduler.Snapshot()[0];
  EXPECT_EQ(result.last_check_status, AgentMonitorCheckStatus::kSucceeded);
  EXPECT_EQ(result.last_http_status, 200);
  EXPECT_EQ(result.consecutive_failures, 0);
}

TEST(AegisAgentPolicyTest, RequiresExactDocumentAndOrigin) {
  AgentToolRegistry registry;
  AgentPolicyBroker broker(&registry);
  AgentTask task("task-1", "click fixture", AgentMode::kAct, TestScope());
  ConsentTask(&task);

  AgentToolCall call = PageClickCall();
  EXPECT_EQ(broker.Evaluate(task, call).disposition,
            AgentPolicyDisposition::kRequireActionApproval);
  std::optional<AgentApprovalReceipt> approval =
      broker.IssueApproval(task, call, base::Minutes(1), 1);
  ASSERT_TRUE(approval);
  EXPECT_EQ(broker.Evaluate(task, call, approval->approval_id).disposition,
            AgentPolicyDisposition::kAllow);

  call.document->document_token.clear();
  EXPECT_EQ(broker.Evaluate(task, call).error, AgentErrorCode::kStaleDocument);

  call = PageClickCall();
  call.committed_url = GURL("https://other.example/product");
  EXPECT_EQ(broker.Evaluate(task, call).error, AgentErrorCode::kScopeViolation);
}

TEST(AegisAgentPolicyTest, ApprovalIsExactSingleUseAndExpires) {
  AgentToolRegistry registry;
  AgentPolicyBroker broker(&registry);
  AgentTask task("task-1", "apply bookmark plan", AgentMode::kAct, TestScope());
  ConsentTask(&task);
  AgentToolCall call = BookmarkApplyCall();
  const base::Time now = base::Time::Now();

  EXPECT_EQ(broker.Evaluate(task, call, std::nullopt, now).disposition,
            AgentPolicyDisposition::kRequireActionApproval);
  auto approval = broker.IssueApproval(task, call, base::Minutes(1), 1, now);
  ASSERT_TRUE(approval);

  AgentToolCall changed = BookmarkApplyCall();
  changed.arguments.Set("snapshot_hash", "sha256:changed");
  EXPECT_NE(AgentPolicyBroker::ActionHash(call),
            AgentPolicyBroker::ActionHash(changed));
  EXPECT_EQ(
      broker.Evaluate(task, changed, approval->approval_id, now).disposition,
      AgentPolicyDisposition::kRequireActionApproval);
  EXPECT_EQ(broker.Evaluate(task, call, approval->approval_id, now).disposition,
            AgentPolicyDisposition::kAllow);
  EXPECT_EQ(broker.Evaluate(task, call, approval->approval_id, now).disposition,
            AgentPolicyDisposition::kRequireActionApproval);

  auto expired = broker.IssueApproval(task, call, base::Seconds(1), 1, now);
  ASSERT_TRUE(expired);
  EXPECT_EQ(
      broker.Evaluate(task, call, expired->approval_id, now + base::Seconds(1))
          .disposition,
      AgentPolicyDisposition::kRequireActionApproval);
}

TEST(AegisAgentPolicyTest, FinalCheckoutAlwaysRequiresUserTakeover) {
  AgentToolRegistry registry;
  AgentPolicyBroker broker(&registry);
  AgentTask task("task-1", "prepare checkout", AgentMode::kAct, TestScope());
  ConsentTask(&task);
  AgentToolCall call = CheckoutCall();

  EXPECT_EQ(broker.Evaluate(task, call).disposition,
            AgentPolicyDisposition::kRequireUserTakeover);
  EXPECT_EQ(registry.Find("transaction.submit"), nullptr);
  EXPECT_EQ(registry.Find("script.execute"), nullptr);

  AgentTaskScope download_scope = TestScope();
  download_scope.allowed_tools.insert("download.open");
  download_scope.allowed_data_classes.insert(AgentDataClass::kDownloads);
  AgentTask download_task("task-download-open", "open verified download",
                          AgentMode::kAct, std::move(download_scope));
  ConsentTask(&download_task);
  AgentToolCall open;
  open.action_id = "download-open-1";
  open.tool_name = "download.open";
  open.arguments.Set("download_id", "download-1");
  EXPECT_EQ(broker.Evaluate(download_task, open).disposition,
            AgentPolicyDisposition::kRequireUserTakeover);
}

TEST(AegisAgentPolicyTest, RejectsArgumentScopeAndStateMismatch) {
  AgentToolRegistry registry;
  AgentPolicyBroker broker(&registry);
  AgentTask task("task-1", "safe navigation", AgentMode::kAct, TestScope());
  ConsentTask(&task);

  AgentToolCall click = PageClickCall();
  click.arguments.Set("tab_id", 8);
  EXPECT_EQ(broker.Evaluate(task, click).error, AgentErrorCode::kStaleDocument);

  AgentToolCall navigate;
  navigate.action_id = "navigate";
  navigate.tool_name = "page.navigate";
  navigate.committed_url = GURL("https://shop.example/current");
  navigate.arguments.Set("tab_id", 7);
  navigate.arguments.Set("url", "https://evil.example/");
  EXPECT_EQ(broker.Evaluate(task, navigate).error,
            AgentErrorCode::kScopeViolation);

  AgentToolCall activate;
  activate.action_id = "activate";
  activate.tool_name = "tab.activate";
  activate.arguments.Set("tab_id", 8);
  EXPECT_EQ(broker.Evaluate(task, activate).error,
            AgentErrorCode::kScopeViolation);

  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kPausedByUser, "pause"));
  EXPECT_EQ(broker.Evaluate(task, PageClickCall()).error,
            AgentErrorCode::kInvalidRequest);
}

TEST(AegisAgentPolicyTest, RejectsSecretsHiddenInWebMcpJson) {
  AgentToolRegistry registry;
  AgentPolicyBroker broker(&registry);
  AgentTaskScope scope = TestScope();
  scope.allowed_tools.insert("page.webmcp.invoke");
  AgentTask task("task-webmcp", "invoke page tool", AgentMode::kAct,
                 std::move(scope));
  ConsentTask(&task);

  AgentToolCall call;
  call.action_id = "webmcp-1";
  call.tool_name = "page.webmcp.invoke";
  call.committed_url = GURL("https://shop.example/product");
  call.document = AgentDocumentRef{.tab_id = 7,
                                   .frame_token = "frame-1",
                                   .document_token = "document-1",
                                   .committed_url = call.committed_url};
  call.arguments.Set("tab_id", 7);
  call.arguments.Set("document_token", "document-1");
  call.arguments.Set("name", "fixture.lookup");
  call.arguments.Set("tool_revision", "revision-1");
  call.arguments.Set("input_json",
                     R"({"query":"safe","nested":{"accessToken":"fixture"}})");

  const AgentPolicyDecision decision = broker.Evaluate(task, call);
  EXPECT_EQ(decision.disposition, AgentPolicyDisposition::kDeny);
  EXPECT_EQ(decision.error, AgentErrorCode::kScopeViolation);
}

TEST(AegisAgentPolicyTest, CompletedTaskAllowsOnlyScopedBookmarkUndo) {
  AgentToolRegistry registry;
  AgentPolicyBroker broker(&registry);
  AgentTaskScope scope = TestScope();
  scope.allowed_tools.insert("bookmark.undo");
  AgentTask task("task-undo", "organize bookmarks", AgentMode::kAct,
                 std::move(scope));
  ConsentTask(&task);
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kVerifying, "verified"));
  ASSERT_TRUE(task.TransitionTo(AgentTaskState::kCompleted, "done"));

  AgentToolCall undo;
  undo.action_id = "undo-1";
  undo.tool_name = "bookmark.undo";
  undo.arguments.Set("undo_token", "receipt-1");
  EXPECT_EQ(broker.Evaluate(task, undo).disposition,
            AgentPolicyDisposition::kAllow);

  EXPECT_EQ(broker.Evaluate(task, BookmarkApplyCall()).error,
            AgentErrorCode::kInvalidRequest);
}

TEST(AegisAgentToolRegistryTest, ExposesOnlyScopedFixedSchemas) {
  AgentToolRegistry registry;
  AgentTaskScope scope = TestScope();
  scope.allowed_tools = {"page.observe", "page.click"};
  std::vector<AgentModelToolDefinition> tools =
      registry.ModelToolsForScope(scope);
  ASSERT_EQ(tools.size(), 2u);
  EXPECT_EQ(tools[0].name, "page.observe");
  EXPECT_EQ(tools[1].name, "page.click");
  EXPECT_EQ(tools[0].input_schema.FindBool("additionalProperties"), false);

  base::DictValue valid;
  valid.Set("tab_id", 7);
  std::string error;
  EXPECT_TRUE(ValidateAgentToolArguments(tools[0], valid, &error)) << error;
  valid.Set("secret", "password");
  EXPECT_FALSE(ValidateAgentToolArguments(tools[0], valid, &error));
  EXPECT_EQ(error, "tool argument contains an unknown field");
}

TEST(AegisAgentPolicyTest, BookmarkCheckRequiresExactlyOneSelection) {
  AgentToolRegistry registry;
  AgentPolicyBroker broker(&registry);
  auto scope = TestScope();
  scope.allowed_tools.insert("bookmark.check_urls");
  AgentTask task("task-selection", "检查收藏", AgentMode::kAsk,
                 std::move(scope));
  ConsentTask(&task);
  AgentToolCall call;
  call.action_id = "check";
  call.tool_name = "bookmark.check_urls";
  EXPECT_EQ(broker.Evaluate(task, call).error, AgentErrorCode::kInvalidRequest);
  call.arguments.Set("selection_ref", "browser-issued-reference");
  EXPECT_EQ(broker.Evaluate(task, call).disposition,
            AgentPolicyDisposition::kAllow);
  call.arguments.Set("node_ids", base::ListValue());
  EXPECT_EQ(broker.Evaluate(task, call).error, AgentErrorCode::kInvalidRequest);
  call.arguments.Remove("selection_ref");
  EXPECT_EQ(broker.Evaluate(task, call).error, AgentErrorCode::kInvalidRequest);
  call.arguments.FindList("node_ids")->Append("local:fixture");
  EXPECT_EQ(broker.Evaluate(task, call).disposition,
            AgentPolicyDisposition::kAllow);
}

TEST(AegisAgentResultVerifierTest, BookmarkCoverageMustMatchNativeResults) {
  AgentToolRegistry registry;
  AgentResultVerifier verifier;
  AgentTask task("task-coverage", "检查收藏", AgentMode::kAsk, TestScope());
  AgentToolCall call;
  call.action_id = "check";
  call.tool_name = "bookmark.check_urls";
  call.arguments.Set("selection_ref", "current-reference");
  AgentToolResult result;
  result.action_id = call.action_id;
  result.ok = true;
  result.message = "原生检查完成";
  result.value.Set("selection_ref", "current-reference");
  result.value.Set("selected_count", 1);
  result.value.Set("attempted_count", 0);
  result.value.Set("list_truncated", false);
  base::DictValue counts;
  counts.Set("not_checked", 1);
  result.value.Set("classification_counts", std::move(counts));
  base::ListValue entries;
  base::DictValue entry;
  entry.Set("node_id", "local:fixture");
  entry.Set("classification", "not_checked");
  entries.Append(std::move(entry));
  result.value.Set("results", std::move(entries));
  const auto* descriptor = registry.Find(call.tool_name);
  ASSERT_TRUE(descriptor);
  EXPECT_TRUE(verifier.Verify(task, call, *descriptor, result).accepted);
  result.value.Set("selected_count", 500);
  EXPECT_FALSE(verifier.Verify(task, call, *descriptor, result).accepted);
  result.value.Set("selected_count", 1);
  result.value.Set("selection_ref", "foreign-reference");
  EXPECT_FALSE(verifier.Verify(task, call, *descriptor, result).accepted);
  result.value.Set("selection_ref", "current-reference");
  result.value.FindDict("classification_counts")->Set("live", 500);
  EXPECT_FALSE(verifier.Verify(task, call, *descriptor, result).accepted);
  result.value.FindDict("classification_counts")->Remove("live");
  result.value.FindList("results")->Append("malformed");
  EXPECT_FALSE(verifier.Verify(task, call, *descriptor, result).accepted);
}

TEST(AegisAgentToolRegistryTest, LoginRequiresAnExactObservedButton) {
  AgentToolRegistry registry;
  AgentTaskScope scope = TestScope();
  scope.allowed_tools = {"auth.attempt_login"};
  std::vector<AgentModelToolDefinition> tools =
      registry.ModelToolsForScope(scope);
  ASSERT_EQ(tools.size(), 1u);

  base::DictValue arguments;
  arguments.Set("tab_id", 7);
  arguments.Set("document_token", "document-7");
  std::string error;
  EXPECT_FALSE(ValidateAgentToolArguments(tools[0], arguments, &error));
  EXPECT_EQ(error, "required tool argument is missing");
  arguments.Set("password_button_node_id", 71);
  EXPECT_TRUE(ValidateAgentToolArguments(tools[0], arguments, &error)) << error;
}

TEST(AegisAgentToolRegistryTest, EveryV1ToolHasAStrictSchemaAndKnownRisk) {
  AgentToolRegistry registry;
  const std::vector<std::string_view> names = registry.Names();
  EXPECT_EQ(names.size(), 49u);
  EXPECT_TRUE(registry.Find("monitor.create"));
  EXPECT_TRUE(registry.Find("monitor.list"));
  EXPECT_TRUE(registry.Find("monitor.pause"));
  EXPECT_TRUE(registry.Find("monitor.delete"));
  for (std::string_view name : names) {
    const AgentToolDescriptor* descriptor = registry.Find(name);
    ASSERT_TRUE(descriptor) << name;
    EXPECT_NE(descriptor->risk, AgentRiskLevel::kBlocked) << name;
    std::optional<AgentModelToolDefinition> tool =
        registry.ModelToolForName(name);
    ASSERT_TRUE(tool) << name;
    EXPECT_EQ(tool->input_schema.FindString("type")
                  ? *tool->input_schema.FindString("type")
                  : std::string(),
              "object")
        << name;
    EXPECT_EQ(tool->input_schema.FindBool("additionalProperties"), false)
        << name;
  }
  EXPECT_EQ(registry.Find("script.execute"), nullptr);
  EXPECT_EQ(registry.Find("filesystem.read"), nullptr);
  EXPECT_EQ(registry.Find("transaction.submit"), nullptr);
}

TEST(AegisAgentResultVerifierTest, RejectsModelClaimWithoutBrowserEvidence) {
  AgentToolRegistry registry;
  AgentResultVerifier verifier;
  AgentTask task("task-verify", "verify page", AgentMode::kAct, TestScope());
  AgentToolCall call = PageClickCall();
  const AgentToolDescriptor* descriptor = registry.Find(call.tool_name);
  ASSERT_TRUE(descriptor);

  AgentToolResult claimed;
  claimed.action_id = call.action_id;
  claimed.ok = true;
  claimed.message = "model says click succeeded";
  EXPECT_FALSE(verifier.Verify(task, call, *descriptor, claimed).accepted);

  AgentToolResult observed;
  observed.action_id = call.action_id;
  observed.ok = true;
  observed.message = "fresh browser observation";
  observed.value.Set("tab_id", 7);
  observed.value.Set("url", "https://shop.example/after");
  observed.value.Set("frame_token", "frame-2");
  observed.value.Set("document_token", "document-2");
  observed.value.Set("observation_fingerprint", "fingerprint-2");
  observed.value.Set("untrusted", true);
  observed.value.Set("nodes", base::ListValue());
  base::DictValue evidence;
  evidence.Set("kind", "browser_observation");
  observed.evidence.Append(std::move(evidence));
  AgentVerificationDecision decision =
      verifier.Verify(task, call, *descriptor, observed);
  EXPECT_TRUE(decision.accepted) << decision.reason;
  EXPECT_TRUE(decision.postcondition_met);

  base::DictValue webmcp_result;
  webmcp_result.Set("name", "fixture.lookup");
  webmcp_result.Set("untrusted", true);
  webmcp_result.Set("result", R"({"sessionId":"fixture-secret"})");
  base::ListValue webmcp_results;
  webmcp_results.Append(std::move(webmcp_result));
  observed.value.Set("webmcp_results", std::move(webmcp_results));
  EXPECT_FALSE(verifier.Verify(task, call, *descriptor, observed).accepted);
}

TEST(AegisAgentResultVerifierTest, AcceptsStructuredBrowserFailure) {
  AgentToolRegistry registry;
  AgentResultVerifier verifier;
  AgentTask task("task-failure", "verify failure", AgentMode::kAct,
                 TestScope());
  AgentToolCall call = PageClickCall();
  AgentToolResult failure;
  failure.action_id = call.action_id;
  failure.ok = false;
  failure.error = AgentErrorCode::kStaleDocument;
  failure.message = "document changed";

  AgentVerificationDecision decision =
      verifier.Verify(task, call, *registry.Find(call.tool_name), failure);
  EXPECT_TRUE(decision.accepted);
  EXPECT_FALSE(decision.postcondition_met);
}

TEST(AegisAgentResultVerifierTest,
     AcceptsSessionBoundMonitorWithoutExposingTarget) {
  AgentToolRegistry registry;
  AgentResultVerifier verifier;
  AgentTaskScope scope = TestScope();
  scope.allowed_tools.insert("monitor.create");
  AgentTask task("task-monitor", "monitor fixture", AgentMode::kAutomate,
                 std::move(scope));
  AgentToolCall call;
  call.action_id = "monitor-create";
  call.tool_name = "monitor.create";

  AgentToolResult result;
  result.action_id = call.action_id;
  result.ok = true;
  result.message = "session monitor created";
  result.value.Set("monitor_id", "monitor-1");
  result.value.Set("target_hash", "sha256:fixture");
  result.value.Set("origin", "https://shop.example");
  result.value.Set("interval_minutes", 60);
  result.value.Set("revision", "sha256:revision");
  result.value.Set("session_only", true);
  AgentVerificationDecision decision =
      verifier.Verify(task, call, *registry.Find(call.tool_name), result);
  EXPECT_TRUE(decision.accepted) << decision.reason;
  EXPECT_TRUE(decision.postcondition_met);

  result.value.Set("target_url", "https://shop.example/private");
  EXPECT_FALSE(verifier.Verify(task, call, *registry.Find(call.tool_name),
                               result)
                   .accepted);
  result.value.Remove("target_url");
  result.value.Remove("session_only");
  EXPECT_FALSE(verifier.Verify(task, call, *registry.Find(call.tool_name),
                               result)
                   .accepted);
}

TEST(AegisAgentResultVerifierTest, VerifiesDynamicTabAndWorkspaceOwnership) {
  AgentToolRegistry registry;
  AgentResultVerifier verifier;
  AgentTask task("task-browser-data", "restore workspace", AgentMode::kAct,
                 TestScope());

  AgentToolCall create;
  create.action_id = "window-create";
  create.tool_name = "window.create";
  AgentToolResult created;
  created.action_id = create.action_id;
  created.ok = true;
  created.message = "created";
  created.value.Set("window_id", 3);
  created.value.Set("tab_id", 8);
  created.value.Set("revision", "window-revision");
  EXPECT_FALSE(
      verifier.Verify(task, create, *registry.Find(create.tool_name), created)
          .accepted);
  ASSERT_TRUE(task.AdoptOwnedTab(8));
  EXPECT_TRUE(
      verifier.Verify(task, create, *registry.Find(create.tool_name), created)
          .accepted);

  ASSERT_TRUE(task.AdoptOwnedTab(9));
  AgentToolCall restore;
  restore.action_id = "workspace-restore";
  restore.tool_name = "workspace.restore";
  AgentToolResult restored;
  restored.action_id = restore.action_id;
  restored.ok = true;
  restored.message = "restored";
  base::ListValue tab_ids;
  tab_ids.Append(8);
  tab_ids.Append(9);
  restored.value.Set("tab_ids", std::move(tab_ids));
  restored.value.Set("workspace_revision", "saved-revision");
  restored.value.Set("revision", "current-tabs-revision");
  EXPECT_TRUE(
      verifier
          .Verify(task, restore, *registry.Find(restore.tool_name), restored)
          .accepted);
}

TEST(AegisAgentResultVerifierTest, VerifiesScopedMetadataAndDownloadState) {
  AgentToolRegistry registry;
  AgentResultVerifier verifier;
  AgentTask task("task-native", "inspect and download", AgentMode::kAct,
                 TestScope());

  AgentToolCall permissions;
  permissions.action_id = "permissions";
  permissions.tool_name = "permissions.inspect";
  AgentToolResult inspected;
  inspected.action_id = permissions.action_id;
  inspected.ok = true;
  inspected.message = "inspected";
  inspected.value.Set("origin", "https://shop.example");
  base::DictValue settings;
  settings.Set("camera", "ask");
  inspected.value.Set("permissions", std::move(settings));
  EXPECT_TRUE(verifier
                  .Verify(task, permissions,
                          *registry.Find(permissions.tool_name), inspected)
                  .accepted);
  inspected.value.Set("origin", "https://evil.example");
  EXPECT_FALSE(verifier
                   .Verify(task, permissions,
                           *registry.Find(permissions.tool_name), inspected)
                   .accepted);

  AgentToolCall cancelled_call;
  cancelled_call.action_id = "cancel";
  cancelled_call.tool_name = "download.cancel";
  AgentToolResult cancelled;
  cancelled.action_id = cancelled_call.action_id;
  cancelled.ok = true;
  cancelled.message = "cancelled";
  cancelled.value.Set("download_id", "download-guid");
  cancelled.value.Set("state", "cancelled");
  EXPECT_TRUE(verifier
                  .Verify(task, cancelled_call,
                          *registry.Find(cancelled_call.tool_name), cancelled)
                  .accepted);

  AgentToolCall verify_call;
  verify_call.action_id = "verify";
  verify_call.tool_name = "download.verify";
  AgentToolResult verifying;
  verifying.action_id = verify_call.action_id;
  verifying.ok = true;
  verifying.message = "native state read";
  verifying.value.Set("download_id", "download-guid");
  verifying.value.Set("state", "in_progress");
  verifying.value.Set("verified", false);
  verifying.value.Set("safe_and_complete", false);
  verifying.value.Set("integrity", "not_provided");
  AgentVerificationDecision incomplete = verifier.Verify(
      task, verify_call, *registry.Find(verify_call.tool_name), verifying);
  EXPECT_TRUE(incomplete.accepted);
  EXPECT_FALSE(incomplete.postcondition_met);

  verifying.value.Set("state", "complete");
  verifying.value.Set("verified", true);
  verifying.value.Set("safe_and_complete", true);
  verifying.value.Set("integrity", "match");
  verifying.value.Set("sha256", std::string(64, 'a'));
  AgentVerificationDecision complete = verifier.Verify(
      task, verify_call, *registry.Find(verify_call.tool_name), verifying);
  EXPECT_TRUE(complete.accepted);
  EXPECT_TRUE(complete.postcondition_met);

  verifying.value.Set("integrity", "not_provided");
  EXPECT_FALSE(verifier
                   .Verify(task, verify_call,
                           *registry.Find(verify_call.tool_name), verifying)
                   .accepted);
}

}  // namespace
}  // namespace aegis::agent
