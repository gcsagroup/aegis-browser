// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_proxying_url_loader_factory.h"

#include <atomic>
#include <cstdint>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/base64.h"
#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/run_loop.h"
#include "base/test/run_until.h"
#include "base/test/scoped_feature_list.h"
#include "base/test/test_future.h"
#include "build/chromeos_buildflags.h"
#include "chrome/browser/aegis/access/access_browser_request_adapter.h"
#include "chrome/browser/aegis/access/access_identity_generation_source.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/access/access_proxy_selection_generation_source.h"
#include "chrome/browser/aegis/access/access_published_request_runtime.h"
#include "chrome/browser/aegis/access/access_request_dispatch_state.h"
#include "chrome/browser/aegis/access/access_service_coordinator.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/net/profile_network_context_service.h"
#include "chrome/browser/net/profile_network_context_service_factory.h"
#include "chrome/browser/predictors/predictors_features.h"
#include "chrome/browser/predictors/predictors_switches.h"
#include "chrome/browser/predictors/prefetch_manager.h"
#include "chrome/browser/predictors/resource_prefetch_predictor.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_test_util.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/aegis_access/access_identity_generation_state.h"
#include "components/aegis_access/access_proxy_selection_generation_state.h"
#include "components/aegis_access/request_policy_context.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/storage_partition_config.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/content_features.h"
#include "content/public/test/back_forward_cache_util.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/dns/mock_host_resolver.h"
#include "net/http/http_status_code.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_request.h"
#include "net/test/embedded_test_server/http_response.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "services/network/test/test_url_loader_factory.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::access {

class AccessRuleStoreTestPeer {
 public:
  static StoreStatus Import(AccessRuleStore* store, StoredAccessRule rule) {
    return store->ImportIndependentRuleForTesting(std::move(rule));
  }

  static AccessStoreBinding Ephemeral(const OwnershipKey& owner) {
    return AccessStoreBinding(AccessStoreKind::kEphemeralProfile, owner.channel,
                              "prepared-browser-test", owner.profile_token, {}, {});
  }
};

namespace {

constexpr char kTargetHost[] = "target.example";
constexpr char kTrailingDotTargetHost[] = "target.example.";
constexpr char kUnselectedRedirectHost[] = "redirect-unselected.example";
constexpr char kProxyGroup[] = "proxy-group-browser-test";

SiteGroupMutationRequest PreparedNavigationRequest(const OwnershipKey& owner) {
  SiteGroupMutationRequest request;
  request.operation_id = "prepared-navigation";
  request.request_fingerprint = "prepared-navigation-fingerprint";
  request.candidate_group = {
      .site_toggle_id = "navigation-toggle",
      .canonical_host = kTargetHost,
      .owner = owner,
      .http_top_level_site = "http://target.example",
      .https_top_level_site = "https://target.example",
      .member_rule_ids = {"navigation:http", "navigation:https"},
  };
  for (const auto& scheme : {std::string("http"), std::string("https")}) {
    request.candidate_members.push_back({
        .rule_id = "navigation:" + scheme,
        .owner = owner,
        .site_toggle_id = "navigation-toggle",
        .top_level_site = scheme + "://target.example",
        .exact_host = kTargetHost,
        .schemes = {RequestScheme::kHttp, RequestScheme::kHttps,
                    RequestScheme::kWs, RequestScheme::kWss},
        .ports = PortScope::kAllBrowserPermitted,
        .mode = AccessMode::kProxy,
        .proxy_group_id = kProxyGroup,
        .protection_override = ProtectionOverride::kNone,
    });
  }
  return request;
}

enum class ServiceWorkerRequestKind {
  kOther,
  kMainScript,
  kImportedScript,
  kData,
};

ServiceWorkerRequestKind ClassifyServiceWorkerRequest(
    const net::test_server::HttpRequest& request) {
  if (request.relative_url.find("/aegis-service-worker.js") !=
      std::string::npos) {
    return ServiceWorkerRequestKind::kMainScript;
  }
  if (request.relative_url.find("/aegis-service-worker-imported.js") !=
      std::string::npos) {
    return ServiceWorkerRequestKind::kImportedScript;
  }
  if (request.relative_url.find("/service-worker-data") != std::string::npos) {
    return ServiceWorkerRequestKind::kData;
  }
  return ServiceWorkerRequestKind::kOther;
}

void ConfigureServiceWorkerMainScriptResponse(
    net::test_server::BasicHttpResponse* response) {
  response->set_code(net::HTTP_OK);
  response->set_content(
      "importScripts('/aegis-service-worker-imported.js');"
      "self.addEventListener('install', event => "
      "  event.waitUntil(self.skipWaiting()));"
      "self.addEventListener('activate', event => "
      "  event.waitUntil(self.clients.claim()));"
      "self.addEventListener('message', event => {"
      "  const port = event.ports[0];"
      "  if (event.data === 'aegis-script-source') {"
      "    port.postMessage(self.aegisImportedScriptSource || 'missing');"
      "    return;"
      "  }"
      "  event.waitUntil(fetch(event.data, {mode: 'no-cors'})"
      "    .then(() => port.postMessage('resolved'))"
      "    .catch(() => port.postMessage('error')));"
      "});");
  response->set_content_type("application/javascript");
}

std::unique_ptr<net::test_server::HttpResponse> BuildServiceWorkerReply(
    std::atomic<size_t>* counter,
    const net::test_server::HttpRequest& request,
    bool proxy_response) {
  const ServiceWorkerRequestKind kind = ClassifyServiceWorkerRequest(request);
  if (kind == ServiceWorkerRequestKind::kOther) {
    return nullptr;
  }

  counter->fetch_add(1, std::memory_order_relaxed);
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_OK);
  if (kind == ServiceWorkerRequestKind::kMainScript) {
    ConfigureServiceWorkerMainScriptResponse(response.get());
    return response;
  }
  if (kind == ServiceWorkerRequestKind::kImportedScript) {
    response->set_content(proxy_response
                              ? "self.aegisImportedScriptSource = "
                                "'proxy-service-worker-script';"
                              : "self.aegisImportedScriptSource = "
                                "'origin-service-worker-script';");
    response->set_content_type("application/javascript");
    return response;
  }

  response->set_content(proxy_response ? "proxy-service-worker-subresource"
                                       : "origin-service-worker-subresource");
  response->set_content_type("text/plain");
  return response;
}

std::unique_ptr<net::test_server::HttpResponse>
ServiceWorkerOriginReply(std::atomic<size_t>* counter,
                         const net::test_server::HttpRequest& request) {
  return BuildServiceWorkerReply(counter, request, /*proxy_response=*/false);
}

std::unique_ptr<net::test_server::HttpResponse>
ServiceWorkerProxyReply(std::atomic<size_t>* counter,
                        const net::test_server::HttpRequest& request) {
  return BuildServiceWorkerReply(counter, request, /*proxy_response=*/true);
}

std::unique_ptr<net::test_server::HttpResponse> IgnoreAutomaticFavicon(
    const net::test_server::HttpRequest& request) {
  if (request.GetURL().path() != "/favicon.ico") {
    return nullptr;
  }

  // Chromium fetches this after navigation; only route-test resources count.
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_NO_CONTENT);
  return response;
}

std::unique_ptr<net::test_server::HttpResponse> ParserEarlyPageReply(
    std::atomic<size_t>* counter,
    net::test_server::EmbeddedTestServer* origin,
    const net::test_server::HttpRequest& request) {
  if (request.GetURL().path() != "/parser-early-page") {
    return nullptr;
  }
  counter->fetch_add(1, std::memory_order_relaxed);
  const char* resource = request.relative_url.find("blocked") !=
                                 std::string::npos
                             ? "/resource?parser-blocked"
                             : "/resource?parser-healthy";
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_OK);
  response->set_content(
      "<!doctype html><script>window.parserFetchDone = "
      "fetch('" + origin->GetURL(kTargetHost, resource).spec() +
      "', {mode:'no-cors',cache:'no-store'})"
      ".then(() => 'loaded', () => 'error');</script>");
  response->set_content_type("text/html");
  return response;
}

std::unique_ptr<net::test_server::HttpResponse> SandboxedPageReply(
    std::atomic<size_t>* counter,
    net::test_server::EmbeddedTestServer* origin,
    const net::test_server::HttpRequest& request) {
  if (request.GetURL().path() != "/sandboxed-page") {
    return nullptr;
  }
  counter->fetch_add(1, std::memory_order_relaxed);
  const bool healthy = request.relative_url.find("healthy") !=
                       std::string::npos;
  const char* resource = healthy ? "/resource?sandbox-healthy"
                                 : "/resource?sandbox-blocked";
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_OK);
  response->AddCustomHeader("Content-Security-Policy",
                            "sandbox allow-scripts");
  response->set_content(
      "<!doctype html><script>window.sandboxFetchDone = "
      "fetch('" + origin->GetURL(kTargetHost, resource).spec() +
      "', {mode:'no-cors',cache:'no-store'})"
      ".then(() => 'loaded', () => 'error');</script>");
  response->set_content_type("text/html");
  return response;
}

std::unique_ptr<net::test_server::HttpResponse> SandboxedPrefetchPageReply(
    std::atomic<size_t>* counter,
    net::test_server::EmbeddedTestServer* origin,
    const net::test_server::HttpRequest& request) {
  if (request.GetURL().path() != "/sandboxed-prefetch-page") {
    return nullptr;
  }
  counter->fetch_add(1, std::memory_order_relaxed);
  const bool healthy = request.relative_url.find("healthy") !=
                       std::string::npos;
  const char* resource = healthy ? "/resource?sandbox-prefetch-healthy"
                                 : "/resource?sandbox-prefetch-blocked";
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_OK);
  response->AddCustomHeader("Content-Security-Policy",
                            "sandbox allow-scripts");
  response->set_content(
      "<!doctype html><script>window.prefetchDone = new Promise(resolve => "
      "window.resolvePrefetch = resolve)</script>"
      "<link rel='prefetch' as='document' href='" +
      origin->GetURL(kTargetHost, resource).spec() +
      "' onload=\"resolvePrefetch('loaded')\" "
      "onerror=\"resolvePrefetch('error')\">");
  response->set_content_type("text/html");
  return response;
}

