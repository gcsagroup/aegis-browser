// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_network_context_transport.h"

#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/test/task_environment.h"
#include "base/time/time.h"
#include "chrome/test/base/testing_profile.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/network_anonymization_key.h"
#include "net/base/network_change_notifier.h"
#include "net/base/proxy_string_util.h"
#include "net/proxy_resolution/proxy_info.h"
#include "services/network/network_service_proxy_delegate.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis::access {

class AccessNetworkContextTransportTestPeer {
 public:
  static void SetNetworkEpoch(AccessNetworkContextTransport* transport,
                              uint64_t epoch) {
    transport->network_epoch_ = epoch;
  }
};

namespace {

constexpr char kTargetHost[] = "target.example";
constexpr uint16_t kProxyPort = 18080;

class AccessNetworkContextTransportTest : public testing::Test {
 protected:
  AccessNetworkContextTransportTest() = default;

  void SetUp() override {
    network_change_notifier_ =
        net::NetworkChangeNotifier::CreateMockIfNeeded();
    profile_ = TestingProfile::Builder().Build();
    transport_ = AccessNetworkContextTransport::GetOrCreate(profile_.get());
    ASSERT_TRUE(transport_);
  }

  aegis_access::RegisteredProxyEndpoint EndpointFor(
      const base::FilePath& partition) {
    std::optional<aegis_access::OwnershipKey> owner =
        transport_->OwnerForPartition(aegis_access::ChannelNamespace::kDev,
                                      partition);
    EXPECT_TRUE(owner.has_value());
    return aegis_access::RegisteredProxyEndpoint{
        "registration-local", "proxy-group-local", *owner,
        aegis_access::GenerationTuple{1, 2, 3, transport_->network_epoch(), 5},
        aegis_access::RegisteredProxyTransport::kHttp, "127.0.0.1",
        kProxyPort};
  }

  std::unique_ptr<network::NetworkServiceProxyDelegate> CreateDelegate(
      const base::FilePath& partition) {
    network::mojom::NetworkContextParams params;
    EXPECT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), partition, &params));
    EXPECT_TRUE(params.initial_custom_proxy_config);
    EXPECT_TRUE(params.custom_proxy_config_client_receiver.is_valid());
    return std::make_unique<network::NetworkServiceProxyDelegate>(
        std::move(params.initial_custom_proxy_config),
        std::move(params.custom_proxy_config_client_receiver),
        mojo::PendingRemote<network::mojom::CustomProxyConnectionObserver>());
  }

  net::ProxyInfo Resolve(
      network::NetworkServiceProxyDelegate* delegate,
      const std::string& url,
      const std::string& method = "GET",
      const net::ProxyRetryInfoMap& retry_info = net::ProxyRetryInfoMap()) {
    net::ProxyInfo result;
    result.UseNamedProxy("http://native.example:3128;direct://");
    delegate->OnResolveProxy(GURL(url), net::NetworkAnonymizationKey(), method,
                             retry_info, &result);
    return result;
  }

  void ExpectProxyResolution(
      network::NetworkServiceProxyDelegate* delegate,
      const std::string& url,
      const std::string& method = "GET",
      const net::ProxyRetryInfoMap& retry_info = net::ProxyRetryInfoMap()) {
    const net::ProxyInfo result = Resolve(delegate, url, method, retry_info);
    ASSERT_EQ(result.proxy_list().size(), 1u);
    EXPECT_FALSE(result.is_direct());
    EXPECT_EQ(result.proxy_chain().First().GetHost(), "127.0.0.1");
    EXPECT_EQ(result.proxy_chain().First().GetPort(), kProxyPort);
  }

  base::test::TaskEnvironment task_environment_;
  std::unique_ptr<net::NetworkChangeNotifier> network_change_notifier_;
  std::unique_ptr<TestingProfile> profile_;
  raw_ptr<AccessNetworkContextTransport> transport_ = nullptr;
};

