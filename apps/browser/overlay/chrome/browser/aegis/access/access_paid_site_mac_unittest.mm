// Copyright 2026 GCSA
#import <Foundation/Foundation.h>

#include "chrome/browser/aegis/access/access_paid_site_mac.h"
#include "base/base64.h"
#include "base/json/json_writer.h"
#include "base/files/file_util.h"
#include "net/base/load_flags.h"
#include "net/http/access_proxy_route.h"
#include "net/log/test_net_log.h"
#include "net/proxy_resolution/proxy_info.h"
#include "base/files/scoped_temp_dir.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/sys_string_conversions.h"
#include "base/test/run_until.h"
#include "base/test/scoped_run_loop_timeout.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "crypto/hash.h"
#include "net/cert/test_root_certs.h"
#include "net/test/cert_test_util.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "net/url_request/url_request.h"
#include "net/url_request/url_request_context.h"
#include "net/url_request/url_request_context_builder.h"
#include "net/url_request/url_request_test_util.h"
#include "services/network/network_service_proxy_delegate.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "testing/gtest/include/gtest/gtest.h"

#include "chrome/browser/aegis/access/access_proxying_url_loader_factory.h"
#include "chrome/browser/aegis/access/access_site_proxy_bubble_controller.h"
#include "services/network/test/test_url_loader_client.h"
#include "services/network/test/test_url_loader_factory.h"
#include "base/test/test_future.h"

namespace aegis::access {
namespace {
class HeldAccountConfig : public network::mojom::CustomProxyConfigClient {
 public:
  explicit HeldAccountConfig(network::mojom::NetworkContextParams& params)
      : receiver(this, std::move(params.custom_proxy_config_client_receiver)) {}
  void OnCustomProxyConfigUpdated(network::mojom::CustomProxyConfigPtr,
                                  OnCustomProxyConfigUpdatedCallback callback) override {
    replies.push_back(std::move(callback));
  }
  void OnAegisAccessPolicyPublished(network::mojom::AegisAccessPolicyPublicationMetadataPtr,
                                    OnAegisAccessPolicyPublishedCallback callback) override {
    std::move(callback).Run(true);
  }
  std::vector<OnCustomProxyConfigUpdatedCallback> replies;
  mojo::Receiver<network::mojom::CustomProxyConfigClient> receiver;
};

TEST(PaidSiteMac, BrowserDispatchWaitsForCurrentConfigOnEveryPipe) {
  content::BrowserTaskEnvironment task;
  auto profile = TestingProfile::Builder().Build();
  network::mojom::NetworkContextParams params;
  ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(profile.get(), {}, &params));
  HeldAccountConfig first(params);
  auto* transport = AccessNetworkContextTransport::Get(profile.get());
  const auto owner = *transport->OwnerForPartition(aegis_access::ChannelNamespace::kDev, {});
  network::TestURLLoaderFactory origin;
  mojo::PendingRemote<network::mojom::URLLoaderFactory> target;
  origin.Clone(target.InitWithNewPipeAndPassReceiver());
  mojo::Remote<network::mojom::URLLoaderFactory> requests;
  AccessProxyingURLLoaderFactory wrapper(profile.get(), content::FrameTreeNodeId(1), {}, {}, nullptr, owner, {},
      requests.BindNewPipeAndPassReceiver(), std::move(target), {}, base::DoNothing());
  auto dispatch = [&](const char* address) {
    network::ResourceRequest request;
    request.url = GURL(address);
    origin.AddResponse(address, "origin received request");
    mojo::Remote<network::mojom::URLLoader> loader;
    network::TestURLLoaderClient client;
    requests->CreateLoaderAndStart(loader.BindNewPipeAndPassReceiver(), 1, 0, request,
        client.CreateRemote(), net::MutableNetworkTrafficAnnotationTag(TRAFFIC_ANNOTATION_FOR_TESTS));
    client.RunUntilComplete();
    return client.completion_status().error_code;
  };
  const char* selected = "https://paid.example./";
  ASSERT_TRUE(transport->SetAccountNodeSites({"paid.example"}, "", 0, ""));
  EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, dispatch(selected));
  EXPECT_EQ(net::OK, dispatch("https://sub.paid.example./"));
  ASSERT_EQ(first.replies.size(), 1u);
  ASSERT_TRUE(transport->SetAccountNodeSites({"paid.example"}, "node.test", 443, "Basic test"));
  std::move(first.replies[0]).Run();
  task.RunUntilIdle();
  EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, dispatch(selected));
  network::mojom::NetworkContextParams next;
  ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(profile.get(), {}, &next));
  HeldAccountConfig second(next);
  task.RunUntilIdle();
  ASSERT_EQ(first.replies.size(), 3u);
  ASSERT_EQ(second.replies.size(), 1u);
  std::move(first.replies[1]).Run();
  std::move(first.replies[2]).Run();
  task.RunUntilIdle();
  EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, dispatch(selected));
  std::move(second.replies[0]).Run();
  task.RunUntilIdle();
  EXPECT_EQ(net::OK, dispatch(selected));
  ASSERT_TRUE(transport->SetAccountNodeSites({}, "", 0, ""));
  task.RunUntilIdle();
  ASSERT_EQ(first.replies.size(), 4u);
  std::move(first.replies.back()).Run();
  second.receiver.reset();
  task.RunUntilIdle();
  EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, dispatch(selected));
}