std::unique_ptr<net::test_server::HttpResponse> CountAndReply(
    std::atomic<size_t>* counter,
    const char* body,
    const net::test_server::HttpRequest& request) {
  counter->fetch_add(1, std::memory_order_relaxed);
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_OK);
  if (request.relative_url.find("/startup-prefetch-page") !=
      std::string::npos) {
    response->set_content(
        "<!doctype html><script>"
        "window.prefetchDone = new Promise(resolve => "
        "  window.resolvePrefetch = resolve);"
        "</script><link rel='prefetch' as='document' "
        "href='/startup-prefetch-resource' "
        "onload=\"resolvePrefetch('loaded')\" "
        "onerror=\"resolvePrefetch('error')\">");
    response->set_content_type("text/html");
    return response;
  }
  if (request.relative_url.find("/worker-page") != std::string::npos) {
    response->set_content("<!doctype html><title>worker-main</title>");
    response->set_content_type("text/html");
    return response;
  }
  if (request.relative_url.find("/shared-worker-subresource.js") !=
      std::string::npos) {
    response->set_content(
        "self.onconnect = event => {"
        "  const port = event.ports[0];"
        "  port.onmessage = async message => {"
        "    try {"
        "      const response = await fetch(message.data);"
        "      port.postMessage(await response.text());"
        "    } catch {"
        "      port.postMessage('error');"
        "    }"
        "  };"
        "  port.start();"
        "  port.postMessage('ready');"
        "};");
    response->set_content_type("application/javascript");
    return response;
  }
  if (request.relative_url.find("/worker-subresource.js") !=
      std::string::npos) {
    response->set_content(
        "self.postMessage('ready');"
        "self.onmessage = async event => {"
        "  try {"
        "    const response = await fetch(event.data);"
        "    self.postMessage(await response.text());"
        "  } catch {"
        "    self.postMessage('error');"
        "  }"
        "};");
    response->set_content_type("application/javascript");
    return response;
  }
  if (request.relative_url.find("/worker-data") != std::string::npos) {
    response->set_content("origin-worker-subresource");
    response->set_content_type("text/plain");
    return response;
  }
  if (request.relative_url.find("/worker.js") != std::string::npos) {
    response->set_content("self.postMessage('origin');");
    response->set_content_type("application/javascript");
    return response;
  }
  response->set_content(body);
  response->set_content_type("text/plain");
  return response;
}

std::unique_ptr<net::test_server::HttpResponse> ProxyReply(
    std::atomic<size_t>* counter,
    net::test_server::EmbeddedTestServer* target_origin,
    const net::test_server::HttpRequest& request) {
  counter->fetch_add(1, std::memory_order_relaxed);
  if (request.relative_url.find("/hang") != std::string::npos) {
    return std::make_unique<net::test_server::HungResponse>();
  }
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  if (request.relative_url.find("/worker.js") != std::string::npos) {
    response->set_code(net::HTTP_OK);
    response->set_content("self.postMessage('proxy');");
    response->set_content_type("application/javascript");
    return response;
  }
  if (request.relative_url.find("/worker-data") != std::string::npos) {
    response->set_code(net::HTTP_OK);
    response->set_content("proxy-worker-subresource");
    response->set_content_type("text/plain");
    return response;
  }
  if (request.relative_url.find("/redirect-unselected") !=
      std::string::npos) {
    response->set_code(net::HTTP_FOUND);
    response->AddCustomHeader(
        "Location",
        target_origin->GetURL(kUnselectedRedirectHost, "/resource").spec());
    return response;
  }
  if (request.relative_url.find("/redirect") != std::string::npos) {
    response->set_code(net::HTTP_FOUND);
    response->AddCustomHeader(
        "Location", target_origin->GetURL(kTargetHost, "/resource").spec());
    return response;
  }
  response->set_code(net::HTTP_OK);
  response->set_content("proxy");
  response->set_content_type("text/plain");
  return response;
}

class AccessProxyingURLLoaderFactoryBrowserTest : public InProcessBrowserTest {
 public:
  AccessProxyingURLLoaderFactoryBrowserTest()
      : target_origin_(net::test_server::EmbeddedTestServer::TYPE_HTTP),
        proxy_server_(net::test_server::EmbeddedTestServer::TYPE_HTTP) {}
  ~AccessProxyingURLLoaderFactoryBrowserTest() override = default;

  void SetUpOnMainThread() override {
    InProcessBrowserTest::SetUpOnMainThread();

    host_resolver()->AddRule(kTargetHost, "127.0.0.1");
    host_resolver()->AddRule(kTrailingDotTargetHost, "127.0.0.1");
    host_resolver()->AddRule(kUnselectedRedirectHost, "127.0.0.1");

    target_origin_.RegisterRequestHandler(
        base::BindRepeating(&IgnoreAutomaticFavicon));
    target_origin_.RegisterRequestHandler(base::BindRepeating(
        &ParserEarlyPageReply, base::Unretained(&origin_requests_),
        base::Unretained(&target_origin_)));
    target_origin_.RegisterRequestHandler(base::BindRepeating(
        &SandboxedPageReply, base::Unretained(&origin_requests_),
        base::Unretained(&target_origin_)));
    target_origin_.RegisterRequestHandler(base::BindRepeating(
        &SandboxedPrefetchPageReply, base::Unretained(&origin_requests_),
        base::Unretained(&target_origin_)));
    target_origin_.RegisterRequestHandler(base::BindRepeating(
        &ServiceWorkerOriginReply, base::Unretained(&origin_requests_)));
    target_origin_.RegisterRequestHandler(base::BindRepeating(
        &CountAndReply, base::Unretained(&origin_requests_), "origin"));
    proxy_server_.RegisterRequestHandler(
        base::BindRepeating(&IgnoreAutomaticFavicon));
    proxy_server_.RegisterRequestHandler(base::BindRepeating(
        &ServiceWorkerProxyReply, base::Unretained(&proxy_requests_)));
    proxy_server_.RegisterRequestHandler(base::BindRepeating(
        &ProxyReply, base::Unretained(&proxy_requests_),
        base::Unretained(&target_origin_)));
    ASSERT_TRUE(target_origin_.Start());
    ASSERT_TRUE(proxy_server_.Start());
    ASSERT_TRUE(embedded_test_server()->Start());

    ASSERT_TRUE(ui_test_utils::NavigateToURL(
        browser(), embedded_test_server()->GetURL("/title1.html")));

    transport_ = AccessNetworkContextTransport::Get(browser()->profile());
    ASSERT_NE(transport_, nullptr);

    owner_ = transport_->OwnerForPartition(
        aegis_access::ChannelNamespace::kDev, base::FilePath());
    ASSERT_TRUE(owner_.has_value());
    ASSERT_TRUE(transport_->OwnsConfiguredPartition(*owner_));
  }

 protected:
  content::WebContents* web_contents() {
    return browser()->tab_strip_model()->GetActiveWebContents();
  }

  GURL target_url() const {
    return target_origin_.GetURL(kTargetHost, "/resource");
  }

  GURL worker_page_url() const {
    return target_origin_.GetURL(kTargetHost, "/worker-page");
  }

  GURL worker_script_url() const {
    return target_origin_.GetURL(kTargetHost, "/worker.js");
  }

  GURL worker_subresource_script_url() const {
    return target_origin_.GetURL(kTargetHost, "/worker-subresource.js");
  }

  GURL worker_subresource_url() const {
    return target_origin_.GetURL(kTargetHost, "/worker-data");
  }

  GURL shared_worker_subresource_script_url() const {
    return target_origin_.GetURL(kTargetHost, "/shared-worker-subresource.js");
  }

  GURL service_worker_page_url() const {
    return target_origin_.GetURL("localhost", "/worker-page");
  }

  GURL service_worker_script_url() const {
    return target_origin_.GetURL("localhost", "/aegis-service-worker.js");
  }

  GURL service_worker_subresource_url() const {
    return target_origin_.GetURL("localhost", "/service-worker-data");
  }

  GURL redirect_url() const {
    return target_origin_.GetURL(kTargetHost, "/redirect");
  }

  GURL unselected_redirect_url() const {
    return target_origin_.GetURL(kTargetHost, "/redirect-unselected");
  }

  GURL hanging_url() const {
    return target_origin_.GetURL(kTargetHost, "/hang");
  }

  void BuildCancellationSelector(
      const GURL& url,
      aegis_access::RequestCancellationSelector* selector) {
    ASSERT_NE(selector, nullptr);
    Profile* profile = browser()->profile();
    content::RenderFrameHost* frame = web_contents()->GetPrimaryMainFrame();
    ASSERT_NE(frame, nullptr);
    const content::FrameTreeNodeId frame_tree_node_id =
        frame->GetFrameTreeNodeId();
    auto wc_getter =
        base::BindRepeating(&content::WebContents::FromFrameTreeNodeId,
                            frame_tree_node_id);
    AccessBrowserRequestMetadataResult metadata = BuildBrowserOwnedRequestMetadata(
        profile, wc_getter, frame_tree_node_id, std::nullopt);
    ASSERT_EQ(metadata.status, AccessBrowserRequestMetadataStatus::kOk);
    ASSERT_TRUE(metadata.metadata.has_value());

    aegis_access::RequestPolicyContextResult context =
        aegis_access::CanonicalizeBrowserOwnedRequest(*metadata.metadata, url);
    ASSERT_TRUE(context.context.has_value());
    *selector = {context.context->owner(),
                 context.context->document_token(),
                 context.context->pending_navigation_token(),
                 context.context->top_level_site(),
                 context.context->exact_host(),
                 context.context->scheme(),
                 context.context->port()};
  }

  void StartPendingFetch(const GURL& url) {
    ASSERT_TRUE(content::ExecJs(
        web_contents(),
        content::JsReplace(
            "window.aegisFetchState = 'pending';"
            "fetch($1, {mode: 'no-cors'})"
            ".then(() => { window.aegisFetchState = 'resolved'; })"
            ".catch(() => { window.aegisFetchState = 'blocked'; });"
            "true;",
            url.spec())));
  }

  std::string PendingFetchState() {
    return content::EvalJs(web_contents(), "window.aegisFetchState")
        .ExtractString();
  }

  bool Fetch(const GURL& url) {
    return content::EvalJs(
               web_contents(),
               content::JsReplace(
                   "fetch($1, {mode: 'no-cors'}).then(() => true)"
                   ".catch(() => false)",
                   url.spec()))
        .ExtractBool();
  }

  bool FetchTarget() { return Fetch(target_url()); }

  int FetchWithFactory(network::mojom::URLLoaderFactory* factory,
                       const GURL& url,
                       const GURL& initiator_url) {
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = url;
    request->request_initiator = url::Origin::Create(initiator_url);
    request->load_flags = net::LOAD_BYPASS_CACHE;
    auto loader = network::SimpleURLLoader::Create(
        std::move(request), TRAFFIC_ANNOTATION_FOR_TESTS);
    base::test::TestFuture<std::optional<std::string>> result;
    loader->DownloadToStringOfUnboundedSizeUntilCrashAndDie(
        factory, result.GetCallback());
    EXPECT_TRUE(result.Wait());
    return loader->NetError();
  }