TEST_F(AccessNetworkContextTransportTest,
       OwnsOnlyPartitionsConfiguredByThisProfileTransport) {
  network::mojom::NetworkContextParams default_params;
  ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(
      profile_.get(), base::FilePath(), &default_params));

  const auto default_owner = transport_->OwnerForPartition(
      aegis_access::ChannelNamespace::kDev, base::FilePath());
  ASSERT_TRUE(default_owner.has_value());
  EXPECT_TRUE(transport_->OwnsConfiguredPartition(*default_owner));

  const base::FilePath other_partition =
      base::FilePath::FromASCII("Storage/ext");
  const auto other_owner = transport_->OwnerForPartition(
      aegis_access::ChannelNamespace::kDev, other_partition);
  ASSERT_TRUE(other_owner.has_value());
  EXPECT_FALSE(transport_->OwnsConfiguredPartition(*other_owner));

  network::mojom::NetworkContextParams other_params;
  ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(
      profile_.get(), other_partition, &other_params));
  EXPECT_TRUE(transport_->OwnsConfiguredPartition(*other_owner));

  auto forged = *default_owner;
  forged.profile_token = "other-profile";
  EXPECT_FALSE(transport_->OwnsConfiguredPartition(forged));
}

TEST_F(AccessNetworkContextTransportTest, OffPreservesNativeProxyResult) {
  auto delegate = CreateDelegate(base::FilePath());

  const net::ProxyInfo result =
      Resolve(delegate.get(), "https://target.example/path");
  EXPECT_EQ(result.proxy_list().ToPacString(),
            "PROXY native.example:3128; DIRECT");
}

TEST_F(AccessNetworkContextTransportTest,
       ExactTargetUsesOnlyLoopbackAndOtherHostPreservesNative) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(
      partition, {kTargetHost}, EndpointFor(partition)));
  transport_->FlushClientsForTesting(partition);

  ExpectProxyResolution(delegate.get(), "https://target.example/path");
  ExpectProxyResolution(delegate.get(), "http://target.example/plain");

  const net::ProxyInfo other =
      Resolve(delegate.get(), "https://other.example/path");
  EXPECT_EQ(other.proxy_list().ToPacString(),
            "PROXY native.example:3128; DIRECT");

  const net::ProxyInfo subdomain =
      Resolve(delegate.get(), "https://sub.target.example/path");
  EXPECT_EQ(subdomain.proxy_list().ToPacString(),
            "PROXY native.example:3128; DIRECT");
}

TEST_F(AccessNetworkContextTransportTest,
       CapturesOnlyCurrentExactHostEndpoint) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  const auto endpoint = EndpointFor(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(
      partition, {kTargetHost}, endpoint));

  const auto captured = transport_->CaptureSelectedProxyEndpoint(
      endpoint.owner, endpoint.proxy_group_id, kTargetHost);
  ASSERT_TRUE(captured.has_value());
  EXPECT_EQ(*captured, endpoint);

  EXPECT_FALSE(transport_
                   ->CaptureSelectedProxyEndpoint(
                       endpoint.owner, endpoint.proxy_group_id, "other.example")
                   .has_value());
  EXPECT_FALSE(transport_
                   ->CaptureSelectedProxyEndpoint(endpoint.owner,
                                                  "other-proxy-group",
                                                  kTargetHost)
                   .has_value());

  auto forged_owner = endpoint.owner;
  forged_owner.profile_token = "other-profile";
  EXPECT_FALSE(transport_
                   ->CaptureSelectedProxyEndpoint(
                       forged_owner, endpoint.proxy_group_id, kTargetHost)
                   .has_value());
}

TEST_F(AccessNetworkContextTransportTest,
       CaptureHandlesUnsortedPublishedHosts) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  const auto endpoint = EndpointFor(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(
      partition, {"z.example", kTargetHost, "a.example"}, endpoint));

  EXPECT_TRUE(transport_
                  ->CaptureSelectedProxyEndpoint(
                      endpoint.owner, endpoint.proxy_group_id, "a.example")
                  .has_value());
  EXPECT_TRUE(transport_
                  ->CaptureSelectedProxyEndpoint(
                      endpoint.owner, endpoint.proxy_group_id, kTargetHost)
                  .has_value());
  EXPECT_TRUE(transport_
                  ->CaptureSelectedProxyEndpoint(
                      endpoint.owner, endpoint.proxy_group_id, "z.example")
                  .has_value());
}

