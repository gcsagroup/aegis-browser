// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BUILD_CHANNEL_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BUILD_CHANNEL_H_

#include "components/aegis_access/access_route_types.h"

namespace aegis::access {
// Explicit Alpha test builds use Alpha ownership even when unbranded Chromium
// reports UNKNOWN. Chromium branding and the normal channel mapping are kept.
aegis_access::ChannelNamespace AccessChannelForCurrentBuild();
}  // namespace aegis::access
#endif
