// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_tab_helper_unittest.cc

#include "chrome/browser/aegis/aegis_phish_tab_helper.h"

#include <utility>

#include "base/memory/weak_ptr.h"
#include "chrome/test/base/chrome_render_view_host_test_harness.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/test/navigation_simulator.h"
#include "net/base/net_errors.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {

class PhishTabHelperTestPeer {
 public:
  static void BeginPageSignalCheck(PhishTabHelper* helper,
                                   content::WeakDocumentPtr checking_document) {
    helper->checking_ = true;
    helper->checking_document_ = std::move(checking_document);
  }

  static void DeliverPageSignals(PhishTabHelper* helper,
                                 content::WeakDocumentPtr source_document) {
    helper->OnPageSignalsCollected(std::move(source_document),
                                   /*password_fields=*/1, /*forms=*/1,
                                   /*form_actions=*/{}, "Sign in",
                                   "Verify your account");
  }

  static void FailPageSignalCheck(PhishTabHelper* helper,
                                  content::WeakDocumentPtr source_document) {
    helper->OnPageSignalCollectionFailed(std::move(source_document));
  }

  static bool IsChecking(const PhishTabHelper* helper) {
    return helper->checking_;
  }

  static content::RenderFrameHost* CheckingFrame(const PhishTabHelper* helper) {
    return helper->checking_document_.AsRenderFrameHostIfValid();
  }

  static base::WeakPtr<PhishTabHelper> GetCallbackTarget(
      PhishTabHelper* helper) {
    return helper->weak_factory_.GetWeakPtr();
  }
};

namespace {

class PhishTabHelperTest : public ChromeRenderViewHostTestHarness {
 protected:
  void SetUp() override {
    ChromeRenderViewHostTestHarness::SetUp();
    PhishTabHelper::CreateForWebContents(web_contents());
  }

  PhishTabHelper* helper() {
    return PhishTabHelper::FromWebContents(web_contents());
  }
};

TEST_F(PhishTabHelperTest, ContinueOnceIsConsumedByFirstMatchingNavigation) {
  const GURL url("https://phish.example.test/login");
  helper()->AllowNextNavigationOnce(url);

  EXPECT_TRUE(helper()->ConsumeOneTimeNavigationBypass(url, 101));
  EXPECT_FALSE(helper()->ConsumeOneTimeNavigationBypass(url, 102));
}

TEST_F(PhishTabHelperTest, DifferentNextNavigationInvalidatesPermit) {
  const GURL permitted("https://phish.example.test/login");
  helper()->AllowNextNavigationOnce(permitted);

  EXPECT_FALSE(helper()->ConsumeOneTimeNavigationBypass(
      GURL("https://example.test/other"), 201));
  EXPECT_FALSE(helper()->ConsumeOneTimeNavigationBypass(permitted, 202));
}

TEST_F(PhishTabHelperTest, RedirectCancellationDoesNotRestorePermit) {
  const GURL url("https://phish.example.test/login");
  helper()->AllowNextNavigationOnce(url);

  ASSERT_TRUE(helper()->ConsumeOneTimeNavigationBypass(url, 301));
  helper()->CancelOneTimeNavigationBypass(301);
  EXPECT_FALSE(helper()->ConsumeOneTimeNavigationBypass(url, 302));
}

TEST_F(PhishTabHelperTest, NewPermitReplacesPreviousPermit) {
  const GURL first("https://first.example.test/login");
  const GURL second("https://second.example.test/login");
  helper()->AllowNextNavigationOnce(first);
  helper()->AllowNextNavigationOnce(second);

  EXPECT_TRUE(helper()->ConsumeOneTimeNavigationBypass(second, 401));
  EXPECT_FALSE(helper()->ConsumeOneTimeNavigationBypass(first, 402));
}

TEST_F(PhishTabHelperTest, ContinueOnceInvalidatesPendingPageSignalCheck) {
  const GURL url("https://phish.example.test/login");
  NavigateAndCommit(url);
  PhishTabHelperTestPeer::BeginPageSignalCheck(
      helper(), main_rfh()->GetWeakDocumentPtr());
  base::WeakPtr<PhishTabHelper> callback_target =
      PhishTabHelperTestPeer::GetCallbackTarget(helper());

  helper()->AllowNextNavigationOnce(url);

  EXPECT_FALSE(callback_target);
  EXPECT_FALSE(PhishTabHelperTestPeer::IsChecking(helper()));
  EXPECT_EQ(nullptr, PhishTabHelperTestPeer::CheckingFrame(helper()));
}

TEST_F(PhishTabHelperTest,
       LateCallbackCannotCompleteNewDocumentCheckAtSameUrl) {
  const GURL url("https://phish.example.test/login");
  NavigateAndCommit(url);
  content::WeakDocumentPtr old_document = main_rfh()->GetWeakDocumentPtr();
  PhishTabHelperTestPeer::BeginPageSignalCheck(helper(), old_document);

  helper()->AllowNextNavigationOnce(url);
  NavigateAndCommit(url);
  content::RenderFrameHost* new_frame = main_rfh();
  ASSERT_EQ(nullptr, old_document.AsRenderFrameHostIfValid());
  PhishTabHelperTestPeer::BeginPageSignalCheck(helper(),
                                               new_frame->GetWeakDocumentPtr());

  PhishTabHelperTestPeer::DeliverPageSignals(helper(), std::move(old_document));

  EXPECT_TRUE(PhishTabHelperTestPeer::IsChecking(helper()));
  EXPECT_EQ(new_frame, PhishTabHelperTestPeer::CheckingFrame(helper()));
}

TEST_F(PhishTabHelperTest, AbortedNavigationDoesNotCancelCurrentDocumentCheck) {
  const GURL url("https://phish.example.test/login");
  NavigateAndCommit(url);
  content::RenderFrameHost* checked_frame = main_rfh();
  PhishTabHelperTestPeer::BeginPageSignalCheck(
      helper(), checked_frame->GetWeakDocumentPtr());

  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      GURL("https://other.example.test/"), web_contents());
  navigation->Fail(net::ERR_ABORTED);

