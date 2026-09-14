// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_PLANNER_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_PLANNER_H_

#include "components/aegis_access/access_route_types.h"

namespace aegis_access {

// Produces a declarative route plan from an already matched policy and an
// immutable runtime snapshot. This function performs no I/O and never builds
// or reorders Chromium's native proxy configuration.
RoutePlan PlanAccessRoute(const RouteInput& input);

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_PLANNER_H_
