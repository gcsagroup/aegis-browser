// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_navigation_retry_tab_helper.h"

#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/test/bind.h"
#include "base/test/test_future.h"
#include "components/error_page/content/browser/net_error_auto_reloader.h"

#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/test/navigation_simulator.h"
#include "content/public/test/test_renderer_host.h"
#include "net/base/net_errors.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class AccessNavigationRetryTabHelperTest
    : public content::RenderViewHostTestHarness {
 protected:
  void SetUp() override {
    content::RenderViewHostTestHarness::SetUp();
    AccessNavigationRetryTabHelper::CreateForWebContents(web_contents());
  }
  AccessNavigationRetryTabHelper* helper() {
    return AccessNavigationRetryTabHelper::FromWebContents(web_contents());
  }
  void Fail(const GURL& url) {
    content::NavigationSimulator::NavigateAndFailFromBrowser(
        web_contents(), url, net::ERR_NAME_NOT_RESOLVED);
  }
};

TEST_F(AccessNavigationRetryTabHelperTest,
       ToolbarReloadsCommittedRedirectDestinationOnce) {
  const GURL original("https://start.example/");
  const GURL destination("https://destination.example/article#section");
  web_contents()->WasShown();
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      original, web_contents());
  navigation->Start();
  navigation->Redirect(destination);
  navigation->Commit();

  auto reload = helper()->CaptureSiteProxyReload();
  ASSERT_TRUE(reload);
  EXPECT_TRUE(helper()->IsPreparingProxyRetry());
  EXPECT_FALSE(helper()->CaptureSiteProxyReload());
  const int entries = controller().GetEntryCount();
  EXPECT_FALSE(controller().GetPendingEntry());
  std::move(reload).Run();
  EXPECT_FALSE(helper()->IsPreparingProxyRetry());
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), destination);
  auto reloading = content::NavigationSimulator::CreateFromPending(controller());
  EXPECT_EQ(reloading->GetNavigationHandle()->GetRequestMethod(), "GET");
  reloading->Commit();
  EXPECT_EQ(controller().GetEntryCount(), entries);
  EXPECT_FALSE(controller().GetPendingEntry());
}

TEST_F(AccessNavigationRetryTabHelperTest, ToolbarAbandonedRouteClearsStopState) {
  web_contents()->WasShown();
  content::NavigationSimulator::NavigateAndCommitFromBrowser(
      web_contents(), GURL("https://source.example/"));
  auto pending = helper()->CaptureSiteProxyReload();
  ASSERT_TRUE(pending);
  EXPECT_TRUE(helper()->IsPreparingProxyRetry());
  pending.Reset();
  EXPECT_FALSE(helper()->IsPreparingProxyRetry());
  EXPECT_FALSE(controller().GetPendingEntry());
}

TEST_F(AccessNavigationRetryTabHelperTest,
       ToolbarSkipsPostAndItsRedirectDestination) {
  web_contents()->WasShown();
  for (bool redirect : {false, true}) {
    auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
        GURL("https://source.example/form"), web_contents());
    navigation->SetMethod("POST");
    navigation->Start();
    if (redirect) navigation->Redirect(GURL("https://destination.example/"));
    navigation->Commit();
    EXPECT_FALSE(helper()->CaptureSiteProxyReload()) << redirect;
  }
}

