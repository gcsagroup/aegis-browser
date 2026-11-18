// Copyright 2026 GCSA
#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_OPTIONS_CAPABILITY_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_OPTIONS_CAPABILITY_H_

#include <string_view>
#include "components/aegis_access/browser_request_metadata_seed.h"

namespace aegis_access {

enum class AccessProductChannel { kUnknown, kDebug, kAlpha, kBeta, kStable };
constexpr AccessProductChannel ParseAccessProductChannel(std::string_view value) {
  if (value == "debug") return AccessProductChannel::kDebug;
  if (value == "alpha") return AccessProductChannel::kAlpha;
  if (value == "beta") return AccessProductChannel::kBeta;
  if (value == "stable") return AccessProductChannel::kStable;
  return AccessProductChannel::kUnknown;
}
enum class AccessOptionsOperation { kPage, kRead, kWrite, kImport, kActivate };

struct AccessBuildIdentity {
  ChannelNamespace channel = ChannelNamespace::kInvalid;
  AccessProductChannel product = AccessProductChannel::kUnknown;
  bool internal_options = false;
  bool conflict = false;
};

// Inputs originate in native build flags and Chromium's own channel authority.
// A node resource can supply legacy ownership only for an unspecified product.
inline AccessBuildIdentity ResolveAccessBuildIdentity(
    AccessProductChannel product,
    BrowserReleaseChannel browser,
    ChannelNamespace bundled_channel,
    bool internal_options) {
  AccessBuildIdentity result;
  result.product = product;
  result.channel = MapBrowserReleaseChannel(browser);
  if (product == AccessProductChannel::kUnknown) {
    if (browser == BrowserReleaseChannel::kUnknown &&
        (bundled_channel == ChannelNamespace::kAlpha ||
         bundled_channel == ChannelNamespace::kBeta)) {
      result.channel = bundled_channel;
    }
    return result;
  }
  ChannelNamespace declared = ChannelNamespace::kInvalid;
  switch (product) {
    case AccessProductChannel::kDebug: declared = ChannelNamespace::kDev; break;
    case AccessProductChannel::kAlpha: declared = ChannelNamespace::kAlpha; break;
    case AccessProductChannel::kBeta: declared = ChannelNamespace::kBeta; break;
    case AccessProductChannel::kStable: declared = ChannelNamespace::kRelease; break;
    case AccessProductChannel::kUnknown: break;
  }
  result.conflict = declared == ChannelNamespace::kInvalid ||
      browser == BrowserReleaseChannel::kInvalid ||
      (browser == BrowserReleaseChannel::kBeta && declared != ChannelNamespace::kBeta) ||
      (browser == BrowserReleaseChannel::kStable && declared != ChannelNamespace::kRelease);
  if (result.conflict)
    return result;
  result.channel = declared;
  result.internal_options = internal_options &&
      (product == AccessProductChannel::kDebug || product == AccessProductChannel::kAlpha);
  return result;
}

inline bool CanUseAccessOptions(const AccessBuildIdentity& identity,
                               AccessOptionsOperation operation) {
  if (identity.conflict || !identity.internal_options ||
      (identity.product != AccessProductChannel::kDebug &&
       identity.product != AccessProductChannel::kAlpha)) {
    return false;
  }
  if ((identity.product == AccessProductChannel::kDebug && identity.channel != ChannelNamespace::kDev) ||
      (identity.product == AccessProductChannel::kAlpha && identity.channel != ChannelNamespace::kAlpha)) {
    return false;
  }
  switch (operation) {
    case AccessOptionsOperation::kPage:
    case AccessOptionsOperation::kRead:
    case AccessOptionsOperation::kWrite:
    case AccessOptionsOperation::kImport:
    case AccessOptionsOperation::kActivate:
      return true;
  }
  return false;
}
}  // namespace aegis_access
#endif
