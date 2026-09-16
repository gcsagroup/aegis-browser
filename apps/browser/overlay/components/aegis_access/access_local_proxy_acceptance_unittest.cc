// Copyright 2026 GCSA

#include "components/aegis_access/access_proxy_route_adapter.h"

#include <atomic>
#include <memory>
#include <string>
#include <string_view>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/notreached.h"
#include "base/test/task_environment.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/isolation_info.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/dns/host_resolver.h"
#include "net/dns/mock_host_resolver.h"
#include "net/http/http_status_code.h"
#include "net/proxy_resolution/proxy_config.h"
#include "net/proxy_resolution/proxy_info.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_request.h"
#include "net/test/embedded_test_server/http_response.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "services/network/network_context.h"
#include "services/network/network_service.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "services/network/public/mojom/url_loader.mojom.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"
#include "services/network/test/fake_test_cert_verifier_params_factory.h"
#include "services/network/test/test_url_loader_client.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/origin.h"

namespace aegis_access {
namespace {

constexpr char kTargetHost[] = "target.example";
constexpr char kOtherHost[] = "other.example";
constexpr char kLoopbackAddress[] = "127.0.0.1";

class HostResolverFactory final : public net::HostResolver::Factory {
 public:
  explicit HostResolverFactory(std::unique_ptr<net::HostResolver> resolver)
      : resolver_(std::move(resolver)) {}

  HostResolverFactory(const HostResolverFactory&) = delete;
  HostResolverFactory& operator=(const HostResolverFactory&) = delete;
  ~HostResolverFactory() override = default;

  std::unique_ptr<net::HostResolver> CreateResolver(
      net::HostResolverManager* manager,
      std::string_view host_mapping_rules,
      bool enable_caching,
      bool enable_stale) override {
    CHECK(resolver_);
    return std::move(resolver_);
  }

  std::unique_ptr<net::HostResolver> CreateStandaloneResolver(
      net::NetLog* net_log,
      const net::HostResolver::ManagerOptions& options,
      std::string_view host_mapping_rules,
      bool enable_caching,
      bool enable_stale) override {
    NOTREACHED();
  }

 private:
  std::unique_ptr<net::HostResolver> resolver_;
};

std::unique_ptr<net::test_server::HttpResponse> HandleOriginRequest(
    std::atomic<size_t>* counter,
    const net::test_server::HttpRequest& request) {
  if (request.method != net::test_server::METHOD_GET) {
    return nullptr;
  }
  counter->fetch_add(1, std::memory_order_relaxed);
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_OK);
  response->set_content("origin");
  response->set_content_type("text/plain");
  return response;
}

std::unique_ptr<net::test_server::HttpResponse> HandleHttpProxyRequest(
    std::atomic<size_t>* counter,
    const net::test_server::HttpRequest& request) {
  if (request.method != net::test_server::METHOD_GET) {
    return nullptr;
  }
  counter->fetch_add(1, std::memory_order_relaxed);
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_OK);
  response->set_content("proxy");
  response->set_content_type("text/plain");
  return response;
}

void CountProxyRequest(std::atomic<size_t>* connect_counter,
                       const net::test_server::HttpRequest& request) {
  if (request.method == net::test_server::METHOD_CONNECT) {
    connect_counter->fetch_add(1, std::memory_order_relaxed);
  }
}

class AccessLocalProxyAcceptanceTest : public testing::Test {
 protected:
  AccessLocalProxyAcceptanceTest()
      : task_environment_(base::test::TaskEnvironment::MainThreadType::IO),
        http_origin_(net::test_server::EmbeddedTestServer::TYPE_HTTP),
        https_origin_(net::test_server::EmbeddedTestServer::TYPE_HTTPS),
        proxy_server_(net::test_server::EmbeddedTestServer::TYPE_HTTP) {}

  void SetUp() override {
    http_origin_.RegisterRequestHandler(base::BindRepeating(
        &HandleOriginRequest, base::Unretained(&http_origin_requests_)));
    https_origin_.RegisterRequestHandler(base::BindRepeating(
        &HandleOriginRequest, base::Unretained(&https_origin_requests_)));
    ASSERT_TRUE(http_origin_.Start());
    ASSERT_TRUE(https_origin_.Start());

    proxy_server_.RegisterRequestMonitor(
        base::BindRepeating(&CountProxyRequest,
                            base::Unretained(&proxy_connect_requests_)));
    proxy_server_.RegisterRequestHandler(base::BindRepeating(
        &HandleHttpProxyRequest, base::Unretained(&proxy_http_requests_)));
    const net::HostPortPair connect_destination = https_origin_.host_port_pair();
    proxy_server_.EnableConnectProxy({connect_destination});
    ASSERT_TRUE(proxy_server_.Start());

    auto resolver = std::make_unique<net::MockHostResolver>();
    resolver->rules()->AddRule(kTargetHost, kLoopbackAddress);
    resolver->rules()->AddRule(kOtherHost, kLoopbackAddress);
    resolver->set_synchronous_mode(true);
    network_service_ = network::NetworkService::CreateForTesting();
    network_service_->set_host_resolver_factory_for_testing(
        std::make_unique<HostResolverFactory>(std::move(resolver)));
  }

