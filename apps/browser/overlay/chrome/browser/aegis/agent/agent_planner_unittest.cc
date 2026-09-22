// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_planner.h"

#include <string>
#include <string_view>
#include <utility>

#include "base/json/json_reader.h"
#include "chrome/browser/aegis/agent/agent_tool_registry.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {

AgentTaskScope MaximumScope() {
  AgentTaskScope scope;
  scope.allowed_origins = {
      url::Origin::Create(GURL("https://research.example/")),
      url::Origin::Create(GURL("https://docs.example/"))};
  scope.allowed_tab_ids = {17};
  scope.allowed_tools = {"page.observe", "page.navigate", "tab.create"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage,
                                AgentDataClass::kBrowserMetadata};
  scope.budgets.max_tabs = 8;
  scope.budgets.max_tool_calls = 20;
  scope.budgets.max_model_calls = 10;
  scope.budgets.max_network_requests = 40;
  scope.budgets.max_duration = base::Minutes(10);
  scope.model_destination.kind = AgentModelDestination::Kind::kOnDevice;
  scope.model_destination.provider = "fixture";
  scope.model_destination.model = "fixture-model";
  return scope;
}

AgentModelEvent ValidPlanEvent() {
  AgentModelEvent event;
  event.type = AgentModelEventType::kToolCall;
  event.tool_call_id = "plan-1";
  event.tool_name = "agent.submit_plan";
  event.arguments.Set("schema_version", kAgentSchemaVersion);
  event.arguments.Set("summary", "Read the approved research sources.");

  base::DictValue step;
  step.Set("id", "step-1");
  step.Set("title", "Read the current page");
  step.Set("tool", "page.observe");
  base::ListValue steps;
  steps.Append(std::move(step));
  event.arguments.Set("steps", std::move(steps));
  return event;
}

AgentModelEvent GoalRouteEvent(std::string workflow, std::string entry_kind,
                               std::string target) {
  AgentModelEvent event;
  event.type = AgentModelEventType::kToolCall;
  event.tool_call_id = "route-1";
  event.tool_name = "agent.route_goal";
  event.arguments.Set("schema_version", kAgentSchemaVersion);
  event.arguments.Set("workflow", std::move(workflow));
  event.arguments.Set("entry_kind", std::move(entry_kind));
  event.arguments.Set("target", std::move(target));
  event.arguments.Set("summary", "理解目标后选择浏览器入口");
  return event;
}

TEST(AegisAgentPlannerTest, EnglishGoalRejectsClearlyWrongDefaultLanguage) {
  EXPECT_TRUE(AgentTextHasWrongDefaultLanguage("总结页面并列出来源。",
                                               "Summarize this page."));
  EXPECT_FALSE(AgentTextHasWrongDefaultLanguage("Summarize the page.",
                                                "Summarize this page."));
  EXPECT_FALSE(
      AgentTextHasWrongDefaultLanguage("总结页面。", "总结当前页面。"));
  EXPECT_FALSE(
      AgentTextHasWrongDefaultLanguage("总结页面。", "Summarize in Chinese."));
  EXPECT_FALSE(AgentTextHasWrongDefaultLanguage(
      "翻译文本", "Translate this page into Chinese."));
  EXPECT_FALSE(AgentTextHasWrongDefaultLanguage("42", "Read the metric."));
}

TEST(AegisAgentPlannerTest, TaskTabGoalCannotExpandToWindowMetadata) {
  for (const char *goal :
       {"列出这个任务打开的标签页。", "列出本任务的标签页",
        "列出本任務開啟的標籤頁", "List open tabs for this task.",
        "列出当前窗口中本任务的标签页", "总结当前页面"}) {
    SCOPED_TRACE(goal);
    EXPECT_FALSE(AgentGoalRequestsWindowTabMetadata(goal));
  }
  for (const char *goal :
       {"统计当前窗口有几个标签", "列出所有标签页", "列出目前視窗的標籤頁",
        "List my tabs", "List open tabs"}) {
    SCOPED_TRACE(goal);
    EXPECT_TRUE(AgentGoalRequestsWindowTabMetadata(goal));
  }
}

TEST(AegisAgentGoalRegressionTest, NativeTitlesKeepMetadataOnlyPlans) {
  for (const auto &[goal, tool] : {
           std::pair{"列出所有标签页的页面标题", "tab.list"},
           std::pair{"列出所有標籤頁的頁面標題", "tab.list"},
           std::pair{"List all tab page titles", "tab.list"},
           std::pair{"读取收藏夹中 https://example.com/ 的书签标题",
                     "bookmark.list"},
           std::pair{"Read bookmark page titles", "bookmark.list"},
       }) {
    SCOPED_TRACE(goal);
    EXPECT_FALSE(AgentGoalRequiresPageEvidence(goal));
    AgentGoalRoute route;
    route.workflow = AgentWorkflowKind::kResearch;
    route.entry_kind = AgentGoalEntryKind::kWebSearch;
    route.target = goal;
    route = ConstrainGoalRouteToUserIntent(goal, std::move(route));
    EXPECT_EQ(route.workflow, AgentWorkflowKind::kBrowserSteward);
    EXPECT_EQ(route.entry_kind, AgentGoalEntryKind::kBrowserOnly);
    EXPECT_TRUE(route.target.empty());

    AgentTaskPlan plan;
    plan.steps.push_back({.step_id = "list",
                          .title = "读取原生标题",
                          .tool_name = tool,
                          .risk = AgentRiskLevel::kR0ReadOnly});
    std::string error;
    EXPECT_TRUE(ValidateTaskPlanForGoal(plan, goal, &error)) << error;
  }
}

TEST(AegisAgentGoalRegressionTest, NegatedHintKeepsPageBoundReadRequirement) {
  for (const char *goal : {
           "不要整理书签，总结当前页。",
           "不要整理書籤，總結 https://example.com/ 。",
           "Do not organize bookmarks, summarize this page.",
       }) {
    SCOPED_TRACE(goal);
    const auto workflow =
        ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kBrowserSteward);
    EXPECT_EQ(workflow, AgentWorkflowKind::kResearch);
    AgentTaskScope initial = MaximumScope();
    const auto scope = BuildAgentWorkflowScope(
        workflow, initial.allowed_origins, initial.allowed_tab_ids,
        initial.model_destination);
    ASSERT_TRUE(scope);
    EXPECT_TRUE(AgentTaskRequiresPageEvidence(goal, *scope));
    EXPECT_TRUE(scope->AllowsTool("page.observe"));
    EXPECT_FALSE(scope->AllowsTool("bookmark.apply"));
    EXPECT_FALSE(scope->AllowsTool("download.start"));

    // 不猜测逗号后的语义；验证浏览器已绑定页面时，模型不能以元数据收尾。
    AgentModelEvent event;
    event.type = AgentModelEventType::kToolCall;
    event.tool_call_id = "plan";
    event.tool_name = "agent.submit_plan";
    event.arguments.Set("schema_version", kAgentSchemaVersion);
    event.arguments.Set("summary", std::string_view(goal).starts_with("Do not")
                                       ? "Check the page reading scope"
                                       : "核对页面读取范围");
    base::ListValue steps;
    steps.Append(base::DictValue()
                     .Set("id", "read")
                     .Set("title", "读取页面")
                     .Set("tool", "tab.list"));
    event.arguments.Set("steps", std::move(steps));
    AgentToolRegistry registry;
    std::string error;
    EXPECT_FALSE(ParseAndValidateTaskPlan(event, *scope, registry, &error));
    AgentTaskPlan metadata_only;
    metadata_only.scope = *scope;
    metadata_only.steps.push_back({.step_id = "list",
                                   .title = "读取标签元数据",
                                   .tool_name = "tab.list",
                                   .risk = AgentRiskLevel::kR0ReadOnly});
    EXPECT_FALSE(ValidateTaskPlanForGoal(metadata_only, goal, &error));
    event.arguments.FindList("steps")->front().GetDict().Set("tool",
                                                             "page.observe");
    const auto plan = ParseAndValidateTaskPlan(event, *scope, registry, &error);
    ASSERT_TRUE(plan) << error;
    EXPECT_TRUE(AgentTaskRequiresPageEvidence(goal, plan->scope));
    EXPECT_TRUE(ValidateTaskPlanForGoal(*plan, goal, &error)) << error;
  }
}

