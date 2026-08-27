// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/features.cc

#include "chrome/common/aegis/features.h"

namespace aegis::features {

// Chromium 120+ uses the 2-arg BASE_FEATURE form (name derived from identifier).
BASE_FEATURE(kAegisEnabled, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisTrackerBlocking, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisPhishInterstitial, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisFingerprintGuard, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisFilterListUpdater, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisLinkSanitize, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisCookieJanitor, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisCnameUncloak, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisBounceTracking, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisPolicyWorker, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisPrivacyAi, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisAiControl, base::FEATURE_ENABLED_BY_DEFAULT);

}  // namespace aegis::features
