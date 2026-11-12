// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_build_channel.h"

#include "chrome/browser/aegis/access/access_buildflags.h"
#include "chrome/common/channel_info.h"
#include "components/aegis_access/browser_request_metadata_seed.h"
#include "components/version_info/channel.h"

namespace aegis::access {
namespace {
aegis_access::BrowserReleaseChannel BrowserReleaseChannel() {
  switch (chrome::GetChannel()) {
    case version_info::Channel::STABLE:
      return aegis_access::BrowserReleaseChannel::kStable;
    case version_info::Channel::BETA:
      return aegis_access::BrowserReleaseChannel::kBeta;
    case version_info::Channel::DEV:
      return aegis_access::BrowserReleaseChannel::kDev;
    case version_info::Channel::CANARY:
      return aegis_access::BrowserReleaseChannel::kCanary;
    case version_info::Channel::UNKNOWN:
      return aegis_access::BrowserReleaseChannel::kUnknown;
  }
  return aegis_access::BrowserReleaseChannel::kInvalid;
}
}  // namespace

aegis_access::ChannelNamespace BundledAccessTestChannel() {
#if BUILDFLAG(AEGIS_BETA_TEST_NODE_ENABLED)
  return aegis_access::ChannelNamespace::kBeta;
#elif BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
  return aegis_access::ChannelNamespace::kAlpha;
#else
  return aegis_access::ChannelNamespace::kInvalid;
#endif
}

aegis_access::ChannelNamespace AccessChannelForCurrentBuild() {
  const auto browser_channel = BrowserReleaseChannel();
#if BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
  // Only the unbranded UNKNOWN channel takes its identity from the build.
  if (browser_channel == aegis_access::BrowserReleaseChannel::kUnknown)
    return BundledAccessTestChannel();
#endif
  return aegis_access::MapBrowserReleaseChannel(browser_channel);
}

const char* LocalAccessIdentityChannel(aegis_access::ChannelNamespace channel) {
  if (channel == aegis_access::ChannelNamespace::kBeta) return "beta";
  if (channel == aegis_access::ChannelNamespace::kAlpha) return "alpha";
  return "dev";
}

std::string_view DefaultCoreLogLevelForCurrentBuild() {
  return DefaultCoreLogLevelForBuild(
      BrowserReleaseChannel(), BundledAccessTestChannel());
}
}  // namespace aegis::access