  EXPECT_TRUE(PhishTabHelperTestPeer::IsChecking(helper()));
  EXPECT_EQ(checked_frame, PhishTabHelperTestPeer::CheckingFrame(helper()));
}

TEST_F(PhishTabHelperTest, SameDocumentUrlChangeUsesCurrentUrl) {
  const GURL initial_url("http://paypal-login.example.test/login#before");
  const GURL current_url("http://paypal-login.example.test/login#after");
  NavigateAndCommit(initial_url);
  content::WeakDocumentPtr checked_document = main_rfh()->GetWeakDocumentPtr();
  PhishTabHelperTestPeer::BeginPageSignalCheck(helper(), checked_document);

  auto navigation = content::NavigationSimulator::CreateRendererInitiated(
      current_url, main_rfh());
  navigation->CommitSameDocument();
  ASSERT_EQ(current_url, main_rfh()->GetLastCommittedURL());

  PhishTabHelperTestPeer::DeliverPageSignals(helper(),
                                             std::move(checked_document));

  EXPECT_FALSE(PhishTabHelperTestPeer::IsChecking(helper()));
  EXPECT_TRUE(helper()->TakeStashedAssessment(current_url).has_value());
}

TEST_F(PhishTabHelperTest, CollectionDisconnectUnlocksMatchingDocument) {
  const GURL url("https://phish.example.test/login");
  NavigateAndCommit(url);
  content::WeakDocumentPtr checked_document = main_rfh()->GetWeakDocumentPtr();
  PhishTabHelperTestPeer::BeginPageSignalCheck(helper(), checked_document);

  PhishTabHelperTestPeer::FailPageSignalCheck(helper(),
                                              std::move(checked_document));

  EXPECT_FALSE(PhishTabHelperTestPeer::IsChecking(helper()));
  EXPECT_EQ(nullptr, PhishTabHelperTestPeer::CheckingFrame(helper()));
}

TEST_F(PhishTabHelperTest, ErrorDocumentIsNotScored) {
  const GURL url("https://phish.example.test/login");
  auto navigation =
      content::NavigationSimulator::CreateBrowserInitiated(url, web_contents());
  navigation->Fail(net::ERR_FAILED);
  navigation->CommitErrorPage();
  content::RenderFrameHost* error_frame = web_contents()->GetPrimaryMainFrame();
  ASSERT_TRUE(error_frame->IsErrorDocument());
  PhishTabHelperTestPeer::BeginPageSignalCheck(
      helper(), error_frame->GetWeakDocumentPtr());

  helper()->DOMContentLoaded(error_frame);

  EXPECT_FALSE(PhishTabHelperTestPeer::IsChecking(helper()));
  EXPECT_EQ(nullptr, PhishTabHelperTestPeer::CheckingFrame(helper()));
}

}  // namespace
}  // namespace aegis