TEST(AegisAgentGoalRegressionTest, BoundPageRequirementSurvivesScopeNarrowing) {
  const std::string_view goal = "不要整理书签，总结当前页。";
  // 文本本身仍有禁止范围歧义；统一门槛必须依赖浏览器范围补足。
  EXPECT_FALSE(AgentGoalRequiresPageEvidence(goal));
  AgentTaskScope scope = MaximumScope();
  EXPECT_TRUE(AgentTaskRequiresPageEvidence(goal, scope));
  scope.allowed_tools = {"page.observe"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage};
  EXPECT_TRUE(AgentTaskRequiresPageEvidence(goal, scope));

  scope.allowed_tools.insert("page.extract");
  AgentTaskPlan title_only;
  title_only.scope = scope;
  title_only.steps.push_back({.step_id = "extract",
                              .title = "仅提取标题",
                              .tool_name = "page.extract",
                              .risk = AgentRiskLevel::kR0ReadOnly});
  std::string error;
  EXPECT_FALSE(ValidateTaskPlanForGoal(title_only, goal, &error));
  AgentToolRegistry registry;
  scope.allowed_tools = {"page.extract"};
  // 此范围无法形成合法的已绑定页面计划；不能把 extract 当作 observe 授权。
  EXPECT_FALSE(AgentTaskRequiresPageEvidence(goal, scope));
  EXPECT_FALSE(BuildBrowserReadOnlyRecoveryPlan(goal, scope, registry));

  scope.allowed_tools = {"page.observe", "tab.list"};
  scope.allowed_data_classes.insert(AgentDataClass::kBrowserMetadata);
  EXPECT_TRUE(AgentTaskRequiresPageEvidence(goal, scope));
  const auto recovery = BuildBrowserReadOnlyRecoveryPlan(goal, scope, registry);
  ASSERT_TRUE(recovery);
  const auto plan =
      ParseAndValidateTaskPlan(*recovery, scope, registry, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->steps.front().tool_name, "page.observe");
  EXPECT_TRUE(AgentTaskRequiresPageEvidence(goal, plan->scope));
  EXPECT_TRUE(ValidateTaskPlanForGoal(*plan, goal, &error)) << error;

  // 原生任务即使持有公共来源，也不会仅因数据类别包含 public_page 被升级。
  scope.allowed_tools = {"tab.list", "bookmark.list"};
  scope.allowed_data_classes.insert(AgentDataClass::kBookmarks);
  EXPECT_FALSE(
      AgentTaskRequiresPageEvidence("列出所有标签页的页面标题", scope));
  EXPECT_FALSE(AgentTaskRequiresPageEvidence(
      "读取收藏夹中 https://example.com/ 的书签标题", scope));
  EXPECT_FALSE(AgentTaskRequiresPageEvidence(
      "只统计标签页，不要读取页面内容、下载、整理书签。", scope));
  EXPECT_TRUE(AgentTaskRequiresPageEvidence("总结页面内容", scope));
}

TEST(AegisAgentGoalRegressionTest, DeniedListsDoNotCreateNativeRequirements) {
  for (const char *goal : {
           "只统计标签页，不要读取页面内容、下载、整理书签。",
           "只統計標籤頁，不要讀取頁面內容、下載、整理書籤。",
           "List tabs. Do not read page content, download, organize bookmarks.",
       }) {
    SCOPED_TRACE(goal);
    EXPECT_FALSE(AgentGoalRequiresPageEvidence(goal));
    EXPECT_EQ(
        ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kBrowserSteward),
        AgentWorkflowKind::kBrowserSteward);
    AgentTaskPlan plan;
    plan.steps.push_back({.step_id = "list",
                          .title = "统计标签页",
                          .tool_name = "tab.list",
                          .risk = AgentRiskLevel::kR0ReadOnly});
    std::string error;
    EXPECT_TRUE(ValidateTaskPlanForGoal(plan, goal, &error)) << error;
  }
  for (const auto &[goal, current_page] :
       std::initializer_list<std::pair<const char *, bool>>{
           {"总结当前页；不要下载、整理书签、提交或购买。", true},
           {"總結目前網頁；不要下載、整理書籤、提交或購買。", true},
           {"Summarize this page. Do not download, organize bookmarks, or buy.",
            true},
           {"不要官方下载、整理书签、提交或购买。", false},
           {"不要官方下载，整理书签。", false},
           {"Do not download official installers, organize bookmarks, or buy.",
            false},
       }) {
    SCOPED_TRACE(goal);
    AgentGoalRoute route;
    route.workflow = AgentWorkflowKind::kResearch;
    route.entry_kind = AgentGoalEntryKind::kOpenUrl;
    route.target = "https://example.com/";
    route = ConstrainGoalRouteToUserIntent(goal, std::move(route));
    EXPECT_EQ(route.workflow, AgentWorkflowKind::kResearch);
    // 否定清单仍不能增加原生操作；当前页任务同时禁止保留猜测的网址。
    EXPECT_EQ(route.entry_kind, current_page ? AgentGoalEntryKind::kBrowserOnly
                                             : AgentGoalEntryKind::kOpenUrl);
    EXPECT_EQ(route.target, current_page ? "" : "https://example.com/");
  }
}

TEST(AegisAgentGoalRegressionTest, PageObjectsRequireEvidenceWithoutVerbList) {
  for (const char *goal : {
           "翻译当前页，不要整理书签。",
           "翻譯目前網頁；不要整理書籤。",
           "Translate this page. Do not organize bookmarks.",
           "给当前网页挑错",
           "逐句点评 https://example.com/article",
       }) {
    SCOPED_TRACE(goal);
    EXPECT_TRUE(AgentGoalRequiresPageEvidence(goal));
    EXPECT_EQ(
        ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kBrowserSteward),
        AgentWorkflowKind::kResearch);
    AgentTaskPlan plan;
    plan.steps.push_back({.step_id = "list",
                          .title = "读取标签页",
                          .tool_name = "tab.list",
                          .risk = AgentRiskLevel::kR0ReadOnly});
    std::string error;
    EXPECT_FALSE(ValidateTaskPlanForGoal(plan, goal, &error));
  }
}

TEST(AegisAgentGoalRegressionTest, NativeTitlesDoNotHideSeparatePageContent) {
  for (const char *goal : {
           "列出书签标题，并总结当前页面内容",
           "列出标签页的页面标题，并读取当前网页",
           "读取收藏夹中 https://example.com/ 的正文",
       }) {
    EXPECT_TRUE(AgentGoalRequiresPageEvidence(goal)) << goal;
  }
  for (const char *goal : {"保存当前页到书签", "List workspace titles"}) {
    EXPECT_FALSE(AgentGoalRequiresPageEvidence(goal)) << goal;
  }
}

TEST(AegisAgentGoalRegressionTest, CheckoutReviewCannotUseTabMetadataOnly) {
  for (const char *goal :
       {"准备核对订单，最终购买由我操作。", "準備核對訂單，最後購買由我操作。",
        "Review this order; I will make the final purchase."}) {
    SCOPED_TRACE(goal);
    EXPECT_TRUE(AgentGoalRequiresPageEvidence(goal));
    EXPECT_EQ(
        ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kBrowserSteward),
        AgentWorkflowKind::kResearch);
    EXPECT_EQ(ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kShopping),
              AgentWorkflowKind::kResearch);
  }
}

TEST(AegisAgentGoalRegressionTest, TraditionalWorkflowsKeepNativeCapabilities) {
  for (const char *goal : {
           "讀取 https://example.com/ 並核對官方下載地址。",
           "读取 https://example.com/ 并核对官方下载地址。",
       }) {
    SCOPED_TRACE(goal);
    EXPECT_EQ(
        ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kSafeDownload),
        AgentWorkflowKind::kSafeDownload);
    EXPECT_EQ(ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kResearch),
              AgentWorkflowKind::kSafeDownload);
    AgentGoalRoute route;
    route.workflow = AgentWorkflowKind::kResearch;
    route.entry_kind = AgentGoalEntryKind::kOpenUrl;
    route.target = "https://example.com/";
    EXPECT_EQ(ConstrainGoalRouteToUserIntent(goal, std::move(route)).workflow,
              AgentWorkflowKind::kSafeDownload);
  }
  for (const char *goal : {
           "在 https://example.com/ 幫我準備結帳；不要付款。",
           "在 https://example.com/ 帮我准备结账；不要付款。",
       }) {
    SCOPED_TRACE(goal);
    const auto workflow =
        ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kShopping);
    EXPECT_EQ(workflow, AgentWorkflowKind::kShopping);
    AgentTaskScope initial = MaximumScope();
    const auto scope = BuildAgentWorkflowScope(
        workflow, initial.allowed_origins, initial.allowed_tab_ids,
        initial.model_destination);
    ASSERT_TRUE(scope);
    EXPECT_TRUE(scope->AllowsTool("shopping.prepare_checkout"));
    EXPECT_TRUE(GetAgentWorkflowTemplate(workflow)
                    .always_user_takeover_for_final_action);
  }
  for (const char *goal : {"閱讀網頁並給出購買建議；不要結帳或付款。",
                           "讀取網頁；不要官方下載、整理書籤或購買。"}) {
    SCOPED_TRACE(goal);
    EXPECT_EQ(ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kShopping),
              AgentWorkflowKind::kResearch);
    EXPECT_EQ(
        ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kSafeDownload),
        AgentWorkflowKind::kResearch);
  }
}

TEST(AegisAgentGoalRegressionTest,
     DownloadSourcePlanCannotOmitNativeAssessment) {
  AgentTaskPlan plan;
  plan.steps.push_back({.step_id = "observe",
                        .title = "读取当前页面",
                        .tool_name = "page.observe",
                        .risk = AgentRiskLevel::kR0ReadOnly});
  plan.steps.push_back({.step_id = "extract",
                        .title = "提取页面内容",
                        .tool_name = "page.extract",
                        .risk = AgentRiskLevel::kR0ReadOnly});
  std::string error;
  for (const char *goal :
       {"在当前页面找到 macOS ARM64 的官方下载，先不要下载。",
        "在目前網頁核對官方下載地址。",
        "Find the official download link on this page."}) {
    EXPECT_FALSE(ValidateTaskPlanForGoal(plan, goal, &error)) << goal;
    EXPECT_NE(error.find("download.find_official"), std::string::npos);
  }
  for (const char *goal : {"总结当前网页。", "把官方下载页翻译成英文。",
                           "核对刚下载的文件是否已经安装。"}) {
    EXPECT_TRUE(ValidateTaskPlanForGoal(plan, goal, &error)) << error;
  }
  plan.steps.push_back({.step_id = "source",
                        .title = "核验下载来源",
                        .tool_name = "download.find_official",
                        .risk = AgentRiskLevel::kR0ReadOnly});
  EXPECT_TRUE(ValidateTaskPlanForGoal(
      plan, "在当前页面找到 macOS ARM64 的官方下载，先不要下载。", &error))
      << error;
}

