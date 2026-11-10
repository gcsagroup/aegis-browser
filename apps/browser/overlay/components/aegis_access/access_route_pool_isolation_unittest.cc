// Copyright 2026 GCSA

#include <optional>
#include <set>
#include <utility>

#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "net/base/access_route_isolation_key.h"
#include "net/base/host_port_pair.h"
#include "net/base/ip_address.h"
#include "net/base/ip_endpoint.h"
#include "net/base/net_errors.h"
#include "net/base/network_anonymization_key.h"
#include "net/base/network_change_notifier.h"
#include "net/base/privacy_mode.h"
#include "net/base/proxy_chain.h"
#include "net/base/session_usage.h"
#include "net/http/access_proxy_route.h"
#include "net/http/http_network_session.h"
#include "net/http/http_transaction_factory.h"
#include "net/log/net_log_source.h"
#include "net/log/net_log_with_source.h"
#include "net/socket/client_socket_handle.h"
#include "net/socket/client_socket_pool.h"
#include "net/socket/client_socket_pool_manager.h"
#include "net/proxy_resolution/proxy_info.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "net/socket/socket_tag.h"
#include "net/socket/stream_socket.h"
#include "net/socket/tcp_server_socket.h"
#include "net/spdy/spdy_session_key.h"
#include "net/url_request/url_request_context.h"
#include "net/url_request/url_request_context_builder.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/scheme_host_port.h"

