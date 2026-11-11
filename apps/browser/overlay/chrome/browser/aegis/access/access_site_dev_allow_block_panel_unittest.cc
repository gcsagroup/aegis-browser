// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_dev_allow_block_panel.h"

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

TEST(AccessSiteDevAllowBlockPanelTest, AdmitsDevCanaryUnknownOnly) {
  EXPECT_TRUE(
      IsAccessDevAllowBlockPanelAdmitted(version_info::Channel::DEV));
  EXPECT_TRUE(
      IsAccessDevAllowBlockPanelAdmitted(version_info::Channel::CANARY));
  EXPECT_TRUE(
      IsAccessDevAllowBlockPanelAdmitted(version_info::Channel::UNKNOWN));
  EXPECT_FALSE(
      IsAccessDevAllowBlockPanelAdmitted(version_info::Channel::BETA));
  EXPECT_FALSE(
      IsAccessDevAllowBlockPanelAdmitted(version_info::Channel::STABLE));
}

TEST(AccessSiteDevAllowBlockPanelTest,
     NeverRegistersGeneralRuleEditorOnAnyChannel) {
  for (version_info::Channel channel :
       {version_info::Channel::UNKNOWN, version_info::Channel::CANARY,
        version_info::Channel::DEV, version_info::Channel::BETA,
        version_info::Channel::STABLE}) {
    EXPECT_FALSE(IsGeneralAccessRuleEditorRegistered(channel));
  }
}

TEST(AccessSiteDevAllowBlockPanelTest, BetaReleaseRefuseApply) {
  AccessSiteIntentStore store;
  auto blocked = ApplyAccessDevAllowBlock(
      &store, version_info::Channel::BETA, "news.example",
      AccessDevAllowBlockAction::kAllow);
  EXPECT_EQ(blocked.status,
            AccessDevAllowBlockApplyStatus::kChannelNotAdmitted);
  EXPECT_TRUE(store.All().empty());

  auto stable = ApplyAccessDevAllowBlock(
      &store, version_info::Channel::STABLE, "news.example",
      AccessDevAllowBlockAction::kBlock);
  EXPECT_EQ(stable.status,
            AccessDevAllowBlockApplyStatus::kChannelNotAdmitted);
  EXPECT_TRUE(store.All().empty());
}

