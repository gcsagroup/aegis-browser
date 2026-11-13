// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BUILD_CHANNEL_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BUILD_CHANNEL_H_

#include "components/aegis_access/access_route_types.h"

namespace aegis::access {
// Explicit private test builds use their selected channel even when unbranded Chromium
// reports UNKNOWN. Chromium branding and the normal channel mapping are kept.
aegis_access::ChannelNamespace AccessChannelForCurrentBuild();
aegis_access::ChannelNamespace BundledAccessTestChannel();
const char* LocalAccessIdentityChannel(aegis_access::ChannelNamespace channel);
}  // namespace aegis::access
#endif
