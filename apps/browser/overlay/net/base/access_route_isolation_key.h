// Copyright 2026 GCSA

#ifndef NET_BASE_ACCESS_ROUTE_ISOLATION_KEY_H_
#define NET_BASE_ACCESS_ROUTE_ISOLATION_KEY_H_

#include <compare>
#include <cstdint>
#include <string>

namespace net {

// A value identity for already-authorized Access requests, not an authorization
// capability. Network Service must validate its private request binding before
// supplying this key. Absence of a key preserves native pooling semantics.
// Keep this independent from NetworkAnonymizationKey and from chrome/components.
struct AccessRouteIsolationKey {
  uint8_t channel = 255;
  std::string profile;
  std::string partition;
  std::string group;
  std::string registration;
  std::string incarnation;
  uint64_t policy_generation = 0;
  uint64_t identity_generation = 0;
  uint64_t selection_generation = 0;
  uint64_t network_epoch = 0;
  uint64_t base_proxy_config_generation = 0;

  bool IsComplete() const {
    return channel <= 3 && !profile.empty() && !partition.empty() &&
           !group.empty() && !registration.empty() && !incarnation.empty() &&
           policy_generation != 0 && identity_generation != 0 &&
           selection_generation != 0 && network_epoch != 0 &&
           base_proxy_config_generation != 0;
  }
  bool operator==(const AccessRouteIsolationKey&) const = default;
  auto operator<=>(const AccessRouteIsolationKey&) const = default;
};

}  // namespace net

#endif  // NET_BASE_ACCESS_ROUTE_ISOLATION_KEY_H_