  bool FetchNoStore(const GURL& url) {
    return content::EvalJs(
               web_contents(),
               content::JsReplace(
                   "fetch($1, {mode: 'no-cors', cache: 'no-store'})"
                   ".then(() => true).catch(() => false)",
                   url.spec()))
        .ExtractBool();
  }

  std::optional<std::string> FetchBrowserProcessPrefetchOnPartition(
      content::StoragePartition* partition,
      const GURL& url) {
    Profile* profile = browser()->profile();
    EXPECT_NE(partition, nullptr);
    if (!partition) {
      return std::nullopt;
    }

    network::URLLoaderFactoryBuilder factory_builder;
    AccessProxyingURLLoaderFactory::MaybeProxyBrowserProcessPrefetch(
        profile, partition, factory_builder);
    scoped_refptr<network::SharedURLLoaderFactory> factory =
        std::move(factory_builder)
            .Finish(partition->GetURLLoaderFactoryForBrowserProcess());

    auto request = std::make_unique<network::ResourceRequest>();
    request->method = "GET";
    request->url = url;
    request->load_flags = net::LOAD_PREFETCH;
    request->mode = network::mojom::RequestMode::kNoCors;
    request->destination = network::mojom::RequestDestination::kEmpty;
    auto loader = network::SimpleURLLoader::Create(
        std::move(request), TRAFFIC_ANNOTATION_FOR_TESTS);
    base::test::TestFuture<std::optional<std::string>> result;
    loader->DownloadToStringOfUnboundedSizeUntilCrashAndDie(
        factory.get(), result.GetCallback());
    EXPECT_TRUE(result.Wait());
    if (loader->NetError() != net::OK) {
      return std::nullopt;
    }
    return result.Get();
  }

  std::optional<std::string> FetchBrowserProcessPrefetch(const GURL& url) {
    return FetchBrowserProcessPrefetchOnPartition(
        browser()->profile()->GetDefaultStoragePartition(), url);
  }

  std::string RunPrefetch(const GURL& url) {
    return content::EvalJs(
               web_contents(),
               content::JsReplace(
                   "new Promise(resolve => {"
                   "  const link = document.createElement('link');"
                   "  link.rel = 'prefetch';"
                   "  link.as = 'document';"
                   "  link.href = $1;"
                   "  link.onload = () => resolve('loaded');"
                   "  link.onerror = () => resolve('error');"
                   "  document.head.appendChild(link);"
                   "})",
                   url.spec()))
        .ExtractString();
  }

  void PreparePrefetchTest(size_t* origin_before, size_t* proxy_before) {
    ASSERT_NE(origin_before, nullptr);
    ASSERT_NE(proxy_before, nullptr);
    ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
    *origin_before = origin_requests_.load(std::memory_order_relaxed);
    *proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  }

