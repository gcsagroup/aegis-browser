// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_service_coordinator.h"

#include <memory>
#include <optional>

#include "base/files/scoped_temp_dir.h"
#include "base/test/test_future.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/access/access_published_request_runtime.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "services/network/public/mojom/network_context.mojom.h"

#include "build/chromeos_buildflags.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_testing_helper.h"
#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {

class AccessRuleStoreTestPeer {
 public:
  static StoreStatus Import(AccessRuleStore* store, const StoredAccessRule& rule) {
    return store->ImportIndependentRuleForTesting(rule);
  }
  static AccessStoreBinding Binding(const base::FilePath& path,
                                   const OwnershipKey& owner) {
    return AccessStoreBinding(path.empty() ? AccessStoreKind::kEphemeralProfile
                                           : AccessStoreKind::kPersistentProfile, owner.channel,
                              "durable-test-profile", owner.profile_token, path,
                              path.empty() ? base::FilePath() : path.AppendASCII("access.db"));
  }
};

namespace {

class AccessServiceCoordinatorTest : public testing::Test {
 protected:
  content::BrowserTaskEnvironment task_environment_{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME};
};

TEST_F(AccessServiceCoordinatorTest, RejectsNullProfile) {
  EXPECT_EQ(AccessServiceCoordinator::Get(nullptr), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(nullptr), nullptr);
}

TEST_F(AccessServiceCoordinatorTest, ReusesProfileOwnedCoordinator) {
  auto profile = TestingProfile::Builder().Build();
  EXPECT_EQ(AccessServiceCoordinator::Get(profile.get()), nullptr);

  auto* first = AccessServiceCoordinator::GetOrCreate(profile.get());
  auto* second = AccessServiceCoordinator::GetOrCreate(profile.get());

  ASSERT_TRUE(first);
  EXPECT_EQ(first, second);
  EXPECT_EQ(AccessServiceCoordinator::Get(profile.get()), first);
  EXPECT_EQ(first->state_generation(), 0u);
}

TEST_F(AccessServiceCoordinatorTest, ProfilesNeverShareCoordinatorState) {
  auto first_profile = TestingProfile::Builder().Build();
  auto second_profile = TestingProfile::Builder().Build();

  auto* first = AccessServiceCoordinator::GetOrCreate(first_profile.get());
  auto* second = AccessServiceCoordinator::GetOrCreate(second_profile.get());

  ASSERT_TRUE(first);
  ASSERT_TRUE(second);
  EXPECT_NE(first, second);
  EXPECT_EQ(first->state_generation(), 0u);
  EXPECT_EQ(second->state_generation(), 0u);
}

// Holds the real Mojo reply across the PREPARED observation point.
class HeldPolicyClient : public network::mojom::CustomProxyConfigClient {
 public:
  explicit HeldPolicyClient(
      mojo::PendingReceiver<network::mojom::CustomProxyConfigClient> receiver)
      : receiver_(this, std::move(receiver)) {}
  void OnCustomProxyConfigUpdated(
      network::mojom::CustomProxyConfigPtr,
      OnCustomProxyConfigUpdatedCallback callback) override {
    std::move(callback).Run();
  }
  void OnAegisAccessPolicyPublished(
      network::mojom::AegisAccessPolicyPublicationMetadataPtr value,
      OnAegisAccessPolicyPublishedCallback callback) override {
    metadata = std::move(value);
    reply = std::move(callback);
  }
  network::mojom::AegisAccessPolicyPublicationMetadataPtr metadata;
  OnAegisAccessPolicyPublishedCallback reply;
  mojo::Receiver<network::mojom::CustomProxyConfigClient> receiver_;
};

class AccessMutationTransactionTest : public AccessServiceCoordinatorTest {
 protected:
  void SetUp() override {
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    profile_ = TestingProfile::Builder().Build();
    network::mojom::NetworkContextParams params;
    ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), base::FilePath(), &params));
    transport_ = AccessNetworkContextTransport::Get(profile_.get());
    owner_ = *transport_->OwnerForPartition(ChannelNamespace::kDev, {});
    client_ = std::make_unique<HeldPolicyClient>(
        std::move(params.custom_proxy_config_client_receiver));
    coordinator_ = AccessServiceCoordinator::GetOrCreate(profile_.get());
  }

  std::unique_ptr<AccessRuleStore> OpenStore() {
    auto store = std::make_unique<AccessRuleStore>(
        AccessRuleStoreTestPeer::Binding(directory_.GetPath(), owner_));
    EXPECT_EQ(store->Open(), StoreStatus::kValid);
    return store;
  }

  SiteGroupMutationRequest Mutation() {
    SiteGroupMutationRequest request;
    request.operation_id = "ordinary-operation";
    request.request_fingerprint = "ordinary-fingerprint";
    request.candidate_group = {
        .site_toggle_id = "toggle",
        .canonical_host = "news.example",
        .owner = owner_,
        .http_top_level_site = "http://news.example",
        .https_top_level_site = "https://news.example",
        .member_rule_ids = {"toggle:http", "toggle:https"},
    };
    for (const auto& scheme : {std::string("http"), std::string("https")}) {
      request.candidate_members.push_back({
          .rule_id = "toggle:" + scheme,
          .owner = owner_,
          .site_toggle_id = "toggle",
          .top_level_site = scheme + "://news.example",
          .exact_host = "news.example",
          .schemes = {RequestScheme::kHttp, RequestScheme::kHttps,
                      RequestScheme::kWs, RequestScheme::kWss},
          .ports = PortScope::kAllBrowserPermitted,
          .mode = AccessMode::kDirect,
          .protection_override = ProtectionOverride::kNone,
      });
    }
    return request;
  }

  aegis_access::RequestCancellationSelector Selector() {
    aegis_access::RequestCancellationSelector selector;
    selector.owner = owner_;
    selector.document_token = "trusted-document";
    selector.top_level_site = "https://news.example";
    selector.exact_host = "news.example";
    selector.scheme = RequestScheme::kHttps;
    selector.port = 443;
    return selector;
  }

  base::ScopedTempDir directory_;
  std::unique_ptr<TestingProfile> profile_;
  AccessNetworkContextTransport* transport_ = nullptr;
  AccessServiceCoordinator* coordinator_ = nullptr;
  OwnershipKey owner_;
  std::unique_ptr<HeldPolicyClient> client_;
};