TEST_F(AccessNetworkContextTransportTest,
       CaptureRejectsEndpointAfterNetworkEpochChanges) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  const auto endpoint = EndpointFor(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(
      partition, {kTargetHost}, endpoint));

  net::NetworkChangeNotifier::NotifyObserversOfNetworkChangeForTests(
      net::NetworkChangeNotifier::CONNECTION_NONE);
  task_environment_.RunUntilIdle();

  EXPECT_FALSE(transport_
                   ->CaptureSelectedProxyEndpoint(
                       endpoint.owner, endpoint.proxy_group_id, kTargetHost)
                   .has_value());
}

TEST_F(AccessNetworkContextTransportTest,
       RealCustomProxyConfigCallbackAcknowledgesPublication) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  const auto endpoint = EndpointFor(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(
      partition, {kTargetHost}, endpoint));

  std::optional<bool> acked;
  const auto started = transport_->RepublishCurrentConfigWithAck(
      endpoint.owner,
      base::BindOnce(
          [](std::optional<bool>* value, bool success) { *value = success; },
          &acked));
  EXPECT_EQ(started.status, AccessNetworkConfigAckStatus::kStarted);
  EXPECT_EQ(started.required_client_acks, 1u);
  EXPECT_FALSE(acked.has_value());

  transport_->FlushClientsForTesting(partition);
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(acked.has_value());
  EXPECT_TRUE(*acked);
}

TEST_F(AccessNetworkContextTransportTest,
       PublicationAckWaitsForEveryAttachedNetworkContext) {
  const base::FilePath partition;
  auto first_delegate = CreateDelegate(partition);
  auto second_delegate = CreateDelegate(partition);
  const auto endpoint = EndpointFor(partition);

  std::optional<bool> acked;
  const auto started = transport_->RepublishCurrentConfigWithAck(
      endpoint.owner,
      base::BindOnce(
          [](std::optional<bool>* value, bool success) { *value = success; },
          &acked));
  EXPECT_EQ(started.status, AccessNetworkConfigAckStatus::kStarted);
  EXPECT_EQ(started.required_client_acks, 2u);
  EXPECT_FALSE(acked.has_value());

  transport_->FlushClientsForTesting(partition);
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(acked.has_value());
  EXPECT_TRUE(*acked);
}

TEST_F(AccessNetworkContextTransportTest,
       DroppedMojoCallbackSettlesAsFailureAndNeverAsAck) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  auto owner = transport_->OwnerForPartition(
      aegis_access::ChannelNamespace::kDev, partition);
  ASSERT_TRUE(owner.has_value());

  std::optional<bool> settled;
  const auto started = transport_->RepublishCurrentConfigWithAck(
      *owner,
      base::BindOnce(
          [](std::optional<bool>* value, bool success) { *value = success; },
          &settled));
  ASSERT_EQ(started.status, AccessNetworkConfigAckStatus::kStarted);
  EXPECT_FALSE(settled.has_value());

  delegate.reset();
  task_environment_.RunUntilIdle();
  ASSERT_TRUE(settled.has_value());
  EXPECT_FALSE(*settled);

  std::optional<bool> no_client_callback;
  const auto no_client = transport_->RepublishCurrentConfigWithAck(
      *owner,
      base::BindOnce(
          [](std::optional<bool>* value, bool success) { *value = success; },
          &no_client_callback));
  EXPECT_EQ(no_client.status, AccessNetworkConfigAckStatus::kNoClients);
  ASSERT_TRUE(no_client_callback.has_value());
  EXPECT_FALSE(*no_client_callback);
}

