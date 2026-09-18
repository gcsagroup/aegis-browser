// Copyright 2026 GCSA

#include "components/aegis_access/request_policy_context.h"

#include <utility>

#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "url/url_constants.h"

namespace aegis_access {
namespace {

std::optional<RequestScheme> SchemeForUrl(const GURL& url) {
  if (url.SchemeIs(url::kHttpScheme)) {
    return RequestScheme::kHttp;
  }
  if (url.SchemeIs(url::kHttpsScheme)) {
    return RequestScheme::kHttps;
  }
  if (url.SchemeIs(url::kWsScheme)) {
    return RequestScheme::kWs;
  }
  if (url.SchemeIs(url::kWssScheme)) {
    return RequestScheme::kWss;
  }
  return std::nullopt;
}

RequestPolicyContextResult Error(RequestContextError error) {
  return RequestPolicyContextResult{error, std::nullopt};
}

bool IsUsableTopLevelSite(const net::SchemefulSite& site) {
  return !site.opaque() && site.GetURL().SchemeIsHTTPOrHTTPS() &&
         !site.Serialize().empty();
}

}  // namespace

RequestPolicyContext::RequestPolicyContext(
    std::string request_id,
    OwnershipKey owner,
    RequestAttributionKind attribution_kind,
    std::string document_token,
    std::string pending_navigation_token,
    bool site_ownership_reliable,
    std::string top_level_site,
    std::string exact_host,
    std::string registrable_domain,
    RequestScheme scheme,
    uint16_t port)
    : request_id_(std::move(request_id)),
      owner_(std::move(owner)),
      attribution_kind_(attribution_kind),
      document_token_(std::move(document_token)),
      pending_navigation_token_(std::move(pending_navigation_token)),
      site_ownership_reliable_(site_ownership_reliable),
      top_level_site_(std::move(top_level_site)),
      exact_host_(std::move(exact_host)),
      registrable_domain_(std::move(registrable_domain)),
      scheme_(scheme),
      port_(port) {}

RequestPolicyContext::RequestPolicyContext(const RequestPolicyContext&) =
    default;
RequestPolicyContext::RequestPolicyContext(RequestPolicyContext&&) noexcept =
    default;
RequestPolicyContext& RequestPolicyContext::operator=(
    const RequestPolicyContext&) = default;
RequestPolicyContext& RequestPolicyContext::operator=(
    RequestPolicyContext&&) noexcept = default;
RequestPolicyContext::~RequestPolicyContext() = default;

RequestOwnershipRecord RequestPolicyContext::ToOwnershipRecord(
    const GenerationTuple& generations) const {
  return RequestOwnershipRecord{
      request_id_,
      owner_,
      generations,
      document_token_,
      pending_navigation_token_,
      site_ownership_reliable_,
      top_level_site_,
      exact_host_,
      scheme_,
      port_};
}

RequestPolicyContextResult CanonicalizeBrowserOwnedRequest(
    const BrowserOwnedRequestMetadata& metadata,
    const GURL& request_url) {
  if (!IsCompleteOwner(metadata.owner)) {
    return Error(RequestContextError::kInvalidOwner);
  }
  if (metadata.request_id.empty()) {
    return Error(RequestContextError::kInvalidRequestId);
  }
  if (!request_url.is_valid()) {
    return Error(RequestContextError::kInvalidUrl);
  }
  const std::optional<RequestScheme> scheme = SchemeForUrl(request_url);
  if (!scheme.has_value()) {
    return Error(RequestContextError::kUnsupportedScheme);
  }
  if (request_url.host().empty()) {
    return Error(RequestContextError::kMissingHost);
  }
  const int effective_port = request_url.EffectiveIntPort();
  if (effective_port <= 0 || effective_port > 65535) {
    return Error(RequestContextError::kInvalidPort);
  }

  bool site_ownership_reliable = false;
  std::string top_level_site;
  switch (metadata.attribution_kind) {
    case RequestAttributionKind::kDocument:
      if (metadata.document_token.empty() ||
          !metadata.pending_navigation_token.empty() ||
          !metadata.top_frame_site.has_value()) {
        return Error(RequestContextError::kInvalidAttribution);
      }
      if (!IsUsableTopLevelSite(*metadata.top_frame_site)) {
        return Error(RequestContextError::kInvalidTopLevelSite);
      }
      site_ownership_reliable = true;
      top_level_site = metadata.top_frame_site->Serialize();
      break;
    case RequestAttributionKind::kPendingNavigation: {
      if (!metadata.document_token.empty() ||
          metadata.pending_navigation_token.empty()) {
        return Error(RequestContextError::kInvalidAttribution);
      }
      if (!request_url.SchemeIsHTTPOrHTTPS()) {
        return Error(RequestContextError::kInvalidTopLevelSite);
      }
      if (metadata.top_frame_site.has_value()) {
        if (!IsUsableTopLevelSite(*metadata.top_frame_site)) {
          return Error(RequestContextError::kInvalidTopLevelSite);
        }
        top_level_site = metadata.top_frame_site->Serialize();
      } else {
        const net::SchemefulSite pending_site(request_url);
        if (!IsUsableTopLevelSite(pending_site)) {
          return Error(RequestContextError::kInvalidTopLevelSite);
        }
        top_level_site = pending_site.Serialize();
      }
      site_ownership_reliable = true;
      break;
    }
    case RequestAttributionKind::kProfileOnly:
      if (!metadata.document_token.empty() ||
          !metadata.pending_navigation_token.empty() ||
          metadata.top_frame_site.has_value()) {
        return Error(RequestContextError::kInvalidAttribution);
      }
      break;
    case RequestAttributionKind::kInvalid:
      return Error(RequestContextError::kInvalidAttribution);
    default:
      return Error(RequestContextError::kInvalidAttribution);
  }

  const std::string registrable_domain =
      net::registry_controlled_domains::GetDomainAndRegistry(
          request_url,
          net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  return RequestPolicyContextResult{
      RequestContextError::kNone,
      RequestPolicyContext(
          metadata.request_id, metadata.owner, metadata.attribution_kind,
          metadata.document_token, metadata.pending_navigation_token,
          site_ownership_reliable, std::move(top_level_site),
          std::string(request_url.host()), registrable_domain, *scheme,
          static_cast<uint16_t>(effective_port))};
}

}  // namespace aegis_access
