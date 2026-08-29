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
}

TEST(AegisAgentToolRegistryTest, SelectRequiresExactActionApproval) {
  AgentToolRegistry registry;
  const AgentToolDescriptor* select = registry.Find("page.select");
  ASSERT_TRUE(select);
  EXPECT_EQ(select->risk, AgentRiskLevel::kR2ExternalSideEffect);
  EXPECT_TRUE(select->has_external_side_effect);
  EXPECT_TRUE(select->requires_document);
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