  void ExpectRoutingDelta(size_t origin_before,
                          size_t proxy_before,
                          size_t origin_delta,
                          size_t proxy_delta) {
    if (origin_delta > 0u) {
      EXPECT_TRUE(base::test::RunUntil([&] {
        return origin_requests_.load(std::memory_order_relaxed) ==
               origin_before + origin_delta;
      }));
    }
    if (proxy_delta > 0u) {
      EXPECT_TRUE(base::test::RunUntil([&] {
        return proxy_requests_.load(std::memory_order_relaxed) ==
               proxy_before + proxy_delta;
      }));
    }
    EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed),
              origin_before + origin_delta);
    EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed),
              proxy_before + proxy_delta);
  }

  std::string RunWorkerMainScript(const GURL& script_url) {
    return content::EvalJs(
               web_contents(),
               content::JsReplace(
                   "new Promise(resolve => {"
                   "  const worker = new Worker($1);"
                   "  worker.onmessage = event => resolve(event.data);"
                   "  worker.onerror = event => {"
                   "    event.preventDefault();"
                   "    resolve('error');"
                   "  };"
                   "})",
                   script_url.spec()))
        .ExtractString();
  }

  void StartWorkerSubresourceHarness() {
    EXPECT_EQ(
        content::EvalJs(
            web_contents(),
            content::JsReplace(
                "new Promise(resolve => {"
                "  window.aegisSubresourceWorker = new Worker($1);"
                "  window.aegisSubresourceWorker.onmessage = event => {"
                "    if (event.data === 'ready') resolve('ready');"
                "  };"
                "  window.aegisSubresourceWorker.onerror = event => {"
                "    event.preventDefault();"
                "    resolve('error');"
                "  };"
                "})",
                worker_subresource_script_url().spec()))
            .ExtractString(),
        "ready");
  }

  void PrepareWorkerSubresourceTest(size_t* origin_before,
                                    size_t* proxy_before) {
    ASSERT_NE(origin_before, nullptr);
    ASSERT_NE(proxy_before, nullptr);
    ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
    StartWorkerSubresourceHarness();
    *origin_before = origin_requests_.load(std::memory_order_relaxed);
    *proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  }

  std::string FetchWorkerSubresource(const GURL& url) {
    return content::EvalJs(
               web_contents(),
               content::JsReplace(
                   "new Promise(resolve => {"
                   "  const worker = window.aegisSubresourceWorker;"
                   "  worker.onmessage = event => resolve(event.data);"
                   "  worker.onerror = event => {"
                   "    event.preventDefault();"
                   "    resolve('error');"
                   "  };"
                   "  worker.postMessage($1);"
                   "})",
                   url.spec()))
        .ExtractString();
  }

  void StartSharedWorkerSubresourceHarness() {
    EXPECT_EQ(
        content::EvalJs(
            web_contents(),
            content::JsReplace(
                "new Promise(resolve => {"
                "  const worker = new SharedWorker($1);"
                "  const port = worker.port;"
                "  window.aegisSharedWorker = worker;"
                "  window.aegisSharedWorkerPort = port;"
                "  port.onmessage = event => {"
                "    if (event.data === 'ready') resolve('ready');"
                "  };"
                "  port.start();"
                "})",
                shared_worker_subresource_script_url().spec()))
            .ExtractString(),
        "ready");
  }

  void PrepareSharedWorkerSubresourceTest(size_t* origin_before,
                                          size_t* proxy_before) {
    ASSERT_NE(origin_before, nullptr);
    ASSERT_NE(proxy_before, nullptr);
    ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
    StartSharedWorkerSubresourceHarness();
    *origin_before = origin_requests_.load(std::memory_order_relaxed);
    *proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  }

  std::string FetchSharedWorkerSubresource(const GURL& url) {
    return content::EvalJs(
               web_contents(),
               content::JsReplace(
                   "new Promise(resolve => {"
                   "  const port = window.aegisSharedWorkerPort;"
                   "  port.onmessage = event => resolve(event.data);"
                   "  port.postMessage($1);"
                   "})",
                   url.spec()))
        .ExtractString();
  }

  std::string StartServiceWorkerHarness() {
    return content::EvalJs(
               web_contents(),
               content::JsReplace(
                   "new Promise(async resolve => {"
                   "  try {"
                   "    const registration = "
                   "        await navigator.serviceWorker.register($1);"
                   "    await navigator.serviceWorker.ready;"
                   "    const worker = registration.active;"
                   "    if (!worker) { resolve('error'); return; }"
                   "    window.aegisServiceWorker = worker;"
                   "    resolve('ready');"
                   "  } catch { resolve('error'); }"
                   "})",
                   service_worker_script_url().spec()))
        .ExtractString();
  }

  void PrepareServiceWorkerSubresourceTest(size_t* origin_before,
                                           size_t* proxy_before) {
    ASSERT_NE(origin_before, nullptr);
    ASSERT_NE(proxy_before, nullptr);
    ASSERT_TRUE(
        ui_test_utils::NavigateToURL(browser(), service_worker_page_url()));
    ASSERT_EQ(StartServiceWorkerHarness(), "ready");
    *origin_before = origin_requests_.load(std::memory_order_relaxed);
    *proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  }

  std::string ServiceWorkerScriptSource() {
    return content::EvalJs(
               web_contents(),
               "new Promise(resolve => {"
               "  const worker = window.aegisServiceWorker;"
               "  const channel = new MessageChannel();"
               "  channel.port1.onmessage = event => resolve(event.data);"
               "  worker.postMessage('aegis-script-source', [channel.port2]);"
               "})")
        .ExtractString();
  }

  std::string FetchServiceWorkerSubresource(const GURL& url) {
    return content::EvalJs(
               web_contents(),
               content::JsReplace(
                   "new Promise(resolve => {"
                   "  const worker = window.aegisServiceWorker;"
                   "  const channel = new MessageChannel();"
                   "  channel.port1.onmessage = event => resolve(event.data);"
                   "  worker.postMessage($1, [channel.port2]);"
                   "})",
                   url.spec()))
        .ExtractString();
  }

  void ExpectRedirectFollowedThroughProxy() {
    EXPECT_TRUE(base::test::RunUntil([&] {
      return proxy_requests_.load(std::memory_order_relaxed) == 2u;
    }));
    EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), 0u);
  }

  void NavigateNewIframe(const GURL& url) {
    ASSERT_TRUE(content::ExecJs(
        web_contents(),
        content::JsReplace(
            "const frame = document.createElement('iframe');"
            "frame.src = $1;"
            "document.body.appendChild(frame);",
            url.spec())));
  }

  std::string FetchFromInlineIframe(bool srcdoc, const GURL& resource) {
    const std::string markup =
        "<!doctype html><script>"
        "parent.postMessage('started', '*');"
        "setTimeout(() => parent.postMessage('child-timeout', '*'), 8000);"
        "fetch('" + resource.spec() +
        "', {mode:'no-cors',cache:'no-store'})"
        ".then(() => parent.postMessage('loaded', '*'), "
        "() => parent.postMessage('error', '*'));</script>";
    return content::EvalJs(
               web_contents(),
               content::JsReplace(
                   "new Promise(resolve => {"
                   "  const frame = document.createElement('iframe');"
                   "  const markup = $2;"
                   "  const timeout = setTimeout(() => {"
                   "    window.removeEventListener('message', listener);"
                   "    frame.remove();"
                   "    resolve('timeout:' + stages.join(','));"
                   "  }, 10000);"
                   "  const stages = [];"
                   "  const listener = event => {"
                   "    if (event.source !== frame.contentWindow) return;"
                   "    if (event.data === 'started' ||"
                   "        event.data === 'child-timeout') {"
                   "      stages.push(event.data);"
                   "      return;"
                   "    }"
                   "    clearTimeout(timeout);"
                   "    window.removeEventListener('message', listener);"
                   "    frame.remove();"
                   "    resolve(event.data);"
                   "  };"
                   "  frame.onload = () => { stages.push('frame-loaded'); };"
                   "  frame.onerror = () => { stages.push('frame-error'); };"
                   "  window.addEventListener('message', listener);"
                   "  if ($1) frame.srcdoc = markup;"
                   "  else frame.src = 'data:text/html;base64,' + btoa(markup);"
                   "  document.body.appendChild(frame);"
                   "})",
                   srcdoc, markup))
        .ExtractString();
  }

  uint64_t CommitIdentityGenerationForProxyPolicy() {
    auto* identity =
        AccessIdentityGenerationSource::GetOrCreate(browser()->profile());
    EXPECT_NE(identity, nullptr);
    if (!identity) {
      return 0;
    }

    const auto commit = identity->CommitIdentity(
        {aegis_access::AccessIdentityKind::kInstallationGuest,
         "guest-browser-test", "entitlement-browser-test", "dev", "access"});
    EXPECT_EQ(commit.status,
              aegis_access::IdentityGenerationCommitStatus::kCommitted);
    return commit.generation;
  }

  uint64_t CommitSelectionGenerationForProxyPolicy() {
    auto* selection =
        AccessProxySelectionGenerationSource::GetOrCreate(browser()->profile());
    EXPECT_NE(selection, nullptr);
    if (!selection) {
      return 0;
    }

    const auto commit = selection->CommitSelection(
        {kProxyGroup, "endpoint-browser-test", "lease-browser-test",
         "assignment-browser-test", 1});
    EXPECT_EQ(commit.status,
              aegis_access::ProxySelectionGenerationCommitStatus::kCommitted);
    return commit.generation;
  }

  uint64_t CurrentBaseProxyGeneration() {
    auto* network_service =
        ProfileNetworkContextServiceFactory::GetForContext(browser()->profile());
    EXPECT_NE(network_service, nullptr);
    if (!network_service) {
      return 0;
    }

    const uint64_t generation =
        network_service->GetAegisBaseProxyConfigGeneration();
    EXPECT_GT(generation, 0u);
    return generation;
  }

  void PublishCommittedRule(const std::string& destination_host,
                            aegis_access::AccessMode mode) {
    aegis_access::AccessPolicyRule rule;
    rule.rule_id = "rule-browser-test";
    rule.owner = *owner_;
    rule.scope = aegis_access::PolicyScope::kProfile;
    rule.destination_host = destination_host;
    rule.schemes = {aegis_access::RequestScheme::kHttp};
    rule.ports.scope = aegis_access::PortScope::kAllBrowserPermitted;
    rule.mode = mode;
    if (mode == aegis_access::AccessMode::kProxy) {
      rule.proxy_group_id = kProxyGroup;
    }
    rule.protection_override = aegis_access::ProtectionOverride::kNone;
    rule.row_revision = 1;
    rule.last_operation_sequence = 1;

    StoredAccessRule stored_rule;
    stored_rule.policy = rule;
    stored_rule.source = StoredRuleSource::kTestFixture;
    stored_rule.lifetime = StoredRuleLifetime::kPersistent;

    StoredPolicySnapshot snapshot;
    snapshot.owner = *owner_;
    snapshot.policy_generation = 1;
    snapshot.independent_rules.push_back(std::move(stored_rule));

    auto* runtime =
        AccessPublishedRequestRuntime::GetOrCreate(browser()->profile());
    EXPECT_NE(runtime, nullptr);
    if (!runtime) {
      return;
    }

    const AccessPolicyPublicationResult publication =
        runtime->PublishCommittedPolicySnapshot(snapshot);
    EXPECT_EQ(publication.status, AccessPolicyPublicationStatus::kPublished);
  }

  void PublishSelectedProxyEndpoint(
      const std::string& destination_host,
      const aegis_access::GenerationTuple& generations) {
    const aegis_access::RegisteredProxyEndpoint endpoint{
        "registration-browser-test", kProxyGroup, *owner_, generations,
        aegis_access::RegisteredProxyTransport::kHttp, "127.0.0.1",
        static_cast<uint16_t>(proxy_server_.port())};
    EXPECT_TRUE(transport_->PublishProxySelection(
        base::FilePath(), {destination_host}, endpoint));
    transport_->FlushClientsForTesting(base::FilePath());
  }

  void PublishProxyPolicy(bool publish_endpoint,
                          std::string destination_host = kTargetHost) {
    const aegis_access::GenerationTuple generations{
        1,
        CommitIdentityGenerationForProxyPolicy(),
        CommitSelectionGenerationForProxyPolicy(),
        transport_->network_epoch(),
        CurrentBaseProxyGeneration(),
    };

    PublishCommittedRule(destination_host, aegis_access::AccessMode::kProxy);
    if (publish_endpoint) {
      PublishSelectedProxyEndpoint(destination_host, generations);
    }
  }

  void PublishRejectPolicy() {
    PublishCommittedRule(kTargetHost, aegis_access::AccessMode::kReject);
  }

  std::optional<aegis_access::RequestCancellationSelector> CurrentSiteSelector() {
    const auto metadata = BuildBrowserOwnedRequestMetadata(
        browser()->profile(), base::BindRepeating(
            &AccessProxyingURLLoaderFactoryBrowserTest::web_contents,
            base::Unretained(this)),
        web_contents()->GetPrimaryMainFrame()->GetFrameTreeNodeId(), std::nullopt);
    if (!metadata.metadata) {
      return std::nullopt;
    }
    const auto context = aegis_access::CanonicalizeBrowserOwnedRequest(
        *metadata.metadata, target_url());
    if (!context.context) {
      return std::nullopt;
    }
    const auto& value = *context.context;
    return aegis_access::RequestCancellationSelector{
        value.owner(), value.document_token(), value.pending_navigation_token(),
        value.top_level_site(), value.exact_host(), value.scheme(), value.port()};
  }

  std::atomic<size_t> origin_requests_{0};
  std::atomic<size_t> proxy_requests_{0};
  net::test_server::EmbeddedTestServer target_origin_;
  net::test_server::EmbeddedTestServer proxy_server_;
  raw_ptr<AccessNetworkContextTransport> transport_ = nullptr;
  std::optional<aegis_access::OwnershipKey> owner_;
};

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       NoPublishedPolicyPreservesNativePath) {
  EXPECT_TRUE(FetchTarget());
  EXPECT_TRUE(base::test::RunUntil([&] {
    return origin_requests_.load(std::memory_order_relaxed) == 1u;
  }));
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       DataDocumentWithoutPolicyPreservesNativeSubresource) {
  const GURL resource = target_url().Resolve("/data-document-health");
  const std::string markup =
      "<!doctype html><script>window.resourceDone = "
      "fetch('" + resource.spec() +
      "', {mode:'no-cors',cache:'no-store'})"
      ".then(() => 'loaded', () => 'error');</script>";
  const GURL data_page("data:text/html;base64," + base::Base64Encode(markup));
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), data_page));
  EXPECT_EQ(content::EvalJs(web_contents(), "window.resourceDone")
                .ExtractString(),
            "loaded");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       DataIframeWithoutEndpointFailsClosed) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
  const GURL resource = target_url().Resolve("/data-iframe-policy");
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchFromInlineIframe(/*srcdoc=*/false, resource), "loaded");
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  PublishProxyPolicy(/*publish_endpoint=*/false);
  const size_t blocked_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t blocked_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchFromInlineIframe(/*srcdoc=*/false, resource), "error");
  ExpectRoutingDelta(blocked_origin_before, blocked_proxy_before,
                     /*origin_delta=*/0u, /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SrcdocIframeWithoutEndpointFailsClosed) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
  const GURL resource = target_url().Resolve("/srcdoc-iframe-policy");
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchFromInlineIframe(/*srcdoc=*/true, resource), "loaded");
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  PublishProxyPolicy(/*publish_endpoint=*/false);
  const size_t blocked_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t blocked_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchFromInlineIframe(/*srcdoc=*/true, resource), "error");
  ExpectRoutingDelta(blocked_origin_before, blocked_proxy_before,
                     /*origin_delta=*/0u, /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       DataIframeRejectPolicyFailsClosed) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
  const GURL resource = target_url().Resolve("/data-iframe-reject");
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchFromInlineIframe(/*srcdoc=*/false, resource), "loaded");
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  PublishRejectPolicy();
  const size_t blocked_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t blocked_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchFromInlineIframe(/*srcdoc=*/false, resource), "error");
  ExpectRoutingDelta(blocked_origin_before, blocked_proxy_before,
                     /*origin_delta=*/0u, /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SrcdocIframeRejectPolicyFailsClosed) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
  const GURL resource = target_url().Resolve("/srcdoc-iframe-reject");
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchFromInlineIframe(/*srcdoc=*/true, resource), "loaded");
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  PublishRejectPolicy();
  const size_t blocked_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t blocked_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchFromInlineIframe(/*srcdoc=*/true, resource), "error");
  ExpectRoutingDelta(blocked_origin_before, blocked_proxy_before,
                     /*origin_delta=*/0u, /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       ParserEarlySubresourceWaitsForCommittedDocument) {
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL("localhost", "/parser-early-page?healthy")));
  EXPECT_EQ(content::EvalJs(web_contents(), "window.parserFetchDone")
                .ExtractString(),
            "loaded");
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/2u, /*proxy_delta=*/0u);

  PublishProxyPolicy(/*publish_endpoint=*/false);
  const size_t blocked_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t blocked_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL("localhost", "/parser-early-page?blocked")));
  EXPECT_EQ(content::EvalJs(web_contents(), "window.parserFetchDone")
                .ExtractString(),
            "error");
  // The unselected page loads once; its parser-issued target request does not.
  ExpectRoutingDelta(blocked_origin_before, blocked_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       ParserEarlySubresourceUsesSelectedProxy) {
  PublishProxyPolicy(/*publish_endpoint=*/true);
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL("localhost", "/parser-early-page?healthy")));
  EXPECT_EQ(content::EvalJs(web_contents(), "window.parserFetchDone")
                .ExtractString(),
            "loaded");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/1u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SandboxedHttpWithoutPolicyPreservesNativePath) {
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL("localhost", "/sandboxed-page?healthy")));
  EXPECT_EQ(content::EvalJs(web_contents(), "window.sandboxFetchDone")
                .ExtractString(),
            "loaded");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/2u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SandboxedHttpWithMissingEndpointFailsClosed) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL("localhost", "/sandboxed-page?healthy")));
  ASSERT_EQ(content::EvalJs(web_contents(), "window.sandboxFetchDone")
                .ExtractString(),
            "loaded");
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  PublishProxyPolicy(/*publish_endpoint=*/false);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL("localhost", "/sandboxed-page?blocked")));
  EXPECT_EQ(content::EvalJs(web_contents(), "window.sandboxFetchDone")
                .ExtractString(),
            "error");
  // The unselected page is served, while its selected target is blocked.
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
  EXPECT_EQ(content::EvalJs(
                web_contents(),
                "fetch('" + target_url().Resolve("/resource?sandbox-postcommit")
                                  .spec() +
                    "', {mode:'no-cors',cache:'no-store'})"
                    ".then(() => 'loaded', () => 'error')")
                .ExtractString(),
            "error");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);

  // A newly created factory for this already committed opaque document must
  // still carry its trusted HTTP document URL and fail closed.
  content::RenderFrameHost* frame = web_contents()->GetPrimaryMainFrame();
  ASSERT_TRUE(frame->GetLastCommittedOrigin().opaque());
  mojo::Remote<network::mojom::URLLoaderFactory> recreated_factory;
  frame->CreateNetworkServiceDefaultFactory(
      recreated_factory.BindNewPipeAndPassReceiver());
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = target_url().Resolve("/resource?sandbox-recreated");
  request->request_initiator = frame->GetLastCommittedOrigin();
  request->load_flags = net::LOAD_BYPASS_CACHE;
  auto loader = network::SimpleURLLoader::Create(
      std::move(request), TRAFFIC_ANNOTATION_FOR_TESTS);
  base::test::TestFuture<std::optional<std::string>> result;
  loader->DownloadToStringOfUnboundedSizeUntilCrashAndDie(
      recreated_factory.get(), result.GetCallback());
  ASSERT_TRUE(result.Wait());
  EXPECT_EQ(loader->NetError(), net::ERR_BLOCKED_BY_CLIENT);
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SandboxedHttpWithSelectedEndpointFailsClosed) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL("localhost", "/sandboxed-page?healthy")));
  ASSERT_EQ(content::EvalJs(web_contents(), "window.sandboxFetchDone")
                .ExtractString(),
            "loaded");
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  PublishProxyPolicy(/*publish_endpoint=*/true);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL("localhost", "/sandboxed-page?blocked")));
  EXPECT_EQ(content::EvalJs(web_contents(), "window.sandboxFetchDone")
                .ExtractString(),
            "error");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SandboxedHttpPrefetchWithPolicyFailsClosed) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(),
      target_origin_.GetURL("localhost", "/sandboxed-prefetch-page?healthy")));
  ASSERT_EQ(content::EvalJs(web_contents(), "window.prefetchDone")
                .ExtractString(),
            "loaded");
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  PublishProxyPolicy(/*publish_endpoint=*/false);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(),
      target_origin_.GetURL("localhost", "/sandboxed-prefetch-page?blocked")));
  EXPECT_EQ(content::EvalJs(web_contents(), "window.prefetchDone")
                .ExtractString(),
            "error");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       PendingDocumentFactoryClosesWhenTabIsDestroyed) {
  ASSERT_NE(ui_test_utils::NavigateToURLWithDisposition(
                browser(), worker_page_url(),
                WindowOpenDisposition::NEW_FOREGROUND_TAB,
                ui_test_utils::BROWSER_TEST_WAIT_FOR_LOAD_STOP),
            nullptr);
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(FetchNoStore(target_url().Resolve("/pending-health")));
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  network::URLLoaderFactoryBuilder builder;
  // A synthetic never-committing navigation leaves the new wrapper endpoint
  // pending. Destroying its WebContents must close queued requests, not run
  // them through the downstream factory.
  AccessProxyingURLLoaderFactory::MaybeProxyDocumentSubresource(
      browser()->profile(), web_contents()->GetPrimaryMainFrame(),
      std::numeric_limits<int64_t>::max(), builder);
  scoped_refptr<network::SharedURLLoaderFactory> pending_factory =
      std::move(builder).Finish(
          browser()->profile()
              ->GetDefaultStoragePartition()
              ->GetURLLoaderFactoryForBrowserProcess());
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = target_url().Resolve("/pending-cancelled");
  request->request_initiator = url::Origin::Create(worker_page_url());
  auto loader = network::SimpleURLLoader::Create(
      std::move(request), TRAFFIC_ANNOTATION_FOR_TESTS);
  base::test::TestFuture<std::optional<std::string>> result;
  loader->DownloadToStringOfUnboundedSizeUntilCrashAndDie(
      pending_factory.get(), result.GetCallback());
  base::RunLoop().RunUntilIdle();
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);

  browser()->tab_strip_model()->CloseWebContentsAt(
      browser()->tab_strip_model()->active_index(), TabCloseTypes::CLOSE_NONE);
  ASSERT_TRUE(result.Wait());
  EXPECT_NE(loader->NetError(), net::OK);
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       CancelledNavigationClosesPendingFactoryAndClone) {
  const GURL first_page = worker_page_url();
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), first_page));
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(FetchNoStore(target_url().Resolve("/cancel-health")));
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  const GURL pending_url =
      target_origin_.GetURL(kTargetHost, "/worker-page?pending-cancel");
  content::TestNavigationManager navigation(web_contents(), pending_url);
  auto pending_navigation = web_contents()->GetController().LoadURL(
      pending_url, content::Referrer(), ui::PAGE_TRANSITION_TYPED,
      std::string());
  ASSERT_TRUE(pending_navigation);
  ASSERT_TRUE(navigation.WaitForResponse());
  content::NavigationHandle* handle = navigation.GetNavigationHandle();
  ASSERT_NE(handle, nullptr);
  content::RenderFrameHost* pending_frame = handle->GetRenderFrameHost();
  ASSERT_NE(pending_frame, nullptr);

  network::URLLoaderFactoryBuilder builder;
  AccessProxyingURLLoaderFactory::MaybeProxyDocumentSubresource(
      browser()->profile(), pending_frame,
      handle->GetNavigationId(), builder);
  scoped_refptr<network::SharedURLLoaderFactory> pending_factory =
      std::move(builder).Finish(
          browser()->profile()
              ->GetDefaultStoragePartition()
              ->GetURLLoaderFactoryForBrowserProcess());
  mojo::Remote<network::mojom::URLLoaderFactory> clone;
  pending_factory->Clone(clone.BindNewPipeAndPassReceiver());

  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  auto start_queued = [&](network::mojom::URLLoaderFactory* factory,
                          const GURL& url,
                          base::test::TestFuture<std::optional<std::string>>&
                              result) {
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = url;
    request->request_initiator = url::Origin::Create(pending_url);
    request->load_flags = net::LOAD_BYPASS_CACHE;
    auto loader = network::SimpleURLLoader::Create(
        std::move(request), TRAFFIC_ANNOTATION_FOR_TESTS);
    loader->DownloadToStringOfUnboundedSizeUntilCrashAndDie(
        factory, result.GetCallback());
    return loader;
  };
  base::test::TestFuture<std::optional<std::string>> original_result;
  base::test::TestFuture<std::optional<std::string>> clone_result;
  auto original_loader = start_queued(
      pending_factory.get(), target_url().Resolve("/cancel-original"),
      original_result);
  auto clone_loader = start_queued(
      clone.get(), target_url().Resolve("/cancel-clone"), clone_result);
  base::RunLoop().RunUntilIdle();
  EXPECT_FALSE(original_result.IsReady());
  EXPECT_FALSE(clone_result.IsReady());
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);

  web_contents()->Stop();
  ASSERT_TRUE(navigation.WaitForNavigationFinished());
  ASSERT_TRUE(original_result.Wait());
  ASSERT_TRUE(clone_result.Wait());
  EXPECT_NE(original_loader->NetError(), net::OK);
  EXPECT_NE(clone_loader->NetError(), net::OK);
  EXPECT_EQ(web_contents()->GetLastCommittedURL(), first_page);
  EXPECT_EQ(web_contents(),
            browser()->tab_strip_model()->GetActiveWebContents());
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);
}