namespace aegis_access {
namespace {

net::AccessRouteIsolationKey Key() {
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

net::ClientSocketPool::GroupId SocketKey(
    std::optional<net::AccessRouteIsolationKey> access = std::nullopt) {
  return {url::SchemeHostPort("https", "cdn.example", 443),
          net::PRIVACY_MODE_DISABLED, net::NetworkAnonymizationKey(),
          net::SecureDnsPolicy::kAllow, false,
          net::handles::kInvalidNetworkHandle, std::move(access)};
}

net::SpdySessionKey SpdyKey(
    std::optional<net::AccessRouteIsolationKey> access = std::nullopt,
    const char* host = "cdn.example") {
  return {net::HostPortPair(host, 443), net::PRIVACY_MODE_DISABLED,
          net::ProxyChain::Direct(), net::SessionUsage::kDestination,
          net::SocketTag(), net::NetworkAnonymizationKey(),
          net::SecureDnsPolicy::kAllow, false,
          net::handles::kInvalidNetworkHandle, std::move(access)};
}

TEST(AccessRoutePoolIsolationTest, NativeAndEqualRouteKeepTheirPoolIdentity) {
  EXPECT_EQ(SocketKey(), SocketKey());
  EXPECT_EQ(SocketKey(Key()), SocketKey(Key()));
  EXPECT_NE(SocketKey(), SocketKey(Key()));
  EXPECT_EQ(SpdyKey(), SpdyKey());
  EXPECT_EQ(SpdyKey(Key()), SpdyKey(Key()));
  EXPECT_NE(SpdyKey(), SpdyKey(Key()));
}

TEST(AccessRoutePoolIsolationTest, AllIdentityChangesSeparateBothPools) {
  const auto key = Key();
  std::set<net::ClientSocketPool::GroupId> sockets{SocketKey(), SocketKey(key)};
  std::set<net::SpdySessionKey> sessions{SpdyKey(), SpdyKey(key)};
  const auto verify = [&](const net::AccessRouteIsolationKey& changed) {
    EXPECT_NE(SocketKey(key), SocketKey(changed));
    EXPECT_TRUE(sockets.insert(SocketKey(changed)).second);
    EXPECT_NE(SpdyKey(key), SpdyKey(changed));
    EXPECT_TRUE(sessions.insert(SpdyKey(changed)).second);
    EXPECT_FALSE(SpdyKey(key).CompareForAliasing(SpdyKey(changed))
                     .is_potentially_aliasable);
  };
  auto changed = key;
  changed.channel = 1;
  verify(changed);
  for (auto member : {&net::AccessRouteIsolationKey::profile,
                      &net::AccessRouteIsolationKey::partition,
                      &net::AccessRouteIsolationKey::group,
                      &net::AccessRouteIsolationKey::registration,
                      &net::AccessRouteIsolationKey::incarnation}) {
    changed = key;
    changed.*member += "-new";
    verify(changed);
  }
  for (auto member : {&net::AccessRouteIsolationKey::policy_generation,
                      &net::AccessRouteIsolationKey::identity_generation,
                      &net::AccessRouteIsolationKey::selection_generation,
                      &net::AccessRouteIsolationKey::network_epoch,
                      &net::AccessRouteIsolationKey::base_proxy_config_generation}) {
    changed = key;
    ++(changed.*member);
    verify(changed);
  }
  EXPECT_EQ(sockets.size(), 13u);
  EXPECT_EQ(sessions.size(), 13u);
}

TEST(AccessRoutePoolIsolationTest, CoalescingCannotCrossRouteIdentity) {
  const auto key = Key();
  EXPECT_TRUE(SpdyKey(key).CompareForAliasing(SpdyKey(key, "other.example"))
                  .is_potentially_aliasable);
  EXPECT_FALSE(SpdyKey(key).CompareForAliasing(SpdyKey())
                   .is_potentially_aliasable);
  EXPECT_FALSE(SpdyKey().CompareForAliasing(SpdyKey(key))
                   .is_potentially_aliasable);
  auto changed = key;
  changed.registration = "same-listener-new-registration";
  EXPECT_FALSE(SpdyKey(key).CompareForAliasing(SpdyKey(changed, "other.example"))
                   .is_potentially_aliasable);
}

TEST(AccessRoutePoolIsolationTest, LiveTcpPoolReusesOnlyTheSameRoute) {
  base::test::TaskEnvironment tasks(
      base::test::TaskEnvironment::MainThreadType::IO);
  auto notifier = net::NetworkChangeNotifier::CreateMockIfNeeded();
  auto context = net::URLRequestContextBuilder().Build();
  auto* pool = context->http_transaction_factory()->GetSession()->GetSocketPool(
      net::HttpNetworkSession::SocketPoolType::kNormal,
      net::ProxyChain::Direct());
  ASSERT_TRUE(pool);
  net::TCPServerSocket listener(nullptr, net::NetLogSource());
  ASSERT_EQ(listener.Listen(net::IPEndPoint(net::IPAddress::IPv4Localhost(), 0),
                            8, std::nullopt), net::OK);
  net::IPEndPoint bound;
  ASSERT_EQ(listener.GetLocalAddress(&bound), net::OK);

  const auto acquire = [&](std::optional<net::AccessRouteIsolationKey> route)
      -> std::optional<uint32_t> {
    net::ClientSocketPool::GroupId group(
        url::SchemeHostPort("http", "127.0.0.1", bound.port()),
        net::PRIVACY_MODE_DISABLED, net::NetworkAnonymizationKey(),
        net::SecureDnsPolicy::kAllow, false,
        net::handles::kInvalidNetworkHandle, std::move(route));
    net::ClientSocketHandle handle;
    base::test::TestFuture<int> completion;
    int result = handle.Init(
        group, net::ClientSocketPool::SocketParams::CreateForHttpForTesting(),
        std::nullopt, net::DEFAULT_PRIORITY, net::SocketTag(),
        net::ClientSocketPool::RespectLimits::ENABLED, completion.GetCallback(),
        {}, pool, net::NetLogWithSource());
    if (result == net::ERR_IO_PENDING) {
      result = completion.Get();
    }
    EXPECT_EQ(result, net::OK);
    if (result != net::OK || !handle.socket()) {
      return std::nullopt;
    }
    const uint32_t identity = handle.socket()->NetLog().source().id;
    handle.Reset();
    tasks.RunUntilIdle();
    return identity;
  };

  const auto key = Key();
  const auto first = acquire(key);
  ASSERT_TRUE(first);
  EXPECT_NE(*first, 0u);
  EXPECT_EQ(first, acquire(key));
  auto changed = key;
  changed.registration = "same-address-new-registration";
  const auto replacement = acquire(changed);
  ASSERT_TRUE(replacement);
  EXPECT_NE(first, replacement);
  changed = key;
  ++changed.network_epoch;
  const auto next_network = acquire(changed);
  ASSERT_TRUE(next_network);
  EXPECT_NE(first, next_network);
  EXPECT_NE(replacement, next_network);
  const auto native = acquire(std::nullopt);
  ASSERT_TRUE(native);
  EXPECT_NE(first, native);
  EXPECT_NE(replacement, native);
  EXPECT_NE(next_network, native);
  EXPECT_EQ(native, acquire(std::nullopt));
  EXPECT_EQ(first, acquire(key));
}

TEST(AccessRoutePoolIsolationTest, ManagedHttpPoolDispatchKeepsRouteIsolation) {
  base::test::TaskEnvironment tasks(
      base::test::TaskEnvironment::MainThreadType::IO);
  auto notifier = net::NetworkChangeNotifier::CreateMockIfNeeded();
  auto context = net::URLRequestContextBuilder().Build();
  auto* session = context->http_transaction_factory()->GetSession();
  net::TCPServerSocket listener(nullptr, net::NetLogSource());
  ASSERT_EQ(listener.Listen(net::IPEndPoint(net::IPAddress::IPv4Localhost(), 0),
                            8, std::nullopt), net::OK);
  net::IPEndPoint bound;
  ASSERT_EQ(listener.GetLocalAddress(&bound), net::OK);
  const auto chain = net::ProxyChain::FromSchemeHostAndPort(
      net::ProxyServer::SCHEME_HTTP, "127.0.0.1", bound.port());
  net::ProxyInfo proxy;
  proxy.UseProxyChain(chain);
  proxy.set_traffic_annotation(
      net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS));
  auto route = net::AccessProxyRoute::Create(Key(), chain);
  ASSERT_TRUE(route);

  const auto acquire = [&](scoped_refptr<net::AccessProxyRoute> selected)
      -> std::optional<uint32_t> {
    net::ClientSocketHandle handle;
    base::test::TestFuture<int> completion;
    int result = net::InitSocketHandleForHttpRequest(
        url::SchemeHostPort("http", "destination.invalid", 80), 0,
        net::DEFAULT_PRIORITY, session, proxy, {}, net::PRIVACY_MODE_DISABLED,
        net::NetworkAnonymizationKey(), net::SecureDnsPolicy::kAllow,
        net::SocketTag(), net::handles::kInvalidNetworkHandle,
        net::NetLogWithSource(), &handle, completion.GetCallback(), {}, selected);
    if (result == net::ERR_IO_PENDING) {
      result = completion.Get();
    }
    EXPECT_EQ(result, net::OK);
    if (result != net::OK || !handle.socket()) {
      return std::nullopt;
    }
    const uint32_t identity = handle.socket()->NetLog().source().id;
    handle.Reset();
    tasks.RunUntilIdle();
    return identity;
  };
  const auto first = acquire(route);
  ASSERT_TRUE(first);
  EXPECT_EQ(first, acquire(route));
  auto changed = Key();
  ++changed.selection_generation;
  auto replacement = net::AccessProxyRoute::Create(changed, chain);
  const auto next = acquire(replacement);
  ASSERT_TRUE(next);
  EXPECT_NE(first, next);
  const auto native = acquire(nullptr);
  ASSERT_TRUE(native);
  EXPECT_NE(first, native);
  EXPECT_NE(next, native);
  EXPECT_EQ(native, acquire(nullptr));
  EXPECT_EQ(first, acquire(route));

  // Reject a mismatched credential context before an existing socket can be
  // reused, even if a caller bypasses the HTTP manager's key construction.
  net::ClientSocketPool::GroupId original_group(
      url::SchemeHostPort("http", "destination.invalid", 80),
      net::PRIVACY_MODE_DISABLED, net::NetworkAnonymizationKey(),
      net::SecureDnsPolicy::kAllow, false,
      net::handles::kInvalidNetworkHandle, Key());
  auto wrong_params = base::MakeRefCounted<net::ClientSocketPool::SocketParams>(
      std::vector<net::SSLConfig::CertAndStatus>(), replacement);
  net::ClientSocketHandle mismatched;
  base::test::TestFuture<int> wrong_completion;
  EXPECT_EQ(mismatched.Init(
                original_group, wrong_params, TRAFFIC_ANNOTATION_FOR_TESTS,
                net::DEFAULT_PRIORITY, net::SocketTag(),
                net::ClientSocketPool::RespectLimits::ENABLED,
                wrong_completion.GetCallback(), {},
                session->GetSocketPool(
                    net::HttpNetworkSession::SocketPoolType::kNormal, chain),
                net::NetLogWithSource()),
            net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_FALSE(mismatched.socket());
  EXPECT_FALSE(wrong_completion.IsReady());
  EXPECT_EQ(first, acquire(route));

  // A managed request cannot be redirected into a native/direct socket pool.
  net::ProxyInfo direct;
  direct.UseDirect();
  net::ClientSocketHandle blocked;
  base::test::TestFuture<int> completion;
  EXPECT_EQ(net::InitSocketHandleForHttpRequest(
                url::SchemeHostPort("http", "destination.invalid", 80), 0,
                net::DEFAULT_PRIORITY, session, direct, {},
                net::PRIVACY_MODE_DISABLED, net::NetworkAnonymizationKey(),
                net::SecureDnsPolicy::kAllow, net::SocketTag(),
                net::handles::kInvalidNetworkHandle, net::NetLogWithSource(),
                &blocked, completion.GetCallback(), {}, route),
            net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_FALSE(blocked.socket());
  EXPECT_FALSE(completion.IsReady());
}

}  // namespace
}  // namespace aegis_access
