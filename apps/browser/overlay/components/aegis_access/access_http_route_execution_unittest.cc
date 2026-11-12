// Copyright 2026 GCSA

#include <atomic>
#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/test/task_environment.h"
#include "net/base/host_port_pair.h"
#include "net/base/isolation_info.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/base/network_change_notifier.h"
#include "net/base/test_completion_callback.h"
#include "net/http/access_proxy_route.h"
#include "net/http/http_network_transaction.h"
#include "net/http/http_response_info.h"
#include "net/http/http_server_properties.h"
#include "net/http/http_status_code.h"
#include "net/http/http_transaction_factory.h"
#include "net/http/http_transaction_test_util.h"
#include "net/http/transport_security_state.h"
#include "net/proxy_resolution/configured_proxy_resolution_service.h"
#include "net/ssl/ssl_info.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_request.h"
#include "net/test/embedded_test_server/http_response.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "net/url_request/url_request.h"
#include "net/url_request/url_request_context.h"
#include "net/url_request/url_request_context_builder.h"
#include "net/url_request/url_request_test_util.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/origin.h"
#include "url/scheme_host_port.h"

namespace aegis_access {
namespace {

class AccessHttpRouteExecutionTest : public testing::Test {
 protected:
  AccessHttpRouteExecutionTest()
      : tasks_(base::test::TaskEnvironment::MainThreadType::IO),
        notifier_(net::NetworkChangeNotifier::CreateMockIfNeeded()) {}

  void ConfigureServer(net::EmbeddedTestServer& server,
                       std::atomic<int>& hits,
                       const std::string& body) {
    server.RegisterRequestHandler(base::BindRepeating(
        [](std::atomic<int>* hits, std::string body,
           const net::test_server::HttpRequest& request)
            -> std::unique_ptr<net::test_server::HttpResponse> {
          ++*hits;
          auto response = std::make_unique<net::test_server::BasicHttpResponse>();
          response->set_code(net::HTTP_OK);
          response->set_content(body);
          response->AddCustomHeader("Cache-Control", "public, max-age=600");
          response->set_content_type("text/plain");
          return response;
        }, &hits, body));
  }

  scoped_refptr<net::AccessProxyRoute> Route(net::EmbeddedTestServer& proxy,
                                            const std::string& group = "g") {
    return net::AccessProxyRoute::Create(
        {.channel = 0, .profile = "p", .partition = "s", .group = group,
         .registration = "r-" + group, .incarnation = "i",
         .policy_generation = 1, .identity_generation = 1,
         .selection_generation = 1, .network_epoch = 1,
         .base_proxy_config_generation = 1},
        net::ProxyChain::FromSchemeHostAndPort(
            net::ProxyServer::SCHEME_HTTP, "127.0.0.1", proxy.port()));
  }

  std::unique_ptr<net::URLRequestContext> Context(
      std::unique_ptr<net::ProxyResolutionService> proxy =
          net::ConfiguredProxyResolutionService::CreateDirect()) {
    net::URLRequestContextBuilder builder;
    builder.set_proxy_resolution_service(std::move(proxy));
    return builder.Build();
  }

  net::HttpRequestInfo Request(const GURL& url,
                              scoped_refptr<net::AccessProxyRoute> route) {
    net::HttpRequestInfo request;
    request.url = url;
    request.method = "GET";
    request.traffic_annotation =
        net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS);
    request.access_proxy_route = std::move(route);
    return request;
  }

  int Execute(net::URLRequestContext& context, net::HttpRequestInfo& request,
              std::string* body) {
    net::HttpNetworkTransaction transaction(
        net::DEFAULT_PRIORITY, context.http_transaction_factory()->GetSession());
    net::TestCompletionCallback complete;
    int result = complete.GetResult(transaction.Start(
        &request, complete.callback(), net::NetLogWithSource()));
    if (result != net::OK) {
      return result;
    }
    return net::ReadTransaction(&transaction, body);
  }