class AccessProxyingURLLoaderFactorySameFrameBrowserTest
    : public AccessProxyingURLLoaderFactoryBrowserTest {
 public:
  AccessProxyingURLLoaderFactorySameFrameBrowserTest() {
    features_.InitAndDisableFeature(features::kRenderDocument);
  }

 private:
  base::test::ScopedFeatureList features_;
};

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactorySameFrameBrowserTest,
                       SameFrameOldDocumentFactoryCloneAbortsWithoutPolicy) {
  content::DisableBackForwardCacheForTesting(
      web_contents(), content::BackForwardCache::TEST_REQUIRES_NO_CACHING);
  const GURL first_page = worker_page_url();
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), first_page));
  content::RenderFrameHost* frame = web_contents()->GetPrimaryMainFrame();
  ASSERT_NE(frame, nullptr);
  const content::GlobalRenderFrameHostId frame_id = frame->GetGlobalId();
  const content::WeakDocumentPtr first_document = frame->GetWeakDocumentPtr();

  mojo::Remote<network::mojom::URLLoaderFactory> first_factory;
  frame->CreateNetworkServiceDefaultFactory(
      first_factory.BindNewPipeAndPassReceiver());
  mojo::Remote<network::mojom::URLLoaderFactory> old_clone;
  first_factory->Clone(old_clone.BindNewPipeAndPassReceiver());
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchWithFactory(first_factory.get(),
                             target_url().Resolve("/same-frame-health"),
                             first_page),
            net::OK);
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL(kTargetHost, "/worker-page?second")));
  ASSERT_EQ(web_contents()->GetPrimaryMainFrame()->GetGlobalId(), frame_id);
  ASSERT_EQ(first_document.AsRenderFrameHostIfValid(), nullptr);
  const size_t stale_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t stale_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(FetchWithFactory(old_clone.get(),
                             target_url().Resolve("/same-frame-stale"),
                             first_page),
            net::ERR_ABORTED);
  ExpectRoutingDelta(stale_origin_before, stale_proxy_before,
                     /*origin_delta=*/0u, /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       TrailingDotHostStaysNativeWithoutPolicyAndBlocksAfterPublish) {
  const GURL trailing_url =
      target_origin_.GetURL(kTrailingDotTargetHost, "/resource");
  ASSERT_EQ(trailing_url.host(), kTrailingDotTargetHost);

  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(FetchNoStore(trailing_url));
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  PublishProxyPolicy(/*publish_endpoint=*/true);
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_FALSE(FetchNoStore(trailing_url));
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);

  ASSERT_TRUE(FetchNoStore(target_url()));
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/1u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       TrailingDotTopFrameBlocksCanonicalSubresourceAfterPublish) {
  const GURL trailing_page =
      target_origin_.GetURL(kTrailingDotTargetHost, "/worker-page");
  ASSERT_EQ(trailing_page.host(), kTrailingDotTargetHost);
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), trailing_page));
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  const size_t native_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t native_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(FetchNoStore(target_url()));
  ExpectRoutingDelta(native_origin_before, native_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  PublishProxyPolicy(/*publish_endpoint=*/true);
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_FALSE(FetchNoStore(target_url()));
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       MainNavigationWithoutPolicyPreservesNativePath) {
  EXPECT_TRUE(ui_test_utils::NavigateToURL(browser(), target_url()));
  EXPECT_TRUE(base::test::RunUntil([&] {
    return origin_requests_.load(std::memory_order_relaxed) == 1u;
  })) << "origin=" << origin_requests_.load(std::memory_order_relaxed)
      << " proxy=" << proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       MainNavigationUsesPendingNavigationProxy) {
  PublishProxyPolicy(/*publish_endpoint=*/true);

  EXPECT_TRUE(ui_test_utils::NavigateToURL(browser(), target_url()));
  EXPECT_TRUE(base::test::RunUntil([&] {
    return proxy_requests_.load(std::memory_order_relaxed) == 1u;
  }));
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       MainNavigationConsumesPreparedSnapshotBeforeCommit) {
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(*owner_));
  ASSERT_EQ(store.Open(), StoreStatus::kValid);
  const auto request = PreparedNavigationRequest(*owner_);
  const auto prepared = store.PrepareSiteGroupMutation(request);
  ASSERT_TRUE(prepared.value) << prepared.detail;
  EXPECT_EQ(prepared.value->committed_policy_generation, 0u);
  const auto candidate = store.BuildPreparedCandidateSnapshot(*prepared.value);
  ASSERT_TRUE(candidate.value) << candidate.detail;
  const aegis_access::GenerationTuple generations{
      prepared.value->operation_sequence,
      CommitIdentityGenerationForProxyPolicy(),
      CommitSelectionGenerationForProxyPolicy(),
      transport_->network_epoch(), CurrentBaseProxyGeneration()};
  PublishSelectedProxyEndpoint(kTargetHost, generations);
  auto* runtime = AccessPublishedRequestRuntime::GetOrCreate(browser()->profile());
  ASSERT_EQ(runtime->PublishPreparedPolicyCandidate(*candidate.value).status,
            AccessPolicyPublicationStatus::kPublished);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), target_url()));
  EXPECT_TRUE(base::test::RunUntil([&] {
    return proxy_requests_.load(std::memory_order_relaxed) == 1u;
  }));
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), 0u);
  EXPECT_EQ(store.ReadCommittedSnapshot(owner_->storage_partition_token).status,
            StoreStatus::kRecoveryRequired);
  EXPECT_EQ(prepared.value->committed_policy_generation, 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       ConflictingSiteProxyGroupPreservesNavigationRoute) {
  PublishProxyPolicy(/*publish_endpoint=*/true);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), target_url()));
  auto* runtime = AccessPublishedRequestRuntime::Get(browser()->profile());
  ASSERT_TRUE(runtime);
  const auto* published = runtime->GetPublishedPolicySnapshot(*owner_);
  ASSERT_TRUE(published);
  const auto published_before = *published;
  auto store = std::make_unique<AccessRuleStore>(
      AccessRuleStoreTestPeer::Ephemeral(*owner_));
  ASSERT_EQ(store->Open(), StoreStatus::kValid);
  StoredAccessRule independent;
  independent.policy = published_before.rules.front();
  independent.source = StoredRuleSource::kTestFixture;
  independent.lifetime = StoredRuleLifetime::kPersistent;
  ASSERT_EQ(AccessRuleStoreTestPeer::Import(store.get(), independent),
            StoreStatus::kValid);
  auto request = PreparedNavigationRequest(*owner_);
  for (auto& member : request.candidate_members) {
    member.proxy_group_id = "conflicting-group";
  }
  const auto selector = CurrentSiteSelector();
  ASSERT_TRUE(selector);
  const auto selection_before = transport_->CurrentSelection(*owner_);
  auto* coordinator = AccessServiceCoordinator::GetOrCreate(browser()->profile());
  ASSERT_TRUE(coordinator);
  base::test::TestFuture<AccessMutationTransactionResult> result;
  coordinator->CommitSiteGroupMutation(std::move(store), request, *selector,
                                        result.GetCallback());
  ASSERT_TRUE(result.Wait());
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(result.Get().status,
            AccessMutationTransactionStatus::kUnsupportedTransportScope);
  EXPECT_EQ(*runtime->GetPublishedPolicySnapshot(*owner_), published_before);
  EXPECT_EQ(transport_->CurrentSelection(*owner_), selection_before);
  EXPECT_EQ(coordinator->state_generation(), 0u);
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_url().Resolve("/after-rejected-site-mutation")));
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/1u);
}

