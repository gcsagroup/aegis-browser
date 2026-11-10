// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_bubble_controller.h"

#include "base/command_line.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/test/run_until.h"
#include "base/test/scoped_run_loop_timeout.h"
#include "base/test/test_future.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/access/access_published_request_runtime.h"
#include "chrome/browser/net/profile_network_context_service.h"
#include "chrome/browser/net/profile_network_context_service_factory.h"
#include "chrome/test/base/testing_profile.h"
#include "components/prefs/pref_service.h"
#include "components/proxy_config/proxy_config_pref_names.h"
#include "components/proxy_config/proxy_config_dictionary.h"
#include "content/public/test/browser_task_environment.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "services/network/test/test_network_context.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

// Real Mojo ACK with an explicit hold at the product PREPARED boundary. The
// core is not mocked: these tests require the authorized local DEV inputs.
class ProductAckContext final : public network::TestNetworkContext,
                                public network::mojom::AegisAccessContext {
 public:
  void BindAegisAccessContext(
      mojo::PendingReceiver<network::mojom::AegisAccessContext> receiver,
      BindAegisAccessContextCallback callback) override {
    receivers_.Add(this, std::move(receiver));
    std::move(callback).Run("product-test-context");
  }
  void InstallSnapshot(network::mojom::AegisAccessSnapshotPtr snapshot,
                       InstallSnapshotCallback callback) override {
    auto ack = network::mojom::AegisAccessSnapshotAck::New();
    ack->accepted = true;
    ack->owner = snapshot->owner.Clone();
    ack->incarnation = snapshot->incarnation;
    ack->sequence = snapshot->sequence;
    ack->common_generations = snapshot->common_generations.Clone();
    for (const auto& endpoint : snapshot->endpoints)
      ack->registrations.push_back(
          network::mojom::AegisAccessRegistrationAck::New(
              endpoint->proxy_group_id, endpoint->registration_id,
              endpoint->selection_generation));
    for (const auto& group : snapshot->unavailable_groups)
      ack->unavailable_groups.push_back(group.Clone());
    if (hold_next) {
      hold_next = false;
      held_ack_ = std::move(ack);
      held_reply_ = std::move(callback);
    } else {
      std::move(callback).Run(std::move(ack));
    }
  }
  bool has_reply() const { return !!held_reply_; }
  void Reply(bool accepted) {
    CHECK(held_reply_);
    held_ack_->accepted = accepted;
    std::move(held_reply_).Run(std::move(held_ack_));
  }
  void BeginRestore(network::mojom::AegisAccessOwnerPtr, const std::string&,
                    BeginRestoreCallback callback) override {
    std::move(callback).Run(true);
  }
  void CreateFactory(
      mojo::PendingReceiver<network::mojom::AegisAccessURLLoaderFactory>,
      network::mojom::URLLoaderFactoryParamsPtr,
      network::mojom::AegisAccessFactoryBindingPtr,
      CreateFactoryCallback callback) override {
    std::move(callback).Run(true);
  }
  bool hold_next = false;

 private:
  network::mojom::AegisAccessSnapshotAckPtr held_ack_;
  InstallSnapshotCallback held_reply_;
  mojo::ReceiverSet<network::mojom::AegisAccessContext> receivers_;
};

