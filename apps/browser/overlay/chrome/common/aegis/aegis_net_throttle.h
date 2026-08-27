// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/aegis_net_throttle.h

#ifndef CHROME_COMMON_AEGIS_AEGIS_NET_THROTTLE_H_
#define CHROME_COMMON_AEGIS_AEGIS_NET_THROTTLE_H_

#include <memory>
#include <vector>

#include "third_party/blink/public/common/loader/url_loader_throttle.h"
#include "url/gurl.h"

namespace aegis {

// Cancels subresource requests that match builtin + compiled EasyList hosts,
// including first-party hosts whose DNS CNAME chain points at a tracker.
// Also strips tracking decorations from Referer / redirect URLs.
// Registered from both browser and renderer throttle providers.
class AegisNetThrottle : public blink::URLLoaderThrottle {
 public:
  // Prefs 来自 profile（browser）或 DynamicParams（renderer）。
  static std::unique_ptr<blink::URLLoaderThrottle> MaybeCreate(
      bool tracker_blocking_enabled,
      bool cname_uncloak_enabled,
      bool link_sanitize_enabled);

  AegisNetThrottle(bool tracker_blocking_enabled,
                   bool cname_uncloak_enabled,
                   bool link_sanitize_enabled);
  AegisNetThrottle(const AegisNetThrottle&) = delete;
  AegisNetThrottle& operator=(const AegisNetThrottle&) = delete;
  ~AegisNetThrottle() override;

  // blink::URLLoaderThrottle:
  void DetachFromCurrentSequence() override;
  void WillStartRequest(network::ResourceRequest* request,
                        bool* defer) override;
  void WillRedirectRequest(
      net::RedirectInfo* redirect_info,
      const network::mojom::URLResponseHead& response_head,
      bool* defer,
      network::HttpRequestHeadersUpdateParams* headers_update_params) override;
  void WillProcessResponse(const GURL& response_url,
                           network::mojom::URLResponseHead* response_head,
                           bool* defer) override;

 private:
  void MaybeSanitizeReferrer(network::ResourceRequest* request);
  void MaybeSanitizeRedirect(net::RedirectInfo* redirect_info,
                             network::HttpRequestHeadersUpdateParams*
                                 headers_update_params);
  void MaybeBlock(const GURL& url);
  void MaybeBlockCloaked(const GURL& url,
                         const std::vector<std::string>& dns_aliases);
  void CancelAndReport(const GURL& url,
                       const std::string& reason,
                       const std::string& cname_alias);

  const bool tracker_blocking_enabled_;
  const bool cname_uncloak_enabled_;
  const bool link_sanitize_enabled_;
  bool is_main_document_ = false;
  GURL current_url_;
};

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_AEGIS_NET_THROTTLE_H_