  void TearDown() override {
    url_loader_factory_.reset();
    network_context_.reset();
    network_context_remote_.reset();
    network_service_.reset();

    if (!proxy_stopped_ && proxy_server_.Started()) {
      EXPECT_TRUE(proxy_server_.ShutdownAndWaitUntilComplete());
    }
    if (https_origin_.Started()) {
      EXPECT_TRUE(https_origin_.ShutdownAndWaitUntilComplete());
    }
    if (http_origin_.Started()) {
      EXPECT_TRUE(http_origin_.ShutdownAndWaitUntilComplete());
    }
  }

  network::mojom::CustomProxyConfigPtr BuildSelectedProxyConfig() const {
    const OwnershipKey owner{ChannelNamespace::kDev, "acceptance-profile",
                             "acceptance-partition"};
    const GenerationTuple generations{1, 2, 3, 4, 5};
    const RegisteredProxyEndpoint endpoint{
        "acceptance-local", "acceptance-proxy-group", owner, generations,
        RegisteredProxyTransport::kHttp, kLoopbackAddress,
        static_cast<uint16_t>(proxy_server_.port())};

    RoutePlan plan;
    plan.action = RouteAction::kUseRegisteredProxy;
    plan.effective_mode = AccessMode::kProxy;
    plan.reason = RouteReason::kNone;
    plan.generations = generations;
    plan.registered_proxy_entry = RegisteredProxyEntry{
        endpoint.registration_id, endpoint.proxy_group_id, owner, generations};

    net::ProxyInfo proxy_info;
    proxy_info.UseDirect();
    CHECK(ApplyRoutePlanToProxyInfo(plan, &endpoint, &proxy_info) ==
          ProxyRouteApplyStatus::kAppliedProxy);
    CHECK(!proxy_info.is_empty());
    CHECK(!proxy_info.is_direct());

    auto config = network::mojom::CustomProxyConfig::New();
    config->rules.type =
        net::ProxyConfig::ProxyRules::Type::PROXY_LIST_PER_SCHEME;
    config->rules.proxies_for_http = proxy_info.proxy_list();
    config->rules.proxies_for_https = proxy_info.proxy_list();
    CHECK(config->rules.bypass_rules.AddRuleFromString(kTargetHost));
    config->rules.reverse_bypass = true;
    config->should_override_existing_config = true;
    config->allow_non_idempotent_methods = true;
    return config;
  }

  void CreateNetworkContext(const GURL& target_url, bool select_proxy) {
    network::mojom::NetworkContextParamsPtr context_params =
        network::mojom::NetworkContextParams::New();
    context_params->cert_verifier_params =
        network::FakeTestCertVerifierParamsFactory::GetCertVerifierParams();
    if (select_proxy) {
      context_params->initial_custom_proxy_config = BuildSelectedProxyConfig();
    }

    network_context_ = network::NetworkContext::CreateForTesting(
        network_service_.get(),
        network_context_remote_.BindNewPipeAndPassReceiver(),
        std::move(context_params),
        network::NetworkContext::OnURLRequestContextBuilderConfiguredCallback());
    ASSERT_TRUE(network_context_);

    network::mojom::URLLoaderFactoryParamsPtr factory_params =
        network::mojom::URLLoaderFactoryParams::New();
    factory_params->process_id = network::OriginatingProcessId::browser();
    factory_params->is_orb_enabled = false;
    factory_params->is_trusted = true;
    factory_params->isolation_info =
        net::IsolationInfo::CreateForInternalRequest(url::Origin::Create(target_url));
    network_context_->CreateURLLoaderFactory(
        url_loader_factory_.BindNewPipeAndPassReceiver(),
        std::move(factory_params));
  }

  int Fetch(const GURL& url) {
    network::ResourceRequest request;
    request.url = url;
    request.load_flags = net::LOAD_BYPASS_CACHE;

    network::TestURLLoaderClient client;
    mojo::Remote<network::mojom::URLLoader> loader;
    url_loader_factory_->CreateLoaderAndStart(
        loader.BindNewPipeAndPassReceiver(), 1, 0, request,
        client.CreateRemote(), net::MutableNetworkTrafficAnnotationTag(
                                   TRAFFIC_ANNOTATION_FOR_TESTS));
    client.RunUntilComplete();
    return client.completion_status().error_code;
  }