TEST_F(AccessNavigationRetryTabHelperTest,
       ToolbarIgnoresHiddenStoppedOrSupersededDocument) {
  const GURL first("https://source.example/");
  const GURL second("https://destination.example/");
  web_contents()->WasShown();
  content::NavigationSimulator::NavigateAndCommitFromBrowser(web_contents(), first);
  auto hidden = helper()->CaptureSiteProxyReload();
  ASSERT_TRUE(hidden);
  web_contents()->WasHidden();
  web_contents()->WasShown();
  std::move(hidden).Run();
  EXPECT_FALSE(controller().GetPendingEntry());

  auto stopped = helper()->CaptureSiteProxyReload();
  ASSERT_TRUE(stopped);
  EXPECT_TRUE(helper()->IsPreparingProxyRetry());
  helper()->NavigationStopped();
  EXPECT_FALSE(helper()->IsPreparingProxyRetry());
  std::move(stopped).Run();
  EXPECT_FALSE(controller().GetPendingEntry());

  auto superseded = helper()->CaptureSiteProxyReload();
  ASSERT_TRUE(superseded);
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      second, web_contents());
  navigation->Start();
  EXPECT_FALSE(helper()->CaptureSiteProxyReload());
  std::move(superseded).Run();
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), second);
}

TEST_F(AccessNavigationRetryTabHelperTest, ReloadsOriginalUrlOnceAfterRedirect) {
  const GURL original("https://start.example/path?q=1#section");
  const GURL failed("https://target.example/redirect?q=2");
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      original, web_contents());
  navigation->Start();
  navigation->Redirect(failed);
  navigation->Fail(net::ERR_CONNECTION_RESET);
  navigation->CommitErrorPage();
  ASSERT_TRUE(helper()->FailureForRetry());
  EXPECT_EQ(helper()->FailureForRetry()->failed_url, failed);
  const int entry_count = controller().GetEntryCount();
  auto ready = helper()->CaptureRouteReadyCallback();
  auto duplicate = helper()->CaptureRouteReadyCallback();
  ASSERT_TRUE(ready);
  ASSERT_TRUE(duplicate);

  std::move(ready).Run();
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), original);
  content::NavigationSimulator::CreateFromPending(controller())->Commit();
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), original);
  EXPECT_EQ(controller().GetEntryCount(), entry_count);
  std::move(duplicate).Run();
  EXPECT_FALSE(controller().GetPendingEntry());
}

TEST_F(AccessNavigationRetryTabHelperTest,
       RetryPreparesFailedRedirectSiteAndReloadsOriginalUrlOnce) {
  const GURL original("https://start.example/path?q=original#section");
  const GURL failed("https://target.example/redirect?q=failed");
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      original, web_contents());
  navigation->Start();
  navigation->Redirect(failed);
  navigation->Fail(net::ERR_CONNECTION_RESET);
  navigation->CommitErrorPage();
  ASSERT_TRUE(helper()->FailureForRetry());
  EXPECT_EQ(helper()->FailureForRetry()->original_url, original);
  EXPECT_EQ(helper()->FailureForRetry()->failed_url, failed);

  base::OnceCallback<void(bool)> prepared;
  int calls = 0;
  helper()->SetProxyRetryHandler(base::BindLambdaForTesting(
      [&](const GURL& target, base::OnceCallback<void(bool)> completion) {
        ++calls;
        EXPECT_EQ(target, failed);
        prepared = std::move(completion);
      }));
  base::test::TestFuture<bool> result;
  ASSERT_TRUE(helper()->RequestProxyRetry(result.GetCallback()));
  EXPECT_EQ(calls, 1);
  EXPECT_FALSE(controller().GetPendingEntry());
  ASSERT_TRUE(prepared);
  std::move(prepared).Run(true);
  ASSERT_TRUE(result.Get());
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), original);
  content::NavigationSimulator::CreateFromPending(controller())->Commit();

  base::test::TestFuture<bool> duplicate;
  EXPECT_FALSE(helper()->RequestProxyRetry(duplicate.GetCallback()));
  EXPECT_FALSE(duplicate.Get());
  EXPECT_EQ(calls, 1);
  EXPECT_FALSE(controller().GetPendingEntry());
}