TEST(PaidSiteMac, PaidWebsiteRejectsLocalErrorPageRetryForAliases) {
  content::BrowserTaskEnvironment task;
  auto profile = TestingProfile::Builder().Build();
  auto* transport = AccessNetworkContextTransport::GetOrCreate(profile.get());
  ASSERT_TRUE(transport->SetAccountNodeSites({"news.example.com"}, "", 0, ""));
  auto* controller = AccessSiteProxyBubbleController::GetOrCreate(profile.get());
  for (const char* url : {"https://news.example.com./", "https://cdn.example.com/"}) {
    base::test::TestFuture<bool> result;
    controller->RequestFailedNavigationProxy(GURL(url), result.GetCallback());
    EXPECT_FALSE(result.Get());
    EXPECT_EQ(AccessSiteConnectionState::kIdle,
              controller->SnapshotForCommittedUrl(GURL(url)).connection);
  }
}

TEST(PaidSiteMac, UnboundPrivateWindowPreservesConfiguredLocalNode) {
  content::BrowserTaskEnvironment task;
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  TestingProfile::Builder builder;
  builder.SetPath(temp.GetPath());
  auto profile = builder.Build();
  Profile* otr = profile->GetPrimaryOTRProfile(true);
  ASSERT_TRUE(otr);
  EXPECT_FALSE(UsesAccountNode(profile.get(), true));
  EXPECT_FALSE(UsesAccountNode(otr, true));
  EXPECT_TRUE(UsesAccountNode(otr, false));
  ASSERT_TRUE(base::WriteFile(temp.GetPath().AppendASCII("AegisAccessAccount.json"), "{}"));
  EXPECT_TRUE(UsesAccountNode(otr, true));
}

TEST(PaidSiteMac, CanonicalDnsHostIsExactWithOrWithoutRootDots) {
  content::BrowserTaskEnvironment task;
  auto profile = TestingProfile::Builder().Build();
  network::mojom::NetworkContextParams params;
  ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(profile.get(), {}, &params));
  auto* transport = AccessNetworkContextTransport::Get(profile.get());
  for (bool assigned : {true, false}) {
    ASSERT_TRUE(transport->SetAccountNodeSites({"example.com"}, assigned ? "node.test" : "",
                                               assigned ? 443 : 0, assigned ? "Basic fixture" : ""));
    const auto config = transport->BuildConfigForTesting({});
    for (const char* url : {"https://example.com", "https://example.com.",
                            "http://EXAMPLE.COM.:8080/path", "https://example.com..",
                            "wss://example.com%2E./socket"}) {
      SCOPED_TRACE(url);
      net::ProxyInfo result;
      config->rules.Apply(GURL(url), &result);
      EXPECT_FALSE(result.is_direct());
      if (!result.is_direct())
        EXPECT_EQ(result.proxy_chain().First().host_port_pair().host(),
                  assigned ? "node.test" : "blocked.invalid");
    }
    for (const char* url : {"https://sub.example.com.", "https://example.com.other.",
                            "http://notexample.com..", "wss://localhost/socket"}) {
      SCOPED_TRACE(url);
      net::ProxyInfo result;
      config->rules.Apply(GURL(url), &result);
      EXPECT_TRUE(result.is_direct());
    }
  }
}

