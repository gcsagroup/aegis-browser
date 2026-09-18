// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_published_request_runtime.h"

#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/test/base/testing_profile.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class AccessPublishedRequestRuntimeTest : public testing::Test {
 protected:
  void SetUp() override {
    profile_ = std::make_unique<TestingProfile>();
    network::mojom::NetworkContextParams params;
    ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), base::FilePath(), &params));
    transport_ = AccessNetworkContextTransport::Get(profile_.get());
    ASSERT_NE(transport_, nullptr);
    owner_ = transport_->OwnerForPartition(
        aegis_access::ChannelNamespace::kDev, base::FilePath());
    ASSERT_TRUE(owner_.has_value());
    runtime_ = AccessPublishedRequestRuntime::GetOrCreate(profile_.get());
    ASSERT_NE(runtime_, nullptr);
  }

  StoredPolicySnapshot Snapshot(uint64_t generation) const {
    StoredPolicySnapshot snapshot;
    snapshot.owner = *owner_;
    snapshot.policy_generation = generation;
    return snapshot;
  }

  std::unique_ptr<TestingProfile> profile_;
  raw_ptr<AccessNetworkContextTransport> transport_ = nullptr;
  raw_ptr<AccessPublishedRequestRuntime> runtime_ = nullptr;
  std::optional<aegis_access::OwnershipKey> owner_;
};

TEST_F(AccessPublishedRequestRuntimeTest, PublishesCommittedSnapshotInMemory) {
  const auto published = runtime_->PublishCommittedPolicySnapshot(Snapshot(1));
  EXPECT_EQ(published.status, AccessPolicyPublicationStatus::kPublished);
  EXPECT_EQ(published.policy_generation, 1u);

  const auto* snapshot = runtime_->GetPublishedPolicySnapshot(*owner_);
  ASSERT_NE(snapshot, nullptr);
  EXPECT_EQ(snapshot->owner, *owner_);
  EXPECT_EQ(snapshot->policy_generation, 1u);
  EXPECT_TRUE(snapshot->rules.empty());
}

TEST_F(AccessPublishedRequestRuntimeTest, DuplicatePublicationIsIdempotent) {
  ASSERT_EQ(runtime_->PublishCommittedPolicySnapshot(Snapshot(1)).status,
            AccessPolicyPublicationStatus::kPublished);
  const auto duplicate = runtime_->PublishCommittedPolicySnapshot(Snapshot(1));
  EXPECT_EQ(duplicate.status, AccessPolicyPublicationStatus::kUnchanged);
  EXPECT_EQ(duplicate.policy_generation, 1u);
}

TEST_F(AccessPublishedRequestRuntimeTest, StaleGenerationCannotReplaceNewer) {
  ASSERT_EQ(runtime_->PublishCommittedPolicySnapshot(Snapshot(1)).status,
            AccessPolicyPublicationStatus::kPublished);
  ASSERT_EQ(runtime_->PublishCommittedPolicySnapshot(Snapshot(2)).status,
            AccessPolicyPublicationStatus::kPublished);

  const auto stale = runtime_->PublishCommittedPolicySnapshot(Snapshot(1));
  EXPECT_EQ(stale.status, AccessPolicyPublicationStatus::kStaleGeneration);
  EXPECT_EQ(stale.policy_generation, 2u);
  ASSERT_NE(runtime_->GetPublishedPolicySnapshot(*owner_), nullptr);
  EXPECT_EQ(runtime_->GetPublishedPolicySnapshot(*owner_)->policy_generation,
            2u);
}

TEST_F(AccessPublishedRequestRuntimeTest, CrossProfileOwnerIsRejected) {
  StoredPolicySnapshot snapshot = Snapshot(1);
  snapshot.owner.profile_token = "other-profile";
  const auto result = runtime_->PublishCommittedPolicySnapshot(snapshot);
  EXPECT_EQ(result.status, AccessPolicyPublicationStatus::kOwnershipMismatch);
  EXPECT_EQ(runtime_->GetPublishedPolicySnapshot(snapshot.owner), nullptr);
}

TEST_F(AccessPublishedRequestRuntimeTest, InvalidationFailsClosed) {
  ASSERT_EQ(runtime_->PublishCommittedPolicySnapshot(Snapshot(1)).status,
            AccessPolicyPublicationStatus::kPublished);
  EXPECT_TRUE(runtime_->InvalidatePublishedPolicySnapshot(*owner_));
  EXPECT_EQ(runtime_->GetPublishedPolicySnapshot(*owner_), nullptr);
  EXPECT_FALSE(runtime_->InvalidatePublishedPolicySnapshot(*owner_));
}

TEST_F(AccessPublishedRequestRuntimeTest,
       MissingLiveSourcesDoNotProduceProxyTuple) {
  ASSERT_EQ(runtime_->PublishCommittedPolicySnapshot(Snapshot(1)).status,
            AccessPolicyPublicationStatus::kPublished);
  const auto result =
      runtime_->BuildProxyGenerationTuple(*owner_, "proxy-group-a");
  EXPECT_EQ(result.status,
            aegis_access::RequestGenerationTupleBuildStatus::
                kMissingIdentityGeneration);
  EXPECT_FALSE(result.generations.has_value());
}

}  // namespace
}  // namespace aegis::access
