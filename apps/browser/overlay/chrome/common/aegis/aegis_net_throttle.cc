// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/aegis_net_throttle.cc

#include "chrome/common/aegis/aegis_net_throttle.h"

#include <string>
#include <utility>
#include <vector>

#include "base/feature_list.h"
#include "base/time/time.h"
#include "chrome/common/aegis/aegis_block_reporter.h"
#include "chrome/common/aegis/cname_uncloak.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/filter_list_matcher.h"
#include "chrome/common/aegis/site_control.h"
#include "chrome/common/aegis/tracking_query_params.h"
#include "net/base/net_errors.h"
#include "net/http/http_request_headers.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/http_request_headers_update_params.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr char kCancelReason[] = "AegisNetThrottle";

bool FeatureAllowsTrackerBlocking() {
  return base::FeatureList::IsEnabled(features::kAegisEnabled) &&
         base::FeatureList::IsEnabled(features::kAegisTrackerBlocking);
}

bool FeatureAllowsCnameUncloak() {
  return FeatureAllowsTrackerBlocking() &&
         base::FeatureList::IsEnabled(features::kAegisCnameUncloak);
}

bool FeatureAllowsLinkSanitize() {
  return base::FeatureList::IsEnabled(features::kAegisEnabled) &&
         base::FeatureList::IsEnabled(features::kAegisLinkSanitize);
}

bool IsMainDocumentRequest(const network::ResourceRequest& request) {
  return request.destination == network::mojom::RequestDestination::kDocument;
}

int64_t NowUnixSeconds() {
  return (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
}

}  // namespace

// static
std::unique_ptr<blink::URLLoaderThrottle> AegisNetThrottle::MaybeCreate(
    bool tracker_blocking_enabled,
    bool cname_uncloak_enabled,
    bool link_sanitize_enabled,
    std::string paused_sites,
    std::string document_id,
    std::string default_source_site) {
  const bool block = FeatureAllowsTrackerBlocking() && tracker_blocking_enabled;
  const bool sanitize = FeatureAllowsLinkSanitize() && link_sanitize_enabled;
  if (!block && !sanitize) {
    return nullptr;
  }
  const bool cname =
      block && FeatureAllowsCnameUncloak() && cname_uncloak_enabled;
  return std::make_unique<AegisNetThrottle>(
      block, cname, sanitize, std::move(paused_sites), std::move(document_id),
      std::move(default_source_site));
}

AegisNetThrottle::AegisNetThrottle(bool tracker_blocking_enabled,
                                   bool cname_uncloak_enabled,
                                   bool link_sanitize_enabled,
                                   std::string paused_sites,
                                   std::string document_id,
                                   std::string default_source_site)
    : tracker_blocking_enabled_(tracker_blocking_enabled),
      cname_uncloak_enabled_(cname_uncloak_enabled),
      link_sanitize_enabled_(link_sanitize_enabled),
      paused_sites_(std::move(paused_sites)),
      document_id_(std::move(document_id)),
      default_source_site_(std::move(default_source_site)) {}

AegisNetThrottle::~AegisNetThrottle() = default;

void AegisNetThrottle::DetachFromCurrentSequence() {}

void AegisNetThrottle::WillStartRequest(network::ResourceRequest* request,
                                        bool* /*defer*/) {
  current_url_ = request->url;
  is_main_document_ = IsMainDocumentRequest(*request);
  source_site_ = default_source_site_;
  if (request->request_initiator &&
      request->request_initiator->GetURL().has_host()) {
    source_site_ = std::string(request->request_initiator->host());
  }
  paused_for_site_ =
      IsSitePaused(paused_sites_, source_site_, NowUnixSeconds());
  if (paused_for_site_) {
    return;
  }
  MaybeSanitizeReferrer(request);
  if (is_main_document_) {
    return;
  }
  MaybeBlock(request->url);
  if (cname_uncloak_enabled_ && request->url.has_host() &&
      CnameUncloakCache::GetInstance()->IsCloakedHost(request->url.host())) {
    CancelAndReport(
        request->url, "cname",
        CnameUncloakCache::GetInstance()->CloakedAlias(request->url.host()));
  }
}

