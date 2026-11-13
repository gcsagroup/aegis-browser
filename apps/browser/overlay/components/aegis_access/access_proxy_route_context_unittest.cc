// Copyright 2026 GCSA

#include "net/http/access_proxy_route.h"

#include <cstdint>
#include <optional>
#include <utility>

#include "net/base/proxy_server.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access {
namespace {

net::AccessRouteIsolationKey RouteKey() {
  return {.channel = 0,
          .profile = "profile-a",
          .partition = "partition-a",
          .group = "group-a",
          .registration = "registration-a",
          .incarnation = "context-a",
          .policy_generation = 1,
          .identity_generation = 2,
          .selection_generation = 3,
          .network_epoch = 4,
          .base_proxy_config_generation = 5};
}

net::ProxyChain LocalProxy() {
  return net::ProxyChain::FromSchemeHostAndPort(
      net::ProxyServer::SCHEME_HTTP, "127.0.0.1", 8080);
}

url::SchemeHostPort ProxyOrigin() {
  return url::SchemeHostPort("http", "127.0.0.1", 8080);
}

net::HttpAuthCache::Entry* Find(net::HttpAuthCache* cache) {
  return cache->Lookup(ProxyOrigin(), net::HttpAuth::AUTH_PROXY, "access",
                       net::HttpAuth::AUTH_SCHEME_BASIC,
                       net::NetworkAnonymizationKey());
}

void Add(net::HttpAuthCache* cache, const net::AuthCredentials& credentials) {
  cache->Add(ProxyOrigin(), net::HttpAuth::AUTH_PROXY, "access",
             net::HttpAuth::AUTH_SCHEME_BASIC, net::NetworkAnonymizationKey(),
             "Basic realm=\"access\"", credentials, "");
}

TEST(AccessProxyRouteContextTest, AcceptsOnlyCompleteLoopbackProxyValues) {
  for (auto scheme : {net::ProxyServer::SCHEME_HTTP,
                      net::ProxyServer::SCHEME_SOCKS5}) {
    for (const auto* address : {"127.0.0.1", "::1"}) {
      const auto chain = net::ProxyChain::FromSchemeHostAndPort(
          scheme, address, 8080);
      auto route = net::AccessProxyRoute::Create(RouteKey(), chain);
      ASSERT_TRUE(route);
      EXPECT_EQ(route->isolation_key(), RouteKey());
      EXPECT_EQ(route->proxy_chain(), chain);
      EXPECT_EQ(route->proxy_auth_cache()->GetEntriesSizeForTesting(), 0u);
    }
  }
}

TEST(AccessProxyRouteContextTest, RejectsInvalidOrUnregisteredTransportValues) {
  EXPECT_FALSE(net::AccessProxyRoute::Create({}, LocalProxy()));
  auto incomplete = RouteKey();
  incomplete.incarnation.clear();
  EXPECT_FALSE(net::AccessProxyRoute::Create(incomplete, LocalProxy()));
  EXPECT_FALSE(net::AccessProxyRoute::Create(RouteKey(), net::ProxyChain()));
  EXPECT_FALSE(net::AccessProxyRoute::Create(RouteKey(), net::ProxyChain::Direct()));
  for (const auto* address : {"localhost", "192.0.2.1", "0.0.0.0", "::"}) {
    EXPECT_FALSE(net::AccessProxyRoute::Create(
        RouteKey(), net::ProxyChain::FromSchemeHostAndPort(
                        net::ProxyServer::SCHEME_HTTP, address, 8080)));
  }
  EXPECT_FALSE(net::AccessProxyRoute::Create(
      RouteKey(), net::ProxyChain::FromSchemeHostAndPort(
                      net::ProxyServer::SCHEME_HTTP, "127.0.0.1",
                      std::optional<uint16_t>(0))));
  for (auto scheme : {net::ProxyServer::SCHEME_HTTPS,
                      net::ProxyServer::SCHEME_SOCKS4}) {
    EXPECT_FALSE(net::AccessProxyRoute::Create(
        RouteKey(), net::ProxyChain::FromSchemeHostAndPort(
                        scheme, "127.0.0.1", 8080)));
  }
}

TEST(AccessProxyRouteContextTest, ProxyCredentialsDoNotEnterNativeCache) {
  net::HttpAuthCache native(true);
  const net::AuthCredentials native_credentials(u"native", u"native-password");
  const net::AuthCredentials managed_credentials(u"managed", u"managed-password");
  Add(&native, native_credentials);
  auto route = net::AccessProxyRoute::Create(RouteKey(), LocalProxy());
  ASSERT_TRUE(route);
  EXPECT_FALSE(Find(route->proxy_auth_cache()));
  Add(route->proxy_auth_cache(), managed_credentials);
  ASSERT_TRUE(Find(&native));
  EXPECT_TRUE(Find(&native)->credentials().Equals(native_credentials));
  ASSERT_TRUE(Find(route->proxy_auth_cache()));
  EXPECT_TRUE(Find(route->proxy_auth_cache())->credentials().Equals(
      managed_credentials));
  EXPECT_TRUE(route->proxy_auth_cache()->ClearAllEntries());
  EXPECT_TRUE(Find(&native));
}

TEST(AccessProxyRouteContextTest, NewOwnerOrRegistrationNeverInheritsCredentials) {
  auto original = net::AccessProxyRoute::Create(RouteKey(), LocalProxy());
  ASSERT_TRUE(original);
  Add(original->proxy_auth_cache(), net::AuthCredentials(u"a", u"password-a"));
  for (auto member : {&net::AccessRouteIsolationKey::profile,
                      &net::AccessRouteIsolationKey::partition,
                      &net::AccessRouteIsolationKey::group,
                      &net::AccessRouteIsolationKey::registration,
                      &net::AccessRouteIsolationKey::incarnation}) {
    auto changed = RouteKey();
    changed.*member += "-new";
    auto next = net::AccessProxyRoute::Create(changed, LocalProxy());
    ASSERT_TRUE(next);
    EXPECT_FALSE(Find(next->proxy_auth_cache()));
    EXPECT_FALSE(next->proxy_auth_cache()->LookupByPath(
        ProxyOrigin(), net::HttpAuth::AUTH_PROXY,
        net::NetworkAnonymizationKey(), ""));
  }
  auto changed = RouteKey();
  ++changed.selection_generation;
  auto next = net::AccessProxyRoute::Create(changed, LocalProxy());
  ASSERT_TRUE(next);
  EXPECT_FALSE(Find(next->proxy_auth_cache()));
  EXPECT_TRUE(Find(original->proxy_auth_cache()));
}

TEST(AccessProxyRouteContextTest, InFlightReferenceRetainsOnlyItsOwnCache) {
  auto installed = net::AccessProxyRoute::Create(RouteKey(), LocalProxy());
  ASSERT_TRUE(installed);
  Add(installed->proxy_auth_cache(), net::AuthCredentials(u"old", u"old-secret"));
  auto in_flight = installed;
  auto replacement = RouteKey();
  ++replacement.policy_generation;
  installed = net::AccessProxyRoute::Create(replacement, LocalProxy());
  ASSERT_TRUE(installed);
  EXPECT_FALSE(Find(installed->proxy_auth_cache()));
  ASSERT_TRUE(Find(in_flight->proxy_auth_cache()));
  EXPECT_EQ(Find(in_flight->proxy_auth_cache())->credentials().username(), u"old");
}

}  // namespace
}  // namespace aegis_access
