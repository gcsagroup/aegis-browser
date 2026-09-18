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
#include "base/test/run_until.h"
#include "chrome/browser/aegis/access/access_browser_request_adapter.h"
#include "chrome/browser/aegis/access/access_identity_generation_source.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/access/access_proxy_selection_generation_source.h"
#include "chrome/browser/aegis/access/access_published_request_runtime.h"
#include "chrome/browser/aegis/access/access_request_dispatch_state.h"
#include "chrome/browser/net/profile_network_context_service.h"
#include "chrome/browser/net/profile_network_context_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/aegis_access/access_identity_generation_state.h"
#include "components/aegis_access/access_proxy_selection_generation_state.h"
#include "components/aegis_access/request_policy_context.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test_utils.h"
#include "net/http/http_status_code.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_request.h"
#include "net/test/embedded_test_server/http_response.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

constexpr char kTargetHost[] = "target.example";
constexpr char kUnselectedRedirectHost[] = "redirect-unselected.example";
constexpr char kProxyGroup[] = "proxy-group-browser-test";

std::unique_ptr<net::test_server::HttpResponse> CountAndReply(
    std::atomic<size_t>* counter,
    const char* body,
    const net::test_server::HttpRequest&) {
  counter->fetch_add(1, std::memory_order_relaxed);
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_OK);
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
        &CountAndReply, base::Unretained(&origin_requests_), "origin"));
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

  void PublishProxyPolicy(bool publish_endpoint) {
    Profile* profile = browser()->profile();

    auto* identity = AccessIdentityGenerationSource::GetOrCreate(profile);
    ASSERT_NE(identity, nullptr);
    const auto identity_commit = identity->CommitIdentity(
        {aegis_access::AccessIdentityKind::kInstallationGuest,
         "guest-browser-test", "entitlement-browser-test", "dev", "access"});
    EXPECT_EQ(identity_commit.status,
              aegis_access::IdentityGenerationCommitStatus::kCommitted);

    auto* selection =
        AccessProxySelectionGenerationSource::GetOrCreate(profile);
    ASSERT_NE(selection, nullptr);
    const auto selection_commit = selection->CommitSelection(
        {kProxyGroup, "endpoint-browser-test", "lease-browser-test",
         "assignment-browser-test", 1});
    EXPECT_EQ(
        selection_commit.status,
        aegis_access::ProxySelectionGenerationCommitStatus::kCommitted);

    auto* network_service =
        ProfileNetworkContextServiceFactory::GetForContext(profile);
    EXPECT_NE(network_service, nullptr);
    const uint64_t base_proxy_generation =
        network_service ? network_service->GetAegisBaseProxyConfigGeneration()
                        : 0;
    EXPECT_GT(base_proxy_generation, 0u);

    aegis_access::AccessPolicyRule rule;
    rule.rule_id = "rule-browser-test";
    rule.owner = *owner_;
    rule.scope = aegis_access::PolicyScope::kProfile;
    rule.destination_host = kTargetHost;
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

    auto* runtime = AccessPublishedRequestRuntime::GetOrCreate(profile);
    EXPECT_NE(runtime, nullptr);
    const AccessPolicyPublicationResult publication =
        runtime->PublishCommittedPolicySnapshot(snapshot);
    EXPECT_EQ(publication.status, AccessPolicyPublicationStatus::kPublished);

    aegis_access::GenerationTuple generations{
        1,
        identity_commit.generation,
        selection_commit.generation,
        transport_->network_epoch(),
        base_proxy_generation,
    };

    if (publish_endpoint) {
      const aegis_access::RegisteredProxyEndpoint endpoint{
          "registration-browser-test", kProxyGroup, *owner_, generations,
          aegis_access::RegisteredProxyTransport::kHttp, "127.0.0.1",
          static_cast<uint16_t>(proxy_server_.port())};
      EXPECT_TRUE(transport_->PublishProxySelection(
          base::FilePath(), {kTargetHost}, endpoint));
      transport_->FlushClientsForTesting(base::FilePath());
    }

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