TEST_F(AccessMutationTransactionTest, PublishesPreparedThenCommitsOnlyAfterAck) {
  auto store = OpenStore();
  auto* pending_store = store.get();
  base::test::TestFuture<AccessMutationTransactionResult> result;
  coordinator_->CommitSiteGroupMutation(std::move(store), Mutation(), Selector(),
                                        result.GetCallback());
  task_environment_.RunUntilIdle();
  ASSERT_FALSE(result.IsReady());
  ASSERT_TRUE(client_->metadata);
  EXPECT_EQ(client_->metadata->operation_id, "ordinary-operation");
  EXPECT_EQ(client_->metadata->policy_generation,
            client_->metadata->operation_sequence);
  EXPECT_EQ(pending_store->ReadCommittedSnapshot(owner_.storage_partition_token)
                .status, StoreStatus::kRecoveryRequired);
  const auto* runtime = AccessPublishedRequestRuntime::Get(profile_.get());
  ASSERT_TRUE(runtime);
  ASSERT_TRUE(runtime->GetPublishedPolicySnapshot(owner_));
  EXPECT_EQ(runtime->GetPublishedPolicySnapshot(owner_)->policy_generation,
            client_->metadata->policy_generation);
  EXPECT_EQ(coordinator_->state_generation(), 0u);
  std::move(client_->reply).Run(true);
  ASSERT_TRUE(result.Wait());
  EXPECT_EQ(result.Get().status, AccessMutationTransactionStatus::kCommitted);
  EXPECT_EQ(coordinator_->state_generation(), 1u);
  const auto durable = pending_store->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(durable.value);
  EXPECT_EQ(durable.value->policy_generation, result.Get().policy_generation);
}

TEST_F(AccessMutationTransactionTest, FailedAckRemovesCandidateWithoutCommit) {
  base::test::TestFuture<AccessMutationTransactionResult> result;
  auto store = OpenStore();
  auto* retained_store = store.get();
  coordinator_->CommitSiteGroupMutation(std::move(store), Mutation(), Selector(),
                                        result.GetCallback());
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(client_->reply);
  std::move(client_->reply).Run(false);
  ASSERT_TRUE(result.Wait());
  EXPECT_EQ(result.Get().status,
            AccessMutationTransactionStatus::kNetworkPublicationFailed);
  EXPECT_EQ(coordinator_->state_generation(), 0u);
  EXPECT_EQ(AccessPublishedRequestRuntime::Get(profile_.get())
                ->GetPublishedPolicySnapshot(owner_), nullptr);
  EXPECT_EQ(retained_store->ReadCommittedSnapshot(owner_.storage_partition_token).status,
            StoreStatus::kMissing);
}

TEST_F(AccessMutationTransactionTest, NewerRuntimeMakesDelayedAckFailClosed) {
  base::test::TestFuture<AccessMutationTransactionResult> result;
  coordinator_->CommitSiteGroupMutation(OpenStore(), Mutation(), Selector(),
                                        result.GetCallback());
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(client_->metadata);
  StoredPolicySnapshot newer;
  newer.owner = owner_;
  newer.policy_generation = client_->metadata->policy_generation + 1;
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_.get());
  ASSERT_EQ(runtime->PublishCommittedPolicySnapshot(newer).status,
            AccessPolicyPublicationStatus::kPublished);
  std::move(client_->reply).Run(true);
  ASSERT_TRUE(result.Wait());
  EXPECT_EQ(result.Get().status,
            AccessMutationTransactionStatus::kNetworkPublicationFailed);
  EXPECT_EQ(runtime->GetPublishedPolicySnapshot(owner_)->policy_generation,
            newer.policy_generation);
  EXPECT_EQ(coordinator_->state_generation(), 0u);
}