#if !BUILDFLAG(IS_CHROMEOS)
IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       MainNavigationRoutingIsolatedAcrossProfiles) {
  PublishProxyPolicy(/*publish_endpoint=*/true);

  size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_TRUE(ui_test_utils::NavigateToURL(browser(), target_url()));
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/1u);

  ProfileManager* profile_manager = g_browser_process->profile_manager();
  ASSERT_NE(profile_manager, nullptr);
  Profile* second_profile = &profiles::testing::CreateProfileSync(
      profile_manager, profile_manager->GenerateNextProfileDirectoryPath());
  ASSERT_NE(second_profile, nullptr);
  Browser* second_browser = CreateBrowser(second_profile);
  ASSERT_NE(second_browser, nullptr);

  origin_before = origin_requests_.load(std::memory_order_relaxed);
  proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  EXPECT_TRUE(ui_test_utils::NavigateToURL(second_browser, target_url()));
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
}
#endif

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SubframeNavigationWithoutPolicyPreservesNativePath) {
  NavigateNewIframe(target_url());
  EXPECT_TRUE(base::test::RunUntil([&] {
    return origin_requests_.load(std::memory_order_relaxed) == 1u;
  }));
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SubframeNavigationUsesPrimaryPageProxy) {
  PublishProxyPolicy(/*publish_endpoint=*/true);

  NavigateNewIframe(target_url());
  EXPECT_TRUE(base::test::RunUntil([&] {
    return proxy_requests_.load(std::memory_order_relaxed) == 1u;
  }));
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       PrefetchWithoutPolicyPreservesNativePath) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PreparePrefetchTest(&origin_before, &proxy_before);

  ASSERT_EQ(RunPrefetch(target_url()), "loaded");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       StartupMarkupPrefetchWithoutPolicyPreservesNativePath) {
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), target_origin_.GetURL(kTargetHost, "/startup-prefetch-page")));
  EXPECT_EQ(content::EvalJs(web_contents(), "window.prefetchDone")
                .ExtractString(),
            "loaded");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/2u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       PrefetchUsesSelectedProxy) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PreparePrefetchTest(&origin_before, &proxy_before);
  PublishProxyPolicy(/*publish_endpoint=*/true);

  ASSERT_EQ(RunPrefetch(target_url()), "loaded");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/1u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       TargetLoaderDisconnectWaitsForClientCompletion) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
  PublishProxyPolicy(/*publish_endpoint=*/true);
  auto* dispatch_state =
      AccessRequestDispatchState::GetOrCreate(browser()->profile());
  ASSERT_NE(dispatch_state, nullptr);
  // Navigation and automatic page requests can finish after NavigateToURL.
  // Establish an empty registry before asserting exact relay ownership
  // transitions; an unrelated completion could otherwise hide the new entry.
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return dispatch_state->ownership().size() == 0u; }))
      << "Previous request ownership did not quiesce";
  const size_t ownership_before = dispatch_state->ownership().size();
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  network::TestURLLoaderFactory terminal(/*observe_loader_requests=*/true);
  network::URLLoaderFactoryBuilder builder;
  AccessProxyingURLLoaderFactory::MaybeProxyDocumentSubresource(
      browser()->profile(), web_contents()->GetPrimaryMainFrame(),
      std::nullopt, builder);
  ASSERT_EQ(builder.num_interceptors(), 1u);
  scoped_refptr<network::SharedURLLoaderFactory> factory =
      std::move(builder).Finish(terminal.GetSafeWeakWrapper());

  const GURL completed_url = target_url().Resolve("/relay-complete");
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = completed_url;
  request->request_initiator = url::Origin::Create(worker_page_url());
  auto loader = network::SimpleURLLoader::Create(
      std::move(request), TRAFFIC_ANNOTATION_FOR_TESTS);
  base::test::TestFuture<std::optional<std::string>> result;
  loader->DownloadToStringOfUnboundedSizeUntilCrashAndDie(
      factory.get(), result.GetCallback());
  terminal.WaitForRequest(completed_url);
  ASSERT_EQ(terminal.NumPending(), 1);
  ASSERT_EQ(dispatch_state->ownership().size(), ownership_before + 1u);
  ASSERT_NE(terminal.pending_requests()->front().test_url_loader, nullptr);

  // The downstream control pipe closes before its independent client pipe
  // delivers OnComplete. This order must not turn a successful response into
  // a connection error or remove its ownership record prematurely.
  terminal.pending_requests()->front().test_url_loader.reset();
  base::RunLoop().RunUntilIdle();
  EXPECT_FALSE(result.IsReady());
  EXPECT_EQ(dispatch_state->ownership().size(), ownership_before + 1u);
  ASSERT_TRUE(terminal.SimulateResponseForPendingRequest(
      completed_url.spec(), "relay-ok"));
  ASSERT_TRUE(result.Wait());
  EXPECT_EQ(result.Get(), std::optional<std::string>("relay-ok"));
  EXPECT_EQ(loader->NetError(), net::OK);
  EXPECT_EQ(dispatch_state->ownership().size(), ownership_before);

  // A real downstream client disconnect without OnComplete still cleans up.
  const GURL disconnected_url = target_url().Resolve("/relay-disconnect");
  auto disconnected_request = std::make_unique<network::ResourceRequest>();
  disconnected_request->url = disconnected_url;
  disconnected_request->request_initiator =
      url::Origin::Create(worker_page_url());
  auto disconnected_loader = network::SimpleURLLoader::Create(
      std::move(disconnected_request), TRAFFIC_ANNOTATION_FOR_TESTS);
  base::test::TestFuture<std::optional<std::string>> disconnected_result;
  disconnected_loader->DownloadToStringOfUnboundedSizeUntilCrashAndDie(
      factory.get(), disconnected_result.GetCallback());
  terminal.WaitForRequest(disconnected_url);
  ASSERT_EQ(terminal.NumPending(), 1);
  EXPECT_EQ(dispatch_state->ownership().size(), ownership_before + 1u);
  terminal.pending_requests()->front().test_url_loader.reset();
  terminal.pending_requests()->front().client.reset();
  ASSERT_TRUE(disconnected_result.Wait());
  EXPECT_NE(disconnected_loader->NetError(), net::OK);
  EXPECT_EQ(dispatch_state->ownership().size(), ownership_before);
  // TestURLLoaderFactory retains manually disconnected pending requests.
  // Remove the consumed entry before WaitForRequest scans its client remote.
  ASSERT_EQ(terminal.pending_requests()->size(), 1u);
  terminal.pending_requests()->clear();

  // A BLOCK barrier must also terminate a request during the interval after
  // control-pipe disconnect but before client completion or watchdog expiry.
  const GURL blocked_url = target_url().Resolve("/relay-blocked");
  auto blocked_request = std::make_unique<network::ResourceRequest>();
  blocked_request->url = blocked_url;
  blocked_request->request_initiator = url::Origin::Create(worker_page_url());
  auto blocked_loader = network::SimpleURLLoader::Create(
      std::move(blocked_request), TRAFFIC_ANNOTATION_FOR_TESTS);
  base::test::TestFuture<std::optional<std::string>> blocked_result;
  blocked_loader->DownloadToStringOfUnboundedSizeUntilCrashAndDie(
      factory.get(), blocked_result.GetCallback());
  terminal.WaitForRequest(blocked_url);
  ASSERT_EQ(terminal.NumPending(), 1);
  ASSERT_EQ(dispatch_state->ownership().size(), ownership_before + 1u);
  terminal.pending_requests()->back().test_url_loader.reset();
  base::RunLoop().RunUntilIdle();
  ASSERT_FALSE(blocked_result.IsReady());
  EXPECT_EQ(dispatch_state->ownership().size(), ownership_before + 1u);

  aegis_access::RequestCancellationSelector selector;
  BuildCancellationSelector(blocked_url, &selector);
  const AccessBlockAndCancelResult barrier_result =
      dispatch_state->InstallBlockBarrierAndCancelMatching(
          {"relay-control-disconnected", 1, std::move(selector)});
  EXPECT_EQ(barrier_result.barrier_status,
            aegis_access::RequestDispatchBarrierStatus::kOk);
  EXPECT_EQ(barrier_result.cancellation_status,
            aegis_access::RequestOwnershipStatus::kOk);
  EXPECT_EQ(barrier_result.matched_requests, 1u);
  EXPECT_EQ(barrier_result.terminated_requests, 1u);
  ASSERT_TRUE(blocked_result.Wait());
  EXPECT_NE(blocked_loader->NetError(), net::OK);
  EXPECT_EQ(dispatch_state->ownership().size(), ownership_before);
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       PrefetchWithoutEndpointFailsClosed) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PreparePrefetchTest(&origin_before, &proxy_before);

  ASSERT_EQ(RunPrefetch(target_url().Resolve("/prefetch-endpoint-health")),
            "loaded");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);

  PublishProxyPolicy(/*publish_endpoint=*/false);
  origin_before = origin_requests_.load(std::memory_order_relaxed);
  proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  ASSERT_EQ(RunPrefetch(target_url().Resolve("/prefetch-no-endpoint")), "error");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       PrefetchUsesCurrentPolicyForNewUrls) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PreparePrefetchTest(&origin_before, &proxy_before);

  ASSERT_EQ(RunPrefetch(target_url().Resolve("/prefetch-before-policy")),
            "loaded");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);

  PublishProxyPolicy(/*publish_endpoint=*/true);
  origin_before = origin_requests_.load(std::memory_order_relaxed);
  proxy_before = proxy_requests_.load(std::memory_order_relaxed);
  ASSERT_EQ(RunPrefetch(target_url().Resolve("/prefetch-after-policy")),
            "loaded");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/1u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       BrowserProcessPrefetchWithoutPolicyPreservesNativePath) {
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);

  const std::optional<std::string> body =
      FetchBrowserProcessPrefetch(target_url());
  ASSERT_TRUE(body.has_value());
  EXPECT_EQ(*body, "origin");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       BrowserProcessPrefetchUsesSelectedProxy) {
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  PublishProxyPolicy(/*publish_endpoint=*/true);

  const std::optional<std::string> body =
      FetchBrowserProcessPrefetch(target_url());
  ASSERT_TRUE(body.has_value());
  EXPECT_EQ(*body, "proxy");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/1u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       BrowserProcessPrefetchWithoutEndpointFailsClosed) {
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  PublishProxyPolicy(/*publish_endpoint=*/false);

  EXPECT_FALSE(FetchBrowserProcessPrefetch(target_url()).has_value());
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(
    AccessProxyingURLLoaderFactoryBrowserTest,
    BrowserProcessPrefetchRedirectToUnselectedHostFailsClosed) {
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  PublishProxyPolicy(/*publish_endpoint=*/true);

  EXPECT_FALSE(
      FetchBrowserProcessPrefetch(unselected_redirect_url()).has_value());
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/1u);
}

