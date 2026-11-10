// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_network_context_transport.h"

#include "base/test/test_future.h"
#include "chrome/browser/aegis/access/access_private_context_client.h"
#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "services/network/test/test_network_context.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class HeldPrivateContext final : public network::TestNetworkContext,
                                 public network::mojom::AegisAccessContext {
 public:
  void BindAegisAccessContext(
      mojo::PendingReceiver<network::mojom::AegisAccessContext> receiver,
      BindAegisAccessContextCallback callback) override {
    receivers.Add(this, std::move(receiver));
    std::move(callback).Run(incarnation);
  }
  void InstallSnapshot(network::mojom::AegisAccessSnapshotPtr value,
                       InstallSnapshotCallback callback) override {
    ++install_count;
    snapshot = std::move(value);
    reply = std::move(callback);
  }
  void Acknowledge() {
    CHECK(reply);
    auto ack = network::mojom::AegisAccessSnapshotAck::New();
    ack->accepted = true;
    ack->owner = snapshot->owner.Clone();
    ack->incarnation = snapshot->incarnation;
    ack->sequence = snapshot->sequence;
    ack->common_generations = snapshot->common_generations.Clone();
    for (const auto& endpoint : snapshot->endpoints) {
      ack->registrations.push_back(
          network::mojom::AegisAccessRegistrationAck::New(
              endpoint->proxy_group_id, endpoint->registration_id,
              endpoint->selection_generation));
    }
    for (const auto& unavailable : snapshot->unavailable_groups)
      ack->unavailable_groups.push_back(unavailable.Clone());
    std::move(reply).Run(std::move(ack));
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

  std::string incarnation = "actual-context";
  size_t install_count = 0;
  network::mojom::AegisAccessSnapshotPtr snapshot;
  InstallSnapshotCallback reply;
  mojo::ReceiverSet<network::mojom::AegisAccessContext> receivers;
};

class AccessPrivatePublicationTest : public testing::Test {
 protected:
  void SetUp() override {
    profile_ = TestingProfile::Builder().Build();
    network::mojom::NetworkContextParams params;
    ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), {}, &params));
    transport_ = AccessNetworkContextTransport::Get(profile_.get());
    owner_ = *transport_->OwnerForPartition(aegis_access::ChannelNamespace::kDev, {});
  }
  AccessNetworkContextTransport::PrivateContext Bind(HeldPrivateContext& context) {
    base::test::TestFuture<AccessNetworkContextTransport::PrivateContext> bound;
    transport_->BindPrivateContext(owner_, &context, bound.GetCallback());
    return bound.Take();
  }
  aegis_access::PublishedAccessPolicySnapshot Policy(uint64_t generation = 1) {
    return {owner_, generation, {}};
  }
  aegis_access::GenerationTuple Common(uint64_t generation = 1) {
    return {generation, 2, 0, transport_->network_epoch(), 5};
  }
  void AddProxyRule(aegis_access::PublishedAccessPolicySnapshot& policy,
                    const std::string& group) {
    policy.rules.push_back({.rule_id = group,
                            .owner = owner_,
                            .scope = aegis_access::PolicyScope::kProfile,
                            .destination_host = group + ".example",
                            .schemes = {aegis_access::RequestScheme::kHttps},
                            .ports = {aegis_access::PortScope::kAllBrowserPermitted, {}},
                            .mode = aegis_access::AccessMode::kProxy,
                            .proxy_group_id = group,
                            .protection_override = aegis_access::ProtectionOverride::kNone,
                            .row_revision = 1,
                            .last_operation_sequence = 1});
  }

  content::BrowserTaskEnvironment environment_;
  std::unique_ptr<TestingProfile> profile_;
  raw_ptr<AccessNetworkContextTransport> transport_ = nullptr;
  aegis_access::OwnershipKey owner_;
};

