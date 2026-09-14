// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_POLICY_CONTEXT_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_POLICY_CONTEXT_H_

#include <cstdint>
#include <optional>
#include <string>

#include "components/aegis_access/access_route_types.h"
#include "components/aegis_access/site_proxy_rule_group.h"
#include "net/base/schemeful_site.h"
#include "url/gurl.h"

namespace aegis_access {

enum class RequestAttributionKind {
  kDocument,
  kPendingNavigation,
  kProfileOnly,
  kInvalid,
};

// This metadata must be supplied by the browser-side ownership adapter. It is
// deliberately not a wire format and must never be populated from renderer or
// page-provided Profile/partition identifiers.
struct BrowserOwnedRequestMetadata {
  std::string request_id;
  OwnershipKey owner;
  RequestAttributionKind attribution_kind = RequestAttributionKind::kInvalid;
  std::string document_token;
  std::string pending_navigation_token;
  std::optional<net::SchemefulSite> top_frame_site;
};

enum class RequestContextError {
  kNone,
  kInvalidOwner,
  kInvalidRequestId,
  kInvalidAttribution,
  kInvalidUrl,
  kUnsupportedScheme,
  kMissingHost,
  kInvalidPort,
  kInvalidTopLevelSite,
};

struct RequestPolicyContextResult;

// Immutable normalized context. Construction is restricted to the native
// adapter below so policy matching cannot consume arbitrary string fields.
class RequestPolicyContext {
 public:
  RequestPolicyContext(const RequestPolicyContext&);
  RequestPolicyContext(RequestPolicyContext&&) noexcept;
  RequestPolicyContext& operator=(const RequestPolicyContext&);
  RequestPolicyContext& operator=(RequestPolicyContext&&) noexcept;
  ~RequestPolicyContext();

  const std::string& request_id() const { return request_id_; }
  const OwnershipKey& owner() const { return owner_; }
  RequestAttributionKind attribution_kind() const {
    return attribution_kind_;
  }
  const std::string& document_token() const { return document_token_; }
  const std::string& pending_navigation_token() const {
    return pending_navigation_token_;
  }
  bool site_ownership_reliable() const { return site_ownership_reliable_; }
  const std::string& top_level_site() const { return top_level_site_; }
  const std::string& exact_host() const { return exact_host_; }
  const std::string& registrable_domain() const {
    return registrable_domain_;
  }
  RequestScheme scheme() const { return scheme_; }
  uint16_t port() const { return port_; }

 private:
  friend RequestPolicyContextResult CanonicalizeBrowserOwnedRequest(
      const BrowserOwnedRequestMetadata& metadata,
      const GURL& request_url);

  RequestPolicyContext(std::string request_id,
                       OwnershipKey owner,
                       RequestAttributionKind attribution_kind,
                       std::string document_token,
                       std::string pending_navigation_token,
                       bool site_ownership_reliable,
                       std::string top_level_site,
                       std::string exact_host,
                       std::string registrable_domain,
                       RequestScheme scheme,
                       uint16_t port);

  std::string request_id_;
  OwnershipKey owner_;
  RequestAttributionKind attribution_kind_;
  std::string document_token_;
  std::string pending_navigation_token_;
  bool site_ownership_reliable_;
  std::string top_level_site_;
  std::string exact_host_;
  std::string registrable_domain_;
  RequestScheme scheme_;
  uint16_t port_;
};

struct RequestPolicyContextResult {
  RequestContextError error = RequestContextError::kInvalidAttribution;
  std::optional<RequestPolicyContext> context;
};

// Canonicalizes URL and site fields using Chromium's pinned GURL,
// SchemefulSite and public/private suffix implementations. It performs no I/O
// and does not turn syntactically valid renderer data into trusted ownership;
// callers must source metadata from a browser-owned registry or navigation.
RequestPolicyContextResult CanonicalizeBrowserOwnedRequest(
    const BrowserOwnedRequestMetadata& metadata,
    const GURL& request_url);

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_POLICY_CONTEXT_H_
