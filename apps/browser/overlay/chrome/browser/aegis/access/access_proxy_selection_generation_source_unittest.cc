// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_proxy_selection_generation_source.h"

#include <memory>

#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class AccessProxySelectionGenerationSourceTest : public testing::Test {
 protected:
  content::BrowserTaskEnvironment task_environment_;
};

aegis_access::AccessProxySelectionBinding InitialSelection() {
  return {"group-a", "endpoint-a", "lease-a", "assignment-a", 1};
}

aegis_access::AccessProxySelectionBinding SwitchedSelection() {
  return {"group-a", "endpoint-b", "lease-b", "assignment-b", 2};
}

TEST_F(AccessProxySelectionGenerationSourceTest,
     StartsUnpublishedUntilCommittedSelection) {
  auto profile = TestingProfile::Builder().Build();
  auto* source =
      AccessProxySelectionGenerationSource::GetOrCreate(profile.get());
  ASSERT_TRUE(source);

  EXPECT_EQ(source->selection_generation("group-a"), 0u);
  EXPECT_EQ(source->binding_for_group("group-a"), nullptr);

  const auto committed = source->CommitSelection(InitialSelection());
  EXPECT_EQ(committed.status,
            aegis_access::ProxySelectionGenerationCommitStatus::kCommitted);
  EXPECT_EQ(committed.generation, 1u);
  EXPECT_EQ(source->selection_generation("group-a"), 1u);
}

TEST_F(AccessProxySelectionGenerationSourceTest,
     CommittedSelectionSwitchAdvancesGeneration) {
  auto profile = TestingProfile::Builder().Build();
  auto* source =
      AccessProxySelectionGenerationSource::GetOrCreate(profile.get());
  ASSERT_TRUE(source);

  ASSERT_EQ(source->CommitSelection(InitialSelection()).generation, 1u);
  EXPECT_EQ(source->CommitSelection(InitialSelection()).status,
            aegis_access::ProxySelectionGenerationCommitStatus::kUnchanged);
  EXPECT_EQ(source->CommitSelection(SwitchedSelection()).generation, 2u);
  ASSERT_NE(source->binding_for_group("group-a"), nullptr);
  EXPECT_EQ(source->binding_for_group("group-a")->endpoint_id, "endpoint-b");
}

TEST_F(AccessProxySelectionGenerationSourceTest,
     StaleBindingRevisionCannotOverwriteNewerSelection) {
  auto profile = TestingProfile::Builder().Build();
  auto* source =
      AccessProxySelectionGenerationSource::GetOrCreate(profile.get());
  ASSERT_TRUE(source);

  ASSERT_EQ(source->CommitSelection(InitialSelection()).generation, 1u);
  ASSERT_EQ(source->CommitSelection(SwitchedSelection()).generation, 2u);

  auto stale = InitialSelection();
  stale.endpoint_id = "endpoint-stale";
  EXPECT_EQ(
      source->CommitSelection(stale).status,
      aegis_access::ProxySelectionGenerationCommitStatus::kStaleBindingRevision);
  EXPECT_EQ(source->selection_generation("group-a"), 2u);
  EXPECT_EQ(source->binding_for_group("group-a")->endpoint_id, "endpoint-b");
}

TEST_F(AccessProxySelectionGenerationSourceTest,
     ProxyGroupsAndProfilesAreIsolated) {
  auto first_profile = TestingProfile::Builder().Build();
  auto second_profile = TestingProfile::Builder().Build();
  auto* first =
      AccessProxySelectionGenerationSource::GetOrCreate(first_profile.get());
  auto* second =
      AccessProxySelectionGenerationSource::GetOrCreate(second_profile.get());
  ASSERT_TRUE(first);
  ASSERT_TRUE(second);

  ASSERT_EQ(first->CommitSelection(InitialSelection()).generation, 1u);
  auto group_b = InitialSelection();
  group_b.proxy_group_id = "group-b";
  ASSERT_EQ(first->CommitSelection(group_b).generation, 1u);

  EXPECT_EQ(first->selection_generation("group-a"), 1u);
  EXPECT_EQ(first->selection_generation("group-b"), 1u);
  EXPECT_EQ(second->selection_generation("group-a"), 0u);
  EXPECT_EQ(second->selection_generation("group-b"), 0u);
}

}  // namespace
}  // namespace aegis::access