IN_PROC_BROWSER_TEST_F(
    AccessProxyingURLLoaderFactoryBrowserTest,
    BrowserProcessPrefetchNonDefaultPartitionStaysNative) {
  Profile* profile = browser()->profile();
  const content::StoragePartitionConfig config =
      content::StoragePartitionConfig::Create(
          profile, "aegis-prefetch-test", "non-default",
          /*in_memory=*/true);
  content::StoragePartition* partition =
      profile->GetStoragePartition(config, /*can_create=*/true);
  ASSERT_NE(partition, nullptr);
  ASSERT_NE(partition, profile->GetDefaultStoragePartition());

  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  PublishProxyPolicy(/*publish_endpoint=*/true);

  const std::optional<std::string> body =
      FetchBrowserProcessPrefetchOnPartition(partition, target_url());
  ASSERT_TRUE(body.has_value());
  EXPECT_EQ(*body, "origin");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       WorkerMainResourceWithoutPolicyPreservesNativePath) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);

  EXPECT_EQ(RunWorkerMainScript(worker_script_url()), "origin");
  EXPECT_TRUE(base::test::RunUntil([&] {
    return origin_requests_.load(std::memory_order_relaxed) ==
           origin_before + 1u;
  }));
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       WorkerMainResourceUsesSelectedProxy) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  PublishProxyPolicy(/*publish_endpoint=*/true);

  EXPECT_EQ(RunWorkerMainScript(worker_script_url()), "proxy");
  EXPECT_TRUE(base::test::RunUntil([&] {
    return proxy_requests_.load(std::memory_order_relaxed) == 1u;
  }));
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), origin_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       WorkerMainResourceWithoutEndpointFailsClosed) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), worker_page_url()));
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  PublishProxyPolicy(/*publish_endpoint=*/false);

  EXPECT_EQ(RunWorkerMainScript(worker_script_url()), "error");
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), 0u);
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), origin_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       WorkerSubresourceWithoutPolicyPreservesNativePath) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PrepareWorkerSubresourceTest(&origin_before, &proxy_before);

  EXPECT_EQ(FetchWorkerSubresource(worker_subresource_url()),
            "origin-worker-subresource");
  EXPECT_TRUE(base::test::RunUntil([&] {
    return origin_requests_.load(std::memory_order_relaxed) ==
           origin_before + 1u;
  }));
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), proxy_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       WorkerSubresourceUsesSelectedProxy) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PrepareWorkerSubresourceTest(&origin_before, &proxy_before);
  PublishProxyPolicy(/*publish_endpoint=*/true);

  EXPECT_EQ(FetchWorkerSubresource(worker_subresource_url()),
            "proxy-worker-subresource");
  EXPECT_TRUE(base::test::RunUntil([&] {
    return proxy_requests_.load(std::memory_order_relaxed) ==
           proxy_before + 1u;
  }));
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), origin_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       WorkerSubresourceWithoutEndpointFailsClosed) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PrepareWorkerSubresourceTest(&origin_before, &proxy_before);
  PublishProxyPolicy(/*publish_endpoint=*/false);

  EXPECT_EQ(FetchWorkerSubresource(worker_subresource_url()), "error");
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), proxy_before);
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), origin_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SharedWorkerSubresourceWithoutPolicyPreservesNativePath) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PrepareSharedWorkerSubresourceTest(&origin_before, &proxy_before);

  EXPECT_EQ(FetchSharedWorkerSubresource(worker_subresource_url()),
            "origin-worker-subresource");
  EXPECT_TRUE(base::test::RunUntil([&] {
    return origin_requests_.load(std::memory_order_relaxed) ==
           origin_before + 1u;
  }));
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), proxy_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SharedWorkerSubresourceUsesSelectedProxy) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PrepareSharedWorkerSubresourceTest(&origin_before, &proxy_before);
  PublishProxyPolicy(/*publish_endpoint=*/true);

  EXPECT_EQ(FetchSharedWorkerSubresource(worker_subresource_url()),
            "proxy-worker-subresource");
  EXPECT_TRUE(base::test::RunUntil([&] {
    return proxy_requests_.load(std::memory_order_relaxed) ==
           proxy_before + 1u;
  }));
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), origin_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SharedWorkerSubresourceWithoutEndpointFailsClosed) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PrepareSharedWorkerSubresourceTest(&origin_before, &proxy_before);
  PublishProxyPolicy(/*publish_endpoint=*/false);

  EXPECT_EQ(FetchSharedWorkerSubresource(worker_subresource_url()), "error");
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), proxy_before);
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), origin_before);
}

