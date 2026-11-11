// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_navigation_retry_state.h"

#include "net/base/net_errors.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

GURL OriginalUrl() {
  return GURL("https://start.example/path?q=1#section");
}
GURL FailedUrl() {
  return GURL("https://target.example/redirected?q=2#result");
}

TEST(AccessNavigationRetryStateTest, PreservesOriginalAndFailedNavigationUrls) {
  AccessNavigationRetryState state;
  state.BeginNavigation(17);
  ASSERT_TRUE(state.RecordFailure(17, OriginalUrl(), FailedUrl(), "GET",
                                  net::ERR_NAME_NOT_RESOLVED, true));
  const auto ticket = state.Capture();
  ASSERT_TRUE(ticket);
  EXPECT_EQ(ticket->original_url, OriginalUrl());
  EXPECT_EQ(ticket->failed_url, FailedUrl());
  EXPECT_TRUE(state.Consume(*ticket));
  EXPECT_FALSE(state.Consume(*ticket));
  EXPECT_FALSE(state.Capture());
}

TEST(AccessNavigationRetryStateTest, NavigationInvalidatesLateReadyCallback) {
  AccessNavigationRetryState state;
  state.BeginNavigation(17);
  ASSERT_TRUE(state.RecordFailure(17, OriginalUrl(), FailedUrl(), "GET",
                                  net::ERR_CONNECTION_RESET, true));
  const auto old = state.Capture();
  ASSERT_TRUE(old);
  state.BeginNavigation(18);
  EXPECT_FALSE(state.Consume(*old));
  EXPECT_FALSE(state.RecordFailure(17, OriginalUrl(), FailedUrl(), "GET",
                                   net::ERR_CONNECTION_RESET, true));
}

TEST(AccessNavigationRetryStateTest, AnotherTabCannotConsumeTheSameUrlTicket) {
  AccessNavigationRetryState first;
  AccessNavigationRetryState second;
  for (auto* state : {&first, &second}) {
    state->BeginNavigation(17);
    ASSERT_TRUE(state->RecordFailure(17, OriginalUrl(), FailedUrl(), "GET",
                                    net::ERR_CONNECTION_TIMED_OUT, true));
  }
  const auto ticket = first.Capture();
  ASSERT_TRUE(ticket);
  EXPECT_FALSE(second.Consume(*ticket));
  EXPECT_TRUE(first.Consume(*ticket));
  ASSERT_TRUE(second.Capture());
  EXPECT_TRUE(second.Consume(*second.Capture()));
}

TEST(AccessNavigationRetryStateTest, StoppedFailureBelongsToItsOriginalEntry) {
  AccessNavigationRetryState state;
  state.BeginNavigation(17);
  ASSERT_TRUE(state.RecordFailure(17, OriginalUrl(), FailedUrl(), "GET",
                                  net::ERR_CONNECTION_RESET, true));
  const auto old = state.Capture();
  ASSERT_TRUE(old);
  state.StopOnErrorEntry(10);
  state.StopOnErrorEntry(11);
  EXPECT_FALSE(state.Capture());
  EXPECT_FALSE(state.Consume(*old));
  EXPECT_FALSE(state.CaptureForUserRetry(11));
  const auto fresh = state.CaptureForUserRetry(10);
  ASSERT_TRUE(fresh);
  EXPECT_NE(fresh->identity, old->identity);
  EXPECT_FALSE(state.Consume(*old));
  state.StopOnErrorEntry(10);
  state.BeginNavigation(18);
  EXPECT_FALSE(state.CaptureForUserRetry(10));
}

TEST(AccessNavigationRetryStateTest, DoesNotReplayNonIdempotentInitialMethod) {
  for (const auto* method : {"POST", "PATCH", "PUT", "DELETE"}) {
    AccessNavigationRetryState state;
    state.BeginNavigation(17);
    EXPECT_FALSE(state.RecordFailure(17, OriginalUrl(), FailedUrl(), method,
                                     net::ERR_CONNECTION_RESET, true));
    EXPECT_FALSE(state.Capture());
  }
}

TEST(AccessNavigationRetryStateTest, SecurityAndHttpFailuresStayOnNativePath) {
  for (int error : {net::OK, net::ERR_CERT_AUTHORITY_INVALID,
                    net::ERR_SSL_PROTOCOL_ERROR, net::ERR_BLOCKED_BY_CLIENT,
                    net::ERR_ABORTED}) {
    AccessNavigationRetryState state;
    state.BeginNavigation(17);
    EXPECT_FALSE(state.RecordFailure(17, OriginalUrl(), FailedUrl(), "GET", error,
                                     true));
    EXPECT_FALSE(state.Capture());
  }
}

TEST(AccessNavigationRetryStateTest, RejectsUncommittedAndNonWebErrorPages) {
  AccessNavigationRetryState state;
  state.BeginNavigation(17);
  EXPECT_FALSE(state.RecordFailure(17, OriginalUrl(), FailedUrl(), "GET",
                                   net::ERR_CONNECTION_RESET, false));
  EXPECT_FALSE(state.RecordFailure(17, GURL("chrome://settings"), FailedUrl(),
                                   "GET", net::ERR_CONNECTION_RESET, true));
  EXPECT_FALSE(state.RecordFailure(17, OriginalUrl(), GURL("about:blank"), "GET",
                                   net::ERR_CONNECTION_RESET, true));
  EXPECT_FALSE(state.Capture());
}

TEST(AccessNavigationRetryStateTest, ModifiedTicketCannotChangeReloadUrl) {
  AccessNavigationRetryState state;
  state.BeginNavigation(17);
  ASSERT_TRUE(state.RecordFailure(17, OriginalUrl(), FailedUrl(), "GET",
                                  net::ERR_CONNECTION_REFUSED, true));
  auto modified = state.Capture();
  ASSERT_TRUE(modified);
  modified->original_url = GURL("https://other.example/");
  EXPECT_FALSE(state.Consume(*modified));
  ASSERT_TRUE(state.Capture());
  EXPECT_TRUE(state.Consume(*state.Capture()));
}

}  // namespace
}  // namespace aegis::access
