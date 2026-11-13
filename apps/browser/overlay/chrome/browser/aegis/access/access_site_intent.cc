// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_intent.h"

#include <algorithm>
#include <cctype>
#include <utility>

#include "base/strings/string_util.h"
#include "net/base/schemeful_site.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

bool HasUpperAscii(std::string_view text) {
  return std::ranges::any_of(
      text, [](unsigned char character) { return base::IsAsciiUpper(character); });
}

bool LooksLikeSchemeOrPath(std::string_view text) {
  return text.find("://") != std::string_view::npos ||
         text.find('/') != std::string_view::npos ||
         text.find('@') != std::string_view::npos ||
         text.find('\\') != std::string_view::npos;
}

bool IsCanonicalExactHostValue(std::string_view host) {
  if (host.empty() || host.back() == '.' || HasUpperAscii(host) ||
      LooksLikeSchemeOrPath(host) || host.find('\0') != std::string_view::npos) {
    return false;
  }
  const bool bracketed_ipv6 = host.front() == '[' && host.back() == ']';
  if (!bracketed_ipv6 && host.find(':') != std::string_view::npos) {
    return false;
  }
  const GURL url(std::string("https://") + std::string(host) + "/");
  return url.is_valid() && url.has_host() && url.host() == host;
}

std::string StripToHostCandidate(std::string_view raw) {
  std::string text = std::string(raw);
  base::TrimWhitespaceASCII(text, base::TRIM_ALL, &text);
  if (text.empty()) {
    return text;
  }

  const size_t at = text.find('@');
  if (at != std::string::npos) {
    text = text.substr(at + 1);
  }
  const size_t scheme = text.find("://");
  if (scheme != std::string::npos) {
    text = text.substr(scheme + 3);
  }
  const size_t slash = text.find('/');
  if (slash != std::string::npos) {
    text.resize(slash);
  }
  if (!text.empty() && text.front() == '[') {
    const size_t end = text.find(']');
    if (end != std::string::npos) {
      const std::string_view suffix = std::string_view(text).substr(end + 1);
      if (!suffix.empty() &&
          (suffix.front() != ':' || suffix.size() == 1 ||
           !std::ranges::all_of(suffix.substr(1), [](unsigned char character) {
             return base::IsAsciiDigit(character);
           }))) {
        return text;
      }
      text.resize(end + 1);
    }
  } else {
    const size_t colon = text.rfind(':');
    if (colon != std::string::npos) {
      const std::string_view port = std::string_view(text).substr(colon + 1);
      if (!port.empty() &&
          std::ranges::all_of(port, [](unsigned char character) {
            return base::IsAsciiDigit(character);
          })) {
        text.resize(colon);
      }
    }
  }
  while (!text.empty() && text.back() == '.') {
    text.pop_back();
  }
  return base::ToLowerASCII(text);
}

SiteProxyRuleMember MakeMember(const AccessSiteIntentMutationInput& input,
                               std::string_view rule_suffix,
                               std::string_view top_level_site,
                               aegis_access::AccessMode mode) {
  SiteProxyRuleMember member;
  member.rule_id = input.site_toggle_id + ":" + std::string(rule_suffix);
  member.owner = input.owner;
  member.site_toggle_id = input.site_toggle_id;
  member.group_revision = 0;
  member.top_level_site = std::string(top_level_site);
  member.exact_host = input.host.value;
  member.schemes = {RequestScheme::kHttp, RequestScheme::kHttps,
                    RequestScheme::kWs, RequestScheme::kWss};
  member.ports = PortScope::kAllBrowserPermitted;
  member.include_subdomains = false;
  member.mode = mode;
  member.proxy_group_id =
      mode == AccessMode::kProxy ? input.proxy_group_id : std::string();
  member.protection_override = ProtectionOverride::kNone;
  member.last_operation_sequence = 0;
  member.scope = input.website_context ? PolicyScope::kWebsite : PolicyScope::kSite;
  return member;
}

}  // namespace

AccessSiteIntentParseStatus ParseAccessSiteIntent(std::string_view raw,
                                                  AccessSiteIntent* out) {
  if (!out) {
    return AccessSiteIntentParseStatus::kUnknownIntent;
  }
  if (raw == "off") {
    *out = AccessSiteIntent::kOff;
    return AccessSiteIntentParseStatus::kOk;
  }
  if (raw == "allow") {
    *out = AccessSiteIntent::kAllow;
    return AccessSiteIntentParseStatus::kOk;
  }
  if (raw == "block") {
    *out = AccessSiteIntent::kBlock;
    return AccessSiteIntentParseStatus::kOk;
  }
  return AccessSiteIntentParseStatus::kUnknownIntent;
}

std::string_view AccessSiteIntentToString(AccessSiteIntent intent) {
  switch (intent) {
    case AccessSiteIntent::kOff:
      return "off";
    case AccessSiteIntent::kAllow:
      return "allow";
    case AccessSiteIntent::kBlock:
      return "block";
  }
  return "off";
}

