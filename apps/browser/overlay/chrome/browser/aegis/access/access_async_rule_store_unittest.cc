// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_async_rule_store.h"
#include "base/files/scoped_temp_dir.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "chrome/browser/aegis/access/access_site_intent.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {
class AccessAsyncRuleStoreTest : public testing::Test {
 protected:
  AccessStoreBinding Binding(std::string token = "profile") {
    return *TrustedAccessStoreBindingFactory::CreatePersistent(
        ChannelNamespace::kDev, "async-profile", token, directory_.GetPath());
  }
  void SetUp() override { ASSERT_TRUE(directory_.CreateUniqueTempDir()); }
  void TearDown() override { environment_.RunUntilIdle(); }
  SiteGroupMutationRequest Mutation(std::string operation, bool enable,
                                   uint64_t revision = 0,
                                   std::string token = "profile") {
    auto built = BuildOrdinarySiteGroupMutation({
        enable ? AccessSiteIntent::kAllow : AccessSiteIntent::kOff,
        *MakeAccessSiteHost("example.test").host,
        {ChannelNamespace::kDev, token, "partition"}, "site", operation,
        "fingerprint-" + operation, enable ? "group" : "", revision});
    EXPECT_EQ(built.status, AccessSiteIntentMutationStatus::kReady);
    return *built.request;
  }
  AsyncAccessStoreRestoration Restore(AccessAsyncRuleStore* store) {
    base::test::TestFuture<AsyncAccessStoreRestoration> future;
    store->InitializeAndRestore("partition", future.GetCallback());
    return future.Take();
  }
  AsyncAccessStorePrepared Prepare(AccessAsyncRuleStore* store,
                                   SiteGroupMutationRequest request) {
    base::test::TestFuture<AsyncAccessStorePrepared> future;
    store->Prepare(std::move(request), future.GetCallback());
    return future.Take();
  }
  base::test::TaskEnvironment environment_;
  base::ScopedTempDir directory_;
};
TEST_F(AccessAsyncRuleStoreTest, UIBlockingDisallowedDuringOpenReadWriteAndClose) {
  {
    base::ScopedDisallowBlocking disallow_blocking;
    auto store = std::make_unique<AccessAsyncRuleStore>(Binding());
    auto restored = Restore(store.get());
    ASSERT_EQ(restored.status, StoreStatus::kValid);
    ASSERT_TRUE(restored.publication);
    EXPECT_EQ(restored.publication->policy_generation, 1u);
    auto prepared = Prepare(store.get(), Mutation("enable", true));
    ASSERT_EQ(prepared.status, StoreStatus::kValid);
    ASSERT_TRUE(prepared.pending);
    EXPECT_EQ(prepared.pending->operation_sequence, 2u);
    base::test::TestFuture<StoreResult<PendingMutationRecord>> committed;
    store->Commit(*prepared.pending, committed.GetCallback());
    EXPECT_EQ(committed.Get().status, StoreStatus::kValid);
    base::test::TestFuture<StoreResult<StoredPolicySnapshot>> read;
    store->ReadCommitted("partition", read.GetCallback());
    EXPECT_EQ(read.Get().status, StoreStatus::kValid);
    store.reset();
    environment_.RunUntilIdle();
  }
  AccessAsyncRuleStore reopened(Binding("new-profile"));
  auto restored = Restore(&reopened);
  ASSERT_TRUE(restored.publication);
  EXPECT_EQ(restored.publication->owner.profile_token, "new-profile");
  EXPECT_GT(restored.publication->policy_generation, 2u);
  EXPECT_EQ(restored.publication->rules.size(), 2u);
}
TEST_F(AccessAsyncRuleStoreTest, RestartSupersedesPreparedWithoutPublishingItsRules) {
  PendingMutationRecord pending;
  {
    AccessAsyncRuleStore store(Binding());
    ASSERT_EQ(Restore(&store).status, StoreStatus::kValid);
    auto prepared = Prepare(&store, Mutation("incomplete", true));
    ASSERT_TRUE(prepared.pending);
    pending = *prepared.pending;
    EXPECT_EQ(Restore(&store).status, StoreStatus::kConflict);
    base::test::TestFuture<StoreResult<StoredPolicySnapshot>> read;
    store.ReadCommitted("partition", read.GetCallback());
    EXPECT_EQ(read.Get().status, StoreStatus::kRecoveryRequired);
  }
  environment_.RunUntilIdle();
  AccessAsyncRuleStore reopened(Binding("new-profile"));
  auto restored = Restore(&reopened);
  ASSERT_EQ(restored.status, StoreStatus::kValid);
  ASSERT_TRUE(restored.publication);
  EXPECT_TRUE(restored.publication->rules.empty());
  EXPECT_EQ(restored.recovered_prepared, 1u);
  EXPECT_GT(restored.publication->policy_generation, pending.operation_sequence);
  auto next = Prepare(&reopened, Mutation("next", true, 0, "new-profile"));
  ASSERT_TRUE(next.pending);
  EXPECT_GT(next.pending->operation_sequence, restored.publication->policy_generation);
}
TEST_F(AccessAsyncRuleStoreTest, FailedMutationRestoresOnlyCommittedContentsAtFreshVersion) {
  AccessAsyncRuleStore store(Binding());
  ASSERT_EQ(Restore(&store).status, StoreStatus::kValid);
  auto enabled = Prepare(&store, Mutation("enable", true));
  ASSERT_TRUE(enabled.pending);
  base::test::TestFuture<StoreResult<PendingMutationRecord>> committed;
  store.Commit(*enabled.pending, committed.GetCallback());
  ASSERT_EQ(committed.Get().status, StoreStatus::kValid);
  auto failed = Prepare(&store, Mutation("failed-off", false, 1));
  ASSERT_TRUE(failed.pending);
  base::test::TestFuture<AsyncAccessStoreRestoration> recovered;
  store.RecoverFailedMutation(*failed.pending, recovered.GetCallback());
  const auto& result = recovered.Get();
  ASSERT_EQ(result.status, StoreStatus::kValid);
  ASSERT_TRUE(result.publication);
  EXPECT_GT(result.publication->policy_generation, failed.pending->operation_sequence);
  ASSERT_EQ(result.publication->rules.size(), 2u);
  for (const auto& rule : result.publication->rules)
    EXPECT_EQ(rule.mode, AccessMode::kProxy);
  base::test::TestFuture<AsyncAccessStoreRestoration> invalid;
  store.RecoverFailedMutation(*enabled.pending, invalid.GetCallback());
  EXPECT_EQ(invalid.Get().status, StoreStatus::kConflict);
}
TEST_F(AccessAsyncRuleStoreTest, RestoringAnotherPartitionCannotSupersedeLiveMutation) {
  AccessAsyncRuleStore store(Binding());
  ASSERT_EQ(Restore(&store).status, StoreStatus::kValid);
  auto live = Prepare(&store, Mutation("live", true));
  ASSERT_TRUE(live.pending);
  base::test::TestFuture<AsyncAccessStoreRestoration> other;
  store.InitializeAndRestore("other-partition", other.GetCallback());
  ASSERT_EQ(other.Get().status, StoreStatus::kValid);
  EXPECT_EQ(other.Get().recovered_prepared, 0u);
  auto forged = *live.pending;
  forged.owner.profile_token = "foreign";
  base::test::TestFuture<AsyncAccessStoreRestoration> rejected;
  store.RecoverFailedMutation(std::move(forged), rejected.GetCallback());
  EXPECT_EQ(rejected.Get().status, StoreStatus::kConflict);
  base::test::TestFuture<StoreResult<StoredPolicySnapshot>> read;
  store.ReadCommitted("partition", read.GetCallback());
  EXPECT_EQ(read.Get().status, StoreStatus::kRecoveryRequired);
  base::test::TestFuture<StoreResult<PendingMutationRecord>> committed;
  store.Commit(*live.pending, committed.GetCallback());
  EXPECT_EQ(committed.Get().status, StoreStatus::kValid);
}
TEST_F(AccessAsyncRuleStoreTest, MutationCannotSkipInitialRestore) {
  AccessAsyncRuleStore store(Binding());
  auto prepared = Prepare(&store, Mutation("premature", true));
  EXPECT_EQ(prepared.status, StoreStatus::kMissing);
  EXPECT_FALSE(prepared.pending);
  ASSERT_EQ(Restore(&store).status, StoreStatus::kValid);
}
}  // namespace
}  // namespace aegis::access
