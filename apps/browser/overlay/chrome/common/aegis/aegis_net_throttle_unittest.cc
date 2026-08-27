// Copyright 2026 GCSA

#include "chrome/common/aegis/aegis_net_throttle.h"

#include <string>
#include <string_view>

#include "net/base/net_errors.h"
#include "net/http/http_request_headers.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/http_request_headers_update_params.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/blink/public/common/loader/url_loader_throttle.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis {
namespace {

class RecordingDelegate : public blink::URLLoaderThrottle::Delegate {
 public:
  void CancelWithError(int error_code,
                       std::string_view custom_reason) override {
    ++cancel_count;
    last_error = error_code;
    last_reason = custom_reason;
  }

  void Resume() override { ++resume_count; }

  int cancel_count = 0;
  int resume_count = 0;
  int last_error = net::OK;
  std::string last_reason;
};

network::ResourceRequest SubresourceRequest(const GURL& url) {
  network::ResourceRequest request;
  request.url = url;
  request.destination = network::mojom::RequestDestination::kScript;
  return request;
}

TEST(AegisNetThrottleTest, BlocksTrackerSubresource) {
  AegisNetThrottle throttle(/*tracker_blocking_enabled=*/true,
                            /*cname_uncloak_enabled=*/false,
                            /*link_sanitize_enabled=*/false);
  RecordingDelegate delegate;
  throttle.set_delegate(&delegate);
  network::ResourceRequest request =
      SubresourceRequest(GURL("https://www.google-analytics.com/collect?v=2"));
  bool defer = false;

  throttle.WillStartRequest(&request, &defer);

  EXPECT_FALSE(defer);
  EXPECT_EQ(delegate.cancel_count, 1);
  EXPECT_EQ(delegate.last_error, net::ERR_BLOCKED_BY_CLIENT);
  EXPECT_EQ(delegate.last_reason, "AegisNetThrottle");
}

TEST(AegisNetThrottleTest, DoesNotBlockMainDocument) {
  AegisNetThrottle throttle(/*tracker_blocking_enabled=*/true,
                            /*cname_uncloak_enabled=*/true,
                            /*link_sanitize_enabled=*/false);
  RecordingDelegate delegate;
  throttle.set_delegate(&delegate);
  network::ResourceRequest request;
  request.url = GURL("https://www.google-analytics.com/collect?v=2");
  request.destination = network::mojom::RequestDestination::kDocument;
  bool defer = false;

  throttle.WillStartRequest(&request, &defer);

  EXPECT_EQ(delegate.cancel_count, 0);
}

TEST(AegisNetThrottleTest, PausedSiteSkipsBlockingAndSanitizing) {
  AegisNetThrottle throttle(
      /*tracker_blocking_enabled=*/true,
      /*cname_uncloak_enabled=*/true,
      /*link_sanitize_enabled=*/true,
      /*paused_sites=*/"shop.example|4102444800", /*document_id=*/"doc-1");
  RecordingDelegate delegate;
  throttle.set_delegate(&delegate);
  network::ResourceRequest request =
      SubresourceRequest(GURL("https://www.google-analytics.com/collect?v=2"));
  request.request_initiator = url::Origin::Create(GURL("https://shop.example"));
  request.referrer = GURL("https://shop.example/page?utm_source=mail&keep=1");
  bool defer = false;

  throttle.WillStartRequest(&request, &defer);

  EXPECT_EQ(delegate.cancel_count, 0);
  EXPECT_EQ(request.referrer.spec(),
            "https://shop.example/page?utm_source=mail&keep=1");
}

TEST(AegisNetThrottleTest, SanitizesReferrerAndRedirect) {
  AegisNetThrottle throttle(/*tracker_blocking_enabled=*/false,
                            /*cname_uncloak_enabled=*/false,
                            /*link_sanitize_enabled=*/true);
  RecordingDelegate delegate;
  throttle.set_delegate(&delegate);
  network::ResourceRequest request =
      SubresourceRequest(GURL("https://origin.example/script.js"));
  request.referrer =
      GURL("https://referrer.example/page?utm_source=mail&keep=1");
  bool defer = false;

  throttle.WillStartRequest(&request, &defer);

  EXPECT_EQ(request.referrer.spec(), "https://referrer.example/page?keep=1");
  const auto referer =
      request.headers.GetHeader(net::HttpRequestHeaders::kReferer);
  ASSERT_TRUE(referer.has_value());
  EXPECT_EQ(*referer, "https://referrer.example/page?keep=1");

  net::RedirectInfo redirect_info;
  redirect_info.new_url = GURL(
      "https://destination.example/path?fbclid=abc&keep=1"
      "#utm_campaign=spring");
  redirect_info.new_referrer = "https://referrer.example/next?gclid=abc&keep=2";
  network::mojom::URLResponseHead response_head;
  network::HttpRequestHeadersUpdateParams headers_update_params;

  throttle.WillRedirectRequest(&redirect_info, response_head, &defer,
                               &headers_update_params);

  EXPECT_EQ(redirect_info.new_url.spec(),
            "https://destination.example/path?keep=1");
  EXPECT_EQ(redirect_info.new_referrer, "https://referrer.example/next?keep=2");
  const auto redirected_referer =
      headers_update_params.modified_headers.GetHeader(
          net::HttpRequestHeaders::kReferer);
  ASSERT_TRUE(redirected_referer.has_value());
  EXPECT_EQ(*redirected_referer, "https://referrer.example/next?keep=2");
  EXPECT_EQ(delegate.cancel_count, 0);
}

TEST(AegisNetThrottleTest, BlocksCrossSiteTrackerCnameButNotSameSiteAlias) {
  AegisNetThrottle throttle(/*tracker_blocking_enabled=*/true,
                            /*cname_uncloak_enabled=*/true,
                            /*link_sanitize_enabled=*/false);
  RecordingDelegate delegate;
  throttle.set_delegate(&delegate);
  network::ResourceRequest request =
      SubresourceRequest(GURL("https://metrics.shop.com/pixel"));
  bool defer = false;
  throttle.WillStartRequest(&request, &defer);

  network::mojom::URLResponseHead same_site_response;
  same_site_response.dns_aliases = {"edge.shop.com."};
  throttle.WillProcessResponse(request.url, &same_site_response, &defer);
  EXPECT_EQ(delegate.cancel_count, 0);

  network::mojom::URLResponseHead tracker_response;
  tracker_response.dns_aliases = {"stats.doubleclick.net."};
  throttle.WillProcessResponse(request.url, &tracker_response, &defer);

  EXPECT_EQ(delegate.cancel_count, 1);
  EXPECT_EQ(delegate.last_error, net::ERR_BLOCKED_BY_CLIENT);
}

}  // namespace
}  // namespace aegis
