// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/v2_runtime_spike.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::agent {
namespace {

constexpr int32_t kOwnedTab = 7;

V2DocumentBinding Binding(const char* document_token = "document-1") {
  return {.profile_id = "isolated-profile",
          .task_id = "task-1",
          .tab_id = kOwnedTab,
          .frame_token = "main-frame",
          .document_token = document_token,
          .origin = url::Origin::Create(GURL("https://fixture.test"))};
}

V2RuntimeSpike Runtime() {
  return V2RuntimeSpike("isolated-profile", "task-1",
                        {url::Origin::Create(GURL("https://fixture.test"))});
}

TEST(AegisV2RuntimeSpikeTest, DiscoveryStartsWithoutCurrentPageUrl) {
  auto runtime = Runtime();
  EXPECT_EQ(runtime.BuildDiscoveryUrl(GURL("https://fixture.test/search"),
                                      "battery research"),
            GURL("https://fixture.test/search?q=battery+research"));
  EXPECT_FALSE(runtime
                   .BuildDiscoveryUrl(GURL("https://outside.test/search"),
                                      "battery research")
                   .is_valid());
  EXPECT_FALSE(
      runtime
          .BuildDiscoveryUrl(GURL("https://user:password@fixture.test/search"),
                             "battery research")
          .is_valid());
}

TEST(AegisV2RuntimeSpikeTest, BindsEveryActionToCurrentDocument) {
  auto runtime = Runtime();
  ASSERT_TRUE(runtime.AdoptOwnedTab(kOwnedTab));
  ASSERT_TRUE(runtime.CommitDocument(Binding()));
  V2SpikeAction action{.action_id = "action-1",
                       .tool = V2SpikeTool::kClick,
                       .binding = Binding()};
  EXPECT_EQ(runtime.Authorize(action), V2SpikeDecision::kAllow);
  action.action_id = "action-2";
  action.binding.document_token = "stale-document";
  EXPECT_EQ(runtime.Authorize(action), V2SpikeDecision::kStaleDocument);
}

TEST(AegisV2RuntimeSpikeTest, RejectsCrossProfileTabAndOpenRedirect) {
  auto runtime = Runtime();
  ASSERT_TRUE(runtime.AdoptOwnedTab(kOwnedTab));
  ASSERT_TRUE(runtime.CommitDocument(Binding()));
  V2SpikeAction cross_profile{.action_id = "action-profile",
                              .tool = V2SpikeTool::kExtract,
                              .binding = Binding()};
  cross_profile.binding.profile_id = "daily-profile";
  EXPECT_EQ(runtime.Authorize(cross_profile), V2SpikeDecision::kScopeViolation);
  V2SpikeAction redirect{.action_id = "action-redirect",
                         .tool = V2SpikeTool::kNavigate,
                         .binding = Binding(),
                         .destination = GURL("https://outside.test/")};
  EXPECT_EQ(runtime.Authorize(redirect), V2SpikeDecision::kInvalidDestination);
}

TEST(AegisV2RuntimeSpikeTest, VisualFallbackIsDocumentBoundAndSingleUse) {
  auto runtime = Runtime();
  ASSERT_TRUE(runtime.AdoptOwnedTab(kOwnedTab));
  ASSERT_TRUE(runtime.CommitDocument(Binding()));
  EXPECT_FALSE(runtime.ConsumeVisualFallback(Binding()));
  EXPECT_TRUE(runtime.MarkDomObservationFailed(Binding()));
  EXPECT_TRUE(runtime.ConsumeVisualFallback(Binding()));
  EXPECT_FALSE(runtime.ConsumeVisualFallback(Binding()));
  EXPECT_FALSE(runtime.ConsumeVisualFallback(Binding("stale-document")));
}

TEST(AegisV2RuntimeSpikeTest, VisualFallbackCannotCrossTabsWithReusedToken) {
  auto runtime = Runtime();
  ASSERT_TRUE(runtime.AdoptOwnedTab(kOwnedTab));
  ASSERT_TRUE(runtime.CommitDocument(Binding()));
  V2DocumentBinding second_tab = Binding();
  second_tab.tab_id = kOwnedTab + 1;
  ASSERT_TRUE(runtime.AdoptOwnedTab(second_tab.tab_id));
  ASSERT_TRUE(runtime.CommitDocument(second_tab));
  ASSERT_TRUE(runtime.MarkDomObservationFailed(Binding()));
  EXPECT_FALSE(runtime.ConsumeVisualFallback(second_tab));
}

TEST(AegisV2RuntimeSpikeTest, NativeBookmarksAreReadOnly) {
  auto runtime = Runtime();
  ASSERT_TRUE(runtime.AdoptOwnedTab(kOwnedTab));
  ASSERT_TRUE(runtime.CommitDocument(Binding()));
  EXPECT_FALSE(runtime.AllowsNativeBookmarkMutation());
  EXPECT_EQ(runtime.Authorize({.action_id = "read-bookmarks",
                               .tool = V2SpikeTool::kReadBookmarks,
                               .binding = Binding()}),
            V2SpikeDecision::kAllow);
}

TEST(AegisV2RuntimeSpikeTest, NativeBookmarksRejectUnexpectedDestination) {
  auto runtime = Runtime();
  ASSERT_TRUE(runtime.AdoptOwnedTab(kOwnedTab));
  ASSERT_TRUE(runtime.CommitDocument(Binding()));
  EXPECT_EQ(runtime.Authorize(
                {.action_id = "read-bookmarks-with-url",
                 .tool = V2SpikeTool::kReadBookmarks,
                 .binding = Binding(),
                 .destination = GURL("https://fixture.test/unexpected")}),
            V2SpikeDecision::kToolDenied);
}

TEST(AegisV2RuntimeSpikeTest, StopRevokesOwnedStateAndFutureActions) {
  auto runtime = Runtime();
  ASSERT_TRUE(runtime.AdoptOwnedTab(kOwnedTab));
  ASSERT_TRUE(runtime.CommitDocument(Binding()));
  EXPECT_EQ(runtime.Stop(), std::vector<int32_t>({kOwnedTab}));
  EXPECT_TRUE(runtime.stopped());
  EXPECT_EQ(runtime.owned_tab_count(), 0u);
  EXPECT_EQ(runtime.Authorize({.action_id = "after-stop",
                               .tool = V2SpikeTool::kExtract,
                               .binding = Binding()}),
            V2SpikeDecision::kStopped);
}

}  // namespace
}  // namespace aegis::agent