TEST(AegisAgentGoalRegressionTest, ExplicitCheckoutPreparationKeepsShopping) {
  for (const char *goal : {"核对订单并准备结账，最终购买由我操作。",
                           "核對訂單並準備結帳，最後購買由我操作。",
                           "Review this order and prepare checkout."}) {
    EXPECT_EQ(ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kShopping),
              AgentWorkflowKind::kShopping)
        << goal;
  }
}

TEST(AegisAgentGoalRegressionTest, ExplicitPageDownloadKeepsDownloadWorkflow) {
  for (const char *goal : {
           "下载当前页面提供的 macOS ARM64 测试文件，并核对页面提供的 SHA-256 "
           "完整性；不要运行或安装文件。",
           "请帮我下载所选文件；不要运行。",
           "开始页面中的慢速测试下载后取消。",
           "開始頁面中的慢速測試下載後取消。",
           "Start the download on this page, then cancel it.",
           "請下載目前頁面的測試檔案；不要安裝。",
           "Please download the file on this page; do not run it.",
       }) {
    SCOPED_TRACE(goal);
    EXPECT_EQ(
        ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kSafeDownload),
        AgentWorkflowKind::kSafeDownload);
  }
}

TEST(AegisAgentGoalRegressionTest, DownloadDiscussionAndDenialRemainReadOnly) {
  for (const char *goal : {
           "总结当前页面；不要下载当前页面文件。",
           "解释如何下载当前页面的文件，不要操作。",
           "总结当前页面下载量和下载速度。",
           "解释开始页面中的慢速测试下载的作用。",
           "开始页面中的视频；不要下载文件。",
           "Summarize this page; do not download the file.",
       }) {
    SCOPED_TRACE(goal);
    EXPECT_EQ(
        ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kSafeDownload),
        AgentWorkflowKind::kResearch);
  }
}

TEST(AegisAgentGoalRegressionTest, CurrentPageDownloadRouteKeepsNativeTools) {
  EXPECT_EQ(ConstrainWorkflowToUserIntent(
                "在当前页面找到 macOS ARM64 的官方下载，先不要下载。",
                AgentWorkflowKind::kResearch),
            AgentWorkflowKind::kSafeDownload);
  EXPECT_EQ(ConstrainWorkflowToUserIntent("核对刚下载的文件是否已经安装。",
                                          AgentWorkflowKind::kBrowserSteward),
            AgentWorkflowKind::kSafeDownload);
  EXPECT_FALSE(
      AgentGoalRequestsDownloadTransfer("核对刚下载的文件是否已经安装。"));
  AgentGoalRoute route;
  route.workflow = AgentWorkflowKind::kResearch;
  route.entry_kind = AgentGoalEntryKind::kBrowserOnly;
  auto result = ConstrainGoalRouteToUserIntent(
      "开始页面中的慢速测试下载后取消。", std::move(route));
  EXPECT_EQ(result.workflow, AgentWorkflowKind::kSafeDownload);
  EXPECT_EQ(result.entry_kind, AgentGoalEntryKind::kBrowserOnly);
  EXPECT_TRUE(
      AgentGoalRequestsDownloadTransfer("开始页面中的慢速测试下载后取消。"));
  EXPECT_FALSE(AgentGoalRequestsDownloadTransfer("找到官方下载，先不要下载。"));
}

TEST(AegisAgentGoalRegressionTest, DownloadRequestsAcceptOrdinaryPhrasing) {
  for (const char *goal :
       {"从当前官方合成发布页下载适合本机的安装包，只下载，不打开。",
        "找官方下载并实际下载当前网页的macOS arm64测试包。",
        "实际下载当前页面中适合macOS arm64的合成测试包。",
        "请帮我从这个网页下载文件并核对SHA-256。",
        "先找到链接，然后下载所选文件。",
        "請從目前網頁下載適合本機的檔案，不執行。",
        "Please find the official link and actually download the file.",
        "Please help me download the selected file."}) {
    SCOPED_TRACE(goal);
    EXPECT_TRUE(AgentGoalRequestsDownloadTransfer(goal));
    EXPECT_EQ(ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kResearch),
              AgentWorkflowKind::kSafeDownload);
  }
}

TEST(AegisAgentGoalRegressionTest,
     DownloadRequestsDoNotExpandDiscussionOrDenial) {
  for (const char *goal :
       {"找到官方下载，先不要下载。", "下载当前文件，但不要下载。",
        "不下载文件，只查看说明。", "只找官方下载链接。",
        "请解释如何查找链接，然后下载文件。", "介绍下载文件的方法。",
        "下载量是多少？", "下载速度为什么很慢？", "下载地址在哪里？",
        "下载的文件是否已经安装？", "核对刚下载的文件。",
        "总结“下载当前文件”的操作说明。", "不要下载、不要执行文件。",
        "Please explain how to find and download the file.",
        "Find the link and do not download the file.",
        "Do not download this file.", "請勿下載這個檔案。"}) {
    EXPECT_FALSE(AgentGoalRequestsDownloadTransfer(goal)) << goal;
  }
}