TEST_F(AccessNetworkContextTransportTest,
       PublicationAckRejectsForgedOwner) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  auto owner = transport_->OwnerForPartition(
      aegis_access::ChannelNamespace::kDev, partition);
  ASSERT_TRUE(owner.has_value());

  std::optional<bool> settled;
  auto forged = *owner;
  forged.profile_token = "other-profile";
  const auto forged_result = transport_->RepublishCurrentConfigWithAck(
      forged,
      base::BindOnce(
          [](std::optional<bool>* value, bool success) { *value = success; },
          &settled));
  EXPECT_EQ(forged_result.status, AccessNetworkConfigAckStatus::kInvalidOwner);
  ASSERT_TRUE(settled.has_value());
  EXPECT_FALSE(*settled);
}

TEST_F(AccessNetworkContextTransportTest,
       NonIdempotentFirstSendUsesSelectedProxy) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(
      partition, {kTargetHost}, EndpointFor(partition)));
  transport_->FlushClientsForTesting(partition);

  ExpectProxyResolution(delegate.get(), "https://target.example/submit",
                        "POST");
}

TEST_F(AccessNetworkContextTransportTest,
       BadSelectedProxyNeverFallsBackToNativeDirect) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(
      partition, {kTargetHost}, EndpointFor(partition)));
  transport_->FlushClientsForTesting(partition);

  net::ProxyRetryInfoMap retry_info;
  net::ProxyRetryInfo& failed = retry_info[net::ProxyUriToProxyChain(
      "127.0.0.1:18080", net::ProxyServer::SCHEME_HTTP)];
  failed.bad_until = base::TimeTicks::Now() + base::Days(2);

  ExpectProxyResolution(delegate.get(),
                        "https://target.example/fail-closed", "GET",
                        retry_info);
}

TEST_F(AccessNetworkContextTransportTest,
       ClearSelectionRestoresNativeProxyResult) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(
      partition, {kTargetHost}, EndpointFor(partition)));
  transport_->FlushClientsForTesting(partition);
  ASSERT_EQ(Resolve(delegate.get(), "https://target.example/")
                .proxy_list()
                .size(),
            1u);

  ASSERT_TRUE(transport_->ClearProxySelection(partition));
  transport_->FlushClientsForTesting(partition);
  const net::ProxyInfo restored =
      Resolve(delegate.get(), "https://target.example/");
  EXPECT_EQ(restored.proxy_list().ToPacString(),
            "PROXY native.example:3128; DIRECT");
}

TEST_F(AccessNetworkContextTransportTest, StoragePartitionsAreIsolated) {
  const base::FilePath default_partition;
  const base::FilePath isolated_partition(FILE_PATH_LITERAL("isolated/site"));
  auto default_delegate = CreateDelegate(default_partition);
  auto isolated_delegate = CreateDelegate(isolated_partition);

  ASSERT_TRUE(transport_->PublishProxySelection(
      default_partition, {kTargetHost}, EndpointFor(default_partition)));
  transport_->FlushClientsForTesting(default_partition);

  EXPECT_EQ(Resolve(default_delegate.get(), "https://target.example/")
                .proxy_chain()
                .First()
                .GetHost(),
            "127.0.0.1");
  EXPECT_EQ(Resolve(isolated_delegate.get(), "https://target.example/")
                .proxy_list()
                .ToPacString(),
            "PROXY native.example:3128; DIRECT");
}

