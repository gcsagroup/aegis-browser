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
inline constexpr char kMinerGuardEnabled[] = "aegis.miner_guard_enabled";
inline constexpr char kFingerprintFarblingSecret[] =
    "aegis.fingerprint_farbling_secret";
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
inline constexpr char kModelProvider[] = "aegis.model_provider";
inline constexpr char kModelBaseUrl[] = "aegis.model_base_url";
inline constexpr char kModelName[] = "aegis.model_name";
inline constexpr char kModelApiKeyCiphertexts[] =
    "aegis.model_api_key_ciphertexts";
// Legacy Ollama prefs retained only for one-way migration.
inline constexpr char kOllamaBaseUrl[] = "aegis.ollama_base_url";
inline constexpr char kOllamaModel[] = "aegis.ollama_model";
inline constexpr char kAiControlEnabled[] = "aegis.ai_control_enabled";
inline constexpr char kAgentEnabled[] = "aegis.agent_enabled";
inline constexpr char kAgentTaskRetentionDays[] =
    "aegis.agent_task_retention_days";
inline constexpr char kAgentWorkspaces[] = "aegis.agent_workspaces";
inline constexpr char kPausedSites[] = "aegis.paused_sites";
inline constexpr char kAwarenessIntroShown[] = "aegis.awareness_intro_shown";
inline constexpr char kTorrentDisclosureAcknowledged[] =
    "aegis.torrent_disclosure_acknowledged";
inline constexpr char kLastTorrentTaskId[] = "aegis.last_torrent_task_id";

}  // namespace aegis::prefs

#endif  // CHROME_COMMON_AEGIS_PREF_NAMES_H_
