// Copyright 2026 GCSA
// Intended path in Chromium: chrome/common/aegis/features.h
// This file is an overlay template — applied via patches after fetch.

#ifndef CHROME_COMMON_AEGIS_FEATURES_H_
#define CHROME_COMMON_AEGIS_FEATURES_H_

#include "base/feature_list.h"

namespace aegis::features {

BASE_DECLARE_FEATURE(kAegisEnabled);
BASE_DECLARE_FEATURE(kAegisTrackerBlocking);
BASE_DECLARE_FEATURE(kAegisPhishInterstitial);
BASE_DECLARE_FEATURE(kAegisFingerprintGuard);
BASE_DECLARE_FEATURE(kAegisFilterListUpdater);
BASE_DECLARE_FEATURE(kAegisLinkSanitize);
BASE_DECLARE_FEATURE(kAegisCookieJanitor);
BASE_DECLARE_FEATURE(kAegisCnameUncloak);
BASE_DECLARE_FEATURE(kAegisBounceTracking);
BASE_DECLARE_FEATURE(kAegisPolicyWorker);
BASE_DECLARE_FEATURE(kAegisPrivacyAi);
BASE_DECLARE_FEATURE(kAegisAiControl);

}  // namespace aegis::features

#endif  // CHROME_COMMON_AEGIS_FEATURES_H_