TEST(AegisAgentPlannerTest, WindowMetadataBindingComesOnlyFromBrowserScope) {
  AgentTaskScope scope = MaximumScope();
  scope.allowed_origins.clear();
  scope.allowed_tools = {"tab.list", "bookmark.list"};
  scope.allowed_data_classes = {AgentDataClass::kBrowserMetadata,
                                AgentDataClass::kBookmarks};
  scope.tab_metadata_window_id = 41;
  AgentModelEvent event = ValidPlanEvent();
  event.arguments.FindList("steps")->front().GetDict().Set("tool", "tab.list");
  AgentToolRegistry registry;
  std::string error;
  auto plan = ParseAndValidateTaskPlan(event, scope, registry, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->scope.tab_metadata_window_id, 41);
  EXPECT_EQ(plan->scope.allowed_tab_ids, scope.allowed_tab_ids);
  EXPECT_FALSE(plan->scope.AllowsTab(41));
  event.arguments.Set("tab_metadata_window_id", 42);
  EXPECT_FALSE(ParseAndValidateTaskPlan(event, scope, registry, &error));
  event = ValidPlanEvent();
  event.arguments.FindList("steps")->front().GetDict().Set("tool",
                                                           "bookmark.list");
  plan = ParseAndValidateTaskPlan(event, scope, registry, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_EQ(plan->scope.tab_metadata_window_id, 0);
}

TEST(AegisAgentPlannerTest, CurrentPageModifiersCannotRouteToAnotherSite) {
  for (const auto *goal :
       {"从当前官方合成发布页下载适合本机 macOS arm64 "
        "的测试安装包，核验页面公布的 "
        "SHA-256。只下载，不打开、不执行、不安装。",
        "从当前官方发布页下载测试安装包", "从当前官方下载页下载",
        "总结当前产品详情页面", "打开当前官方发布页中的下载链接",
        "Open the current release page download link",
        "Download from the current official download page",
        "从这个软件的官方发布页下载", "总结目前正在浏览的网页",
        "從當前官方合成發佈頁下載測試檔案", "總結這個產品詳情頁", "总结本页",
        "Download from the current official release page",
        "Summarize this official product page", "Read the currently open tab",
        "Summarize the active product page", "帮我总结下页面内容"}) {
    SCOPED_TRACE(goal);
    EXPECT_TRUE(AgentGoalRefersToCurrentPage(goal));
    for (const auto entry :
         {AgentGoalEntryKind::kOpenUrl, AgentGoalEntryKind::kWebSearch}) {
      AgentGoalRoute route;
      route.workflow = AgentWorkflowKind::kResearch;
      route.entry_kind = entry;
      route.target = "https://www.electronjs.org/latest";
      const auto constrained = ConstrainGoalRouteToUserIntent(goal, route);
      EXPECT_EQ(constrained.entry_kind, AgentGoalEntryKind::kBrowserOnly);
      EXPECT_TRUE(constrained.target.empty());
    }
  }
}

TEST(AegisAgentPlannerTest, CurrentPageBindingPreservesExplicitOtherTargets) {
  for (const auto *goal :
       {"打开 https://example.com/releases 并总结当前页面",
        "从 www.example.com 下载并核对当前页面", "去 GitHub 搜索当前官方发布页",
        "在京东搜索当前产品页面", "上网搜索当前官方发布页",
        "打开另一个网站再总结当前页面", "访问 Mozilla 并总结当前页面",
        "不要读取当前官方发布页；请搜索浏览器论文",
        "当前版本的官方发布页是什么", "当前时间是多少，搜索官方发布页",
        "总结当前之前打开的页面", "总结过去打开的发布页",
        "Search for the current official release page",
        "Visit GitHub and summarize this page",
        "Read the current previous page",
        "Find the current version on the release page",
        "Summarize this wallpaper", "列出当前窗口的标签页标题"}) {
    SCOPED_TRACE(goal);
    EXPECT_FALSE(AgentGoalRefersToCurrentPage(goal));
  }
  AgentGoalRoute route;
  route.entry_kind = AgentGoalEntryKind::kOpenUrl;
  route.target = "https://example.com/releases";
  EXPECT_EQ(ConstrainGoalRouteToUserIntent(
                "打开 https://example.com/releases 并总结当前页面", route)
                .target,
            route.target);
}

TEST(AegisAgentPlannerTest, GoalRouterChoosesNativeUrlOrSearchEntry) {
  std::string error;
  std::optional<AgentGoalRoute> native = ParseAndValidateGoalRoute(
      GoalRouteEvent("browser_steward", "browser_only", ""), &error);
  ASSERT_TRUE(native) << error;
  EXPECT_EQ(native->workflow, AgentWorkflowKind::kBrowserSteward);
  EXPECT_EQ(native->entry_kind, AgentGoalEntryKind::kBrowserOnly);

  std::optional<AgentGoalRoute> current_page = ParseAndValidateGoalRoute(
      GoalRouteEvent("research", "browser_only", ""), &error);
  ASSERT_TRUE(current_page) << error;
  EXPECT_EQ(current_page->workflow, AgentWorkflowKind::kResearch);
  EXPECT_EQ(current_page->entry_kind, AgentGoalEntryKind::kBrowserOnly);

  std::optional<AgentGoalRoute> redundant_target = ParseAndValidateGoalRoute(
      GoalRouteEvent("browser_steward", "browser_only",
                     "整理收藏夹里的 GitHub 链接"),
      &error);
  ASSERT_TRUE(redundant_target) << error;
  EXPECT_EQ(redundant_target->entry_kind, AgentGoalEntryKind::kBrowserOnly);
  EXPECT_TRUE(redundant_target->target.empty());

  std::optional<AgentGoalRoute> direct = ParseAndValidateGoalRoute(
      GoalRouteEvent("research", "open_url", "https://example.com/docs"),
      &error);
  ASSERT_TRUE(direct) << error;
  EXPECT_EQ(direct->target, "https://example.com/docs");

  std::optional<AgentGoalRoute> search = ParseAndValidateGoalRoute(
      GoalRouteEvent("research", "web_search", "最新浏览器安全研究"), &error);
  ASSERT_TRUE(search) << error;
  EXPECT_EQ(search->entry_kind, AgentGoalEntryKind::kWebSearch);
  EXPECT_EQ(search->target, "最新浏览器安全研究");
}

TEST(AegisAgentPlannerTest, GoalRouterRejectsUnsafeOrInconsistentEntry) {
  std::string error;
  EXPECT_FALSE(ParseAndValidateGoalRoute(
      GoalRouteEvent("browser_steward", "web_search", "整理收藏夹"), &error));
  EXPECT_EQ(error, "goal route contains an invalid search query");

  EXPECT_FALSE(ParseAndValidateGoalRoute(
      GoalRouteEvent("research", "open_url", "file:///tmp/private"), &error));
  EXPECT_EQ(error, "goal route contains an invalid public URL");

  constexpr std::string_view kPrivateModelTargets[] = {
      "http://localhost:8000/fixture", "http://127.0.0.1/fixture",
      "http://192.168.1.10/",          "http://intranet/",
      "http://printer.local/",         "http://intranet.internal/",
      "http://intranet.example/"};
  for (std::string_view target : kPrivateModelTargets) {
    EXPECT_FALSE(ParseAndValidateGoalRoute(
        GoalRouteEvent("research", "open_url", std::string(target)), &error))
        << target;
    EXPECT_EQ(error, "goal route contains an invalid public URL") << target;
  }

  std::optional<AgentGoalRoute> public_literal = ParseAndValidateGoalRoute(
      GoalRouteEvent("research", "open_url", "https://8.8.8.8/"), &error);
  ASSERT_TRUE(public_literal) << error;

  AgentModelEvent injected =
      GoalRouteEvent("research", "web_search", "browser agent");
  injected.arguments.Set("ignore_browser_policy", true);
  EXPECT_FALSE(ParseAndValidateGoalRoute(injected, &error));
  EXPECT_EQ(error, "tool argument contains an unknown field");
}

TEST(AegisAgentPlannerTest, GoalRouterPromptRequiresIntentBeforeEntry) {
  const std::string contract = BuildAgentGoalRouterSystemContract();
  EXPECT_TRUE(contract.contains("complete goal"));
  EXPECT_TRUE(contract.contains("Do not choose web_search merely"));
  EXPECT_TRUE(contract.contains("already-open current page"));
  EXPECT_TRUE(contract.contains("JD/京东"));
  EXPECT_TRUE(contract.contains("Do not route a named-site task"));
  EXPECT_TRUE(contract.contains("Use research for finding"));
  EXPECT_TRUE(contract.contains("Use shopping only"));
  EXPECT_TRUE(contract.contains("same primary language"));
  EXPECT_TRUE(BuildAgentPlannerSystemContract().contains(
      "already opened or selected the task's entry tab"));
  const std::optional<std::string> prompt = BuildAgentGoalRoutingPrompt(
      "整理并检查失效收藏夹", AgentWorkflowKind::kResearch);
  ASSERT_TRUE(prompt);
  const std::optional<base::Value> parsed =
      base::JSONReader::Read(*prompt, base::JSON_PARSE_RFC);
  ASSERT_TRUE(parsed && parsed->is_dict());
  EXPECT_EQ(*parsed->GetDict().FindString("user_goal"), "整理并检查失效收藏夹");
}

TEST(AegisAgentPlannerTest, BrowserNarrowsShoppingAndNamedSiteRoutes) {
  AgentGoalRoute discovery;
  discovery.workflow = AgentWorkflowKind::kShopping;
  discovery.entry_kind = AgentGoalEntryKind::kOpenUrl;
  discovery.target = "https://search.jd.com/Search?keyword=memory";
  AgentGoalRoute narrowed = ConstrainGoalRouteToUserIntent(
      "帮我在 JD 找几款内存", std::move(discovery));
  EXPECT_EQ(narrowed.workflow, AgentWorkflowKind::kResearch);
  EXPECT_EQ(narrowed.target, "https://search.jd.com/Search?keyword=memory");

  AgentGoalRoute general_search;
  general_search.workflow = AgentWorkflowKind::kResearch;
  general_search.entry_kind = AgentGoalEntryKind::kWebSearch;
  general_search.target = "京东 内存";
  AgentGoalRoute direct =
      ConstrainGoalRouteToUserIntent("在京东找内存", std::move(general_search));
  EXPECT_EQ(direct.entry_kind, AgentGoalEntryKind::kOpenUrl);
  EXPECT_EQ(GURL(direct.target).host(), "search.jd.com");
  EXPECT_TRUE(GURL(direct.target).query().contains("keyword="));

  AgentGoalRoute open_site;
  open_site.workflow = AgentWorkflowKind::kResearch;
  open_site.entry_kind = AgentGoalEntryKind::kWebSearch;
  open_site.target = "京东";
  EXPECT_EQ(
      ConstrainGoalRouteToUserIntent("打开京东", std::move(open_site)).target,
      "https://www.jd.com/");

  AgentGoalRoute homepage_for_search;
  homepage_for_search.workflow = AgentWorkflowKind::kResearch;
  homepage_for_search.entry_kind = AgentGoalEntryKind::kOpenUrl;
  homepage_for_search.target = "https://www.jd.com/";
  AgentGoalRoute direct_from_homepage = ConstrainGoalRouteToUserIntent(
      "帮我在 JD 找几款内存", std::move(homepage_for_search));
  EXPECT_EQ(GURL(direct_from_homepage.target).host(), "search.jd.com");
  EXPECT_TRUE(GURL(direct_from_homepage.target).query().contains("keyword="));

  AgentGoalRoute unrelated_url;
  unrelated_url.workflow = AgentWorkflowKind::kResearch;
  unrelated_url.entry_kind = AgentGoalEntryKind::kOpenUrl;
  unrelated_url.target = "https://example.com/search?q=memory";
  AgentGoalRoute direct_from_unrelated =
      ConstrainGoalRouteToUserIntent("在京东找内存", std::move(unrelated_url));
  EXPECT_EQ(GURL(direct_from_unrelated.target).host(), "search.jd.com");
  EXPECT_TRUE(GURL(direct_from_unrelated.target).query().contains("keyword="));

  AgentGoalRoute mistaken_browser_only;
  mistaken_browser_only.workflow = AgentWorkflowKind::kBrowserSteward;
  mistaken_browser_only.entry_kind = AgentGoalEntryKind::kBrowserOnly;
  AgentGoalRoute corrected_browser_only = ConstrainGoalRouteToUserIntent(
      "在京东找几款内存", std::move(mistaken_browser_only));
  EXPECT_EQ(corrected_browser_only.workflow, AgentWorkflowKind::kResearch);
  EXPECT_EQ(corrected_browser_only.entry_kind, AgentGoalEntryKind::kOpenUrl);
  EXPECT_EQ(GURL(corrected_browser_only.target).host(), "search.jd.com");
  EXPECT_TRUE(GURL(corrected_browser_only.target).query().contains("keyword="));

  AgentGoalRoute purchase;
  purchase.workflow = AgentWorkflowKind::kShopping;
  purchase.entry_kind = AgentGoalEntryKind::kOpenUrl;
  purchase.target = "https://www.amazon.com/";
  EXPECT_EQ(ConstrainGoalRouteToUserIntent(
                "Buy this on Amazon and add it to cart", std::move(purchase))
                .workflow,
            AgentWorkflowKind::kShopping);

  AgentGoalRoute official_download;
  official_download.workflow = AgentWorkflowKind::kResearch;
  official_download.entry_kind = AgentGoalEntryKind::kWebSearch;
  official_download.target = "VLC 官方下载地址";
  EXPECT_EQ(ConstrainGoalRouteToUserIntent("帮我找 VLC 的官方下载地址",
                                           std::move(official_download))
                .workflow,
            AgentWorkflowKind::kSafeDownload);

  AgentGoalRoute browser_only;
  browser_only.workflow = AgentWorkflowKind::kBrowserSteward;
  browser_only.entry_kind = AgentGoalEntryKind::kBrowserOnly;
  EXPECT_EQ(ConstrainGoalRouteToUserIntent("整理收藏夹里的 GitHub 链接",
                                           std::move(browser_only))
                .entry_kind,
            AgentGoalEntryKind::kBrowserOnly);

  AgentGoalRoute weak_bookmark_route;
  weak_bookmark_route.workflow = AgentWorkflowKind::kResearch;
  weak_bookmark_route.entry_kind = AgentGoalEntryKind::kWebSearch;
  weak_bookmark_route.target = "GitHub bookmarks";
  AgentGoalRoute corrected_bookmark_route = ConstrainGoalRouteToUserIntent(
      "整理收藏夹里的 GitHub 链接，先给预览，不要修改",
      std::move(weak_bookmark_route));
  EXPECT_EQ(corrected_bookmark_route.workflow,
            AgentWorkflowKind::kBrowserSteward);
  EXPECT_EQ(corrected_bookmark_route.entry_kind,
            AgentGoalEntryKind::kBrowserOnly);
  EXPECT_TRUE(corrected_bookmark_route.target.empty());
}

TEST(AegisAgentPlannerTest, NegatedWorkflowPhrasesKeepPageEntryRoutes) {
  for (std::string_view goal : {
           "打开 https://research.example/slow 并总结页面内容。只允许读取这个"
           "公开测试来源；不要下载、整理书签、提交或购买。",
           "開啟 https://research.example/slow 並總結網頁內容；不要下載、"
           "整理書籤、提交或購買。",
           "Open https://research.example/slow and summarize the page content. "
           "Do not download, organize bookmarks, submit, or purchase.",
       }) {
    SCOPED_TRACE(goal);
    AgentGoalRoute route;
    route.workflow = AgentWorkflowKind::kResearch;
    route.entry_kind = AgentGoalEntryKind::kOpenUrl;
    route.target = "https://research.example/slow";
    const AgentGoalRoute constrained =
        ConstrainGoalRouteToUserIntent(goal, std::move(route));
    EXPECT_EQ(constrained.workflow, AgentWorkflowKind::kResearch);
    EXPECT_EQ(constrained.entry_kind, AgentGoalEntryKind::kOpenUrl);
    EXPECT_EQ(constrained.target, "https://research.example/slow");
  }
}

TEST(AegisAgentPlannerTest, PageIntentOverridesNegatedWorkflowHints) {
  const std::string_view goal =
      "打开 http://127.0.0.1:52861/slow 并总结页面内容。只允许读取这个"
      "本地公开测试来源；不要下载、整理书签、提交或购买。";
  for (AgentWorkflowKind hint :
       {AgentWorkflowKind::kResearch, AgentWorkflowKind::kBrowserSteward,
        AgentWorkflowKind::kSafeDownload, AgentWorkflowKind::kShopping}) {
    EXPECT_EQ(ConstrainWorkflowToUserIntent(goal, hint),
              AgentWorkflowKind::kResearch);
  }
  EXPECT_EQ(ConstrainWorkflowToUserIntent("整理收藏夹；不要下载或购买。",
                                          AgentWorkflowKind::kBrowserSteward),
            AgentWorkflowKind::kBrowserSteward);
  EXPECT_EQ(ConstrainWorkflowToUserIntent(
                "读取页面并核对官方下载地址；不要整理书签。",
                AgentWorkflowKind::kSafeDownload),
            AgentWorkflowKind::kSafeDownload);
  EXPECT_EQ(ConstrainWorkflowToUserIntent(
                "读取页面并帮我买下这件商品；不要整理书签。",
                AgentWorkflowKind::kShopping),
            AgentWorkflowKind::kShopping);
}

TEST(AegisAgentPlannerTest, PageEvidenceRequirementKeepsNegationAndReminders) {
  for (std::string_view goal :
       {"总结当前页", "讀取目前網頁", "不要忘记总结页面内容",
        "Read https://research.example/ and summarize it"}) {
    EXPECT_TRUE(AgentGoalRequiresPageEvidence(goal)) << goal;
  }
  for (std::string_view goal :
       {"只统计标签页，不要读取页面内容。", "整理收藏夹；不要总结网页。",
        "List tabs. Do not summarize page content."}) {
    EXPECT_FALSE(AgentGoalRequiresPageEvidence(goal)) << goal;
  }
}

TEST(AegisAgentPlannerTest, BrowserOwnsScopeAndModelChoosesOnlySteps) {
  AgentToolRegistry registry;
  std::string error;
  std::optional<AgentTaskPlan> plan = ParseAndValidateTaskPlan(
      ValidPlanEvent(), MaximumScope(), registry, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_TRUE(plan->scope.AllowsOrigin(GURL("https://research.example/a")));
  EXPECT_TRUE(plan->scope.AllowsOrigin(GURL("https://docs.example/a")));
  EXPECT_TRUE(plan->scope.AllowsTab(17));
  EXPECT_EQ(plan->scope.allowed_tools.size(), 1u);
  EXPECT_TRUE(plan->scope.allowed_tools.contains("page.observe"));
  EXPECT_EQ(plan->scope.allowed_data_classes.size(), 1u);
  EXPECT_TRUE(
      plan->scope.allowed_data_classes.contains(AgentDataClass::kPublicPage));
  EXPECT_EQ(plan->scope.budgets.max_tool_calls,
            MaximumScope().budgets.max_tool_calls);
  ASSERT_EQ(plan->steps.size(), 1u);
  EXPECT_EQ(plan->steps[0].risk, AgentRiskLevel::kR0ReadOnly);
}

TEST(AegisAgentPlannerTest, RejectsModelAuthorshipOfBrowserScope) {
  AgentToolRegistry registry;
  std::string error;

  AgentModelEvent expanded = ValidPlanEvent();
  base::ListValue origins;
  origins.Append("https://evil.example/");
  expanded.arguments.Set("origins", std::move(origins));
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(expanded, MaximumScope(), registry, &error));
  EXPECT_EQ(error, "tool argument contains an unknown field");

  AgentModelEvent injected = ValidPlanEvent();
  injected.arguments.Set("ignore_browser_policy", true);
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(injected, MaximumScope(), registry, &error));
  EXPECT_EQ(error, "tool argument contains an unknown field");
}