  int ExecuteURLRequest(net::URLRequestContext& context, const GURL& url,
                        scoped_refptr<net::AccessProxyRoute> route,
                        std::string* body, int flags = 0) {
    net::TestDelegate delegate;
    auto request = context.CreateRequest(url, net::DEFAULT_PRIORITY, &delegate,
                                         TRAFFIC_ANNOTATION_FOR_TESTS,
                                         net::handles::kInvalidNetworkHandle);
    request->set_isolation_info(net::IsolationInfo::CreateForInternalRequest(
        url::Origin::Create(url)));
    request->SetLoadFlags(flags);
    request->SetAccessProxyRoute(std::move(route));
    request->Start();
    delegate.RunUntilComplete();
    *body = delegate.data_received();
    return delegate.request_status();
  }

  base::test::TaskEnvironment tasks_;
  std::unique_ptr<net::NetworkChangeNotifier> notifier_;
};

TEST_F(AccessHttpRouteExecutionTest, ManagedRouteWinsEvenWithBypassFlag) {
  std::atomic<int> hits{0};
  net::EmbeddedTestServer proxy;
  ConfigureServer(proxy, hits, "managed");
  ASSERT_TRUE(proxy.Start());
  auto context = Context();
  auto request = Request(GURL("http://destination.invalid/path"), Route(proxy));
  request.load_flags = net::LOAD_BYPASS_PROXY;
  std::string body;
  EXPECT_EQ(Execute(*context, request, &body), net::OK);
  EXPECT_EQ(body, "managed");
  EXPECT_EQ(hits.load(), 1);
}

TEST_F(AccessHttpRouteExecutionTest, NativeProxyConfigurationRemainsUnchanged) {
  std::atomic<int> hits{0};
  net::EmbeddedTestServer proxy;
  ConfigureServer(proxy, hits, "native");
  ASSERT_TRUE(proxy.Start());
  auto context = Context(
      net::ConfiguredProxyResolutionService::CreateFixedFromPacResultForTest(
          "PROXY " + proxy.host_port_pair().ToString(),
          TRAFFIC_ANNOTATION_FOR_TESTS));
  auto request = Request(GURL("http://destination.invalid/path"), nullptr);
  std::string body;
  EXPECT_EQ(Execute(*context, request, &body), net::OK);
  EXPECT_EQ(body, "native");
  EXPECT_EQ(hits.load(), 1);
}

TEST_F(AccessHttpRouteExecutionTest, ManagedHttpsKeepsHstsAndIsolatesAltSvc) {
  constexpr char kHost[] = "secure-route.test";
  net::EmbeddedTestServer origin(net::EmbeddedTestServer::TYPE_HTTPS);
  origin.SetCertHostnames({kHost});
  origin.RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest&)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_content("secure response");
        response->AddCustomHeader("Strict-Transport-Security", "max-age=3600");
        response->AddCustomHeader("Alt-Svc", "h2=\":443\"");
        return response;
      }));
  ASSERT_TRUE(origin.Start());
  const GURL url = origin.GetURL(kHost, "/policy");
  net::EmbeddedTestServer proxy;
  proxy.EnableConnectProxy({net::HostPortPair::FromURL(url)});
  ASSERT_TRUE(proxy.Start());

  // Both requests use the same local TLS server and CONNECT proxy. Only the
  // explicitly managed request must suppress the native Alt-Svc update.
  for (bool managed : {false, true}) {
    SCOPED_TRACE(managed ? "managed" : "native");
    auto context = Context(
        net::ConfiguredProxyResolutionService::CreateFixedFromPacResultForTest(
            "PROXY " + proxy.host_port_pair().ToString(),
            TRAFFIC_ANNOTATION_FOR_TESTS));
    net::TransportSecurityState::STSState sts;
    EXPECT_FALSE(
        context->transport_security_state()->GetDynamicSTSState(kHost, &sts));
    net::TestDelegate delegate;
    auto request = context->CreateRequest(url, net::DEFAULT_PRIORITY, &delegate,
                                          TRAFFIC_ANNOTATION_FOR_TESTS,
                                          net::handles::kInvalidNetworkHandle);
    request->set_isolation_info(net::IsolationInfo::CreateForInternalRequest(
        url::Origin::Create(url)));
    if (managed) {
      auto route = Route(proxy);
      ASSERT_TRUE(route);
      request->SetAccessProxyRoute(std::move(route));
    }
    request->Start();
    delegate.RunUntilComplete();
    ASSERT_EQ(delegate.request_status(), net::OK);
    ASSERT_EQ(delegate.data_received(), "secure response");
    EXPECT_TRUE(request->ssl_info().is_valid());
    EXPECT_TRUE(
        context->transport_security_state()->GetDynamicSTSState(kHost, &sts));
    EXPECT_EQ(context->http_server_properties()
                  ->GetAlternativeServiceInfos(
                      url::SchemeHostPort(url),
                      request->isolation_info().network_anonymization_key())
                  .empty(),
              managed);
  }
}

