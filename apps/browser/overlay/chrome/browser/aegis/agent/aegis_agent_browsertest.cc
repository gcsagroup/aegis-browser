// Copyright 2026 GCSA

#include <algorithm>
#include <memory>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/test/run_until.h"
#include "base/test/scoped_feature_list.h"
#include "base/test/test_future.h"
#include "build/build_config.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/aegis/aegis_ai_control.h"
#include "chrome/browser/aegis/aegis_phish_blocking_page.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/aegis/aegis_service_factory.h"
#include "chrome/browser/aegis/agent/aegis_agent_service.h"
#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"
#include "chrome/browser/aegis/agent/v2_runtime_spike.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/prefs/incognito_mode_prefs.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/profiles/profile_test_util.h"
#include "chrome/browser/profiles/profile_window.h"
#include "chrome/browser/renderer_context_menu/render_view_context_menu_test_util.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
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
#include "chrome/common/aegis/cdp_target_filter.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "chrome/common/chrome_switches.h"
#include "chrome/common/webui_url_constants.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
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
#include "net/dns/mock_host_resolver.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/actions/actions.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {

SidePanelEntry* AgentEntry(Browser* browser) {
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
      browser->tab_strip_model()->GetActiveWebContents();
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
  Profile* profile = browser()->profile();
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
      browser()->GetActions()->root_action_item());
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
  Profile* profile = browser()->profile();
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
      browser()->GetActions()->root_action_item());
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
  Profile* profile = browser()->profile();
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
    browser()->profile()->GetPrefs()->SetBoolean(prefs::kAgentEnabled, true);
  }

 private:
  base::test::ScopedFeatureList features_;
};

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ProfileIsolationAndRestrictedProfiles) {
  Profile* regular = browser()->profile();
  ASSERT_TRUE(regular->IsRegularProfile());
  AegisAgentService* service = AegisAgentServiceFactory::GetForProfile(regular);
  ASSERT_TRUE(service);
  EXPECT_TRUE(service->IsEnabled());
  EXPECT_TRUE(IsAegisAgentSidePanelSupported(regular));
  EXPECT_TRUE(AgentEntry(browser()));
  EXPECT_TRUE(
      browser()->command_controller()->IsCommandEnabled(IDC_SHOW_AEGIS));

  Browser* otr_browser = CreateIncognitoBrowser(regular);
  ASSERT_TRUE(otr_browser);
  EXPECT_TRUE(otr_browser->profile()->IsOffTheRecord());
  EXPECT_TRUE(IsAegisAgentSidePanelSupported(otr_browser->profile()));
  EXPECT_TRUE(AgentEntry(otr_browser));
  EXPECT_TRUE(
      otr_browser->command_controller()->IsCommandEnabled(IDC_SHOW_AEGIS));
  AegisAgentService* otr_service =
      AegisAgentServiceFactory::GetForProfile(otr_browser->profile());
  ASSERT_TRUE(otr_service);
  EXPECT_NE(service, otr_service);
  EXPECT_EQ(otr_browser->profile(), otr_service->profile());
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
  EXPECT_TRUE(
      second_browser->command_controller()->IsCommandEnabled(IDC_SHOW_AEGIS));

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

  base::test::TestFuture<Browser*> guest_future;
  profiles::SwitchToGuestProfile(guest_future.GetCallback());
  Browser* guest_browser = guest_future.Get();
  ASSERT_TRUE(guest_browser);
  ASSERT_TRUE(guest_browser->profile()->IsGuestSession());
  EXPECT_FALSE(IsAegisAgentSidePanelSupported(guest_browser->profile()));
  EXPECT_FALSE(AgentEntry(guest_browser));
  EXPECT_FALSE(
      guest_browser->command_controller()->IsCommandEnabled(IDC_SHOW_AEGIS));
  EXPECT_EQ(AegisAgentServiceFactory::GetForProfile(guest_browser->profile()),
            nullptr);
#endif
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       IncognitoPanelCreatesMemoryOnlyIsolatedTask) {
  Profile* regular_profile = browser()->profile();
  AegisAgentService* regular_service =
      AegisAgentServiceFactory::GetForProfile(regular_profile);
  ASSERT_TRUE(regular_service);
  EXPECT_FALSE(regular_service->task_store_is_in_memory_for_testing());
  const size_t regular_task_count = regular_service->task_count_for_testing();

  Browser* incognito_browser = CreateIncognitoBrowser(regular_profile);
  ASSERT_TRUE(incognito_browser);
  Profile* incognito_profile = incognito_browser->profile();
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
  Profile* regular_profile = browser()->profile();
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
  Profile* incognito_profile = incognito_browser->profile();
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
  ConfigureAgentModel(browser()->profile());
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
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
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
  ConfigureAgentModel(browser()->profile());
  TemplateURLService* search =
      TemplateURLServiceFactory::GetForProfile(browser()->profile());
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
  const int initial_tab_count = browser()->tab_strip_model()->count();
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
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
    return browser()->tab_strip_model()->count() == initial_tab_count + 1 &&
           browser()->GetActiveTabInterface()->GetURL() == expected;
  }));
  EXPECT_EQ(service->task_count_for_testing(), 1u);
  EXPECT_TRUE(service->MostRecentTask()->scope().AllowsOrigin(expected));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       NamedSiteDiscoveryStaysOnNamedSiteAndReadOnlyWorkflow) {
  ConfigureAgentModel(browser()->profile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->tab_strip_model()->count();
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
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
  ASSERT_EQ(browser()->tab_strip_model()->count(), initial_tab_count + 1);
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
  ConfigureAgentModel(browser()->profile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->tab_strip_model()->count();
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
  EXPECT_EQ(browser()->tab_strip_model()->count(), initial_tab_count);
  EXPECT_EQ(browser()->GetActiveTabInterface()->GetURL(), page_url);

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
  ASSERT_TRUE(service);
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_TRUE(task->scope().AllowsTab(active_tab_id));
  EXPECT_TRUE(task->scope().AllowsOrigin(page_url));
  EXPECT_TRUE(task->scope().AllowsTool("page.observe"));
  EXPECT_TRUE(task->scope().AllowsTool("page.extract"));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ModelBrowserOnlyResearchRouteBindsCurrentPage) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->profile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->tab_strip_model()->count();
  const int32_t active_tab_id =
      browser()->GetActiveTabInterface()->GetHandle().raw_value();

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
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
  EXPECT_EQ(browser()->tab_strip_model()->count(), initial_tab_count);
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
  ConfigureAgentModel(browser()->profile());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->tab_strip_model()->count();

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
  EXPECT_EQ(browser()->tab_strip_model()->count(), initial_tab_count);

  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
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
                       ChinesePunctuationTerminatesExplicitUrl) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ConfigureAgentModel(browser()->profile());
  const GURL current_url = embedded_test_server()->GetURL("/title2.html");
  const GURL target_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), current_url));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->tab_strip_model()->count();

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
    return browser()->tab_strip_model()->count() == initial_tab_count + 1 &&
           browser()->GetActiveTabInterface()->GetURL() == target_url;
  }));
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       BareWwwDomainOpensHttpsTargetWithoutSearching) {
  ConfigureAgentModel(browser()->profile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->tab_strip_model()->count();

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
  ASSERT_EQ(browser()->tab_strip_model()->count(), initial_tab_count + 1);
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
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
  ConfigureAgentModel(browser()->profile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->tab_strip_model()->count();

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
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
  ASSERT_TRUE(service);
  ASSERT_TRUE(base::test::RunUntil(
      [&]() { return service->task_count_for_testing() == 1u; }));
  EXPECT_EQ(browser()->tab_strip_model()->count(), initial_tab_count);
  EXPECT_TRUE(service->MostRecentTask()->scope().allowed_origins.empty());
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       ModelCanCorrectGenericGoalToBrowserOnlyWorkflow) {
  ConfigureAgentModel(browser()->profile());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  const int initial_tab_count = browser()->tab_strip_model()->count();
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
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
  EXPECT_EQ(browser()->tab_strip_model()->count(), initial_tab_count);
  AgentTask* task = service->GetTask(task_id);
  ASSERT_TRUE(task);
  EXPECT_TRUE(task->scope().allowed_origins.empty());
  EXPECT_TRUE(task->scope().AllowsTool("bookmark.plan"));
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

  const int initial_tab_count = browser()->tab_strip_model()->count();
  chrome::AddTabAt(browser(), entry_url, -1, true);
  ASSERT_TRUE(base::test::RunUntil([&]() {
    return browser()->tab_strip_model()->count() == initial_tab_count + 1 &&
           browser()->GetActiveTabInterface()->GetURL() == entry_url;
  }));
  TabStripModel* tabs = browser()->tab_strip_model();
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

  Browser* otr_browser = CreateIncognitoBrowser(browser()->profile());
  ASSERT_TRUE(otr_browser);
  ASSERT_TRUE(otr_browser->profile()->IsOffTheRecord());
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
  AegisBrowserTools tools(otr_browser->profile());

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
    InProcessBrowserTest::SetUpOnMainThread();
    AegisService* service =
        AegisServiceFactory::GetForProfile(browser()->profile());
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
  Profile* regular_profile = browser()->profile();
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
  Profile* regular_profile = browser()->profile();
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
      browser()->tab_strip_model()->GetActiveWebContents();
  ASSERT_TRUE(contents);
  EXPECT_EQ(contents->GetLastCommittedURL(), clean_url);
  EXPECT_FALSE(contents->GetLastCommittedURL().query().contains("utm_source"));
  EXPECT_FALSE(contents->GetLastCommittedURL().query().contains("fbclid"));

  bool found_event = false;
  AegisService* service =
      AegisServiceFactory::GetForProfile(browser()->profile());
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
  Browser* incognito_browser = CreateIncognitoBrowser(browser()->profile());
  ASSERT_TRUE(incognito_browser);
  Profile* incognito_profile = incognito_browser->profile();
  ASSERT_TRUE(incognito_profile->IsIncognitoProfile());
  AegisService* regular_service =
      AegisServiceFactory::GetForProfile(browser()->profile());
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
  Profile* regular_profile = browser()->profile();
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

  ASSERT_TRUE(AegisServiceFactory::GetForProfile(incognito_browser->profile()));
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
  Profile* regular_profile = browser()->profile();
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), GURL(chrome::kChromeUIAegisURL)));
  content::WebContents* regular_contents =
      browser()->tab_strip_model()->GetActiveWebContents();
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
  Profile* incognito_profile = incognito_browser->profile();
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      incognito_browser, embedded_test_server()->GetURL("/title1.html")));
  std::unique_ptr<content::WebContents> delayed_otr_contents =
      content::WebContents::Create(
          content::WebContents::CreateParams(incognito_profile));
  ASSERT_TRUE(content::NavigateToURL(
      delayed_otr_contents.get(),
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
  Profile* regular_profile = browser()->profile();
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
  Profile* regular_profile = browser()->profile();
  IncognitoModePrefs::SetAvailability(
      regular_profile->GetPrefs(), policy::IncognitoModeAvailability::kForced);

  Browser* incognito_browser = CreateIncognitoBrowser(regular_profile);
  ASSERT_TRUE(incognito_browser);
  ASSERT_TRUE(incognito_browser->profile()->IsPrimaryOTRProfile());
  EXPECT_TRUE(incognito_browser->command_controller()->IsCommandEnabled(
      IDC_SHOW_AEGIS));
}

IN_PROC_BROWSER_TEST_F(
    AegisPrivacyProtectionBrowserTest,
    IncognitoStopsRemoteDebuggingNotOwnedByTheProfileService) {
  Profile* regular_profile = browser()->profile();
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
      browser()->tab_strip_model()->GetActiveWebContents();
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
  EXPECT_TRUE(content::EvalJs(contents, R"JS(
    document.body.innerText.includes('Aegis') &&
        document.body.innerText.toLowerCase().includes('phish')
  )JS")
                  .ExtractBool());

  bool found_event = false;
  AegisService* service =
      AegisServiceFactory::GetForProfile(browser()->profile());
  ASSERT_TRUE(service);
  for (const PrivacyEvent& event : service->RecentPrivacyEvents()) {
    found_event |= event.kind == "phish" &&
                   event.display_domain == "paypal-secure-login.com";
  }
  EXPECT_TRUE(found_event);
}

}  // namespace
}  // namespace aegis::agent