TEST(PaidSiteMac, ExplicitLocalRouteAndBypassCannotReplaceSelectedAccountSite) {
  content::BrowserTaskEnvironment task(base::test::TaskEnvironment::MainThreadType::IO);
  auto profile = TestingProfile::Builder().Build();
  network::mojom::NetworkContextParams params;
  ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(profile.get(), {}, &params));
  auto* transport = AccessNetworkContextTransport::Get(profile.get());
  auto builder = net::CreateTestURLRequestContextBuilder();
  builder->set_proxy_delegate(std::make_unique<network::NetworkServiceProxyDelegate>(
      std::move(params.initial_custom_proxy_config), std::move(params.custom_proxy_config_client_receiver),
      mojo::PendingRemote<network::mojom::CustomProxyConnectionObserver>()));
  auto network = builder->Build();
  auto local = net::AccessProxyRoute::Create(
      {0, "profile", "partition", "group", "registration", "context", 1, 1, 1, 1, 1},
      net::ProxyChain(net::ProxyServer::FromSchemeHostAndPort(
          net::ProxyServer::SCHEME_HTTP, "127.0.0.1", 1)));
  ASSERT_TRUE(local);
  auto send = [&](const char* url, bool explicit_route) {
    net::TestDelegate result;
    auto request = network->CreateRequest(GURL(url), net::DEFAULT_PRIORITY, &result,
        TRAFFIC_ANNOTATION_FOR_TESTS, net::handles::kInvalidNetworkHandle);
    if (explicit_route) request->SetAccessProxyRoute(local);
    else request->SetLoadFlags(net::LOAD_BYPASS_PROXY);
    request->Start();
    result.RunUntilComplete();
    return result.request_status();
  };
  for (bool assigned : {true, false}) {
    ASSERT_TRUE(transport->SetAccountNodeSites({"paid.example"}, assigned ? "node.test" : "",
                                               assigned ? 443 : 0, assigned ? "Basic fixture" : ""));
    task.RunUntilIdle();
    EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, send("https://paid.example./", true));
    EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, send("https://paid.example./", false));
    EXPECT_EQ(net::ERR_PROXY_CONNECTION_FAILED, send("https://local.example/", true));
  }
}

// Optional wire fixture: the target accepts only traffic owned by its Xray
// peer and returns a known payload. No process-global trust changes.
enum class WireScenario { kShortRequest, kSlow, kDenyRenewal, kSignOut };

