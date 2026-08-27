// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_prefs.cc

#include "chrome/browser/aegis/aegis_prefs.h"

#include <string>

#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/pref_registry/pref_registry_syncable.h"

namespace aegis {

void RegisterProfilePrefs(user_prefs::PrefRegistrySyncable* registry) {
  registry->RegisterBooleanPref(prefs::kTrackerBlockingEnabled, true);
  registry->RegisterBooleanPref(prefs::kPhishInterstitialEnabled, true);
  // FingerprintGuard on by default when the feature is enabled.
  registry->RegisterBooleanPref(prefs::kFingerprintGuardEnabled, true);
  registry->RegisterBooleanPref(prefs::kFilterListAutoUpdateEnabled, true);
  registry->RegisterInt64Pref(prefs::kFilterListLastUpdated, 0);
  registry->RegisterIntegerPref(prefs::kFilterListHostCount, 0);
  registry->RegisterIntegerPref(prefs::kFilterListGeneration, 0);
  registry->RegisterStringPref(prefs::kFilterListLastError, std::string());
  registry->RegisterInt64Pref(prefs::kFilterListLastAttempt, 0);
  registry->RegisterDictionaryPref(prefs::kFilterListHttpValidators);
  registry->RegisterBooleanPref(prefs::kLinkSanitizeEnabled, true);
  registry->RegisterBooleanPref(prefs::kCookieJanitorEnabled, true);
  registry->RegisterBooleanPref(prefs::kCnameUncloakEnabled, true);
  registry->RegisterBooleanPref(prefs::kBounceTrackingEnabled, true);
  registry->RegisterBooleanPref(prefs::kPolicyWorkerEnabled, true);
  registry->RegisterBooleanPref(prefs::kPrivacyAiEnabled, true);
  registry->RegisterStringPref(prefs::kOllamaBaseUrl,
                               "http://127.0.0.1:11434");
  registry->RegisterStringPref(prefs::kOllamaModel, "llama3.2:3b");
  registry->RegisterBooleanPref(prefs::kAiControlEnabled, false);
}

}  // namespace aegis
