// Copyright 2026 GCSA

#include "chrome/browser/aegis/summary_session.h"

#include "chrome/test/base/chrome_render_view_host_test_harness.h"
#include "content/public/test/navigation_simulator.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {

class SummarySessionTestPeer {
 public:
  static bool IsSourceCurrent(const SummarySession& session) {
    return session.IsSourceCurrent();
  }
};

namespace {

class SummarySessionTest : public ChromeRenderViewHostTestHarness {};

TEST_F(SummarySessionTest, ExactDocumentAndUrlRemainCurrent) {
  NavigateAndCommit(GURL("https://source.example.test/article?token=hidden"));
  SummarySession session(web_contents(), "zh-CN");

  EXPECT_TRUE(SummarySessionTestPeer::IsSourceCurrent(session));
}

TEST_F(SummarySessionTest, CrossDocumentNavigationInvalidatesSource) {
  NavigateAndCommit(GURL("https://source.example.test/first"));
  SummarySession session(web_contents(), "zh-CN");

  NavigateAndCommit(GURL("https://source.example.test/second"));

  EXPECT_FALSE(SummarySessionTestPeer::IsSourceCurrent(session));
}

TEST_F(SummarySessionTest, SameDocumentUrlChangeInvalidatesSource) {
  const GURL initial("https://source.example.test/article#before");
  NavigateAndCommit(initial);
  SummarySession session(web_contents(), "zh-CN");

  auto navigation = content::NavigationSimulator::CreateRendererInitiated(
      GURL("https://source.example.test/article#after"), main_rfh());
  navigation->CommitSameDocument();

  EXPECT_FALSE(SummarySessionTestPeer::IsSourceCurrent(session));
}

TEST_F(SummarySessionTest, InternalPageCannotBecomeSummarySource) {
  NavigateAndCommit(GURL("chrome://version/"));
  SummarySession session(web_contents(), "zh-CN");

  EXPECT_FALSE(SummarySessionTestPeer::IsSourceCurrent(session));
}

}  // namespace
}  // namespace aegis
