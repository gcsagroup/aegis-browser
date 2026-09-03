// Copyright 2026 GCSA

#include "chrome/common/aegis/aegis_net_throttle.h"

#include <string>
#include <string_view>

#include "chrome/common/aegis/cname_uncloak.h"
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

constexpr CnameCachePartitionId kProfileARegularPartition{1};
constexpr CnameCachePartitionId kProfileAOffTheRecordPartition{2};
constexpr CnameCachePartitionId kProfileBRegularPartition{3};
constexpr CnameCachePartitionId kProfileBOffTheRecordPartition{4};

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

class ScopedCnameCachePartitionReset {
 public:
  explicit ScopedCnameCachePartitionReset(CnameCachePartitionId partition_id)
      : partition_id_(partition_id) {
    CnameUncloakCache::GetInstance()->ClearPartition(partition_id_);
  }

  ScopedCnameCachePartitionReset(const ScopedCnameCachePartitionReset&) =
      delete;
  ScopedCnameCachePartitionReset& operator=(
      const ScopedCnameCachePartitionReset&) = delete;

  ~ScopedCnameCachePartitionReset() {
    CnameUncloakCache::GetInstance()->ClearPartition(partition_id_);
  }

 private:
  const CnameCachePartitionId partition_id_;
};

network::ResourceRequest SubresourceRequest(const GURL& url) {
  network::ResourceRequest request;
  request.url = url;
  request.destination = network::mojom::RequestDestination::kScript;
  return request;
}

