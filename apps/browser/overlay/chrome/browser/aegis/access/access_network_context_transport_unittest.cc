// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_network_context_transport.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/test/task_environment.h"
#include "base/time/time.h"
#include "chrome/test/base/testing_profile.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/network_anonymization_key.h"
#include "net/base/proxy_string_util.h"
#include "net/proxy_resolution/proxy_info.h"
#include "services/network/network_service_proxy_delegate.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

constexpr char kTargetHost[] = "target.example";
constexpr uint16_t kProxyPort = 18080;

class AccessNetworkContextTransportTest : public testing::Test {
 protected:
  AccessNetworkContextTransportTest() = default;

  void SetUp() override {
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
        aegis_access::GenerationTuple{1, 2, 3, 4, 5},
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
  std::unique_ptr<TestingProfile> profile_;
  raw_ptr<AccessNetworkContextTransport> transport_ = nullptr;
};

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