TEST(AegisAgentPlannerTest, RejectsModelDeclaredRiskOrUnapprovedStep) {
  AgentToolRegistry registry;
  std::string error;

  AgentModelEvent declared_risk = ValidPlanEvent();
  declared_risk.arguments.FindList("steps")->front().GetDict().Set("risk",
                                                                   "read_only");
  EXPECT_FALSE(ParseAndValidateTaskPlan(declared_risk, MaximumScope(), registry,
                                        &error));

  AgentModelEvent unapproved = ValidPlanEvent();
  unapproved.arguments.FindList("steps")->front().GetDict().Set(
      "tool", "bookmark.apply");
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(unapproved, MaximumScope(), registry, &error));
  EXPECT_EQ(error, "task plan step is duplicated or outside scope");
}

TEST(AegisAgentPlannerTest,
     BookmarkApplyKeepsBrowserOwnedUndoOutsideForwardSteps) {
  AgentToolRegistry registry;
  AgentTaskScope scope = MaximumScope();
  scope.allowed_origins.clear();
  scope.allowed_tab_ids.clear();
  scope.allowed_tools = {"bookmark.plan", "bookmark.apply", "bookmark.undo"};
  scope.allowed_data_classes = {AgentDataClass::kBookmarks};
  ASSERT_TRUE(scope.IsValid());

  AgentModelEvent event;
  event.type = AgentModelEventType::kToolCall;
  event.tool_call_id = "bookmark-plan";
  event.tool_name = "agent.submit_plan";
  event.arguments.Set("schema_version", kAgentSchemaVersion);
  event.arguments.Set("summary", "Preview and apply bookmark organization");
  base::ListValue steps;
  auto add_step = [&steps](std::string_view id, std::string_view title,
                           std::string_view tool) {
    base::DictValue step;
    step.Set("id", id);
    step.Set("title", title);
    step.Set("tool", tool);
    steps.Append(std::move(step));
  };
  add_step("preview", "Preview bookmark changes", "bookmark.plan");
  add_step("apply", "Apply approved bookmark changes", "bookmark.apply");
  event.arguments.Set("steps", std::move(steps));

  std::string error;
  const std::optional<AgentTaskPlan> plan =
      ParseAndValidateTaskPlan(event, scope, registry, &error);
  ASSERT_TRUE(plan) << error;
  ASSERT_EQ(plan->steps.size(), 2u);
  EXPECT_EQ(plan->steps.back().tool_name, "bookmark.apply");
  EXPECT_TRUE(plan->scope.AllowsTool("bookmark.undo"));
  EXPECT_TRUE(plan->scope.IsNoBroaderThan(scope));
}

TEST(AegisAgentPlannerTest, PreopenedPagePlanMustObserveBeforeActing) {
  AgentToolRegistry registry;
  std::string error;
  AgentModelEvent navigation_first = ValidPlanEvent();
  navigation_first.arguments.FindList("steps")->front().GetDict().Set(
      "tool", "page.navigate");

  EXPECT_FALSE(ParseAndValidateTaskPlan(navigation_first, MaximumScope(),
                                        registry, &error));
  EXPECT_EQ(error,
            "page-bound task plan must start with page.observe because the "
            "browser already opened the entry page");
}

