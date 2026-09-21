// Copyright 2026 GCSA

#include <algorithm>
#include <atomic>
#include <map>
#include <memory>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/path_service.h"
#include "base/run_loop.h"
#include "base/scoped_observation.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/test/run_until.h"
#include "base/test/scoped_feature_list.h"
#include "base/test/test_future.h"
#include "base/test/scoped_run_loop_timeout.h"
#include "base/threading/thread_restrictions.h"
#include "base/timer/timer.h"
#include "build/build_config.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/aegis/aegis_ai_control.h"
#include "chrome/browser/aegis/aegis_phish_blocking_page.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/aegis/aegis_service_factory.h"
#include "chrome/browser/aegis/agent/aegis_agent_service.h"
#include "chrome/browser/actor/actor_keyed_service.h"
#include "chrome/browser/actor/actor_task.h"
#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"
#include "chrome/browser/aegis/agent/agent_model_client.h"
#include "chrome/browser/aegis/agent/agent_monitor_summary.h"
#include "chrome/browser/aegis/agent/v2_runtime_spike.h"
#include "chrome/browser/bookmarks/bookmark_model_factory.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/notifications/notification_display_service_tester.h"
#include "chrome/browser/prefs/incognito_mode_prefs.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/profiles/profile_test_util.h"
#include "chrome/browser/profiles/profile_window.h"
#include "chrome/browser/renderer_context_menu/render_view_context_menu_test_util.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "chrome/browser/tab_list/tab_list_interface.h"
#include "chrome/browser/ui/actions/chrome_action_id.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_actions.h"
#include "chrome/browser/ui/browser_command_controller.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/side_panel/side_panel_action_callback.h"
#include "chrome/browser/ui/side_panel/side_panel_entry.h"
#include "chrome/browser/ui/side_panel/side_panel_entry_key.h"
#include "chrome/browser/ui/side_panel/side_panel_enums.h"
#include "chrome/browser/ui/side_panel/side_panel_registry.h"
#include "chrome/browser/ui/side_panel/side_panel_ui.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/toolbar/pinned_toolbar/pinned_toolbar_actions_model.h"
#include "chrome/browser/ui/toolbar/toolbar_pref_names.h"
#include "chrome/browser/ui/views/side_panel/aegis_agent/aegis_agent_side_panel.h"
#include "chrome/browser/ui/views/toolbar/aegis_toolbar_button.h"
#include "chrome/common/aegis/cdp_target_filter.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "chrome/common/chrome_paths.h"
#include "chrome/common/chrome_switches.h"
#include "chrome/common/chrome_features.h"
#include "chrome/common/webui_url_constants.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_node.h"
#include "components/bookmarks/test/bookmark_test_helpers.h"
#include "components/os_crypt/async/browser/os_crypt_async.h"
#include "components/policy/core/common/policy_pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_service.h"
#include "components/security_interstitials/content/security_interstitial_tab_helper.h"
#include "components/tab_groups/tab_group_id.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/content_switches.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "crypto/sha2.h"
#include "net/dns/mock_host_resolver.h"
#include "net/http/http_status_code.h"
#include "net/test/embedded_test_server/controllable_http_response.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_request.h"
#include "net/test/embedded_test_server/http_response.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/test/test_url_loader_factory.h"
#include "services/network/test/test_utils.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/actions/actions.h"
#include "ui/message_center/public/cpp/notification.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {

SidePanelEntry* AgentEntry(BrowserWindowInterface* browser) {
  SidePanelRegistry* registry = SidePanelRegistry::From(browser);
  return registry ? registry->GetEntryForKey(
                        SidePanelEntry::Key(SidePanelEntry::Id::kAegisAgent))
                  : nullptr;
}

void ConfigureAgentModel(Profile* profile) {
  PrefService* pref_service = profile->GetPrefs();
  pref_service->SetString(prefs::kModelProvider, "openai");
  pref_service->SetString(prefs::kModelBaseUrl, "https://api.openai.com/v1");
  pref_service->SetString(prefs::kModelName, "gpt-4.1-mini");
}

content::WebContents* ShowAgentPanel(Browser* browser) {
  SidePanelUI* side_panel = browser->GetFeatures().side_panel_ui();
  if (!side_panel) {
    return nullptr;
  }
  side_panel->SetNoDelaysForTesting(true);
  side_panel->DisableAnimationsForTesting();
  if (!ShowAegisAgentSidePanel(browser) || !base::test::RunUntil([&]() {
        return side_panel->IsSidePanelEntryShowing(
            SidePanelEntry::Key(SidePanelEntry::Id::kAegisAgent));
      })) {
    return nullptr;
  }
  content::WebContents* contents =
      side_panel->GetWebContentsForTest(SidePanelEntry::Id::kAegisAgent);
  return contents && content::WaitForLoadStop(contents) ? contents : nullptr;
}

class ProfileDestructionProbe : public ProfileObserver {
 public:
  explicit ProfileDestructionProbe(Profile* profile)
      : original_profile_(profile->GetOriginalProfile()) {
    observation_.Observe(profile);
  }

  void OnProfileWillBeDestroyed(Profile*) override {
    notified_ = true;
    original_had_primary_otr_ =
        original_profile_ && original_profile_->HasPrimaryOTRProfile();
    observation_.Reset();
  }

  bool notified() const { return notified_; }
  bool original_had_primary_otr() const { return original_had_primary_otr_; }

 private:
  raw_ptr<Profile> original_profile_;
  bool notified_ = false;
  bool original_had_primary_otr_ = false;
  base::ScopedObservation<Profile, ProfileObserver> observation_{this};
};

std::unique_ptr<TestRenderViewContextMenu> CreateAegisContextMenu(
    Browser* browser) {
  content::WebContents* contents =
      browser->GetTabStripModel()->GetActiveWebContents();
  content::ContextMenuParams params;
  params.page_url = contents->GetLastCommittedURL();
  params.frame_url = params.page_url;
  auto menu = std::make_unique<TestRenderViewContextMenu>(
      *contents->GetPrimaryMainFrame(), std::move(params));
  menu->SetBrowser(browser);
  menu->Init();
  return menu;
}

class AegisAgentDefaultEntryBrowserTest : public InProcessBrowserTest {
 public:
  AegisAgentDefaultEntryBrowserTest() {
    features_.InitWithFeatures({}, {features::kAegisFilterListUpdater,
                                    features::kAegisPhishInterstitial});
  }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch(::switches::kDisableBackgroundNetworking);
    command_line->AppendSwitch(::switches::kNoProxyServer);
  }

 private:
  base::test::ScopedFeatureList features_;
};

IN_PROC_BROWSER_TEST_F(AegisAgentDefaultEntryBrowserTest,
                       EntryIsVisibleBeforeProfileOptIn) {
  Profile* profile = browser()->GetProfile();
  ASSERT_TRUE(profile->IsRegularProfile());
  EXPECT_TRUE(base::FeatureList::IsEnabled(features::kAegisAgent));
  EXPECT_TRUE(base::FeatureList::IsEnabled(features::kAegisAgentPageActions));
  EXPECT_TRUE(base::FeatureList::IsEnabled(features::kAegisAgentBrowserTools));
  EXPECT_TRUE(base::FeatureList::IsEnabled(features::kAegisAgentWorkflows));
  EXPECT_FALSE(profile->GetPrefs()->GetBoolean(prefs::kAgentEnabled));
  EXPECT_TRUE(IsAegisAgentSidePanelSupported(profile));
  EXPECT_TRUE(AgentEntry(browser()));
  EXPECT_EQ(AegisAgentServiceFactory::GetForProfile(profile), nullptr);

  actions::ActionItem* action = actions::ActionManager::Get().FindAction(
      kActionSidePanelShowAegisAgent,
      BrowserActions::From(browser())->root_action_item());
  ASSERT_TRUE(action);
  EXPECT_TRUE(action->GetVisible());
  PinnedToolbarActionsModel* pinned = PinnedToolbarActionsModel::Get(profile);
  ASSERT_TRUE(pinned);
  EXPECT_TRUE(pinned->Contains(kActionSidePanelShowAegisAgent));
  EXPECT_TRUE(
      profile->GetPrefs()->GetBoolean(::prefs::kAegisAgentAutoPinnedMigration));
}

IN_PROC_BROWSER_TEST_F(AegisAgentDefaultEntryBrowserTest,
                       ExistingProfilePinsEntryOnlyOnce) {
  Profile* profile = browser()->GetProfile();
  PinnedToolbarActionsModel* pinned = PinnedToolbarActionsModel::Get(profile);
  ASSERT_TRUE(pinned);

  pinned->UpdatePinnedState(kActionSidePanelShowAegisAgent, false);
  profile->GetPrefs()->SetBoolean(::prefs::kAegisAgentAutoPinnedMigration,
                                  false);
  pinned->MaybeMigrateExistingPinnedStates();
  EXPECT_TRUE(pinned->Contains(kActionSidePanelShowAegisAgent));
  EXPECT_TRUE(
      profile->GetPrefs()->GetBoolean(::prefs::kAegisAgentAutoPinnedMigration));

  pinned->UpdatePinnedState(kActionSidePanelShowAegisAgent, false);
  pinned->MaybeMigrateExistingPinnedStates();
  EXPECT_FALSE(pinned->Contains(kActionSidePanelShowAegisAgent));
}

IN_PROC_BROWSER_TEST_F(AegisAgentDefaultEntryBrowserTest,
                       PinnedToolbarActionOpensPanel) {
  actions::ActionItem* action = actions::ActionManager::Get().FindAction(
      kActionSidePanelShowAegisAgent,
      BrowserActions::From(browser())->root_action_item());
  ASSERT_TRUE(action);
  SidePanelUI* side_panel = browser()->GetFeatures().side_panel_ui();
  ASSERT_TRUE(side_panel);
  side_panel->DisableAnimationsForTesting();

  action->InvokeAction(
      actions::ActionInvocationContext::Builder()
          .SetProperty(
              kSidePanelOpenTriggerKey,
              static_cast<std::underlying_type_t<SidePanelOpenTrigger>>(
                  SidePanelOpenTrigger::kPinnedEntryToolbarButton))
          .Build());

  EXPECT_TRUE(base::test::RunUntil([&]() {
    return side_panel->IsSidePanelEntryShowing(
        SidePanelEntry::Key(SidePanelEntry::Id::kAegisAgent));
  }));
}

