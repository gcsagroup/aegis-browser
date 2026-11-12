// Copyright 2026 GCSA

#include "net/http/access_proxy_route.h"
#include "net/http/http_request_info.h"
#include "net/http/http_stream_factory.h"

#include <utility>

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access {
namespace {

scoped_refptr<net::AccessProxyRoute> Route(uint64_t generation = 1) {
  return net::AccessProxyRoute::Create(
      {.channel = 0,
       .profile = "profile",
       .partition = "partition",
       .group = "group",
       .registration = "registration",
       .incarnation = "incarnation",
       .policy_generation = 1,
       .identity_generation = 1,
       .selection_generation = generation,
       .network_epoch = 1,
       .base_proxy_config_generation = 1},
      net::ProxyChain::FromSchemeHostAndPort(
          net::ProxyServer::SCHEME_HTTP, "127.0.0.1", 8080));
}

TEST(AccessRouteRequestContextTest, CopiesKeepOriginalRouteAlive) {
  net::HttpRequestInfo request;
  request.url = GURL("https://example.test/resource");
  request.access_proxy_route = Route();
  ASSERT_TRUE(request.access_proxy_route);
  auto original = request.access_proxy_route;
  net::HttpRequestInfo copy(request);
  net::HttpRequestInfo assigned;
  assigned = request;
  net::HttpRequestInfo moved(std::move(copy));
  net::HttpStreamFactory::StreamRequestInfo stream(request);
  net::HttpStreamFactory::StreamRequestInfo stream_copy(stream);
  request.access_proxy_route = Route(2);
  EXPECT_EQ(assigned.access_proxy_route, original);
  EXPECT_EQ(moved.access_proxy_route, original);
  EXPECT_EQ(stream.access_proxy_route, original);
  EXPECT_EQ(stream_copy.access_proxy_route, original);
  EXPECT_NE(request.access_proxy_route, original);
}

TEST(AccessRouteRequestContextTest, NativeRequestHasNoRouteIdentity) {
  net::HttpRequestInfo request;
  request.url = GURL("https://example.test/resource");
  net::HttpStreamFactory::StreamRequestInfo stream(request);
  EXPECT_FALSE(request.access_proxy_route);
  EXPECT_FALSE(stream.access_proxy_route);
  EXPECT_FALSE(net::HttpStreamFactory::GetSpdySessionKey(
                   net::ProxyChain::Direct(), stream).access_route_key());
}

TEST(AccessRouteRequestContextTest, Http2KeysFollowInstalledRouteGeneration) {
  net::HttpRequestInfo request;
  request.url = GURL("https://example.test/resource");
  request.access_proxy_route = Route();
  ASSERT_TRUE(request.access_proxy_route);
  const auto chain = request.access_proxy_route->proxy_chain();
  const auto first = net::HttpStreamFactory::GetSpdySessionKey(
      chain, net::HttpStreamFactory::StreamRequestInfo(request));
  ASSERT_TRUE(first.access_route_key());
  EXPECT_EQ(*first.access_route_key(), request.access_proxy_route->isolation_key());
  const auto same = net::HttpStreamFactory::GetSpdySessionKey(
      chain, net::HttpStreamFactory::StreamRequestInfo(request));
  EXPECT_EQ(first, same);
  request.access_proxy_route = Route(2);
  const auto next = net::HttpStreamFactory::GetSpdySessionKey(
      chain, net::HttpStreamFactory::StreamRequestInfo(request));
  EXPECT_NE(first, next);
  EXPECT_FALSE(first.CompareForAliasing(next).is_potentially_aliasable);
  request.access_proxy_route = nullptr;
  const auto native = net::HttpStreamFactory::GetSpdySessionKey(
      chain, net::HttpStreamFactory::StreamRequestInfo(request));
  EXPECT_NE(first, native);
  EXPECT_FALSE(first.CompareForAliasing(native).is_potentially_aliasable);
}

}  // namespace
}  // namespace aegis_access