TEST(AegisAgentPlannerTest,
     SinglePreopenedOriginMustBeExtractedBeforeFollowupNavigation) {
  AgentToolRegistry registry;
  std::string error;
  AgentTaskScope scope = MaximumScope();
  scope.allowed_origins = {
      url::Origin::Create(GURL("https://research.example/"))};
  scope.allowed_tools.insert("page.extract");

  AgentModelEvent premature_navigation = ValidPlanEvent();
  base::DictValue navigate;
  navigate.Set("id", "navigate-again");
  navigate.Set("title", "Navigate to the already opened entry page");
  navigate.Set("tool", "page.navigate");
  premature_navigation.arguments.FindList("steps")->Append(std::move(navigate));
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(premature_navigation, scope, registry, &error));
  EXPECT_EQ(error, "single preopened entry page must be extracted before any "
                   "follow-up navigation");

  AgentModelEvent evidence_first = ValidPlanEvent();
  base::DictValue extract;
  extract.Set("id", "extract-entry");
  extract.Set("title", "Extract links from the entry page");
  extract.Set("tool", "page.extract");
  evidence_first.arguments.FindList("steps")->Append(std::move(extract));
  base::DictValue followup;
  followup.Set("id", "navigate-followup");
  followup.Set("title", "Open one extracted follow-up page");
  followup.Set("tool", "page.navigate");
  evidence_first.arguments.FindList("steps")->Append(std::move(followup));
  EXPECT_TRUE(ParseAndValidateTaskPlan(evidence_first, scope, registry, &error))
      << error;
}

TEST(AegisAgentPlannerTest,
     ExplicitDownloadCancellationUsesCheckedNativeSequence) {
  AgentToolRegistry registry;
  auto scope = MaximumScope();
  scope.allowed_tools = {"page.observe", "download.find_official",
                         "download.start", "download.cancel"};
  scope.allowed_data_classes.insert(AgentDataClass::kDownloads);
  for (const auto *goal :
       {"开始页面中的慢速测试下载后取消。", "開始頁面中的慢速測試下載後取消。",
        "Start the download on this page, then cancel it."}) {
    auto event = BuildBrowserDownloadCancellationPlan(goal, scope, registry);
    ASSERT_TRUE(event) << goal;
    std::string error;
    auto plan = ParseAndValidateTaskPlan(*event, scope, registry, &error);
    ASSERT_TRUE(plan) << error;
    ASSERT_EQ(plan->steps.size(), 4u);
    EXPECT_EQ(plan->steps[0].tool_name, "page.observe");
    EXPECT_EQ(plan->steps[1].tool_name, "download.find_official");
    EXPECT_EQ(plan->steps[2].tool_name, "download.start");
    EXPECT_EQ(plan->steps[2].risk, AgentRiskLevel::kR2ExternalSideEffect);
    EXPECT_EQ(plan->steps[3].tool_name, "download.cancel");
  }
}

TEST(AegisAgentPlannerTest,
     DownloadCancellationTemplateNeverExpandsScopeOrIntent) {
  AgentToolRegistry registry;
  auto scope = MaximumScope();
  scope.allowed_tools = {"page.observe", "download.find_official",
                         "download.start", "download.cancel"};
  scope.allowed_data_classes.insert(AgentDataClass::kDownloads);
  for (const auto *goal :
       {"解释开始页面中的慢速测试下载后取消。",
        "不要开始页面中的慢速测试下载后取消。", "下载当前文件但不要取消。",
        "下载当前文件，然后取消订阅。"}) {
    EXPECT_FALSE(BuildBrowserDownloadCancellationPlan(goal, scope, registry))
        << goal;
  }
  const std::string goal = "开始页面中的慢速测试下载后取消。";
  scope.allowed_tools.erase("download.start");
  EXPECT_FALSE(BuildBrowserDownloadCancellationPlan(goal, scope, registry));
  scope.allowed_tools.insert("download.start");
  scope.allowed_tab_ids.clear();
  EXPECT_FALSE(BuildBrowserDownloadCancellationPlan(goal, scope, registry));
}

TEST(AegisAgentPlannerTest, BrowserResultDependenciesAreOrdered) {
  AgentToolRegistry registry;
  std::string error;
  AgentTaskScope bookmarks = MaximumScope();
  bookmarks.allowed_origins.clear();
  bookmarks.allowed_tab_ids.clear();
  bookmarks.allowed_tools = {"bookmark.list", "bookmark.check_urls"};
  bookmarks.allowed_data_classes = {AgentDataClass::kBookmarks};
  AgentModelEvent missing_bookmark_list = ValidPlanEvent();
  missing_bookmark_list.arguments.FindList("steps")->front().GetDict().Set(
      "tool", "bookmark.check_urls");
  EXPECT_FALSE(ParseAndValidateTaskPlan(missing_bookmark_list, bookmarks,
                                        registry, &error));
  EXPECT_EQ(error,
            "task plan uses a browser result before the step that creates it");

  AgentTaskScope downloads = MaximumScope();
  downloads.allowed_tools = {"page.observe", "download.find_official",
                             "download.start", "download.verify"};
  downloads.allowed_data_classes.insert(AgentDataClass::kDownloads);
  AgentModelEvent premature_verify = ValidPlanEvent();
  base::DictValue verify;
  verify.Set("id", "verify-before-download");
  verify.Set("title", "Verify the download");
  verify.Set("tool", "download.verify");
  premature_verify.arguments.FindList("steps")->Append(std::move(verify));
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(premature_verify, downloads, registry, &error));
  EXPECT_EQ(error, "download.verify requires an earlier download.start step. "
                   "page.click cannot replace either native download step.");
  premature_verify.arguments.FindList("steps")->back().GetDict().Set(
      "tool", "download.start");
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(premature_verify, downloads, registry, &error));
  EXPECT_EQ(error,
            "download.start requires an earlier download.find_official step. "
            "page.click cannot replace either native download step.");
}

TEST(AegisAgentPlannerTest, ShoppingPlanMustEndInOneUserTakeover) {
  AgentTaskScope shopping_scope = MaximumScope();
  shopping_scope.allowed_tools.insert("shopping.prepare_checkout");
  shopping_scope.allowed_data_classes.insert(AgentDataClass::kFormData);
  AgentToolRegistry registry;
  std::string error;

  AgentModelEvent omitted = ValidPlanEvent();
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(omitted, shopping_scope, registry, &error));
  EXPECT_EQ(error,
            "shopping plan must end with one browser-enforced user takeover");

  AgentModelEvent valid = ValidPlanEvent();
  base::DictValue checkout;
  checkout.Set("id", "checkout-takeover");
  checkout.Set("title", "Hand the final purchase to the user");
  checkout.Set("tool", "shopping.prepare_checkout");
  valid.arguments.FindList("steps")->Append(std::move(checkout));
  ASSERT_TRUE(ParseAndValidateTaskPlan(valid, shopping_scope, registry, &error))
      << error;

  AgentModelEvent duplicate = ValidPlanEvent();
  for (std::string_view id : {"checkout-one", "checkout-two"}) {
    base::DictValue step;
    step.Set("id", id);
    step.Set("title", "Hand the final purchase to the user");
    step.Set("tool", "shopping.prepare_checkout");
    duplicate.arguments.FindList("steps")->Append(std::move(step));
  }
  EXPECT_FALSE(
      ParseAndValidateTaskPlan(duplicate, shopping_scope, registry, &error));
  EXPECT_EQ(error,
            "shopping plan must end with one browser-enforced user takeover");
}

TEST(AegisAgentPlannerTest, ContractMarksExternalContentUntrusted) {
  const std::string contract = BuildAgentPlannerSystemContract();
  EXPECT_TRUE(contract.contains("untrusted"));
  EXPECT_TRUE(contract.contains("user takeover"));
  EXPECT_TRUE(contract.contains("agent.submit_plan"));
  EXPECT_TRUE(contract.contains("browser owns origins"));
  EXPECT_TRUE(contract.contains("same primary language"));
  EXPECT_TRUE(contract.contains("returned to you automatically"));
  EXPECT_TRUE(contract.contains("Honor negative constraints"));
  EXPECT_TRUE(contract.contains("Never put interval_minutes"));

  const AgentModelToolDefinition tool = BuildSubmitPlanToolDefinition();
  const base::DictValue *properties = tool.input_schema.FindDict("properties");
  ASSERT_TRUE(properties);
  EXPECT_FALSE(properties->contains("origins"));
  EXPECT_FALSE(properties->contains("tools"));
  EXPECT_FALSE(properties->contains("budgets"));

  AgentToolRegistry registry;
  const std::optional<std::string> prompt = BuildAgentPlanningPrompt(
      "Compare approved sources", MaximumScope(), registry);
  ASSERT_TRUE(prompt);
  const std::optional<base::Value> parsed =
      base::JSONReader::Read(*prompt, base::JSON_PARSE_RFC);
  ASSERT_TRUE(parsed && parsed->is_dict());
  ASSERT_TRUE(parsed->GetDict().FindString("user_goal"));
  EXPECT_EQ(*parsed->GetDict().FindString("user_goal"),
            "Compare approved sources");
  EXPECT_EQ(parsed->GetDict()
                .FindDict("model_destination")
                ->FindBool("credential_in_browser"),
            true);
  EXPECT_EQ(parsed->GetDict().FindBool("entry_page_already_open"), true);
  EXPECT_EQ(*parsed->GetDict().FindString("required_first_tool"),
            "page.observe");
  EXPECT_EQ(parsed->GetDict().FindBool("entry_navigation_complete"), true);
  EXPECT_EQ(parsed->GetDict().FindList("plan_dependency_rules")->size(), 1u);
  const base::ListValue *catalog = parsed->GetDict().FindList("tool_catalog");
  ASSERT_TRUE(catalog);
  ASSERT_EQ(catalog->size(), 3u);
  EXPECT_TRUE((*catalog)[0].GetDict().FindString("purpose"));
}

