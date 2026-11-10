// Copyright 2026 GCSA
#include "services/network/aegis/access_request_route_state.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace network {
namespace {
using namespace aegis_access;
class AccessRequestRouteStateTest : public testing::Test {
 protected:
  OwnershipKey owner_{ChannelNamespace::kDev, "profile", "partition"};
  GenerationTuple common_{1, 1, 0, 1, 1};
  BrowserOwnedRequestMetadata metadata_{
      "request", owner_, RequestAttributionKind::kDocument, "document", {},
      net::SchemefulSite(GURL("https://a.test"))};
  std::unique_ptr<AccessRouteRegistry> registry_ =
      std::make_unique<AccessRouteRegistry>(owner_, "incarnation");
  AccessRouteRegistry::Expectation expectation_{"incarnation", common_, {}};
  void SetUp() override {
    ASSERT_TRUE(registry_->Install(1, {{owner_, 1, {}}, common_, {}}));
  }
  scoped_refptr<AccessRequestRouteState> Create(std::string method = "GET") {
    return AccessRequestRouteState::Create(registry_->GetWeakPtr(), metadata_,
        GURL("https://a.test/start"), method, expectation_);
  }
};
TEST_F(AccessRequestRouteStateTest, PreflightDoesNotConsumeActualRequest) {
  auto state = Create("POST");
  ASSERT_TRUE(state);
  EXPECT_EQ(state->BeginSend(GURL("https://a.test/start"), "OPTIONS", true).net_error,
            net::OK);
  EXPECT_EQ(state->BeginSend(GURL("https://a.test/start"), "POST", false).net_error,
            net::OK);
  EXPECT_NE(state->BeginSend(GURL("https://a.test/start"), "POST", false).net_error,
            net::OK);
}
TEST_F(AccessRequestRouteStateTest, NativeRedirectRequiresPrivateNextHopApproval) {
  auto state = Create();
  ASSERT_TRUE(state);
  ASSERT_EQ(state->BeginSend(GURL("https://a.test/start"), "GET", false).net_error,
            net::OK);
  ASSERT_TRUE(state->ObserveRedirect(GURL("https://b.test/next"), "GET"));
  EXPECT_NE(state->BeginSend(GURL("https://b.test/next"), "GET", false).net_error,
            net::OK);
  ASSERT_TRUE(state->ApproveRedirect(1, GURL("https://b.test/next"), "GET",
                                     expectation_));
  EXPECT_EQ(state->BeginSend(GURL("https://b.test/next"), "GET", false).net_error,
            net::OK);
  EXPECT_FALSE(state->ApproveRedirect(1, GURL("https://b.test/next"), "GET",
                                      expectation_));
}
TEST_F(AccessRequestRouteStateTest, RedirectRejectsWrongHopMethodOrOverrideOrigin) {
  for (int kind = 0; kind < 3; ++kind) {
    auto state = Create("POST");
    ASSERT_TRUE(state);
    ASSERT_EQ(state->BeginSend(GURL("https://a.test/start"), "POST", false).net_error,
              net::OK);
    ASSERT_TRUE(state->ObserveRedirect(GURL("https://b.test/next"), "POST"));
    EXPECT_FALSE(state->ApproveRedirect(kind == 0 ? 2 : 1,
        GURL(kind == 1 ? "https://evil.test/next" : "https://b.test/next"),
        kind == 2 ? "GET" : "POST", expectation_));
    EXPECT_NE(state->BeginSend(GURL("https://b.test/next"), "POST", false).net_error,
              net::OK);
  }
}
TEST_F(AccessRequestRouteStateTest, RechecksRegistryAfterSchedulingDelayAndDestruction) {
  auto state = Create();
  ASSERT_TRUE(state);
  registry_->EnterRestoring();
  EXPECT_NE(state->BeginSend(GURL("https://a.test/start"), "GET", false).net_error,
            net::OK);
  registry_.reset();
  EXPECT_NE(state->BeginSend(GURL("https://a.test/start"), "GET", false).net_error,
            net::OK);
}
TEST_F(AccessRequestRouteStateTest, PreflightCannotChangeTargetOrReplayActualMethod) {
  auto state = Create("POST");
  ASSERT_TRUE(state);
  EXPECT_NE(state->BeginSend(GURL("https://b.test/start"), "OPTIONS", true).net_error,
            net::OK);
  EXPECT_NE(state->BeginSend(GURL("https://a.test/start"), "POST", true).net_error,
            net::OK);
}
TEST_F(AccessRequestRouteStateTest, SubframeNavigationRetainsTrustedTopSite) {
  for (bool main_frame : {false, true}) {
    registry_ = std::make_unique<AccessRouteRegistry>(owner_, "incarnation");
    AccessPolicyRule reject{"rule", owner_, PolicyScope::kSite, "https://a.test",
        "b.test", false, {RequestScheme::kHttps},
        {PortScope::kAllBrowserPermitted, {}}, AccessMode::kReject, {},
        ProtectionOverride::kNone, 1, 1};
    ASSERT_TRUE(registry_->Install(1, {{owner_, 1, {reject}}, common_, {}}));
    metadata_.attribution_kind = RequestAttributionKind::kPendingNavigation;
    metadata_.document_token.clear();
    metadata_.pending_navigation_token = "navigation";
    if (main_frame) metadata_.top_frame_site.reset();
    auto state = Create();
    ASSERT_TRUE(state);
    ASSERT_EQ(state->BeginSend(GURL("https://a.test/start"), "GET", false).net_error,
              net::OK);
    ASSERT_TRUE(state->ObserveRedirect(GURL("https://b.test/next"), "GET"));
    EXPECT_EQ(state->ApproveRedirect(1, GURL("https://b.test/next"), "GET",
                                     expectation_), main_frame);
  }
}
}  // namespace
}  // namespace network
