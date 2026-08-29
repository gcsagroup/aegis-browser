// Copyright 2026 GCSA

#include <string>
#include <utility>
#include <vector>

#include "base/test/run_until.h"
#include "base/test/scoped_feature_list.h"
#include "build/build_config.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/aegis/agent/aegis_agent_service.h"
#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_element_identifiers.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/side_panel/side_panel_entry.h"
#include "chrome/browser/ui/side_panel/side_panel_entry_key.h"
#include "chrome/browser/ui/side_panel/side_panel_ui.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "chrome/common/webui_url_constants.h"
#include "chrome/test/base/interactive_test_utils.h"
#include "chrome/test/base/ui_test_utils.h"
#include "chrome/test/interaction/interactive_browser_test.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {

class AegisAgentInteractiveUiTest : public InteractiveBrowserTest {
 public:
  AegisAgentInteractiveUiTest() {
    features_.InitWithFeatures(
        {features::kAegisAgentWebMcp},
        {features::kAegisAgentTransactionPilot,
         features::kAegisFilterListUpdater, features::kAegisPhishInterstitial});
  }

  void SetUp() override {
    set_open_about_blank_on_browser_launch(true);
    InteractiveBrowserTest::SetUp();
  }

  void SetUpOnMainThread() override {
    InteractiveBrowserTest::SetUpOnMainThread();
    browser()->profile()->GetPrefs()->SetBoolean(prefs::kAgentEnabled, true);
    SidePanelUI* side_panel = browser()->GetFeatures().side_panel_ui();
    ASSERT_TRUE(side_panel);
    side_panel->SetNoDelaysForTesting(true);
    side_panel->DisableAnimationsForTesting();
  }

 private:
  base::test::ScopedFeatureList features_;
};