TEST(AegisAgentPlannerTest,
     DependenciesFollowAuthorizedToolsWithoutExpandingScope) {
  AgentToolRegistry registry;
  auto scope = MaximumScope();
  scope.allowed_tools.insert("bookmark.list");
  scope.allowed_tools.insert("bookmark.check_urls");
  scope.allowed_tools.insert("download.start");
  scope.allowed_tools.insert("download.verify");
  scope.allowed_tools.insert("monitor.create");
  auto prompt = BuildAgentPlanningPrompt("核对授权来源", scope, registry);
  ASSERT_TRUE(prompt);
  auto parsed = base::JSONReader::Read(*prompt, base::JSON_PARSE_RFC);
  ASSERT_TRUE(parsed);
  const auto *rules = parsed->GetDict().FindList("plan_dependency_rules");
  ASSERT_TRUE(rules);
  EXPECT_EQ(rules->size(), 5u);
  EXPECT_NE(prompt->find("bookmark.check_urls requires"), std::string::npos);
  EXPECT_EQ(prompt->find("bookmark.apply requires"), std::string::npos);
  EXPECT_NE(prompt->find("download.start requires"), std::string::npos);
  EXPECT_NE(prompt->find("download pause, resume"), std::string::npos);
  EXPECT_NE(prompt->find("one-shot tasks must not"), std::string::npos);
  EXPECT_EQ(parsed->GetDict().FindList("maximum_tools")->size(),
            scope.allowed_tools.size());
}

TEST(AegisAgentPlannerTest,
     BrowserReadOnlyRecoveryKeepsResearchInsideApprovedScope) {
  AgentToolRegistry registry;
  AgentTaskScope scope = MaximumScope();
  scope.allowed_tools.insert("page.extract");
  const std::optional<AgentModelEvent> recovery =
      BuildBrowserReadOnlyRecoveryPlan("帮我总结当前页面", scope, registry);
  ASSERT_TRUE(recovery);

  std::string error;
  const std::optional<AgentTaskPlan> plan =
      ParseAndValidateTaskPlan(*recovery, scope, registry, &error);
  ASSERT_TRUE(plan) << error;
  ASSERT_EQ(plan->steps.size(), 2u);
  EXPECT_EQ(plan->steps[0].tool_name, "page.observe");
  EXPECT_EQ(plan->steps[1].tool_name, "page.extract");
  EXPECT_TRUE(plan->scope.IsNoBroaderThan(scope));
  for (const AgentPlanStep &step : plan->steps) {
    EXPECT_EQ(step.risk, AgentRiskLevel::kR0ReadOnly);
  }
}

TEST(AegisAgentPlannerTest,
     BrowserReadOnlyRecoveryRejectsShoppingAndSideEffectOnlyScopes) {
  AgentToolRegistry registry;
  AgentTaskScope shopping = MaximumScope();
  shopping.allowed_tools.insert("shopping.prepare_checkout");
  shopping.allowed_data_classes.insert(AgentDataClass::kFormData);
  EXPECT_FALSE(
      BuildBrowserReadOnlyRecoveryPlan("帮我买下这个商品", shopping, registry));

  AgentTaskScope writes = MaximumScope();
  writes.allowed_origins.clear();
  writes.allowed_tab_ids.clear();
  writes.allowed_tools = {"bookmark.apply"};
  writes.allowed_data_classes = {AgentDataClass::kBookmarks};
  EXPECT_TRUE(writes.IsValid());
  EXPECT_FALSE(
      BuildBrowserReadOnlyRecoveryPlan("应用收藏夹方案", writes, registry));
}

TEST(AegisAgentPlannerTest, BrowserReadOnlyRecoveryCoversCompoundBookmarkGoal) {
  AgentToolRegistry registry;
  AgentTaskScope scope = MaximumScope();
  scope.allowed_origins.clear();
  scope.allowed_tab_ids.clear();
  scope.allowed_tools = {"bookmark.list", "bookmark.check_urls",
                         "bookmark.plan", "bookmark.apply"};
  scope.allowed_data_classes = {AgentDataClass::kBookmarks};
  ASSERT_TRUE(scope.IsValid());

  for (std::string_view goal : {
           std::string_view("检查收藏夹失效 URL，并给出分类预览，不要修改"),
           std::string_view("檢查書籤死鏈並提供分類預覽，不要更改"),
       }) {
    const std::optional<AgentModelEvent> recovery =
        BuildBrowserReadOnlyRecoveryPlan(goal, scope, registry);
    ASSERT_TRUE(recovery);
    std::string error;
    const std::optional<AgentTaskPlan> plan =
        ParseAndValidateTaskPlan(*recovery, scope, registry, &error);
    ASSERT_TRUE(plan) << error;
    ASSERT_EQ(plan->steps.size(), 3u);
    EXPECT_EQ(plan->steps[0].tool_name, "bookmark.list");
    EXPECT_EQ(plan->steps[1].tool_name, "bookmark.check_urls");
    EXPECT_EQ(plan->steps[2].tool_name, "bookmark.plan");
    EXPECT_TRUE(ValidateTaskPlanForGoal(plan.value(), goal, &error)) << error;
  }
}

TEST(AegisAgentPlannerTest, BookmarkGoalCoverageIsBrowserValidated) {
  AgentTaskPlan plan;
  auto add_step = [&](std::string_view tool_name) {
    plan.steps.push_back(
        {.step_id = "step-" + std::to_string(plan.steps.size() + 1),
         .title = std::string(tool_name),
         .tool_name = std::string(tool_name),
         .risk = tool_name == "bookmark.apply"
                     ? AgentRiskLevel::kR2ExternalSideEffect
                     : AgentRiskLevel::kR0ReadOnly});
  };
  std::string error;

  add_step("bookmark.list");
  EXPECT_FALSE(ValidateTaskPlanForGoal(
      plan, "检查收藏夹失效 URL，并给出分类预览，不要修改", &error));
  EXPECT_EQ(
      error,
      "bookmark URL-check goal omitted required bookmark.check_urls step");

  add_step("bookmark.check_urls");
  EXPECT_FALSE(ValidateTaskPlanForGoal(
      plan, "检查收藏夹失效 URL，并给出分类预览，不要修改", &error));
  EXPECT_EQ(error,
            "bookmark organization goal omitted required bookmark.plan step");

  add_step("bookmark.plan");
  EXPECT_TRUE(ValidateTaskPlanForGoal(
      plan, "检查收藏夹失效 URL，并给出分类预览，不要修改", &error))
      << error;

  add_step("bookmark.apply");
  EXPECT_FALSE(ValidateTaskPlanForGoal(
      plan, "检查收藏夹失效 URL，并给出分类预览，不要修改", &error));
  EXPECT_EQ(error, "read-only bookmark goal must not include bookmark.apply");

  EXPECT_FALSE(ValidateTaskPlanForGoal(plan, "总结当前页面", &error));
}

TEST(AegisAgentPlannerTest, PageReadingGoalRejectsMetadataOnlyPlan) {
  AgentTaskPlan plan;
  plan.steps.push_back({.step_id = "list",
                        .title = "读取标签页",
                        .tool_name = "tab.list",
                        .risk = AgentRiskLevel::kR0ReadOnly});
  for (std::string_view goal : {
           "打开 http://127.0.0.1:52861/slow 并总结页面内容。只允许读取这个"
           "本地公开测试来源；不要下载、整理书签、提交或购买。",
           "總結目前網頁內容；不要下載或整理書籤。",
           "Summarize the page content. Do not organize bookmarks.",
       }) {
    SCOPED_TRACE(goal);
    std::string error;
    EXPECT_FALSE(ValidateTaskPlanForGoal(plan, goal, &error));
    EXPECT_EQ(error, "page-reading goal omitted required page.observe step");
  }
  std::string error;
  EXPECT_TRUE(
      ValidateTaskPlanForGoal(plan, "只统计标签页，不要读取页面内容。", &error))
      << error;
}

TEST(AegisAgentPlannerTest, PageReadingRecoveryCannotUseOnlyTabMetadata) {
  AgentTaskScope scope = MaximumScope();
  scope.allowed_tools = {"tab.list"};
  scope.allowed_data_classes = {AgentDataClass::kBrowserMetadata};
  AgentToolRegistry registry;
  EXPECT_FALSE(BuildBrowserReadOnlyRecoveryPlan(
      "总结页面内容，不要下载、整理书签或购买。", scope, registry));
  EXPECT_TRUE(BuildBrowserReadOnlyRecoveryPlan(
      "只统计标签页，不要读取页面内容。", scope, registry));
}

