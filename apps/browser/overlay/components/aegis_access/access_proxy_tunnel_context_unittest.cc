// Copyright 2026 GCSA

#include <optional>
#include <utility>

#include "net/http/access_proxy_route.h"
#include "net/http/http_proxy_connect_job.h"

#include "base/test/gtest_util.h"
#include "net/socket/connect_job_params_factory.h"
#include "net/socket/transport_connect_job.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access {
namespace {

net::ProxyChain Proxy(uint16_t port = 8080) {
  return net::ProxyChain::FromSchemeHostAndPort(
      net::ProxyServer::SCHEME_HTTP, "127.0.0.1", port);
}

scoped_refptr<net::AccessProxyRoute> Route() {
  return net::AccessProxyRoute::Create(
      {.channel = 0, .profile = "p", .partition = "s", .group = "g",
       .registration = "r", .incarnation = "i", .policy_generation = 1,
       .identity_generation = 1, .selection_generation = 1,
       .network_epoch = 1, .base_proxy_config_generation = 1}, Proxy());
}

scoped_refptr<net::HttpProxySocketParams> Tunnel(
    scoped_refptr<net::AccessProxyRoute> route,
    net::ProxyChain chain = Proxy(),
    std::optional<net::HostPortPair> transport_endpoint = std::nullopt) {
  auto transport = base::MakeRefCounted<net::TransportSocketParams>(
      transport_endpoint.value_or(chain.GetProxyServer(0).host_port_pair()),
      net::NetworkAnonymizationKey(), net::SecureDnsPolicy::kAllow,
      net::handles::kInvalidNetworkHandle, net::OnHostResolutionCallback(),
      base::flat_set<std::string>());
  return base::MakeRefCounted<net::HttpProxySocketParams>(
      net::ConnectJobParams(std::move(transport)),
      net::HostPortPair("destination.test", 443), chain, 0, true,
      TRAFFIC_ANNOTATION_FOR_TESTS, net::NetworkAnonymizationKey(),
      net::SecureDnsPolicy::kAllow, net::handles::kInvalidNetworkHandle,
      std::move(route));
}

TEST(AccessProxyTunnelContextTest, TunnelRetainsOriginalRoute) {
  auto route = Route();
  ASSERT_TRUE(route);
  auto params = Tunnel(route);
  auto* original = route.get();
  route = nullptr;
  ASSERT_TRUE(params->access_proxy_route());
  EXPECT_EQ(params->access_proxy_route().get(), original);
  EXPECT_EQ(params->access_proxy_route()->proxy_chain(), params->proxy_chain());
}

TEST(AccessProxyTunnelContextTest, UsesPrivateProxyCacheInsteadOfSessionCache) {
  net::HttpAuthCache native(true);
  auto route = Route();
  ASSERT_TRUE(route);
  auto params = Tunnel(route);
  EXPECT_EQ(params->GetProxyAuthCache(&native), route->proxy_auth_cache());
  EXPECT_NE(params->GetProxyAuthCache(&native), &native);
  // This remains private even when the session has no cache.
  EXPECT_EQ(params->GetProxyAuthCache(nullptr), route->proxy_auth_cache());
}

TEST(AccessProxyTunnelContextTest, NativeTunnelKeepsSessionCache) {
  net::HttpAuthCache native(true);
  auto params = Tunnel(nullptr);
  EXPECT_FALSE(params->access_proxy_route());
  EXPECT_EQ(params->GetProxyAuthCache(&native), &native);
}

TEST(AccessProxyTunnelContextTest, MismatchedEndpointCannotReceiveCredentials) {
  EXPECT_CHECK_DEATH(Tunnel(Route(), Proxy(8081)));
}

TEST(AccessProxyTunnelContextTest, MismatchedTransportCannotReceiveCredentials) {
  EXPECT_CHECK_DEATH(Tunnel(Route(), Proxy(),
                           net::HostPortPair("127.0.0.1", 8081)));
}

net::ConnectJobParams BuildParams(scoped_refptr<net::AccessProxyRoute> route,
                                  net::ProxyChain chain = Proxy()) {
  return net::ConstructConnectJobParams(
      url::SchemeHostPort("http", "destination.test", 80), chain,
      TRAFFIC_ANNOTATION_FOR_TESTS, {},
      net::ConnectJobFactory::AlpnMode::kDisabled, true,
      net::PRIVACY_MODE_DISABLED, net::OnHostResolutionCallback(),
      net::NetworkAnonymizationKey(), net::SecureDnsPolicy::kAllow, false,
      nullptr, net::NetworkAnonymizationKey(),
      net::handles::kInvalidNetworkHandle, std::move(route));
}

TEST(AccessProxyTunnelContextTest, FactoryPreservesRegisteredRoute) {
  auto route = Route();
  ASSERT_TRUE(route);
  auto params = BuildParams(route);
  ASSERT_TRUE(params.is_http_proxy());
  EXPECT_EQ(params.http_proxy()->access_proxy_route(), route);
  EXPECT_TRUE(params.http_proxy()->tunnel());
  EXPECT_EQ(params.http_proxy()->transport_params()->destination(),
            net::TransportSocketParams::Endpoint(
                Proxy().GetProxyServer(0).host_port_pair()));
}

TEST(AccessProxyTunnelContextTest, FactoryPreservesNativeRoute) {
  auto params = BuildParams(nullptr);
  ASSERT_TRUE(params.is_http_proxy());
  EXPECT_FALSE(params.http_proxy()->access_proxy_route());
  auto direct = BuildParams(nullptr, net::ProxyChain::Direct());
  EXPECT_TRUE(direct.is_transport());
}

TEST(AccessProxyTunnelContextTest, FactoryCannotDowngradeRouteToDirect) {
  EXPECT_CHECK_DEATH(BuildParams(Route(), net::ProxyChain::Direct()));
  EXPECT_CHECK_DEATH(BuildParams(Route(), Proxy(8081)));
}

class CapturingProxyFactory : public net::HttpProxyConnectJob::Factory {
 public:
  scoped_refptr<net::AccessProxyRoute> captured_route;
  int calls = 0;

