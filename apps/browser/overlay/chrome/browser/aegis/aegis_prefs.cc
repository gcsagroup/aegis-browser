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
  registry->RegisterBooleanPref(prefs::kMinerGuardEnabled, true);
  // Profile 本地密钥；不设置 SYNCABLE_PREF，避免跨设备同步。
  registry->RegisterStringPref(prefs::kFingerprintFarblingSecret,
                               std::string());
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
  registry->RegisterStringPref(prefs::kModelProvider, "openai");
  registry->RegisterStringPref(prefs::kModelBaseUrl, std::string());
  registry->RegisterStringPref(prefs::kModelName, std::string());
  // API keys are encrypted with OSCrypt before being stored in this local,
  // non-syncable dictionary. Values are never exposed through WebUI status.
  registry->RegisterDictionaryPref(prefs::kModelApiKeyCiphertexts);
  // 仅用于识别有真实 user setting 的旧配置；新安装不会从这些默认值迁移。
  registry->RegisterStringPref(prefs::kOllamaBaseUrl, "http://127.0.0.1:11434");
  registry->RegisterStringPref(prefs::kOllamaModel, "llama3.2:3b");
  registry->RegisterBooleanPref(prefs::kAiControlEnabled, false);
  registry->RegisterStringPref(prefs::kPausedSites, std::string());
  registry->RegisterBooleanPref(prefs::kAwarenessIntroShown, false);
  registry->RegisterBooleanPref(prefs::kTorrentDisclosureAcknowledged, false);
  registry->RegisterStringPref(prefs::kLastTorrentTaskId, std::string());
}

}  // namespace aegis