IN_PROC_BROWSER_TEST_F(AegisAgentDefaultEntryBrowserTest,
                       FirstTaskConfiguresAndEnablesAgentInPanel) {
  Profile* profile = browser()->GetProfile();
  ASSERT_FALSE(profile->GetPrefs()->GetBoolean(prefs::kAgentEnabled));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const handler = BrowserProxy.getInstance().handler;
      const configured = await handler.configureModel(
          'openai', 'http://127.0.0.1:8000/v1', 'fixture-local', '', false);
      if (!configured.snapshot.modelConfigured) {
        return `CONFIG_ERROR:${configured.snapshot.lastError}`;
      }
      const created = await handler.createTask(
          'organize my bookmarks with a preview', 1, 1, [], 0);
      return created.snapshot.taskId || `TASK_ERROR:${created.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("CONFIG_ERROR:")) << task_id;
  ASSERT_FALSE(task_id.starts_with("TASK_ERROR:")) << task_id;
  EXPECT_TRUE(profile->GetPrefs()->GetBoolean(prefs::kAgentEnabled));
  AegisAgentService* service = AegisAgentServiceFactory::GetForProfile(profile);
  ASSERT_TRUE(service);
  EXPECT_EQ(service->task_count_for_testing(), 1u);
}

IN_PROC_BROWSER_TEST_F(AegisAgentDefaultEntryBrowserTest,
                       NarrowPanelKeepsFocusedFieldsAndActionsVisible) {
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return content::EvalJs(panel, R"JS(
      document.getElementById('task-view-button').textContent.length > 0
    )JS").ExtractBool();
  }));

  // 调整真实 WebUI 视口；不复制 CSS，也不以隐藏溢出来代替内容可达。
  for (int width : {240, 280, 320, 400, 720}) {
    SCOPED_TRACE(width);
    panel->Resize(gfx::Rect(0, 0, width, 800));
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return content::EvalJs(panel, "window.innerWidth").ExtractInt() == width;
    }));
    for (const char* workspace : {"task", "automation"}) {
      SCOPED_TRACE(workspace);
      EXPECT_EQ("ok", content::EvalJs(panel, content::JsReplace(R"JS(
        (async () => {
          const element = id => document.getElementById(id);
          element($1 + '-view-button').click();
          element('model-details').open = true;
          element('model-name').value =
              'Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit';
          element('model-base-url').value = 'http://127.0.0.1:8000/v1';
          const goal = element($1 === 'task' ? 'goal' : 'automation-goal');
          goal.value = '检查页面变化；不要下载、整理书签、提交或购买。';
          const errors = [];
          for (const field of [goal, element('model-name'),
                               element('model-base-url')]) {
            field.focus();
            await new Promise(resolve => requestAnimationFrame(() =>
                requestAnimationFrame(resolve)));
            const root = document.documentElement;
            if (root.scrollWidth > root.clientWidth || window.scrollX !== 0) {
              errors.push(field.id + ': viewport=' + root.clientWidth +
                          ', content=' + root.scrollWidth +
                          ', scrollX=' + window.scrollX);
            }
            for (const node of document.querySelectorAll(
                'main, header, section, nav, details, textarea, input, ' +
                'select, button, label, h1, h2, .mark')) {
              if (!node.getClientRects().length) continue;
              const bounds = node.getBoundingClientRect();
              if (bounds.left < -1 || bounds.right > root.clientWidth + 1) {
                errors.push((node.id || node.className || node.tagName) +
                            ': [' + bounds.left + ', ' + bounds.right + ']');
              }
            }
          }
          return errors.length ? errors.join('\n') : 'ok';
        })()
      )JS", workspace)).ExtractString());
    }
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentDefaultEntryBrowserTest,
                       FailedModelSaveKeepsDraftAndAllowsRetry) {
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  // 经真实 WebUI 按钮和原生配置校验，不用模拟响应替代旧设置保持与重试。
  EXPECT_EQ("ok", content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const {loadTimeData} = await import('//resources/js/load_time_data.js');
      const handler = BrowserProxy.getInstance().handler;
      const element = id => document.getElementById(id);
      const waitFor = async predicate => {
        const deadline = performance.now() + 10000;
        while (!predicate()) {
          if (performance.now() > deadline) throw new Error('form wait timed out');
          await new Promise(resolve => setTimeout(resolve, 10));
        }
      };
      await waitFor(() => element('model-base-url').value.length > 0);
      const save = async (baseUrl, name) => {
        element('model-details').open = true;
        element('model-provider').value = 'openai';
        element('model-base-url').value = baseUrl;
        element('model-name').value = name;
        element('model-api-key').value = '';
        element('save-model-button').click();
        await waitFor(() => !element('save-model-button').disabled &&
                           element('model-feedback').textContent.length > 0);
        return (await handler.getSnapshot()).snapshot;
      };
      const baseUrl = 'http://127.0.0.1:8000/v1';
      const first = await save(baseUrl, 'previous-model');
      if (!first.modelConfigured || first.lastError ||
          first.modelName !== 'previous-model' ||
          element('model-details').open) return 'initial save failed';
      const rejected = await save('file:///invalid-model', 'requested-model');
      if (!rejected.modelConfigured || !rejected.lastError ||
          rejected.modelBaseUrl !== baseUrl ||
          rejected.modelName !== 'previous-model') return 'old setting changed';
      if (!element('model-details').open ||
          element('model-base-url').value !== 'file:///invalid-model' ||
          element('model-name').value !== 'requested-model' ||
          element('model-api-key').value !== '' ||
          element('model-feedback').textContent !==
              loadTimeData.getString('modelConfigurationError')) {
        return 'failed save hid or overwrote the draft';
      }
      const retried = await save(baseUrl, 'requested-model');
      if (!retried.modelConfigured || retried.lastError ||
          retried.modelName !== 'requested-model' ||
          element('model-details').open ||
          element('model-feedback').textContent !==
              loadTimeData.getString('modelSaved')) return 'retry failed';
      return 'ok';
    })()
  )JS"));
  EXPECT_EQ(browser()->GetProfile()->GetPrefs()->GetString(prefs::kModelName),
            "requested-model");
  EXPECT_FALSE(
      browser()->GetProfile()->GetPrefs()->GetBoolean(prefs::kAgentEnabled));
}

// 独立夹具：启动期间不启用 Agent、不访问 Agent 面板、不主动创建服务。
class AegisAgentColdStartMonitorBrowserTest : public InProcessBrowserTest {
 public:
  AegisAgentColdStartMonitorBrowserTest() {
    features_.InitWithFeatures({}, {features::kAegisFilterListUpdater,
                                    features::kAegisPhishInterstitial});
    server_.RegisterRequestHandler(base::BindRepeating(
        &AegisAgentColdStartMonitorBrowserTest::HandleRequest,
        base::Unretained(this)));
  }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch(::switches::kDisableBackgroundNetworking);
    command_line->AppendSwitch(::switches::kNoProxyServer);
  }

  bool SetUpUserDataDirectory() override {
    if (!InProcessBrowserTest::SetUpUserDataDirectory()) {
      return false;
    }
    base::FilePath user_data;
    if (!base::PathService::Get(chrome::DIR_USER_DATA, &user_data)) {
      ADD_FAILURE() << "无法定位测试专用用户目录";
      return false;
    }
    metadata_path_ = user_data.AppendASCII("aegis-cold-start-monitor.json");
    int port = 0;
    if (GetTestPreCount() == 0) {
      std::string json;
      if (!base::ReadFileToString(metadata_path_, &json)) {
        ADD_FAILURE() << "缺少 PRE 元数据；必须由原生 PRE 启动器运行整对测试";
        return false;
      }
      const auto data = base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
      const auto saved_port = data ? data->FindInt("port") : std::nullopt;
      const auto* id = data ? data->FindString("task_id") : nullptr;
      const auto* deadline = data ? data->FindString("deadline_us") : nullptr;
      int64_t deadline_us = 0;
      if (!saved_port || *saved_port <= 0 || *saved_port > 65535 ||
          !id || id->empty() || !deadline ||
          !base::StringToInt64(*deadline, &deadline_us) || deadline_us <= 0) {
        ADD_FAILURE() << "PRE 元数据无效";
        return false;
      }
      port = *saved_port;
      task_id_ = *id;
      original_deadline_ = base::Time::FromDeltaSinceWindowsEpoch(
          base::Microseconds(deadline_us));
    } else if (GetTestPreCount() != 1 || base::PathExists(metadata_path_)) {
      ADD_FAILURE() << "PRE 需要干净的测试专用用户目录";
      return false;
    }
    // 浏览器启动前只绑定监听套接字；不在进程派生前创建服务器 IO 线程。
    // PRE 由系统分配端口，POST 原样复用；占用即失败，不能改目标端口。
    if (!server_.InitializeAndListen(port, "127.0.0.1")) {
      ADD_FAILURE() << "测试夹具不能监听 PRE 端口：" << port;
      return false;
    }
    listening_at_ = base::Time::Now();
    return true;
  }

  void SetUpOnMainThread() override {
    // 按 EmbeddedTestServer 标准时序接收启动期间已排队的连接。
    server_.StartAcceptingConnections();
    InProcessBrowserTest::SetUpOnMainThread();
  }

  void TearDownOnMainThread() override {
    if (server_.Started()) {
      EXPECT_TRUE(server_.ShutdownAndWaitUntilComplete());
    }
    if (GetTestPreCount() == 1) {
      EXPECT_EQ(head_requests_.load(), 0)
          << "PRE 已到期发请求，不能算作重启后的首次检查";
      EXPECT_EQ(unexpected_requests_.load(), 0);
    }
    InProcessBrowserTest::TearDownOnMainThread();
  }

 protected:
  static constexpr char kMonitorId[] = "native-cold-start-url-status";
  static constexpr char kTargetPath[] = "/aegis-cold-start-status";

  std::unique_ptr<net::test_server::HttpResponse> HandleRequest(
      const net::test_server::HttpRequest& request) {
    auto response = std::make_unique<net::test_server::BasicHttpResponse>();
    if (request.relative_url != kTargetPath ||
        request.method != net::test_server::METHOD_HEAD) {
      ++unexpected_requests_;
      response->set_code(net::HTTP_BAD_REQUEST);
      return response;
    }
    ++head_requests_;
    response->set_code(net::HTTP_OK);
    response->AddCustomHeader("Cache-Control", "no-store");
    return response;
  }

  base::FilePath metadata_path_;
  std::string task_id_;
  base::Time original_deadline_;
  base::Time listening_at_;
  std::atomic<int> head_requests_{0};
  std::atomic<int> unexpected_requests_{0};
  base::test::ScopedFeatureList features_;
  // 最后声明，保证异常退出时服务器先析构，再销毁回调访问的计数器。
  net::EmbeddedTestServer server_;
};

IN_PROC_BROWSER_TEST_F(AegisAgentColdStartMonitorBrowserTest,
                       PRE_RestoresUrlStatusWithoutOpeningPanel) {
  Profile* profile = browser()->GetProfile();
  ASSERT_TRUE(profile->IsRegularProfile());
  ASSERT_FALSE(profile->GetPrefs()->GetBoolean(prefs::kAgentEnabled));
  ASSERT_EQ(AegisAgentServiceFactory::GetForProfileIfExists(profile), nullptr);
  ASSERT_FALSE(browser()->GetFeatures().side_panel_ui()->IsSidePanelEntryShowing(
      SidePanelEntry::Key(SidePanelEntry::Id::kAegisAgent)));

  // 仅 PRE 正文显式启用并创建服务；不通过面板、模型或执行工具准备资料。
  profile->GetPrefs()->SetBoolean(prefs::kAgentEnabled, true);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile);
  ASSERT_TRUE(service);
  base::test::TestFuture<bool> loaded;
  service->FlushTaskStoreForTesting(loaded.GetCallback());
  ASSERT_TRUE(loaded.Get());

  const GURL target = server_.GetURL(kTargetPath);
  AgentTaskScope scope;
  scope.allowed_origins = {url::Origin::Create(target)};
  scope.allowed_tools = {"monitor.create"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage};
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = server_.GetURL("/v1").spec();
  scope.model_destination.model = "unused-cold-start-fixture";
  auto* owner = service->CreateTask("定时检查固定网址",
                                   AgentMode::kAutomate, std::move(scope));
  ASSERT_TRUE(owner);
  ASSERT_TRUE(owner->TransitionTo(AgentTaskState::kPlanning, "固定监控计划"));
  ASSERT_TRUE(owner->TransitionTo(AgentTaskState::kAwaitingTaskConsent,
                                  "测试计划已准备"));
  ASSERT_TRUE(service->GrantTaskConsent(owner->id()));

  // 使用浏览器实际 OSCryptAsync；沿用原生测试 mock Keychain，不注入密钥。
  base::test::TestFuture<scoped_refptr<os_crypt_async::Encryptor>> ready;
  g_browser_process->os_crypt_async()->GetInstance(ready.GetCallback());
  const auto encryptor = ready.Get();
  ASSERT_TRUE(encryptor);
  ASSERT_TRUE(encryptor->IsEncryptionAvailable());
  AgentMonitorDefinition monitor;
  monitor.monitor_id = kMonitorId;
  monitor.task_id = owner->id();
  monitor.kind = AgentMonitorKind::kUrlStatus;
  monitor.origin = url::Origin::Create(target);
  monitor.target_url = target;
  monitor.target_hash =
      "sha256:" + base::HexEncode(crypto::SHA256HashString(target.spec()));
  ASSERT_TRUE(encryptor->EncryptString(target.spec(), &monitor.target_ciphertext));
  ASSERT_FALSE(monitor.target_ciphertext.empty());
  monitor.session_only = false;
  monitor.interval = base::Minutes(15);
  // 仅在新监控首次创建时设 20 秒；后续不改记录、不改时钟、不手动触发。
  monitor.next_run = base::Time::Now() + base::Seconds(20);
  ASSERT_TRUE(service->UpsertMonitor(monitor));
  ASSERT_TRUE(owner->TransitionTo(AgentTaskState::kVerifying, "监控已保存"));
  ASSERT_TRUE(service->CompleteTask(owner->id()));
  ASSERT_EQ(owner->state(), AgentTaskState::kCompleted);

  base::test::TestFuture<bool> stored;
  service->FlushTaskStoreForTesting(stored.GetCallback());
  ASSERT_TRUE(stored.Get());
  ASSERT_TRUE(service->IsEnabled());
  base::test::TestFuture<void> prefs_stored;
  profile->GetPrefs()->CommitPendingWrite(prefs_stored.GetCallback());
  ASSERT_TRUE(prefs_stored.Wait());

  base::DictValue metadata;
  metadata.Set("port", target.EffectiveIntPort());
  metadata.Set("task_id", owner->id());
  metadata.Set("deadline_us", base::NumberToString(
      monitor.next_run.ToDeltaSinceWindowsEpoch().InMicroseconds()));
  const auto json = base::WriteJson(metadata);
  ASSERT_TRUE(json);
  {
    base::ScopedAllowBlockingForTesting allow_blocking;
    ASSERT_TRUE(base::WriteFile(metadata_path_, *json));
  }
  const auto saved = service->GetMonitors(owner->id());
  ASSERT_EQ(saved.size(), 1u);
  EXPECT_EQ(saved[0].next_run, monitor.next_run);
  EXPECT_TRUE(saved[0].last_run.is_null());
  EXPECT_EQ(saved[0].last_check_status, AgentMonitorCheckStatus::kNotChecked);
  EXPECT_EQ(owner->tool_calls_used(), 0);
  EXPECT_EQ(owner->model_calls_used(), 0);
  EXPECT_EQ(owner->network_requests_used(), 0);
  EXPECT_EQ(head_requests_.load(), 0);
  ASSERT_LT(base::Time::Now(), monitor.next_run)
      << "PRE 准备超过 20 秒；须报告夹具超时，禁止推迟原 deadline";
}

IN_PROC_BROWSER_TEST_F(AegisAgentColdStartMonitorBrowserTest,
                       RestoresUrlStatusWithoutOpeningPanel) {
  // 旧产品预期首先在此失败；禁止用 GetForProfile 补建 service。
  auto* service =
      AegisAgentServiceFactory::GetForProfileIfExists(browser()->GetProfile());
  ASSERT_NE(service, nullptr) << "启用资料冷启动未主动恢复 Agent 服务";
  ASSERT_TRUE(browser()->GetProfile()->IsRegularProfile());
  ASSERT_TRUE(
      browser()->GetProfile()->GetPrefs()->GetBoolean(prefs::kAgentEnabled));
  ASSERT_FALSE(browser()->GetFeatures().side_panel_ui()->IsSidePanelEntryShowing(
      SidePanelEntry::Key(SidePanelEntry::Id::kAegisAgent)));

  // 只让真实消息循环与时钟前进；允许启动时已过期的原监控自然立即执行。
  base::test::ScopedRunLoopTimeout timeout(FROM_HERE, base::Seconds(60));
  ASSERT_TRUE(base::test::RunUntil([&] {
    const auto monitors = service->GetMonitors(task_id_);
    return monitors.size() == 1u &&
           monitors[0].last_check_status != AgentMonitorCheckStatus::kNotChecked;
  }));
  const auto monitors = service->GetMonitors(task_id_);
  ASSERT_EQ(monitors.size(), 1u);
  const auto& monitor = monitors[0];
  EXPECT_EQ(monitor.monitor_id, kMonitorId);
  EXPECT_EQ(monitor.task_id, task_id_);
  EXPECT_EQ(monitor.kind, AgentMonitorKind::kUrlStatus);
  EXPECT_EQ(monitor.interval, base::Minutes(15));
  EXPECT_FALSE(monitor.session_only);
  EXPECT_TRUE(monitor.enabled);
  EXPECT_EQ(monitor.target_url, server_.GetURL(kTargetPath));
  EXPECT_FALSE(monitor.target_ciphertext.empty());
  EXPECT_EQ(monitor.last_check_status, AgentMonitorCheckStatus::kSucceeded);
  EXPECT_EQ(monitor.last_http_status, 200);
  EXPECT_EQ(monitor.consecutive_failures, 0);
  EXPECT_GE(monitor.last_run, original_deadline_);
  EXPECT_GE(monitor.last_run, listening_at_);
  EXPECT_EQ(monitor.next_run, monitor.last_run + base::Minutes(15));
  EXPECT_EQ(head_requests_.load(), 1);
  EXPECT_EQ(unexpected_requests_.load(), 0);
  const auto* owner = service->GetTask(task_id_);
  ASSERT_TRUE(owner);
  EXPECT_EQ(service->task_count_for_testing(), 1u);
  EXPECT_EQ(owner->state(), AgentTaskState::kCompleted);
  EXPECT_EQ(owner->tool_calls_used(), 0);
  EXPECT_EQ(owner->model_calls_used(), 0);
  EXPECT_EQ(owner->network_requests_used(), 1);
  // 仅清理本测试经正常接口创建的监控，不操作已有资料或调度数据。
  ASSERT_TRUE(service->RemoveMonitor(task_id_, kMonitorId));
  base::test::TestFuture<bool> removed;
  service->FlushTaskStoreForTesting(removed.GetCallback());
  ASSERT_TRUE(removed.Get());
}

class AegisAgentBrowserTest : public InProcessBrowserTest {
 public:
  AegisAgentBrowserTest() {
    features_.InitWithFeatures(
        {features::kAegisAgentWebMcp},
        {features::kAegisAgentTransactionPilot,
         features::kAegisFilterListUpdater, features::kAegisPhishInterstitial});
  }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch(::switches::kDisableBackgroundNetworking);
    command_line->AppendSwitch(::switches::kNoProxyServer);
  }

  void SetUpOnMainThread() override {
    InProcessBrowserTest::SetUpOnMainThread();
    browser()->GetProfile()->GetPrefs()->SetBoolean(prefs::kAgentEnabled, true);
  }

 private:
  base::test::ScopedFeatureList features_;
};

class AegisAgentUrlMonitorBrowserTest : public AegisAgentBrowserTest {
 public:
  void SetUpOnMainThread() override {
    AegisAgentBrowserTest::SetUpOnMainThread();
    foreign_server_.RegisterRequestHandler(base::BindRepeating(
        [](std::atomic<int>* count, const net::test_server::HttpRequest&)
            -> std::unique_ptr<net::test_server::HttpResponse> {
          ++*count;
          return std::make_unique<net::test_server::BasicHttpResponse>();
        },
        &foreign_requests_));
    ASSERT_TRUE(foreign_server_.Start());
    embedded_test_server()->RegisterRequestHandler(
        base::BindRepeating(&AegisAgentUrlMonitorBrowserTest::HandleRequest,
                            base::Unretained(this)));
  }

  void TearDownOnMainThread() override {
    // 先停网络线程，再销毁它读取的夹具成员。
    if (embedded_test_server()->Started()) {
      EXPECT_TRUE(embedded_test_server()->ShutdownAndWaitUntilComplete());
    }
    EXPECT_TRUE(foreign_server_.ShutdownAndWaitUntilComplete());
    service_ = nullptr;
    AegisAgentBrowserTest::TearDownOnMainThread();
  }

 protected:
  void ConfigureMonitorSummaryModel() {
    summary_endpoint_ = embedded_test_server()->GetURL("/v1").spec();
    auto* pref_service = browser()->GetProfile()->GetPrefs();
    pref_service->SetString(prefs::kModelProvider, "openai");
    pref_service->SetString(prefs::kModelBaseUrl, summary_endpoint_);
    pref_service->SetString(prefs::kModelName, "fixture-model");
  }

  void PrepareMonitor(const GURL& target,
                      AgentMonitorDefinition* monitor,
                      AgentTask** owner,
                      AgentMonitorKind kind = AgentMonitorKind::kUrlStatus,
                      bool session_only = true) {
    service_ = AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
    ASSERT_TRUE(service_);
    base::test::TestFuture<bool> loaded;
    service_->FlushTaskStoreForTesting(loaded.GetCallback());
    ASSERT_TRUE(loaded.Get());
    AgentTaskScope scope;
    scope.allowed_origins = {url::Origin::Create(target),
                             url::Origin::Create(foreign_server_.GetURL("/"))};
    scope.allowed_tools = {"page.observe", "monitor.create"};
    scope.allowed_data_classes = {AgentDataClass::kPublicPage};
    scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
    scope.model_destination.provider = "openai";
    scope.model_destination.endpoint = summary_endpoint_.empty()
                                           ? "http://127.0.0.1:8000/v1"
                                           : summary_endpoint_;
    scope.model_destination.model = "fixture-model";
    *owner = service_->CreateTask("定时检查固定网址，不需要预先打开目标页",
                                  AgentMode::kAutomate, std::move(scope));
    ASSERT_TRUE(*owner);
    ASSERT_TRUE((*owner)->TransitionTo(AgentTaskState::kPlanning, "固定计划"));
    ASSERT_TRUE((*owner)->TransitionTo(AgentTaskState::kAwaitingTaskConsent,
                                       "测试计划已准备"));
    ASSERT_TRUE(service_->GrantTaskConsent((*owner)->id()));
    monitor->monitor_id = "native-url-monitor";
    monitor->task_id = (*owner)->id();
    monitor->kind = kind;
    monitor->origin = url::Origin::Create(target);
    monitor->target_url = target;
    monitor->target_hash = "fixture-target";
    monitor->session_only = session_only;
    if (!session_only) {
      base::test::TestFuture<scoped_refptr<os_crypt_async::Encryptor>> ready;
      g_browser_process->os_crypt_async()->GetInstance(ready.GetCallback());
      const auto encryptor = ready.Get();
      ASSERT_TRUE(encryptor);
      monitor->target_hash =
          "sha256:" + base::HexEncode(crypto::SHA256HashString(target.spec()));
      ASSERT_TRUE(encryptor->EncryptString(target.spec(),
                                          &monitor->target_ciphertext));
    }
    monitor->next_run = base::Time::Now();
    ASSERT_TRUE(service_->UpsertMonitor(*monitor));
  }

  void WaitForCheck(const std::string& task_id) {
    ASSERT_TRUE(base::test::RunUntil([&] {
      const auto monitors = service_->GetMonitors(task_id);
      return monitors.size() == 1u && monitors[0].last_check_status !=
                                          AgentMonitorCheckStatus::kNotChecked;
    }));
  }

  std::unique_ptr<net::test_server::HttpResponse> HandleRequest(
      const net::test_server::HttpRequest& request) {
    if (request.relative_url == "/v1/responses") {
      if (hold_summary_response_) {
        // 让后注册的可控响应接管，避免普通夹具提前吞掉请求。
        return nullptr;
      }
      ++summary_requests_;
      const auto payload =
          base::JSONReader::ReadDict(request.content, base::JSON_PARSE_RFC);
      const auto* choice = payload ? payload->FindDict("tool_choice") : nullptr;
      const auto* tools = payload ? payload->FindList("tools") : nullptr;
      const auto* input = payload ? payload->FindString("input") : nullptr;
      const auto data =
          input ? base::JSONReader::ReadDict(*input, base::JSON_PARSE_RFC)
                : std::nullopt;
      const auto* changes = data ? data->FindList("changes") : nullptr;
      auto response = std::make_unique<net::test_server::BasicHttpResponse>();
      if (request.method != net::test_server::METHOD_POST || !choice ||
          !choice->FindString("name") ||
          *choice->FindString("name") != "agent.summarize_monitor" || !tools ||
          tools->size() != 1u || !changes || changes->empty() ||
          request.headers.contains("Cookie") ||
          request.headers.contains("Authorization")) {
        summary_requests_valid_ = false;
        response->set_code(net::HTTP_BAD_REQUEST);
        return response;
      }
      const int mode = summary_reply_mode_.load();
      base::ListValue ids;
      std::string added;
      bool has_removed = false;
      for (const auto& change : *changes) {
        const auto* item = change.GetIfDict();
        const auto* id = item ? item->FindString("id") : nullptr;
        const auto* kind = item ? item->FindString("kind") : nullptr;
        const auto* text = item ? item->FindString("text") : nullptr;
        if (!id || !kind || !text) {
          summary_requests_valid_ = false;
          continue;
        }
        if (*kind == "removed" && !has_removed) {
          ids.Append(*id);
          has_removed = true;
        } else if (*kind == "added" && added.empty()) {
          ids.Append(*id);
          added = *text;
        }
      }
      base::DictValue arguments;
      arguments.Set("meaningful", mode != 1);
      arguments.Set("summary", mode == 1 ? "" : "页面更新：" + added);
      arguments.Set("evidence_ids",
                    mode == 1   ? base::ListValue()
                    : mode == 2 ? base::ListValue().Append("invented-id")
                                : std::move(ids));
      base::DictValue call;
      call.Set("type", "function_call");
      call.Set("call_id", "monitor-summary-fixture");
      call.Set("name", "agent.summarize_monitor");
      call.Set("arguments", base::WriteJson(arguments).value_or("{}"));
      base::DictValue result;
      result.Set("status", "completed");
      result.Set("output", base::ListValue().Append(std::move(call)));
      response->set_content_type("application/json");
      response->set_content(base::WriteJson(result).value_or("{}"));
      return response;
    }
    if (!request.relative_url.starts_with("/monitor-")) {
      return nullptr;
    }
    ++requests_;
    if (request.headers.contains("Cookie") ||
        request.headers.contains("Authorization") ||
        request.headers.contains("Proxy-Authorization")) {
      credentials_omitted_ = false;
    }
    if (request.relative_url == "/monitor-timeout") {
      return std::make_unique<net::test_server::HungResponse>();
    }
    auto response = std::make_unique<net::test_server::BasicHttpResponse>();
    response->set_code(static_cast<net::HttpStatusCode>(http_status_.load()));
    response->AddCustomHeader("Cache-Control", "public, max-age=86400");
    if (request.relative_url == "/monitor-page") {
      response->set_content_type("text/html; charset=utf-8");
      const int revision = page_revision_.load();
      const std::string version = base::NumberToString(revision);
      const std::string stock = revision == 1 ? "缺货" : "有货";
      response->set_content(
          "<!doctype html><meta charset=utf-8><h1>公开商品资料</h1>"
          "<p>售价：￥" + version + "99</p><p>库存：" + stock +
          "</p><p>正文修订版本 " + version + "</p>");
    }
    if (request.relative_url == "/monitor-fallback") {
      if (request.method == net::test_server::METHOD_HEAD) {
        response->set_code(net::HTTP_METHOD_NOT_ALLOWED);
      } else {
        ++get_requests_;
        auto range = request.headers.find("Range");
        ranged_get_ = request.method == net::test_server::METHOD_GET &&
                      range != request.headers.end() &&
                      range->second == "bytes=0-0";
      }
    } else if (request.relative_url == "/monitor-redirect") {
      response->set_code(net::HTTP_FOUND);
      response->AddCustomHeader("Location", foreign_server_.GetURL("/").spec());
    }
    return response;
  }

  raw_ptr<AegisAgentService> service_ = nullptr;
  net::EmbeddedTestServer foreign_server_;
  std::atomic<int> http_status_{200};
  std::atomic<int> requests_{0};
  std::atomic<int> page_revision_{1};
  std::atomic<int> get_requests_{0};
  std::atomic<int> foreign_requests_{0};
  std::atomic<bool> credentials_omitted_{true};
  std::atomic<bool> ranged_get_{false};
  // 只在测试服务器内返回合成摘要，不连接真实模型或用户资料。
  std::string summary_endpoint_;
  std::atomic<int> summary_requests_{0};
  std::atomic<int> summary_reply_mode_{0};  // 0：变化；1：噪声；2：无效引用。
  std::atomic<bool> summary_requests_valid_{true};
  std::atomic<bool> hold_summary_response_{false};
};

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       FreshChecksDoNotNeedTabsOrWidenCompletedTaskScope) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL target = embedded_test_server()->GetURL("/monitor-status");
  ASSERT_TRUE(content::SetCookie(browser()->GetProfile(), target,
                                 "monitor_session=private-fixture"));
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(target, &monitor, &task));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto first = service_->GetMonitors(task->id());
  ASSERT_EQ(first.size(), 1u);
  EXPECT_EQ(first[0].last_http_status, 200);
  EXPECT_EQ(first[0].last_check_status, AgentMonitorCheckStatus::kSucceeded);
  EXPECT_EQ(requests_, 1);
  EXPECT_FALSE(first[0].last_value_hash.empty());

  // 即便服务器允许长缓存，第二轮必须实际访问；任务完成后仍可执行已批准监控。
  http_status_ = 404;
  monitor = first[0];
  monitor.next_run = base::Time::Now();
  monitor.last_check_status = AgentMonitorCheckStatus::kNotChecked;
  ASSERT_TRUE(service_->UpsertMonitor(monitor));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kVerifying, "创建完成"));
  ASSERT_TRUE(service_->CompleteTask(task->id()));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto second = service_->GetMonitors(task->id());
  ASSERT_EQ(second.size(), 1u);
  EXPECT_EQ(second[0].last_http_status, 404);
  EXPECT_EQ(second[0].last_check_status, AgentMonitorCheckStatus::kHttpError);
  EXPECT_EQ(second[0].consecutive_failures, 0);
  EXPECT_NE(first[0].last_value_hash, second[0].last_value_hash);
  EXPECT_EQ(requests_, 2);
  EXPECT_TRUE(credentials_omitted_);
  EXPECT_EQ(task->network_requests_used(), 2);
  EXPECT_TRUE(task->scope().allowed_tab_ids.empty());
  EXPECT_TRUE(task->owned_tab_ids().empty());
  EXPECT_FALSE(task->scope().AllowsTool("page.navigate"));
  EXPECT_FALSE(task->scope().AllowsTool("tab.create"));
  EXPECT_EQ(browser()->GetTabStripModel()->count(), 1);
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       HeadFallbackIsRangedCredentialFreeAndBudgeted) {
  ASSERT_TRUE(embedded_test_server()->Start());
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/monitor-fallback"), &monitor, &task));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  EXPECT_EQ(service_->GetMonitors(task->id())[0].last_check_status,
            AgentMonitorCheckStatus::kSucceeded);
  EXPECT_EQ(requests_, 2);
  EXPECT_EQ(get_requests_, 1);
  EXPECT_TRUE(ranged_get_);
  EXPECT_TRUE(credentials_omitted_);
  EXPECT_EQ(task->network_requests_used(), 2);
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       RedirectCannotExpandEvenToAnotherTaskApprovedOrigin) {
  ASSERT_TRUE(embedded_test_server()->Start());
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/monitor-redirect"), &monitor, &task));
  ASSERT_TRUE(task->scope().AllowsOrigin(foreign_server_.GetURL("/")));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto result = service_->GetMonitors(task->id());
  EXPECT_EQ(result[0].last_check_status,
            AgentMonitorCheckStatus::kRedirectBlocked);
  EXPECT_EQ(result[0].consecutive_failures, 1);
  EXPECT_EQ(requests_, 1);
  EXPECT_EQ(foreign_requests_, 0);
  EXPECT_TRUE(result[0].last_value_hash.empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       TimeoutIsBoundedAndDoesNotReportABrokenLink) {
  ASSERT_TRUE(embedded_test_server()->Start());
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  const base::TimeTicks started = base::TimeTicks::Now();
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/monitor-timeout"), &monitor, &task));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto result = service_->GetMonitors(task->id());
  EXPECT_EQ(result[0].last_check_status, AgentMonitorCheckStatus::kTimeout);
  EXPECT_EQ(result[0].last_http_status, 0);
  EXPECT_EQ(result[0].consecutive_failures, 1);
  EXPECT_GT(result[0].next_run, result[0].last_run + result[0].interval);
  EXPECT_LT(base::TimeTicks::Now() - started, base::Seconds(20));
  EXPECT_TRUE(result[0].last_value_hash.empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       LoginFailureReachesVisibleMonitorExplanation) {
  ASSERT_TRUE(embedded_test_server()->Start());
  http_status_ = 403;
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/monitor-status"), &monitor, &task));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto result = service_->GetMonitors(task->id());
  ASSERT_EQ(result.size(), 1u);
  EXPECT_EQ(result[0].last_check_status,
            AgentMonitorCheckStatus::kLoginRequired);
  EXPECT_EQ(result[0].last_http_status, 403);
  EXPECT_EQ(result[0].consecutive_failures, 1);
  EXPECT_TRUE(result[0].last_value_hash.empty());
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  ASSERT_TRUE(base::test::RunUntil([&] {
    auto visible = content::EvalJs(
        panel,
        "(async () => {const {loadTimeData} = await "
        "import('//resources/js/load_time_data.js');"
        "const button = document.getElementById('automation-view-button');"
        "if (!button || button.disabled) return false; button.click();"
        "const e = document.querySelector('.monitor-outcome');"
        "return !!e && !e.hidden && e.textContent.includes("
        "loadTimeData.getString('automationCheckStatus3')) && "
        "e.textContent.includes('HTTP 403') && "
        "e.getBoundingClientRect().height > 0;})()");
    return visible.is_ok() && visible.ExtractBool();
  }));
  // 使用真正注册的监控与本地化按钮，覆盖窄侧栏下的暂停/删除入口。
  for (int width : {240, 280, 320}) {
    SCOPED_TRACE(width);
    panel->Resize(gfx::Rect(0, 0, width, 800));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(panel, "window.innerWidth").ExtractInt() == width;
    }));
    EXPECT_EQ("ok", content::EvalJs(panel, R"JS(
      (async () => {
        await new Promise(resolve => requestAnimationFrame(() =>
            requestAnimationFrame(resolve)));
        const root = document.documentElement;
        if (root.scrollWidth > root.clientWidth || window.scrollX !== 0) {
          return '监控页宽度超出视口：' + root.scrollWidth + '/' + root.clientWidth;
        }
        const buttons = [...document.querySelectorAll('.monitor-actions button')];
        if (buttons.length !== 2) return '缺少监控操作按钮';
        for (const button of buttons) {
          button.focus();
          const bounds = button.getBoundingClientRect();
          if (bounds.left < 0 || bounds.right > root.clientWidth ||
              bounds.width <= 0 || bounds.height <= 0 || button.disabled) {
            return '监控按钮不可达：' + button.textContent;
          }
        }
        return 'ok';
      })()
    )JS").ExtractString());
  }
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       PausingCancelsPendingCheckAndIgnoresLateResponse) {
  net::test_server::ControllableHttpResponse pending(embedded_test_server(),
                                                     "/pending-check");
  ASSERT_TRUE(embedded_test_server()->Start());
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/pending-check"), &monitor, &task));
  pending.WaitForRequest();
  ASSERT_TRUE(service_->SetMonitorPaused(task->id(), monitor.monitor_id, true));
  pending.Send(net::HTTP_OK);
  pending.Done();
  base::RunLoop().RunUntilIdle();
  const auto result = service_->GetMonitors(task->id());
  ASSERT_EQ(result.size(), 1u);
  EXPECT_FALSE(result[0].enabled);
  EXPECT_EQ(result[0].last_check_status, AgentMonitorCheckStatus::kNotChecked);
  EXPECT_TRUE(result[0].last_value_hash.empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       RecoveryNotifiesOnceAndDoesNotExposeTheTargetPath) {
  int notifications_added = 0;
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  notifications.SetNotificationAddedClosure(base::BindRepeating(
      [](int* count) { ++*count; }, &notifications_added));
  ASSERT_TRUE(embedded_test_server()->Start());
  http_status_ = 403;
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/monitor-private-note"), &monitor, &task));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  EXPECT_EQ(notifications_added, 1);

  // 保留真实的上次状态；不能为了等待而将它重置成“从未检查”。
  monitor = service_->GetMonitors(task->id())[0];
  monitor.next_run = base::Time::Now();
  ASSERT_TRUE(service_->UpsertMonitor(monitor));
  ASSERT_TRUE(base::test::RunUntil([&] {
    const auto current = service_->GetMonitors(task->id());
    return current.size() == 1u && current[0].consecutive_failures == 2;
  }));
  EXPECT_EQ(notifications_added, 1);

  http_status_ = 200;
  monitor = service_->GetMonitors(task->id())[0];
  monitor.next_run = base::Time::Now();
  ASSERT_TRUE(service_->UpsertMonitor(monitor));
  ASSERT_TRUE(base::test::RunUntil([&] {
    const auto current = service_->GetMonitors(task->id());
    return current.size() == 1u && current[0].last_check_status ==
                                    AgentMonitorCheckStatus::kSucceeded;
  }));
  EXPECT_EQ(notifications_added, 2);
  EXPECT_EQ(requests_, 3);
  const auto notification =
      notifications.GetNotification("aegis-agent-monitor-" + monitor.monitor_id);
  ASSERT_TRUE(notification);
  ASSERT_TRUE(notification->delegate());
  EXPECT_NE(notification->message().find(u"127.0.0.1"), std::u16string::npos);
  EXPECT_EQ(notification->message().find(u"monitor-private-note"),
            std::u16string::npos);
  // 等待本轮所有日志写入及其主线程回调，不能在异步失败到达前结束测试。
  base::test::TestFuture<bool> persisted;
  service_->FlushTaskStoreForTesting(persisted.GetCallback());
  ASSERT_TRUE(persisted.Get());
  EXPECT_TRUE(service_->IsEnabled());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       PageMonitorsFetchFreshContentWithoutOwningUserTabs) {
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int initial_tabs = browser()->GetTabStripModel()->count();
  content::WebContents* original =
      browser()->GetTabStripModel()->GetActiveWebContents();
  const GURL original_url = original->GetLastCommittedURL();
  for (AgentMonitorKind kind :
       {AgentMonitorKind::kPrice, AgentMonitorKind::kInventory,
        AgentMonitorKind::kPageChange}) {
    SCOPED_TRACE(static_cast<int>(kind));
    notifications.RemoveAllNotifications(NotificationHandler::Type::TRANSIENT,
                                         /*by_user=*/false);
    requests_ = 0;
    page_revision_ = 1;
    if (kind == AgentMonitorKind::kPageChange) {
      ConfigureMonitorSummaryModel();
    }
    AgentMonitorDefinition monitor;
    AgentTask* task = nullptr;
    ASSERT_NO_FATAL_FAILURE(
        PrepareMonitor(embedded_test_server()->GetURL("/monitor-page"),
                       &monitor, &task, kind));
    ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
    const auto first = service_->GetMonitors(task->id())[0];
    ASSERT_EQ(first.last_check_status, AgentMonitorCheckStatus::kSucceeded);
    ASSERT_FALSE(first.last_value_hash.empty());
    ASSERT_FALSE(first.last_observation.empty());
    EXPECT_TRUE(notifications
                    .GetDisplayedNotificationsForType(
                        NotificationHandler::Type::TRANSIENT)
                    .empty());
    EXPECT_EQ(requests_, 1);
    EXPECT_EQ(summary_requests_, 0);
    EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs);

    page_revision_ = 2;
    monitor = first;
    monitor.next_run = base::Time::Now();
    ASSERT_TRUE(service_->UpsertMonitor(monitor));
    // 已完成任务的授权不被重开或扩大；价格用第三轮检查验证同一约束。
    if (kind != AgentMonitorKind::kPrice) {
      ASSERT_TRUE(task->TransitionTo(AgentTaskState::kVerifying, "创建完成"));
      ASSERT_TRUE(service_->CompleteTask(task->id()));
    }
    ASSERT_TRUE(base::test::RunUntil([&] {
      const auto current = service_->GetMonitors(task->id());
      return current.size() == 1u && current[0].last_run > first.last_run &&
             (current[0].last_value_hash != first.last_value_hash ||
              current[0].consecutive_failures > 0);
    }));
    const auto second = service_->GetMonitors(task->id())[0];
    EXPECT_EQ(second.last_check_status, AgentMonitorCheckStatus::kSucceeded);
    EXPECT_NE(first.last_value_hash, second.last_value_hash);
    EXPECT_EQ(notifications
                  .GetDisplayedNotificationsForType(
                      NotificationHandler::Type::TRANSIENT)
                  .size(),
              kind == AgentMonitorKind::kPrice ? 0u : 1u);
    EXPECT_EQ(requests_, 2);
    EXPECT_EQ(task->network_requests_used(),
              kind == AgentMonitorKind::kPageChange ? 3 : 2);
    if (kind == AgentMonitorKind::kPageChange) {
      EXPECT_EQ(summary_requests_, 1);
      EXPECT_TRUE(summary_requests_valid_);
      EXPECT_TRUE(HasMeaningfulAgentMonitorSummary(second.last_observation));
      EXPECT_FALSE(ReadAgentMonitorSummary(second.last_observation).empty());
      EXPECT_EQ(task->model_calls_used(), 1);
    }
    EXPECT_TRUE(task->scope().allowed_tab_ids.empty());
    EXPECT_TRUE(task->owned_tab_ids().empty());
    EXPECT_FALSE(task->scope().AllowsTool("tab.create"));
    EXPECT_EQ(
        service_->actor_bridge_for_testing().active_task_count_for_testing(),
        kind == AgentMonitorKind::kPrice ? 1u : 0u);
    EXPECT_EQ(service_->actor_bridge_for_testing().HasTask(task->id()),
              kind == AgentMonitorKind::kPrice);
    EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs);
    EXPECT_EQ(browser()->GetTabStripModel()->GetActiveWebContents(), original);
    EXPECT_EQ(original->GetLastCommittedURL(), original_url);
    if (kind == AgentMonitorKind::kPrice) {
      // 第一轮 199，第二轮涨到 299 不通知，第三轮实际降到 199 才通知。
      page_revision_ = 1;
      monitor = second;
      monitor.next_run = base::Time::Now();
      ASSERT_TRUE(service_->UpsertMonitor(monitor));
      ASSERT_TRUE(task->TransitionTo(AgentTaskState::kVerifying, "创建完成"));
      ASSERT_TRUE(service_->CompleteTask(task->id()));
      ASSERT_TRUE(base::test::RunUntil([&] {
        const auto current = service_->GetMonitors(task->id());
        return current.size() == 1u && current[0].last_run > second.last_run &&
               (current[0].last_value_hash != second.last_value_hash ||
                current[0].consecutive_failures > 0);
      }));
      EXPECT_EQ(service_->GetMonitors(task->id())[0].last_check_status,
                AgentMonitorCheckStatus::kSucceeded);
      EXPECT_EQ(notifications
                    .GetDisplayedNotificationsForType(
                        NotificationHandler::Type::TRANSIENT)
                    .size(),
                1u);
      EXPECT_EQ(requests_, 3);
      EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs);
    }
    EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
    EXPECT_EQ(
        service_->actor_bridge_for_testing().active_task_count_for_testing(),
        0u);
    ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       RepeatedPageChangesKeepStorageAndMonitorUsable) {
  int notifications_added = 0;
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  notifications.SetNotificationAddedClosure(base::BindRepeating(
      [](int* count) { ++*count; }, &notifications_added));
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureMonitorSummaryModel();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(
      PrepareMonitor(embedded_test_server()->GetURL("/monitor-page"), &monitor,
                     &task, AgentMonitorKind::kPageChange));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  ASSERT_EQ(service_->GetMonitors(task->id())[0].last_check_status,
            AgentMonitorCheckStatus::kSucceeded);
  EXPECT_EQ(notifications_added, 0);
  for (int revision : {2, 3}) {
    SCOPED_TRACE(revision);
    page_revision_ = revision;
    monitor = service_->GetMonitors(task->id())[0];
    const std::string previous_hash = monitor.last_value_hash;
    monitor.next_run = base::Time::Now();
    ASSERT_TRUE(service_->UpsertMonitor(monitor));
    ASSERT_TRUE(base::test::RunUntil([&] {
      const auto current = service_->GetMonitors(task->id());
      return current.size() == 1u &&
             current[0].last_value_hash != previous_hash;
    }));
    // 第二次变化日志也必须真正落盘，不能由异步回调停用整个Agent。
    base::test::TestFuture<bool> persisted;
    service_->FlushTaskStoreForTesting(persisted.GetCallback());
    ASSERT_TRUE(persisted.Get());
    ASSERT_TRUE(service_->IsEnabled());
    EXPECT_EQ(service_->GetMonitors(task->id())[0].last_check_status,
              AgentMonitorCheckStatus::kSucceeded);
    EXPECT_EQ(notifications_added, revision - 1);
    EXPECT_EQ(requests_, revision);
    EXPECT_EQ(summary_requests_, revision - 1);
  }
  EXPECT_TRUE(summary_requests_valid_);
  EXPECT_TRUE(credentials_omitted_);
  ASSERT_TRUE(service_->SetMonitorPaused(task->id(), monitor.monitor_id, true));
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       PageSummaryIgnoresNoiseAndSkipsUnchangedModelCalls) {
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureMonitorSummaryModel();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(
      PrepareMonitor(embedded_test_server()->GetURL("/monitor-page"), &monitor,
                     &task, AgentMonitorKind::kPageChange));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  auto first = service_->GetMonitors(task->id())[0];
  ASSERT_EQ(first.last_check_status, AgentMonitorCheckStatus::kSucceeded);
  EXPECT_EQ(summary_requests_, 0);
  page_revision_ = 2;
  summary_reply_mode_ = 1;
  monitor = first;
  monitor.next_run = base::Time::Now();
  ASSERT_TRUE(service_->UpsertMonitor(monitor));
  ASSERT_TRUE(base::test::RunUntil([&] {
    const auto current = service_->GetMonitors(task->id())[0];
    return current.last_run > first.last_run &&
           (current.last_value_hash != first.last_value_hash ||
            current.consecutive_failures > 0);
  }));
  const auto second = service_->GetMonitors(task->id())[0];
  ASSERT_EQ(second.last_check_status, AgentMonitorCheckStatus::kSucceeded);
  EXPECT_EQ(summary_requests_, 1);
  EXPECT_FALSE(HasMeaningfulAgentMonitorSummary(second.last_observation));
  EXPECT_TRUE(ReadAgentMonitorSummary(second.last_observation).empty());
  // 内容保持相同，第三轮只读取网页，不再次调用模型。
  monitor = second;
  monitor.next_run = base::Time::Now();
  ASSERT_TRUE(service_->UpsertMonitor(monitor));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return requests_ >= 3 && browser()->GetTabStripModel()->count() == 1;
  }));
  const auto third = service_->GetMonitors(task->id())[0];
  EXPECT_EQ(third.last_check_status, AgentMonitorCheckStatus::kSucceeded);
  EXPECT_EQ(third.last_value_hash, second.last_value_hash);
  EXPECT_EQ(summary_requests_, 1);
  EXPECT_TRUE(summary_requests_valid_);
  EXPECT_TRUE(notifications
                  .GetDisplayedNotificationsForType(
                      NotificationHandler::Type::TRANSIENT)
                  .empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       PageSummaryFailureIsBoundedAndPreservesBaseline) {
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureMonitorSummaryModel();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(
      PrepareMonitor(embedded_test_server()->GetURL("/monitor-page"), &monitor,
                     &task, AgentMonitorKind::kPageChange));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto first = service_->GetMonitors(task->id())[0];
  ASSERT_EQ(first.last_check_status, AgentMonitorCheckStatus::kSucceeded);
  summary_reply_mode_ = 2;
  page_revision_ = 2;
  monitor = first;
  monitor.next_run = base::Time::Now();
  ASSERT_TRUE(service_->UpsertMonitor(monitor));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return service_->GetMonitors(task->id())[0].consecutive_failures == 1;
  }));
  const auto failed = service_->GetMonitors(task->id())[0];
  EXPECT_EQ(failed.last_check_status,
            AgentMonitorCheckStatus::kSummaryUnavailable);
  EXPECT_EQ(failed.last_value_hash, first.last_value_hash);
  EXPECT_EQ(failed.last_observation, first.last_observation);
  EXPECT_EQ(summary_requests_, 2);
  EXPECT_EQ(task->model_calls_used(), 2);
  EXPECT_TRUE(summary_requests_valid_);
  EXPECT_EQ(browser()->GetTabStripModel()->count(), 1);
  EXPECT_TRUE(notifications
                  .GetDisplayedNotificationsForType(
                      NotificationHandler::Type::TRANSIENT)
                  .empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       PausingDuringSummaryDiscardsLateModelResponse) {
  hold_summary_response_ = true;
  net::test_server::ControllableHttpResponse pending(embedded_test_server(),
                                                     "/v1/responses");
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureMonitorSummaryModel();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(
      PrepareMonitor(embedded_test_server()->GetURL("/monitor-page"), &monitor,
                     &task, AgentMonitorKind::kPageChange));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto first = service_->GetMonitors(task->id())[0];
  ASSERT_EQ(first.last_check_status, AgentMonitorCheckStatus::kSucceeded);
  page_revision_ = 2;
  monitor = first;
  monitor.next_run = base::Time::Now();
  ASSERT_TRUE(service_->UpsertMonitor(monitor));
  ASSERT_TRUE(base::test::RunUntil([&] { return pending.has_received_request(); }));
  pending.WaitForRequest();
  EXPECT_EQ(task->model_calls_used(), 1);
  ASSERT_TRUE(service_->SetMonitorPaused(task->id(), monitor.monitor_id, true));
  EXPECT_EQ(browser()->GetTabStripModel()->count(), 1);
  pending.Send(net::HTTP_OK, "application/json",
               R"({"status":"completed","output":[]})");
  pending.Done();
  base::RunLoop().RunUntilIdle();
  const auto paused = service_->GetMonitors(task->id())[0];
  EXPECT_FALSE(paused.enabled);
  EXPECT_EQ(paused.last_value_hash, first.last_value_hash);
  EXPECT_EQ(paused.last_observation, first.last_observation);
  EXPECT_EQ(paused.last_check_status, first.last_check_status);
  EXPECT_EQ(task->model_calls_used(), 1);
  EXPECT_TRUE(notifications
                  .GetDisplayedNotificationsForType(
                      NotificationHandler::Type::TRANSIENT)
                  .empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
}

class AegisAgentMonitorWithoutGlicBrowserTest
    : public AegisAgentUrlMonitorBrowserTest {
 public:
  AegisAgentMonitorWithoutGlicBrowserTest() {
    glic_feature_.InitAndDisableFeature(::features::kGlicActor);
  }

 private:
  base::test::ScopedFeatureList glic_feature_;
};

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       PersistsMeasuredBaselineWithSystemEncryption) {
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int initial_tabs = browser()->GetTabStripModel()->count();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/monitor-page"), &monitor, &task,
      AgentMonitorKind::kPrice, /*session_only=*/false));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto result = service_->GetMonitors(task->id());
  ASSERT_EQ(result.size(), 1u);
  ASSERT_EQ(result[0].last_check_status, AgentMonitorCheckStatus::kSucceeded);
  ASSERT_FALSE(result[0].last_observation.empty());
  ASSERT_FALSE(result[0].last_observation_ciphertext.empty());
  EXPECT_NE(result[0].last_observation, result[0].last_observation_ciphertext);
  base::test::TestFuture<scoped_refptr<os_crypt_async::Encryptor>> ready;
  g_browser_process->os_crypt_async()->GetInstance(ready.GetCallback());
  const auto encryptor = ready.Get();
  ASSERT_TRUE(encryptor);
  std::string plaintext;
  ASSERT_TRUE(encryptor->DecryptString(result[0].last_observation_ciphertext,
                                       &plaintext));
  const auto envelope = base::JSONReader::ReadDict(plaintext, base::JSON_PARSE_RFC);
  ASSERT_TRUE(envelope);
  ASSERT_TRUE(envelope->FindString("observation"));
  ASSERT_TRUE(envelope->FindString("monitor_id"));
  ASSERT_TRUE(envelope->FindString("task_id"));
  ASSERT_TRUE(envelope->FindString("target_hash"));
  EXPECT_EQ(*envelope->FindString("observation"), result[0].last_observation);
  EXPECT_EQ(*envelope->FindString("monitor_id"), monitor.monitor_id);
  EXPECT_EQ(*envelope->FindString("task_id"), task->id());
  EXPECT_EQ(*envelope->FindString("target_hash"), monitor.target_hash);
  base::test::TestFuture<bool> saved;
  service_->FlushTaskStoreForTesting(saved.GetCallback());
  ASSERT_TRUE(saved.Get());
  {
    base::ScopedAllowBlockingForTesting allow_blocking;
    std::string bytes;
    ASSERT_TRUE(
        base::ReadFileToString(browser()->GetProfile()->GetPath().AppendASCII(
                                   "AegisAgentTasks.sqlite"),
                               &bytes));
    EXPECT_EQ(bytes.find(result[0].last_observation), std::string::npos);
    EXPECT_EQ(bytes.find(plaintext), std::string::npos);
  }
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs);
  EXPECT_TRUE(notifications.GetDisplayedNotificationsForType(
      NotificationHandler::Type::TRANSIENT).empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
  ASSERT_TRUE(service_->CancelTask(task->id()));
}

IN_PROC_BROWSER_TEST_F(AegisAgentMonitorWithoutGlicBrowserTest,
                       PageMonitorBlocksForeignRedirectBeforeRequest) {
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int initial_tabs = browser()->GetTabStripModel()->count();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/monitor-redirect"), &monitor, &task,
      AgentMonitorKind::kPageChange));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto result = service_->GetMonitors(task->id())[0];
  EXPECT_EQ(result.last_check_status, AgentMonitorCheckStatus::kRedirectBlocked);
  EXPECT_EQ(result.consecutive_failures, 1);
  EXPECT_TRUE(result.last_value_hash.empty());
  EXPECT_EQ(requests_, 1);
  // 另一个来源虽在原任务范围内，也不能自动成为这个监控的目标。
  EXPECT_EQ(foreign_requests_, 0);
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs);
  EXPECT_TRUE(task->owned_tab_ids().empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
  ASSERT_TRUE(service_->CancelTask(task->id()));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       PausingPageMonitorClosesOnlyItsPendingTab) {
  net::test_server::ControllableHttpResponse response(embedded_test_server(),
                                                      "/pending-page");
  ASSERT_TRUE(embedded_test_server()->Start());
  const int initial_tabs = browser()->GetTabStripModel()->count();
  content::WebContents* original =
      browser()->GetTabStripModel()->GetActiveWebContents();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/pending-page"), &monitor, &task,
      AgentMonitorKind::kPageChange));
  response.WaitForRequest();
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs + 1);
  ASSERT_TRUE(service_->SetMonitorPaused(task->id(), monitor.monitor_id, true));
  response.Send(net::HTTP_OK, "text/html", "<p>不应提交的迟到结果</p>");
  response.Done();
  base::RunLoop().RunUntilIdle();
  const auto result = service_->GetMonitors(task->id())[0];
  EXPECT_FALSE(result.enabled);
  EXPECT_TRUE(result.last_value_hash.empty());
  EXPECT_EQ(result.last_check_status, AgentMonitorCheckStatus::kNotChecked);
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs);
  EXPECT_EQ(browser()->GetTabStripModel()->GetActiveWebContents(), original);
  EXPECT_TRUE(task->owned_tab_ids().empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
  ASSERT_TRUE(service_->CancelTask(task->id()));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       PageMonitorTimesOutAndCleansItsTab) {
  // 产品等待仍为 30 秒；测试应给正常超时回调留下完成清理的时间。
  base::test::ScopedRunLoopTimeout timeout(FROM_HERE, base::Seconds(45));
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int initial_tabs = browser()->GetTabStripModel()->count();
  const base::TimeTicks started = base::TimeTicks::Now();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/monitor-timeout"), &monitor, &task,
      AgentMonitorKind::kPageChange));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto result = service_->GetMonitors(task->id())[0];
  EXPECT_EQ(result.last_check_status, AgentMonitorCheckStatus::kTimeout);
  EXPECT_GE(base::TimeTicks::Now() - started, base::Seconds(30));
  EXPECT_LT(base::TimeTicks::Now() - started, base::Seconds(35));
  EXPECT_EQ(result.consecutive_failures, 1);
  EXPECT_TRUE(result.last_value_hash.empty());
  EXPECT_EQ(requests_, 1);
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs);
  EXPECT_TRUE(task->owned_tab_ids().empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
  ASSERT_TRUE(service_->CancelTask(task->id()));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       PageWithoutPriceDoesNotProducePriceEvidence) {
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int initial_tabs = browser()->GetTabStripModel()->count();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/title1.html"), &monitor, &task,
      AgentMonitorKind::kPrice));
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  const auto result = service_->GetMonitors(task->id());
  ASSERT_EQ(result.size(), 1u);
  EXPECT_EQ(result[0].last_check_status, AgentMonitorCheckStatus::kContentUnavailable);
  EXPECT_TRUE(result[0].last_value_hash.empty());
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs);
  EXPECT_TRUE(task->scope().allowed_tab_ids.empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
  ASSERT_TRUE(service_->CancelTask(task->id()));
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlMonitorBrowserTest,
                       UserTakeoverKeepsMonitorTabAndDiscardsLateResponse) {
  NotificationDisplayServiceTester notifications(browser()->GetProfile());
  net::test_server::ControllableHttpResponse response(embedded_test_server(),
                                                      "/takeover-page");
  ASSERT_TRUE(embedded_test_server()->Start());
  const int initial_tabs = browser()->GetTabStripModel()->count();
  content::WebContents* original =
      browser()->GetTabStripModel()->GetActiveWebContents();
  AgentMonitorDefinition monitor;
  AgentTask* task = nullptr;
  ASSERT_NO_FATAL_FAILURE(PrepareMonitor(
      embedded_test_server()->GetURL("/takeover-page"), &monitor, &task,
      AgentMonitorKind::kPageChange));
  response.WaitForRequest();
  ASSERT_EQ(browser()->GetTabStripModel()->count(), initial_tabs + 1);
  auto* tab = browser()->GetTabStripModel()->GetTabAtIndex(initial_tabs);
  ASSERT_TRUE(tab);
  actor::ActorTask* monitor_actor =
      actor::ActorKeyedService::Get(browser()->GetProfile())
          ->GetTaskFromTab(*tab);
  ASSERT_TRUE(monitor_actor);
  // 通过真实 Actor 用户暂停入口接管，不能用删除监控冒充用户接管。
  monitor_actor->Pause(/*from_actor=*/false, /*cancel_existing_action=*/true);
  ASSERT_NO_FATAL_FAILURE(WaitForCheck(task->id()));
  ASSERT_EQ(browser()->GetTabStripModel()->count(), initial_tabs + 1);
  response.Send(net::HTTP_OK, "text/html", "<p>接管后的迟到正文</p>");
  response.Done();
  ASSERT_TRUE(content::WaitForLoadStop(tab->GetContents()));
  const auto result = service_->GetMonitors(task->id());
  ASSERT_EQ(result.size(), 1u);
  EXPECT_EQ(result[0].last_check_status,
            AgentMonitorCheckStatus::kPageUnavailable);
  EXPECT_TRUE(result[0].last_value_hash.empty());
  EXPECT_EQ(browser()->GetTabStripModel()->GetActiveWebContents(), original);
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs + 1);
  EXPECT_TRUE(task->scope().allowed_tab_ids.empty());
  ASSERT_TRUE(service_->RemoveMonitor(task->id(), monitor.monitor_id));
  ASSERT_TRUE(service_->CancelTask(task->id()));
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tabs + 1);
}

class AegisAgentUrlCheckBrowserTest : public AegisAgentBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    AegisAgentBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("aegis-agent-allow-local-fixture");
  }

  void SetUpOnMainThread() override {
    AegisAgentBrowserTest::SetUpOnMainThread();
    embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
        &AegisAgentUrlCheckBrowserTest::HandleRequest, base::Unretained(this)));
  }

  int request_count() const { return request_count_.load(); }

  int selection_head_count() const { return selection_head_count_.load(); }

 private:
  std::unique_ptr<net::test_server::HttpResponse> HandleRequest(
      const net::test_server::HttpRequest& request) {
    if (request.relative_url.rfind("/selection-live-", 0) == 0) {
      ++request_count_;
      if (request.method == net::test_server::METHOD_HEAD) {
        ++selection_head_count_;
      }
      auto response = std::make_unique<net::test_server::BasicHttpResponse>();
      response->set_code(net::HTTP_OK);
      return response;
    }
    if (request.relative_url.rfind("/rate-limited-", 0) != 0) {
      return nullptr;
    }
    ++request_count_;
    auto response = std::make_unique<net::test_server::BasicHttpResponse>();
    response->set_code(net::HTTP_TOO_MANY_REQUESTS);
    response->AddCustomHeader("Retry-After", "17");
    return response;
  }

  std::atomic<int> request_count_{0};
  std::atomic<int> selection_head_count_{0};
};

AgentTaskScope BookmarkCheckTestScope(int network_budget = 500) {
  AgentTaskScope scope;
  scope.allowed_tools = {"bookmark.list", "bookmark.check_urls"};
  scope.allowed_data_classes = {AgentDataClass::kBookmarks};
  scope.budgets.max_network_requests = network_budget;
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = "http://127.0.0.1:8000/v1";
  scope.model_destination.model = "fixture-model";
  return scope;
}

IN_PROC_BROWSER_TEST_F(
    AegisAgentUrlCheckBrowserTest,
    RuntimeChecks500WithDefaultBudgetAndKeepsNarrowedBudgetPartial) {
  base::test::ScopedRunLoopTimeout timeout(FROM_HERE, base::Seconds(60));
  ASSERT_TRUE(embedded_test_server()->Start());
  Profile* profile = browser()->GetProfile();
  ConfigureAgentModel(profile);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  auto* model = BookmarkModelFactory::GetForBrowserContext(profile);
  ASSERT_TRUE(model);
  bookmarks::test::WaitForBookmarkModelToLoad(model);
  ASSERT_TRUE(model->bookmark_bar_node()->children().empty());
  ASSERT_TRUE(model->other_node()->children().empty());
  ASSERT_TRUE(model->mobile_node()->children().empty());
  base::DictValue expected_nodes;
  for (int index = 0; index < 500; ++index) {
    const GURL url = embedded_test_server()->GetURL(
        "/selection-live-" + base::NumberToString(index));
    const auto* node = model->AddURL(
        model->bookmark_bar_node(), index,
        base::UTF8ToUTF16("链接检查 " + base::NumberToString(index)), url);
    ASSERT_TRUE(node);
    expected_nodes.Set("local:" + node->uuid().AsLowercaseString(), url.spec());
  }
  ASSERT_EQ(expected_nodes.size(), 500u);
  // 前序遍历保留整棵树的身份、父子关系和顺序，也能发现额外新增的目录。
  const auto snapshot_bookmarks = [&]() {
    base::ListValue snapshot;
    const auto append = [&](const auto& self,
                            const bookmarks::BookmarkNode* node) -> void {
      base::DictValue entry;
      entry.Set("id", base::NumberToString(node->id()));
      entry.Set("uuid", node->uuid().AsLowercaseString());
      entry.Set("title", base::UTF16ToUTF8(node->GetTitle()));
      entry.Set("url", node->url().spec());
      entry.Set("parent", node->parent()
                              ? base::NumberToString(node->parent()->id())
                              : std::string());
      snapshot.Append(std::move(entry));
      for (const auto& child : node->children()) {
        self(self, child.get());
      }
    };
    append(append, model->root_node());
    return snapshot;
  };
  const base::ListValue original_bookmarks = snapshot_bookmarks();
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile);
  ASSERT_TRUE(service);
  base::test::TestFuture<bool> storage;
  service->FlushTaskStoreForTesting(storage.GetCallback());
  ASSERT_TRUE(storage.Get());
  const int initial_tab_count = browser()->GetTabStripModel()->count();
  const GURL endpoint("https://api.openai.com/v1/responses");

  // 单场景的断言失败不能跳过其余场景；旧实现也应终止并明确报红。
  const auto run_scenario = [&](bool narrowed, int model_budget) {
    SCOPED_TRACE(narrowed ? "授权前合法缩为500" : "产品默认520");
    SCOPED_TRACE("模型预算：" + base::NumberToString(model_budget));
    const int requests_before = request_count();
    const int heads_before = selection_head_count();
    const std::string task_id = content::EvalJs(panel, R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const {snapshot} = await BrowserProxy.getInstance().handler.createTask(
            '检查我的全部500条书签网址是否可访问，只报告检查结果，不修改书签。',
            0, 1, [], 0);
        return snapshot.taskId || `ERROR:${snapshot.lastError}`;
      })()
    )JS").ExtractString();
    ASSERT_FALSE(task_id.empty());
    ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
    AgentTask* task = service->GetTask(task_id);
    ASSERT_TRUE(task);
    EXPECT_EQ(task->scope().budgets.max_model_calls, 20);
    EXPECT_EQ(task->scope().budgets.max_network_requests, 520);
    const int budget = narrowed ? 500 : 520;
    if (narrowed || model_budget < 20) {
      // 预算属于浏览器授权域，模型计划不能自行设置预算。
      ASSERT_TRUE(service->BeginPlanning(task_id));
      AgentTaskScope scope = task->scope();
      scope.budgets.max_network_requests = budget;
      scope.budgets.max_model_calls = model_budget;
      ASSERT_TRUE(task->AdoptPlanScope(std::move(scope)));
      AgentTaskScope expanded = task->scope();
      expanded.budgets.max_network_requests = 520;
      expanded.budgets.max_model_calls = 20;
      EXPECT_FALSE(task->AdoptPlanScope(std::move(expanded)));
      EXPECT_EQ(task->scope().budgets.max_network_requests, budget);
      EXPECT_EQ(task->scope().budgets.max_model_calls, model_budget);
    }
    network::TestURLLoaderFactory factory;
    service->SetTaskModelClientForTesting(
        task_id,
        std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
    int response_index = 0;
    const auto respond = [&](const char* tool, base::DictValue arguments) {
      // pending_requests 是只读观察；不要在 RunUntil 内调用 NumPending。
      if (!base::test::RunUntil([&]() {
            return !factory.pending_requests()->empty() ||
                   IsTerminalState(task->state());
          }) || factory.pending_requests()->empty()) {
        return false;
      }
      base::DictValue call;
      call.Set("type", "function_call");
      call.Set("call_id", task_id + "-response-" +
                              base::NumberToString(++response_index));
      call.Set("name", tool);
      call.Set("arguments", *base::WriteJson(arguments));
      base::ListValue output;
      output.Append(std::move(call));
      base::DictValue response;
      response.Set("status", "completed");
      response.Set("output", std::move(output));
      return factory.SimulateResponseForPendingRequest(
          endpoint.spec(), *base::WriteJson(response));
    };
    ASSERT_EQ(content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        return (await BrowserProxy.getInstance().handler.requestPlan($1))
            .snapshot.state;
      })()
    )JS", task_id)).ExtractString(), "planning");
    base::DictValue plan;
    plan.Set("schema_version", kAgentSchemaVersion);
    plan.Set("summary", "读取全部书签并检查500条网址，只报告结果");
    base::ListValue steps;
    for (const auto& [id, tool] :
         {std::pair{"list", "bookmark.list"},
          std::pair{"check", "bookmark.check_urls"}}) {
      base::DictValue step;
      step.Set("id", id);
      step.Set("title", std::string(id) == "list" ? "读取全部书签" :
                                                   "检查全部网址");
      step.Set("tool", tool);
      steps.Append(std::move(step));
    }
    plan.Set("steps", std::move(steps));
    ASSERT_TRUE(respond("agent.submit_plan", std::move(plan)));
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return task->state() == AgentTaskState::kAwaitingTaskConsent ||
             IsTerminalState(task->state());
    }));
    ASSERT_EQ(task->state(), AgentTaskState::kAwaitingTaskConsent);
    ASSERT_TRUE(service->GetPlan(task_id));
    EXPECT_EQ(service->GetPlan(task_id)->scope.budgets.max_network_requests,
              budget);
    EXPECT_EQ(service->GetPlan(task_id)->scope.budgets.max_model_calls,
              model_budget);
    ASSERT_EQ(service->GetPlan(task_id)->steps.size(), 2u);
    EXPECT_EQ(task->model_calls_used(), 1);
    EXPECT_EQ(task->network_requests_used(), 1);
    EXPECT_EQ(request_count(), requests_before);
    EXPECT_EQ(task->scope().allowed_tools.size(), 2u);
    EXPECT_TRUE(task->scope().AllowsTool("bookmark.list"));
    EXPECT_TRUE(task->scope().AllowsTool("bookmark.check_urls"));
    // 展开真实计划详情，核对展示的模型及网络预算，再通过 handler 授权。
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return content::EvalJs(panel, content::JsReplace(R"JS(
        (() => {
          const card = document.querySelector('#plan-card');
          const details = card.querySelector('.task-details');
          if (card.hidden || !details || details.hidden) return false;
          details.open = true;
          const scope = document.querySelector('#scope-grid');
          return scope.getBoundingClientRect().height > 0 &&
              scope.innerText.includes($2 + ' model · ' + $1 + ' network');
        })()
      )JS", task->scope().budgets.max_network_requests,
          model_budget)).ExtractBool();
    }));
    EXPECT_TRUE(content::EvalJs(panel, content::JsReplace(R"JS(
      document.querySelector('#scope-grid').innerText.includes(
          $2 + ' model · ' + $1 + ' network')
    )JS", budget, model_budget)).ExtractBool());
    ASSERT_EQ(content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        return (await BrowserProxy.getInstance().handler.consentAndRun($1))
            .snapshot.state;
      })()
    )JS", task_id)).ExtractString(), "running");
    ASSERT_TRUE(respond("bookmark.list", {}));
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return service->FindRecordedResult(task_id, task_id + ":list:1") ||
             IsTerminalState(task->state());
    }));
    const auto* listed =
        service->FindRecordedResult(task_id, task_id + ":list:1");
    ASSERT_TRUE(listed && listed->ok);
    EXPECT_EQ(listed->value.FindBool("truncated"), false);
    EXPECT_EQ(listed->value.FindInt("check_selection_count"), 500);
    const auto* selection = listed->value.FindString("check_selection_ref");
    ASSERT_TRUE(selection);
    if (model_budget == 2) {
      // 规划和 list 耗尽模型预算时，check 尚未执行，不能跳过计划收尾。
      ASSERT_TRUE(base::test::RunUntil([&]() {
        return IsTerminalState(task->state()) ||
               !factory.pending_requests()->empty();
      }));
      EXPECT_TRUE(factory.pending_requests()->empty());
      EXPECT_EQ(task->state(), AgentTaskState::kFailed);
      EXPECT_EQ(task->model_calls_used(), 2);
      EXPECT_EQ(response_index, 2);
      EXPECT_EQ(task->tool_calls_used(), 1);
      EXPECT_EQ(task->network_requests_used(), 2);
      EXPECT_EQ(task->scope().budgets.max_model_calls, 2);
      EXPECT_EQ(task->scope().budgets.max_network_requests, budget);
      EXPECT_EQ(service->GetPlan(task_id)->scope.budgets.max_model_calls, 2);
      EXPECT_EQ(service->GetPlan(task_id)->scope.budgets.max_network_requests,
                budget);
      EXPECT_EQ(service->GetPlan(task_id)->steps.size(), 2u);
      EXPECT_FALSE(service->FindRecordedResult(task_id, task_id + ":check:1"));
      EXPECT_FALSE(service->GetCompletionSummary(task_id));
      for (const auto& event : task->events()) {
        EXPECT_NE(event.to, AgentTaskState::kCompleted);
      }
      EXPECT_EQ(request_count(), requests_before);
      EXPECT_EQ(selection_head_count(), heads_before);
      EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task_id));
      EXPECT_EQ(snapshot_bookmarks(), original_bookmarks);
      EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count);
      ASSERT_TRUE(base::test::RunUntil([&]() {
        return content::EvalJs(panel, content::JsReplace(R"JS(
          (async () => {
            const {BrowserProxy} = await import('./browser_proxy.js');
            const {loadTimeData} = await import('//resources/js/load_time_data.js');
            const {snapshot} = await BrowserProxy.getInstance().handler.getSnapshot();
            return snapshot.taskId === $1 && snapshot.state === 'failed' &&
                !snapshot.resultOutcome && !snapshot.resultSummary &&
                snapshot.unfinishedItems.length === 0 &&
                document.querySelector('#status').textContent ===
                    loadTimeData.getString('statusFailed') &&
                document.querySelector('#result-card').hidden;
          })()
        )JS", task_id)).ExtractBool();
      }));
      return;
    }
    base::DictValue check;
    check.Set("selection_ref", *selection);
    ASSERT_TRUE(respond("bookmark.check_urls", std::move(check)));
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return service->FindRecordedResult(task_id, task_id + ":check:1") ||
             IsTerminalState(task->state());
    }));
    const auto* checked =
        service->FindRecordedResult(task_id, task_id + ":check:1");
    ASSERT_TRUE(checked && checked->ok);
    // 规划、list、check 共三次真实模型请求；耗尽场景不补发完成请求。
    const int attempted = narrowed ? 497 : 500;
    EXPECT_EQ(checked->value.FindInt("selected_count"), 500);
    EXPECT_EQ(checked->value.FindInt("attempted_count"), attempted);
    EXPECT_EQ(checked->value.FindBool("list_truncated"), false);
    const auto* checked_selection =
        checked->value.FindString("selection_ref");
    ASSERT_TRUE(checked_selection);
    EXPECT_EQ(*checked_selection, *selection);
    const auto* counts = checked->value.FindDict("classification_counts");
    ASSERT_TRUE(counts);
    EXPECT_EQ(counts->FindInt("live"), attempted);
    EXPECT_EQ(counts->FindInt("not_checked").value_or(0), 500 - attempted);
    const auto* results = checked->value.FindList("results");
    ASSERT_TRUE(results);
    ASSERT_EQ(results->size(), 500u);
    base::DictValue seen;
    for (const auto& result : *results) {
      const auto& value = result.GetDict();
      const auto* node_id = value.FindString("node_id");
      const auto* classification = value.FindString("classification");
      ASSERT_TRUE(node_id && classification);
      ASSERT_TRUE(expected_nodes.contains(*node_id));
      EXPECT_FALSE(seen.contains(*node_id));
      seen.Set(*node_id, true);
      EXPECT_TRUE(*classification == "live" ||
                  (narrowed && *classification == "not_checked"));
      EXPECT_EQ(value.FindInt("http_status"),
                *classification == "live" ? 200 : 0);
    }
    EXPECT_EQ(request_count() - requests_before, attempted);
    EXPECT_EQ(selection_head_count() - heads_before, attempted);
    if (!narrowed && model_budget > 3) {
      base::DictValue completion;
      completion.Set("outcome", "completed");
      completion.Set("summary", "全部500条书签网址均可访问，书签未修改。");
      completion.Set("source_urls", base::ListValue());
      completion.Set("unfinished_items", base::ListValue());
      ASSERT_TRUE(respond("agent.complete", std::move(completion)));
    }
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return IsTerminalState(task->state()) ||
             !factory.pending_requests()->empty();
    }));
    // 若耗尽后仍请求模型，立即报错；不能永远等一个没有预算的完成响应。
    EXPECT_TRUE(factory.pending_requests()->empty());
    EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
    EXPECT_EQ(task->model_calls_used(), narrowed || model_budget == 3 ? 3 : 4);
    EXPECT_EQ(response_index, task->model_calls_used());
    EXPECT_EQ(task->tool_calls_used(), 2);
    EXPECT_EQ(task->network_requests_used(),
              attempted + task->model_calls_used());
    EXPECT_EQ(task->network_requests_used(),
              narrowed ? 500 : (model_budget == 3 ? 503 : 504));
    EXPECT_EQ(task->scope().budgets.max_model_calls, model_budget);
    EXPECT_EQ(service->GetPlan(task_id)->scope.budgets.max_model_calls,
              model_budget);
    EXPECT_EQ(task->scope().budgets.max_network_requests, budget);
    EXPECT_EQ(service->GetPlan(task_id)->scope.budgets.max_network_requests,
              budget);
    EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task_id));
    EXPECT_EQ(snapshot_bookmarks(), original_bookmarks);
    EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count);
    const auto* completion = service->GetCompletionSummary(task_id);
    ASSERT_TRUE(completion)
        << "检查步骤完成后必须保留浏览器检查证据及真实完成程度";
    EXPECT_EQ(completion->outcome, narrowed ? "partial" : "completed");
    EXPECT_EQ(completion->unfinished_items.empty(), !narrowed);
    EXPECT_NE(completion->summary.find("实际发起检查 " +
                                       base::NumberToString(attempted) + " 条"),
              std::string::npos);
    if (narrowed) {
      EXPECT_NE(completion->summary.find("预算不足，未检查：3 条"),
                std::string::npos);
    }
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return content::EvalJs(panel, content::JsReplace(R"JS(
        (async () => {
          const {BrowserProxy} = await import('./browser_proxy.js');
          const {loadTimeData} = await import('//resources/js/load_time_data.js');
          const {snapshot} = await BrowserProxy.getInstance().handler.getSnapshot();
          const card = document.querySelector('#result-card');
          const unfinished = document.querySelector('#unfinished-items');
          return snapshot.taskId === $1 && snapshot.state === 'completed' &&
              snapshot.resultOutcome === ($2 ? 'partial' : 'completed') &&
              document.querySelector('#status').textContent ===
                  loadTimeData.getString($2 ? 'statusPartial' : 'statusCompleted') &&
              !card.hidden && card.dataset.outcome === snapshot.resultOutcome &&
              document.querySelector('#result-summary').textContent === $3 &&
              unfinished.children.length === snapshot.unfinishedItems.length &&
              ($2 ? unfinished.children.length > 0 :
                    unfinished.children.length === 0);
        })()
      )JS", task_id, narrowed, completion->summary)).ExtractBool();
    }));
  };
  run_scenario(false, 20);
  run_scenario(true, 20);
  run_scenario(false, 3);
  run_scenario(false, 2);
  EXPECT_EQ(snapshot_bookmarks(), original_bookmarks);
}

IN_PROC_BROWSER_TEST_F(
    AegisAgentUrlCheckBrowserTest,
    SelectionChecks500AndRejectsForeignStaleAndForgottenRefs) {
  ASSERT_TRUE(embedded_test_server()->Start());
  auto* model =
      BookmarkModelFactory::GetForBrowserContext(browser()->GetProfile());
  ASSERT_TRUE(model);
  bookmarks::test::WaitForBookmarkModelToLoad(model);
  for (int index = 0; index < 500; ++index) {
    ASSERT_TRUE(model->AddURL(
        model->bookmark_bar_node(), index, u"合成收藏",
        embedded_test_server()->GetURL("/selection-live-" +
                                       base::NumberToString(index))));
  }
  AgentTask task("selection-owner", "检查全部收藏", AgentMode::kAsk,
                 BookmarkCheckTestScope());
  AgentTask foreign("another-task", "另一任务", AgentMode::kAsk,
                    BookmarkCheckTestScope());
  AegisBrowserTools tools(browser()->GetProfile());
  auto execute = [&](AgentTask* owner, const AgentToolCall& call) {
    base::test::TestFuture<AgentToolResult> future;
    tools.Execute(owner, call, future.GetCallback());
    return future.Take();
  };
  AgentToolCall list;
  list.action_id = "list-selection";
  list.tool_name = "bookmark.list";
  auto listed = execute(&task, list);
  ASSERT_TRUE(listed.ok);
  ASSERT_EQ(listed.value.FindInt("check_selection_count"), 500);
  const auto* reference = listed.value.FindString("check_selection_ref");
  ASSERT_TRUE(reference);
  AgentToolCall check;
  check.action_id = "check-selection";
  check.tool_name = "bookmark.check_urls";
  check.arguments.Set("selection_ref", *reference);
  EXPECT_FALSE(execute(&foreign, check).ok);
  check.arguments.Set("node_ids", base::ListValue());
  EXPECT_FALSE(execute(&task, check).ok);
  check.arguments.Remove("node_ids");
  EXPECT_EQ(request_count(), 0);
  auto checked = execute(&task, check);
  ASSERT_TRUE(checked.ok) << checked.message;
  ASSERT_TRUE(checked.value.FindList("results"));
  EXPECT_EQ(checked.value.FindList("results")->size(), 500u);
  EXPECT_EQ(checked.value.FindInt("selected_count"), 500);
  EXPECT_EQ(checked.value.FindInt("attempted_count"), 500);
  EXPECT_EQ(checked.value.FindDict("classification_counts")->FindInt("live"),
            500);
  EXPECT_EQ(request_count(), 500);
  AgentToolRegistry registry;
  AgentResultVerifier verifier;
  EXPECT_TRUE(
      verifier.Verify(task, check, *registry.Find(check.tool_name), checked)
          .accepted);
  // 所有收藏在检测前再次绑定；检测后的编辑也使旧选择失效。
  model->SetURL(model->bookmark_bar_node()->children()[0].get(),
                embedded_test_server()->GetURL("/selection-live-changed"),
                bookmarks::metrics::BookmarkEditSource::kOther);
  EXPECT_FALSE(execute(&task, check).ok);
  auto fresh = execute(&task, list);
  ASSERT_TRUE(fresh.ok);
  EXPECT_FALSE(execute(&task, check).ok);
  check.arguments.Set("selection_ref",
                      *fresh.value.FindString("check_selection_ref"));
  tools.ForgetTask(task.id());
  EXPECT_FALSE(execute(&task, check).ok);
  EXPECT_EQ(request_count(), 500);
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlCheckBrowserTest,
                       SelectionPreservesResultsWhenBudgetOrScopeBlocksRest) {
  ASSERT_TRUE(embedded_test_server()->Start());
  auto* model =
      BookmarkModelFactory::GetForBrowserContext(browser()->GetProfile());
  ASSERT_TRUE(model);
  bookmarks::test::WaitForBookmarkModelToLoad(model);
  model->AddURL(model->bookmark_bar_node(), 0, u"可检查一",
                embedded_test_server()->GetURL("/selection-live-one"));
  model->AddURL(model->bookmark_bar_node(), 1, u"预算外",
                embedded_test_server()->GetURL("/selection-live-two"));
  model->AddURL(model->bookmark_bar_node(), 2, u"禁止的内网",
                GURL("http://10.0.0.1/private"));
  AgentTask task("selection-budget", "检查全部收藏", AgentMode::kAsk,
                 BookmarkCheckTestScope(1));
  AegisBrowserTools tools(browser()->GetProfile());
  AgentToolCall list;
  list.action_id = "list-selection";
  list.tool_name = "bookmark.list";
  base::test::TestFuture<AgentToolResult> listed;
  tools.Execute(&task, list, listed.GetCallback());
  ASSERT_TRUE(listed.Get().ok);
  AgentToolCall check;
  check.action_id = "check-selection";
  check.tool_name = "bookmark.check_urls";
  check.arguments.Set("selection_ref",
                      *listed.Get().value.FindString("check_selection_ref"));
  base::test::TestFuture<AgentToolResult> checked;
  tools.Execute(&task, check, checked.GetCallback());
  const auto& result = checked.Get();
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_EQ(result.value.FindInt("selected_count"), 3);
  EXPECT_EQ(result.value.FindInt("attempted_count"), 1);
  const auto* counts = result.value.FindDict("classification_counts");
  ASSERT_TRUE(counts);
  EXPECT_EQ(counts->FindInt("live"), 1);
  EXPECT_EQ(counts->FindInt("not_checked"), 1);
  EXPECT_EQ(counts->FindInt("scope_blocked"), 1);
  EXPECT_EQ(request_count(), 1);
  AgentToolRegistry registry;
  AgentResultVerifier verifier;
  EXPECT_TRUE(
      verifier.Verify(task, check, *registry.Find(check.tool_name), result)
          .accepted);
}

IN_PROC_BROWSER_TEST_F(AegisAgentUrlCheckBrowserTest,
                       RateLimitCompletesAllPendingSameOriginBookmarks) {
  ASSERT_TRUE(embedded_test_server()->Start());
  bookmarks::BookmarkModel* model =
      BookmarkModelFactory::GetForBrowserContext(browser()->GetProfile());
  ASSERT_TRUE(model);
  bookmarks::test::WaitForBookmarkModelToLoad(model);

  base::ListValue node_ids;
  for (int index = 0; index < 4; ++index) {
    const bookmarks::BookmarkNode* node = model->AddURL(
        model->bookmark_bar_node(), index, u"Rate-limited fixture",
        embedded_test_server()->GetURL("/rate-limited-" +
                                       base::NumberToString(index)));
    ASSERT_TRUE(node);
    node_ids.Append("local:" + node->uuid().AsLowercaseString());
  }

  AgentTaskScope scope;
  scope.allowed_tools = {"bookmark.check_urls"};
  scope.allowed_data_classes = {AgentDataClass::kBookmarks};
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = "http://127.0.0.1:8000/v1";
  scope.model_destination.model = "fixture-model";
  ASSERT_TRUE(scope.IsValid());
  AgentTask task("rate-limit-task", "check fixture bookmarks", AgentMode::kAsk,
                 std::move(scope));
  AegisBrowserTools tools(browser()->GetProfile());
  AgentToolCall call;
  call.action_id = "check-rate-limited-bookmarks";
  call.tool_name = "bookmark.check_urls";
  call.arguments.Set("node_ids", std::move(node_ids));

  base::test::TestFuture<AgentToolResult> future;
  tools.Execute(&task, call, future.GetCallback());
  AgentToolResult result = future.Take();
  ASSERT_TRUE(result.ok) << result.message;
  const base::ListValue* values = result.value.FindList("results");
  ASSERT_TRUE(values);
  ASSERT_EQ(values->size(), 4u);
  for (const base::Value& value : *values) {
    const base::DictValue& checked = value.GetDict();
    const std::string* classification = checked.FindString("classification");
    ASSERT_TRUE(classification);
    EXPECT_EQ(*classification, "rate_limited");
    EXPECT_EQ(checked.FindInt("http_status"), 429);
    EXPECT_EQ(checked.FindInt("retry_after_seconds"), 17);
  }
  EXPECT_EQ(request_count(), 1);
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       DueMonitorValidatesBeforeReleasingAdoptedTab) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL target = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), target));
  chrome::AddTabAt(browser(), target, -1, true);
  ASSERT_TRUE(content::WaitForLoadStop(
      browser()->GetTabStripModel()->GetActiveWebContents()));
  ASSERT_EQ(browser()->GetTabStripModel()->count(), 2);

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  // 等待异步恢复结束，避免恢复空存储时覆盖刚创建的测试监控。
  base::test::TestFuture<bool> storage_loaded;
  service->FlushTaskStoreForTesting(storage_loaded.GetCallback());
  ASSERT_TRUE(storage_loaded.Get());
  const int32_t first_tab_id =
      browser()->GetTabStripModel()->GetTabAtIndex(0)->GetHandle().raw_value();
  for (bool needs_temporary_tab : {false, true}) {
    SCOPED_TRACE(needs_temporary_tab);
    const int32_t original_tab_id =
        browser()
            ->GetTabStripModel()
            ->GetTabAtIndex(needs_temporary_tab ? 1 : 0)
            ->GetHandle()
            .raw_value();
    AgentTaskScope scope;
    scope.allowed_origins = {url::Origin::Create(target)};
    scope.allowed_tab_ids = {original_tab_id};
    scope.allowed_tools = {"page.observe", "monitor.create"};
    scope.allowed_data_classes = {AgentDataClass::kPublicPage};
    scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
    scope.model_destination.provider = "openai";
    scope.model_destination.endpoint = "http://127.0.0.1:8000/v1";
    scope.model_destination.model = "fixture-model";
    AgentTask* task =
        service->CreateTask("监控同一资料页，校验完成后释放临时标签读取范围",
                            AgentMode::kAutomate, std::move(scope));
    ASSERT_TRUE(task);
    ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "固定测试计划"));
    ASSERT_TRUE(task->TransitionTo(AgentTaskState::kAwaitingTaskConsent,
                                   "测试计划已准备"));
    ASSERT_TRUE(service->GrantTaskConsent(task->id()));

    if (!needs_temporary_tab) {
      // 先验证夹具可以被真实 Actor 读取，读取失败不应冒充生命周期回归。
      AgentToolCall probe;
      probe.action_id = "monitor-observation-precondition";
      probe.tool_name = "page.observe";
      probe.arguments.Set("tab_id", original_tab_id);
      probe.committed_url = target;
      base::test::TestFuture<AgentToolResult> observed;
      service->actor_bridge_for_testing().ExecutePageTool(
          task->id(), probe, observed.GetCallback());
      ASSERT_TRUE(observed.Get().ok) << observed.Get().message;
    }

    AgentMonitorDefinition monitor;
    monitor.monitor_id = "monitor-tab-lifetime-" + task->id();
    monitor.task_id = task->id();
    monitor.origin = url::Origin::Create(target);
    monitor.target_url = target;
    monitor.target_hash = "fixture-target-hash";
    monitor.session_only = true;
    monitor.next_run = base::Time::Now();
    ASSERT_TRUE(service->UpsertMonitor(monitor));
    ASSERT_TRUE(base::test::RunUntil([&]() {
      const auto monitors = service->GetMonitors(task->id());
      return monitors.size() == 1u &&
             (!monitors[0].enabled || !monitors[0].last_value_hash.empty() ||
              monitors[0].consecutive_failures > 0);
    }));
    const auto completed = service->GetMonitors(task->id());
    ASSERT_EQ(completed.size(), 1u);
    EXPECT_TRUE(completed[0].enabled);
    EXPECT_EQ(completed[0].consecutive_failures, 0);
    EXPECT_FALSE(completed[0].last_value_hash.empty());
    // 正常校验之后仍须释放临时范围，不能靠永久扩大授权修复误拒绝。
    EXPECT_EQ(task->AllowsTab(first_tab_id), !needs_temporary_tab);
    EXPECT_TRUE(task->AllowsTab(original_tab_id));
    ASSERT_TRUE(service->RemoveMonitor(task->id(), monitor.monitor_id));
    ASSERT_TRUE(service->CancelTask(task->id()));
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ObservedDocumentExpiresOnReloadNavigationAndCancel) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/section-body") {
          return nullptr;
        }
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_content_type("text/html; charset=utf-8");
        response->set_content(
            "<!doctype html><meta charset=utf-8><title>章节验收资料</title>"
            "<main><h1>章节验收资料</h1><h2>事实一</h2>"
            "<p>本轮包含 38 个受控源文件。</p><h2>事实二</h2>"
            "<p>原生浏览器回归共有 53 项，全部通过。</p>"
            "<h2>只有标题</h2><h2>其他章节</h2><p>独立正文。</p>"
            "<iframe srcdoc='<p>跨框架内容不得读取</p>'></iframe>"
            "</main>");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL target = embedded_test_server()->GetURL("/section-body");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), target));
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  const int32_t tab_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  AgentTaskScope scope;
  scope.allowed_origins = {url::Origin::Create(target)};
  scope.allowed_tab_ids = {tab_id};
  scope.allowed_tools = {"page.observe", "page.extract"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage};
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = "http://127.0.0.1:8000/v1";
  scope.model_destination.model = "fixture-model";
  AgentTask* task = service->CreateTask("验证观察文档的生命周期",
                                        AgentMode::kAsk, std::move(scope));
  ASSERT_TRUE(task);
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "测试计划"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kAwaitingTaskConsent,
                                 "只读计划已准备"));
  ASSERT_TRUE(service->GrantTaskConsent(task->id()));
  AgentToolCall call;
  call.action_id = "observe-sections";
  call.tool_name = "page.observe";
  call.arguments.Set("tab_id", tab_id);
  call.committed_url = target;
  base::test::TestFuture<AgentToolResult> observed;
  auto& bridge = service->actor_bridge_for_testing();
  bridge.ExecutePageTool(task->id(), call, observed.GetCallback());
  ASSERT_TRUE(observed.Get().ok) << observed.Get().message;
  call.document = bridge.LastDocument(task->id(), tab_id);
  ASSERT_TRUE(call.document);
  const std::string original_token = call.document->document_token;
  EXPECT_TRUE(bridge.IsObservedDocumentCurrent(task->id(), tab_id, original_token));
  EXPECT_FALSE(bridge.IsObservedDocumentCurrent(task->id(), tab_id, "错误 token"));
  // 同网址的新文档也必须让旧观察失效。
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), target));
  EXPECT_FALSE(bridge.IsObservedDocumentCurrent(task->id(), tab_id, original_token));
  call.action_id = "observe-reloaded-document";
  call.document.reset();
  base::test::TestFuture<AgentToolResult> refreshed;
  bridge.ExecutePageTool(task->id(), call, refreshed.GetCallback());
  ASSERT_TRUE(refreshed.Get().ok) << refreshed.Get().message;
  const auto latest = bridge.LastDocument(task->id(), tab_id);
  ASSERT_TRUE(latest);
  EXPECT_NE(latest->document_token, original_token);
  EXPECT_TRUE(bridge.IsObservedDocumentCurrent(task->id(), tab_id, latest->document_token));
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  EXPECT_FALSE(bridge.IsObservedDocumentCurrent(task->id(), tab_id, latest->document_token));
  EXPECT_TRUE(service->CancelTask(task->id()));
  EXPECT_FALSE(bridge.IsObservedDocumentCurrent(task->id(), tab_id, latest->document_token));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       PageExtractionReturnsSectionBodyNotHeadingLabels) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/section-body") {
          return nullptr;
        }
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_content_type("text/html; charset=utf-8");
        response->set_content(
            "<!doctype html><meta charset=utf-8><title>章节验收资料</title>"
            "<main><h1>章节验收资料</h1><h2>事实一</h2>"
            "<p>本轮包含 38 个受控源文件。</p><h2>事实二</h2>"
            "<p>原生浏览器回归共有 53 项，全部通过。</p>"
            "<h2>只有标题</h2><h2>其他章节</h2><p>独立正文。</p>"
            "<iframe srcdoc='<p>跨框架内容不得读取</p>'></iframe>"
            "</main>");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL target = embedded_test_server()->GetURL("/section-body");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), target));
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  const int32_t tab_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  AgentTaskScope scope;
  scope.allowed_origins = {url::Origin::Create(target)};
  scope.allowed_tab_ids = {tab_id};
  scope.allowed_tools = {"page.observe", "page.extract"};
  scope.allowed_data_classes = {AgentDataClass::kPublicPage};
  scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
  scope.model_destination.provider = "openai";
  scope.model_destination.endpoint = "http://127.0.0.1:8000/v1";
  scope.model_destination.model = "fixture-model";
  AgentTask* task = service->CreateTask("提取章节正文而不是标题",
                                        AgentMode::kAsk, std::move(scope));
  ASSERT_TRUE(task);
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "测试计划"));
  ASSERT_TRUE(task->TransitionTo(AgentTaskState::kAwaitingTaskConsent,
                                 "只读计划已准备"));
  ASSERT_TRUE(service->GrantTaskConsent(task->id()));
  AgentToolCall call;
  call.action_id = "observe-sections";
  call.tool_name = "page.observe";
  call.arguments.Set("tab_id", tab_id);
  call.committed_url = target;
  base::test::TestFuture<AgentToolResult> observed;
  auto& bridge = service->actor_bridge_for_testing();
  bridge.ExecutePageTool(task->id(), call, observed.GetCallback());
  ASSERT_TRUE(observed.Get().ok) << observed.Get().message;
  call.document = bridge.LastDocument(task->id(), tab_id);
  ASSERT_TRUE(call.document);
  call.action_id = "extract-sections";
  call.tool_name = "page.extract";
  call.arguments.Set("document_token", call.document->document_token);
  call.arguments.Set("kind", "article");
  base::ListValue requested;
  for (const char* field :
       {"事实一", "事实二", "只有标题", "title", "summary", "不存在字段"}) {
    requested.Append(field);
  }
  call.arguments.Set("fields", std::move(requested));
  base::test::TestFuture<AgentToolResult> extracted;
  bridge.ExecutePageTool(task->id(), call, extracted.GetCallback());
  ASSERT_TRUE(extracted.Get().ok) << extracted.Get().message;
  const auto* extracted_nodes = extracted.Get().value.FindList("nodes");
  ASSERT_TRUE(extracted_nodes);
  bool saw_main_heading = false;
  bool saw_section_heading = false;
  bool saw_body = false;
  for (const auto& node_value : *extracted_nodes) {
    const auto& node = node_value.GetDict();
    const auto* text = node.FindString("text");
    if (!text)
      continue;
    if (*text == "章节验收资料") {
      EXPECT_EQ(node.FindBool("text_is_heading"), true);
      ASSERT_TRUE(node.FindString("text_size"));
      EXPECT_EQ(*node.FindString("text_size"), "XL");
      saw_main_heading = true;
    } else if (*text == "事实一") {
      EXPECT_EQ(node.FindBool("text_is_heading"), true);
      ASSERT_TRUE(node.FindString("text_size"));
      EXPECT_EQ(*node.FindString("text_size"), "L");
      saw_section_heading = true;
    } else if (*text == "本轮包含 38 个受控源文件。") {
      EXPECT_EQ(node.FindBool("text_is_heading"), false);
      saw_body = true;
    }
  }
  EXPECT_TRUE(saw_main_heading && saw_section_heading && saw_body);
  const base::ListValue* fields =
      extracted.Get().value.FindListByDottedPath("extraction.fields");
  ASSERT_TRUE(fields && fields->size() == 6u);
  const std::string* first = (*fields)[0].GetDict().FindString("value");
  const std::string* second = (*fields)[1].GetDict().FindString("value");
  const std::string* title = (*fields)[3].GetDict().FindString("value");
  ASSERT_TRUE(first && second && title);
  EXPECT_EQ(*first, "本轮包含 38 个受控源文件。");
  EXPECT_EQ(*second, "原生浏览器回归共有 53 项，全部通过。");
  EXPECT_EQ((*fields)[2].GetDict().FindBool("resolved"), false);
  EXPECT_EQ(*title, "章节验收资料");
  EXPECT_EQ((*fields)[5].GetDict().FindBool("resolved"), false);
  const std::string* body = (*fields)[4].GetDict().FindString("value");
  ASSERT_TRUE(body);
  EXPECT_NE(body->find("38 个受控源文件"), std::string::npos);
  EXPECT_NE(body->find("53 项"), std::string::npos);
  EXPECT_EQ(body->find("跨框架内容不得读取"), std::string::npos);
  EXPECT_TRUE(service->CancelTask(task->id()));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ProfileIsolationAndRestrictedProfiles) {
  Profile* regular = browser()->GetProfile();
  ASSERT_TRUE(regular->IsRegularProfile());
  AegisAgentService* service = AegisAgentServiceFactory::GetForProfile(regular);
  ASSERT_TRUE(service);
  EXPECT_TRUE(service->IsEnabled());
  EXPECT_TRUE(IsAegisAgentSidePanelSupported(regular));
  EXPECT_TRUE(AgentEntry(browser()));
  EXPECT_TRUE(chrome::IsCommandEnabled(browser(), IDC_SHOW_AEGIS));

  Browser* otr_browser = CreateIncognitoBrowser(regular);
  ASSERT_TRUE(otr_browser);
  EXPECT_TRUE(otr_browser->GetProfile()->IsOffTheRecord());
  EXPECT_TRUE(IsAegisAgentSidePanelSupported(otr_browser->GetProfile()));
  EXPECT_TRUE(AgentEntry(otr_browser));
  EXPECT_TRUE(chrome::IsCommandEnabled(otr_browser, IDC_SHOW_AEGIS));
  AegisAgentService* otr_service =
      AegisAgentServiceFactory::GetForProfile(otr_browser->GetProfile());
  ASSERT_TRUE(otr_service);
  EXPECT_NE(service, otr_service);
  EXPECT_EQ(otr_browser->GetProfile(), otr_service->profile());
  EXPECT_TRUE(otr_service->IsEnabled());
  EXPECT_TRUE(otr_service->actor_bridge_for_testing().IsAvailable());
  EXPECT_EQ(0u, otr_service->task_count_for_testing());

#if !BUILDFLAG(IS_CHROMEOS)
  ProfileManager* profile_manager = g_browser_process->profile_manager();
  ASSERT_TRUE(profile_manager);
  Profile* second = &profiles::testing::CreateProfileSync(
      profile_manager, profile_manager->GenerateNextProfileDirectoryPath());
  second->GetPrefs()->SetBoolean(prefs::kAgentEnabled, true);
  Browser* second_browser = CreateBrowser(second);
  ASSERT_TRUE(second_browser);
  AegisAgentService* second_service =
      AegisAgentServiceFactory::GetForProfile(second);
  ASSERT_TRUE(second_service);
  EXPECT_NE(second_service, service);
  EXPECT_EQ(second_service->task_count_for_testing(), 0u);
  EXPECT_TRUE(AgentEntry(second_browser));
  EXPECT_TRUE(chrome::IsCommandEnabled(second_browser, IDC_SHOW_AEGIS));

  const base::FilePath system_path = ProfileManager::GetSystemProfilePath();
  Profile* system = profile_manager->GetProfileByPath(system_path);
  if (!system) {
    system =
        &profiles::testing::CreateProfileSync(profile_manager, system_path);
  }
  ASSERT_TRUE(system->IsSystemProfile());
  system->GetPrefs()->SetBoolean(prefs::kAgentEnabled, true);
  EXPECT_FALSE(IsAegisAgentSidePanelSupported(system));
  EXPECT_EQ(AegisAgentServiceFactory::GetForProfile(system), nullptr);

  base::test::TestFuture<BrowserWindowInterface*> guest_future;
  profiles::SwitchToGuestProfile(guest_future.GetCallback());
  BrowserWindowInterface* guest_browser = guest_future.Get();
  ASSERT_TRUE(guest_browser);
  ASSERT_TRUE(guest_browser->GetProfile()->IsGuestSession());
  EXPECT_FALSE(IsAegisAgentSidePanelSupported(guest_browser->GetProfile()));
  EXPECT_FALSE(AgentEntry(guest_browser));
  EXPECT_FALSE(chrome::IsCommandEnabled(guest_browser, IDC_SHOW_AEGIS));
  EXPECT_EQ(
      AegisAgentServiceFactory::GetForProfile(guest_browser->GetProfile()),
      nullptr);
#endif
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       IncognitoPanelCreatesMemoryOnlyIsolatedTask) {
  Profile* regular_profile = browser()->GetProfile();
  AegisAgentService* regular_service =
      AegisAgentServiceFactory::GetForProfile(regular_profile);
  ASSERT_TRUE(regular_service);
  EXPECT_FALSE(regular_service->task_store_is_in_memory_for_testing());
  const size_t regular_task_count = regular_service->task_count_for_testing();

  Browser* incognito_browser = CreateIncognitoBrowser(regular_profile);
  ASSERT_TRUE(incognito_browser);
  Profile* incognito_profile = incognito_browser->GetProfile();
  ASSERT_TRUE(incognito_profile->IsIncognitoProfile());
  ASSERT_TRUE(incognito_profile->IsPrimaryOTRProfile());
  ConfigureAgentModel(incognito_profile);

  AegisAgentService* incognito_service =
      AegisAgentServiceFactory::GetForProfile(incognito_profile);
  ASSERT_TRUE(incognito_service);
  EXPECT_NE(regular_service, incognito_service);
  EXPECT_TRUE(incognito_service->task_store_is_in_memory_for_testing());
  const size_t incognito_task_count =
      incognito_service->task_count_for_testing();

  content::WebContents* panel = ShowAgentPanel(incognito_browser);
  ASSERT_TRUE(panel);
  EXPECT_EQ(panel->GetLastCommittedURL(),
            GURL(chrome::kChromeUIUntrustedAegisAgentURL));
  ASSERT_TRUE(panel->GetWebUI());
  EXPECT_TRUE(content::EvalJs(panel, R"JS(
    document.readyState === 'complete' &&
        !!document.querySelector('#goal') &&
        !!document.querySelector('#plan-button')
  )JS")
                  .ExtractBool());

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler.createTask(
          'organize my bookmarks with a preview', 1, 1, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;

  EXPECT_EQ(incognito_service->task_count_for_testing(),
            incognito_task_count + 1u);
  EXPECT_TRUE(incognito_service->GetTask(task_id));
  EXPECT_EQ(regular_service->task_count_for_testing(), regular_task_count);
  EXPECT_EQ(regular_service->GetTask(task_id), nullptr);
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       IncognitoContextMenuInvokesItsOwnAgent) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL regular_url = embedded_test_server()->GetURL("/title1.html");
  const GURL private_url = embedded_test_server()->GetURL("/title2.html");
  Profile* regular_profile = browser()->GetProfile();
  regular_profile->GetPrefs()->SetBoolean(prefs::kAgentEnabled, true);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), regular_url));

  std::unique_ptr<TestRenderViewContextMenu> regular_menu =
      CreateAegisContextMenu(browser());
  EXPECT_TRUE(
      regular_menu->IsItemPresent(IDC_CONTENT_CONTEXT_SEND_TO_AEGIS_AGENT));
  EXPECT_TRUE(
      regular_menu->IsItemEnabled(IDC_CONTENT_CONTEXT_SEND_TO_AEGIS_AGENT));

  Browser* incognito_browser = CreateIncognitoBrowser(regular_profile);
  ASSERT_TRUE(incognito_browser);
  Profile* incognito_profile = incognito_browser->GetProfile();
  incognito_profile->GetPrefs()->SetBoolean(prefs::kAgentEnabled, true);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(incognito_browser, private_url));
  AegisAgentService* incognito_service =
      AegisAgentServiceFactory::GetForProfile(incognito_profile);
  ASSERT_TRUE(incognito_service);

  std::unique_ptr<TestRenderViewContextMenu> incognito_menu =
      CreateAegisContextMenu(incognito_browser);
  ASSERT_TRUE(
      incognito_menu->IsItemPresent(IDC_CONTENT_CONTEXT_SEND_TO_AEGIS_AGENT));
  ASSERT_TRUE(
      incognito_menu->IsItemEnabled(IDC_CONTENT_CONTEXT_SEND_TO_AEGIS_AGENT));
  incognito_menu->ExecuteCommand(IDC_CONTENT_CONTEXT_SEND_TO_AEGIS_AGENT, 0);

  const AgentInvocationContext* invocation =
      incognito_service->PendingInvocationContext();
  ASSERT_TRUE(invocation);
  EXPECT_EQ("page", invocation->kind);
  EXPECT_NE(std::string::npos, invocation->display.find(private_url.host()));
  AegisAgentService* regular_service =
      AegisAgentServiceFactory::GetForProfile(regular_profile);
  ASSERT_TRUE(regular_service);
  EXPECT_EQ(nullptr, regular_service->PendingInvocationContext());
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       LoadsSimplePanelAndRejectsOriginExpansion) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));

  SidePanelUI* side_panel = browser()->GetFeatures().side_panel_ui();
  ASSERT_TRUE(side_panel);
  side_panel->SetNoDelaysForTesting(true);
  side_panel->DisableAnimationsForTesting();
  ASSERT_TRUE(ShowAegisAgentSidePanel(browser()));
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return side_panel->IsSidePanelEntryShowing(
        SidePanelEntry::Key(SidePanelEntry::Id::kAegisAgent));
  }));

  content::WebContents* contents =
      side_panel->GetWebContentsForTest(SidePanelEntry::Id::kAegisAgent);
  ASSERT_TRUE(contents);
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(contents->GetLastCommittedURL(),
            GURL(chrome::kChromeUIUntrustedAegisAgentURL));
  ASSERT_TRUE(contents->GetWebUI());

  const std::string expected_origin = url::Origin::Create(page_url).Serialize();
  EXPECT_TRUE(content::EvalJs(contents, R"JS(
    !document.querySelector('#advanced-settings') &&
        !document.querySelector('#mode-group') &&
        !document.querySelector('#workflow') &&
        !document.querySelector('#origins') &&
        !document.querySelector('#current-page') &&
        document.querySelectorAll('#quick-actions button').length === 6 &&
        document.querySelectorAll('#automation-presets button').length === 4 &&
        document.querySelector('#automation-schedule').value === '60'
  )JS")
                  .ExtractBool());

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  tabs::TabInterface* active_tab = browser()->GetActiveTabInterface();
  ASSERT_TRUE(active_tab);
  AgentInvocationContext invocation;
  invocation.tab_id = active_tab->GetHandle().raw_value();
  invocation.kind = "selection";
  invocation.display = "Selection · " + expected_origin;
  invocation.suggested_goal = "Research the selected fixture";
  ASSERT_TRUE(service->SetPendingInvocationContext(std::move(invocation)));
  EXPECT_EQ(content::EvalJs(contents, R"JS(
      new Promise(resolve => {
        const deadline = Date.now() + 5000;
        const poll = () => {
          const value = document.querySelector('#invocation-context')
                            ?.textContent || '';
          if (value || Date.now() >= deadline) {
            resolve(value);
            return;
          }
          setTimeout(poll, 10);
        };
        poll();
      })
    )JS")
                .ExtractString(),
            "Selection · " + expected_origin);

  const std::string error =
      content::EvalJs(contents, content::JsReplace(R"JS(
        (async () => {
          const {BrowserProxy} = await import('./browser_proxy.js');
          const result = await BrowserProxy.getInstance().handler.createTask(
              'Read one page', 1, 0, [$1], 0);
          return result.snapshot.lastError;
        })()
      )JS",
                                                   page_url.spec()))
          .ExtractString();
  EXPECT_EQ(error, "Task input is invalid");
  EXPECT_EQ(service->task_count_for_testing(), 0u);
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ModelRoutedGoalOpensItsChosenSearchTaskTab) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  TemplateURLService* search =
      TemplateURLServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(search);
  search->Load();
  ASSERT_TRUE(base::test::RunUntil([&]() { return search->loaded(); }));
  TemplateURLData data;
  data.SetShortName(u"Aegis fixture search");
  data.SetKeyword(u"aegis-fixture");
  data.SetURL(embedded_test_server()
                  ->GetURL("a.test", "/title1.html?q={searchTerms}")
                  .spec());
  TemplateURL* provider = search->Add(std::make_unique<TemplateURL>(data));
  ASSERT_TRUE(provider);
  search->SetUserSelectedDefaultSearchProvider(provider);

  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/title2.html")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  EXPECT_TRUE(content::EvalJs(panel, R"JS(
    document.querySelector('#plan-button').disabled
  )JS")
                  .ExtractBool());
  EXPECT_FALSE(content::EvalJs(panel, R"JS(
    (() => {
      const goal = document.querySelector('#goal');
      goal.value = 'compare usb hubs';
      goal.dispatchEvent(new Event('input', {bubbles: true}));
      return document.querySelector('#plan-button').disabled;
    })()
  )JS")
                   .ExtractBool());
  const int initial_tab_count = browser()->GetTabStripModel()->count();
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentGoalRoute route;
  route.workflow = AgentWorkflowKind::kResearch;
  route.entry_kind = AgentGoalEntryKind::kWebSearch;
  route.target = "2026 reliable usb hub comparison";
  route.summary = "Search for current comparison sources";
  service->SetGoalRouteForTesting(route);
  const GURL expected = search->GenerateSearchURLForDefaultSearchProvider(
      u"2026 reliable usb hub comparison");

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler
          .createTask('compare usb hubs', 1, 0, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;

  ASSERT_TRUE(base::test::RunUntil([&]() {
    return browser()->GetTabStripModel()->count() == initial_tab_count + 1 &&
           browser()->GetActiveTabInterface()->GetURL() == expected;
  }));
  EXPECT_EQ(service->task_count_for_testing(), 1u);
  EXPECT_TRUE(service->MostRecentTask()->scope().AllowsOrigin(expected));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       NamedSiteDiscoveryStaysOnNamedSiteAndReadOnlyWorkflow) {
  ConfigureAgentModel(browser()->GetProfile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->GetTabStripModel()->count();
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);

  AgentGoalRoute overly_broad_route;
  overly_broad_route.workflow = AgentWorkflowKind::kShopping;
  overly_broad_route.entry_kind = AgentGoalEntryKind::kWebSearch;
  overly_broad_route.target = "京东 内存";
  overly_broad_route.summary = "搜索并购买内存";
  service->SetGoalRouteForTesting(std::move(overly_broad_route));

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler
          .createTask('帮我在 JD 找几款内存', 1, 3, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  ASSERT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count + 1);
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return browser()->GetActiveTabInterface()->GetURL().host() ==
           "search.jd.com";
  }));

  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_TRUE(
      task->scope().AllowsOrigin(browser()->GetActiveTabInterface()->GetURL()));
  EXPECT_TRUE(task->scope().AllowsTool("page.extract"));
  EXPECT_FALSE(task->scope().AllowsTool("shopping.prepare_checkout"));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ImplicitCurrentPageGoalBindsActiveTabWithoutNewTab) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  chrome::AddTabAt(browser(), GURL("about:blank"), -1, false);
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->GetTabStripModel()->count();
  const int32_t active_tab_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();

  EXPECT_TRUE(content::EvalJs(panel, R"JS(
    (() => {
      const summary = document.querySelector('#quick-actions button');
      summary.click();
      return document.querySelector('#goal').value.length > 0 &&
          !document.querySelector('#current-page');
    })()
  )JS")
                  .ExtractBool());

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler
          .createTask('帮我总结下页面内容', 1, 0, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count);
  EXPECT_EQ(browser()->GetActiveTabInterface()->GetURL(), page_url);

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_TRUE(task->scope().AllowsTab(active_tab_id));
  EXPECT_TRUE(task->scope().AllowsOrigin(page_url));
  EXPECT_TRUE(task->scope().AllowsTool("page.observe"));
  EXPECT_TRUE(task->scope().AllowsTool("page.extract"));
  EXPECT_EQ(task->scope().allowed_tab_ids.size(), 1u);
  EXPECT_EQ(task->scope().tab_metadata_window_id, 0);
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ModifiedCurrentReleasePageRejectsUnrelatedModelEntry) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentGoalRoute route;
  route.workflow = AgentWorkflowKind::kSafeDownload;
  route.entry_kind = AgentGoalEntryKind::kOpenUrl;
  route.target = "https://www.electronjs.org/latest";
  service->SetGoalRouteForTesting(route);
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int count = browser()->GetTabStripModel()->count();
  const int32_t tab_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  const std::string id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const {snapshot} = await BrowserProxy.getInstance().handler.createTask(
          '从当前官方合成发布页下载适合本机 macOS arm64 的测试安装包，核验页面公布的 SHA-256。只下载，不打开、不执行、不安装。',
          1, 0, [], 0);
      return snapshot.taskId || `ERROR:${snapshot.lastError}`;
    })()
  )JS").ExtractString();
  const auto* task = service->GetTask(id);
  ASSERT_TRUE(task) << id;
  EXPECT_EQ(browser()->GetTabStripModel()->count(), count);
  EXPECT_EQ(browser()->GetActiveTabInterface()->GetURL(), page_url);
  EXPECT_EQ(task->scope().allowed_tab_ids.size(), 1u);
  EXPECT_TRUE(task->scope().AllowsTab(tab_id));
  EXPECT_TRUE(task->scope().AllowsOrigin(page_url));
  EXPECT_FALSE(task->scope().AllowsOrigin(GURL(route.target)));
  EXPECT_TRUE(task->scope().AllowsTool("download.start"));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       CurrentPageDownloadReviewCannotTransferOrReadBookmarks) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const std::string id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler.createTask(
          '在当前页面找到 macOS ARM64 的官方下载，先不要下载。', 1, 0, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                             .ExtractString();
  ASSERT_FALSE(id.starts_with("ERROR:")) << id;
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  const auto* task = service->GetTask(id);
  ASSERT_TRUE(task);
  EXPECT_TRUE(task->scope().AllowsOrigin(page_url));
  EXPECT_TRUE(task->scope().AllowsTool("download.find_official"));
  EXPECT_TRUE(task->scope().AllowsTool("page.observe"));
  for (const auto* tool : {"download.start", "download.open", "page.click",
                           "bookmark.list", "bookmark.apply"}) {
    EXPECT_FALSE(task->scope().AllowsTool(tool)) << tool;
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       CurrentPageRejectsInternalTargetsAndStaleInvocation) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL background_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), background_url));
  const int32_t background_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  const size_t task_count = service->task_count_for_testing();

  for (const char* target : {"about:blank", "chrome://bookmarks/"}) {
    SCOPED_TRACE(target);
    chrome::AddTabAt(browser(), GURL(target), -1, true);
    // AddTabAt 只发起导航；必须先进入目标页，再检验内部页面拒绝，
    // 不能把尚未提交的空网址当作 chrome://bookmarks 的测试前提。
    ASSERT_TRUE(content::WaitForLoadStop(
        browser()->GetTabStripModel()->GetActiveWebContents()));
    ASSERT_EQ(browser()->GetActiveTabInterface()->GetURL(), GURL(target));
    content::WebContents* panel = ShowAgentPanel(browser());
    ASSERT_TRUE(panel);
    // 未消费的旧右键入口也不能把新活动页悄悄换成后台内容。
    AgentInvocationContext invocation;
    invocation.tab_id = background_id;
    invocation.kind = "page";
    invocation.display = "旧测试页面";
    invocation.suggested_goal = "总结当前页面内容";
    ASSERT_TRUE(service->SetPendingInvocationContext(std::move(invocation)));
    EXPECT_TRUE(content::EvalJs(panel, R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const {snapshot} = await BrowserProxy.getInstance().handler.createTask(
            '总结当前页面内容，并列出重点', 1, 0, [], 0);
        return snapshot.lastError ===
            'The current public page is unavailable for this task' &&
            !snapshot.activeOrigin && !snapshot.taskId;
      })()
    )JS").ExtractBool());
    EXPECT_EQ(browser()->GetActiveTabInterface()->GetURL(), GURL(target));
    EXPECT_EQ(service->task_count_for_testing(), task_count);
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       CurrentPageUsesActivePublicTabOverStaleInvocation) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL old_url = embedded_test_server()->GetURL("a.test", "/title1.html");
  const GURL active_url = embedded_test_server()->GetURL("b.test", "/title2.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), old_url));
  const int32_t old_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  chrome::AddTabAt(browser(), active_url, -1, true);
  const int32_t active_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentInvocationContext invocation;
  invocation.tab_id = old_id;
  invocation.kind = "selection";
  invocation.display = "旧选区";
  invocation.suggested_goal = "总结旧选区";
  ASSERT_TRUE(service->SetPendingInvocationContext(std::move(invocation)));
  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const {snapshot} = await BrowserProxy.getInstance().handler.createTask(
          '总结当前页面内容，并列出重点', 1, 0, [], 0);
      return snapshot.taskId || `ERROR:${snapshot.lastError}`;
    })()
  )JS").ExtractString();
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task) << task_id;
  EXPECT_TRUE(task->scope().AllowsTab(active_id));
  EXPECT_FALSE(task->scope().AllowsTab(old_id));
  EXPECT_TRUE(task->scope().AllowsOrigin(active_url));
  EXPECT_FALSE(task->scope().AllowsOrigin(old_url));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       FullPageAgentUsesDirectOpenerNotLastPublicTab) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL source_url = embedded_test_server()->GetURL("a.test", "/title1.html");
  const GURL other_url = embedded_test_server()->GetURL("b.test", "/title2.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), source_url));
  const tabs::TabHandle source = browser()->GetActiveTabInterface()->GetHandle();
  chrome::AddTabAt(browser(), other_url, -1, false);
  auto* tab_list = TabListInterface::From(browser());
  ASSERT_TRUE(tab_list);
  auto* agent = tab_list->OpenTab(GURL(chrome::kChromeUIUntrustedAegisAgentURL),
                                tab_list->GetTabCount(), true);
  ASSERT_TRUE(agent);
  tab_list->SetOpenerForTab(agent->GetHandle(), source);
  content::WebContents* page = agent->GetContents();
  ASSERT_TRUE(page);
  ASSERT_TRUE(content::WaitForLoadStop(page));
  const std::string task_id = content::EvalJs(page, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const {snapshot} = await BrowserProxy.getInstance().handler.createTask(
          '总结当前页面内容，并列出重点', 1, 0, [], 0);
      return snapshot.taskId || `ERROR:${snapshot.lastError}`;
    })()
  )JS").ExtractString();
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task) << task_id;
  EXPECT_TRUE(task->scope().AllowsTab(source.raw_value()));
  EXPECT_FALSE(task->scope().AllowsTab(agent->GetHandle().raw_value()));
  EXPECT_TRUE(task->scope().AllowsOrigin(source_url));
  EXPECT_FALSE(task->scope().AllowsOrigin(other_url));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       FullPageAgentRejectsMissingOrNonPublicOpener) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/title1.html")));
  auto* tab_list = TabListInterface::From(browser());
  ASSERT_TRUE(tab_list);
  auto* blank = tab_list->OpenTab(GURL("about:blank"), tab_list->GetTabCount(), false);
  ASSERT_TRUE(blank);
  const tabs::TabHandle blank_handle = blank->GetHandle();
  auto* agent = tab_list->OpenTab(GURL(chrome::kChromeUIUntrustedAegisAgentURL),
                                tab_list->GetTabCount(), true);
  ASSERT_TRUE(agent);
  ASSERT_TRUE(content::WaitForLoadStop(agent->GetContents()));
  // 先清除可能由浏览器附带的来源，再验证非公开来源；不能退到其他网页。
  for (bool use_blank : {false, true}) {
    SCOPED_TRACE(use_blank);
    if (use_blank) {
      tab_list->SetOpenerForTab(agent->GetHandle(), blank_handle);
    } else {
      browser()->GetTabStripModel()->ForgetAllOpeners();
    }
    EXPECT_TRUE(content::EvalJs(agent->GetContents(), R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const {snapshot} = await BrowserProxy.getInstance().handler.createTask(
            '总结当前页面内容，并列出重点', 1, 0, [], 0);
        return snapshot.lastError ===
            'The current public page is unavailable for this task' &&
            !snapshot.activeOrigin && !snapshot.taskId;
      })()
    )JS").ExtractBool());
  }
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  EXPECT_EQ(service->task_count_for_testing(), 0u);
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       PartialCompletionReachesVisibleResultAndTimeline) {
  constexpr char kEndpoint[] = "http://127.0.0.1:8765/v1/responses";
  Profile* profile = browser()->GetProfile();
  ConfigureAgentModel(profile);
  profile->GetPrefs()->SetString(prefs::kModelBaseUrl,
                                 "http://127.0.0.1:8765/v1");
  profile->GetPrefs()->SetString(prefs::kModelName, "fixture-model");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile);
  ASSERT_TRUE(service);
  base::test::TestFuture<bool> storage;
  service->FlushTaskStoreForTesting(storage.GetCallback());
  ASSERT_TRUE(storage.Get());
  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler
          .createTask('读取当前标签信息，无法读取的部分请说明', 0, 1, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task_id));
  AgentModelEvent plan;
  plan.type = AgentModelEventType::kToolCall;
  plan.tool_name = "agent.submit_plan";
  plan.tool_call_id = "fixture-plan";
  plan.arguments.Set("schema_version", kAgentSchemaVersion);
  plan.arguments.Set("summary", "读取授权标签并说明未完成事项");
  base::DictValue step;
  step.Set("id", "list");
  step.Set("title", "读取标签");
  step.Set("tool", "tab.list");
  base::ListValue steps;
  steps.Append(std::move(step));
  plan.arguments.Set("steps", std::move(steps));
  std::string error;
  ASSERT_TRUE(service->AcceptModelPlan(task_id, plan, &error)) << error;
  network::TestURLLoaderFactory factory;
  service->SetTaskModelClientForTesting(
      task_id,
      std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
  EXPECT_EQ(content::EvalJs(panel, content::JsReplace(R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      return (await BrowserProxy.getInstance().handler.consentAndRun($1))
          .snapshot.state;
    })()
  )JS",
                                                      task_id))
                .ExtractString(),
            "running");
  factory.WaitForRequest(GURL(kEndpoint));
  ASSERT_TRUE(factory.SimulateResponseForPendingRequest(
      kEndpoint,
      R"({"status":"completed","output":[{"type":"function_call","call_id":"fixture-list","name":"tab.list","arguments":"{}"}]})"));
  factory.WaitForRequest(GURL(kEndpoint));
  ASSERT_TRUE(factory.SimulateResponseForPendingRequest(
      kEndpoint,
      R"({"status":"completed","output":[{"type":"function_call","call_id":"fixture-partial","name":"agent.complete","arguments":"{\"outcome\":\"partial\",\"summary\":\"已读取允许查看的标签。\",\"source_urls\":[],\"unfinished_items\":[\"另一个来源需要登录，尚未读取。\"]}"}]})"));
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return service->GetCompletionSummary(task_id) != nullptr; }));
  EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
  EXPECT_EQ(service->GetCompletionSummary(task_id)->outcome, "partial");
  // 等待实际 DOM 状态，而不是绘制帧；Windows 被遮挡的窗口可能暂停 rAF。
  ASSERT_TRUE(base::test::RunUntil([&]() {
    const auto visible_result = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const {loadTimeData} = await import('//resources/js/load_time_data.js');
      const {snapshot} = await BrowserProxy.getInstance().handler.getSnapshot();
      const status = document.querySelector('#status');
      const card = document.querySelector('#result-card');
      const timeline = document.querySelector('#timeline').lastElementChild;
      return snapshot.resultOutcome === 'partial' &&
          status.textContent === loadTimeData.getString('statusPartial') &&
          status.dataset.tone === 'warning' && !card.hidden &&
          card.dataset.outcome === 'partial' &&
          document.querySelector('#result-title').textContent ===
              loadTimeData.getString('resultPartialTitle') &&
          !document.querySelector('#result-partial-note').hidden &&
          document.querySelector('#unfinished-items').children.length === 1 &&
          timeline.textContent.includes(loadTimeData.getString('statusPartial')) &&
          !document.querySelector('#error').textContent;
    })()
  )JS");
    EXPECT_TRUE(visible_result.is_ok()) << visible_result;
    return visible_result.is_ok() && visible_result.ExtractBool();
  }));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       SelectedTabGroupBindsOnlyExplicitCurrentWindowTabs) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page));
  for (int index = 0; index < 3; ++index) {
    chrome::AddTabAt(browser(), page, -1, false);
    ASSERT_TRUE(content::WaitForLoadStop(
        browser()->GetTabStripModel()->GetWebContentsAt(index + 1)));
  }
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const std::string id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const handler = BrowserProxy.getInstance().handler;
      const {tabs} = await handler.listResearchTabs();
      const ids = tabs.slice(0, 3).map(tab => tab.tabId);
      const bad = await handler.createTabGroupTask('分组', [ids[0], ids[0], ids[1]]);
      if (!bad.snapshot.lastError) return 'ERROR:duplicate accepted';
      const result = await handler.createTabGroupTask(
          '把本任务的三个研究标签放入一个组。', ids);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                             .ExtractString();
  ASSERT_FALSE(id.starts_with("ERROR:")) << id;
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  AgentTask* task = service->GetTask(id);
  ASSERT_TRUE(task);
  EXPECT_EQ(task->scope().allowed_tab_ids.size(), 3u);
  EXPECT_TRUE(task->scope().selected_tab_group);
  EXPECT_EQ(task->scope().tab_metadata_window_id, 0);
  EXPECT_TRUE(task->scope().allowed_origins.empty());
  EXPECT_FALSE(task->scope().AllowsTool("page.observe"));
  EXPECT_FALSE(task->scope().AllowsTool("tab.close"));
  EXPECT_FALSE(task->scope().AllowsTool("bookmark.apply"));
  AegisBrowserTools tools(browser()->GetProfile());
  AgentToolCall call;
  call.action_id = "selected-list";
  call.tool_name = "tab.list";
  base::test::TestFuture<AgentToolResult> listed;
  tools.Execute(task, call, listed.GetCallback());
  ASSERT_TRUE(listed.Get().ok);
  EXPECT_EQ(listed.Get().value.FindInt("tab_count"), 3);
  call.action_id = "selected-group";
  call.tool_name = "tab.group";
  base::ListValue ids;
  for (int32_t tab_id : task->scope().allowed_tab_ids) {
    ids.Append(tab_id);
  }
  call.arguments.Set("tab_ids", std::move(ids));
  call.arguments.Set("revision", *listed.Get().value.FindString("revision"));
  base::test::TestFuture<AgentToolResult> grouped;
  tools.Execute(task, call, grouped.GetCallback());
  ASSERT_TRUE(grouped.Get().ok) << grouped.Get().message;
  ASSERT_TRUE(grouped.Get().value.FindList("tab_ids"));
  EXPECT_EQ(grouped.Get().value.FindList("tab_ids")->size(), 3u);
  const auto* title = grouped.Get().value.FindString("title");
  ASSERT_TRUE(title);
  EXPECT_FALSE(title->empty());
  const auto* group_id = grouped.Get().value.FindString("group_id");
  ASSERT_TRUE(group_id);
  auto* tabs = TabListInterface::From(browser());
  for (auto* tab : tabs->GetAllTabs()) {
    const auto group = tab->GetGroup();
    if (task->AllowsTab(tab->GetHandle().raw_value())) {
      ASSERT_TRUE(group);
      EXPECT_EQ(group->ToString(), *group_id);
      const auto visual = tabs->GetTabGroupVisualData(*group);
      ASSERT_TRUE(visual);
      EXPECT_EQ(base::UTF16ToUTF8(visual->title()), *title);
    } else {
      EXPECT_FALSE(group);
    }
  }
  AgentToolCall verification_call =
      AgentResultVerifier::RetainVerificationContext(call);
  AgentResultVerifier verifier;
  AgentToolRegistry registry;
  EXPECT_TRUE(verifier
                  .Verify(*task, verification_call, *registry.Find("tab.group"),
                          grouped.Get())
                  .accepted);
  AgentToolResult incomplete;
  incomplete.action_id = grouped.Get().action_id;
  incomplete.ok = true;
  incomplete.value = grouped.Get().value.Clone();
  incomplete.value.Remove("tab_ids");
  EXPECT_FALSE(verifier
                   .Verify(*task, verification_call,
                           *registry.Find("tab.group"), incomplete)
                   .accepted);
  incomplete.value = grouped.Get().value.Clone();
  incomplete.value.Set("tab_ids", base::ListValue().Append(
                                      *task->scope().allowed_tab_ids.begin()));
  EXPECT_FALSE(verifier
                   .Verify(*task, verification_call,
                           *registry.Find("tab.group"), incomplete)
                   .accepted);
  // 列表展示后导航，旧选择不能授权新的网页或其他窗口。
  const size_t before = service->task_count_for_testing();
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/title2.html")));
  EXPECT_TRUE(
      content::EvalJs(panel, content::JsReplace(
                                 R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const handler = BrowserProxy.getInstance().handler;
      const result = await handler.createTabGroupTask('分组', $1);
      return Boolean(result.snapshot.lastError);
    })()
  )JS",
                                 call.arguments.FindList("tab_ids")->Clone()))
          .ExtractBool());
  EXPECT_EQ(service->task_count_for_testing(), before);
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       TaskTabGoalDoesNotGrantWindowMetadata) {
  ConfigureAgentModel(browser()->GetProfile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  const int32_t active_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  chrome::AddTabAt(browser(), GURL("about:blank"), -1, false);
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AegisBrowserTools tools(browser()->GetProfile());
  for (const char* goal :
       {"列出这个任务打开的标签页。", "列出本任務開啟的標籤頁。",
        "List open tabs for this task.", "列出当前窗口中本任务的标签页。"}) {
    SCOPED_TRACE(goal);
    AgentGoalRoute route;
    route.workflow = AgentWorkflowKind::kBrowserSteward;
    route.entry_kind = AgentGoalEntryKind::kBrowserOnly;
    route.summary = "列出任务标签";
    service->SetGoalRouteForTesting(route);
    const std::string id = content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const result = await BrowserProxy.getInstance().handler
            .createTask($1, 0, 0, [], 0);
        return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
      })()
    )JS",
                                                                     goal))
                               .ExtractString();
    ASSERT_FALSE(id.starts_with("ERROR:")) << id;
    AgentTask* task = service->GetTask(id);
    ASSERT_TRUE(task);
    EXPECT_EQ(task->scope().tab_metadata_window_id, 0);
    AgentToolCall call;
    call.action_id = "list-task-tabs";
    call.tool_name = "tab.list";
    base::test::TestFuture<AgentToolResult> future;
    tools.Execute(task, call, future.GetCallback());
    const AgentToolResult& result = future.Get();
    ASSERT_TRUE(result.ok) << result.message;
    EXPECT_EQ(result.value.FindInt("tab_count"), 1);
    EXPECT_EQ(*result.value.FindString("count_scope"), "task_tabs");
    const base::ListValue* listed = result.value.FindList("tabs");
    ASSERT_TRUE(listed);
    ASSERT_EQ(listed->size(), 1u);
    EXPECT_EQ((*listed)[0].GetDict().FindInt("tab_id"), active_id);
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       CurrentWindowMetadataCountsAllTabsWithoutActionAccess) {
  ConfigureAgentModel(browser()->GetProfile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  for (int index = 1; index < 6; ++index) {
    chrome::AddTabAt(browser(), GURL("about:blank"), -1, false);
  }
  Browser* other_window = CreateBrowser(browser()->GetProfile());
  Browser* otr_window = CreateIncognitoBrowser(browser()->GetProfile());
  ASSERT_TRUE(other_window);
  ASSERT_TRUE(otr_window);
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentGoalRoute route;
  route.workflow = AgentWorkflowKind::kBrowserSteward;
  route.entry_kind = AgentGoalEntryKind::kBrowserOnly;
  route.summary = "统计当前窗口标签";
  service->SetGoalRouteForTesting(route);
  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler
          .createTask('统计当前窗口有几个标签', 0, 0, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  ASSERT_EQ(task->scope().tab_metadata_window_id,
            browser()->GetSessionID().id());
  EXPECT_EQ(task->scope().allowed_tab_ids.size(), 1u);
  EXPECT_TRUE(task->scope().allowed_origins.empty());
  AegisBrowserTools tools(browser()->GetProfile());
  AgentToolCall list_call;
  list_call.action_id = "count-window-tabs";
  list_call.tool_name = "tab.list";
  auto list_tabs = [&]() {
    base::test::TestFuture<AgentToolResult> future;
    tools.Execute(task, list_call, future.GetCallback());
    return future.Take();
  };
  AgentToolResult result = list_tabs();
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_EQ(result.value.FindInt("tab_count"), 6);
  EXPECT_EQ(result.value.FindBool("list_truncated"), false);
  const base::ListValue* listed = result.value.FindList("tabs");
  ASSERT_TRUE(listed);
  ASSERT_EQ(listed->size(), 6u);
  int32_t metadata_only_tab = 0;
  for (const base::Value& value : *listed) {
    const int32_t id = value.GetDict().FindInt("tab_id").value_or(0);
    ASSERT_TRUE(tabs::TabHandle(id).Get());
    EXPECT_EQ(tabs::TabHandle(id).Get()->GetBrowserWindowInterface(),
              browser());
    if (!task->AllowsTab(id)) {
      metadata_only_tab = id;
    }
  }
  ASSERT_GT(metadata_only_tab, 0);
  AgentToolCall close_call;
  close_call.action_id = "reject-metadata-only-close";
  close_call.tool_name = "tab.close";
  base::ListValue ids;
  ids.Append(metadata_only_tab);
  close_call.arguments.Set("tab_ids", std::move(ids));
  close_call.arguments.Set("revision", *result.value.FindString("revision"));
  base::test::TestFuture<AgentToolResult> close_future;
  tools.Execute(task, close_call, close_future.GetCallback());
  EXPECT_FALSE(close_future.Get().ok);
  EXPECT_EQ(close_future.Get().error, AgentErrorCode::kScopeViolation);
  EXPECT_EQ(browser()->GetTabStripModel()->count(), 6);
  for (int index = 6; index < 26; ++index) {
    chrome::AddTabAt(browser(), GURL("about:blank"), -1, false);
  }
  result = list_tabs();
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_EQ(result.value.FindInt("tab_count"), 26);
  EXPECT_EQ(result.value.FindList("tabs")->size(), 20u);
  EXPECT_EQ(result.value.FindBool("list_truncated"), true);
  EXPECT_EQ(task->scope().allowed_tab_ids.size(), 1u);
  AgentResultVerifier verifier;
  AgentToolRegistry registry;
  EXPECT_TRUE(
      verifier.Verify(*task, list_call, *registry.Find("tab.list"), result)
          .accepted);
  result.value.Set("tab_count", 19);
  EXPECT_FALSE(
      verifier.Verify(*task, list_call, *registry.Find("tab.list"), result)
          .accepted);

  AgentTaskScope foreign_scope = task->scope();
  foreign_scope.tab_metadata_window_id = otr_window->GetSessionID().id();
  AgentTask foreign("foreign-window", "读取窗口", AgentMode::kAsk,
                    foreign_scope);
  base::test::TestFuture<AgentToolResult> foreign_future;
  tools.Execute(&foreign, list_call, foreign_future.GetCallback());
  EXPECT_FALSE(foreign_future.Get().ok);
  EXPECT_EQ(foreign_future.Get().error, AgentErrorCode::kScopeViolation);
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ModelBrowserOnlyResearchRouteBindsCurrentPage) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->GetTabStripModel()->count();
  const int32_t active_tab_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentGoalRoute route;
  route.workflow = AgentWorkflowKind::kResearch;
  route.entry_kind = AgentGoalEntryKind::kBrowserOnly;
  route.summary = "读取当前内容并概括";
  service->SetGoalRouteForTesting(std::move(route));

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler
          .createTask('帮我概括一下这里讲了什么', 1, 0, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count);
  EXPECT_EQ(browser()->GetActiveTabInterface()->GetURL(), page_url);

  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_TRUE(task->scope().AllowsTab(active_tab_id));
  EXPECT_TRUE(task->scope().AllowsOrigin(page_url));
  EXPECT_TRUE(task->scope().AllowsTool("page.observe"));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       AutomationScheduleIsBrowserOwnedAndBoundToTask) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->GetTabStripModel()->count();

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler.createTask(
          '监控当前页面内容变化', 2, 0, [], 60);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count);

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_EQ(task->mode(), AgentMode::kAutomate);
  EXPECT_NE(task->goal().find("[AEGIS_SCHEDULE_INTERVAL_MINUTES=60]"),
            std::string::npos);
  EXPECT_TRUE(task->scope().AllowsOrigin(page_url));
  EXPECT_TRUE(task->scope().AllowsTool("monitor.create"));

  const std::string invalid = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler.createTask(
          '监控当前页面内容变化', 2, 0, [], 10);
      return result.snapshot.lastError;
    })()
  )JS")
                                  .ExtractString();
  EXPECT_EQ(invalid, "Task input is invalid");
  EXPECT_EQ(service->task_count_for_testing(), 1u);
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       AutomationRouteCannotGrantOneShotActionPermissions) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  for (int workflow : {2, 3}) {
    const std::string task_id = content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const result = await BrowserProxy.getInstance().handler.createTask(
            '监控当前网页内容，每15分钟提醒重要变化；不下载、不购买、不填写表单。',
            2, $1, [], 15);
        return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
      })()
    )JS", workflow)).ExtractString();
    ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
    AgentTask* task = service->GetTask(task_id);
    ASSERT_TRUE(task);
    EXPECT_EQ(task->mode(), AgentMode::kAutomate);
    EXPECT_TRUE(task->scope().AllowsOrigin(page_url));
    EXPECT_TRUE(task->scope().AllowsTool("page.observe"));
    EXPECT_TRUE(task->scope().AllowsTool("monitor.create"));
    EXPECT_FALSE(task->scope().AllowsTool("download.start"));
    EXPECT_FALSE(task->scope().AllowsTool("download.open"));
    EXPECT_FALSE(task->scope().AllowsTool("shopping.prepare_checkout"));
    EXPECT_FALSE(task->scope().AllowsTool("form.fill"));
    EXPECT_FALSE(task->scope().AllowsTool("page.click"));
    EXPECT_NE(task->goal().find("不下载、不购买、不填写表单"), std::string::npos);
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       FirstPlannedObservationUsesOnlyUnambiguousBrowserTab) {
  base::test::ScopedRunLoopTimeout timeout(FROM_HERE, base::Seconds(60));
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  const GURL other_url = embedded_test_server()->GetURL("/title2.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  const int32_t source_tab =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  chrome::AddTabAt(browser(), other_url, -1, true);
  ASSERT_TRUE(content::WaitForLoadStop(
      browser()->GetTabStripModel()->GetActiveWebContents()));
  const int32_t active_tab =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  ASSERT_NE(source_tab, active_tab);
  constexpr char kModelBase[] = "http://127.0.0.1:8765/v1";
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  PrefService* prefs = browser()->GetProfile()->GetPrefs();
  prefs->SetString(aegis::prefs::kModelProvider, "openai");
  prefs->SetString(aegis::prefs::kModelBaseUrl, kModelBase);
  prefs->SetString(aegis::prefs::kModelName, "fixture-model");
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  base::test::TestFuture<bool> storage_loaded;
  service->FlushTaskStoreForTesting(storage_loaded.GetCallback());
  ASSERT_TRUE(storage_loaded.Get());
  for (bool ambiguous_scope : {false, true}) {
    SCOPED_TRACE(ambiguous_scope);
    AgentTaskScope scope;
    scope.allowed_origins = {url::Origin::Create(page_url)};
    scope.allowed_tab_ids = {source_tab};
    if (ambiguous_scope) {
      scope.allowed_tab_ids.insert(active_tab);
    }
    scope.allowed_tools = {"page.observe"};
    scope.allowed_data_classes = {AgentDataClass::kPublicPage};
    scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
    scope.model_destination.provider = "openai";
    scope.model_destination.endpoint = kModelBase;
    scope.model_destination.model = "fixture-model";
    auto* task = service->CreateTask("读取第一个已授权页面的正文并总结",
                                      AgentMode::kAsk, std::move(scope));
    ASSERT_TRUE(task);
    network::TestURLLoaderFactory factory;
    service->SetTaskModelClientForTesting(
        task->id(),
        std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
    int responses = 0;
    const auto respond = [&](const char* tool, base::DictValue arguments) {
      ASSERT_TRUE(base::test::RunUntil([&]() {
        return !factory.pending_requests()->empty() ||
               IsTerminalState(task->state());
      }));
      ASSERT_EQ(factory.pending_requests()->size(), 1u);
      auto request = base::JSONReader::ReadDict(
          network::GetUploadData(factory.GetPendingRequest(0)->request),
          base::JSON_PARSE_RFC);
      ASSERT_TRUE(request);
      const auto* choice = request->FindDict("tool_choice");
      ASSERT_TRUE(choice && choice->FindString("name"));
      EXPECT_EQ(*choice->FindString("name"), tool);
      base::DictValue call;
      call.Set("type", "function_call");
      call.Set("call_id", "native-bound-" + base::NumberToString(++responses));
      call.Set("name", tool);
      call.Set("arguments", *base::WriteJson(arguments));
      base::ListValue output;
      output.Append(std::move(call));
      base::DictValue response;
      response.Set("status", "completed");
      response.Set("output", std::move(output));
      ASSERT_TRUE(factory.SimulateResponseForPendingRequest(
          endpoint.spec(), *base::WriteJson(response)));
    };
    base::test::TestFuture<bool, std::string> planned;
    service->RequestPlan(task->id(), planned.GetCallback());
    base::DictValue plan;
    plan.Set("schema_version", kAgentSchemaVersion);
    plan.Set("summary", "读取已授权页面后总结");
    base::DictValue step;
    step.Set("id", "observe");
    step.Set("title", "读取网页正文");
    step.Set("tool", "page.observe");
    base::ListValue steps;
    steps.Append(std::move(step));
    plan.Set("steps", std::move(steps));
    ASSERT_NO_FATAL_FAILURE(respond("agent.submit_plan", std::move(plan)));
    ASSERT_TRUE(planned.Get<0>()) << planned.Get<1>();
    EXPECT_EQ(task->model_calls_used(), 1);
    EXPECT_EQ(task->tool_calls_used(), 0);
    // 未同意任务时，优化也不能提前读取页面。
    base::test::TestFuture<bool, std::string,
                           std::optional<AgentCompletionSummary>> before_consent;
    service->RunTask(task->id(), before_consent.GetCallback());
    EXPECT_FALSE(before_consent.Get<0>());
    EXPECT_EQ(task->tool_calls_used(), 0);
    ASSERT_TRUE(service->GrantTaskConsent(task->id()));
    base::test::TestFuture<bool, std::string,
                           std::optional<AgentCompletionSummary>> finished;
    service->RunTask(task->id(), finished.GetCallback());
    if (ambiguous_scope) {
      base::DictValue observe;
      observe.Set("tab_id", source_tab);
      ASSERT_NO_FATAL_FAILURE(respond("page.observe", std::move(observe)));
    }
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return !factory.pending_requests()->empty() || finished.IsReady();
    }));
    ASSERT_FALSE(finished.IsReady());
    const auto* observed =
        service->FindRecordedResult(task->id(), task->id() + ":observe:1");
    ASSERT_TRUE(observed && observed->ok);
    EXPECT_EQ(observed->value.FindInt("tab_id"), source_tab);
    ASSERT_TRUE(observed->value.FindString("url"));
    EXPECT_EQ(*observed->value.FindString("url"), page_url.spec());
    ASSERT_TRUE(observed->value.FindString("document_token"));
    EXPECT_FALSE(observed->value.FindString("document_token")->empty());
    ASSERT_TRUE(observed->value.FindList("nodes"));
    EXPECT_FALSE(observed->value.FindList("nodes")->empty());
    base::DictValue completion;
    completion.Set("outcome", "completed");
    completion.Set("summary", "已读取第一个测试页面的正文。");
    base::ListValue sources;
    sources.Append(page_url.spec());
    completion.Set("source_urls", std::move(sources));
    completion.Set("unfinished_items", base::ListValue());
    ASSERT_NO_FATAL_FAILURE(respond("agent.complete", std::move(completion)));
    ASSERT_TRUE(finished.Get<0>()) << finished.Get<1>();
    EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
    EXPECT_EQ(task->tool_calls_used(), 1);
    EXPECT_EQ(task->model_calls_used(), ambiguous_scope ? 3 : 2);
    EXPECT_EQ(responses, task->model_calls_used());
    EXPECT_EQ(task->network_requests_used(), responses);
    EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task->id()));
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       FinishedMonitorRegistrationHasAnInertOwner) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  constexpr char kModelBase[] = "http://127.0.0.1:8765/v1";
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  PrefService* prefs = browser()->GetProfile()->GetPrefs();
  prefs->SetString(aegis::prefs::kModelProvider, "openai");
  prefs->SetString(aegis::prefs::kModelBaseUrl, kModelBase);
  prefs->SetString(aegis::prefs::kModelName, "fixture-model");
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  base::test::TestFuture<bool> storage_loaded;
  service->FlushTaskStoreForTesting(storage_loaded.GetCallback());
  ASSERT_TRUE(storage_loaded.Get());
  const int32_t tab_id = browser()->GetActiveTabInterface()->GetHandle().raw_value();
  for (bool malformed_completion : {false, true}) {
    SCOPED_TRACE(malformed_completion);
    AgentTaskScope scope;
    scope.allowed_origins = {url::Origin::Create(page_url)};
    scope.allowed_tab_ids = {tab_id};
    scope.allowed_tools = {"page.observe", "monitor.create"};
    scope.allowed_data_classes = {AgentDataClass::kPublicPage};
    scope.model_destination.kind = AgentModelDestination::Kind::kLoopback;
    scope.model_destination.provider = "openai";
    scope.model_destination.endpoint = kModelBase;
    scope.model_destination.model = "fixture-model";
    AgentTask* task = service->CreateTask(
        "每15分钟监控当前公开页面的变化，不执行其他操作", AgentMode::kAutomate,
        std::move(scope));
    ASSERT_TRUE(task);
    ASSERT_TRUE(service->BeginPlanning(task->id()));
    AgentModelEvent plan;
    plan.type = AgentModelEventType::kToolCall;
    plan.tool_call_id = "monitor-registration-plan";
    plan.tool_name = "agent.submit_plan";
    plan.arguments.Set("schema_version", 1);
    plan.arguments.Set("summary", "读取公开页面并创建定时监控");
    base::ListValue steps;
    for (const char* tool : {"page.observe", "monitor.create"}) {
      base::DictValue step;
      step.Set("id", tool);
      step.Set("title", tool);
      step.Set("tool", tool);
      steps.Append(std::move(step));
    }
    plan.arguments.Set("steps", std::move(steps));
    std::string error;
    ASSERT_TRUE(service->AcceptModelPlan(task->id(), plan, &error)) << error;
    ASSERT_TRUE(service->GrantTaskConsent(task->id()));
    network::TestURLLoaderFactory factory;
    service->SetTaskModelClientForTesting(
        task->id(), std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
    base::test::TestFuture<bool, std::string, std::optional<AgentCompletionSummary>> finished;
    service->RunTask(task->id(), finished.GetCallback());
    const auto respond = [&](const char* tool, base::DictValue arguments) {
      factory.WaitForRequest(endpoint);
      base::DictValue call;
      call.Set("type", "function_call");
      call.Set("call_id", std::string("registration-") + tool);
      call.Set("name", tool);
      call.Set("arguments", *base::WriteJson(arguments));
      base::ListValue output;
      output.Append(std::move(call));
      base::DictValue response;
      response.Set("status", "completed");
      response.Set("output", std::move(output));
      EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
          endpoint.spec(), *base::WriteJson(response)));
    };
    factory.WaitForRequest(endpoint);
    const auto document = service->actor_bridge_for_testing().LastDocument(task->id(), tab_id);
    ASSERT_TRUE(document);
    base::DictValue create;
    create.Set("tab_id", tab_id);
    create.Set("document_token", document->document_token);
    create.Set("kind", "page_change");
    create.Set("interval_minutes", 15);
    respond("monitor.create", std::move(create));
    if (malformed_completion) {
      respond("agent.complete", {});
      respond("agent.complete", {});
    } else {
      base::DictValue completion;
      completion.Set("outcome", "completed");
      completion.Set("summary", "已创建公开页面监控。");
      base::ListValue sources;
      sources.Append(page_url.spec());
      completion.Set("source_urls", std::move(sources));
      completion.Set("unfinished_items", base::ListValue());
      respond("agent.complete", std::move(completion));
    }
    ASSERT_TRUE(finished.Get<0>()) << finished.Get<1>();
    ASSERT_TRUE(finished.Get<2>());
    EXPECT_EQ(finished.Get<2>()->outcome, "monitoring");
    EXPECT_EQ(task->model_calls_used(), malformed_completion ? 3 : 2);
    EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
    EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task->id()));
    const auto monitors = service->GetMonitors(task->id());
    ASSERT_EQ(monitors.size(), 1u);
    EXPECT_TRUE(monitors[0].enabled);
    EXPECT_FALSE(monitors[0].session_only);
    EXPECT_FALSE(monitors[0].target_ciphertext.empty());
    EXPECT_EQ(monitors[0].interval, base::Minutes(15));
    EXPECT_TRUE(monitors[0].last_run.is_null());
    EXPECT_GT(monitors[0].next_run, base::Time::Now());
    EXPECT_FALSE(service->GrantTaskConsent(task->id()));
    EXPECT_TRUE(service->SetMonitorPaused(task->id(), monitors[0].monitor_id, true));
    EXPECT_FALSE(service->GetMonitors(task->id())[0].enabled);
    EXPECT_TRUE(service->RemoveMonitor(task->id(), monitors[0].monitor_id));
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ExplicitPageGoalRejectsDeniedWorkflowHints) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  const GURL target = embedded_test_server()->GetURL("/title1.html");
  for (int workflow_hint : {1, 2, 3}) {
    SCOPED_TRACE(workflow_hint);
    const std::string task_id = content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const goal = `打开 ${$1} 并总结页面内容。只允许读取这个本地公开测试来源；不要下载、整理书签、提交或购买。`;
        const result = await BrowserProxy.getInstance().handler
            .createTask(goal, 1, $2, [], 0);
        return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
      })()
    )JS", target.spec(), workflow_hint)).ExtractString();
    ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
    const AgentTask* task = service->GetTask(task_id);
    ASSERT_TRUE(task);
    EXPECT_TRUE(task->scope().AllowsOrigin(target));
    EXPECT_TRUE(task->scope().AllowsTool("page.observe"));
    EXPECT_TRUE(task->scope().AllowsTool("page.extract"));
    EXPECT_FALSE(task->scope().AllowsTool("bookmark.list"));
    EXPECT_FALSE(task->scope().AllowsTool("download.start"));
    EXPECT_FALSE(task->scope().AllowsTool("shopping.prepare_checkout"));
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       SlowPageCannotCompleteBeforeContentArrives) {
  base::test::ScopedRunLoopTimeout timeout(FROM_HERE, base::Seconds(70));
  net::test_server::ControllableHttpResponse pending(embedded_test_server(),
                                                    "/slow-page-evidence");
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const GURL target = embedded_test_server()->GetURL("/slow-page-evidence");
  const std::string task_id = content::EvalJs(panel, content::JsReplace(R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const goal = `打开 ${$1} 并总结页面内容；不要下载、整理书签或购买。`;
      const result = await BrowserProxy.getInstance().handler
          .createTask(goal, 1, 1, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS", target.spec())).ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  pending.WaitForRequest();
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  ASSERT_TRUE(task->scope().AllowsTool("page.observe"));
  ASSERT_EQ(task->scope().allowed_tab_ids.size(), 1u);
  ASSERT_TRUE(service->BeginPlanning(task_id));
  AgentModelEvent plan;
  plan.type = AgentModelEventType::kToolCall;
  plan.tool_name = "agent.submit_plan";
  plan.tool_call_id = "slow-page-plan";
  plan.arguments.Set("schema_version", kAgentSchemaVersion);
  plan.arguments.Set("summary", "读取实际页面内容后总结");
  base::DictValue step;
  step.Set("id", "observe");
  step.Set("title", "读取页面内容");
  step.Set("tool", "page.observe");
  base::ListValue steps;
  steps.Append(std::move(step));
  plan.arguments.Set("steps", std::move(steps));
  std::string error;
  ASSERT_TRUE(service->AcceptModelPlan(task_id, plan, &error)) << error;
  ASSERT_TRUE(service->GrantTaskConsent(task_id));
  const GURL endpoint("https://api.openai.com/v1/responses");
  network::TestURLLoaderFactory factory;
  service->SetTaskModelClientForTesting(
      task_id,
      std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
  base::test::TestFuture<bool, std::string,
                         std::optional<AgentCompletionSummary>> finished;
  base::test::TestFuture<void> delay_elapsed;
  base::OneShotTimer release_response;
  const base::TimeTicks started = base::TimeTicks::Now();
  release_response.Start(FROM_HERE, base::Seconds(35),
                         delay_elapsed.GetCallback());
  service->RunTask(task_id, finished.GetCallback());
  // 等待条件只读取状态；NumPending()会运行事件循环，不能在此嵌套调用。
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return delay_elapsed.IsReady() || !factory.pending_requests()->empty() ||
           finished.IsReady();
  }));
  ASSERT_TRUE(delay_elapsed.IsReady())
      << "页面返回前不应调用执行模型或结束任务";
  ASSERT_FALSE(finished.IsReady());
  ASSERT_TRUE(factory.pending_requests()->empty());
  EXPECT_EQ(task->state(), AgentTaskState::kRunning);
  // 在主测试流程发送响应，避免定时回调内的同步发送形成嵌套等待。
  pending.Send(net::HTTP_OK, "text/html; charset=utf-8",
               "<!doctype html><title>真实慢页面</title>"
               "<h1>合成产品公开资料</h1>"
               "<p>电池续航为24小时。保修期为36个月。</p>");
  pending.Done();
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return !factory.pending_requests()->empty() || finished.IsReady();
  }));
  ASSERT_FALSE(finished.IsReady())
      << (finished.IsReady() ? finished.Get<1>() : std::string());
  EXPECT_GE(base::TimeTicks::Now() - started, base::Seconds(35));
  EXPECT_EQ(task->state(), AgentTaskState::kRunning);
  const auto respond = [&](const char* tool, base::DictValue arguments) {
    factory.WaitForRequest(endpoint);
    base::DictValue call;
    call.Set("type", "function_call");
    call.Set("call_id", std::string("slow-page-") + tool);
    call.Set("name", tool);
    call.Set("arguments", *base::WriteJson(arguments));
    base::ListValue output;
    output.Append(std::move(call));
    base::DictValue response;
    response.Set("status", "completed");
    response.Set("output", std::move(output));
    EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
        endpoint.spec(), *base::WriteJson(response)));
  };
  base::DictValue completion;
  completion.Set("outcome", "completed");
  completion.Set("summary", "电池续航为24小时，保修期为36个月。");
  base::ListValue sources;
  sources.Append(target.spec());
  completion.Set("source_urls", std::move(sources));
  completion.Set("unfinished_items", base::ListValue());
  respond("agent.complete", std::move(completion));
  ASSERT_TRUE(finished.Get<0>()) << finished.Get<1>();
  ASSERT_TRUE(finished.Get<2>());
  EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
  EXPECT_EQ(task->tool_calls_used(), 1);
  EXPECT_EQ(task->model_calls_used(), 1);
  EXPECT_EQ(finished.Get<2>()->source_urls,
            std::vector<std::string>{target.spec()});
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       PageSummaryFallbackPreservesEvidenceAsPartial) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  const GURL endpoint("https://api.openai.com/v1/responses");
  // 分别覆盖完成参数错误、必需工具错误以及无法解析的模型响应。
  for (int malformed_kind : {0, 1, 2}) {
    SCOPED_TRACE(malformed_kind);
    const std::string task_id = content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const result = await BrowserProxy.getInstance().handler.createTask(
            $1, 1, 1, [], 0);
        return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
      })()
    )JS", malformed_kind == 0 ? "不要整理书签，总结当前页。" :
                               "总结当前页")).ExtractString();
    ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
    AgentTask* task = service->GetTask(task_id);
    ASSERT_TRUE(task);
    ASSERT_TRUE(service->BeginPlanning(task_id));
    AgentModelEvent plan;
    plan.type = AgentModelEventType::kToolCall;
    plan.tool_name = "agent.submit_plan";
    plan.tool_call_id = "summary-plan";
    plan.arguments.Set("schema_version", kAgentSchemaVersion);
    plan.arguments.Set("summary", "读取页面后总结");
    base::DictValue step;
    step.Set("id", "observe");
    step.Set("title", "读取页面内容");
    step.Set("tool", "page.observe");
    base::ListValue steps;
    steps.Append(std::move(step));
    plan.arguments.Set("steps", std::move(steps));
    std::string error;
    ASSERT_TRUE(service->AcceptModelPlan(task_id, plan, &error)) << error;
    network::TestURLLoaderFactory factory;
    service->SetTaskModelClientForTesting(
        task_id,
        std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
    // 由真实页面处理器启动，完成回调才会把服务结果推送给侧栏。
    EXPECT_EQ(content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        return (await BrowserProxy.getInstance().handler.consentAndRun($1))
            .snapshot.state;
      })()
    )JS", task_id)).ExtractString(), "running");
    const auto respond = [&](const char* tool, base::DictValue arguments) {
      factory.WaitForRequest(endpoint);
      base::DictValue call;
      call.Set("type", "function_call");
      call.Set("call_id", std::string("summary-") + tool);
      call.Set("name", tool);
      call.Set("arguments", *base::WriteJson(arguments));
      base::ListValue output;
      output.Append(std::move(call));
      base::DictValue response;
      response.Set("status", "completed");
      response.Set("output", std::move(output));
      EXPECT_TRUE(factory.SimulateResponseForPendingRequest(
          endpoint.spec(), *base::WriteJson(response)));
    };
    for (int attempt = 0; attempt < 2; ++attempt) {
      if (malformed_kind == 2) {
        factory.WaitForRequest(endpoint);
        ASSERT_TRUE(factory.SimulateResponseForPendingRequest(
            endpoint.spec(), "{invalid-json"));
      } else {
        respond(malformed_kind == 0 ? "agent.complete" : "tab.list", {});
      }
    }
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return service->GetCompletionSummary(task_id) != nullptr;
    }));
    const AgentCompletionSummary* completion =
        service->GetCompletionSummary(task_id);
    ASSERT_TRUE(completion);
    EXPECT_EQ(completion->outcome, "partial");
    EXPECT_NE(completion->summary.find("尚未完成内容整理"),
              std::string::npos);
    EXPECT_EQ(completion->unfinished_items.size(), 1u);
    EXPECT_EQ(completion->source_urls,
              std::vector<std::string>{page_url.spec()});
    EXPECT_EQ(task->tool_calls_used(), 1);
    EXPECT_EQ(task->model_calls_used(), 2);
    EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task_id));
    // Runtime已终止，但界面必须明确显示“部分完成”，不能显示普通成功。
    ASSERT_TRUE(base::test::RunUntil([&]() {
      const auto visible = content::EvalJs(panel, R"JS(
        (async () => {
          const {BrowserProxy} = await import('./browser_proxy.js');
          const {loadTimeData} = await import('//resources/js/load_time_data.js');
          const {snapshot} = await BrowserProxy.getInstance().handler.getSnapshot();
          return snapshot.resultOutcome === 'partial' &&
              document.querySelector('#status').textContent ===
                  loadTimeData.getString('statusPartial') &&
              document.querySelector('#result-card').dataset.outcome === 'partial' &&
              document.querySelector('#unfinished-items').children.length === 1;
        })()
      )JS");
      EXPECT_TRUE(visible.is_ok()) << visible;
      return visible.is_ok() && visible.ExtractBool();
    }));
  }
}

IN_PROC_BROWSER_TEST_F(
    AegisAgentBrowserTest,
    TranslationCompletionRequiresFaithfulReviewAndPreservesBudgets) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/translation-review") {
          return nullptr;
        }
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_content_type("text/html; charset=utf-8");
        response->set_content(
            "<!doctype html><meta charset=utf-8><title>Battery trial</title>"
            "<main><h1>Battery trial</h1>"
            "<p>Device A lasted 120 minutes; device B lasted 60 minutes.</p>"
            "<p>The trial does not prove safety.</p></main>");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL page_url = embedded_test_server()->GetURL("/translation-review");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  base::test::TestFuture<bool> storage;
  service->FlushTaskStoreForTesting(storage.GetCallback());
  ASSERT_TRUE(storage.Get());
  const int32_t tab_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  const GURL endpoint("https://api.openai.com/v1/responses");
  constexpr char kGoal[] = "将当前网页的标题和全部正文完整翻译成中文，保留免责声明。";
  constexpr char kFaithful[] =
      "电池试验\n设备 A 持续运行了两小时；设备 B 持续运行了一小时。\n"
      "本次试验并不能证明安全性。";
  constexpr char kNegative[] =
      "电池试验\n设备 A 持续运行了60分钟；设备 B 持续运行了120分钟。\n"
      "本次试验证明了安全性。";
  // 模拟判定只验证宿主如何处理复核结果，不证明真实模型能识别语义错误。
  // 正例允许等价单位换算；反例保留数字却调换归属并反转否定。
  struct Scenario {
    const char* name;
    bool initially_faithful;
    bool regenerate;
    bool finally_faithful;
    bool invalid_review;
    int model_budget;
    int model_calls;
    int observe_steps = 1;
    int network_budget = 0;
    int segment_error = 0;
    int selection_error = 0;
    bool main_heading_only = false;
    bool model_partial = false;
    bool has_unfinished = false;
  };
  const Scenario scenarios[] = {
      {"faithful_positive", true, false, true, false, 20, 4},
      {"semantic_negative_twice", false, true, false, false, 20, 6},
      {"negative_then_faithful", false, true, true, false, 20, 6},
      {"invalid_review_twice", true, false, false, true, 20, 5},
      {"budget_exhausted_before_selection", true, false, false, false, 1, 1},
      {"budget_exhausted_before_completion", true, false, false, false, 2, 2},
      {"budget_exhausted_before_review", true, false, false, false, 3, 3},
      {"network_budget_exhausted_before_review", true, false, false, false, 20,
       3, 1, 3},
      {"page_evidence_history_lost", true, false, false, false, 30, 26, 26},
      {"missing_segment_twice", true, false, false, false, 20, 4, 1, 0, 1},
      {"duplicate_segment_twice", true, false, false, false, 20, 4, 1, 0, 2},
      {"unknown_segment_twice", true, false, false, false, 20, 4, 1, 0, 3},
      {"unstructured_translation_twice", true, false, false, false, 20, 4, 1, 0,
       4},
      {"invalid_selection_twice", true, false, false, false, 20, 3, 1, 0, 0, 1},
      {"unresolved_selection", true, false, false, false, 20, 2, 1, 0, 0, 2},
      {"main_heading_only", true, false, true, false, 20, 4, 1, 0, 0, 0, true},
      {"extra_translation_twice", true, false, false, false, 20, 4, 1, 0, 0, 3,
       true},
      {"partial_faithful_full", true, false, true, false, 20, 4, 1, 0, 0, 0,
       false, true},
      {"partial_faithful_heading", true, false, true, false, 20, 4, 1, 0, 0, 0,
       true, true},
      {"partial_semantic_negative_twice", false, true, false, false, 20, 6,
       1, 0, 0, 0, false, true},
      {"partial_missing_segment_twice", true, false, false, false, 20, 4,
       1, 0, 1, 0, false, true},
      {"partial_duplicate_segment_twice", true, false, false, false, 20, 4,
       1, 0, 2, 0, false, true},
      {"partial_unknown_segment_twice", true, false, false, false, 20, 4,
       1, 0, 3, 0, false, true},
      {"partial_unstructured_twice", true, false, false, false, 20, 4,
       1, 0, 4, 0, false, true},
      {"partial_extra_translation_twice", true, false, false, false, 20, 4,
       1, 0, 0, 3, true, true},
      {"partial_model_budget_before_review", true, false, false, false, 3, 3,
       1, 0, 0, 0, false, true},
      {"partial_network_budget_before_review", true, false, false, false, 20, 3,
       1, 3, 0, 0, false, true},
      {"partial_explicit_unfinished", true, false, false, false, 20, 3,
       1, 0, 0, 0, false, true, true},
  };
  for (const auto& scenario : scenarios) {
    SCOPED_TRACE(scenario.name);
    const char* goal = scenario.main_heading_only
                           ? "只把正文主标题翻译成中文，其他不要翻译。"
                           : kGoal;
    // 此测试只验证已批准的翻译执行；部分目标不触发另一个未模拟的模型路由。
    const std::string task_id =
        content::EvalJs(
            panel,
            content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const {snapshot} = await BrowserProxy.getInstance().handler.createTask(
            $1, 1, 0, $2 ? [$2] : [], 0);
        return snapshot.lastError ? `ERROR:${snapshot.lastError}` : snapshot.taskId;
      })()
    )JS",
                               goal,
                               scenario.main_heading_only
                                   ? url::Origin::Create(page_url).Serialize()
                                   : std::string()))
            .ExtractString();
    ASSERT_FALSE(task_id.empty());
    ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
    AgentTask* task = service->GetTask(task_id);
    ASSERT_TRUE(task);
    EXPECT_EQ(task->goal(), goal);
    ASSERT_TRUE(service->BeginPlanning(task_id));
    AgentTaskScope scope = task->scope();
    scope.budgets.max_model_calls = scenario.model_budget;
    if (scenario.network_budget) {
      scope.budgets.max_network_requests = scenario.network_budget;
    }
    ASSERT_TRUE(task->AdoptPlanScope(std::move(scope)));
    const AgentBudgets budgets = task->scope().budgets;
    AgentModelEvent plan;
    plan.type = AgentModelEventType::kToolCall;
    plan.tool_name = "agent.submit_plan";
    plan.tool_call_id = "translation-plan";
    plan.arguments.Set("schema_version", kAgentSchemaVersion);
    plan.arguments.Set("summary", "读取页面后完整翻译标题和正文");
    base::ListValue steps;
    for (int index = 0; index < scenario.observe_steps; ++index) {
      base::DictValue step;
      step.Set("id", index == 0 ? "observe" :
                                 "observe" + base::NumberToString(index));
      step.Set("title", "读取页面内容");
      step.Set("tool", "page.observe");
      steps.Append(std::move(step));
    }
    plan.arguments.Set("steps", std::move(steps));
    network::TestURLLoaderFactory factory;
    service->SetTaskModelClientForTesting(
        task_id,
        std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
    // 规划经过实际宿主传输与预算路径，响应仍由测试模拟器提供；不能把
    // 原有“规划后预算耗尽”的用例变成不再触及边界的宽松测试。
    base::test::TestFuture<bool, std::string> planned;
    service->RequestPlan(task_id, planned.GetCallback());
    factory.WaitForRequest(endpoint);
    auto planning_body = base::JSONReader::ReadDict(
        network::GetUploadData(factory.GetPendingRequest(0)->request),
        base::JSON_PARSE_RFC);
    ASSERT_TRUE(planning_body);
    const auto* choice = planning_body->FindDict("tool_choice");
    ASSERT_TRUE(choice && choice->FindString("name"));
    EXPECT_EQ(*choice->FindString("name"), "agent.submit_plan");
    base::DictValue planned_call;
    planned_call.Set("type", "function_call");
    planned_call.Set("call_id", "translation-plan");
    planned_call.Set("name", "agent.submit_plan");
    planned_call.Set("arguments", *base::WriteJson(plan.arguments));
    base::ListValue planned_output;
    planned_output.Append(std::move(planned_call));
    base::DictValue planned_response;
    planned_response.Set("status", "completed");
    planned_response.Set("output", std::move(planned_output));
    ASSERT_TRUE(factory.SimulateResponseForPendingRequest(
        endpoint.spec(), *base::WriteJson(planned_response)));
    ASSERT_TRUE(planned.Get<0>()) << planned.Get<1>();
    EXPECT_EQ(task->model_calls_used(), 1);
    ASSERT_EQ(content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        return (await BrowserProxy.getInstance().handler.consentAndRun($1))
            .snapshot.state;
      })()
    )JS", task_id)).ExtractString(), "running");
    int responses = 1;
    std::string candidate = scenario.initially_faithful ? kFaithful : kNegative;
    base::DictValue first_review_input;
    const auto respond = [&](const char* tool, base::DictValue arguments) {
      // 旧实现若提前终止，也应明确报错，不能无限等待不存在的复核请求。
      ASSERT_TRUE(base::test::RunUntil([&]() {
        return !factory.pending_requests()->empty() ||
               IsTerminalState(task->state());
      }));
      ASSERT_EQ(factory.pending_requests()->size(), 1u);
      const auto& request = factory.GetPendingRequest(0)->request;
      EXPECT_EQ(request.url, endpoint);
      auto body = base::JSONReader::ReadDict(network::GetUploadData(request),
                                           base::JSON_PARSE_RFC);
      ASSERT_TRUE(body);
      const auto* choice = body->FindDict("tool_choice");
      ASSERT_TRUE(choice);
      ASSERT_TRUE(choice->FindString("name"));
      EXPECT_EQ(*choice->FindString("name"), tool);
      const auto* tools = body->FindList("tools");
      ASSERT_TRUE(tools);
      ASSERT_EQ(tools->size(), 1u);
      ASSERT_TRUE((*tools)[0].GetDict().FindString("name"));
      EXPECT_EQ(*(*tools)[0].GetDict().FindString("name"), tool);
      EXPECT_EQ(task->goal(), goal);
      const auto* input = body->FindString("input");
      ASSERT_TRUE(input);
      auto prompt = base::JSONReader::ReadDict(*input, base::JSON_PARSE_RFC);
      ASSERT_TRUE(prompt);
      if (std::string_view(tool) != "agent.verify_translation" &&
          std::string_view(tool) != "agent.select_translation") {
        ASSERT_TRUE(prompt->FindString("user_goal"));
        EXPECT_EQ(*prompt->FindString("user_goal"), goal);
      }
      if (std::string_view(tool) == "agent.select_translation") {
        EXPECT_FALSE(service->GetCompletionSummary(task_id));
        ASSERT_TRUE(prompt->FindString("immutable_user_goal"));
        EXPECT_EQ(*prompt->FindString("immutable_user_goal"), goal);
        const auto* units =
            prompt->FindList("translation_source_units_untrusted");
        ASSERT_TRUE(units && units->size() == 3u);
        for (const auto& unit : *units) {
          EXPECT_FALSE(unit.GetDict().contains("translated_text"));
          EXPECT_FALSE(unit.GetDict().contains("omission_reason"));
        }
        const auto& heading = units->front().GetDict();
        ASSERT_TRUE(heading.FindString("source_kind"));
        EXPECT_EQ(*heading.FindString("source_kind"), "body_heading");
        EXPECT_EQ(heading.FindBool("also_document_title"), true);
        ASSERT_TRUE(heading.FindString("text_size"));
        EXPECT_EQ(*heading.FindString("text_size"), "XL");
      }
      if (std::string_view(tool) == "agent.complete") {
        const auto* units =
            prompt->FindList("translation_source_units_untrusted");
        ASSERT_TRUE(units);
        ASSERT_EQ(units->size(), 3u);
        const auto* selected =
            prompt->FindList("selected_translation_source_ids");
        ASSERT_TRUE(selected);
        EXPECT_EQ(selected->size(), scenario.main_heading_only ? 1u : 3u);
        base::ListValue translations;
        const bool faithful = candidate == kFaithful;
        for (const auto& unit : *units) {
          const auto& source = unit.GetDict();
          ASSERT_TRUE(source.FindInt("source_id"));
          const auto* text = source.FindString("source_text");
          ASSERT_TRUE(text);
          std::string translated;
          if (*text == "Battery trial") {
            translated = "电池试验";
          } else if (*text ==
                     "Device A lasted 120 minutes; device B lasted 60 "
                     "minutes.") {
            translated =
                faithful
                    ? "设备 A 持续运行了两小时；设备 B 持续运行了一小时。"
                    : "设备 A 持续运行了60分钟；设备 B 持续运行了120分钟。";
          } else {
            ASSERT_EQ(*text, "The trial does not prove safety.");
            translated = faithful ? "本次试验并不能证明安全性。"
                                  : "本次试验证明了安全性。";
          }
          base::DictValue segment;
          segment.Set("source_id", *source.FindInt("source_id"));
          segment.Set("translated_text", std::move(translated));
          segment.Set("omission_reason", "");
          if (scenario.main_heading_only && scenario.selection_error != 3 &&
              *source.FindInt("source_id") != 1) {
            segment.Set("translated_text", "");
            segment.Set("omission_reason", "用户只要求正文主标题");
          }
          translations.Append(std::move(segment));
        }
        if (scenario.segment_error == 1) {
          translations.erase(translations.begin());
        } else if (scenario.segment_error == 2) {
          translations[0].GetDict().Set("source_id", 2);
        } else if (scenario.segment_error == 3) {
          translations[0].GetDict().Set("source_id", 99);
        }
        if (scenario.segment_error != 4) {
          arguments.Set("translation_segments", std::move(translations));
        }
        if (scenario.segment_error && responses >= 3) {
          EXPECT_TRUE(
              prompt->FindString("previous_model_call_rejected_because"));
        }
      }
      if (std::string_view(tool) == "agent.verify_translation") {
        // 中文候选即使声称 completed，复核返回前也不能完成任务。
        EXPECT_FALSE(IsTerminalState(task->state()));
        EXPECT_FALSE(service->GetCompletionSummary(task_id));
        EXPECT_EQ(task->tool_calls_used(), 1);
        auto& review = prompt;
        ASSERT_TRUE(review->FindString("immutable_user_goal"));
        EXPECT_EQ(*review->FindString("immutable_user_goal"), goal);
        EXPECT_EQ(review->FindBool("browser_selected_scope"), true);
        const auto* pairs = review->FindList("translation_units_untrusted");
        ASSERT_TRUE(pairs);
        ASSERT_EQ(pairs->size(), scenario.main_heading_only ? 1u : 3u);
        std::string reviewed_translation;
        std::string source_text;
        for (const auto& pair_value : *pairs) {
          const auto& pair = pair_value.GetDict();
          ASSERT_TRUE(pair.FindString("translated_text"));
          ASSERT_TRUE(pair.FindString("source_text"));
          if (!reviewed_translation.empty()) {
            reviewed_translation.push_back('\n');
          }
          reviewed_translation += *pair.FindString("translated_text");
          source_text += *pair.FindString("source_text");
        }
        EXPECT_EQ(reviewed_translation,
                  scenario.main_heading_only ? "电池试验" : candidate);
        EXPECT_FALSE(review->contains("candidate_output_untrusted"));
        EXPECT_EQ(review->FindBool("source_truncated"), false);
        const auto* sources = review->FindList("source_documents_untrusted");
        ASSERT_TRUE(sources);
        ASSERT_EQ(sources->size(), 1u);
        const auto& source = (*sources)[0].GetDict();
        ASSERT_TRUE(source.FindString("url"));
        EXPECT_EQ(*source.FindString("url"), page_url.spec());
        EXPECT_FALSE(source.contains("title"));
        if (!scenario.main_heading_only) {
          EXPECT_NE(source_text.find("Device A lasted 120 minutes; "
                                     "device B lasted 60 minutes."),
                    std::string::npos);
          EXPECT_NE(source_text.find("The trial does not prove safety."),
                    std::string::npos);
        }
        const auto* observed =
            service->FindRecordedResult(task_id, task_id + ":observe:1");
        ASSERT_TRUE(observed && observed->ok);
        for (const char* key : {"document_token", "observation_fingerprint"}) {
          ASSERT_TRUE(source.FindString(key));
          ASSERT_TRUE(observed->value.FindString(key));
          EXPECT_EQ(*source.FindString(key), *observed->value.FindString(key));
        }
        if (first_review_input.empty()) {
          EXPECT_FALSE(review->contains("format_correction"));
          first_review_input = review->Clone();
        } else if (scenario.invalid_review) {
          ASSERT_TRUE(review->FindString("format_correction"));
          EXPECT_FALSE(review->FindString("format_correction")->empty());
          review->Remove("format_correction");
          EXPECT_EQ(*review, first_review_input);
        }
      }
      base::DictValue call;
      call.Set("type", "function_call");
      call.Set("call_id", task_id + "-" + base::NumberToString(++responses));
      call.Set("name", tool);
      call.Set("arguments", *base::WriteJson(arguments));
      base::ListValue output;
      output.Append(std::move(call));
      base::DictValue response;
      response.Set("status", "completed");
      response.Set("output", std::move(output));
      ASSERT_TRUE(factory.SimulateResponseForPendingRequest(
          endpoint.spec(), *base::WriteJson(response)));
    };
    const auto complete = [&]() {
      base::DictValue completion;
      completion.Set("outcome", scenario.model_partial ? "partial" : "completed");
      completion.Set("summary", candidate);
      base::ListValue sources;
      sources.Append(page_url.spec());
      completion.Set("source_urls", std::move(sources));
      base::ListValue unfinished;
      if (scenario.has_unfinished) {
        unfinished.Append("仍需人工检查译文。");
      }
      completion.Set("unfinished_items", std::move(unfinished));
      ASSERT_NO_FATAL_FAILURE(respond("agent.complete", std::move(completion)));
    };
    const auto review = [&](bool faithful) {
      base::DictValue arguments;
      arguments.Set("target_language_met", true);
      arguments.Set("meaning_preserved", faithful);
      arguments.Set("requested_content_covered", true);
      base::ListValue issues;
      if (!faithful) {
        issues.Append("设备时长归属被调换，免责声明的否定含义被反转。");
      }
      if (scenario.invalid_review) {
        // 三个布尔值均正确，但 issues 类型错误；只能修复一次格式。
        arguments.Set("issues", "无问题");
      } else {
        arguments.Set("issues", std::move(issues));
      }
      ASSERT_NO_FATAL_FAILURE(
          respond("agent.verify_translation", std::move(arguments)));
    };
    for (int index = 1; index < scenario.observe_steps; ++index) {
      base::DictValue observe;
      observe.Set("tab_id", tab_id);
      ASSERT_NO_FATAL_FAILURE(respond("page.observe", std::move(observe)));
    }
    const bool has_selection =
        scenario.observe_steps <= 24 && scenario.model_budget > 1;
    if (has_selection) {
      const auto select = [&]() {
        base::DictValue arguments;
        arguments.Set("scope_resolved", scenario.selection_error != 2);
        base::ListValue ids;
        if (scenario.selection_error != 2) {
          ids.Append(scenario.selection_error == 1 ? 99 : 1);
          if (!scenario.main_heading_only) {
            ids.Append(2);
            ids.Append(3);
          }
        }
        arguments.Set("selected_source_ids", std::move(ids));
        base::ListValue issues;
        if (scenario.selection_error == 2)
          issues.Append("范围无法确定");
        arguments.Set("issues", std::move(issues));
        ASSERT_NO_FATAL_FAILURE(
            respond("agent.select_translation", std::move(arguments)));
      };
      ASSERT_NO_FATAL_FAILURE(select());
      if (scenario.selection_error == 1)
        ASSERT_NO_FATAL_FAILURE(select());
    }
    const bool has_completion = has_selection && scenario.model_budget > 2 &&
                                scenario.selection_error != 1 &&
                                scenario.selection_error != 2;
    if (has_completion)
      ASSERT_NO_FATAL_FAILURE(complete());
    if (scenario.segment_error || scenario.selection_error == 3) {
      ASSERT_NO_FATAL_FAILURE(complete());
    }
    const bool has_review = has_completion && scenario.model_budget > 3 &&
                            scenario.network_budget != 3 &&
                            !scenario.segment_error &&
                            scenario.selection_error != 3 &&
                            !scenario.has_unfinished;
    if (has_review) {
      ASSERT_NO_FATAL_FAILURE(review(scenario.initially_faithful));
      if (scenario.regenerate) {
        candidate = scenario.finally_faithful ? kFaithful : kNegative;
        ASSERT_NO_FATAL_FAILURE(complete());
        ASSERT_NO_FATAL_FAILURE(review(scenario.finally_faithful));
      } else if (scenario.invalid_review) {
        ASSERT_NO_FATAL_FAILURE(review(true));
      }
    }
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return IsTerminalState(task->state()) ||
             !factory.pending_requests()->empty();
    }));
    EXPECT_TRUE(factory.pending_requests()->empty());
    const auto* completion = service->GetCompletionSummary(task_id);
    ASSERT_TRUE(completion);
    EXPECT_EQ(completion->outcome,
              scenario.finally_faithful ? "completed" : "partial");
    if (scenario.finally_faithful) {
      EXPECT_EQ(completion->summary,
                scenario.main_heading_only ? "电池试验" : kFaithful);
      EXPECT_TRUE(completion->unfinished_items.empty());
    } else if (scenario.has_unfinished) {
      EXPECT_EQ(completion->outcome, "partial");
      EXPECT_EQ(completion->unfinished_items,
                std::vector<std::string>{"仍需人工检查译文。"});
    } else {
      EXPECT_NE(completion->summary.find("不能认定翻译完成"), std::string::npos);
      EXPECT_EQ(completion->unfinished_items.size(), 1u);
    }
    EXPECT_EQ(completion->source_urls,
              std::vector<std::string>{page_url.spec()});
    EXPECT_EQ(task->goal(), goal);
    EXPECT_EQ(task->tool_calls_used(), scenario.observe_steps);
    EXPECT_EQ(task->model_calls_used(), scenario.model_calls);
    EXPECT_EQ(responses, scenario.model_calls);
    EXPECT_EQ(task->network_requests_used(), scenario.model_calls);
    EXPECT_EQ(first_review_input.empty(), !has_review);
    EXPECT_EQ(task->scope().budgets.max_model_calls, budgets.max_model_calls);
    EXPECT_EQ(task->scope().budgets.max_tool_calls, budgets.max_tool_calls);
    EXPECT_EQ(task->scope().budgets.max_network_requests,
              budgets.max_network_requests);
    ASSERT_TRUE(service->GetPlan(task_id));
    EXPECT_EQ(service->GetPlan(task_id)->scope.budgets.max_model_calls,
              budgets.max_model_calls);
    EXPECT_EQ(service->GetPlan(task_id)->scope.budgets.max_tool_calls,
              budgets.max_tool_calls);
    EXPECT_EQ(service->GetPlan(task_id)->scope.budgets.max_network_requests,
              budgets.max_network_requests);
    EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task_id));
    // 服务的终止状态可为 completed，但侧栏必须按结果区分部分完成和普通成功。
    ASSERT_TRUE(base::test::RunUntil([&]() {
      const auto visible = content::EvalJs(
          panel, content::JsReplace(R"JS(
        (async () => {
          const {BrowserProxy} = await import('./browser_proxy.js');
          const {loadTimeData} = await import('//resources/js/load_time_data.js');
          const {snapshot} = await BrowserProxy.getInstance().handler.getSnapshot();
          const outcome = $2 ? 'completed' : 'partial';
          const status = document.querySelector('#status').textContent;
          return snapshot.taskId === $1 && snapshot.goal === $3 &&
              snapshot.resultOutcome === outcome &&
              document.querySelector('#result-card').dataset.outcome === outcome &&
              status === loadTimeData.getString($2 ? 'statusCompleted' : 'statusPartial') &&
              ($2 || status !== loadTimeData.getString('statusCompleted')) &&
              document.querySelector('#unfinished-items').children.length === ($2 ? 0 : 1);
        })()
      )JS",
                                    task_id, scenario.finally_faithful, goal));
      EXPECT_TRUE(visible.is_ok()) << visible;
      return visible.is_ok() && visible.ExtractBool();
    }));
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       TranslationWithoutPageBodyStopsInsteadOfHanging) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/empty-translation")
          return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_content_type("text/html; charset=utf-8");
        response->set_content(
            "<!doctype html><title>Empty page</title><body></body>");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL target = embedded_test_server()->GetURL("/empty-translation");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), target));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  base::test::TestFuture<bool> storage;
  service->FlushTaskStoreForTesting(storage.GetCallback());
  ASSERT_TRUE(storage.Get());
  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const {snapshot} = await BrowserProxy.getInstance().handler.createTask(
          '把当前页翻译成英文。', 1, 0, [], 0);
      return snapshot.lastError ? 'ERROR:' + snapshot.lastError : snapshot.taskId;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.empty());
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  auto* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  ASSERT_TRUE(service->BeginPlanning(task_id));
  AgentModelEvent plan;
  plan.type = AgentModelEventType::kToolCall;
  plan.tool_name = "agent.submit_plan";
  plan.tool_call_id = "empty-translation-plan";
  plan.arguments.Set("schema_version", kAgentSchemaVersion);
  plan.arguments.Set("summary", "读取当前页后翻译");
  base::ListValue steps;
  base::DictValue step;
  step.Set("id", "observe");
  step.Set("title", "读取页面");
  step.Set("tool", "page.observe");
  steps.Append(std::move(step));
  plan.arguments.Set("steps", std::move(steps));
  std::string error;
  ASSERT_TRUE(service->AcceptModelPlan(task_id, plan, &error)) << error;
  network::TestURLLoaderFactory factory;
  service->SetTaskModelClientForTesting(
      task_id,
      std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
  ASSERT_EQ(content::EvalJs(panel, content::JsReplace(R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      return (await BrowserProxy.getInstance().handler.consentAndRun($1)).snapshot.state;
    })()
  )JS",
                                                      task_id))
                .ExtractString(),
            "running");
  ASSERT_TRUE(
      base::test::RunUntil([&]() { return IsTerminalState(task->state()); }));
  const auto* observed =
      service->FindRecordedResult(task_id, task_id + ":observe:1");
  ASSERT_TRUE(observed && observed->ok);
  // 已手动提供计划；空正文读取后无需参数模型或猜测译文的模型请求。
  EXPECT_EQ(task->model_calls_used(), 0);
  EXPECT_EQ(task->network_requests_used(), 0);
  EXPECT_EQ(task->tool_calls_used(), 1);
  EXPECT_TRUE(factory.pending_requests()->empty());
  // APC 可能只保留文档容器。此时可保留来源并报告部分完成；没有容器证据则失败。
  // 两种情况都不能等待后续模型调用，也不能冒充翻译完成。
  if (const auto* completion = service->GetCompletionSummary(task_id)) {
    EXPECT_EQ(completion->outcome, "partial");
    EXPECT_FALSE(completion->unfinished_items.empty());
  } else {
    EXPECT_EQ(task->state(), AgentTaskState::kFailed);
  }
  EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task_id));
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const {snapshot} = await BrowserProxy.getInstance().handler.getSnapshot();
        return snapshot.taskId === $1 &&
            (snapshot.state === 'failed' || snapshot.resultOutcome === 'partial');
      })()
    )JS",
                                                     task_id))
        .ExtractBool();
  }));
}

IN_PROC_BROWSER_TEST_F(
    AegisAgentBrowserTest,
    Bookmark500CompletionAndFallbackUseVerifiedClassificationInVisibleResult) {
  Profile* profile = browser()->GetProfile();
  ConfigureAgentModel(profile);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  auto* model = BookmarkModelFactory::GetForBrowserContext(profile);
  ASSERT_TRUE(model);
  bookmarks::test::WaitForBookmarkModelToLoad(model);
  // 浏览器测试使用独立 Profile；五组标题各一百条，网址不参与主题命中。
  ASSERT_TRUE(model->bookmark_bar_node()->children().empty());
  ASSERT_TRUE(model->other_node()->children().empty());
  ASSERT_TRUE(model->mobile_node()->children().empty());
  const std::pair<std::string_view, std::string_view> groups[] = {
      {"开发文档", "开发"}, {"安全研究", "研究"}, {"产品资料", "其他"},
      {"测试工具", "其他"}, {"技术资讯", "开发"}};
  base::DictValue expected_nodes;
  for (const auto& [prefix, category] : groups) {
    for (int index = 1; index <= 100; ++index) {
      const std::string digits = base::NumberToString(index);
      const std::string title = std::string(prefix) + " " +
                                std::string(3 - digits.size(), '0') + digits;
      const auto* node = model->AddURL(
          model->bookmark_bar_node(),
          model->bookmark_bar_node()->children().size(),
          base::UTF8ToUTF16(title),
          GURL("https://fixture.example/item/" +
               base::NumberToString(expected_nodes.size() + 1)));
      ASSERT_TRUE(node);
      base::DictValue expected;
      expected.Set("title", title);
      expected.Set("category", std::string(category));
      expected_nodes.Set("local:" + node->uuid().AsLowercaseString(),
                         std::move(expected));
    }
  }
  ASSERT_EQ(expected_nodes.size(), 500u);
  // 保存整棵树，比较身份、标题、网址、父节点和顺序，也检测额外新增的目录。
  const auto snapshot_bookmarks = [&]() {
    base::ListValue snapshot;
    const auto append = [&](const auto& self,
                            const bookmarks::BookmarkNode* node) -> void {
      base::DictValue entry;
      entry.Set("id", base::NumberToString(node->id()));
      entry.Set("title", base::UTF16ToUTF8(node->GetTitle()));
      entry.Set("url", node->url().spec());
      entry.Set("parent", node->parent()
                              ? base::NumberToString(node->parent()->id())
                              : std::string());
      snapshot.Append(std::move(entry));
      for (const auto& child : node->children()) {
        self(self, child.get());
      }
    };
    append(append, model->root_node());
    return snapshot;
  };
  const base::ListValue original_bookmarks = snapshot_bookmarks();
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  auto* service = AegisAgentServiceFactory::GetForProfile(profile);
  ASSERT_TRUE(service);
  base::test::TestFuture<bool> storage;
  service->FlushTaskStoreForTesting(storage.GetCallback());
  ASSERT_TRUE(storage.Get());
  const int initial_tab_count = browser()->GetTabStripModel()->count();
  const GURL endpoint("https://api.openai.com/v1/responses");
  for (bool malformed_final : {false, true}) {
    SCOPED_TRACE(malformed_final ? "两次坏格式回退" : "模型伪造分类摘要");
    const std::string task_id = content::EvalJs(panel, R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        const result = await BrowserProxy.getInstance().handler.createTask(
            '按标题主题分类我的全部500条书签，给出各类数量和真实代表标题，' +
            '只生成整理预览，不修改书签。', 0, 1, [], 0);
        return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
      })()
    )JS").ExtractString();
    ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
    AgentTask* task = service->GetTask(task_id);
    ASSERT_TRUE(task);
    ASSERT_TRUE(service->BeginPlanning(task_id));
    AgentModelEvent plan;
    plan.type = AgentModelEventType::kToolCall;
    plan.tool_name = "agent.submit_plan";
    plan.tool_call_id = task_id + "-plan";
    plan.arguments.Set("schema_version", kAgentSchemaVersion);
    plan.arguments.Set("summary", "读取全部书签并生成主题分类预览");
    base::ListValue steps;
    for (const auto& [id, tool] :
         {std::pair{"list", "bookmark.list"},
          std::pair{"preview", "bookmark.plan"}}) {
      base::DictValue step;
      step.Set("id", id);
      step.Set("title", std::string(id) == "list" ? "读取书签" : "生成分类预览");
      step.Set("tool", tool);
      steps.Append(std::move(step));
    }
    plan.arguments.Set("steps", std::move(steps));
    std::string error;
    ASSERT_TRUE(service->AcceptModelPlan(task_id, plan, &error)) << error;
    ASSERT_EQ(task->scope().allowed_tools.size(), 2u);
    EXPECT_TRUE(task->scope().AllowsTool("bookmark.list"));
    EXPECT_TRUE(task->scope().AllowsTool("bookmark.plan"));
    EXPECT_TRUE(task->scope().allowed_origins.empty());
    EXPECT_FALSE(task->scope().AllowsTool("bookmark.check_urls"));
    EXPECT_FALSE(task->scope().AllowsTool("page.observe"));
    EXPECT_FALSE(task->scope().AllowsTool("bookmark.apply"));
    network::TestURLLoaderFactory factory;
    service->SetTaskModelClientForTesting(
        task_id,
        std::make_unique<AgentModelClient>(factory.GetSafeWeakWrapper()));
    // 必须由真实 handler 启动，最终完成回调才能推送到侧栏 DOM。
    ASSERT_EQ(content::EvalJs(panel, content::JsReplace(R"JS(
      (async () => {
        const {BrowserProxy} = await import('./browser_proxy.js');
        return (await BrowserProxy.getInstance().handler.consentAndRun($1))
            .snapshot.state;
      })()
    )JS", task_id)).ExtractString(), "running");
    int response_index = 0;
    const auto respond = [&](const char* tool, base::DictValue arguments) {
      // 只观察待处理请求，不调用会嵌套事件循环的 NumPending。
      if (!base::test::RunUntil([&]() {
            return !factory.pending_requests()->empty() ||
                   task->state() == AgentTaskState::kFailed;
          }) || factory.pending_requests()->empty()) {
        return false;
      }
      base::DictValue call;
      call.Set("type", "function_call");
      call.Set("call_id", task_id + "-response-" +
                              base::NumberToString(++response_index));
      call.Set("name", tool);
      call.Set("arguments", *base::WriteJson(arguments));
      base::ListValue output;
      output.Append(std::move(call));
      base::DictValue response;
      response.Set("status", "completed");
      response.Set("output", std::move(output));
      return factory.SimulateResponseForPendingRequest(
          endpoint.spec(), *base::WriteJson(response));
    };
    ASSERT_TRUE(respond("bookmark.list", {}));
    base::DictValue preview_arguments;
    // 当前严格 schema 的主题策略名称是 topic，semantic 不在枚举内。
    preview_arguments.Set("strategy", "topic");
    ASSERT_TRUE(respond("bookmark.plan", std::move(preview_arguments)));
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return service->FindRecordedResult(task_id, task_id + ":preview:1") ||
             task->state() == AgentTaskState::kFailed;
    }));
    const auto* listed =
        service->FindRecordedResult(task_id, task_id + ":list:1");
    ASSERT_TRUE(listed);
    ASSERT_TRUE(listed->ok);
    EXPECT_EQ(listed->value.FindBool("truncated"), false);
    const auto* nodes = listed->value.FindList("nodes");
    ASSERT_TRUE(nodes);
    EXPECT_EQ(std::ranges::count_if(*nodes, [](const base::Value& node) {
                const auto* kind = node.GetDict().FindString("kind");
                return kind && *kind == "url";
              }), 500);
    const auto* preview =
        service->FindRecordedResult(task_id, task_id + ":preview:1");
    ASSERT_TRUE(preview);
    ASSERT_TRUE(preview->ok);
    const auto* moves = preview->value.FindList("moves");
    ASSERT_TRUE(moves);
    ASSERT_EQ(moves->size(), 500u);
    EXPECT_EQ(preview->value.FindInt("move_count"), 500);
    std::map<std::string, int> counts;
    std::map<std::string, std::string> representatives;
    base::DictValue seen_nodes;
    for (const auto& move : *moves) {
      const auto& value = move.GetDict();
      const auto* node_id = value.FindString("node_id");
      const auto* title = value.FindString("title");
      const auto* category = value.FindString("category");
      ASSERT_TRUE(node_id && title && category);
      const auto* expected = expected_nodes.FindDict(*node_id);
      ASSERT_TRUE(expected);
      EXPECT_EQ(*title, *expected->FindString("title"));
      EXPECT_EQ(*category, *expected->FindString("category"));
      EXPECT_FALSE(seen_nodes.contains(*node_id));
      seen_nodes.Set(*node_id, true);
      ++counts[*category];
      representatives.try_emplace(*category, *title);
    }
    const std::map<std::string, int> expected_counts = {
        {"开发", 200}, {"研究", 100}, {"其他", 200}};
    EXPECT_EQ(counts, expected_counts);
    if (malformed_final) {
      // 工具均已真实成功，连续两次缺少完成参数必须触发浏览器核对回退。
      ASSERT_TRUE(respond("agent.complete", {}));
      ASSERT_TRUE(respond("agent.complete", {}));
    } else {
      base::DictValue completion;
      completion.Set("outcome", "completed");
      completion.Set("summary",
                     "已完成全部500条书签分类：开发496，研究4，设计0。"
                     "研究代表标题：研究报告001。");
      completion.Set("source_urls", base::ListValue());
      completion.Set("unfinished_items", base::ListValue());
      ASSERT_TRUE(respond("agent.complete", std::move(completion)));
    }
    ASSERT_TRUE(base::test::RunUntil([&]() {
      return service->GetCompletionSummary(task_id) ||
             task->state() == AgentTaskState::kFailed;
    }));
    const auto* completion = service->GetCompletionSummary(task_id);
    ASSERT_TRUE(completion);
    EXPECT_EQ(task->state(), AgentTaskState::kCompleted);
    EXPECT_EQ(completion->outcome, "completed");
    EXPECT_TRUE(completion->source_urls.empty());
    EXPECT_TRUE(completion->unfinished_items.empty());
    EXPECT_NE(completion->summary.find("500"), std::string::npos);
    for (const auto& [category, count] : counts) {
      EXPECT_NE(completion->summary.find(category + "：" +
                                        base::NumberToString(count) + " 条"),
                std::string::npos) << completion->summary;
      EXPECT_NE(completion->summary.find(representatives.at(category)),
                std::string::npos) << completion->summary;
    }
    EXPECT_EQ(completion->summary.find("496"), std::string::npos);
    EXPECT_EQ(completion->summary.find("研究报告"), std::string::npos);
    EXPECT_NE(completion->summary.find("尚未应用"), std::string::npos);
    EXPECT_EQ(task->tool_calls_used(), 2);
    EXPECT_EQ(task->model_calls_used(), malformed_final ? 4 : 3);
    // 网络预算包含模型请求；本轮不应额外访问任何书签网址。
    EXPECT_EQ(task->network_requests_used(), task->model_calls_used());
    EXPECT_EQ(std::ranges::any_of(task->events(), [](const auto& event) {
                return event.reason ==
                       "browser verified all actions; model summary fallback used";
              }), malformed_final);
    EXPECT_FALSE(service->actor_bridge_for_testing().HasTask(task_id));
    ASSERT_TRUE(base::test::RunUntil([&]() {
      const auto visible = content::EvalJs(panel, content::JsReplace(R"JS(
        (async () => {
          const {BrowserProxy} = await import('./browser_proxy.js');
          const {snapshot} = await BrowserProxy.getInstance().handler.getSnapshot();
          const card = document.querySelector('#result-card');
          const summary = document.querySelector('#result-summary').textContent;
          return snapshot.taskId === $1 && snapshot.state === 'completed' &&
              snapshot.resultOutcome === 'completed' && snapshot.resultSummary === $2 &&
              !card.hidden && card.dataset.outcome === 'completed' && summary === $2 &&
              !summary.includes('496') && !summary.includes('研究报告') &&
              document.querySelector('#unfinished-items').children.length === 0 &&
              !document.querySelector('#error').textContent;
        })()
      )JS", task_id, completion->summary));
      EXPECT_TRUE(visible.is_ok()) << visible;
      return visible.is_ok() && visible.ExtractBool();
    }));
    EXPECT_EQ(snapshot_bookmarks(), original_bookmarks);
    EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count);
    EXPECT_EQ(browser()->GetActiveTabInterface()->GetURL(), GURL("about:blank"));
  }
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ChinesePunctuationTerminatesExplicitUrl) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->GetProfile());
  const GURL current_url = embedded_test_server()->GetURL("/title2.html");
  const GURL target_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), current_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->GetTabStripModel()->count();

  const std::string task_id =
      content::EvalJs(panel, content::JsReplace(R"JS(
        (async () => {
          const {BrowserProxy} = await import('./browser_proxy.js');
          const goal = `打开 ${$1}，读取页面标题和正文第一句话`;
          const result = await BrowserProxy.getInstance().handler
              .createTask(goal, 1, 0, [], 0);
          return result.snapshot.taskId ||
              `ERROR:${result.snapshot.lastError}`;
        })()
      )JS",
                                                target_url.spec()))
          .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return browser()->GetTabStripModel()->count() == initial_tab_count + 1 &&
           browser()->GetActiveTabInterface()->GetURL() == target_url;
  }));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       BareWwwDomainOpensHttpsTargetWithoutSearching) {
  ConfigureAgentModel(browser()->GetProfile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->GetTabStripModel()->count();

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler.createTask(
          '打开www.example.com告诉我最新消息', 1, 0, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  ASSERT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count + 1);
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_TRUE(
      task->scope().AllowsOrigin(GURL("https://www.example.com/latest")));
  EXPECT_TRUE(task->scope().AllowsOrigin(GURL("https://example.com/latest")));
  EXPECT_FALSE(
      task->scope().AllowsOrigin(GURL("https://unrelated.example.com/latest")));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       BrowserStewardStartsWithoutOpeningWebPage) {
  ConfigureAgentModel(browser()->GetProfile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->GetTabStripModel()->count();

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler
          .createTask('organize my bookmarks with a preview', 1, 1, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return service->task_count_for_testing() == 1u; }));
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count);
  EXPECT_TRUE(service->MostRecentTask()->scope().allowed_origins.empty());
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ModelCanCorrectGenericGoalToBrowserOnlyWorkflow) {
  ConfigureAgentModel(browser()->GetProfile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  chrome::AddTabAt(browser(), GURL("about:blank"), -1, false);
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->GetTabStripModel()->count();
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  AgentGoalRoute route;
  route.workflow = AgentWorkflowKind::kBrowserSteward;
  route.entry_kind = AgentGoalEntryKind::kBrowserOnly;
  route.summary = "先读取收藏夹，再生成分类预览";
  service->SetGoalRouteForTesting(route);

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler
          .createTask('把我的收藏夹按主题分类，先给我看预览', 1, 0, [], 0);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;
  EXPECT_EQ(browser()->GetTabStripModel()->count(), initial_tab_count);
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_TRUE(task->scope().allowed_origins.empty());
  EXPECT_TRUE(task->scope().AllowsTool("bookmark.plan"));
  EXPECT_EQ(task->scope().tab_metadata_window_id, 0);
  EXPECT_FALSE(task->scope().AllowsTool("tab.create"));
  EXPECT_FALSE(task->scope().AllowsTool("page.observe"));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       V2SpikeRoutesEntryOwnsTabAndRejectsStaleDocument) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  const GURL fixture_origin = embedded_test_server()->GetURL("/empty.html");
  V2RuntimeSpike runtime("isolated-test-profile", "v2-task",
                         {url::Origin::Create(fixture_origin)}, /*max_tabs=*/2);
  const GURL entry_url = runtime.RouteExplicitEntry(
      embedded_test_server()->GetURL("/title1.html"));
  ASSERT_TRUE(entry_url.is_valid());

  const int initial_tab_count = browser()->GetTabStripModel()->count();
  chrome::AddTabAt(browser(), entry_url, -1, true);
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return browser()->GetTabStripModel()->count() == initial_tab_count + 1 &&
           browser()->GetActiveTabInterface()->GetURL() == entry_url;
  }));
  TabStripModel* tabs = browser()->GetTabStripModel();
  const int task_index = tabs->active_index();
  const tab_groups::TabGroupId task_group = tabs->AddToNewGroup({task_index});
  EXPECT_EQ(tabs->GetTabGroupForTab(task_index), task_group);

  const int32_t tab_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();
  ASSERT_TRUE(runtime.AdoptOwnedTab(tab_id));
  V2DocumentBinding first_document{
      .profile_id = "isolated-test-profile",
      .task_id = "v2-task",
      .tab_id = tab_id,
      .frame_token = "primary-main-frame",
      .document_token = "document-before-navigation",
      .url = entry_url,
      .origin = url::Origin::Create(entry_url),
  };
  ASSERT_TRUE(runtime.CommitDocument(first_document));
  EXPECT_TRUE(content::EvalJs(tabs->GetActiveWebContents(),
                              "document.body.innerText.length > 0")
                  .ExtractBool());
  EXPECT_EQ(runtime.Authorize({.action_id = "extract-title",
                               .tool = V2SpikeTool::kExtract,
                               .binding = first_document}),
            V2SpikeDecision::kAllow);

  const GURL second_url = embedded_test_server()->GetURL("/title2.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), second_url));
  V2DocumentBinding second_document = first_document;
  second_document.document_token = "document-after-navigation";
  second_document.url = second_url;
  second_document.origin = url::Origin::Create(second_url);
  ASSERT_TRUE(runtime.CommitDocument(second_document));
  EXPECT_EQ(runtime.Authorize({.action_id = "stale-click",
                               .tool = V2SpikeTool::kClick,
                               .binding = first_document}),
            V2SpikeDecision::kStaleDocument);
  EXPECT_TRUE(runtime.MarkDomObservationFailed(second_document));
  EXPECT_TRUE(runtime.ConsumeVisualFallback(second_document));
  EXPECT_FALSE(runtime.ConsumeVisualFallback(second_document));

  EXPECT_EQ(runtime.Stop(), std::vector<int32_t>({tab_id}));
  EXPECT_EQ(runtime.owned_tab_count(), 0u);
  tabs->CloseWebContentsAt(task_index, TabCloseTypes::CLOSE_NONE);
  EXPECT_TRUE(base::test::RunUntil(
      [&]() { return tabs->count() == initial_tab_count; }));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       IncognitoHistoryUsesOnlyItsSessionAndTabsStayIsolated) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL regular_url =
      embedded_test_server()->GetURL("/title1.html?regular-only-marker");
  const GURL otr_first_url =
      embedded_test_server()->GetURL("/title2.html?otr-session-marker");
  const GURL otr_second_url =
      embedded_test_server()->GetURL("/title3.html?otr-session-marker");

  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), regular_url));
  const int32_t regular_tab_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();

  Browser* otr_browser = CreateIncognitoBrowser(browser()->GetProfile());
  ASSERT_TRUE(otr_browser);
  ASSERT_TRUE(otr_browser->GetProfile()->IsOffTheRecord());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(otr_browser, otr_first_url));
  ASSERT_TRUE(ui_test_utils::NavigateToURL(otr_browser, otr_second_url));
  const int32_t otr_tab_id =
      otr_browser->GetActiveTabInterface()->GetHandle().raw_value();

  AgentTaskScope scope;
  scope.allowed_origins = {url::Origin::Create(regular_url)};
  // Include a regular tab id deliberately. Tool lookup still must bind to the
  // exact OTR Profile instead of accepting a globally valid tab handle.
  scope.allowed_tab_ids = {regular_tab_id, otr_tab_id};
  scope.allowed_tools = {"history.search", "tab.list"};
  scope.allowed_data_classes = {AgentDataClass::kHistory,
                                AgentDataClass::kBrowserMetadata};
  scope.model_destination.provider = "aegis-local";
  scope.model_destination.model = "fixture";
  AgentTask task("incognito-history-task", "inspect incognito session",
                 AgentMode::kAsk, std::move(scope));
  AegisBrowserTools tools(otr_browser->GetProfile());

  AgentToolCall tab_call;
  tab_call.action_id = "list-incognito-tabs";
  tab_call.tool_name = "tab.list";
  base::test::TestFuture<AgentToolResult> tab_future;
  tools.Execute(&task, tab_call, tab_future.GetCallback());
  AgentToolResult tab_result = tab_future.Take();
  ASSERT_TRUE(tab_result.ok) << tab_result.message;
  const base::ListValue* returned_tabs = tab_result.value.FindList("tabs");
  ASSERT_TRUE(returned_tabs);
  ASSERT_EQ(returned_tabs->size(), 1u);
  EXPECT_EQ(returned_tabs->front().GetDict().FindInt("tab_id"), otr_tab_id);

  auto search_history = [&](std::string query) {
    AgentToolCall call;
    call.action_id = "search-" + query;
    call.tool_name = "history.search";
    call.arguments.Set("query", std::move(query));
    call.arguments.Set("days", 1);
    call.arguments.Set("max_results", 100);
    base::test::TestFuture<AgentToolResult> future;
    tools.Execute(&task, call, future.GetCallback());
    return future.Take();
  };

  AgentToolResult otr_history = search_history("otr-session-marker");
  ASSERT_TRUE(otr_history.ok) << otr_history.message;
  const base::ListValue* otr_results = otr_history.value.FindList("results");
  ASSERT_TRUE(otr_results);
  ASSERT_EQ(otr_results->size(), 2u);
  base::flat_set<std::string> otr_urls;
  for (const base::Value& value : *otr_results) {
    const std::string* url = value.GetDict().FindString("url");
    ASSERT_TRUE(url);
    otr_urls.insert(*url);
  }
  EXPECT_TRUE(std::ranges::any_of(otr_urls, [](const std::string& url) {
    return url.contains("/title2.html");
  }));
  EXPECT_TRUE(std::ranges::any_of(otr_urls, [](const std::string& url) {
    return url.contains("/title3.html");
  }));
  EXPECT_FALSE(std::ranges::any_of(otr_urls, [](const std::string& url) {
    return url.contains("/title1.html");
  }));

  AgentToolResult regular_history = search_history("regular-only-marker");
  ASSERT_TRUE(regular_history.ok) << regular_history.message;
  const base::ListValue* regular_results =
      regular_history.value.FindList("results");
  ASSERT_TRUE(regular_results);
  EXPECT_TRUE(regular_results->empty());
}

class AegisPrivacyProtectionBrowserTest : public InProcessBrowserTest {
 public:
  AegisPrivacyProtectionBrowserTest() {
    features_.InitWithFeatures(
        {features::kAegisLinkSanitize, features::kAegisPhishInterstitial},
        {features::kAegisFilterListUpdater});
  }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch(::switches::kDisableBackgroundNetworking);
    command_line->AppendSwitch(::switches::kNoProxyServer);
  }

  void SetUpOnMainThread() override {
    host_resolver()->AddRule("paypal-secure-login.com", "127.0.0.1");
    host_resolver()->AddRule("example.test", "127.0.0.1");
    InProcessBrowserTest::SetUpOnMainThread();
    AegisService* service =
        AegisServiceFactory::GetForProfile(browser()->GetProfile());
    ASSERT_TRUE(service);
    service->SetLinkSanitizeEnabled(true);
    service->SetPhishInterstitialEnabled(true);
  }

 private:
  base::test::ScopedFeatureList features_;
};

class AegisIncognitoGuardDisabledFeatureBrowserTest
    : public InProcessBrowserTest {
 public:
  AegisIncognitoGuardDisabledFeatureBrowserTest() {
    features_.InitAndDisableFeature(features::kAegisEnabled);
  }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch(::switches::kDisableBackgroundNetworking);
    command_line->AppendSwitch(::switches::kNoProxyServer);
  }

 private:
  base::test::ScopedFeatureList features_;
};

class AegisIncognitoFailedRestartBrowserTest : public InProcessBrowserTest {
 public:
  AegisIncognitoFailedRestartBrowserTest() {
    features_.InitAndDisableFeature(features::kAegisFilterListUpdater);
  }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitchASCII(switches::kRemoteAllowOrigins, "*");
    command_line->AppendSwitch(::switches::kDisableBackgroundNetworking);
    command_line->AppendSwitch(::switches::kNoProxyServer);
  }

 private:
  base::test::ScopedFeatureList features_;
};

IN_PROC_BROWSER_TEST_F(AegisIncognitoGuardDisabledFeatureBrowserTest,
                       IncognitoStillStopsProcessWideRemoteControl) {
  Profile* regular_profile = browser()->GetProfile();
  ASSERT_TRUE(regular_profile->IsRegularProfile());
  EXPECT_FALSE(base::FeatureList::IsEnabled(features::kAegisEnabled));
  EXPECT_EQ(AegisServiceFactory::GetForProfile(regular_profile), nullptr);

  AiControl external_control;
  ASSERT_TRUE(external_control.Start());
  ASSERT_TRUE(
      base::test::RunUntil([&]() { return external_control.running(); }));

  Profile* incognito_profile =
      regular_profile->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_TRUE(incognito_profile);
  EXPECT_TRUE(incognito_profile->IsPrimaryOTRProfile());
  EXPECT_TRUE(IsRemoteCdpBlockedForIncognito());
  EXPECT_FALSE(external_control.running());
  EXPECT_TRUE(
      content::DevToolsAgentHost::GetRemoteDebuggingServerAddress().empty());
  EXPECT_EQ(AegisServiceFactory::GetForProfile(incognito_profile), nullptr);
}

IN_PROC_BROWSER_TEST_F(AegisIncognitoFailedRestartBrowserTest,
                       FailedExplicitRestartPreservesIncognitoLatch) {
  Profile* regular_profile = browser()->GetProfile();
  AegisService* regular_service =
      AegisServiceFactory::GetForProfile(regular_profile);
  ASSERT_TRUE(regular_service);

  Profile* incognito_profile =
      regular_profile->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_TRUE(incognito_profile);
  EXPECT_TRUE(IsRemoteCdpBlockedForIncognito());
  regular_profile->DestroyOffTheRecordProfile(incognito_profile);
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return !regular_profile->HasPrimaryOTRProfile(); }));

  regular_service->SetAiControlEnabled(true);
  EXPECT_TRUE(IsRemoteCdpBlockedForIncognito());
  EXPECT_FALSE(regular_service->IsAiControlEnabled());
  EXPECT_FALSE(regular_service->AiControlRunning());
  EXPECT_FALSE(
      regular_profile->GetPrefs()->GetBoolean(prefs::kAiControlEnabled));
}

IN_PROC_BROWSER_TEST_F(AegisPrivacyProtectionBrowserTest,
                       TrackingParametersAreRemovedBeforePageLoad) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL clean_url =
      embedded_test_server()->GetURL("/title1.html?keep=yes");
  const GURL decorated_url(
      embedded_test_server()->GetURL("/title1.html").spec() +
      "?keep=yes&utm_source=aegis-fixture&fbclid=fixture-click");

  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), decorated_url));
  content::WebContents* contents =
      browser()->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(contents);
  EXPECT_EQ(contents->GetLastCommittedURL(), clean_url);
  EXPECT_FALSE(contents->GetLastCommittedURL().query().contains("utm_source"));
  EXPECT_FALSE(contents->GetLastCommittedURL().query().contains("fbclid"));

  bool found_event = false;
  AegisService* service =
      AegisServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  for (const PrivacyEvent& event : service->RecentPrivacyEvents()) {
    if (event.kind != "param") {
      continue;
    }
    found_event = true;
    EXPECT_NE(
        std::find(event.details.begin(), event.details.end(), "utm_source"),
        event.details.end());
    EXPECT_NE(std::find(event.details.begin(), event.details.end(), "fbclid"),
              event.details.end());
  }
  EXPECT_TRUE(found_event);
}

IN_PROC_BROWSER_TEST_F(AegisPrivacyProtectionBrowserTest,
                       IncognitoNavigationEventsStayInIncognitoService) {
  ASSERT_TRUE(embedded_test_server()->Start());
  Browser* incognito_browser = CreateIncognitoBrowser(browser()->GetProfile());
  ASSERT_TRUE(incognito_browser);
  Profile* incognito_profile = incognito_browser->GetProfile();
  ASSERT_TRUE(incognito_profile->IsIncognitoProfile());
  AegisService* regular_service =
      AegisServiceFactory::GetForProfile(browser()->GetProfile());
  AegisService* incognito_service =
      AegisServiceFactory::GetForProfile(incognito_profile);
  ASSERT_TRUE(regular_service);
  ASSERT_TRUE(incognito_service);
  ASSERT_NE(regular_service, incognito_service);

  const GURL decorated_url(
      embedded_test_server()->GetURL("/title1.html").spec() +
      "?keep=yes&utm_source=incognito-only&fbclid=private-click");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(incognito_browser, decorated_url));

  auto contains_private_event = [](const AegisService* service) {
    return std::ranges::any_of(
        service->RecentPrivacyEvents(), [](const PrivacyEvent& event) {
          return event.kind == "param" &&
                 std::ranges::find(event.details, "utm_source") !=
                     event.details.end() &&
                 std::ranges::find(event.details, "fbclid") !=
                     event.details.end();
        });
  };
  EXPECT_TRUE(contains_private_event(incognito_service));
  EXPECT_FALSE(contains_private_event(regular_service));
}

IN_PROC_BROWSER_TEST_F(AegisPrivacyProtectionBrowserTest,
                       IncognitoStopsAndBlocksProcessWideAiControl) {
  Profile* regular_profile = browser()->GetProfile();
  AegisService* regular_service =
      AegisServiceFactory::GetForProfile(regular_profile);
  ASSERT_TRUE(regular_service);
  ASSERT_TRUE(regular_service->IsAiControlAvailable());
  regular_service->SetAiControlEnabled(true);
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return regular_service->AiControlRunning(); }));

  Browser* incognito_browser = CreateIncognitoBrowser(regular_profile);
  ASSERT_TRUE(incognito_browser);
  EXPECT_TRUE(IsRemoteCdpBlockedForIncognito());
  EXPECT_FALSE(regular_service->IsAiControlAvailable());
  EXPECT_FALSE(regular_service->IsAiControlEnabled());
  EXPECT_FALSE(regular_service->AiControlRunning());
  EXPECT_FALSE(
      regular_profile->GetPrefs()->GetBoolean(prefs::kAiControlEnabled));

  ASSERT_TRUE(
      AegisServiceFactory::GetForProfile(incognito_browser->GetProfile()));
  CloseBrowserSynchronously(incognito_browser);
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return !regular_profile->HasPrimaryOTRProfile(); }));
  EXPECT_TRUE(IsRemoteCdpBlockedForIncognito());
  EXPECT_TRUE(regular_service->IsAiControlAvailable());
  EXPECT_FALSE(regular_service->IsAiControlEnabled());
  EXPECT_FALSE(regular_service->AiControlRunning());

  regular_service->SetAiControlEnabled(true);
  EXPECT_FALSE(IsRemoteCdpBlockedForIncognito());
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return regular_service->AiControlRunning(); }));
  regular_service->SetAiControlEnabled(false);
  EXPECT_FALSE(regular_service->AiControlRunning());
}

IN_PROC_BROWSER_TEST_F(
    AegisPrivacyProtectionBrowserTest,
    RegularAegisUiRefreshesAfterDelayedIncognitoDestruction) {
  ASSERT_TRUE(embedded_test_server()->Start());
  Profile* regular_profile = browser()->GetProfile();
  ASSERT_TRUE(
      ui_test_utils::NavigateToURL(browser(), GURL(chrome::kChromeUIAegisURL)));
  content::WebContents* regular_contents =
      browser()->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(regular_contents);
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return content::EvalJs(regular_contents, R"JS(
      (() => {
        const toggle = document.querySelector('#ai-control');
        return !!toggle && !toggle.disabled;
      })()
    )JS")
        .ExtractBool();
  }));
  EXPECT_TRUE(content::EvalJs(regular_contents, R"JS(
    (() => {
      window.aegisIncognitoRefreshSentinel = true;
      return true;
    })()
  )JS")
                  .ExtractBool());

  Browser* incognito_browser = CreateIncognitoBrowser(regular_profile);
  ASSERT_TRUE(incognito_browser);
  Profile* incognito_profile = incognito_browser->GetProfile();
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      incognito_browser, embedded_test_server()->GetURL("/title1.html")));
  std::unique_ptr<content::WebContents> delayed_otr_contents =
      content::WebContents::Create(
          content::WebContents::CreateParams(incognito_profile));
  ASSERT_TRUE(
      content::NavigateToURL(delayed_otr_contents.get(),
                             embedded_test_server()->GetURL("/title2.html")));
  ProfileDestructionProbe destruction_probe(incognito_profile);
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return content::EvalJs(regular_contents, R"JS(
      document.querySelector('#ai-control').disabled
    )JS")
        .ExtractBool();
  }));

  // Closing a live OTR renderer enters ProfileDestroyer's delayed path: the
  // destroy notification precedes removal from HasPrimaryOTRProfile(). The
  // existing regular WebUI must refresh after actual removal, without reload.
  CloseBrowserSynchronously(incognito_browser);
  ASSERT_TRUE(
      base::test::RunUntil([&]() { return destruction_probe.notified(); }));
  EXPECT_TRUE(destruction_probe.original_had_primary_otr());
  EXPECT_TRUE(regular_profile->HasPrimaryOTRProfile());
  EXPECT_TRUE(content::EvalJs(regular_contents, R"JS(
    document.querySelector('#ai-control').disabled
  )JS")
                  .ExtractBool());
  delayed_otr_contents.reset();
  ASSERT_TRUE(base::test::RunUntil([&]() {
    if (regular_profile->HasPrimaryOTRProfile()) {
      return false;
    }
    return !content::EvalJs(regular_contents, R"JS(
      document.querySelector('#ai-control').disabled
    )JS")
                .ExtractBool();
  }));
  EXPECT_TRUE(content::EvalJs(regular_contents, R"JS(
    window.aegisIncognitoRefreshSentinel === true
  )JS")
                  .ExtractBool());
}

#if !BUILDFLAG(IS_CHROMEOS)
IN_PROC_BROWSER_TEST_F(
    AegisPrivacyProtectionBrowserTest,
    SecondProfileIncognitoStopsAiControlBeforeBrowserOrRendererExists) {
  Profile* regular_profile = browser()->GetProfile();
  AegisService* regular_service =
      AegisServiceFactory::GetForProfile(regular_profile);
  ASSERT_TRUE(regular_service);
  regular_service->SetAiControlEnabled(true);
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return regular_service->AiControlRunning(); }));

  ProfileManager* profile_manager = g_browser_process->profile_manager();
  ASSERT_TRUE(profile_manager);
  Profile* second = &profiles::testing::CreateProfileSync(
      profile_manager, profile_manager->GenerateNextProfileDirectoryPath());
  // PostProfileInit eagerly installs the observer. This lookup must not create
  // the service and intentionally happens before any Browser or renderer.
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return AegisServiceFactory::GetForProfileIfExists(second); }));

  Profile* second_incognito =
      second->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_TRUE(second_incognito);
  EXPECT_TRUE(second_incognito->IsPrimaryOTRProfile());
  EXPECT_TRUE(IsRemoteCdpBlockedForIncognito());
  EXPECT_FALSE(regular_service->IsAiControlEnabled());
  EXPECT_FALSE(regular_service->AiControlRunning());
  EXPECT_TRUE(
      content::DevToolsAgentHost::GetRemoteDebuggingServerAddress().empty());
}
#endif

IN_PROC_BROWSER_TEST_F(AegisPrivacyProtectionBrowserTest,
                       ForcedIncognitoKeepsAegisSettingsCommandEnabled) {
  Profile* regular_profile = browser()->GetProfile();
  IncognitoModePrefs::SetAvailability(
      regular_profile->GetPrefs(), policy::IncognitoModeAvailability::kForced);

  Browser* incognito_browser = CreateIncognitoBrowser(regular_profile);
  ASSERT_TRUE(incognito_browser);
  ASSERT_TRUE(incognito_browser->GetProfile()->IsPrimaryOTRProfile());
  EXPECT_TRUE(chrome::IsCommandEnabled(incognito_browser, IDC_SHOW_AEGIS));
}

IN_PROC_BROWSER_TEST_F(
    AegisPrivacyProtectionBrowserTest,
    IncognitoStopsRemoteDebuggingNotOwnedByTheProfileService) {
  Profile* regular_profile = browser()->GetProfile();
  AegisService* regular_service =
      AegisServiceFactory::GetForProfile(regular_profile);
  ASSERT_TRUE(regular_service);
  ASSERT_FALSE(regular_service->AiControlRunning());

  // Simulate a process-wide endpoint created outside the Profile service.
  // DisableAiControlForIncognito() must still terminate it and its clients.
  AiControl external_control;
  ASSERT_TRUE(external_control.Start());
  ASSERT_TRUE(
      base::test::RunUntil([&]() { return external_control.running(); }));

  Browser* incognito_browser = CreateIncognitoBrowser(regular_profile);
  ASSERT_TRUE(incognito_browser);
  EXPECT_TRUE(IsRemoteCdpBlockedForIncognito());
  EXPECT_FALSE(external_control.running());
  EXPECT_TRUE(
      content::DevToolsAgentHost::GetRemoteDebuggingServerAddress().empty());
}

IN_PROC_BROWSER_TEST_F(AegisPrivacyProtectionBrowserTest,
                       BuiltInPhishingFixtureShowsAegisInterstitial) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL phishing_url =
      embedded_test_server()->GetURL("paypal-secure-login.com", "/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), phishing_url));
  content::WebContents* contents =
      browser()->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(contents);
  auto* helper =
      security_interstitials::SecurityInterstitialTabHelper::FromWebContents(
          contents);
  ASSERT_TRUE(helper);
  ASSERT_TRUE(helper->IsDisplayingInterstitial());
  auto* page =
      helper->GetBlockingPageForCurrentlyCommittedNavigationForTesting();
  ASSERT_TRUE(page);
  EXPECT_EQ(page->GetTypeForTesting(), AegisPhishBlockingPage::kTypeForTesting);
  const bool chinese_locale =
      base::StartsWith(g_browser_process->GetApplicationLocale(), "zh",
                       base::CompareCase::INSENSITIVE_ASCII);
  EXPECT_EQ(true, content::EvalJs(
                      contents,
                      content::JsReplace(
                          "document.body.innerText.includes($1)",
                          chinese_locale ? "Aegis 检测到疑似钓鱼线索"
                                         : "Aegis detected phishing signals")));

  bool found_event = false;
  AegisService* service =
      AegisServiceFactory::GetForProfile(browser()->GetProfile());
  ASSERT_TRUE(service);
  for (const PrivacyEvent& event : service->RecentPrivacyEvents()) {
    found_event |= event.kind == "phish" &&
                   event.display_domain == "paypal-secure-login.com";
  }
  EXPECT_TRUE(found_event);
}

IN_PROC_BROWSER_TEST_F(AegisPrivacyProtectionBrowserTest,
                       ToolbarSurvivesObservedPageDestroyedBeforeButton) {
  for (bool refresh_before_destroy : {false, true}) {
    auto button = std::make_unique<AegisToolbarButton>(browser());
    auto page = content::WebContents::Create(
        content::WebContents::CreateParams(browser()->GetProfile()));
    auto page_lifetime = page->GetWeakPtr();
    button->Update(page.get());
    page.reset();
    ASSERT_FALSE(page_lifetime);
    if (refresh_before_destroy) {
      button->OnAegisStateChanged();
      EXPECT_TRUE(button->GetVisible());
    }
    // Windows 原故障在这一步释放悬空 raw_ptr；保留默认内存安全检查。
    button.reset();
  }
}

IN_PROC_BROWSER_TEST_F(AegisPrivacyProtectionBrowserTest,
                       ToolbarSurvivesRepeatedBrowserWindowClose) {
  ASSERT_TRUE(embedded_test_server()->Start());
  for (int iteration = 0; iteration < 3; ++iteration) {
    Browser* extra = CreateBrowser(browser()->GetProfile());
    ASSERT_TRUE(ui_test_utils::NavigateToURL(
        extra, embedded_test_server()->GetURL("/title1.html")));
    auto page_lifetime =
        extra->GetTabStripModel()->GetActiveWebContents()->GetWeakPtr();
    ASSERT_TRUE(page_lifetime);
    CloseBrowserSynchronously(extra);
    EXPECT_FALSE(page_lifetime);
  }
}

IN_PROC_BROWSER_TEST_F(AegisPrivacyProtectionBrowserTest,
                       UnicodeSaltedCredentialPageShowsExplainedInterstitial) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/unicode-salting") {
          return nullptr;
        }
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK);
        response->set_content_type("text/html; charset=utf-8");
        response->set_content(
            "<!doctype html><meta charset=utf-8>"
            "<title>Pay&#xE0020;Pal</title>"
            "<p>ver&#xE0020;ify your acc&#x200B;ount</p>"
            "<form><input type=password></form>");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(),
      embedded_test_server()->GetURL("example.test", "/unicode-salting")));
  content::WebContents* contents =
      browser()->GetTabStripModel()->GetActiveWebContents();
  auto* helper =
      security_interstitials::SecurityInterstitialTabHelper::FromWebContents(
          contents);
  ASSERT_TRUE(helper);
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return helper->IsDisplayingInterstitial(); }));
  // 拦截页本来就是错误导航；等待加载结束后，下面单独验证拦截页类型和文案。
  content::WaitForLoadStopWithoutSuccessCheck(contents);
  auto* page =
      helper->GetBlockingPageForCurrentlyCommittedNavigationForTesting();
  ASSERT_TRUE(page);
  EXPECT_EQ(page->GetTypeForTesting(), AegisPhishBlockingPage::kTypeForTesting);
  const bool chinese_locale =
      base::StartsWith(g_browser_process->GetApplicationLocale(), "zh",
                       base::CompareCase::INSENSITIVE_ASCII);
  EXPECT_EQ(true,
            content::EvalJs(
                contents, content::JsReplace(
                              R"JS(
    document.body.innerText.includes($1) &&
        document.body.innerText.includes('Aegis')
  )JS",
                              chinese_locale
                                  ? "页面使用隐形字符干扰文本检测，已还原后检查"
                                  : "Invisible characters were removed before "
                                    "checking page text")));
}

}  // namespace
}  // namespace aegis::agent