TEST_F(AccessNetworkContextTransportTest,
       NetworkChangeAdvancesEpochAndRejectsStaleEndpoint) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  ASSERT_EQ(transport_->network_epoch(), 1u);
  const aegis_access::RegisteredProxyEndpoint stale = EndpointFor(partition);
  ASSERT_TRUE(
      transport_->PublishProxySelection(partition, {kTargetHost}, stale));
  transport_->FlushClientsForTesting(partition);
  ExpectProxyResolution(delegate.get(), "https://target.example/before-change");

  net::NetworkChangeNotifier::NotifyObserversOfNetworkChangeForTests(
      net::NetworkChangeNotifier::CONNECTION_NONE);
  task_environment_.RunUntilIdle();

  EXPECT_GT(transport_->network_epoch(), stale.generations.network_epoch);
  EXPECT_FALSE(
      transport_->PublishProxySelection(partition, {kTargetHost}, stale));

  // The old localhost route remains installed while the new epoch is
  // revalidated. Clearing it here would expose Chromium's native route and
  // violate REQUIRE_PROXY's no-DIRECT-fallback contract.
  ExpectProxyResolution(delegate.get(), "https://target.example/rebinding");

  const aegis_access::RegisteredProxyEndpoint rebound = EndpointFor(partition);
  EXPECT_EQ(rebound.generations.network_epoch, transport_->network_epoch());
  EXPECT_TRUE(
      transport_->PublishProxySelection(partition, {kTargetHost}, rebound));
}

TEST_F(AccessNetworkContextTransportTest,
       NetworkEpochOverflowFailsClosedPermanently) {
  const base::FilePath partition;
  AccessNetworkContextTransportTestPeer::SetNetworkEpoch(
      transport_, std::numeric_limits<uint64_t>::max());
  const aegis_access::RegisteredProxyEndpoint last_valid = EndpointFor(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(
      partition, {kTargetHost}, last_valid));

  net::NetworkChangeNotifier::NotifyObserversOfNetworkChangeForTests(
      net::NetworkChangeNotifier::CONNECTION_NONE);
  task_environment_.RunUntilIdle();
  EXPECT_EQ(transport_->network_epoch(), 0u);
  EXPECT_FALSE(transport_->PublishProxySelection(
      partition, {kTargetHost}, last_valid));

  net::NetworkChangeNotifier::NotifyObserversOfNetworkChangeForTests(
      net::NetworkChangeNotifier::CONNECTION_WIFI);
  task_environment_.RunUntilIdle();
  EXPECT_EQ(transport_->network_epoch(), 0u);
  EXPECT_FALSE(transport_->PublishProxySelection(
      partition, {kTargetHost}, EndpointFor(partition)));
}

TEST_F(AccessNetworkContextTransportTest,
       NetworkEpochIsProfileOwnedAndStartsPublished) {
  EXPECT_EQ(transport_->network_epoch(), 1u);

  auto second_profile = TestingProfile::Builder().Build();
  auto* second_transport =
      AccessNetworkContextTransport::GetOrCreate(second_profile.get());
  ASSERT_TRUE(second_transport);
  EXPECT_EQ(second_transport->network_epoch(), 1u);

  net::NetworkChangeNotifier::NotifyObserversOfNetworkChangeForTests(
      net::NetworkChangeNotifier::CONNECTION_WIFI);
  task_environment_.RunUntilIdle();

  EXPECT_GT(transport_->network_epoch(), 1u);
  EXPECT_GT(second_transport->network_epoch(), 1u);
  EXPECT_EQ(transport_->network_epoch(), second_transport->network_epoch());
}

TEST_F(AccessNetworkContextTransportTest, RejectsCrossProfileEndpointOwnership) {
  auto other_profile = TestingProfile::Builder().Build();
  auto* other_transport =
      AccessNetworkContextTransport::GetOrCreate(other_profile.get());
  ASSERT_TRUE(other_transport);
  const base::FilePath partition;
  std::optional<aegis_access::OwnershipKey> other_owner =
      other_transport->OwnerForPartition(aegis_access::ChannelNamespace::kDev,
                                         partition);
  ASSERT_TRUE(other_owner.has_value());

  aegis_access::RegisteredProxyEndpoint endpoint = EndpointFor(partition);
  endpoint.owner = *other_owner;
  EXPECT_FALSE(transport_->PublishProxySelection(partition, {kTargetHost},
                                                 endpoint));
}