TEST_F(AccessNavigationRetryTabHelperTest, NoProxyHandlerPreservesNativeRecovery) {
  error_page::NetErrorAutoReloader::CreateForWebContents(web_contents());
  auto* reloader =
      error_page::NetErrorAutoReloader::FromWebContents(web_contents());
  reloader->DisableConnectionChangeObservationForTesting();
  reloader->OnConnectionChanged(
      net::NetworkChangeNotifier::ConnectionType::CONNECTION_WIFI);
  Fail(GURL("https://failed.example/"));
  EXPECT_FALSE(helper()->HasProxyRetryHandler());
  base::test::TestFuture<bool> reply;
  EXPECT_FALSE(helper()->RequestProxyRetry(reply.GetCallback()));
  EXPECT_FALSE(reply.Get());
  EXPECT_TRUE(reloader->next_reload_timer_for_testing());
}

TEST_F(AccessNavigationRetryTabHelperTest,
       ExplicitRecoveryKeepsErrorDocumentStableAcrossConnectionChanges) {
  helper()->SetProxyRetryHandler(base::BindRepeating(
      [](const GURL&, base::OnceCallback<void(bool)>) {}));
  error_page::NetErrorAutoReloader::CreateForWebContents(web_contents());
  auto* reloader =
      error_page::NetErrorAutoReloader::FromWebContents(web_contents());
  reloader->DisableConnectionChangeObservationForTesting();
  reloader->OnConnectionChanged(
      net::NetworkChangeNotifier::ConnectionType::CONNECTION_WIFI);
  Fail(GURL("https://failed.example/path?q=original"));
  const auto ticket = helper()->FailureForRetry();
  ASSERT_TRUE(ticket);
  EXPECT_FALSE(reloader->next_reload_timer_for_testing());
  reloader->OnConnectionChanged(
      net::NetworkChangeNotifier::ConnectionType::CONNECTION_NONE);
  reloader->OnConnectionChanged(
      net::NetworkChangeNotifier::ConnectionType::CONNECTION_WIFI);
  reloader->OnVisibilityChanged(content::Visibility::VISIBLE);
  EXPECT_FALSE(reloader->next_reload_timer_for_testing());
  EXPECT_EQ(helper()->FailureForRetry(), ticket);

  // A replacement document that has no Access recovery action retains the
  // existing Chromium automatic-reload behavior.
  content::NavigationSimulator::NavigateAndFailFromBrowser(
      web_contents(), GURL("https://other.example/"), net::ERR_EMPTY_RESPONSE);
  EXPECT_FALSE(helper()->FailureForRetry());
  EXPECT_TRUE(reloader->next_reload_timer_for_testing());
}

TEST_F(AccessNavigationRetryTabHelperTest,
       RecoverySuppressionAlsoWorksWhenAutoReloaderObservesFirst) {
  auto other = CreateTestWebContents();
  error_page::NetErrorAutoReloader::CreateForWebContents(other.get());
  auto* reloader =
      error_page::NetErrorAutoReloader::FromWebContents(other.get());
  reloader->DisableConnectionChangeObservationForTesting();
  reloader->OnConnectionChanged(
      net::NetworkChangeNotifier::ConnectionType::CONNECTION_WIFI);
  AccessNavigationRetryTabHelper::CreateForWebContents(other.get());
  AccessNavigationRetryTabHelper::FromWebContents(other.get())->SetProxyRetryHandler(
      base::BindRepeating([](const GURL&, base::OnceCallback<void(bool)>) {}));
  content::NavigationSimulator::NavigateAndFailFromBrowser(
      other.get(), GURL("https://failed.example/"), net::ERR_CONNECTION_RESET);
  EXPECT_TRUE(AccessNavigationRetryTabHelper::FromWebContents(other.get())
                  ->FailureForRetry());
  EXPECT_FALSE(reloader->next_reload_timer_for_testing());
}

TEST_F(AccessNavigationRetryTabHelperTest, NavigationRevokesLateRouteReady) {
  Fail(GURL("https://failed.example/path"));
  auto ready = helper()->CaptureRouteReadyCallback();
  ASSERT_TRUE(ready);
  const GURL replacement("https://other.example/");
  content::NavigationSimulator::NavigateAndCommitFromBrowser(web_contents(),
                                                            replacement);
  std::move(ready).Run();
  EXPECT_FALSE(controller().GetPendingEntry());
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), replacement);
}