TEST(AegisAgentPlannerTest, NegatedBookmarkMentionKeepsApprovedMonitorPlan) {
  AgentTaskScope scope = MaximumScope();
  scope.allowed_tools.insert("monitor.create");
  AgentModelEvent event = ValidPlanEvent();
  base::DictValue monitor;
  monitor.Set("id", "step-2");
  monitor.Set("title", "创建已请求的监控");
  monitor.Set("tool", "monitor.create");
  event.arguments.FindList("steps")->Append(std::move(monitor));
  AgentToolRegistry registry;
  std::string error;
  auto plan = ParseAndValidateTaskPlan(event, scope, registry, &error);
  ASSERT_TRUE(plan) << error;
  ASSERT_TRUE(ValidateTaskPlanForMode(*plan, AgentMode::kAutomate, &error));
  for (std::string_view goal : {
           "每15分钟检查 http://127.0.0.1:52861/article 网页内容，"
           "只在有重要更新时总结变化并提醒。"
           "不要下载、整理书签、提交或购买；"
           "仅允许读取这个本地公开测试来源并创建上述监控。",
           "每15分鐘檢查公開網頁，不要下載、整理書籤、提交或購買。",
           "Monitor the public page every 15 minutes; do not download, "
           "organize bookmarks, submit, or purchase anything.",
           "监控网页变化，不整理书签。",
       }) {
    EXPECT_TRUE(ValidateTaskPlanForGoal(*plan, goal, &error))
        << goal << ": " << error;
  }
  EXPECT_FALSE(plan->scope.AllowsTool("bookmark.list"));
  EXPECT_FALSE(plan->scope.AllowsTool("bookmark.apply"));
  EXPECT_FALSE(plan->scope.AllowsDataClass(AgentDataClass::kBookmarks));
}

TEST(AegisAgentPlannerTest, AffirmativeBookmarkRequestSurvivesOtherNegation) {
  AgentTaskPlan plan;
  plan.steps.push_back({.step_id = "step-1",
                        .title = "读取页面",
                        .tool_name = "page.observe",
                        .risk = AgentRiskLevel::kR0ReadOnly});
  std::string error;
  for (std::string_view goal : {
           "不要下载，但请整理书签。",
           "不要购买。检查书签失效 URL。",
           "Do not download; organize bookmarks.",
           "Do not download, but list my bookmarks.",
           "不要忘记整理书签。",
       }) {
    EXPECT_FALSE(ValidateTaskPlanForGoal(plan, goal, &error)) << goal;
    EXPECT_EQ(error, "bookmark task plan omitted required bookmark.list step");
  }
}

TEST(AegisAgentPlannerTest, NegatedBookmarkSubtasksDoNotBecomeRequirements) {
  AgentTaskPlan plan;
  plan.steps.push_back({.step_id = "step-1",
                        .title = "列出书签",
                        .tool_name = "bookmark.list",
                        .risk = AgentRiskLevel::kR0ReadOnly});
  std::string error;
  for (std::string_view goal : {
           "列出书签，不要检查失效 URL，也不要整理分类。",
           "List bookmarks; do not check broken URLs or organize categories.",
       }) {
    EXPECT_TRUE(ValidateTaskPlanForGoal(plan, goal, &error))
        << goal << ": " << error;
  }
}

TEST(AegisAgentPlannerTest, ReadOnlyBookmarkConstraintStillRejectsWrites) {
  AgentTaskPlan plan;
  for (std::string_view tool : {"bookmark.list", "bookmark.check_urls",
                                "bookmark.plan", "bookmark.apply"}) {
    plan.steps.push_back({.step_id = std::string(tool),
                          .title = std::string(tool),
                          .tool_name = std::string(tool),
                          .risk = tool == "bookmark.apply"
                                      ? AgentRiskLevel::kR2ExternalSideEffect
                                      : AgentRiskLevel::kR0ReadOnly});
  }
  std::string error;
  for (std::string_view goal : {
           "不要修改书签，只给出分类预览。",
           "检查收藏夹失效 URL，并给出分类预览，不要修改。",
           "Do not change bookmarks; provide a read-only category preview.",
       }) {
    EXPECT_FALSE(ValidateTaskPlanForGoal(plan, goal, &error)) << goal;
    EXPECT_EQ(error, "read-only bookmark goal must not include bookmark.apply");
  }
}

TEST(AegisAgentPlannerTest, TaskModeOwnsScheduledMonitorLifecycle) {
  AgentTaskPlan one_shot;
  one_shot.steps.push_back({.step_id = "step-1",
                            .title = "Read page",
                            .tool_name = "page.observe",
                            .risk = AgentRiskLevel::kR0ReadOnly});
  std::string error;
  EXPECT_TRUE(ValidateTaskPlanForMode(one_shot, AgentMode::kAct, &error))
      << error;
  EXPECT_FALSE(ValidateTaskPlanForMode(one_shot, AgentMode::kAutomate, &error));
  EXPECT_EQ(error, "scheduled automation plan must end with exactly one "
                   "monitor.create step");

  AgentTaskPlan scheduled = one_shot;
  scheduled.steps.push_back({.step_id = "step-2",
                             .title = "Create monitor",
                             .tool_name = "monitor.create",
                             .risk = AgentRiskLevel::kR1Reversible});
  EXPECT_TRUE(ValidateTaskPlanForMode(scheduled, AgentMode::kAutomate, &error))
      << error;
  EXPECT_FALSE(ValidateTaskPlanForMode(scheduled, AgentMode::kAct, &error));
  EXPECT_EQ(error, "monitor.create requires a scheduled automation task");

  std::swap(scheduled.steps[0], scheduled.steps[1]);
  EXPECT_FALSE(
      ValidateTaskPlanForMode(scheduled, AgentMode::kAutomate, &error));
}

TEST(AegisAgentPlannerTest, CurrentPageClickRoutingKeepsNegativeConstraints) {
  for (const auto *goal : {"点击当前页面的按钮", "點擊當前頁面的按鈕",
                           "Click the button on the current page"}) {
    EXPECT_EQ(ConstrainWorkflowToUserIntent(goal, AgentWorkflowKind::kResearch),
              AgentWorkflowKind::kPageInteraction)
        << goal;
    AgentGoalRoute route;
    route.workflow = AgentWorkflowKind::kPageInteraction;
    route.entry_kind = AgentGoalEntryKind::kWebSearch;
    route.target = "不得继承模型提出的其他入口";
    const auto constrained = ConstrainGoalRouteToUserIntent(goal, route);
    EXPECT_EQ(constrained.entry_kind, AgentGoalEntryKind::kBrowserOnly);
    EXPECT_TRUE(constrained.target.empty());
  }
  for (const auto *goal :
       {"不要点击当前页面的按钮，只总结页面", "解释如何点击当前页面的按钮",
        "Do not click the button on the current page"}) {
    EXPECT_EQ(ConstrainWorkflowToUserIntent(
                  goal, AgentWorkflowKind::kPageInteraction),
              AgentWorkflowKind::kResearch)
        << goal;
  }
}

TEST(AegisAgentPlannerTest, CurrentPagePlanRetainsScopeAndApprovalRisk) {
  const auto base = MaximumScope();
  auto scope = BuildAgentWorkflowScope(AgentWorkflowKind::kPageInteraction,
                                       base.allowed_origins, {17},
                                       base.model_destination);
  ASSERT_TRUE(scope);
  auto event = ValidPlanEvent();
  event.arguments.FindList("steps")->Append(base::DictValue()
                                                .Set("id", "click")
                                                .Set("title", "点击按钮")
                                                .Set("tool", "page.click"));
  event.arguments.FindList("steps")->Append(base::DictValue()
                                                .Set("id", "verify")
                                                .Set("title", "回读结果")
                                                .Set("tool", "page.extract"));
  AgentToolRegistry registry;
  std::string error;
  const auto plan = ParseAndValidateTaskPlan(event, *scope, registry, &error);
  ASSERT_TRUE(plan) << error;
  EXPECT_TRUE(plan->scope.restrict_to_current_page);
  EXPECT_EQ(plan->steps[1].risk, AgentRiskLevel::kR2ExternalSideEffect);
  constexpr std::string_view goal = "点击当前页面的按钮并核对结果";
  EXPECT_TRUE(ValidateTaskPlanForGoal(*plan, goal, &error)) << error;
  auto incomplete = *plan;
  incomplete.steps.pop_back();
  EXPECT_FALSE(ValidateTaskPlanForGoal(incomplete, goal, &error));
  incomplete.steps.pop_back();
  EXPECT_FALSE(ValidateTaskPlanForGoal(incomplete, goal, &error));
  auto unverified_last_click = *plan;
  unverified_last_click.steps.push_back(plan->steps[1]);
  EXPECT_FALSE(ValidateTaskPlanForGoal(unverified_last_click, goal, &error));
  auto escaped = plan->scope;
  escaped.restrict_to_current_page = false;
  EXPECT_FALSE(escaped.IsNoBroaderThan(*scope));
}

TEST(AegisAgentPlannerTest, InstallerSourceGoalRequiresNativeCandidateCheck) {
  for (const char *goal :
       {"从当前官方发布页找适合 macOS arm64 的安装包来源，只给链接，不要下载。",
        "從目前官方發佈頁找 macOS arm64 安裝包來源，只給連結，不要下載。",
        "Find the official installer source on this page; do not download."}) {
    SCOPED_TRACE(goal);
    AgentTaskPlan plan;
    plan.steps.push_back(
        {.step_id = "observe", .title = "读取", .tool_name = "page.observe"});
    std::string error;
    EXPECT_FALSE(ValidateTaskPlanForGoal(plan, goal, &error));
    EXPECT_TRUE(error.contains("download.find_official"));
    plan.steps.push_back({.step_id = "source",
                          .title = "核对候选",
                          .tool_name = "download.find_official"});
    EXPECT_TRUE(ValidateTaskPlanForGoal(plan, goal, &error)) << error;
  }
}

} // namespace
} // namespace aegis::agent