TEST_F(AccessNetworkContextTransportTest,
       RejectsCrossPartitionAndInvalidChannelOwnership) {
  const base::FilePath source_partition(FILE_PATH_LITERAL("source"));
  const base::FilePath target_partition(FILE_PATH_LITERAL("target"));

  EXPECT_FALSE(transport_->PublishProxySelection(
      target_partition, {kTargetHost}, EndpointFor(source_partition)));

  aegis_access::RegisteredProxyEndpoint invalid_channel =
      EndpointFor(target_partition);
  invalid_channel.owner.channel = aegis_access::ChannelNamespace::kInvalid;
  EXPECT_FALSE(transport_->PublishProxySelection(
      target_partition, {kTargetHost}, invalid_channel));
}

TEST_F(AccessNetworkContextTransportTest, RejectsInvalidPartitionPaths) {
  const base::FilePath absolute(FILE_PATH_LITERAL("/absolute"));
  const base::FilePath parent(FILE_PATH_LITERAL("partition/../escape"));
  const base::FilePath too_long =
      base::FilePath::FromUTF8Unsafe(std::string(1025, 'a'));

  for (const base::FilePath* partition : {&absolute, &parent, &too_long}) {
    EXPECT_FALSE(transport_->OwnerForPartition(
                                aegis_access::ChannelNamespace::kDev, *partition)
                     .has_value());
    EXPECT_FALSE(transport_->ClearProxySelection(*partition));

    network::mojom::NetworkContextParams params;
    EXPECT_FALSE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), *partition, &params));
  }
}

TEST_F(AccessNetworkContextTransportTest,
       RejectedPublishDoesNotClobberExistingSelection) {
  const base::FilePath partition;
  auto delegate = CreateDelegate(partition);
  const auto endpoint = EndpointFor(partition);
  ASSERT_TRUE(transport_->PublishProxySelection(partition, {kTargetHost}, endpoint));
  transport_->FlushClientsForTesting(partition);

  EXPECT_FALSE(transport_->PublishProxySelection(partition, {}, endpoint));
  EXPECT_FALSE(transport_->PublishProxySelection(
      partition, std::vector<std::string>(257, kTargetHost), endpoint));
  EXPECT_FALSE(transport_->PublishProxySelection(
      partition, {kTargetHost, kTargetHost}, endpoint));
  EXPECT_FALSE(transport_->PublishProxySelection(
      partition, {"TARGET.example"}, endpoint));
  transport_->FlushClientsForTesting(partition);

  ExpectProxyResolution(delegate.get(),
                        "https://target.example/still-selected");
}

TEST_F(AccessNetworkContextTransportTest,
       DoesNotOverwriteAnotherCustomProxyOwner) {
  {
    network::mojom::NetworkContextParams params;
    params.initial_custom_proxy_config =
        network::mojom::CustomProxyConfig::New();
    EXPECT_FALSE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), base::FilePath(), &params));
  }

  {
    network::mojom::NetworkContextParams params;
    mojo::Remote<network::mojom::CustomProxyConfigClient> existing_client;
    params.custom_proxy_config_client_receiver =
        existing_client.BindNewPipeAndPassReceiver();
    EXPECT_FALSE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), base::FilePath(), &params));
  }

  {
    network::mojom::NetworkContextParams params;
    mojo::PendingRemote<network::mojom::CustomProxyConnectionObserver> observer;
    auto observer_receiver = observer.InitWithNewPipeAndPassReceiver();
    ASSERT_TRUE(observer_receiver.is_valid());
    params.custom_proxy_connection_observer_remote = std::move(observer);
    EXPECT_FALSE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), base::FilePath(), &params));
  }
}

TEST_F(AccessNetworkContextTransportTest, RejectsNonCanonicalHostSelection) {
  const base::FilePath partition;
  const auto endpoint = EndpointFor(partition);
  EXPECT_FALSE(transport_->PublishProxySelection(
      partition, {"TARGET.example"}, endpoint));
  EXPECT_FALSE(transport_->PublishProxySelection(
      partition, {"target.example."}, endpoint));
}

}  // namespace
}  // namespace aegis::access