TEST(AegisNetThrottleTest, BlocksTrackerSubresource) {
  AegisNetThrottle throttle(kProfileARegularPartition,
                            /*tracker_blocking_enabled=*/true,
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
  AegisNetThrottle throttle(kProfileARegularPartition,
                            /*tracker_blocking_enabled=*/true,
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
  AegisNetThrottle throttle(kProfileARegularPartition,
                            /*tracker_blocking_enabled=*/true,
                            /*cname_uncloak_enabled=*/true,
                            /*link_sanitize_enabled=*/true,
                            /*paused_sites=*/"shop.example|4102444800",
                            /*document_id=*/"doc-1");
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
  AegisNetThrottle throttle(kProfileARegularPartition,
                            /*tracker_blocking_enabled=*/false,
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
  ScopedCnameCachePartitionReset reset(kProfileARegularPartition);
  AegisNetThrottle throttle(kProfileARegularPartition,
                            /*tracker_blocking_enabled=*/true,
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

TEST(AegisNetThrottleTest, UnsupportedProfileReturnsNull) {
  EXPECT_FALSE(AegisNetThrottle::MaybeCreate(
      /*profile_supported=*/false, kProfileARegularPartition,
      /*tracker_blocking_enabled=*/true,
      /*cname_uncloak_enabled=*/true,
      /*link_sanitize_enabled=*/true));
}

TEST(AegisNetThrottleTest, InvalidPartitionReturnsNull) {
  EXPECT_FALSE(AegisNetThrottle::MaybeCreate(
      /*profile_supported=*/true, kInvalidCnameCachePartitionId,
      /*tracker_blocking_enabled=*/true,
      /*cname_uncloak_enabled=*/true,
      /*link_sanitize_enabled=*/true));
}

TEST(AegisNetThrottleTest, SupportedProfilesCreateThrottles) {
  EXPECT_TRUE(AegisNetThrottle::MaybeCreate(
      /*profile_supported=*/true, kProfileARegularPartition,
      /*tracker_blocking_enabled=*/true,
      /*cname_uncloak_enabled=*/true,
      /*link_sanitize_enabled=*/true));
  EXPECT_TRUE(AegisNetThrottle::MaybeCreate(
      /*profile_supported=*/true, kProfileAOffTheRecordPartition,
      /*tracker_blocking_enabled=*/true,
      /*cname_uncloak_enabled=*/true,
      /*link_sanitize_enabled=*/true));
}

TEST(CnameUncloakCacheTest, SeparatesProfilesAndClearsOnlyExactPartition) {
  ScopedCnameCachePartitionReset profile_a_regular_reset(
      kProfileARegularPartition);
  ScopedCnameCachePartitionReset profile_a_off_the_record_reset(
      kProfileAOffTheRecordPartition);
  ScopedCnameCachePartitionReset profile_b_regular_reset(
      kProfileBRegularPartition);
  ScopedCnameCachePartitionReset profile_b_off_the_record_reset(
      kProfileBOffTheRecordPartition);
  CnameUncloakCache* cache = CnameUncloakCache::GetInstance();

  constexpr std::string_view kHost = "metrics.shop.example";
  cache->RememberCloakedHost(kProfileARegularPartition, kHost,
                             "a-regular.tracker.example");
  cache->RememberCloakedHost(kProfileAOffTheRecordPartition, kHost,
                             "a-otr.tracker.example");
  cache->RememberCloakedHost(kProfileBRegularPartition, kHost,
                             "b-regular.tracker.example");
  cache->RememberCloakedHost(kProfileBOffTheRecordPartition, kHost,
                             "b-otr.tracker.example");

  EXPECT_EQ(cache->CloakedAlias(kProfileARegularPartition, kHost),
            "a-regular.tracker.example");
  EXPECT_EQ(cache->CloakedAlias(kProfileAOffTheRecordPartition, kHost),
            "a-otr.tracker.example");
  EXPECT_EQ(cache->CloakedAlias(kProfileBRegularPartition, kHost),
            "b-regular.tracker.example");
  EXPECT_EQ(cache->CloakedAlias(kProfileBOffTheRecordPartition, kHost),
            "b-otr.tracker.example");

  cache->ClearPartition(kProfileAOffTheRecordPartition);

  EXPECT_TRUE(cache->IsCloakedHost(kProfileARegularPartition, kHost));
  EXPECT_FALSE(cache->IsCloakedHost(kProfileAOffTheRecordPartition, kHost));
  EXPECT_TRUE(cache->IsCloakedHost(kProfileBRegularPartition, kHost));
  EXPECT_TRUE(cache->IsCloakedHost(kProfileBOffTheRecordPartition, kHost));
}

TEST(AegisNetThrottleTest, OffTheRecordCacheDoesNotLeakToRegularThrottle) {
  ScopedCnameCachePartitionReset regular_reset(kProfileARegularPartition);
  ScopedCnameCachePartitionReset off_the_record_reset(
      kProfileAOffTheRecordPartition);
  constexpr std::string_view kHost = "metrics.shop.example";
  CnameUncloakCache::GetInstance()->RememberCloakedHost(
      kProfileAOffTheRecordPartition, kHost, "stats.doubleclick.net");

  AegisNetThrottle regular_throttle(kProfileARegularPartition,
                                    /*tracker_blocking_enabled=*/true,
                                    /*cname_uncloak_enabled=*/true,
                                    /*link_sanitize_enabled=*/false);
  RecordingDelegate regular_delegate;
  regular_throttle.set_delegate(&regular_delegate);
  network::ResourceRequest regular_request =
      SubresourceRequest(GURL("https://metrics.shop.example/pixel"));
  bool defer = false;
  regular_throttle.WillStartRequest(&regular_request, &defer);
  EXPECT_EQ(regular_delegate.cancel_count, 0);

  AegisNetThrottle off_the_record_throttle(kProfileAOffTheRecordPartition,
                                           /*tracker_blocking_enabled=*/true,
                                           /*cname_uncloak_enabled=*/true,
                                           /*link_sanitize_enabled=*/false);
  RecordingDelegate off_the_record_delegate;
  off_the_record_throttle.set_delegate(&off_the_record_delegate);
  network::ResourceRequest off_the_record_request =
      SubresourceRequest(GURL("https://metrics.shop.example/pixel"));
  off_the_record_throttle.WillStartRequest(&off_the_record_request, &defer);
  EXPECT_EQ(off_the_record_delegate.cancel_count, 1);
}

}  // namespace
}  // namespace aegis
