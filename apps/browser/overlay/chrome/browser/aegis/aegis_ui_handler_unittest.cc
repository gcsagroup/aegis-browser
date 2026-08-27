// Copyright 2026 GCSA

#include "chrome/browser/ui/webui/aegis/aegis_ui_handler.h"

#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/browser_with_test_window_test.h"
#include "content/public/browser/web_contents.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

class AegisUIHandlerTest : public BrowserWithTestWindowTest {};

TEST_F(AegisUIHandlerTest, SelectsNearestHttpTabInSameWindow) {
  AddTab(browser(), GURL("https://left.example/"));
  AddTab(browser(), GURL("chrome://aegis/"));
  AddTab(browser(), GURL("https://right.example/"));
  TabStripModel* model = browser()->tab_strip_model();
  content::WebContents* settings = model->GetWebContentsAt(1);

  EXPECT_EQ(model->GetWebContentsAt(0),
            FindSummarySourceTabInModel(model, settings));

  NavigateAndCommit(model->GetWebContentsAt(0), GURL("about:blank"));
  EXPECT_EQ(model->GetWebContentsAt(2),
            FindSummarySourceTabInModel(model, settings));

  NavigateAndCommit(model->GetWebContentsAt(2), GURL("about:blank"));
  EXPECT_EQ(nullptr, FindSummarySourceTabInModel(model, settings));
}

TEST_F(AegisUIHandlerTest, RejectsTabFromAnotherWindowModel) {
  AddTab(browser(), GURL("https://source.example/"));
  TabStripModel* model = browser()->tab_strip_model();
  auto foreign = content::WebContents::Create(
      content::WebContents::CreateParams(profile()));

  EXPECT_EQ(nullptr, FindSummarySourceTabInModel(model, foreign.get()));
}

}  // namespace
}  // namespace aegis