TEST_F(AccessPrivatePublicationTest, FactoriesShareOneContextAndExactPublication) {
  HeldPrivateContext context;
  auto first = Bind(context);
  auto second = Bind(context);
  ASSERT_TRUE(first);
  EXPECT_EQ(first, second);
  base::test::TestFuture<bool> one;
  base::test::TestFuture<bool> two;
  transport_->PublishPrivatePolicy(Policy(), Common(), one.GetCallback());
  transport_->PublishPrivatePolicy(Policy(), Common(), two.GetCallback());
  environment_.RunUntilIdle();
  EXPECT_EQ(context.install_count, 1u);
  EXPECT_FALSE(one.IsReady());
  EXPECT_FALSE(transport_->HasReadyPrivateContext(owner_));
  context.Acknowledge();
  EXPECT_TRUE(one.Get());
  EXPECT_TRUE(two.Get());
  EXPECT_TRUE(transport_->HasReadyPrivateContext(owner_));
}

TEST_F(AccessPrivatePublicationTest, WholeSnapshotIncludesReadyAndUnavailableGroups) {
  HeldPrivateContext context;
  ASSERT_TRUE(Bind(context));
  auto policy = Policy();
  AddProxyRule(policy, "ready");
  AddProxyRule(policy, "cold");
  auto generations = Common();
  generations.selection_generation = 3;
  ASSERT_TRUE(transport_->RegisterPreparedProxy({
      {"real-registration", "ready", owner_, generations,
       aegis_access::RegisteredProxyTransport::kHttp, "127.0.0.1", 18080},
      net::AuthCredentials(u"local", u"private") }));
  base::test::TestFuture<bool> published;
  transport_->PublishPrivatePolicy(policy, Common(), published.GetCallback());
  environment_.RunUntilIdle();
  ASSERT_TRUE(context.snapshot);
  ASSERT_EQ(context.snapshot->endpoints.size(), 1u);
  EXPECT_EQ(context.snapshot->endpoints[0]->registration_id, "real-registration");
  ASSERT_EQ(context.snapshot->unavailable_groups.size(), 1u);
  EXPECT_EQ(context.snapshot->unavailable_groups[0]->proxy_group_id, "cold");
  EXPECT_EQ(context.snapshot->unavailable_groups[0]->selection_generation, 0u);
  EXPECT_EQ(context.snapshot->rules.size(), 2u);
  context.Acknowledge();
  EXPECT_TRUE(published.Get());
}

TEST_F(AccessPrivatePublicationTest, SupersededAckCannotReleaseNewCandidate) {
  HeldPrivateContext context;
  ASSERT_TRUE(Bind(context));
  base::test::TestFuture<bool> previous;
  base::test::TestFuture<bool> current;
  transport_->PublishPrivatePolicy(Policy(), Common(), previous.GetCallback());
  environment_.RunUntilIdle();
  transport_->PublishPrivatePolicy(Policy(2), Common(2), current.GetCallback());
  EXPECT_FALSE(previous.Get());
  context.Acknowledge();
  environment_.RunUntilIdle();
  EXPECT_FALSE(current.IsReady());
  EXPECT_FALSE(transport_->HasReadyPrivateContext(owner_));
  ASSERT_EQ(context.install_count, 2u);
  EXPECT_EQ(context.snapshot->sequence, 2u);
  EXPECT_EQ(context.snapshot->common_generations->policy_generation, 2u);
  context.Acknowledge();
  EXPECT_TRUE(current.Get());
}

TEST_F(AccessPrivatePublicationTest, LostContextRequiresFullNewIncarnationAck) {
  HeldPrivateContext old;
  ASSERT_TRUE(Bind(old));
  base::test::TestFuture<bool> previous;
  transport_->PublishPrivatePolicy(Policy(), Common(), previous.GetCallback());
  environment_.RunUntilIdle();
  old.receivers.Clear();
  EXPECT_FALSE(previous.Get());
  EXPECT_FALSE(transport_->HasReadyPrivateContext(owner_));
  HeldPrivateContext replacement;
  replacement.incarnation = "new-context";
  ASSERT_TRUE(Bind(replacement));
  base::test::TestFuture<bool> restored;
  transport_->PublishPrivatePolicy(Policy(), Common(), restored.GetCallback());
  environment_.RunUntilIdle();
  EXPECT_FALSE(restored.IsReady());
  EXPECT_EQ(replacement.snapshot->incarnation, "new-context");
  EXPECT_EQ(replacement.snapshot->sequence, 1u);
  replacement.Acknowledge();
  EXPECT_TRUE(restored.Get());
  EXPECT_TRUE(transport_->HasReadyPrivateContext(owner_));
}

}  // namespace
}  // namespace aegis::access