IN_PROC_BROWSER_TEST_F(
    AccessProxyingURLLoaderFactoryBrowserTest,
    ServiceWorkerProcessScriptWithoutPolicyPreservesNativePath) {
  ASSERT_TRUE(
      ui_test_utils::NavigateToURL(browser(), service_worker_page_url()));

  ASSERT_EQ(StartServiceWorkerHarness(), "ready");
  EXPECT_EQ(ServiceWorkerScriptSource(), "origin-service-worker-script");
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       ServiceWorkerProcessScriptUsesSelectedProxy) {
  ASSERT_TRUE(
      ui_test_utils::NavigateToURL(browser(), service_worker_page_url()));
  PublishProxyPolicy(/*publish_endpoint=*/true, "localhost");

  ASSERT_EQ(StartServiceWorkerHarness(), "ready");
  EXPECT_EQ(ServiceWorkerScriptSource(), "proxy-service-worker-script");
  EXPECT_GT(proxy_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(
    AccessProxyingURLLoaderFactoryBrowserTest,
    ServiceWorkerBrowserProcessScriptStaysNativeBeforeProcessScriptFailsClosed) {
  ASSERT_TRUE(
      ui_test_utils::NavigateToURL(browser(), service_worker_page_url()));
  const size_t origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  PublishProxyPolicy(/*publish_endpoint=*/false, "localhost");

  ASSERT_EQ(StartServiceWorkerHarness(), "error");
  // The browser-process main script uses kInvalidUniqueID and stays native.
  // The subsequent process-backed importScripts() request is what fails closed.
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed),
            origin_before + 1u);
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(
    AccessProxyingURLLoaderFactoryBrowserTest,
    ServiceWorkerSubresourceWithoutPolicyPreservesNativePath) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PrepareServiceWorkerSubresourceTest(&origin_before, &proxy_before);

  EXPECT_EQ(FetchServiceWorkerSubresource(service_worker_subresource_url()),
            "resolved");
  EXPECT_TRUE(base::test::RunUntil([&] {
    return origin_requests_.load(std::memory_order_relaxed) ==
           origin_before + 1u;
  }));
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), proxy_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       ServiceWorkerSubresourceUsesSelectedProxy) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PrepareServiceWorkerSubresourceTest(&origin_before, &proxy_before);
  PublishProxyPolicy(/*publish_endpoint=*/true, "localhost");

  EXPECT_EQ(FetchServiceWorkerSubresource(service_worker_subresource_url()),
            "resolved");
  EXPECT_TRUE(base::test::RunUntil([&] {
    return proxy_requests_.load(std::memory_order_relaxed) ==
           proxy_before + 1u;
  }));
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), origin_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       ServiceWorkerSubresourceWithoutEndpointFailsClosed) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PrepareServiceWorkerSubresourceTest(&origin_before, &proxy_before);
  PublishProxyPolicy(/*publish_endpoint=*/false, "localhost");

  EXPECT_EQ(FetchServiceWorkerSubresource(service_worker_subresource_url()),
            "error");
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), proxy_before);
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), origin_before);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       RuntimePolicyUpdateRoutesExistingFactoryThroughProxy) {
  PublishProxyPolicy(/*publish_endpoint=*/true);

  EXPECT_TRUE(FetchTarget());
  EXPECT_TRUE(base::test::RunUntil([&] {
    return proxy_requests_.load(std::memory_order_relaxed) == 1u;
  }));
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       ProxyPolicyWithoutSelectedEndpointFailsClosed) {
  PublishProxyPolicy(/*publish_endpoint=*/false);

  EXPECT_FALSE(FetchTarget());
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), 0u);
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SameHostRedirectReevaluatesThroughProxy) {
  PublishProxyPolicy(/*publish_endpoint=*/true);

  EXPECT_TRUE(Fetch(redirect_url()));
  ExpectRedirectFollowedThroughProxy();
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       MainNavigationRedirectReevaluatesThroughProxy) {
  PublishProxyPolicy(/*publish_endpoint=*/true);

  EXPECT_TRUE(ui_test_utils::NavigateToURL(browser(), redirect_url()));
  ExpectRedirectFollowedThroughProxy();
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       SubframeNavigationRedirectReevaluatesThroughProxy) {
  PublishProxyPolicy(/*publish_endpoint=*/true);

  NavigateNewIframe(redirect_url());
  ExpectRedirectFollowedThroughProxy();
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       RedirectToUnselectedHostFailsClosed) {
  PublishProxyPolicy(/*publish_endpoint=*/true);

  EXPECT_FALSE(Fetch(unselected_redirect_url()));
  EXPECT_EQ(proxy_requests_.load(std::memory_order_relaxed), 1u);
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), 0u);
}

IN_PROC_BROWSER_TEST_F(AccessProxyingURLLoaderFactoryBrowserTest,
                       BlockBarrierTerminatesInFlightProxyRequest) {
  PublishProxyPolicy(/*publish_endpoint=*/true);
  StartPendingFetch(hanging_url());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return proxy_requests_.load(std::memory_order_relaxed) == 1u;
  }));
  EXPECT_EQ(PendingFetchState(), "pending");

  aegis_access::RequestCancellationSelector selector;
  BuildCancellationSelector(hanging_url(), &selector);
  auto* dispatch_state =
      AccessRequestDispatchState::GetOrCreate(browser()->profile());
  ASSERT_NE(dispatch_state, nullptr);
  const AccessBlockAndCancelResult result =
      dispatch_state->InstallBlockBarrierAndCancelMatching(
          {"block-browser-0136", 1, std::move(selector)});
  EXPECT_EQ(result.barrier_status,
            aegis_access::RequestDispatchBarrierStatus::kOk);
  EXPECT_EQ(result.cancellation_status,
            aegis_access::RequestOwnershipStatus::kOk);
  EXPECT_EQ(result.matched_requests, 1u);
  EXPECT_EQ(result.terminated_requests, 1u);
  EXPECT_EQ(dispatch_state->ownership().size(), 0u);

  EXPECT_TRUE(base::test::RunUntil(
      [&] { return PendingFetchState() == "blocked"; }));
  EXPECT_EQ(origin_requests_.load(std::memory_order_relaxed), 0u);
}

class LoadingPredictorPrefetchCompletion final
    : public predictors::PrefetchManager::Delegate,
      public predictors::PrefetchManager::Observer {
 public:
  LoadingPredictorPrefetchCompletion(const GURL& navigation_url,
                                     const GURL& resource_url)
      : navigation_url_(navigation_url), resource_url_(resource_url) {}

  base::WeakPtr<predictors::PrefetchManager::Delegate> GetDelegateWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }

  void PrefetchInitiated(const GURL& url, const GURL& prefetch_url) override {
    EXPECT_EQ(url, navigation_url_);
    EXPECT_EQ(prefetch_url, resource_url_);
    ++initiated_count_;
  }

  void PrefetchFinished(
      std::unique_ptr<predictors::PrefetchStats> stats) override {
    EXPECT_EQ(stats->url, navigation_url_);
    delegate_finished_ = true;
  }

  void OnPrefetchFinished(
      const GURL& url,
      const GURL& prefetch_url,
      const network::URLLoaderCompletionStatus& status) override {
    EXPECT_EQ(url, navigation_url_);
    EXPECT_EQ(prefetch_url, resource_url_);
    completion_error_ = status.error_code;
    ++completion_count_;
  }

  void OnAllPrefetchesFinished(const GURL& url) override {
    EXPECT_EQ(url, navigation_url_);
    all_done_.SetValue();
  }

  bool Wait() { return all_done_.Wait(); }
  size_t initiated_count() const { return initiated_count_; }
  size_t completion_count() const { return completion_count_; }
  bool delegate_finished() const { return delegate_finished_; }
  std::optional<int> completion_error() const { return completion_error_; }

 private:
  const GURL navigation_url_;
  const GURL resource_url_;
  size_t initiated_count_ = 0;
  size_t completion_count_ = 0;
  bool delegate_finished_ = false;
  std::optional<int> completion_error_;
  base::test::TestFuture<void> all_done_;
  base::WeakPtrFactory<LoadingPredictorPrefetchCompletion> weak_factory_{this};
};

class AccessLoadingPredictorPrefetchBrowserTest
    : public AccessProxyingURLLoaderFactoryBrowserTest {
 public:
  AccessLoadingPredictorPrefetchBrowserTest() {
    features_.InitWithFeatures(
        {features::kLoadingPredictorPrefetch,
         features::kPrefetchManagerUseNetworkContextPrefetch},
        {});
  }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    AccessProxyingURLLoaderFactoryBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch(
        switches::kLoadingPredictorAllowLocalRequestForTesting);
  }

 protected:
  std::optional<int> StartPrefetchAndWait(const GURL& resource_url) {
    const GURL navigation_url = web_contents()->GetLastCommittedURL();
    LoadingPredictorPrefetchCompletion completion(navigation_url, resource_url);
    predictors::PrefetchManager manager(completion.GetDelegateWeakPtr(),
                                        browser()->profile());
    manager.set_observer_for_testing(&completion);
    manager.Start(navigation_url,
                  {predictors::PrefetchRequest(
                      resource_url, network::mojom::RequestDestination::kScript)});
    if (!completion.Wait()) {
      ADD_FAILURE() << "PrefetchManager did not finish its production request";
      return std::nullopt;
    }
    EXPECT_EQ(completion.initiated_count(), 1u);
    EXPECT_EQ(completion.completion_count(), 1u);
    EXPECT_TRUE(completion.delegate_finished());
    return completion.completion_error();
  }

 private:
  base::test::ScopedFeatureList features_;
};

IN_PROC_BROWSER_TEST_F(AccessLoadingPredictorPrefetchBrowserTest,
                       WithoutPolicyPreservesNativePath) {
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  const std::optional<int> completion_error = StartPrefetchAndWait(target_url());
  ASSERT_TRUE(completion_error.has_value());
  EXPECT_EQ(*completion_error, net::OK);
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/1u,
                     /*proxy_delta=*/0u);
}

IN_PROC_BROWSER_TEST_F(AccessLoadingPredictorPrefetchBrowserTest,
                       UsesSelectedProxy) {
  PublishProxyPolicy(/*publish_endpoint=*/true);
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  const std::optional<int> completion_error = StartPrefetchAndWait(target_url());
  ASSERT_TRUE(completion_error.has_value());
  EXPECT_EQ(*completion_error, net::OK);
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/1u);
}

IN_PROC_BROWSER_TEST_F(AccessLoadingPredictorPrefetchBrowserTest,
                       WithoutEndpointFailsClosed) {
  // Prove this fixture can observe a completed origin request before checking
  // that a selected host with no endpoint sends nothing to either server.
  const size_t healthy_origin_before =
      origin_requests_.load(std::memory_order_relaxed);
  const size_t healthy_proxy_before =
      proxy_requests_.load(std::memory_order_relaxed);
  const std::optional<int> healthy_error = StartPrefetchAndWait(
      target_url().Resolve("/loading-predictor-health"));
  ASSERT_TRUE(healthy_error.has_value());
  ASSERT_EQ(*healthy_error, net::OK);
  ExpectRoutingDelta(healthy_origin_before, healthy_proxy_before,
                     /*origin_delta=*/1u, /*proxy_delta=*/0u);

  PublishProxyPolicy(/*publish_endpoint=*/false);
  const size_t origin_before = origin_requests_.load(std::memory_order_relaxed);
  const size_t proxy_before = proxy_requests_.load(std::memory_order_relaxed);

  const std::optional<int> completion_error = StartPrefetchAndWait(
      target_url().Resolve("/loading-predictor-blocked"));
  ASSERT_TRUE(completion_error.has_value());
  EXPECT_NE(*completion_error, net::OK);
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);
}

}  // namespace
}  // namespace aegis::access
