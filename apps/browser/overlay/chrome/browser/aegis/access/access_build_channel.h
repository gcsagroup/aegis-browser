// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BUILD_CHANNEL_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_BUILD_CHANNEL_H_

#include <string_view>

#include "components/aegis_access/browser_request_metadata_seed.h"

namespace aegis::access {
// Explicit private test builds use their selected channel even when unbranded Chromium
// reports UNKNOWN. Chromium branding and the normal channel mapping are kept.
aegis_access::ChannelNamespace AccessChannelForCurrentBuild();
aegis_access::ChannelNamespace BundledAccessTestChannel();
const char* LocalAccessIdentityChannel(aegis_access::ChannelNamespace channel);

// Match the product channel, including explicit unbranded Alpha/Beta builds.
// Unrecognized builds keep the production logging baseline.
constexpr std::string_view DefaultCoreLogLevelForBuild(
    aegis_access::BrowserReleaseChannel channel,
    aegis_access::ChannelNamespace bundled_test_channel,
    bool dev_local_node_allowed = false) {
  switch (channel) {
    case aegis_access::BrowserReleaseChannel::kDev:
      return "debug";
    case aegis_access::BrowserReleaseChannel::kCanary:
      return "info";
    case aegis_access::BrowserReleaseChannel::kUnknown:
      if (bundled_test_channel == aegis_access::ChannelNamespace::kAlpha)
        return "info";
      // Unbranded Aegis always reports UNKNOWN. The existing trusted build
      // flag distinguishes ordinary local DEV builds from official Release;
      // an explicit private Beta identity still takes precedence.
      if (bundled_test_channel == aegis_access::ChannelNamespace::kInvalid &&
          dev_local_node_allowed)
        return "debug";
      return "warning";
    case aegis_access::BrowserReleaseChannel::kBeta:
    case aegis_access::BrowserReleaseChannel::kStable:
    case aegis_access::BrowserReleaseChannel::kInvalid:
      return "warning";
  }
  return "warning";
}

std::string_view DefaultCoreLogLevelForCurrentBuild();
}  // namespace aegis::access
#endif
