// Copyright 2026 GCSA
#include "services/network/aegis/access_route_wire.h"
#include "net/http/http_auth_cache.h"
#include "net/base/ip_address.h"

namespace network {
namespace {
using namespace aegis_access;
ChannelNamespace Channel(mojom::AegisAccessChannel value) {
  switch (value) {
    case mojom::AegisAccessChannel::kDev: return ChannelNamespace::kDev;
    case mojom::AegisAccessChannel::kAlpha: return ChannelNamespace::kAlpha;
    case mojom::AegisAccessChannel::kBeta: return ChannelNamespace::kBeta;
    case mojom::AegisAccessChannel::kRelease: return ChannelNamespace::kRelease;
  }
  return ChannelNamespace::kInvalid;
}
PolicyScope Scope(mojom::AegisAccessRuleScope value) {
  switch (value) {
    case mojom::AegisAccessRuleScope::kSite: return PolicyScope::kSite;
    case mojom::AegisAccessRuleScope::kProfile: return PolicyScope::kProfile;
    case mojom::AegisAccessRuleScope::kWebsite: return PolicyScope::kWebsite;
  }
  return PolicyScope::kInvalid;
}
RequestScheme Scheme(mojom::AegisAccessScheme value) {
  switch (value) {
    case mojom::AegisAccessScheme::kHttp: return RequestScheme::kHttp;
    case mojom::AegisAccessScheme::kHttps: return RequestScheme::kHttps;
    case mojom::AegisAccessScheme::kWs: return RequestScheme::kWs;
    case mojom::AegisAccessScheme::kWss: return RequestScheme::kWss;
  }
  return RequestScheme::kInvalid;
}
PortScope Ports(mojom::AegisAccessPortScope value) {
  switch (value) {
    case mojom::AegisAccessPortScope::kAllBrowserPermitted:
      return PortScope::kAllBrowserPermitted;
    case mojom::AegisAccessPortScope::kExplicitSubset:
      return PortScope::kExplicitSubset;
  }
  return PortScope::kInvalid;
}
AccessMode Mode(mojom::AegisAccessMode value) {
  switch (value) {
    case mojom::AegisAccessMode::kNone: return AccessMode::kNone;
    case mojom::AegisAccessMode::kDirect: return AccessMode::kDirect;
    case mojom::AegisAccessMode::kProxy: return AccessMode::kProxy;
    case mojom::AegisAccessMode::kReject: return AccessMode::kReject;
  }
  return AccessMode::kInvalid;
}
ProtectionOverride Protection(mojom::AegisAccessProtection value) {
  switch (value) {
    case mojom::AegisAccessProtection::kNone: return ProtectionOverride::kNone;
    case mojom::AegisAccessProtection::kTracker: return ProtectionOverride::kTracker;
    case mojom::AegisAccessProtection::kEasyList: return ProtectionOverride::kEasyList;
    case mojom::AegisAccessProtection::kCname: return ProtectionOverride::kCname;
  }
  return ProtectionOverride::kInvalid;
}
}  // namespace
std::optional<DecodedAccessRouteSnapshot> DecodeAccessRouteSnapshot(
    const mojom::AegisAccessSnapshot& wire) {
  if (!wire.owner || !wire.common_generations || wire.incarnation.empty() ||
      wire.sequence == 0) return std::nullopt;
  OwnershipKey owner{Channel(wire.owner->channel), wire.owner->profile_token,
                     wire.owner->storage_partition_token};
  if (!IsCompleteOwner(owner)) return std::nullopt;
  const auto& g = *wire.common_generations;
  AccessRouteRegistry::Snapshot snapshot{
      {owner, g.policy_generation, {}},
      {g.policy_generation, g.identity_generation, g.selection_generation,
       g.network_epoch, g.base_proxy_config_generation}, {}};
  for (const auto& rule : wire.rules) {
    if (!rule) return std::nullopt;
    AccessPolicyRule decoded{rule->rule_id, owner, Scope(rule->scope),
        rule->top_level_site, rule->destination_host, rule->include_subdomains, {},
        {Ports(rule->port_scope), rule->explicit_ports}, Mode(rule->mode),
        rule->proxy_group_id, Protection(rule->protection_override),
        rule->row_revision, rule->last_operation_sequence};
    for (const auto scheme : rule->schemes) decoded.schemes.push_back(Scheme(scheme));
    snapshot.policy.rules.push_back(std::move(decoded));
  }
  for (const auto& endpoint : wire.endpoints) {
    if (!endpoint) return std::nullopt;
    net::IPAddress address;
    if (!address.AssignFromIPLiteral(endpoint->numeric_loopback_host) ||
        !address.IsLoopback() || address.ToString() != endpoint->numeric_loopback_host ||
        endpoint->port == 0) return std::nullopt;
    net::AccessRouteIsolationKey key{static_cast<uint8_t>(owner.channel),
        owner.profile_token, owner.storage_partition_token, endpoint->proxy_group_id,
        endpoint->registration_id, wire.incarnation, g.policy_generation,
        g.identity_generation, endpoint->selection_generation, g.network_epoch,
        g.base_proxy_config_generation};
    auto proxy = net::ProxyServer::FromSchemeHostAndPort(
        net::ProxyServer::SCHEME_HTTP, endpoint->numeric_loopback_host, endpoint->port);
    auto route = net::AccessProxyRoute::Create(std::move(key), net::ProxyChain(proxy));
    if (!route) return std::nullopt;
    if (endpoint->credentials) {
      if (endpoint->credentials->username().empty() ||
          endpoint->credentials->password().empty()) return std::nullopt;
      // Xray's authenticated local HTTP inbound uses this fixed Basic realm.
      // The credentials are local inbound secrets, never upstream node values.
      route->proxy_auth_cache()->Add(
          url::SchemeHostPort(url::kHttpScheme, proxy.host_port_pair().host(),
                              proxy.host_port_pair().port()),
          net::HttpAuth::AUTH_PROXY, "proxy", net::HttpAuth::AUTH_SCHEME_BASIC,
          net::NetworkAnonymizationKey(), "Basic realm=\"proxy\"",
          *endpoint->credentials, "/");
    }
    if (!snapshot.routes.emplace(endpoint->proxy_group_id, std::move(route)).second)
      return std::nullopt;
  }
  for (const auto& group : wire.unavailable_groups) {
    if (!group ||
        !snapshot.unavailable_groups.emplace(group->proxy_group_id,
                                             group->selection_generation).second)
      return std::nullopt;
  }
  AccessRouteRegistry validator(owner, wire.incarnation);
  if (!validator.Install(wire.sequence, snapshot)) return std::nullopt;
  return DecodedAccessRouteSnapshot{std::move(owner), wire.incarnation,
                                    wire.sequence, std::move(snapshot)};
}
}  // namespace network