TEST_F(AccessNavigationRetryTabHelperTest, ClosedTabRevokesRouteReady) {
  Fail(GURL("https://failed.example/path"));
  auto ready = helper()->CaptureRouteReadyCallback();
  ASSERT_TRUE(ready);
  DeleteContents();
  std::move(ready).Run();
}

TEST_F(AccessNavigationRetryTabHelperTest, OnlyInitiatingWebContentsReloads) {
  const GURL url("https://failed.example/path?q=1");
  Fail(url);
  auto other = CreateTestWebContents();
  AccessNavigationRetryTabHelper::CreateForWebContents(other.get());
  content::NavigationSimulator::NavigateAndFailFromBrowser(
      other.get(), url, net::ERR_NAME_NOT_RESOLVED);
  auto ready = helper()->CaptureRouteReadyCallback();
  ASSERT_TRUE(ready);
  std::move(ready).Run();
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), url);
  EXPECT_FALSE(other->GetController().GetPendingEntry());
  EXPECT_TRUE(AccessNavigationRetryTabHelper::FromWebContents(other.get())
                  ->FailureForRetry());
}

TEST_F(AccessNavigationRetryTabHelperTest, FailedPostDoesNotOfferReplay) {
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      GURL("https://failed.example/submit"), web_contents());
  navigation->SetMethod("POST");
  navigation->Start();
  navigation->Fail(net::ERR_CONNECTION_RESET);
  navigation->CommitErrorPage();
  EXPECT_FALSE(helper()->FailureForRetry());
  EXPECT_FALSE(helper()->CaptureRouteReadyCallback());
}

TEST_F(AccessNavigationRetryTabHelperTest, StopRevokesPendingRouteReady) {
  Fail(GURL("https://failed.example/path"));
  auto ready = helper()->CaptureRouteReadyCallback();
  ASSERT_TRUE(ready);
  helper()->NavigationStopped();
  std::move(ready).Run();
  EXPECT_FALSE(controller().GetPendingEntry());
}

TEST_F(AccessNavigationRetryTabHelperTest,
       StopAnswersRetainedErrorPageBeforeLateReady) {
  const GURL failed("https://failed.example/stop");
  Fail(failed);
  base::OnceCallback<void(bool)> prepared;
  helper()->SetProxyRetryHandler(base::BindLambdaForTesting(
      [&](const GURL&, base::OnceCallback<void(bool)> callback) {
        prepared = std::move(callback);
      }));
  base::test::TestFuture<bool> reply;
  ASSERT_TRUE(helper()->RequestProxyRetry(reply.GetCallback()));
  ASSERT_TRUE(prepared);
  web_contents()->Stop();
  const bool replied_on_stop = reply.IsReady();
  std::move(prepared).Run(true);
  EXPECT_TRUE(replied_on_stop);
  ASSERT_TRUE(reply.IsReady());
  EXPECT_FALSE(reply.Get());
  EXPECT_FALSE(controller().GetPendingEntry());
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), failed);
}

