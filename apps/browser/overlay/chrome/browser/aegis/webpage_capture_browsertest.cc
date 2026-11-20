// Copyright 2026 GCSA

#include "chrome/browser/aegis/webpage_capture.h"

#include "base/run_loop.h"
#include "base/test/run_until.h"
#include "base/test/scoped_feature_list.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/toolbar/app_menu_model.h"
#include "chrome/browser/ui/ui_features.h"
#include "chrome/common/pref_names.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/test_navigation_observer.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {

// Chromium 157 enables Actions by default; keep the legacy fallback working too.
class WebpageCaptureCommandBrowserTest
    : public InProcessBrowserTest,
      public testing::WithParamInterface<bool> {
 public:
  WebpageCaptureCommandBrowserTest() {
    features_.InitWithFeatureState(::features::kUseActionsForBrowserCommands,
                                   GetParam());
  }

  void SetUpOnMainThread() override {
    InProcessBrowserTest::SetUpOnMainThread();
    ASSERT_TRUE(embedded_test_server()->Start());
    ASSERT_TRUE(ui_test_utils::NavigateToURL(
        browser(), embedded_test_server()->GetURL("/title1.html")));
  }

 protected:
  content::WebContents* contents() {
    return browser()->GetTabStripModel()->GetActiveWebContents();
  }

 private:
  base::test::ScopedFeatureList features_;
};

IN_PROC_BROWSER_TEST_P(WebpageCaptureCommandBrowserTest,
                       AppMenuCommandOpensCapturedImage) {
  ASSERT_TRUE(CanCaptureWebpage(contents()));
  AppMenuModel menu(nullptr, browser());
  menu.Init();
  // An unmapped IDC is unsupported by CommandActionUpdater, even when the
  // legacy controller has a switch case and UpdateCommandEnabled call.
  ASSERT_TRUE(chrome::IsCommandEnabled(browser(), IDC_AEGIS_CAPTURE_FULL_PAGE));
  ASSERT_TRUE(menu.IsCommandIdEnabled(IDC_AEGIS_CAPTURE_FULL_PAGE));
  content::TestNavigationObserver navigation(contents());
  menu.ExecuteCommand(IDC_AEGIS_CAPTURE_FULL_PAGE, 0);
  navigation.Wait();
  ASSERT_EQ(GURL(kCapturePageUrl), contents()->GetLastCommittedURL());
  ASSERT_TRUE(content::WaitForLoadStop(contents()));
  // Prove that the command reached the real capture callback and produced PNG
  // pixels, rather than merely opening an empty/error preview page.
  EXPECT_TRUE(base::test::RunUntil([&]() {
    return content::EvalJs(contents(), R"JS(
      (() => {
        const image = document.getElementById('source');
        return !!image && image.src.startsWith('data:image/png;base64,') &&
            image.complete && image.naturalWidth > 0 && image.naturalHeight > 0;
      })()
    )JS").ExtractBool();
  }));
}

IN_PROC_BROWSER_TEST_P(WebpageCaptureCommandBrowserTest,
                       PolicyChangeAfterMenuCreationBlocksCapture) {
  const GURL original = contents()->GetLastCommittedURL();
  AppMenuModel menu(nullptr, browser());
  menu.Init();
  ASSERT_TRUE(menu.IsCommandIdEnabled(IDC_AEGIS_CAPTURE_FULL_PAGE));
  browser()->GetProfile()->GetPrefs()->SetBoolean(::prefs::kDisableScreenshots,
                                                 true);
  ASSERT_FALSE(CanCaptureWebpage(contents()));
  menu.ExecuteCommand(IDC_AEGIS_CAPTURE_FULL_PAGE, 0);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(original, contents()->GetLastCommittedURL());
  EXPECT_TRUE(TakeCapturedWebpage(contents()).png.empty());
}

IN_PROC_BROWSER_TEST_P(WebpageCaptureCommandBrowserTest,
                       CommandDoesNotCaptureInternalPage) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("chrome://version/")));
  ASSERT_FALSE(CanCaptureWebpage(contents()));
  ASSERT_TRUE(chrome::ExecuteCommand(browser(), IDC_AEGIS_CAPTURE_FULL_PAGE));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(GURL("chrome://version/"), contents()->GetLastCommittedURL());
  EXPECT_TRUE(TakeCapturedWebpage(contents()).png.empty());
}

INSTANTIATE_TEST_SUITE_P(ActionsAndLegacy,
                        WebpageCaptureCommandBrowserTest,
                        testing::Bool());

}  // namespace aegis