TEST_F(AccessMutationTransactionTest, TimeoutRejectsLateAckAndReleasesBusyState) {
  base::test::TestFuture<AccessMutationTransactionResult> result;
  coordinator_->CommitSiteGroupMutation(OpenStore(), Mutation(), Selector(),
                                        result.GetCallback());
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(client_->reply);
  task_environment_.FastForwardBy(base::Seconds(30));
  ASSERT_TRUE(result.IsReady());
  EXPECT_EQ(result.Get().status,
            AccessMutationTransactionStatus::kNetworkPublicationFailed);
  std::move(client_->reply).Run(true);
  task_environment_.RunUntilIdle();
  EXPECT_EQ(coordinator_->state_generation(), 0u);
  EXPECT_EQ(AccessPublishedRequestRuntime::Get(profile_.get())
                ->GetPublishedPolicySnapshot(owner_), nullptr);
  auto next = Mutation();
  next.operation_id = "after-timeout";
  next.request_fingerprint = "after-timeout-fingerprint";
  base::test::TestFuture<AccessMutationTransactionResult> second;
  coordinator_->CommitSiteGroupMutation(nullptr, next, Selector(),
                                        second.GetCallback());
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(client_->reply);
  EXPECT_FALSE(second.IsReady());
  std::move(client_->reply).Run(true);
  ASSERT_TRUE(second.Wait());
  EXPECT_EQ(second.Get().status, AccessMutationTransactionStatus::kCommitted);
}

TEST_F(AccessMutationTransactionTest, EndpointPolicyGenerationRollsBackOnFailure) {
  const aegis_access::RegisteredProxyEndpoint old_endpoint{
      "registration", "proxy-group", owner_, {7, 2, 3, transport_->network_epoch(), 5},
      aegis_access::RegisteredProxyTransport::kHttp, "127.0.0.1", 18080};
  ASSERT_TRUE(transport_->PublishProxySelection({}, {"news.example", "other.example"}, old_endpoint));
  base::test::TestFuture<AccessMutationTransactionResult> result;
  coordinator_->CommitSiteGroupMutation(OpenStore(), Mutation(), Selector(),
                                        result.GetCallback());
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(client_->metadata);
  const auto candidate_endpoint = transport_->CurrentEndpoint(owner_);
  EXPECT_EQ(transport_->CurrentSelection(owner_)->exact_hosts,
            (std::vector<std::string>{"other.example"}));
  ASSERT_TRUE(candidate_endpoint);
  EXPECT_EQ(candidate_endpoint->generations.policy_generation,
            client_->metadata->policy_generation);
  std::move(client_->reply).Run(false);
  ASSERT_TRUE(result.Wait());
  EXPECT_EQ(transport_->CurrentEndpoint(owner_), old_endpoint);
  EXPECT_EQ(transport_->CurrentSelection(owner_)->exact_hosts,
            (std::vector<std::string>{"news.example", "other.example"}));
}

TEST_F(AccessMutationTransactionTest, EphemeralStoreSurvivesConsecutiveMutations) {
  auto store = std::make_unique<AccessRuleStore>(
      AccessRuleStoreTestPeer::Binding({}, owner_));
  ASSERT_EQ(store->Open(), StoreStatus::kValid);
  auto* retained_store = store.get();
  base::test::TestFuture<AccessMutationTransactionResult> first;
  coordinator_->CommitSiteGroupMutation(std::move(store), Mutation(), Selector(),
                                        first.GetCallback());
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(client_->reply);
  std::move(client_->reply).Run(true);
  ASSERT_TRUE(first.Wait());
  ASSERT_EQ(first.Get().status, AccessMutationTransactionStatus::kCommitted);
  auto next = Mutation();
  next.operation_id = "second-site";
  next.request_fingerprint = "second-site-fingerprint";
  next.candidate_group.site_toggle_id = "second-toggle";
  next.candidate_group.canonical_host = "other.example";
  next.candidate_group.http_top_level_site = "http://other.example";
  next.candidate_group.https_top_level_site = "https://other.example";
  next.candidate_group.member_rule_ids = {"second:http", "second:https"};
  for (size_t i = 0; i < next.candidate_members.size(); ++i) {
    auto& member = next.candidate_members[i];
    member.rule_id = next.candidate_group.member_rule_ids[i];
    member.site_toggle_id = "second-toggle";
    member.exact_host = "other.example";
    member.top_level_site = i == 0 ? "http://other.example" : "https://other.example";
  }
  auto selector = Selector();
  selector.top_level_site = "https://other.example";
  selector.exact_host = "other.example";
  base::test::TestFuture<AccessMutationTransactionResult> second;
  coordinator_->CommitSiteGroupMutation(nullptr, next, selector, second.GetCallback());
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(client_->reply);
  std::move(client_->reply).Run(true);
  ASSERT_TRUE(second.Wait());
  ASSERT_EQ(second.Get().status, AccessMutationTransactionStatus::kCommitted);
  EXPECT_GT(second.Get().policy_generation, first.Get().policy_generation);
  const auto durable = retained_store->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(durable.value);
  EXPECT_EQ(durable.value->site_groups.size(), 2u);
  EXPECT_EQ(coordinator_->state_generation(), 2u);
}