TEST_F(AccessNavigationRetryTabHelperTest, RefreshesStopWhilePreparingOnIdleTab) {
  class StopDelegate : public content::WebContentsDelegate {
   public:
    void LoadingStateChanged(content::WebContents* source, bool) override {
      stop_states.push_back(
          AccessNavigationRetryTabHelper::FromWebContents(source)
              ->IsPreparingProxyRetry());
    }
    std::vector<bool> stop_states;
  } delegate;
  Fail(GURL("https://failed.example/idle"));
  ASSERT_FALSE(web_contents()->IsLoading());
  auto* previous = web_contents()->GetDelegate();
  web_contents()->SetDelegate(&delegate);
  base::OnceCallback<void(bool)> prepared;
  helper()->SetProxyRetryHandler(base::BindLambdaForTesting(
      [&](const GURL&, base::OnceCallback<void(bool)> callback) {
        prepared = std::move(callback);
      }));
  base::test::TestFuture<bool> reply;
  EXPECT_TRUE(helper()->RequestProxyRetry(reply.GetCallback()));
  EXPECT_EQ(delegate.stop_states, std::vector<bool>({true}));
  web_contents()->Stop();
  EXPECT_FALSE(helper()->IsPreparingProxyRetry());
  EXPECT_TRUE(reply.IsReady());
  if (prepared) {
    std::move(prepared).Run(true);
  }
  EXPECT_FALSE(controller().GetPendingEntry());
  EXPECT_EQ(delegate.stop_states, std::vector<bool>({true, false}));
  web_contents()->SetDelegate(previous);
}

TEST_F(AccessNavigationRetryTabHelperTest, PendingNavigationRevokesLateReady) {
  Fail(GURL("https://failed.example/path"));
  auto ready = helper()->CaptureRouteReadyCallback();
  ASSERT_TRUE(ready);
  const GURL next("https://next.example/pending");
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      next, web_contents());
  navigation->Start();
  std::move(ready).Run();
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), next);
  EXPECT_FALSE(helper()->FailureForRetry());
  navigation->Commit();
}

TEST_F(AccessNavigationRetryTabHelperTest,
       FreshClickAfterStopOnlyAcceptsItsOwnReadyReply) {
  const GURL failed("https://failed.example/again");
  Fail(failed);
  base::OnceCallback<void(bool)> prepared;
  helper()->SetProxyRetryHandler(base::BindLambdaForTesting(
      [&](const GURL&, base::OnceCallback<void(bool)> callback) {
        prepared = std::move(callback);
      }));
  const auto first_ticket = helper()->FailureForRetry();
  ASSERT_TRUE(first_ticket);
  base::test::TestFuture<bool> stopped;
  ASSERT_TRUE(helper()->RequestProxyRetry(stopped.GetCallback()));
  auto late_ready = std::move(prepared);
  web_contents()->Stop();
  ASSERT_TRUE(stopped.IsReady());
  EXPECT_FALSE(stopped.Get());
  EXPECT_FALSE(helper()->CaptureRouteReadyCallback());

  base::test::TestFuture<bool> fresh;
  ASSERT_TRUE(helper()->RequestProxyRetry(fresh.GetCallback()));
  const auto fresh_ticket = helper()->FailureForRetry();
  ASSERT_TRUE(fresh_ticket);
  EXPECT_NE(fresh_ticket->identity, first_ticket->identity);
  std::move(late_ready).Run(true);
  EXPECT_FALSE(fresh.IsReady());
  EXPECT_FALSE(controller().GetPendingEntry());
  std::move(prepared).Run(true);
  ASSERT_TRUE(fresh.IsReady());
  EXPECT_TRUE(fresh.Get());
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), failed);
}

TEST_F(AccessNavigationRetryTabHelperTest, LateObserverUsesTrustedNavigationId) {
  auto other = CreateTestWebContents();
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      GURL("https://failed.example/path"), other.get());
  navigation->Start();
  AccessNavigationRetryTabHelper::ObservePendingNavigation(
      other.get(), navigation->GetNavigationHandle()->GetNavigationId());
  navigation->Fail(net::ERR_CONNECTION_REFUSED);
  navigation->CommitErrorPage();
  EXPECT_TRUE(AccessNavigationRetryTabHelper::FromWebContents(other.get())
                  ->FailureForRetry());
}