TEST(AccessSiteDevAllowBlockPanelTest, DevAppliesAllowBlockOffOnExplicitHost) {
  AccessSiteIntentStore store;
  auto allow = ApplyAccessDevAllowBlock(
      &store, version_info::Channel::DEV, "https://NEWS.Example/path",
      AccessDevAllowBlockAction::kAllow);
  ASSERT_EQ(allow.status, AccessDevAllowBlockApplyStatus::kApplied);
  ASSERT_TRUE(allow.host);
  EXPECT_EQ(allow.host->value, "news.example");
  EXPECT_EQ(allow.intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(store.Get(*allow.host), AccessSiteIntent::kAllow);

  auto block = ApplyAccessDevAllowBlock(&store, version_info::Channel::DEV,
                                        "news.example",
                                        AccessDevAllowBlockAction::kBlock);
  ASSERT_EQ(block.status, AccessDevAllowBlockApplyStatus::kApplied);
  EXPECT_EQ(block.intent, AccessSiteIntent::kBlock);
  EXPECT_EQ(store.Get(*block.host), AccessSiteIntent::kBlock);
  // Block remains product-local refuse — never mapped to ordinary DIRECT here.
  EXPECT_EQ(OrdinaryAccessModeForIntent(AccessSiteIntent::kBlock),
            std::nullopt);

  auto off = ApplyAccessDevAllowBlock(&store, version_info::Channel::CANARY,
                                      "news.example",
                                      AccessDevAllowBlockAction::kOff);
  ASSERT_EQ(off.status, AccessDevAllowBlockApplyStatus::kApplied);
  EXPECT_EQ(off.intent, AccessSiteIntent::kOff);
  EXPECT_EQ(store.Get(*off.host), AccessSiteIntent::kOff);
  EXPECT_TRUE(store.All().empty());
}

TEST(AccessSiteDevAllowBlockPanelTest, RejectsInvalidHost) {
  AccessSiteIntentStore store;
  auto empty = ApplyAccessDevAllowBlock(&store, version_info::Channel::DEV, "",
                                        AccessDevAllowBlockAction::kAllow);
  EXPECT_EQ(empty.status, AccessDevAllowBlockApplyStatus::kInvalidHost);

  auto bad = ApplyAccessDevAllowBlock(&store, version_info::Channel::DEV,
                                      "not a host",
                                      AccessDevAllowBlockAction::kBlock);
  EXPECT_EQ(bad.status, AccessDevAllowBlockApplyStatus::kInvalidHost);
  EXPECT_TRUE(store.All().empty());
}

TEST(AccessSiteDevAllowBlockPanelTest, SnapshotHidesPanelOnBetaRelease) {
  AccessSiteIntentStore store;
  const GURL url("https://news.example/story");
  auto beta = BuildAccessDevAllowBlockPanelSnapshot(
      version_info::Channel::BETA, store, url);
  EXPECT_FALSE(beta.panel_registered);
  EXPECT_FALSE(beta.general_rule_editor_registered);
  EXPECT_FALSE(beta.has_explicit_host);
  EXPECT_EQ(beta.status_id, AccessDevAllowBlockStatusId::kPanelNotRegistered);

  auto stable = BuildAccessDevAllowBlockPanelSnapshot(
      version_info::Channel::STABLE, store, url);
  EXPECT_FALSE(stable.panel_registered);
  EXPECT_EQ(stable.status_id, AccessDevAllowBlockStatusId::kPanelNotRegistered);
}

TEST(AccessSiteDevAllowBlockPanelTest, SnapshotShowsAllowBlockForTrustedHost) {
  AccessSiteIntentStore store;
  const GURL url("https://news.example/story");
  auto idle = BuildAccessDevAllowBlockPanelSnapshot(
      version_info::Channel::DEV, store, url);
  EXPECT_TRUE(idle.panel_registered);
  EXPECT_FALSE(idle.general_rule_editor_registered);
  ASSERT_TRUE(idle.has_explicit_host);
  EXPECT_EQ(idle.host.value, "news.example");
  EXPECT_EQ(idle.status_id, AccessDevAllowBlockStatusId::kOff);

  ASSERT_EQ(ApplyAccessDevAllowBlock(&store, version_info::Channel::DEV,
                                     "news.example",
                                     AccessDevAllowBlockAction::kAllow)
                .status,
            AccessDevAllowBlockApplyStatus::kApplied);
  auto allow = BuildAccessDevAllowBlockPanelSnapshot(
      version_info::Channel::DEV, store, url);
  EXPECT_EQ(allow.status_id, AccessDevAllowBlockStatusId::kAllowProxyIntent);

  ASSERT_EQ(ApplyAccessDevAllowBlock(&store, version_info::Channel::DEV,
                                     "news.example",
                                     AccessDevAllowBlockAction::kBlock)
                .status,
            AccessDevAllowBlockApplyStatus::kApplied);
  auto block = BuildAccessDevAllowBlockPanelSnapshot(
      version_info::Channel::DEV, store, url);
  EXPECT_EQ(block.status_id, AccessDevAllowBlockStatusId::kBlockLocalRefuse);

  auto internal = BuildAccessDevAllowBlockPanelSnapshot(
      version_info::Channel::DEV, store, GURL("chrome://settings"));
  EXPECT_TRUE(internal.panel_registered);
  EXPECT_FALSE(internal.has_explicit_host);
  EXPECT_EQ(internal.status_id, AccessDevAllowBlockStatusId::kNoTrustedHost);
}

TEST(AccessSiteDevAllowBlockPanelTest, ExplicitHostSnapshotIndependentOfUrl) {
  AccessSiteIntentStore store;
  ASSERT_EQ(ApplyAccessDevAllowBlock(&store, version_info::Channel::UNKNOWN,
                                     "blocked.example",
                                     AccessDevAllowBlockAction::kBlock)
                .status,
            AccessDevAllowBlockApplyStatus::kApplied);
  auto snap = BuildAccessDevAllowBlockPanelSnapshotForHost(
      version_info::Channel::UNKNOWN, store, "blocked.example");
  EXPECT_TRUE(snap.panel_registered);
  ASSERT_TRUE(snap.has_explicit_host);
  EXPECT_EQ(snap.host.value, "blocked.example");
  EXPECT_EQ(snap.status_id, AccessDevAllowBlockStatusId::kBlockLocalRefuse);
}

}  // namespace
}  // namespace aegis::access