  void StopProxy() {
    ASSERT_FALSE(proxy_stopped_);
    ASSERT_TRUE(proxy_server_.ShutdownAndWaitUntilComplete());
    proxy_stopped_ = true;
  }

  base::test::TaskEnvironment task_environment_;
  std::atomic<size_t> http_origin_requests_{0};
  std::atomic<size_t> https_origin_requests_{0};
  std::atomic<size_t> proxy_http_requests_{0};
  std::atomic<size_t> proxy_connect_requests_{0};
  net::test_server::EmbeddedTestServer http_origin_;
  net::test_server::EmbeddedTestServer https_origin_;
  net::test_server::EmbeddedTestServer proxy_server_;
  bool proxy_stopped_ = false;

  std::unique_ptr<network::NetworkService> network_service_;
  mojo::Remote<network::mojom::NetworkContext> network_context_remote_;
  std::unique_ptr<network::NetworkContext> network_context_;
  mojo::Remote<network::mojom::URLLoaderFactory> url_loader_factory_;
};

TEST_F(AccessLocalProxyAcceptanceTest, OffHttpRequestUsesNativeDirectPath) {
  const GURL target = http_origin_.GetURL(kTargetHost, "/off");
  CreateNetworkContext(target, false);

  EXPECT_EQ(net::OK, Fetch(target));
  EXPECT_EQ(1u, http_origin_requests_.load(std::memory_order_relaxed));
  EXPECT_EQ(0u, proxy_http_requests_.load(std::memory_order_relaxed));
  EXPECT_EQ(0u, proxy_connect_requests_.load(std::memory_order_relaxed));
}

TEST_F(AccessLocalProxyAcceptanceTest, SelectedHttpRequestReachesProxyFixture) {
  const GURL target = http_origin_.GetURL(kTargetHost, "/selected-http");
  CreateNetworkContext(target, true);

  EXPECT_EQ(net::OK, Fetch(target));
  EXPECT_EQ(1u, proxy_http_requests_.load(std::memory_order_relaxed));
  EXPECT_EQ(0u, proxy_connect_requests_.load(std::memory_order_relaxed));
  EXPECT_EQ(0u, http_origin_requests_.load(std::memory_order_relaxed));
}

TEST_F(AccessLocalProxyAcceptanceTest,
       NonSelectedHostPreservesNativeDirectPath) {
  const GURL target = http_origin_.GetURL(kOtherHost, "/not-selected");
  CreateNetworkContext(target, true);

  EXPECT_EQ(net::OK, Fetch(target));
  EXPECT_EQ(1u, http_origin_requests_.load(std::memory_order_relaxed));
  EXPECT_EQ(0u, proxy_http_requests_.load(std::memory_order_relaxed));
  EXPECT_EQ(0u, proxy_connect_requests_.load(std::memory_order_relaxed));
}

TEST_F(AccessLocalProxyAcceptanceTest,
       SelectedHttpsRequestTraversesConnectProxyToOrigin) {
  const GURL target =
      https_origin_.GetURL(kTargetHost, "/selected-https");
  CreateNetworkContext(target, true);

  EXPECT_EQ(net::OK, Fetch(target));
  EXPECT_GE(proxy_connect_requests_.load(std::memory_order_relaxed), 1u);
  EXPECT_EQ(0u, proxy_http_requests_.load(std::memory_order_relaxed));
  EXPECT_EQ(1u, https_origin_requests_.load(std::memory_order_relaxed));
}

TEST_F(AccessLocalProxyAcceptanceTest,
       UnavailableSelectedProxyFailsWithoutDirectFallback) {
  const GURL target = http_origin_.GetURL(kTargetHost, "/proxy-down");
  CreateNetworkContext(target, true);
  StopProxy();

  EXPECT_NE(net::OK, Fetch(target));
  EXPECT_EQ(0u, http_origin_requests_.load(std::memory_order_relaxed));
}

TEST_F(AccessLocalProxyAcceptanceTest,
       UnavailableSelectedProxyFailsHttpsWithoutDirectFallback) {
  const GURL target =
      https_origin_.GetURL(kTargetHost, "/https-proxy-down");
  CreateNetworkContext(target, true);
  StopProxy();

  EXPECT_NE(net::OK, Fetch(target));
  EXPECT_EQ(0u, https_origin_requests_.load(std::memory_order_relaxed));
}

}  // namespace
}  // namespace aegis_access
