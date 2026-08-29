// Copyright 2026 GCSA

#include <utility>

#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/test/run_until.h"
#include "base/test/scoped_feature_list.h"
#include "base/test/test_future.h"
#include "build/build_config.h"
#include "chrome/browser/aegis/agent/aegis_agent_service.h"
#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_test_util.h"
#include "chrome/browser/profiles/profile_window.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "chrome/browser/ui/actions/chrome_action_id.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_actions.h"
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
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "chrome/common/chrome_switches.h"
#include "chrome/common/webui_url_constants.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/prefs/pref_service.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_service.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
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

class AegisAgentDefaultEntryBrowserTest : public InProcessBrowserTest {
 public:
  AegisAgentDefaultEntryBrowserTest() {
    features_.InitWithFeatures(
        {}, {features::kAegisFilterListUpdater,
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
  PinnedToolbarActionsModel* pinned =
      PinnedToolbarActionsModel::Get(profile);
  ASSERT_TRUE(pinned);
  EXPECT_TRUE(pinned->Contains(kActionSidePanelShowAegisAgent));
  EXPECT_TRUE(
      profile->GetPrefs()->GetBoolean(::prefs::kAegisAgentAutoPinnedMigration));
}

IN_PROC_BROWSER_TEST_F(AegisAgentDefaultEntryBrowserTest,
                       ExistingProfilePinsEntryOnlyOnce) {
  Profile* profile = browser()->profile();
  PinnedToolbarActionsModel* pinned =
      PinnedToolbarActionsModel::Get(profile);
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

  Browser* otr_browser = CreateIncognitoBrowser(regular);
  ASSERT_TRUE(otr_browser);
  EXPECT_TRUE(otr_browser->profile()->IsOffTheRecord());
  EXPECT_FALSE(IsAegisAgentSidePanelSupported(otr_browser->profile()));
  EXPECT_FALSE(AgentEntry(otr_browser));
  EXPECT_EQ(AegisAgentServiceFactory::GetForProfile(otr_browser->profile()),
            nullptr);

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
  EXPECT_EQ(AegisAgentServiceFactory::GetForProfile(guest_browser->profile()),
            nullptr);
#endif
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       LoadsUntrustedPanelAndRejectsOriginExpansion) {
  ASSERT_TRUE(embedded_test_server()->Start());
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
  EXPECT_EQ(content::EvalJs(contents, R"JS(
      new Promise(resolve => {
        const deadline = Date.now() + 5000;
        const poll = () => {
          const value = document.querySelector('#origins')?.value || '';
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
            expected_origin);

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
        new Promise(resolve => {
          const goal = document.querySelector('#goal');
          goal.value = 'Read one page';
          goal.dispatchEvent(new Event('input', {bubbles: true}));
          const origins = document.querySelector('#origins');
          origins.value = $1;
          origins.dispatchEvent(new Event('input', {bubbles: true}));
          document.querySelector('#plan-button').click();
          const deadline = Date.now() + 5000;
          const poll = () => {
            const value = document.querySelector('#error')?.textContent || '';
            if (value || Date.now() >= deadline) {
              resolve(value);
              return;
            }
            setTimeout(poll, 10);
          };
          poll();
        })
      )JS",
                                                   page_url.spec()))
          .ExtractString();
  EXPECT_EQ(error, "Task input is invalid");
  EXPECT_EQ(service->task_count_for_testing(), 0u);
}

IN_PROC_BROWSER_TEST_F(AegisAgentBrowserTest,
                       BlankPageGoalAutomaticallyOpensSearchTaskTab) {
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

  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("about:blank")));
  content::WebContents* panel = ShowAgentPanel(browser());
  ASSERT_TRUE(panel);
  EXPECT_FALSE(content::EvalJs(panel, R"JS(
    document.querySelector('#plan-button').disabled
  )JS")
                   .ExtractBool());
  const int initial_tab_count = browser()->tab_strip_model()->count();
  const GURL expected =
      search->GenerateSearchURLForDefaultSearchProvider(u"compare usb hubs");

  const std::string task_id = content::EvalJs(panel, R"JS(
    (async () => {
      const {BrowserProxy} = await import('./browser_proxy.js');
      const result = await BrowserProxy.getInstance().handler
          .createTask('compare usb hubs', 1, 0, []);
      return result.snapshot.taskId || `ERROR:${result.snapshot.lastError}`;
    })()
  )JS")
                                  .ExtractString();
  ASSERT_FALSE(task_id.starts_with("ERROR:")) << task_id;

  ASSERT_TRUE(base::test::RunUntil([&]() {
    return browser()->tab_strip_model()->count() == initial_tab_count + 1 &&
           browser()->GetActiveTabInterface()->GetURL() == expected;
  }));
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
  ASSERT_TRUE(service);
  EXPECT_EQ(service->task_count_for_testing(), 1u);
  EXPECT_TRUE(service->MostRecentTask()->scope().AllowsOrigin(expected));
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
          .createTask('organize my bookmarks with a preview', 1, 1, []);
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

}  // namespace
}  // namespace aegis::agent