  std::unique_ptr<net::HttpProxyConnectJob> Create(
      net::RequestPriority priority,
      const net::SocketTag& socket_tag,
      const net::CommonConnectJobParams* common_params,
      scoped_refptr<net::HttpProxySocketParams> params,
      net::ConnectJob::Delegate* delegate,
      const net::NetLogWithSource* net_log) override {
    ++calls;
    captured_route = params->access_proxy_route();
    EXPECT_TRUE(params->tunnel());
    return nullptr;
  }
};

TEST(AccessProxyTunnelContextTest, ConnectJobFactoryRetainsRouteThroughDispatch) {
  auto capture = std::make_unique<CapturingProxyFactory>();
  auto* observed = capture.get();
  net::ConnectJobFactory factory(std::move(capture));
  auto route = Route();
  ASSERT_TRUE(route);
  auto result = factory.CreateConnectJob(
      url::SchemeHostPort("http", "destination.test", 80), Proxy(),
      TRAFFIC_ANNOTATION_FOR_TESTS, {},
      net::ConnectJobFactory::AlpnMode::kDisabled, true,
      net::PRIVACY_MODE_DISABLED, net::OnHostResolutionCallback(),
      net::DEFAULT_PRIORITY, net::SocketTag(), net::NetworkAnonymizationKey(),
      net::SecureDnsPolicy::kAllow, false, nullptr,
      net::handles::kInvalidNetworkHandle, nullptr, route);
  EXPECT_FALSE(result);
  EXPECT_EQ(observed->calls, 1);
  EXPECT_EQ(observed->captured_route, route);

  // Existing native callers omit the new argument and keep their cache path.
  factory.CreateConnectJob(
      false, net::HostPortPair("destination.test", 80), Proxy(),
      TRAFFIC_ANNOTATION_FOR_TESTS, true, net::PRIVACY_MODE_DISABLED,
      net::OnHostResolutionCallback(), net::DEFAULT_PRIORITY, net::SocketTag(),
      net::NetworkAnonymizationKey(), net::SecureDnsPolicy::kAllow, nullptr,
      net::handles::kInvalidNetworkHandle, nullptr);
  EXPECT_EQ(observed->calls, 2);
  EXPECT_FALSE(observed->captured_route);
}

}  // namespace
}  // namespace aegis_access
