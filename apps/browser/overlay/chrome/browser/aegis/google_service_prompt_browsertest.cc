// Copyright 2026 GCSA
// 验证真实启动及用户操作：缺少 Google 配置时不在启动阶段提示。
#include "base/command_line.h"
#include "base/test/run_until.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/translate/chrome_translate_client.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_command_controller.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/signin/signin_view_controller.h"
#include "chrome/browser/ui/startup/infobar_utils.h"
#include "chrome/browser/ui/startup/startup_types.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/infobar.h"
#include "components/infobars/core/infobar_delegate.h"
#include "components/signin/public/base/signin_metrics.h"
#include "components/translate/core/browser/translate_manager.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "google_apis/google_api_keys.h"
#include "net/test/embedded_test_server/embedded_test_server.h"

namespace aegis {
class GoogleServicePromptBrowserTest : public InProcessBrowserTest {
 protected:
  content::WebContents* contents() {
    return browser()->tab_strip_model()->GetActiveWebContents();
  }

  size_t GooglePromptCount() {
    size_t count = 0;
    for (const auto& infobar :
         infobars::ContentInfoBarManager::FromWebContents(contents())
             ->infobars()) {
      if (infobar->delegate()->GetIdentifier() ==
          infobars::InfoBarDelegate::GOOGLE_API_KEYS_INFOBAR_DELEGATE) {
        ++count;
      }
    }
    return count;
  }
};

IN_PROC_BROWSER_TEST_F(GoogleServicePromptBrowserTest,
                       OrdinaryStartupWithoutKeyIsQuiet) {
  ASSERT_FALSE(google_apis::HasAPIKeyConfigured());
  // 不传测试启动标志，防止测试框架原有的横幅抑制掩盖回归。
  base::CommandLine ordinary_startup(base::CommandLine::NO_PROGRAM);
  AddInfoBarsIfNecessary(browser(), browser()->GetProfile(), ordinary_startup,
                         chrome::startup::IsFirstRun::kNo, false, false, false);
  EXPECT_EQ(0u, GooglePromptCount());
}

IN_PROC_BROWSER_TEST_F(GoogleServicePromptBrowserTest,
                       ExplicitTranslateWarnsOnceAndNavigationClearsIt) {
  ASSERT_FALSE(google_apis::HasAPIKeyConfigured());
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/english_page.html")));
  EXPECT_EQ(0u, GooglePromptCount());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !ChromeTranslateClient::FromWebContents(contents())
                ->GetLanguageState()
                .source_language()
                .empty();
  }));
  EXPECT_FALSE(ChromeTranslateClient::FromWebContents(contents())
                   ->GetTranslateManager()
                   ->CanManuallyTranslate());
  browser()->GetWindow()->Activate();
  ASSERT_TRUE(
      base::test::RunUntil([&] { return browser()->GetWindow()->IsActive(); }));
  chrome::BrowserCommandController::From(browser())->TabStateChanged();
  ASSERT_TRUE(chrome::IsCommandEnabled(browser(), IDC_SHOW_TRANSLATE));
  EXPECT_TRUE(chrome::ExecuteCommand(browser(), IDC_SHOW_TRANSLATE));
  EXPECT_EQ(1u, GooglePromptCount());
  EXPECT_TRUE(chrome::ExecuteCommand(browser(), IDC_SHOW_TRANSLATE));
  EXPECT_EQ(1u, GooglePromptCount());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/french_page.html")));
  EXPECT_EQ(0u, GooglePromptCount());
  ASSERT_TRUE(
      ui_test_utils::NavigateToURL(browser(), GURL("chrome://version")));
  chrome::BrowserCommandController::From(browser())->TabStateChanged();
  EXPECT_FALSE(chrome::IsCommandEnabled(browser(), IDC_SHOW_TRANSLATE));
}

IN_PROC_BROWSER_TEST_F(GoogleServicePromptBrowserTest,
                       ExplicitBrowserSigninExplainsMissingOAuth) {
  ASSERT_FALSE(google_apis::HasOAuthClientConfigured());
  const int tab_count = browser()->tab_strip_model()->count();
  const GURL original_url = contents()->GetLastCommittedURL();
  EXPECT_EQ(0u, GooglePromptCount());
  SigninViewController::From(browser())->ShowSignin(
      signin_metrics::AccessPoint::kSettings);
  EXPECT_EQ(1u, GooglePromptCount());
  EXPECT_EQ(tab_count, browser()->tab_strip_model()->count());
  EXPECT_EQ(original_url, contents()->GetLastCommittedURL());
}
}  // namespace aegis