class AccessSiteProxyProductTest : public testing::Test {
 protected:
  void SetUp() override {
    const auto* command = base::CommandLine::ForCurrentProcess();
    if (command->GetSwitchValuePath("aegis-access-dev-core-manifest").empty() ||
        command->GetSwitchValuePath("aegis-access-dev-node-config").empty()) {
      GTEST_SKIP() << "Real product core tests require authorized DEV inputs.";
    }
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    profile_ = TestingProfile::Builder()
        .SetPath(directory_.GetPath())
        .AddTestingFactory(ProfileNetworkContextServiceFactory::GetInstance(),
            base::BindRepeating([](content::BrowserContext* context)
                -> std::unique_ptr<KeyedService> {
              return std::make_unique<ProfileNetworkContextService>(
                  Profile::FromBrowserContext(context));
            }))
        .Build();
    ASSERT_TRUE(ProfileNetworkContextServiceFactory::GetForContext(profile_.get()));
    // TestingProfile disables this service by default. Publish an actual
    // native DIRECT preference change so its monitor owns the C generation.
    profile_->GetPrefs()->SetDict(proxy_config::prefs::kProxy,
                                  ProxyConfigDictionary::CreateDirect());
    environment_.RunUntilIdle();
    network::mojom::NetworkContextParams params;
    ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), {}, &params));
    transport_ = AccessNetworkContextTransport::Get(profile_.get());
    owner_ = *transport_->OwnerForPartition(ChannelNamespace::kDev, {});
    coordinator_ = AccessServiceCoordinator::GetOrCreate(profile_.get());
    base::test::TestFuture<bool> restored;
    coordinator_->InitializeForProfile(owner_, restored.GetCallback());
    ASSERT_TRUE(restored.Get());
    base::test::TestFuture<AccessNetworkContextTransport::PrivateContext> bound;
    transport_->BindPrivateContext(owner_, &context_, bound.GetCallback());
    ASSERT_TRUE(bound.Get());
    auto* runtime = AccessPublishedRequestRuntime::Get(profile_.get());
    const auto common = runtime->CaptureCommonGenerationTupleOnUiThread(owner_);
    ASSERT_TRUE(common);
    base::test::TestFuture<bool> published;
    transport_->PublishPrivatePolicy(*runtime->GetPublishedPolicySnapshot(owner_),
                                    *common, published.GetCallback());
    ASSERT_TRUE(published.Get());
    bubble_ = AccessSiteProxyBubbleController::GetOrCreate(profile_.get());
    ASSERT_TRUE(bubble_);
  }
  AccessSiteProxyBubbleSnapshot Snapshot(const char* host = "news.example") {
    return bubble_->SnapshotForCommittedUrl(GURL(std::string("https://") + host));
  }
  void WaitFor(AccessSiteConnectionState state, const char* host = "news.example") {
    ASSERT_TRUE(base::test::RunUntil([&] { return Snapshot(host).connection == state; }));
  }
  void Enable() {
    context_.hold_next = true;
    ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, true));
    ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
    EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kConnecting);
    context_.Reply(true);
    WaitFor(AccessSiteConnectionState::kReady);
  }

  content::BrowserTaskEnvironment environment_;
  base::test::ScopedRunLoopTimeout timeout_{FROM_HERE, base::Seconds(90)};
  base::ScopedTempDir directory_;
  ProductAckContext context_;
  std::unique_ptr<TestingProfile> profile_;
  raw_ptr<AccessNetworkContextTransport> transport_ = nullptr;
  raw_ptr<AccessServiceCoordinator> coordinator_ = nullptr;
  raw_ptr<AccessSiteProxyBubbleController> bubble_ = nullptr;
  OwnershipKey owner_;
};

TEST_F(AccessSiteProxyProductTest, OnOffOnUsesRealCoreAndCommittedRevision) {
  uint64_t previous = 0;
  for (bool enabled : {true, false, true}) {
    context_.hold_next = true;
    ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, enabled));
    ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
    EXPECT_EQ(Snapshot().connection, AccessSiteConnectionState::kConnecting);
    context_.Reply(true);
    WaitFor(enabled ? AccessSiteConnectionState::kReady : AccessSiteConnectionState::kIdle);
    EXPECT_TRUE(Snapshot().failure_reason.empty());
    const auto stored = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
    ASSERT_TRUE(stored.value);
    EXPECT_GT(stored.value->policy_generation, previous);
    previous = stored.value->policy_generation;
    EXPECT_EQ(Snapshot().intent, enabled ? AccessSiteIntent::kAllow : AccessSiteIntent::kOff);
  }
}

