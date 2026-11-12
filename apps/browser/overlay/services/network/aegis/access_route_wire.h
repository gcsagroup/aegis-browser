// Copyright 2026 GCSA
#ifndef SERVICES_NETWORK_AEGIS_ACCESS_ROUTE_WIRE_H_
#define SERVICES_NETWORK_AEGIS_ACCESS_ROUTE_WIRE_H_
#include <optional>
#include "services/network/aegis/access_route_registry.h"
#include "services/network/public/mojom/aegis_access_route_types.mojom.h"

namespace network {
struct DecodedAccessRouteSnapshot {
  aegis_access::OwnershipKey owner;
  std::string incarnation;
  uint64_t sequence;
  AccessRouteRegistry::Snapshot snapshot;
};
// Strict decode before touching the live registry. The caller must still apply
// Install on that registry to enforce its owner/incarnation and high-water.
std::optional<DecodedAccessRouteSnapshot> DecodeAccessRouteSnapshot(
    const mojom::AegisAccessSnapshot& wire);
}  // namespace network
#endif  // SERVICES_NETWORK_AEGIS_ACCESS_ROUTE_WIRE_H_