TEST_F(AccessHttpRouteExecutionTest, FailedManagedRouteNeverFallsBackToOrigin) {
  std::atomic<int> origin_hits{0};
  net::EmbeddedTestServer origin;
  ConfigureServer(origin, origin_hits, "must-not-send");
  ASSERT_TRUE(origin.Start());
  std::atomic<int> proxy_hits{0};
  net::EmbeddedTestServer proxy;
  ConfigureServer(proxy, proxy_hits, "unused");
  ASSERT_TRUE(proxy.Start());
  auto route = Route(proxy);
  ASSERT_TRUE(route);
  ASSERT_TRUE(proxy.ShutdownAndWaitUntilComplete());
  auto context = Context();
  auto request = Request(origin.GetURL("/private"), route);
  std::string body;
  EXPECT_NE(Execute(*context, request, &body), net::OK);
  EXPECT_TRUE(body.empty());
  EXPECT_EQ(origin_hits.load(), 0);
  EXPECT_TRUE(context->proxy_resolution_service()->proxy_retry_info().empty());
}

TEST_F(AccessHttpRouteExecutionTest, ConcurrentSameUrlUsesEachRegisteredProxy) {
  std::atomic<int> hits_a{0}, hits_b{0};
  net::EmbeddedTestServer proxy_a, proxy_b;
  ConfigureServer(proxy_a, hits_a, "a");
  ConfigureServer(proxy_b, hits_b, "b");
  ASSERT_TRUE(proxy_a.Start());
  ASSERT_TRUE(proxy_b.Start());
  auto context = Context();
  auto request_a = Request(GURL("http://destination.invalid/shared"),
                           Route(proxy_a, "a"));
  auto request_b = Request(request_a.url, Route(proxy_b, "b"));
  auto* session = context->http_transaction_factory()->GetSession();
  net::HttpNetworkTransaction transaction_a(net::DEFAULT_PRIORITY, session);
  net::HttpNetworkTransaction transaction_b(net::DEFAULT_PRIORITY, session);
  net::TestCompletionCallback complete_a, complete_b;
  const int started_a = transaction_a.Start(
      &request_a, complete_a.callback(), net::NetLogWithSource());
  const int started_b = transaction_b.Start(
      &request_b, complete_b.callback(), net::NetLogWithSource());
  ASSERT_EQ(complete_a.GetResult(started_a), net::OK);
  ASSERT_EQ(complete_b.GetResult(started_b), net::OK);
  std::string body_a, body_b;
  EXPECT_EQ(net::ReadTransaction(&transaction_a, &body_a), net::OK);
  EXPECT_EQ(net::ReadTransaction(&transaction_b, &body_b), net::OK);
  EXPECT_EQ(body_a, "a");
  EXPECT_EQ(body_b, "b");
  EXPECT_EQ(hits_a.load(), 1);
  EXPECT_EQ(hits_b.load(), 1);
}

