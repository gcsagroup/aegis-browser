// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/pref_names.h

#ifndef CHROME_COMMON_AEGIS_PREF_NAMES_H_
#define CHROME_COMMON_AEGIS_PREF_NAMES_H_

namespace aegis::prefs {

// Profile prefs for chrome://aegis module toggles.
inline constexpr char kTrackerBlockingEnabled[] =
    "aegis.tracker_blocking_enabled";
inline constexpr char kPhishInterstitialEnabled[] =
    "aegis.phish_interstitial_enabled";
inline constexpr char kFingerprintGuardEnabled[] =
    "aegis.fingerprint_guard_enabled";
inline constexpr char kFilterListAutoUpdateEnabled[] =
    "aegis.filter_list_auto_update";
inline constexpr char kFilterListLastUpdated[] =
    "aegis.filter_list_last_updated";
inline constexpr char kFilterListHostCount[] = "aegis.filter_list_host_count";
inline constexpr char kFilterListGeneration[] = "aegis.filter_list_generation";
inline constexpr char kFilterListLastError[] = "aegis.filter_list_last_error";
inline constexpr char kFilterListLastAttempt[] =
    "aegis.filter_list_last_attempt";
inline constexpr char kFilterListHttpValidators[] =
    "aegis.filter_list_http_validators";
inline constexpr char kLinkSanitizeEnabled[] = "aegis.link_sanitize_enabled";
inline constexpr char kCookieJanitorEnabled[] = "aegis.cookie_janitor_enabled";
inline constexpr char kCnameUncloakEnabled[] = "aegis.cname_uncloak_enabled";
inline constexpr char kBounceTrackingEnabled[] =
    "aegis.bounce_tracking_enabled";
inline constexpr char kPolicyWorkerEnabled[] = "aegis.policy_worker_enabled";
inline constexpr char kPrivacyAiEnabled[] = "aegis.privacy_ai_enabled";
inline constexpr char kOllamaBaseUrl[] = "aegis.ollama_base_url";
inline constexpr char kOllamaModel[] = "aegis.ollama_model";
inline constexpr char kAiControlEnabled[] = "aegis.ai_control_enabled";

}  // namespace aegis::prefs

#endif  // CHROME_COMMON_AEGIS_PREF_NAMES_H_
