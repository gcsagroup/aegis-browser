// Copyright 2026 GCSA

#include "chrome/browser/ui/webui/aegis/aegis_ui_handler.h"

#include <string>
#include <utility>
#include <vector>

#include "base/test/test_future.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/aegis/agent/aegis_browser_tools.h"
#include "chrome/browser/aegis/metalink_download_verifier.h"
#include "chrome/browser/tab_list/tab_list_interface.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/webui/aegis/aegis_ui.h"
#include "chrome/common/aegis/pref_names.h"
#include "chrome/test/base/browser_with_test_window_test.h"
#include "chrome/test/base/test_browser_window.h"
#include "chrome/test/base/testing_profile_manager.h"
#include "components/prefs/pref_service.h"
#include "components/tab_groups/tab_group_color.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/test_web_ui.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis {
namespace {

class AegisUIHandlerTest : public BrowserWithTestWindowTest {};

// 工作区恢复需要可编辑的标签栏；基础测试窗口默认禁止编辑。
class WorkspaceTestWindow : public TestBrowserWindow {
 public:
  bool IsTabStripEditable() const override { return true; }
};

class AegisWorkspaceHandlerTest
    : public AegisUIHandlerTest,
      public testing::WithParamInterface<tab_groups::TabGroupColorId> {
 protected:
  std::unique_ptr<BrowserWindow> CreateBrowserWindow() override {
    return std::make_unique<WorkspaceTestWindow>();
  }
};

class TestAegisUIHandler : public AegisUIHandler {
 public:
  using content::WebUIMessageHandler::set_web_ui;
};

TEST_F(AegisUIHandlerTest, SelectsNearestHttpTabInSameWindow) {
  AddTab(browser(), GURL("https://left.example/"));
  AddTab(browser(), GURL("chrome://aegis/"));
  AddTab(browser(), GURL("https://right.example/"));
  TabStripModel* model = browser()->tab_strip_model();
  content::WebContents* settings = model->GetWebContentsAt(1);

  EXPECT_EQ(
      model->GetWebContentsAt(0),
      FindSummarySourceTabInList(TabListInterface::From(browser()), settings));

  NavigateAndCommit(model->GetWebContentsAt(0), GURL("about:blank"));
  EXPECT_EQ(
      model->GetWebContentsAt(2),
      FindSummarySourceTabInList(TabListInterface::From(browser()), settings));

  NavigateAndCommit(model->GetWebContentsAt(2), GURL("about:blank"));
  EXPECT_EQ(nullptr, FindSummarySourceTabInList(
                         TabListInterface::From(browser()), settings));
}

TEST_F(AegisUIHandlerTest, RejectsTabFromAnotherWindowModel) {
  AddTab(browser(), GURL("https://source.example/"));
  auto foreign = content::WebContents::Create(
      content::WebContents::CreateParams(profile()));

  EXPECT_EQ(nullptr, FindSummarySourceTabInList(
                         TabListInterface::From(browser()), foreign.get()));
}

TEST_F(AegisUIHandlerTest, WindowRevisionIgnoresFocusButTracksContentChanges) {
  using namespace aegis::agent;
  AddTab(browser(), GURL("https://workspace.example/first"));
  TabListInterface* list = TabListInterface::From(browser());
  ASSERT_TRUE(list);
  AgentTaskScope scope;
  scope.allowed_tab_ids = {list->GetTab(0)->GetHandle().raw_value()};
  scope.allowed_tools = {"window.list"};
  scope.allowed_data_classes = {AgentDataClass::kBrowserMetadata};
  AgentTask task("window-focus", "核对窗口审批期间的结构", AgentMode::kAct,
                 scope);
  AegisBrowserTools tools(profile());
  auto read = [&]() {
    AgentToolCall call;
    call.action_id = "window-list";
    call.tool_name = "window.list";
    base::test::TestFuture<AgentToolResult> future;
    tools.Execute(&task, call, future.GetCallback());
    return future.Take();
  };
  auto before = read();
  ASSERT_TRUE(before.ok);
  ASSERT_TRUE(before.value.FindString("revision"));
  auto* test_window = static_cast<TestBrowserWindow*>(window());
  test_window->set_is_active(true);
  auto focused = read();
  ASSERT_TRUE(focused.ok);
  const auto* windows = focused.value.FindList("windows");
  ASSERT_TRUE(windows);
  ASSERT_EQ(windows->size(), 1u);
  EXPECT_EQ(windows->front().GetDict().FindBool("active"), true);
  EXPECT_EQ(*before.value.FindString("revision"),
            *focused.value.FindString("revision"));
  test_window->set_is_active(false);
  auto unfocused = read();
  ASSERT_TRUE(unfocused.ok);
  EXPECT_EQ(*before.value.FindString("revision"),
            *unfocused.value.FindString("revision"));
  // URL 或固定状态变化仍使旧审批版本失效。
  NavigateAndCommit(list->GetTab(0)->GetContents(),
                    GURL("https://workspace.example/changed"));
  auto navigated = read();
  ASSERT_TRUE(navigated.ok);
  EXPECT_NE(*before.value.FindString("revision"),
            *navigated.value.FindString("revision"));
  browser()->tab_strip_model()->SetTabPinned(0, true);
  auto pinned = read();
  ASSERT_TRUE(pinned.ok);
  EXPECT_NE(*navigated.value.FindString("revision"),
            *pinned.value.FindString("revision"));
}

TEST_P(AegisWorkspaceHandlerTest, WorkspaceRoundTripUsesSharedTabInterface) {
  using namespace aegis::agent;
  AddTab(browser(), GURL("https://workspace.example/first"));
  AddTab(browser(), GURL("https://workspace.example/second"));
  TabListInterface* list = TabListInterface::From(browser());
  ASSERT_TRUE(list);
  tabs::TabInterface* first = list->GetTab(0);
  tabs::TabInterface* second = list->GetTab(1);
  const auto group =
      list->CreateTabGroup({first->GetHandle(), second->GetHandle()});
  ASSERT_TRUE(group);
  list->SetTabGroupVisualData(
      *group, tab_groups::TabGroupVisualData(u"研究集合", GetParam()));
  AgentTaskScope scope;
  scope.allowed_origins = {
      url::Origin::Create(GURL("https://workspace.example/"))};
  scope.allowed_tab_ids = {first->GetHandle().raw_value(),
                           second->GetHandle().raw_value()};
  scope.allowed_tools = {"tab.list", "workspace.save", "workspace.restore"};
  scope.allowed_data_classes = {AgentDataClass::kBrowserMetadata};
  scope.model_destination.provider = "aegis-local";
  scope.model_destination.model = "fixture";
  scope.budgets.max_tabs = 8;
  AgentTask task("workspace-round-trip", "保存并恢复研究集合", AgentMode::kAct,
                 scope);
  AegisBrowserTools tools(profile());
  ASSERT_TRUE(tools.CanHandle("workspace.save"));
  ASSERT_TRUE(tools.CanHandle("workspace.restore"));
  auto execute = [&](std::string name, base::DictValue arguments) {
    AgentToolCall call;
    call.action_id = name;
    call.tool_name = name;
    call.arguments = std::move(arguments);
    base::test::TestFuture<AgentToolResult> future;
    tools.Execute(&task, call, future.GetCallback());
    return future.Take();
  };
  auto listed = execute("tab.list", {});
  ASSERT_TRUE(listed.ok);
  auto saved =
      execute("workspace.save",
              base::DictValue()
                  .Set("name", "研究集合")
                  .Set("revision", *listed.value.FindString("revision")));
  ASSERT_TRUE(saved.ok) << saved.message;
  const std::string id = *saved.value.FindString("workspace_id");
  const std::string revision = *saved.value.FindString("workspace_revision");
  const auto* entry =
      profile()->GetPrefs()->GetDict(prefs::kAgentWorkspaces).FindDict(id);
  ASSERT_TRUE(entry);
  ASSERT_EQ(entry->FindList("tabs")->size(), 2u);
  EXPECT_EQ(
      *entry->FindList("tabs")->front().GetDict().FindString("group_title"),
      "研究集合");
  const auto stale =
      execute("workspace.restore", base::DictValue()
                                       .Set("workspace_id", id)
                                       .Set("workspace_revision", "stale"));
  EXPECT_FALSE(stale.ok);
  EXPECT_EQ(list->GetTabCount(), 2);
  auto restored =
      execute("workspace.restore", base::DictValue()
                                       .Set("workspace_id", id)
                                       .Set("workspace_revision", revision));
  ASSERT_TRUE(restored.ok) << restored.message;
  ASSERT_EQ(list->GetTabCount(), 4);
  const auto* restored_ids = restored.value.FindList("tab_ids");
  ASSERT_TRUE(restored_ids);
  ASSERT_EQ(restored_ids->size(), 2u);
  auto* restored_first = tabs::TabHandle((*restored_ids)[0].GetInt()).Get();
  auto* restored_second = tabs::TabHandle((*restored_ids)[1].GetInt()).Get();
  ASSERT_TRUE(restored_first && restored_second);
  ASSERT_TRUE(restored_first->GetGroup());
  EXPECT_EQ(restored_first->GetGroup(), restored_second->GetGroup());
  EXPECT_NE(restored_first->GetGroup(), group);
  auto visual = list->GetTabGroupVisualData(*restored_first->GetGroup());
  ASSERT_TRUE(visual);
  EXPECT_EQ(visual->title(), u"研究集合");
  EXPECT_EQ(visual->color(), GetParam());
  EXPECT_TRUE(
      task.owned_tab_ids().contains(restored_first->GetHandle().raw_value()));

  scope.allowed_origins = {url::Origin::Create(GURL("https://other.example/"))};
  AgentTask foreign_task("workspace-other-origin", "恢复另一个来源",
                         AgentMode::kAct, scope);
  AgentToolCall forbidden;
  forbidden.action_id = "restore-foreign";
  forbidden.tool_name = "workspace.restore";
  forbidden.arguments.Set("workspace_id", id);
  forbidden.arguments.Set("workspace_revision", revision);
  base::test::TestFuture<AgentToolResult> rejected;
  tools.Execute(&foreign_task, forbidden, rejected.GetCallback());
  EXPECT_FALSE(rejected.Take().ok);
  EXPECT_EQ(list->GetTabCount(), 4);
}

INSTANTIATE_TEST_SUITE_P(AllGroupColors,
                         AegisWorkspaceHandlerTest,
                         testing::Values(tab_groups::TabGroupColorId::kGrey,
                                         tab_groups::TabGroupColorId::kBlue,
                                         tab_groups::TabGroupColorId::kRed,
                                         tab_groups::TabGroupColorId::kYellow,
                                         tab_groups::TabGroupColorId::kGreen,
                                         tab_groups::TabGroupColorId::kPink,
                                         tab_groups::TabGroupColorId::kPurple,
                                         tab_groups::TabGroupColorId::kCyan,
                                         tab_groups::TabGroupColorId::kOrange));

TEST_F(AegisUIHandlerTest, WorkspaceOriginsStayWithinSelectedNativeTabs) {
  AddTab(browser(), GURL("https://docs.example/first"));
  auto* list = TabListInterface::From(browser());
  const int32_t selected = list->GetTab(0)->GetHandle().raw_value();
  AddTab(browser(), GURL("https://other.example/second"));
  AddTab(browser(), GURL("chrome://aegis/"));
  const auto one =
      agent::WorkspaceRestoreOrigins(profile(), browser(), selected, false);
  ASSERT_EQ(one.size(), 1u);
  EXPECT_EQ(one.front(), url::Origin::Create(GURL("https://docs.example/")));
  const auto window =
      agent::WorkspaceRestoreOrigins(profile(), browser(), selected, true);
  EXPECT_EQ(window.size(), 2u);
  EXPECT_TRUE(
      agent::WorkspaceRestoreOrigins(profile(), browser(), -1, false).empty());
  EXPECT_TRUE(
      agent::WorkspaceRestoreOrigins(profile()->GetPrimaryOTRProfile(true),
                                     browser(), selected, true)
          .empty());
}

TEST_F(AegisUIHandlerTest, InvalidMetalinkCannotReportTaskCreated) {
  base::test::TestFuture<bool, std::string> result;
  MetalinkParseResult invalid;
  StartVerifiedMetalinkDownload(profile(), std::move(invalid),
                                result.GetCallback());
  EXPECT_FALSE(result.Get<0>());
  EXPECT_FALSE(result.Get<1>().empty());
}

TEST_F(AegisUIHandlerTest, WebUIConfigAllowsOnlySupportedProfiles) {
  AegisUIConfig config;
  EXPECT_TRUE(config.IsWebUIEnabled(profile()));

  Profile* primary_otr =
      profile()->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_TRUE(primary_otr);
  EXPECT_TRUE(config.IsWebUIEnabled(primary_otr));

  Profile* auxiliary_otr = profile()->GetOffTheRecordProfile(
      Profile::OTRProfileID::CreateUniqueForTesting(),
      /*create_if_needed=*/true);
  ASSERT_TRUE(auxiliary_otr);
  EXPECT_FALSE(config.IsWebUIEnabled(auxiliary_otr));

  TestingProfile* guest = profile_manager()->CreateGuestProfile();
  ASSERT_TRUE(guest);
  EXPECT_FALSE(config.IsWebUIEnabled(guest));

#if !BUILDFLAG(IS_CHROMEOS) && !BUILDFLAG(IS_ANDROID)
  TestingProfile* system = profile_manager()->CreateSystemProfile();
  ASSERT_TRUE(system);
  EXPECT_FALSE(config.IsWebUIEnabled(system));
#endif
}

TEST_F(AegisUIHandlerTest, AdvancedDownloadsRejectUnsupportedProfiles) {
  Profile* auxiliary_otr = profile()->GetOffTheRecordProfile(
      Profile::OTRProfileID::CreateUniqueForTesting(),
      /*create_if_needed=*/true);
  TestingProfile* guest = profile_manager()->CreateGuestProfile();
  ASSERT_TRUE(auxiliary_otr);
  ASSERT_TRUE(guest);
  std::vector<Profile*> unsupported_profiles = {auxiliary_otr, guest};
#if !BUILDFLAG(IS_CHROMEOS) && !BUILDFLAG(IS_ANDROID)
  TestingProfile* system = profile_manager()->CreateSystemProfile();
  ASSERT_TRUE(system);
  unsupported_profiles.push_back(system);
#endif

  for (Profile* unsupported : unsupported_profiles) {
    auto contents = content::WebContents::Create(
        content::WebContents::CreateParams(unsupported));
    content::TestWebUI web_ui;
    web_ui.set_web_contents(contents.get());
    TestAegisUIHandler handler;
    handler.set_web_ui(&web_ui);
    handler.RegisterMessages();

    std::vector<std::pair<std::string, base::ListValue>> messages;
    base::ListValue parse_metalink;
    parse_metalink.Append("parse-metalink");
    parse_metalink.Append("<metalink/>");
    messages.emplace_back("parseMetalink", std::move(parse_metalink));
    base::ListValue start_metalink;
    start_metalink.Append("start-metalink");
    start_metalink.Append("request-id");
    messages.emplace_back("startMetalinkDownload", std::move(start_metalink));
#if BUILDFLAG(IS_MAC)
    base::ListValue parse_torrent;
    parse_torrent.Append("parse-torrent");
    parse_torrent.Append("AA==");
    messages.emplace_back("parseTorrent", std::move(parse_torrent));
    base::ListValue parse_magnet;
    parse_magnet.Append("parse-magnet");
    parse_magnet.Append("magnet:?xt=urn:btih:test");
    messages.emplace_back("parseMagnet", std::move(parse_magnet));
    base::ListValue start_torrent;
    start_torrent.Append("start-torrent");
    start_torrent.Append("request-id");
    start_torrent.Append(base::ListValue());
    start_torrent.Append(base::DictValue());
    start_torrent.Append(true);
    messages.emplace_back("startTorrent", std::move(start_torrent));
    base::ListValue torrent_status;
    torrent_status.Append("torrent-status");
    torrent_status.Append("regular-task-id");
    messages.emplace_back("getTorrentStatus", std::move(torrent_status));
    base::ListValue control_torrent;
    control_torrent.Append("control-torrent");
    control_torrent.Append("regular-task-id");
    control_torrent.Append("pause");
    messages.emplace_back("controlTorrent", std::move(control_torrent));
#endif

    for (const auto& [message, args] : messages) {
      web_ui.ClearTrackedCalls();
      web_ui.HandleReceivedMessage(message, args);
      ASSERT_EQ(1u, web_ui.call_data().size()) << message;
      const content::TestWebUI::CallData& response = *web_ui.call_data().back();
      EXPECT_EQ("cr.webUIResponse", response.function_name()) << message;
      ASSERT_TRUE(response.arg2()) << message;
      EXPECT_TRUE(response.arg2()->GetBool()) << message;
      ASSERT_TRUE(response.arg3()) << message;
      ASSERT_TRUE(response.arg3()->is_dict()) << message;
      const base::DictValue& body = response.arg3()->GetDict();
      EXPECT_FALSE(body.FindBool("ok").value_or(true)) << message;
      EXPECT_FALSE(body.FindBool("found").value_or(true)) << message;
      const std::string* error = body.FindString("error");
      ASSERT_TRUE(error) << message;
      EXPECT_EQ("Aegis is unavailable for this profile", *error) << message;
    }
  }
}

}  // namespace
}  // namespace aegis