IN_PROC_BROWSER_TEST_F(AegisAgentInteractiveUiTest,
                       CommandOpensPanelAndControlsRemainInteractive) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL page_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), page_url));
  AegisAgentService* service =
      AegisAgentServiceFactory::GetForProfile(browser()->profile());
  ASSERT_TRUE(service);
  SidePanelUI* side_panel = browser()->GetFeatures().side_panel_ui();
  ASSERT_TRUE(side_panel);
  const std::string expected_origin = url::Origin::Create(page_url).Serialize();
  std::string monitor_task_id;

  RunTestSequence(
      EnsureNotPresent(kSidePanelElementId),
#if BUILDFLAG(IS_MAC)
      Do([&]() {
        EXPECT_TRUE(ui_test_utils::SendKeyPressSync(
            browser(), ui::VKEY_A, /*control=*/false, /*shift=*/true,
            /*alt=*/false, /*command=*/true));
      }),
#else
      Do([&]() { chrome::ExecuteCommand(browser(), IDC_SHOW_AEGIS_AGENT); }),
#endif
      WaitForShow(kSidePanelElementId),
      CheckResult(
          [&]() {
            return side_panel->IsSidePanelEntryShowing(
                SidePanelEntry::Key(SidePanelEntry::Id::kAegisAgent));
          },
          true),
      Do([&]() {
        content::WebContents* contents =
            side_panel->GetWebContentsForTest(SidePanelEntry::Id::kAegisAgent);
        ASSERT_TRUE(contents);
        ASSERT_TRUE(content::WaitForLoadStop(contents));
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
        EXPECT_TRUE(content::EvalJs(contents, R"JS(
          (() => {
            const modes = [...document.querySelectorAll('#mode-group button')];
            if (modes.length !== 3) {
              return false;
            }
            modes[1].click();
            const updatedModes =
                [...document.querySelectorAll('#mode-group button')];
            document.querySelector('#goal').focus();
            return updatedModes[1].getAttribute('aria-checked') === 'true' &&
                document.activeElement.id === 'goal' &&
                document.querySelector('#start-button').disabled &&
                document.querySelector('#pause-button').disabled &&
                document.querySelector('#approve-button').disabled &&
                document.querySelector('#approval-arguments') instanceof
                    HTMLPreElement &&
                document.querySelector('#approval-fingerprint') instanceof
                    HTMLElement;
          })()
        )JS")
                        .ExtractBool());

        AgentTaskScope scope;
        scope.allowed_origins = {url::Origin::Create(page_url)};
        scope.allowed_tab_ids = {
            browser()->GetActiveTabInterface()->GetHandle().raw_value()};
        scope.allowed_tools = {"page.observe", "monitor.create",
                               "monitor.list", "monitor.pause",
                               "monitor.delete"};
        scope.allowed_data_classes = {AgentDataClass::kPublicPage};
        scope.model_destination.provider = "aegis-local";
        scope.model_destination.model = "fixture";
        AgentTask* task = service->CreateTask(
            "monitor the fixture", AgentMode::kAutomate, std::move(scope));
        ASSERT_TRUE(task);
        monitor_task_id = task->id();
        ASSERT_TRUE(task->TransitionTo(AgentTaskState::kPlanning, "test"));
        ASSERT_TRUE(task->TransitionTo(AgentTaskState::kAwaitingTaskConsent,
                                       "test"));
        ASSERT_TRUE(task->TransitionTo(AgentTaskState::kRunning, "test"));
        AgentMonitorDefinition monitor;
        monitor.monitor_id = "monitor-ui-fixture";
        monitor.task_id = monitor_task_id;
        monitor.kind = AgentMonitorKind::kPageChange;
        monitor.origin = url::Origin::Create(page_url);
        monitor.target_hash = "sha256:ui-fixture";
        monitor.target_url = page_url;
        monitor.target_ciphertext = "encrypted-ui-fixture";
        monitor.interval = base::Minutes(15);
        monitor.next_run = base::Time::Now() + base::Hours(1);
        ASSERT_TRUE(service->UpsertMonitor(std::move(monitor)));
        ASSERT_TRUE(
            task->TransitionTo(AgentTaskState::kVerifying, "verified"));
        ASSERT_TRUE(service->CompleteTask(monitor_task_id));
      }),
      Do([&]() {
        content::WebContents* contents =
            side_panel->GetWebContentsForTest(SidePanelEntry::Id::kAegisAgent);
        ASSERT_TRUE(contents);
        EXPECT_TRUE(content::EvalJs(contents, R"JS(
          new Promise(resolve => {
            const deadline = Date.now() + 5000;
            const poll = () => {
              const toggle = document.querySelector(
                  '.monitor-actions button[data-monitor-action="toggle"]');
              const remove = document.querySelector(
                  '.monitor-actions button[data-monitor-action="delete"]');
              if (toggle && remove && !toggle.disabled && !remove.disabled) {
                toggle.click();
                resolve(true);
                return;
              }
              if (Date.now() >= deadline) {
                resolve(false);
                return;
              }
              setTimeout(poll, 10);
            };
            poll();
          })
        )JS")
                        .ExtractBool());
        EXPECT_TRUE(base::test::RunUntil([&]() {
          const std::vector<AgentMonitorDefinition> monitors =
              service->GetMonitors(monitor_task_id);
          return monitors.size() == 1u && !monitors[0].enabled;
        }));
        EXPECT_TRUE(content::EvalJs(contents, R"JS(
          new Promise(resolve => {
            const deadline = Date.now() + 5000;
            const poll = () => {
              const remove = document.querySelector(
                  '.monitor-actions button[data-monitor-action="delete"]');
              if (remove && !remove.disabled) {
                remove.click();
                resolve(true);
                return;
              }
              if (Date.now() >= deadline) {
                resolve(false);
                return;
              }
              setTimeout(poll, 10);
            };
            poll();
          })
        )JS")
                        .ExtractBool());
        EXPECT_TRUE(base::test::RunUntil(
            [&]() { return service->GetMonitors(monitor_task_id).empty(); }));
      }),
      PressButton(kSidePanelCloseButtonElementId),
      WaitForHide(kSidePanelElementId));
}

IN_PROC_BROWSER_TEST_F(AegisAgentInteractiveUiTest,
                       SettingsEntryOpensAgentSidePanel) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), GURL(chrome::kChromeUIAegisURL)));
  SidePanelUI* side_panel = browser()->GetFeatures().side_panel_ui();
  ASSERT_TRUE(side_panel);
  ASSERT_FALSE(side_panel->IsSidePanelEntryShowing(
      SidePanelEntry::Key(SidePanelEntry::Id::kAegisAgent)));

  ASSERT_TRUE(content::EvalJs(
                  browser()->GetActiveTabInterface()->GetContents(), R"JS(
        (() => {
          const button = document.querySelector('#browser-agent-open');
          if (!(button instanceof HTMLButtonElement) || button.disabled) {
            return false;
          }
          button.click();
          return true;
        })()
      )JS")
                  .ExtractBool());
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
}

}  // namespace
}  // namespace aegis::agent