TEST_F(AccessNavigationRetryTabHelperTest, SecurityFailureDoesNotOfferReplay) {
  content::NavigationSimulator::NavigateAndFailFromBrowser(
      web_contents(), GURL("https://failed.example/path"),
      net::ERR_CERT_AUTHORITY_INVALID);
  EXPECT_FALSE(helper()->FailureForRetry());
  EXPECT_FALSE(helper()->CaptureRouteReadyCallback());
}

TEST_F(AccessNavigationRetryTabHelperTest, InitialPostRedirectDoesNotOfferReplay) {
  auto navigation = content::NavigationSimulator::CreateBrowserInitiated(
      GURL("https://failed.example/submit"), web_contents());
  navigation->SetMethod("POST");
  navigation->Start();
  navigation->Redirect(GURL("https://failed.example/after-post"));
  navigation->Fail(net::ERR_CONNECTION_RESET);
  navigation->CommitErrorPage();
  EXPECT_FALSE(helper()->FailureForRetry());
  EXPECT_FALSE(helper()->CaptureRouteReadyCallback());
}

TEST_F(AccessNavigationRetryTabHelperTest, ErrorPageRequestWaitsForActualReadyAndCoalesces) {
  const GURL original("https://failed.example/path?q=1#fragment");
  Fail(original);
  base::OnceCallback<void(bool)> prepared;
  int calls = 0;
  helper()->SetProxyRetryHandler(base::BindLambdaForTesting(
      [&](const GURL& target, base::OnceCallback<void(bool)> completion) {
        ++calls;
        EXPECT_EQ(target, original);
        prepared = std::move(completion);
      }));
  base::test::TestFuture<bool> result;
  EXPECT_TRUE(helper()->RequestProxyRetry(result.GetCallback()));
  EXPECT_FALSE(controller().GetPendingEntry());
  base::test::TestFuture<bool> duplicate;
  EXPECT_FALSE(helper()->RequestProxyRetry(duplicate.GetCallback()));
  EXPECT_FALSE(duplicate.Get());
  EXPECT_EQ(calls, 1);
  std::move(prepared).Run(true);
  ASSERT_TRUE(result.Get());
  ASSERT_TRUE(controller().GetPendingEntry());
  EXPECT_EQ(controller().GetPendingEntry()->GetURL(), original);
}
TEST_F(AccessNavigationRetryTabHelperTest, FailedPreparationDoesNotReloadAndAllowsManualRetry) {
  Fail(GURL("https://failed.example/"));
  int calls = 0;
  helper()->SetProxyRetryHandler(base::BindLambdaForTesting(
      [&](const GURL&, base::OnceCallback<void(bool)> completion) {
        ++calls;
        std::move(completion).Run(false);
      }));
  for (int attempt = 0; attempt < 2; ++attempt) {
    base::test::TestFuture<bool> result;
    EXPECT_TRUE(helper()->RequestProxyRetry(result.GetCallback()));
    EXPECT_FALSE(result.Get());
    EXPECT_FALSE(controller().GetPendingEntry());
    EXPECT_TRUE(helper()->FailureForRetry());
  }
  EXPECT_EQ(calls, 2);
}
TEST_F(AccessNavigationRetryTabHelperTest, ErrorPageRequestCannotRetryNewNavigation) {
  Fail(GURL("https://failed.example/"));
  base::OnceCallback<void(bool)> prepared;
  helper()->SetProxyRetryHandler(base::BindLambdaForTesting(
      [&](const GURL&, base::OnceCallback<void(bool)> completion) {
        prepared = std::move(completion);
      }));
  base::test::TestFuture<bool> result;
  EXPECT_TRUE(helper()->RequestProxyRetry(result.GetCallback()));
  const GURL other("https://other.example/");
  content::NavigationSimulator::NavigateAndCommitFromBrowser(web_contents(), other);
  std::move(prepared).Run(true);
  ASSERT_TRUE(result.IsReady());
  EXPECT_FALSE(result.Get());
  EXPECT_FALSE(controller().GetPendingEntry());
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), other);
}

}  // namespace
}  // namespace aegis::access
