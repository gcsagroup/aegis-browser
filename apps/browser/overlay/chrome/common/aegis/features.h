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
BASE_DECLARE_FEATURE(kAegisMinerGuard);
BASE_DECLARE_FEATURE(kAegisBytecodeShadow);
BASE_DECLARE_FEATURE(kAegisFilterListUpdater);
BASE_DECLARE_FEATURE(kAegisLinkSanitize);
BASE_DECLARE_FEATURE(kAegisCookieJanitor);
BASE_DECLARE_FEATURE(kAegisCnameUncloak);
BASE_DECLARE_FEATURE(kAegisBounceTracking);
BASE_DECLARE_FEATURE(kAegisPolicyWorker);
BASE_DECLARE_FEATURE(kAegisPrivacyAi);
BASE_DECLARE_FEATURE(kAegisAiControl);
// The accepted Browser Agent surface is available in regular desktop profiles
// by default. The profile preference remains opt-in, so exposing the entry does
// not start model calls, tools, or persisted monitors.
BASE_DECLARE_FEATURE(kAegisAgent);
// Accepted capabilities ship with the surface. Experimental WebMCP and the
// transaction pilot remain independent kill switches and default off.
BASE_DECLARE_FEATURE(kAegisAgentPageActions);
BASE_DECLARE_FEATURE(kAegisAgentBrowserTools);
BASE_DECLARE_FEATURE(kAegisAgentWebMcp);
BASE_DECLARE_FEATURE(kAegisAgentWorkflows);
BASE_DECLARE_FEATURE(kAegisAgentTransactionPilot);

// 统一计算可发送给 Renderer 的有效开关，避免 UI 与 Blink 状态不一致。
bool IsFingerprintGuardGloballyEnabled(bool pref_enabled);
bool IsMinerGuardGloballyEnabled(bool pref_enabled);
bool IsBytecodeShadowGloballyEnabled();

}  // namespace aegis::features

#endif  // CHROME_COMMON_AEGIS_FEATURES_H_
