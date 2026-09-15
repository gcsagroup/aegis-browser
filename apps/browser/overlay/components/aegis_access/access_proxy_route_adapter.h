// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_PROXY_ROUTE_ADAPTER_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_PROXY_ROUTE_ADAPTER_H_

#include <cstdint>
#include <string>

#include "components/aegis_access/access_route_types.h"

namespace net {
class ProxyInfo;
}

namespace aegis_access {

enum class RegisteredProxyTransport {
  kHttp,
  kInvalid,
};

// Resolved by a trusted browser/network adapter from the opaque registration
// id carried by RoutePlan. V1's first network slice intentionally accepts only
// numeric loopback endpoints so policy decisions cannot inject arbitrary proxy
// destinations before the managed proxy runtime exists.
struct RegisteredProxyEndpoint {
  std::string registration_id;
  std::string proxy_group_id;
  OwnershipKey owner;
  GenerationTuple generations;
  RegisteredProxyTransport transport = RegisteredProxyTransport::kInvalid;
  std::string host;
  uint16_t port = 0;

  friend bool operator==(const RegisteredProxyEndpoint&,
                         const RegisteredProxyEndpoint&) = default;
};

enum class ProxyRouteApplyStatus {
  kPreservedNative,
  kAppliedProxy,
  kMustAbort,
  kInvalidEndpoint,
};

// Applies a previously validated route decision to Chromium's ProxyInfo.
//
// - kPreserveNative does not mutate |proxy_info|.
// - kUseRegisteredProxy replaces its proxy list with exactly one registered
//   loopback proxy, so there is no implicit DIRECT fallback.
// - kWait/kDeny/kFail clear the proxy list as a secondary no-DIRECT guard and
//   return kMustAbort. The caller must stop the request before network send;
//   ProxyDelegate callbacks cannot themselves surface a route-policy error.
//   A higher-level dispatcher may retry kWait after state changes.
//
// The endpoint is separately supplied by trusted registration state. Opaque
// ids in RoutePlan are never interpreted as host/port values. This first P0
// network slice accepts HTTP loopback only; SOCKS5 is a later acceptance item.
ProxyRouteApplyStatus ApplyRoutePlanToProxyInfo(
    const RoutePlan& plan,
    const RegisteredProxyEndpoint* endpoint,
    net::ProxyInfo* proxy_info);

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_PROXY_ROUTE_ADAPTER_H_