TEST_F(AccessMutationTransactionTest, MixedSameHostScopesFailBeforePublication) {
  auto store = OpenStore();
  auto* retained_store = store.get();
  StoredAccessRule independent;
  independent.policy = {
      .rule_id = "other-site-proxy",
      .owner = owner_,
      .scope = PolicyScope::kSite,
      .top_level_site = "https://other.example",
      .destination_host = "news.example",
      .schemes = {RequestScheme::kHttps},
      .ports = {PortScope::kAllBrowserPermitted, {}},
      .mode = AccessMode::kProxy,
      .proxy_group_id = "independent-proxy",
      .protection_override = ProtectionOverride::kNone,
      .row_revision = 1,
      .last_operation_sequence = 1,
  };
  independent.source = StoredRuleSource::kTestFixture;
  independent.lifetime = StoredRuleLifetime::kPersistent;
  ASSERT_EQ(AccessRuleStoreTestPeer::Import(store.get(), independent), StoreStatus::kValid);
  const auto before = store->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(before.value);
  base::test::TestFuture<AccessMutationTransactionResult> result;
  coordinator_->CommitSiteGroupMutation(std::move(store), Mutation(), Selector(),
                                        result.GetCallback());
  ASSERT_TRUE(result.IsReady());
  EXPECT_EQ(result.Get().status,
            AccessMutationTransactionStatus::kUnsupportedTransportScope);
  EXPECT_FALSE(client_->metadata);
  const auto after = retained_store->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(after.value);
  EXPECT_EQ(*after.value, *before.value);
  EXPECT_EQ(coordinator_->state_generation(), 0u);
}

TEST_F(AccessMutationTransactionTest, ForgedSelectorDoesNotPrepareMutation) {
  auto selector = Selector();
  selector.owner.profile_token = "other-profile";
  base::test::TestFuture<AccessMutationTransactionResult> result;
  coordinator_->CommitSiteGroupMutation(OpenStore(), Mutation(), selector,
                                        result.GetCallback());
  ASSERT_TRUE(result.IsReady());
  EXPECT_EQ(result.Get().status, AccessMutationTransactionStatus::kInvalidRequest);
  EXPECT_FALSE(client_->metadata);
  EXPECT_EQ(coordinator_->state_generation(), 0u);
}

class AccessServiceCoordinatorProfileSupportTest
    : public testing::Test,
      public ProfileTestingHelper {
 public:
  void SetUp() override {
    testing::Test::SetUp();
    ProfileTestingHelper::SetUp();
  }
};

TEST_F(AccessServiceCoordinatorProfileSupportTest,
       FollowsAegisProfileSupportContract) {
  auto* regular = AccessServiceCoordinator::GetOrCreate(regular_profile());
  auto* incognito = AccessServiceCoordinator::GetOrCreate(incognito_profile());

  ASSERT_TRUE(regular);
  ASSERT_TRUE(incognito);
  EXPECT_NE(regular, incognito);
  EXPECT_EQ(AccessServiceCoordinator::Get(regular_profile()), regular);
  EXPECT_EQ(AccessServiceCoordinator::Get(incognito_profile()), incognito);

  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(guest_profile()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(guest_profile_otr()), nullptr);

#if !BUILDFLAG(IS_CHROMEOS) && !BUILDFLAG(IS_ANDROID)
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(system_profile()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(system_profile_otr()), nullptr);
#endif

#if BUILDFLAG(IS_CHROMEOS)
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(signin_profile()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(signin_profile_otr()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(lockscreen_profile()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(lockscreen_profile_otr()),
            nullptr);
#endif

  Profile* auxiliary_off_the_record = regular_profile()->GetOffTheRecordProfile(
      Profile::OTRProfileID::CreateUniqueForTesting(),
      /*create_if_needed=*/true);
  ASSERT_TRUE(auxiliary_off_the_record);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(auxiliary_off_the_record),
            nullptr);
}

}  // namespace
}  // namespace aegis::access