TEST_F(AccessSiteProxyProductTest, FailedAckPreservesOffAndExplicitRecoveryRepublishes) {
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, true));
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  context_.Reply(false);
  WaitFor(AccessSiteConnectionState::kUnavailable);
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);
  ASSERT_TRUE(coordinator_->has_retained_store());
  Enable();
  ASSERT_TRUE(bubble_->NotifyHostProxyRuntimeFault({"news.example"}, false));
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kAllow);
  Enable();
}

TEST_F(AccessSiteProxyProductTest, RetainedProductStoreSurvivesPrepareFailure) {
  auto plan = BuildSiteProxySessionMutationPlan(
      {"news.example"}, AccessSiteIntent::kAllow, owner_,
      "dev-authorized-local-node", "invalid-stale-revision", 99);
  ASSERT_TRUE(plan.mutation.request);
  base::test::TestFuture<AccessMutationTransactionResult> failed;
  coordinator_->CommitSiteGroupMutation(nullptr, std::move(*plan.mutation.request),
                                       plan.selector, failed.GetCallback());
  EXPECT_EQ(failed.Get().status, AccessMutationTransactionStatus::kPrepareFailed);
  ASSERT_TRUE(coordinator_->has_retained_store());
  Enable();
}

TEST_F(AccessSiteProxyProductTest, CanDisableAfterEndpointBecomesUnavailable) {
  Enable();
  ASSERT_TRUE(transport_->ClearProxySelection({}));
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, false));
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  context_.Reply(true);
  WaitFor(AccessSiteConnectionState::kIdle);
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);
  const auto stored = coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(stored.value);
  ASSERT_EQ(stored.value->site_groups.size(), 1u);
  EXPECT_EQ(stored.value->site_groups[0].members[0].policy.mode, AccessMode::kDirect);
}

TEST_F(AccessSiteProxyProductTest, HostFailuresRemainIndependent) {
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"news.example"}, true));
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  context_.Reply(false);
  WaitFor(AccessSiteConnectionState::kUnavailable);
  const auto failed = Snapshot();
  ASSERT_FALSE(failed.failure_reason.empty());
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"other.example"}, false));
  ASSERT_TRUE(base::test::RunUntil([&] { return context_.has_reply(); }));
  context_.Reply(true);
  WaitFor(AccessSiteConnectionState::kIdle, "other.example");
  EXPECT_EQ(Snapshot().connection, failed.connection);
  EXPECT_EQ(Snapshot().failure_reason, failed.failure_reason);
  EXPECT_EQ(Snapshot().intent, AccessSiteIntent::kOff);
}

TEST_F(AccessSiteProxyProductTest, SubdomainEnablePersistsCanonicalSites) {
  context_.hold_next = true;
  ASSERT_TRUE(bubble_->RequestHostProxySession({"www.example.com"}, true));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return context_.has_reply() ||
           Snapshot("www.example.com").connection ==
               AccessSiteConnectionState::kUnavailable;
  }));
  ASSERT_TRUE(context_.has_reply())
      << Snapshot("www.example.com").failure_reason;
  context_.Reply(true);
  WaitFor(AccessSiteConnectionState::kReady, "www.example.com");
  const auto stored =
      coordinator_->ReadCommittedSnapshot(owner_.storage_partition_token);
  ASSERT_TRUE(stored.value);
  ASSERT_EQ(stored.value->site_groups.size(), 1u);
  const auto& group = stored.value->site_groups[0];
  EXPECT_EQ(group.group.canonical_host, "www.example.com");
  EXPECT_EQ(group.group.http_top_level_site, "http://example.com");
  EXPECT_EQ(group.group.https_top_level_site, "https://example.com");
  ASSERT_EQ(group.members.size(), 2u);
  for (const auto& member : group.members) {
    EXPECT_EQ(member.policy.destination_host, "www.example.com");
    EXPECT_FALSE(member.policy.include_subdomains);
  }
}

}  // namespace
}  // namespace aegis::access
