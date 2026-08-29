// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/features.cc

#include "chrome/common/aegis/features.h"

namespace aegis::features {

// Chromium 120+ uses the 2-arg BASE_FEATURE form (name derived from
// identifier).
BASE_FEATURE(kAegisEnabled, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisTrackerBlocking, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisPhishInterstitial, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisFingerprintGuard, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisMinerGuard, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisBytecodeShadow, base::FEATURE_DISABLED_BY_DEFAULT);
BASE_FEATURE(kAegisFilterListUpdater, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisLinkSanitize, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisCookieJanitor, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisCnameUncloak, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisBounceTracking, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisPolicyWorker, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisPrivacyAi, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisAiControl, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisAgent, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisAgentPageActions, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisAgentBrowserTools, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisAgentWebMcp, base::FEATURE_DISABLED_BY_DEFAULT);
BASE_FEATURE(kAegisAgentWorkflows, base::FEATURE_ENABLED_BY_DEFAULT);
BASE_FEATURE(kAegisAgentTransactionPilot, base::FEATURE_DISABLED_BY_DEFAULT);

bool IsFingerprintGuardGloballyEnabled(bool pref_enabled) {
  return pref_enabled && base::FeatureList::IsEnabled(kAegisEnabled) &&
         base::FeatureList::IsEnabled(kAegisFingerprintGuard);
}

bool IsMinerGuardGloballyEnabled(bool pref_enabled) {
  return pref_enabled && base::FeatureList::IsEnabled(kAegisEnabled) &&
         base::FeatureList::IsEnabled(kAegisMinerGuard);
}

bool IsBytecodeShadowGloballyEnabled() {
  return base::FeatureList::IsEnabled(kAegisEnabled) &&
         base::FeatureList::IsEnabled(kAegisBytecodeShadow);
}

}  // namespace aegis::features
