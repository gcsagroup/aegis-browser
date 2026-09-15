// Copyright 2026 GCSA

#include "components/aegis_access/access_proxy_route_adapter.h"

#include <optional>

#include "net/base/proxy_chain.h"
#include "net/base/proxy_server.h"
#include "net/proxy_resolution/proxy_info.h"
#include "net/proxy_resolution/proxy_list.h"

namespace aegis_access {
namespace {

bool IsNumericLoopback(const std::string& host) {
  return host == "127.0.0.1" || host == "::1" || host == "[::1]";
}

net::ProxyServer::Scheme ToProxyScheme(RegisteredProxyTransport transport) {
  switch (transport) {
    case RegisteredProxyTransport::kHttp:
      return net::ProxyServer::SCHEME_HTTP;
    case RegisteredProxyTransport::kInvalid:
      return net::ProxyServer::SCHEME_INVALID;
  }
  return net::ProxyServer::SCHEME_INVALID;
}

bool MatchesPlan(const RegisteredProxyEntry& registration,
                 const RegisteredProxyEndpoint& endpoint) {
  return endpoint.registration_id == registration.registration_id &&
         endpoint.proxy_group_id == registration.proxy_group_id &&
         endpoint.owner == registration.owner &&
         endpoint.generations == registration.generations;
}

void BlockWithoutDirectFallback(net::ProxyInfo* proxy_info) {
  net::ProxyList empty;
  proxy_info->OverrideProxyList(empty);
}

std::optional<ProxyRouteApplyStatus> ApplyNonProxyRouteAction(
    const RoutePlan& plan,
    net::ProxyInfo* proxy_info) {
  switch (plan.action) {
    case RouteAction::kPreserveNative:
      if (plan.effective_mode == AccessMode::kNone ||
          plan.effective_mode == AccessMode::kDirect) {
        return ProxyRouteApplyStatus::kPreservedNative;
      }
      BlockWithoutDirectFallback(proxy_info);
      return ProxyRouteApplyStatus::kInvalidEndpoint;
    case RouteAction::kWait:
    case RouteAction::kDeny:
    case RouteAction::kFail:
      BlockWithoutDirectFallback(proxy_info);
      return ProxyRouteApplyStatus::kMustAbort;
    case RouteAction::kUseRegisteredProxy:
      return std::nullopt;
  }
  return ProxyRouteApplyStatus::kInvalidEndpoint;
}

bool IsPlanCompatibleWithEndpoint(const RoutePlan& plan,
                                  const RegisteredProxyEndpoint* endpoint) {
  if (plan.effective_mode != AccessMode::kProxy) {
    return false;
  }
  if (!plan.registered_proxy_entry.has_value()) {
    return false;
  }
  const RegisteredProxyEntry& registration = *plan.registered_proxy_entry;
  if (registration.registration_id.empty()) {
    return false;
  }
  if (registration.proxy_group_id.empty()) {
    return false;
  }
  if (plan.generations != registration.generations) {
    return false;
  }
  if (!endpoint) {
    return false;
  }
  if (!MatchesPlan(registration, *endpoint)) {
    return false;
  }
  if (!IsNumericLoopback(endpoint->host)) {
    return false;
  }
  return endpoint->port != 0;
}

std::optional<net::ProxyServer> BuildLoopbackProxyServer(
    const RegisteredProxyEndpoint& endpoint) {
  const net::ProxyServer::Scheme scheme = ToProxyScheme(endpoint.transport);
  if (scheme == net::ProxyServer::SCHEME_INVALID) {
    return std::nullopt;
  }
  net::ProxyServer server = net::ProxyServer::FromSchemeHostAndPort(
      scheme, endpoint.host, std::optional<uint16_t>(endpoint.port));
  if (!server.is_valid()) {
    return std::nullopt;
  }
  return server;
}

}  // namespace

ProxyRouteApplyStatus ApplyRoutePlanToProxyInfo(
    const RoutePlan& plan,
    const RegisteredProxyEndpoint* endpoint,
    net::ProxyInfo* proxy_info) {
  if (!proxy_info) {
    return ProxyRouteApplyStatus::kInvalidEndpoint;
  }

  if (std::optional<ProxyRouteApplyStatus> terminal_status =
          ApplyNonProxyRouteAction(plan, proxy_info)) {
    return *terminal_status;
  }

  if (!IsPlanCompatibleWithEndpoint(plan, endpoint)) {
    BlockWithoutDirectFallback(proxy_info);
    return ProxyRouteApplyStatus::kInvalidEndpoint;
  }

  std::optional<net::ProxyServer> server = BuildLoopbackProxyServer(*endpoint);
  if (!server.has_value()) {
    BlockWithoutDirectFallback(proxy_info);
    return ProxyRouteApplyStatus::kInvalidEndpoint;
  }

  net::ProxyList proxy_list;
  proxy_list.SetSingleProxyChain(net::ProxyChain(*server));
  proxy_info->OverrideProxyList(proxy_list);
  return ProxyRouteApplyStatus::kAppliedProxy;
}

}  // namespace aegis_access