void RunAccountWire(WireScenario scenario) {
  NSDictionary* env = NSProcessInfo.processInfo.environment;
  if (!env[@"AEGIS_S3_HTTPS_URL"]) GTEST_SKIP() << "requires controlled node fixture";
  content::BrowserTaskEnvironment task(base::test::TaskEnvironment::MainThreadType::IO);
  const bool slow = scenario != WireScenario::kShortRequest;
  if (slow && !env[@"AEGIS_S3_LEASE_TTL_SECONDS"]) GTEST_SKIP() << "requires short lease fixture";
  base::test::ScopedRunLoopTimeout timeout(FROM_HERE, base::Minutes(1));
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  TestingProfile::Builder profile_builder;
  profile_builder.SetPath(temp.GetPath());
  auto profile = profile_builder.Build();
  auto path = temp.GetPath().AppendASCII("AegisAccessAccount.json");
  NSData* binding = [NSJSONSerialization dataWithJSONObject:@{
      @"origin":env[scenario == WireScenario::kDenyRenewal ? @"AEGIS_S3_RENEW_DENIED_ORIGIN" : @"AEGIS_S3_ORIGIN"], @"token":env[@"AEGIS_S3_TOKEN"],
      @"accountId":env[@"AEGIS_S3_ID"], @"generation":NSUUID.UUID.UUIDString }
      options:0 error:nil];
  ASSERT_TRUE(base::WriteFile(path, base::SysNSStringToUTF8([[NSString alloc] initWithData:binding encoding:NSUTF8StringEncoding])));
  ASSERT_TRUE(base::SetPosixFilePermissions(path, 0600));
  net::ScopedTestRoot root(net::ImportCertFromFile(
      base::FilePath(base::SysNSStringToUTF8(env[@"AEGIS_S3_CA_PEM"]))).get());
  network::mojom::NetworkContextParams params;
  ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(profile.get(), {}, &params));
  auto builder = net::CreateTestURLRequestContextBuilder();
  builder->set_proxy_delegate(std::make_unique<network::NetworkServiceProxyDelegate>(
      std::move(params.initial_custom_proxy_config), std::move(params.custom_proxy_config_client_receiver),
      mojo::PendingRemote<network::mojom::CustomProxyConnectionObserver>()));
  auto network = builder->Build();
  GURL configured_url(base::SysNSStringToUTF8(env[slow ? @"AEGIS_S3_SLOW_URL" : @"AEGIS_S3_HTTPS_URL"]));
  const std::string site(configured_url.host());
  const std::string rooted_host = site + ".";
  GURL::Replacements rooted;
  rooted.SetHostStr(rooted_host);
  const GURL url = configured_url.ReplaceComponents(rooted);
  ASSERT_TRUE(UsesAccountNode(profile.get()));
  // Same entry point invoked by the sole trusted toolbar toggle.
  ToggleAccountNodeSite(profile.get(), site);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return AccountNodeForSite(profile.get(), site) == AccountNodeStatus::kAssigned;
  }));
  task.RunUntilIdle();
  net::RecordingNetLogObserver diagnostics(net::NetLogCaptureMode::kEverything);
  const auto authorization = AccessNetworkContextTransport::Get(profile.get())
      ->BuildConfigForTesting({})->connect_tunnel_headers.GetHeader("Proxy-Authorization");
  ASSERT_TRUE(authorization.has_value());
  net::TestDelegate result;
  auto request = network->CreateRequest(url, net::DEFAULT_PRIORITY, &result,
                                        TRAFFIC_ANNOTATION_FOR_TESTS, net::handles::kInvalidNetworkHandle);
  const auto start = base::TimeTicks::Now();
  request->Start();
  if (scenario == WireScenario::kSignOut) {
    base::RunLoop finished;
    result.set_on_complete(finished.QuitClosure());
    ASSERT_TRUE(base::test::RunUntil([&] { return !result.data_received().empty(); }));
    ASSERT_TRUE(base::DeleteFile(path));
    finished.Run();
  } else {
    result.RunUntilComplete();
  }
  if (slow) {
    const auto elapsed = base::TimeTicks::Now() - start;
    const auto ttl = base::Seconds([env[@"AEGIS_S3_LEASE_TTL_SECONDS"] intValue]);
    ASSERT_EQ(200, request->GetResponseCode());
    if (scenario == WireScenario::kSlow) {
      EXPECT_GT(elapsed, ttl * 2);
      EXPECT_EQ(net::OK, result.request_status());
      EXPECT_EQ(base::HexEncodeLower(crypto::hash::Sha256(result.data_received())),
                base::SysNSStringToUTF8(env[@"AEGIS_S3_SLOW_SHA256"]));
      EXPECT_EQ(AccountNodeStatus::kAssigned, AccountNodeForSite(profile.get(), site));
    } else {
      EXPECT_NE(net::OK, result.request_status());
      EXPECT_GT(result.data_received().size(), 0u);
      EXPECT_LT(result.data_received().size(), 409600u);
      EXPECT_LT(elapsed, ttl * 2);
      EXPECT_EQ(AccountNodeStatus::kUnavailable, AccountNodeForSite(profile.get(), site));
    }
    ToggleAccountNodeSite(profile.get(), site);
    return;
  }
  ASSERT_EQ(net::OK, result.request_status());
  ASSERT_EQ(200, request->GetResponseCode());
  EXPECT_EQ(base::HexEncodeLower(crypto::hash::Sha256(result.data_received())),
            base::SysNSStringToUTF8(env[@"AEGIS_S3_EXPECTED_SHA256"]));
  std::map<uint32_t, std::string> socket_bytes;
  for (const auto& entry : diagnostics.GetEntries()) {
    const std::string json = base::WriteJson(entry.params).value_or("");
    EXPECT_FALSE(json.contains(*authorization));
    if (const auto* bytes = entry.params.FindString("bytes")) {
      std::string decoded;
      if (base::Base64Decode(*bytes, &decoded)) socket_bytes[entry.source.id] += decoded;
    }
  }
  for (const auto& [id, bytes] : socket_bytes) EXPECT_FALSE(bytes.contains(*authorization));
  ToggleAccountNodeSite(profile.get(), "second.example");
  EXPECT_EQ(AccountNodeStatus::kAcquiring, AccountNodeForSite(profile.get(), "second.example"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return AccountNodeForSite(profile.get(), "second.example") == AccountNodeStatus::kAssigned;
  }));
  ASSERT_TRUE(base::DeleteFile(path));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return AccountNodeForSite(profile.get(), site) == AccountNodeStatus::kUnavailable;
  }));
  task.RunUntilIdle();
  net::TestDelegate denied;
  auto retry = network->CreateRequest(url, net::DEFAULT_PRIORITY, &denied, TRAFFIC_ANNOTATION_FOR_TESTS, net::handles::kInvalidNetworkHandle);
  retry->Start();
  denied.RunUntilComplete();
  EXPECT_NE(net::OK, denied.request_status());
  ASSERT_EQ(AccountNodeStatus::kUnavailable, AccountNodeForSite(profile.get(), "second.example"));
  ToggleAccountNodeSite(profile.get(), "second.example");
  ToggleAccountNodeSite(profile.get(), "second.example");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return AccountNodeForSite(profile.get(), "second.example") == AccountNodeStatus::kUnavailable;
  }));
  auto blocked = AccessNetworkContextTransport::Get(profile.get())->BuildConfigForTesting({});
  for (const auto& host : {site, std::string("second.example")}) {
    net::ProxyInfo info;
    blocked->rules.Apply(GURL("https://" + host), &info);
    ASSERT_FALSE(info.is_direct());
    EXPECT_EQ("blocked.invalid", info.proxy_chain().First().GetHost());
  }
  ASSERT_TRUE(base::WriteFile(path, base::SysNSStringToUTF8(
      [[NSString alloc] initWithData:binding encoding:NSUTF8StringEncoding])));
  ASSERT_TRUE(base::SetPosixFilePermissions(path, 0600));
  // Only re-enable the second site. Both share the newly issued grant.
  ToggleAccountNodeSite(profile.get(), "second.example");
  ToggleAccountNodeSite(profile.get(), "second.example");
  ASSERT_EQ(AccountNodeStatus::kAcquiring, AccountNodeForSite(profile.get(), site));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return AccountNodeForSite(profile.get(), site) == AccountNodeStatus::kAssigned &&
        AccountNodeForSite(profile.get(), "second.example") == AccountNodeStatus::kAssigned;
  }));
  const auto replacement = AccessNetworkContextTransport::Get(profile.get())
      ->BuildConfigForTesting({})->connect_tunnel_headers.GetHeader("Proxy-Authorization");
  ASSERT_TRUE(replacement.has_value());
  EXPECT_FALSE(*replacement == *authorization);
  net::TestDelegate recovered;
  auto restored = network->CreateRequest(url, net::DEFAULT_PRIORITY, &recovered,
      TRAFFIC_ANNOTATION_FOR_TESTS, net::handles::kInvalidNetworkHandle);
  // A second wire receipt must come from the node, independent of the first
  // URLRequest's still-live HTTP cache entry.
  restored->SetLoadFlags(net::LOAD_DISABLE_CACHE);
  restored->Start();
  recovered.RunUntilComplete();
  EXPECT_EQ(net::OK, recovered.request_status());
  EXPECT_EQ(200, restored->GetResponseCode());
  ToggleAccountNodeSite(profile.get(), "second.example");
  ToggleAccountNodeSite(profile.get(), site);
}
TEST(PaidSiteMac, ChromiumConnectThroughAssignedNode) {
  RunAccountWire(WireScenario::kShortRequest);
}
TEST(PaidSiteMac, ActiveDownloadSurvivesLeaseRenewals) {
  RunAccountWire(WireScenario::kSlow);
}
TEST(PaidSiteMac, DeniedRenewalStopsActiveDownload) {
  RunAccountWire(WireScenario::kDenyRenewal);
}
TEST(PaidSiteMac, SignOutRevokesActiveDownload) {
  RunAccountWire(WireScenario::kSignOut);
}
}  // namespace
}  // namespace aegis::access