AccessSiteHostResult MakeAccessSiteHost(std::string_view exact_host) {
  AccessSiteHostResult result;
  if (exact_host.empty()) {
    result.status = AccessSiteHostStatus::kEmpty;
    return result;
  }
  if (LooksLikeSchemeOrPath(exact_host)) {
    result.status = AccessSiteHostStatus::kContainsSchemeOrPath;
    return result;
  }
  if (!IsCanonicalExactHostValue(exact_host)) {
    result.status = AccessSiteHostStatus::kNotCanonical;
    return result;
  }
  result.status = AccessSiteHostStatus::kOk;
  result.host = AccessSiteHost{std::string(exact_host)};
  return result;
}

AccessSiteHostResult NormalizeAccessSiteHost(std::string_view raw) {
  return MakeAccessSiteHost(StripToHostCandidate(raw));
}
AccessSiteHostResult CanonicalWebsiteHost(const AccessSiteHost& host) {
  const auto checked = MakeAccessSiteHost(host.value);
  if (!checked.host) return checked;
  return MakeAccessSiteHost(net::SchemefulSite(GURL("https://" + host.value))
                                .GetURL().host());
}

std::optional<aegis_access::AccessMode> OrdinaryAccessModeForIntent(
    AccessSiteIntent intent) {
  switch (intent) {
    case AccessSiteIntent::kAllow:
      return AccessMode::kProxy;
    case AccessSiteIntent::kOff:
      return AccessMode::kDirect;
    case AccessSiteIntent::kBlock:
      return std::nullopt;
  }
  return std::nullopt;
}

AccessSiteIntentMutationResult BuildOrdinarySiteGroupMutation(
    const AccessSiteIntentMutationInput& input) {
  AccessSiteIntentMutationResult result;
  if (input.site_toggle_id.empty() || input.operation_id.empty() ||
      input.request_fingerprint.empty()) {
    result.status = AccessSiteIntentMutationStatus::kInvalidArgument;
    return result;
  }
  if (!aegis_access::IsCompleteOwner(input.owner)) {
    result.status = AccessSiteIntentMutationStatus::kInvalidOwner;
    return result;
  }
  if (MakeAccessSiteHost(input.host.value).status != AccessSiteHostStatus::kOk) {
    result.status = AccessSiteIntentMutationStatus::kInvalidHost;
    return result;
  }
  if (input.website_context && CanonicalWebsiteHost(input.host).host != input.host) {
    result.status = AccessSiteIntentMutationStatus::kInvalidHost;
    return result;
  }

  if (input.intent == AccessSiteIntent::kBlock) {
    result.status = AccessSiteIntentMutationStatus::kBlockNotOrdinary;
    return result;
  }

  const auto mode = OrdinaryAccessModeForIntent(input.intent);
  if (!mode) {
    result.status = AccessSiteIntentMutationStatus::kInvalidArgument;
    return result;
  }
  if (*mode == AccessMode::kProxy && input.proxy_group_id.empty()) {
    result.status = AccessSiteIntentMutationStatus::kMissingProxyGroup;
    return result;
  }
  if (*mode == AccessMode::kDirect && !input.proxy_group_id.empty()) {
    result.status = AccessSiteIntentMutationStatus::kInvalidArgument;
    return result;
  }

  // The rule still matches this exact destination host. Its top-level site
  // uses Chromium's registrable-site identity, as required by the store and
  // by the trusted request metadata (e.g. www.example.com -> example.com).
  const std::string http_site =
      net::SchemefulSite(GURL("http://" + input.host.value)).Serialize();
  const std::string https_site =
      net::SchemefulSite(GURL("https://" + input.host.value)).Serialize();

  SiteGroupMutationRequest request;
  request.operation_id = input.operation_id;
  request.request_fingerprint = input.request_fingerprint;
  request.expected_revision = input.expected_revision;
  request.candidate_group = {
      .site_toggle_id = input.site_toggle_id,
      .canonical_host = input.host.value,
      .owner = input.owner,
      .http_top_level_site = http_site,
      .https_top_level_site = https_site,
      .member_rule_ids = {input.site_toggle_id + ":http",
                          input.site_toggle_id + ":https"},
      .website_context = input.website_context,
  };
  request.candidate_members = {
      MakeMember(input, "http", http_site, *mode),
      MakeMember(input, "https", https_site, *mode),
  };

  result.status = AccessSiteIntentMutationStatus::kReady;
  result.ordinary_mode = mode;
  result.request = std::move(request);
  return result;
}

AccessSiteIntentStore::AccessSiteIntentStore() = default;
AccessSiteIntentStore::~AccessSiteIntentStore() = default;

AccessSiteIntent AccessSiteIntentStore::Get(const AccessSiteHost& host) const {
  const auto it = values_.find(host);
  return it == values_.end() ? AccessSiteIntent::kOff : it->second;
}

void AccessSiteIntentStore::Set(const AccessSiteHost& host,
                                AccessSiteIntent intent) {
  if (intent == AccessSiteIntent::kOff) {
    values_.erase(host);
    return;
  }
  values_[host] = intent;
}

}  // namespace aegis::access
