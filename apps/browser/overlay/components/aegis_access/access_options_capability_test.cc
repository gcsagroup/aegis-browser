// Copyright 2026 GCSA
#include "components/aegis_access/access_options_capability.h"
#include <cassert>
#include <iostream>

int main() {
  using namespace aegis_access;
  unsigned checks = 0;
  assert(ParseAccessProductChannel("debug") == AccessProductChannel::kDebug);
  assert(ParseAccessProductChannel("alpha") == AccessProductChannel::kAlpha);
  assert(ParseAccessProductChannel("beta") == AccessProductChannel::kBeta);
  assert(ParseAccessProductChannel("stable") == AccessProductChannel::kStable);
  assert(ParseAccessProductChannel("future") == AccessProductChannel::kUnknown);
  checks += 5;
  for (auto product : {AccessProductChannel::kUnknown, AccessProductChannel::kDebug,
                       AccessProductChannel::kAlpha, AccessProductChannel::kBeta,
                       AccessProductChannel::kStable}) {
    for (auto browser : {BrowserReleaseChannel::kUnknown, BrowserReleaseChannel::kDev,
                         BrowserReleaseChannel::kCanary, BrowserReleaseChannel::kBeta,
                         BrowserReleaseChannel::kStable, BrowserReleaseChannel::kInvalid}) {
      for (bool enabled : {false, true}) {
        for (auto bundled : {ChannelNamespace::kInvalid, ChannelNamespace::kAlpha,
                             ChannelNamespace::kBeta}) {
          const auto identity = ResolveAccessBuildIdentity(product, browser, bundled, enabled);
          const bool internal = product == AccessProductChannel::kDebug ||
                                product == AccessProductChannel::kAlpha;
          const bool known_release = browser == BrowserReleaseChannel::kBeta ||
                                     browser == BrowserReleaseChannel::kStable;
          const bool compatible = !known_release ||
              (browser == BrowserReleaseChannel::kBeta && product == AccessProductChannel::kBeta) ||
              (browser == BrowserReleaseChannel::kStable && product == AccessProductChannel::kStable) ||
              product == AccessProductChannel::kUnknown;
          const bool admitted = enabled && internal && compatible &&
                                browser != BrowserReleaseChannel::kInvalid;
          for (auto operation : {AccessOptionsOperation::kPage, AccessOptionsOperation::kRead,
                                 AccessOptionsOperation::kWrite, AccessOptionsOperation::kImport,
                                 AccessOptionsOperation::kActivate}) {
            assert(CanUseAccessOptions(identity, operation) == admitted);
            ++checks;
          }
          if (product == AccessProductChannel::kUnknown) {
            const auto expected = browser == BrowserReleaseChannel::kUnknown &&
                bundled != ChannelNamespace::kInvalid ? bundled : MapBrowserReleaseChannel(browser);
            assert(identity.channel == expected);
            ++checks;
          }
          if (known_release) {
            assert(identity.channel == MapBrowserReleaseChannel(browser));
            ++checks;
          }
        }
      }
    }
  }
  const auto alpha = ResolveAccessBuildIdentity(AccessProductChannel::kAlpha,
      BrowserReleaseChannel::kUnknown, ChannelNamespace::kInvalid, true);
  assert(alpha.channel == ChannelNamespace::kAlpha && alpha.internal_options);
  const auto beta = ResolveAccessBuildIdentity(AccessProductChannel::kBeta,
      BrowserReleaseChannel::kUnknown, ChannelNamespace::kAlpha, true);
  assert(beta.channel == ChannelNamespace::kBeta && !beta.internal_options);
  const auto conflict = ResolveAccessBuildIdentity(AccessProductChannel::kDebug,
      BrowserReleaseChannel::kStable, ChannelNamespace::kAlpha, true);
  assert(conflict.conflict && conflict.channel == ChannelNamespace::kRelease);
  auto inconsistent = alpha;
  inconsistent.channel = ChannelNamespace::kBeta;
  assert(!CanUseAccessOptions(inconsistent, AccessOptionsOperation::kActivate));
  assert(!CanUseAccessOptions(alpha, static_cast<AccessOptionsOperation>(999)));
  checks += 2;
  std::cout << "PASS: Access Options capability " << checks + 3 << " checks\n";
}