TEST_F(AccessHttpRouteExecutionTest, URLRequestBypassesNativeCacheForManagedRoute) {
  std::atomic<int> native_hits{0}, proxy_hits{0};
  net::EmbeddedTestServer origin, proxy;
  ConfigureServer(origin, native_hits, "native-cache");
  ConfigureServer(proxy, proxy_hits, "managed-network");
  ASSERT_TRUE(origin.Start());
  ASSERT_TRUE(proxy.Start());
  auto context = Context();
  const auto url = origin.GetURL("/cached");
  std::string body;
  ASSERT_EQ(ExecuteURLRequest(*context, url, nullptr, &body), net::OK);
  EXPECT_EQ(body, "native-cache");
  ASSERT_EQ(ExecuteURLRequest(*context, url, nullptr, &body), net::OK);
  EXPECT_EQ(native_hits.load(), 1);
  ASSERT_EQ(ExecuteURLRequest(*context, url, Route(proxy), &body), net::OK);
  EXPECT_EQ(body, "managed-network");
  EXPECT_EQ(proxy_hits.load(), 1);
  ASSERT_EQ(ExecuteURLRequest(*context, url, nullptr, &body), net::OK);
  EXPECT_EQ(body, "native-cache");
  EXPECT_EQ(native_hits.load(), 1);
}

TEST_F(AccessHttpRouteExecutionTest, ManagedCacheOnlyDoesNotSendNetworkRequest) {
  std::atomic<int> hits{0};
  net::EmbeddedTestServer proxy;
  ConfigureServer(proxy, hits, "must-not-send");
  ASSERT_TRUE(proxy.Start());
  auto context = Context();
  std::string body;
  EXPECT_EQ(ExecuteURLRequest(*context, GURL("http://destination.invalid/cache"),
                             Route(proxy), &body, net::LOAD_ONLY_FROM_CACHE),
            net::ERR_CACHE_MISS);
  EXPECT_TRUE(body.empty());
  EXPECT_EQ(hits.load(), 0);
}

class RouteOnRedirectDelegate : public net::TestDelegate {
 public:
  explicit RouteOnRedirectDelegate(scoped_refptr<net::AccessProxyRoute> route)
      : route_(std::move(route)) {}
  void OnReceivedRedirect(net::URLRequest* request,
                          const net::RedirectInfo& redirect,
                          bool* defer) override {
    request->SetAccessProxyRoute(route_);
    net::TestDelegate::OnReceivedRedirect(request, redirect, defer);
  }
 private:
  scoped_refptr<net::AccessProxyRoute> route_;
};

TEST_F(AccessHttpRouteExecutionTest, NativeRedirectCanAcquireManagedRoute) {
  std::atomic<int> proxy_hits{0};
  net::EmbeddedTestServer origin, proxy;
  ConfigureServer(proxy, proxy_hits, "redirect-managed");
  origin.RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_FOUND);
        response->AddCustomHeader("Location", "http://destination.invalid/next");
        return response;
      }));
  ASSERT_TRUE(origin.Start());
  ASSERT_TRUE(proxy.Start());
  auto context = Context();
  RouteOnRedirectDelegate delegate(Route(proxy));
  auto request = context->CreateRequest(origin.GetURL("/start"),
      net::DEFAULT_PRIORITY, &delegate, TRAFFIC_ANNOTATION_FOR_TESTS,
      net::handles::kInvalidNetworkHandle);
  request->Start();
  delegate.RunUntilComplete();
  EXPECT_EQ(delegate.request_status(), net::OK);
  EXPECT_EQ(delegate.received_redirect_count(), 1);
  EXPECT_EQ(delegate.data_received(), "redirect-managed");
  EXPECT_EQ(proxy_hits.load(), 1);
}

TEST_F(AccessHttpRouteExecutionTest, ManagedRedirectRequiresNewTrustedDecision) {
  std::atomic<int> origin_hits{0}, proxy_hits{0};
  net::EmbeddedTestServer origin, proxy;
  ConfigureServer(origin, origin_hits, "must-not-send");
  ASSERT_TRUE(origin.Start());
  proxy.RegisterRequestHandler(base::BindRepeating(
      [](std::atomic<int>* hits, GURL target,
         const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        ++*hits;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_FOUND);
        response->AddCustomHeader("Location", target.spec());
        return response;
      }, &proxy_hits, origin.GetURL("/private")));
  ASSERT_TRUE(proxy.Start());
  auto context = Context();
  std::string body;
  EXPECT_EQ(ExecuteURLRequest(*context, GURL("http://destination.invalid/start"),
                             Route(proxy), &body), net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(proxy_hits.load(), 1);
  EXPECT_EQ(origin_hits.load(), 0);
}

}  // namespace
}  // namespace aegis_access