void AegisNetThrottle::WillRedirectRequest(
    net::RedirectInfo* redirect_info,
    const network::mojom::URLResponseHead& response_head,
    bool* /*defer*/,
    network::HttpRequestHeadersUpdateParams* headers_update_params) {
  if (paused_for_site_) {
    return;
  }
  MaybeBlockCloaked(current_url_, response_head.dns_aliases);
  MaybeSanitizeRedirect(redirect_info, headers_update_params);
  current_url_ = redirect_info->new_url;
  if (is_main_document_) {
    return;
  }
  MaybeBlock(redirect_info->new_url);
  if (cname_uncloak_enabled_ && redirect_info->new_url.has_host() &&
      CnameUncloakCache::GetInstance()->IsCloakedHost(
          redirect_info->new_url.host())) {
    CancelAndReport(redirect_info->new_url, "cname",
                    CnameUncloakCache::GetInstance()->CloakedAlias(
                        redirect_info->new_url.host()));
  }
}

void AegisNetThrottle::WillProcessResponse(
    const GURL& response_url,
    network::mojom::URLResponseHead* response_head,
    bool* /*defer*/) {
  if (paused_for_site_ || !response_head) {
    return;
  }
  MaybeBlockCloaked(response_url, response_head->dns_aliases);
}

void AegisNetThrottle::MaybeSanitizeReferrer(
    network::ResourceRequest* request) {
  if (!link_sanitize_enabled_ || !request) {
    return;
  }
  std::vector<std::string> removed;
  if (request->referrer.is_valid()) {
    const GURL cleaned =
        SanitizeTrackingDecorations(request->referrer, &removed);
    if (cleaned != request->referrer) {
      request->referrer = cleaned;
      request->headers.SetHeader(net::HttpRequestHeaders::kReferer,
                                 cleaned.spec());
      BlockReporter::ReportStrippedReferrer(
          std::string(cleaned.host()), removed, source_site_, document_id_);
    }
  }
}

void AegisNetThrottle::MaybeSanitizeRedirect(
    net::RedirectInfo* redirect_info,
    network::HttpRequestHeadersUpdateParams* headers_update_params) {
  if (!link_sanitize_enabled_ || !redirect_info) {
    return;
  }
  std::vector<std::string> url_removed;
  const GURL cleaned_url =
      SanitizeTrackingDecorations(redirect_info->new_url, &url_removed);
  if (cleaned_url != redirect_info->new_url) {
    redirect_info->new_url = cleaned_url;
    BlockReporter::ReportStrippedParams(std::string(cleaned_url.host()),
                                        url_removed, source_site_,
                                        document_id_);
  }

  if (redirect_info->new_referrer.empty()) {
    return;
  }
  const GURL referrer_url(redirect_info->new_referrer);
  if (!referrer_url.is_valid()) {
    return;
  }
  std::vector<std::string> ref_removed;
  const GURL cleaned_ref =
      SanitizeTrackingDecorations(referrer_url, &ref_removed);
  if (cleaned_ref == referrer_url) {
    return;
  }
  redirect_info->new_referrer = cleaned_ref.spec();
  if (headers_update_params) {
    headers_update_params->modified_headers.SetHeader(
        net::HttpRequestHeaders::kReferer, cleaned_ref.spec());
  }
  BlockReporter::ReportStrippedReferrer(
      std::string(cleaned_ref.host()), ref_removed, source_site_, document_id_);
}

void AegisNetThrottle::MaybeBlock(const GURL& url) {
  if (!tracker_blocking_enabled_) {
    return;
  }
  const BlockReason reason =
      FilterListMatcher::GetInstance()->ClassifyBlock(url);
  if (reason == BlockReason::kNone) {
    return;
  }
  CancelAndReport(url, BlockReasonToString(reason), std::string());
}

void AegisNetThrottle::MaybeBlockCloaked(
    const GURL& url,
    const std::vector<std::string>& dns_aliases) {
  if (is_main_document_ || !cname_uncloak_enabled_) {
    return;
  }
  std::string alias;
  if (!AliasesRevealTracker(url, dns_aliases, &alias)) {
    return;
  }
  if (url.has_host()) {
    CnameUncloakCache::GetInstance()->RememberCloakedHost(url.host(), alias);
  }
  CancelAndReport(url, "cname", alias);
}

void AegisNetThrottle::CancelAndReport(const GURL& url,
                                       const std::string& reason,
                                       const std::string& cname_alias) {
  delegate_->CancelWithError(net::ERR_BLOCKED_BY_CLIENT, kCancelReason);
  BlockReporter::ReportBlocked(url, reason, cname_alias, source_site_,
                               document_id_);
}

}  // namespace aegis
