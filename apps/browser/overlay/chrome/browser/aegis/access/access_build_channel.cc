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

aegis_access::ChannelNamespace AccessChannelForCurrentBuild() {
  auto channel = aegis_access::MapBrowserReleaseChannel(BrowserReleaseChannel());
#if BUILDFLAG(AEGIS_ALPHA_TEST_NODE_ENABLED)
  if (channel == aegis_access::ChannelNamespace::kDev)
    channel = aegis_access::ChannelNamespace::kAlpha;
#endif
  return channel;
}
}  // namespace aegis::access
