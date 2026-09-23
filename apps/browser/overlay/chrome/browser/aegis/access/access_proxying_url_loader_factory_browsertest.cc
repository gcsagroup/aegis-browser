// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_proxying_url_loader_factory.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/run_loop.h"
#include "base/test/run_until.h"
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
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/storage_partition_config.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
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
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

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

std::unique_ptr<net::test_server::HttpResponse> CountAndReply(
    std::atomic<size_t>* counter,
    const char* body,
    const net::test_server::HttpRequest& request) {
  counter->fetch_add(1, std::memory_order_relaxed);
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_OK);
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
    host_resolver()->AddRule(kUnselectedRedirectHost, "127.0.0.1");

    target_origin_.RegisterRequestHandler(base::BindRepeating(
        &ServiceWorkerOriginReply, base::Unretained(&origin_requests_)));
    target_origin_.RegisterRequestHandler(base::BindRepeating(
        &CountAndReply, base::Unretained(&origin_requests_), "origin"));
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
            ".catch(() => { window.aegisFetchState = 'blocked'; });",
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
    request->destination = network::mojom::RequestDestination::kDocument;
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

  void PublishCommittedProxyRule(const std::string& destination_host) {
    aegis_access::AccessPolicyRule rule;
    rule.rule_id = "rule-browser-test";
    rule.owner = *owner_;
    rule.scope = aegis_access::PolicyScope::kProfile;
    rule.destination_host = destination_host;
    rule.schemes = {aegis_access::RequestScheme::kHttp};
    rule.ports.scope = aegis_access::PortScope::kAllBrowserPermitted;
    rule.mode = aegis_access::AccessMode::kProxy;
    rule.proxy_group_id = kProxyGroup;
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

    PublishCommittedProxyRule(destination_host);
    if (publish_endpoint) {
      PublishSelectedProxyEndpoint(destination_host, generations);
    }
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
                       MainNavigationWithoutPolicyPreservesNativePath) {
  EXPECT_TRUE(ui_test_utils::NavigateToURL(browser(), target_url()));
  EXPECT_TRUE(base::test::RunUntil([&] {
    return origin_requests_.load(std::memory_order_relaxed) == 1u;
  }));
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
                       PrefetchWithoutEndpointFailsClosed) {
  size_t origin_before = 0;
  size_t proxy_before = 0;
  PreparePrefetchTest(&origin_before, &proxy_before);
  PublishProxyPolicy(/*publish_endpoint=*/false);

  ASSERT_EQ(RunPrefetch(target_url()), "error");
  ExpectRoutingDelta(origin_before, proxy_before, /*origin_delta=*/0u,
                     /*proxy_delta=*/0u);
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

}  // namespace
}  // namespace aegis::access
