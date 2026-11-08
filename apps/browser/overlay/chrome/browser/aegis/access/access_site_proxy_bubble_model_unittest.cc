// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_bubble_model.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

AccessSiteHost Host(std::string_view value) {
  const auto result = MakeAccessSiteHost(value);
  EXPECT_EQ(result.status, AccessSiteHostStatus::kOk);
  return *result.host;
}

TEST(AccessSiteProxyBubbleModelTest, TrustedHostFromCommittedHttpOnly) {
  const auto ok =
      ResolveTrustedNavigationHost(GURL("https://News.Example/path?q=1"));
  ASSERT_EQ(ok.status, AccessSiteHostStatus::kOk);
  EXPECT_EQ(ok.host->value, "news.example");

  EXPECT_EQ(ResolveTrustedNavigationHost(GURL("chrome://settings")).status,
            AccessSiteHostStatus::kEmpty);
  EXPECT_EQ(ResolveTrustedNavigationHost(GURL("file:///tmp/x")).status,
            AccessSiteHostStatus::kEmpty);
  EXPECT_EQ(ResolveTrustedNavigationHost(GURL()).status,
            AccessSiteHostStatus::kEmpty);
}

TEST(AccessSiteProxyBubbleModelTest, SwitchStateDistinctFromConnection) {
  AccessSiteIntentStore store;
  const GURL url("https://news.example/");
  store.Set(Host("news.example"), AccessSiteIntent::kAllow);

  auto idle = BuildSiteProxyBubbleSnapshot(url, store,
                                           AccessSiteConnectionState::kIdle);
  EXPECT_TRUE(idle.has_trusted_site);
  EXPECT_TRUE(idle.toggle_on);
  EXPECT_TRUE(idle.toggle_enabled);
  EXPECT_EQ(idle.intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(idle.intent_status,
            AccessSiteProxyIntentStatusId::kAllowNotConnected);
  EXPECT_EQ(idle.connection_status, AccessSiteProxyConnectionStatusId::kIdle);

  auto ready = BuildSiteProxyBubbleSnapshot(url, store,
                                            AccessSiteConnectionState::kReady);
  EXPECT_TRUE(ready.toggle_on);
  EXPECT_EQ(ready.intent_status,
            AccessSiteProxyIntentStatusId::kAllowConnected);
  EXPECT_EQ(ready.connection_status, AccessSiteProxyConnectionStatusId::kReady);

  auto off = BuildSiteProxyBubbleSnapshot(url, AccessSiteIntentStore(),
                                          AccessSiteConnectionState::kReady);
  EXPECT_FALSE(off.toggle_on);
  EXPECT_EQ(off.intent_status,
            AccessSiteProxyIntentStatusId::kOffBrowserDefault);
  // Connection may be ready globally while this site switch is off.
  EXPECT_EQ(off.connection_status, AccessSiteProxyConnectionStatusId::kReady);
}

TEST(AccessSiteProxyBubbleModelTest, ToggleUpdatesIntentWithoutReadyClaim) {
  AccessSiteIntentStore store;
  const AccessSiteHost host = Host("www.example.com");
  EXPECT_TRUE(ApplySiteProxyToggle(&store, host, true));
  EXPECT_EQ(store.Get(host), AccessSiteIntent::kAllow);

  auto snap = BuildSiteProxyBubbleSnapshot(GURL("https://www.example.com/"),
                                           store,
                                           AccessSiteConnectionState::kIdle);
  EXPECT_TRUE(snap.toggle_on);
  EXPECT_EQ(snap.intent_status,
            AccessSiteProxyIntentStatusId::kAllowNotConnected);
  EXPECT_EQ(snap.connection, AccessSiteConnectionState::kIdle);

  EXPECT_TRUE(ApplySiteProxyToggle(&store, host, false));
  EXPECT_EQ(store.Get(host), AccessSiteIntent::kOff);
  EXPECT_TRUE(store.All().empty());
}

TEST(AccessSiteProxyBubbleModelTest, InternalPagesDisableToggle) {
  AccessSiteIntentStore store;
  auto snap = BuildSiteProxyBubbleSnapshot(GURL("chrome://aegis/"), store,
                                           AccessSiteConnectionState::kIdle);
  EXPECT_FALSE(snap.has_trusted_site);
  EXPECT_FALSE(snap.toggle_enabled);
  EXPECT_FALSE(snap.toggle_on);
  EXPECT_EQ(snap.intent_status, AccessSiteProxyIntentStatusId::kNoTrustedSite);
}

TEST(AccessSiteProxyBubbleModelTest, BlockIntentSurfacesLocalRefuseStatus) {
  AccessSiteIntentStore store;
  store.Set(Host("blocked.example"), AccessSiteIntent::kBlock);
  auto snap = BuildSiteProxyBubbleSnapshot(GURL("https://blocked.example/"),
                                           store,
                                           AccessSiteConnectionState::kIdle);
  EXPECT_TRUE(snap.has_trusted_site);
  EXPECT_FALSE(snap.toggle_on);
  EXPECT_EQ(snap.intent_status,
            AccessSiteProxyIntentStatusId::kBlockLocalRefuse);
}

}  // namespace
}  // namespace aegis::access
