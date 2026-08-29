// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_service.cc

#include "chrome/browser/aegis/aegis_service.h"

#include <algorithm>
#include <string_view>

#include "base/base64.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/json/json_reader.h"
#include "base/logging.h"
#include "base/memory/singleton.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/aegis/aegis_ai_control.h"
#include "chrome/browser/aegis/aegis_bounce_observer.h"
#include "chrome/browser/aegis/aegis_cookie_janitor.h"
#include "chrome/browser/aegis/filter_list_updater.h"
#include "chrome/browser/aegis/model_provider_client.h"
#include "chrome/browser/aegis/threat_feed_updater.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/tab_contents/tab_contents_iterator.h"
#include "chrome/common/aegis/aegis_block_reporter.h"
#include "chrome/common/aegis/builtin_phish_hosts.h"
#include "chrome/common/aegis/cdp_ws_hook.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/filter_list_matcher.h"
#include "chrome/common/aegis/miner_guard_reporter.h"
#include "chrome/common/aegis/phish_score.h"
#include "chrome/common/aegis/pref_names.h"
#include "chrome/common/aegis/site_control.h"
#include "components/os_crypt/async/browser/os_crypt_async.h"
#include "components/os_crypt/async/common/encryptor.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/btm_service.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/tokens/tokens.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr base::TimeDelta kObserverNotificationInterval =
    base::Milliseconds(250);
constexpr base::TimeDelta kMinerObservationWindow = base::Seconds(30);
constexpr size_t kMaxMinerDocuments = 100;
constexpr size_t kMaxModelApiKeyBytes = 4096;
constexpr std::string_view kLegacyOllamaBaseUrl = "http://127.0.0.1:11434";
constexpr std::string_view kLegacyOllamaModel = "llama3.2:3b";

bool IsValidModelApiKey(std::string_view key) {
  if (key.empty() || key.size() > kMaxModelApiKeyBytes ||
      !base::IsStringUTF8(key)) {
    return false;
  }
  return std::ranges::none_of(
      key, [](unsigned char c) { return c <= 0x20 || c == 0x7f; });
}

std::optional<std::string> NormalizeModelBaseUrl(ModelProvider provider,
                                                 std::string_view candidate) {
  std::string value(base::TrimWhitespaceASCII(candidate, base::TRIM_ALL));
  if (value.empty()) {
    value = std::string(DefaultModelBaseUrl(provider));
  }
  const GURL parsed(value);
  if (!IsAllowedModelBaseUrl(provider, parsed)) {
    return std::nullopt;
  }

  std::string path(parsed.path());
  while (path.size() > 1 && path.ends_with('/')) {
    path.pop_back();
  }
  if (path == parsed.path()) {
    return parsed.spec();
  }
  GURL::Replacements replacements;
  replacements.SetPathStr(path);
  return parsed.ReplaceComponents(replacements).spec();
}

std::string ModelCredentialKey(ModelProvider provider,
                               const std::string& normalized_base_url) {
  return std::string(ModelProviderId(provider)) + "|" + normalized_base_url;
}

bool IsValidModelCredentialKey(std::string_view key) {
  const size_t separator = key.find('|');
  if (separator == std::string_view::npos) {
    return false;
  }
  const std::optional<ModelProvider> provider =
      ParseModelProvider(key.substr(0, separator));
  if (!provider) {
    return false;
  }
  const std::string_view base_url = key.substr(separator + 1);
  const std::optional<std::string> normalized =
      NormalizeModelBaseUrl(*provider, base_url);
  return normalized && ModelCredentialKey(*provider, *normalized) == key;
}

bool HasUserSetting(PrefService* prefs, const char* name) {
  const PrefService::Preference* preference = prefs->FindPreference(name);
  return preference && preference->HasUserSetting();
}

std::optional<std::string> LegacyOllamaBaseToOpenAI(
    std::string_view legacy_base_url) {
  std::optional<std::string> normalized =
      NormalizeModelBaseUrl(ModelProvider::kOpenAI, legacy_base_url);
  if (!normalized) {
    return std::nullopt;
  }
  const GURL parsed(*normalized);
  if (parsed.path() != "/") {
    return normalized;
  }
  GURL::Replacements replacements;
  replacements.SetPathStr("/v1");
  return parsed.ReplaceComponents(replacements).spec();
}

void MigrateLegacyOllamaSettings(PrefService* pref_service) {
  const bool explicit_model_provider =
      HasUserSetting(pref_service, prefs::kModelProvider);
  const bool explicit_ollama_provider =
      explicit_model_provider &&
      pref_service->GetString(prefs::kModelProvider) == "ollama";
  const bool has_new_model_setting =
      explicit_model_provider ||
      HasUserSetting(pref_service, prefs::kModelBaseUrl) ||
      HasUserSetting(pref_service, prefs::kModelName);
  const bool has_legacy_setting =
      HasUserSetting(pref_service, prefs::kOllamaBaseUrl) ||
      HasUserSetting(pref_service, prefs::kOllamaModel);
  if (!explicit_ollama_provider &&
      (has_new_model_setting || !has_legacy_setting)) {
    return;
  }

  std::string legacy_base_url;
  std::string legacy_model;
  if (explicit_ollama_provider) {
    legacy_base_url = pref_service->GetString(prefs::kModelBaseUrl);
    legacy_model = pref_service->GetString(prefs::kModelName);
  }
  if (legacy_base_url.empty()) {
    legacy_base_url = pref_service->GetString(prefs::kOllamaBaseUrl);
  }
  if (legacy_model.empty()) {
    legacy_model = pref_service->GetString(prefs::kOllamaModel);
  }
  if (legacy_base_url.empty()) {
    legacy_base_url = std::string(kLegacyOllamaBaseUrl);
  }
  if (legacy_model.empty()) {
    legacy_model = std::string(kLegacyOllamaModel);
  }

  std::optional<std::string> migrated_base_url =
      LegacyOllamaBaseToOpenAI(legacy_base_url);
  if (!migrated_base_url ||
      !IsValidModelName(ModelProvider::kOpenAI, legacy_model)) {
    return;
  }
  pref_service->SetString(prefs::kModelProvider,
                          std::string(ModelProviderId(ModelProvider::kOpenAI)));
  pref_service->SetString(prefs::kModelBaseUrl, *migrated_base_url);
  pref_service->SetString(prefs::kModelName, legacy_model);
}

int64_t NowUnixSeconds() {
  return (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
}

std::string SafeToken(std::string value, size_t max_length) {
  value = base::ToLowerASCII(value);
  value.erase(std::remove_if(value.begin(), value.end(),
                             [](char c) {
                               return !base::IsAsciiAlphaNumeric(c) &&
                                      c != '_' && c != '-' && c != '.';
                             }),
              value.end());
  if (value.size() > max_length) {
    value.resize(max_length);
  }
  return value;
}

std::vector<std::string> SafeDetails(const std::vector<std::string>& values) {
  std::vector<std::string> result;
  for (const std::string& value : values) {
    const std::string safe = SafeToken(value, 32);
    if (safe.empty() || std::ranges::find(result, safe) != result.end()) {
      continue;
    }
    result.push_back(safe);
    if (result.size() >= PrivacyEventStore::kMaxDetails) {
      break;
    }
  }
  return result;
}

}  // namespace

// static
AegisService* AegisService::GetInstance() {
  return base::Singleton<AegisService>::get();
}

AegisService::AegisService() = default;

AegisService::~AegisService() {
  ClearReporterCallbacks();
}

void AegisService::InitializeForProfile(Profile* profile) {
  CHECK(profile);
  if (profile->IsOffTheRecord()) {
    LOG(WARNING) << "Refusing to initialize Aegis for an off-the-record "
                    "profile";
    return;
  }
  if (!IsEnabled()) {
    VLOG(1) << "Aegis disabled by feature flag";
    return;
  }
  if (initialized_) {
    if (profile_ == profile) {
      return;
    }
    ShutdownForProfile();
  }
  profile_observation_.Observe(profile);
  prefs_ = profile->GetPrefs();
  profile_ = profile;
  initialized_ = true;
  MigrateLegacyOllamaSettings(prefs_);
  if (base::FeatureList::IsEnabled(features::kAegisFilterListUpdater)) {
    filter_list_updater_ = std::make_unique<FilterListUpdater>(profile);
    // LoadFromDisk 完成后再决定是否自动更新，避免缓存未读完就重新下载。
    filter_list_updater_->LoadFromDisk();
  }
  if (IsPhishInterstitialEnabled()) {
    threat_feed_updater_ = std::make_unique<ThreatFeedUpdater>(profile);
    threat_feed_updater_->LoadFromDisk();
  }
  if (base::FeatureList::IsEnabled(features::kAegisCookieJanitor) &&
      IsCookieJanitorEnabled()) {
    cookie_janitor_ = std::make_unique<CookieJanitor>(profile);
    cookie_janitor_->Start();
  }
  if (base::FeatureList::IsEnabled(features::kAegisBounceTracking)) {
    if (content::BtmService* btm = content::BtmService::Get(profile)) {
      BounceObserver::CreateFor(btm, profile);
    }
  }
  model_client_ = std::make_unique<ModelProviderClient>();
  LoadModelCredentials();
  InstallReporterCallbacks();
#if !BUILDFLAG(IS_ANDROID)
  ai_control_ = std::make_unique<AiControl>();
  if (IsAiControlEnabled() && !ai_control_->Start() && prefs_) {
    prefs_->SetBoolean(prefs::kAiControlEnabled, false);
  }
#endif
  LOG(INFO) << "GCSA-aegis initialized for profile"
            << (IsTrackerBlockingEnabled() ? " (tracker blocking on)"
                                           : " (tracker blocking off)");
}

bool AegisService::IsInitializedForProfile(const Profile* profile) const {
  return initialized_ && profile && !profile->IsOffTheRecord() &&
         profile_ == profile;
}

void AegisService::OnProfileWillBeDestroyed(Profile* profile) {
  if (profile_ == profile) {
    ShutdownForProfile();
  }
}

void AegisService::ShutdownForProfile() {
  profile_observation_.Reset();
  host_receivers_.Clear();
  ClearReporterCallbacks();
  if (ai_control_) {
    ai_control_->Stop();
  }
  ai_control_.reset();
  model_client_.reset();
  model_api_keys_.clear();
  model_credentials_loading_ = false;
  model_credentials_loaded_ = false;
  model_credentials_available_ = true;
  if (cookie_janitor_) {
    cookie_janitor_->Stop();
  }
  cookie_janitor_.reset();
  threat_feed_updater_.reset();
  filter_list_updater_.reset();
  observer_notification_timer_.Stop();
  privacy_events_.Clear();
  miner_documents_.clear();
  cdp_ws_clients_ = 0;
  prefs_ = nullptr;
  profile_ = nullptr;
  initialized_ = false;
  NotifyObservers();
}

bool AegisService::IsEnabled() const {
  return base::FeatureList::IsEnabled(features::kAegisEnabled);
}

bool AegisService::IsTrackerBlockingEnabled() const {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisTrackerBlocking)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kTrackerBlockingEnabled);
}

bool AegisService::IsPhishInterstitialEnabled() const {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisPhishInterstitial)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kPhishInterstitialEnabled);
}

bool AegisService::IsFingerprintGuardEnabled() const {
  return features::IsFingerprintGuardGloballyEnabled(
      !prefs_ || prefs_->GetBoolean(prefs::kFingerprintGuardEnabled));
}

bool AegisService::IsMinerGuardEnabled() const {
  return features::IsMinerGuardGloballyEnabled(
      !prefs_ || prefs_->GetBoolean(prefs::kMinerGuardEnabled));
}

void AegisService::SetTrackerBlockingEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kTrackerBlockingEnabled, enabled);
  }
  NotifyObservers();
}

void AegisService::SetPhishInterstitialEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kPhishInterstitialEnabled, enabled);
  }
  if (initialized_ && enabled && !threat_feed_updater_) {
    threat_feed_updater_ = std::make_unique<ThreatFeedUpdater>(profile_);
    threat_feed_updater_->LoadFromDisk();
  } else if (!enabled) {
    threat_feed_updater_.reset();
  }
  NotifyObservers();
}

void AegisService::SetFingerprintGuardEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kFingerprintGuardEnabled, enabled);
  }
  NotifyObservers();
}

void AegisService::SetMinerGuardEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kMinerGuardEnabled, enabled);
  }
  if (!enabled) {
    miner_documents_.clear();
  }
  NotifyObservers();
}

bool AegisService::IsFilterListAutoUpdateEnabled() const {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisFilterListUpdater)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kFilterListAutoUpdateEnabled);
}

bool AegisService::IsFilterListUpdating() const {
  return filter_list_updater_ && filter_list_updater_->updating();
}

int AegisService::FilterListHostCount() const {
  if (prefs_) {
    return prefs_->GetInteger(prefs::kFilterListHostCount);
  }
  return static_cast<int>(
      FilterListMatcher::GetInstance()->compiled_host_count());
}

int64_t AegisService::FilterListLastUpdated() const {
  if (!prefs_) {
    return 0;
  }
  return prefs_->GetInt64(prefs::kFilterListLastUpdated);
}

std::string AegisService::FilterListLastError() const {
  if (!prefs_) {
    return std::string();
  }
  return prefs_->GetString(prefs::kFilterListLastError);
}

void AegisService::SetFilterListAutoUpdateEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kFilterListAutoUpdateEnabled, enabled);
  }
  if (filter_list_updater_) {
    filter_list_updater_->OnAutoUpdateEnabledChanged();
  }
  NotifyObservers();
}

bool AegisService::IsLinkSanitizeEnabled() const {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisLinkSanitize)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kLinkSanitizeEnabled);
}

bool AegisService::IsCookieJanitorEnabled() const {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisCookieJanitor)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kCookieJanitorEnabled);
}

void AegisService::SetLinkSanitizeEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kLinkSanitizeEnabled, enabled);
  }
  NotifyObservers();
}

void AegisService::SetCookieJanitorEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kCookieJanitorEnabled, enabled);
  }
  NotifyObservers();
  if (!enabled) {
    if (cookie_janitor_) {
      cookie_janitor_->Stop();
    }
    return;
  }
  if (!cookie_janitor_ && profile_ &&
      base::FeatureList::IsEnabled(features::kAegisCookieJanitor)) {
    cookie_janitor_ = std::make_unique<CookieJanitor>(profile_);
  }
  if (cookie_janitor_) {
    cookie_janitor_->Start();
  }
}

bool AegisService::IsCnameUncloakEnabled() const {
  if (!IsTrackerBlockingEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisCnameUncloak)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kCnameUncloakEnabled);
}

bool AegisService::IsBounceTrackingEnabled() const {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisBounceTracking)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kBounceTrackingEnabled);
}

void AegisService::SetCnameUncloakEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kCnameUncloakEnabled, enabled);
  }
  NotifyObservers();
}

void AegisService::SetBounceTrackingEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kBounceTrackingEnabled, enabled);
  }
  NotifyObservers();
}

bool AegisService::IsPolicyWorkerEnabled() const {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisPolicyWorker)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kPolicyWorkerEnabled);
}

bool AegisService::IsPrivacyAiEnabled() const {
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisPrivacyAi)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kPrivacyAiEnabled);
}

void AegisService::SetPolicyWorkerEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kPolicyWorkerEnabled, enabled);
  }
  NotifyObservers();
}

void AegisService::SetPrivacyAiEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kPrivacyAiEnabled, enabled);
  }
  NotifyObservers();
}

bool AegisService::IsAiControlEnabled() const {
#if BUILDFLAG(IS_ANDROID)
  return false;
#else
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisAiControl)) {
    return false;
  }
  if (!prefs_) {
    return false;
  }
  return prefs_->GetBoolean(prefs::kAiControlEnabled);
#endif
}

void AegisService::SetAiControlEnabled(bool enabled) {
#if BUILDFLAG(IS_ANDROID)
  (void)enabled;
#else
  if (prefs_) {
    prefs_->SetBoolean(prefs::kAiControlEnabled, enabled);
  }
  if (!ai_control_) {
    ai_control_ = std::make_unique<AiControl>();
  }
  if (enabled && IsAiControlEnabled()) {
    if (!ai_control_->Start() && prefs_) {
      prefs_->SetBoolean(prefs::kAiControlEnabled, false);
    }
    NotifyObservers();
    return;
  }
  ai_control_->Stop();
  NotifyObservers();
#endif
}

void AegisService::AddObserver(AegisServiceObserver* observer) {
  observers_.AddObserver(observer);
}

void AegisService::RemoveObserver(AegisServiceObserver* observer) {
  observers_.RemoveObserver(observer);
}

// static
std::string AegisService::DocumentIdForWebContents(
    content::WebContents* web_contents) {
  if (!web_contents || !web_contents->GetPrimaryMainFrame()) {
    return std::string();
  }
  return web_contents->GetPrimaryMainFrame()->GetReportingSource().ToString();
}

PagePrivacySummary AegisService::GetPageSummary(
    content::WebContents* web_contents) const {
  PagePrivacySummary summary;
  if (!web_contents) {
    return summary;
  }
  summary.site_key =
      SiteKeyForHost(std::string(web_contents->GetLastCommittedURL().host()));
  summary.paused = IsSitePaused(summary.site_key);
  summary.events = privacy_events_.ForDocumentAndSite(
      DocumentIdForWebContents(web_contents), summary.site_key);
  for (const PrivacyEvent& event : summary.events) {
    if (event.kind == "miner") {
      summary.miner_alerts += event.count;
      continue;
    }
    summary.total += event.count;
    if (event.kind == "block") {
      summary.blocked += event.count;
    } else if (event.kind == "param") {
      summary.params += event.count;
    } else if (event.kind == "cookie") {
      summary.cookies += event.count;
    } else if (event.kind == "bounce") {
      summary.bounces += event.count;
    } else if (event.kind == "phish") {
      summary.phishing += event.count;
    }
  }
  return summary;
}

bool AegisService::IsSitePaused(const std::string& host) const {
  return prefs_ && aegis::IsSitePaused(prefs_->GetString(prefs::kPausedSites),
                                       host, NowUnixSeconds());
}

void AegisService::SetSitePaused(const std::string& host,
                                 bool paused,
                                 base::TimeDelta duration) {
  if (!prefs_) {
    return;
  }
  const std::string current = prefs_->GetString(prefs::kPausedSites);
  const int64_t now = NowUnixSeconds();
  const std::string next =
      paused ? aegis::SetSitePaused(
                   current, host,
                   now + std::max<int64_t>(1, duration.InSeconds()), now)
             : ResumeSite(current, host, now);
  if (next == current) {
    return;
  }
  prefs_->SetString(prefs::kPausedSites, next);
  if (paused) {
    std::erase_if(miner_documents_, [&host](const auto& entry) {
      return entry.first.ends_with("|" + SiteKeyForHost(host));
    });
  }
  NotifyObservers();
}

bool AegisService::ShouldShowAwarenessIntro() const {
  return prefs_ && profile_ && !profile_->IsOffTheRecord() &&
         !prefs_->GetBoolean(prefs::kAwarenessIntroShown);
}

void AegisService::MarkAwarenessIntroShown() {
  if (prefs_ && profile_ && !profile_->IsOffTheRecord()) {
    prefs_->SetBoolean(prefs::kAwarenessIntroShown, true);
  }
}

int AegisService::AiControlPort() const {
  if (!ai_control_) {
    return 0;
  }
  return ai_control_->port();
}

std::string AegisService::AiControlAddress() const {
  if (!ai_control_) {
    return std::string();
  }
  return ai_control_->address();
}

bool AegisService::AiControlLoopbackOnly() const {
  return ai_control_ && ai_control_->loopback_only();
}

bool AegisService::AiControlRunning() const {
  return ai_control_ && ai_control_->running();
}

size_t AegisService::CdpWebSocketClientCount() const {
  return cdp_ws_clients_;
}

void AegisService::SetCdpWebSocketClientCount(size_t count) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) {
    content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce(&AegisService::SetCdpWebSocketClientCount,
                                  base::Unretained(this), count));
    return;
  }
  if (cdp_ws_clients_ == count) {
    return;
  }
  cdp_ws_clients_ = count;
  PrivacyEvent event;
  event.kind = "cdp";
  event.reason = count == 0 ? "disconnected" : "connected";
  event.count = 1;
  event.first_unix_seconds = NowUnixSeconds();
  event.last_unix_seconds = event.first_unix_seconds;
  PushPrivacyEvent(std::move(event));
}

void AegisService::BindAegisHost(
    mojo::PendingReceiver<chrome::mojom::AegisHost> receiver,
    int render_process_id) {
  host_receivers_.Add(this, std::move(receiver), render_process_id);
}

void AegisService::ReportBlockedRequest(const std::string& url,
                                        const std::string& reason,
                                        const std::string& cname_alias,
                                        const std::string& source_site,
                                        const std::string& local_frame_token) {
  std::string site_key = source_site;
  const std::string document_id = ResolveDocumentContext(
      local_frame_token, host_receivers_.current_context(), &site_key);
  RecordBlockedRequest(GURL(url), reason, cname_alias, document_id, site_key);
}

void AegisService::ReportStrippedReferrer(
    const std::string& host,
    const std::vector<std::string>& keys,
    const std::string& source_site,
    const std::string& local_frame_token) {
  std::string site_key = source_site;
  const std::string document_id = ResolveDocumentContext(
      local_frame_token, host_receivers_.current_context(), &site_key);
  RecordStrippedReferrer(host, keys, document_id, site_key);
}

void AegisService::ReportStrippedParams(const std::string& host,
                                        const std::vector<std::string>& keys,
                                        const std::string& source_site,
                                        const std::string& local_frame_token) {
  std::string site_key = source_site;
  const std::string document_id = ResolveDocumentContext(
      local_frame_token, host_receivers_.current_context(), &site_key);
  RecordStrippedParams(host, keys, document_id, site_key);
}

void AegisService::OnBlockedReport(GURL url,
                                   std::string reason,
                                   std::string cname_alias,
                                   std::string source_site,
                                   std::string document_id) {
  RecordBlockedRequest(url, reason, cname_alias, document_id, source_site);
}

void AegisService::OnStrippedReferrerReport(std::string host,
                                            std::vector<std::string> keys,
                                            std::string source_site,
                                            std::string document_id) {
  RecordStrippedReferrer(host, keys, document_id, source_site);
}

void AegisService::OnStrippedParamsReport(std::string host,
                                          std::vector<std::string> keys,
                                          std::string source_site,
                                          std::string document_id) {
  RecordStrippedParams(host, keys, document_id, source_site);
}

void AegisService::InstallReporterCallbacks() {
  BlockReporter::SetCallbacks(
      content::GetUIThreadTaskRunner({}),
      base::BindRepeating(&AegisService::OnBlockedReport,
                          weak_ptr_factory_.GetWeakPtr()),
      base::BindRepeating(&AegisService::OnStrippedReferrerReport,
                          weak_ptr_factory_.GetWeakPtr()),
      base::BindRepeating(&AegisService::OnStrippedParamsReport,
                          weak_ptr_factory_.GetWeakPtr()));
  MinerGuardReporter::SetCallback(
      content::GetUIThreadTaskRunner({}),
      base::BindRepeating(&AegisService::OnMinerSignals,
                          weak_ptr_factory_.GetWeakPtr()));
  CdpWsHook::SetClientCountCallback(base::BindRepeating([](size_t count) {
    AegisService::GetInstance()->SetCdpWebSocketClientCount(count);
  }));
}

void AegisService::ClearReporterCallbacks() {
  weak_ptr_factory_.InvalidateWeakPtrs();
  BlockReporter::ClearCallbacks();
  MinerGuardReporter::ClearCallback();
  CdpWsHook::SetClientCountCallback({});
}

bool AegisService::IsCurrentProfileDocument(const std::string& document_id,
                                            const std::string& site_key) const {
  if (!profile_ || document_id.empty() || site_key.empty()) {
    return false;
  }
  bool found = false;
  tabs::ForEachTabInterface([&](tabs::TabInterface* tab) {
    content::WebContents* web_contents = tab->GetContents();
    if (!web_contents || web_contents->GetBrowserContext() != profile_ ||
        DocumentIdForWebContents(web_contents) != document_id) {
      return true;
    }
    found = SiteKeyForHost(
                std::string(web_contents->GetLastCommittedURL().host())) ==
            SiteKeyForHost(site_key);
    return !found;
  });
  return found;
}

void AegisService::OnMinerSignals(std::string document_id,
                                  std::string site_key,
                                  std::string display_domain,
                                  MinerRuntimeSignals signals) {
  site_key = SiteKeyForHost(site_key);
  const std::string state_key = document_id + "|" + site_key;
  if (!IsMinerGuardEnabled() || IsSitePaused(site_key) ||
      !IsCurrentProfileDocument(document_id, site_key)) {
    miner_documents_.erase(state_key);
    return;
  }

  const base::TimeTicks now = base::TimeTicks::Now();
  std::erase_if(miner_documents_, [now](const auto& entry) {
    return now - entry.second.last_update > kMinerObservationWindow;
  });
  auto it = miner_documents_.find(state_key);
  if (it == miner_documents_.end() &&
      miner_documents_.size() >= kMaxMinerDocuments) {
    auto oldest = std::min_element(
        miner_documents_.begin(), miner_documents_.end(),
        [](const auto& left, const auto& right) {
          return left.second.last_update < right.second.last_update;
        });
    if (oldest != miner_documents_.end()) {
      miner_documents_.erase(oldest);
    }
  }
  it = miner_documents_.try_emplace(state_key).first;
  it->second.last_update = now;
  MinerDocumentState& state = it->second;
  AddMinerSignalsToWindow(signals, now, kMinerObservationWindow, &state.window);
  const MinerAssessment assessment = AssessMinerSignals(state.window.signals);
  if (assessment.verdict != MinerVerdict::kLikelyMining ||
      state.likely_mining_reported) {
    return;
  }
  state.likely_mining_reported = true;

  PrivacyEvent event;
  event.document_id = std::move(document_id);
  event.site_key = std::move(site_key);
  event.kind = "miner";
  event.reason = "likely_mining";
  event.display_domain = SiteKeyForHost(display_domain);
  event.details = SafeDetails(assessment.reasons);
  event.first_unix_seconds = NowUnixSeconds();
  event.last_unix_seconds = event.first_unix_seconds;
  PushPrivacyEvent(std::move(event));
  LOG(INFO) << "[AegisMinerGuard] schema=1 mode=observe_only "
               "verdict=likely_mining score_bucket=high";
}

namespace {

std::string NormalizeLocale(const std::string& locale) {
  if (locale.starts_with("zh-TW") || locale.starts_with("zh-HK")) {
    return "zh-TW";
  }
  if (locale.starts_with("zh")) {
    return "zh-CN";
  }
  return "en";
}

std::vector<std::string> StringList(const base::DictValue& dict,
                                    const char* key) {
  std::vector<std::string> out;
  const base::ListValue* list = dict.FindList(key);
  if (!list) {
    return out;
  }
  for (const base::Value& value : *list) {
    if (value.is_string()) {
      out.push_back(value.GetString());
    }
  }
  return out;
}

void AttachLocalProvenance(SummarizeResult* result,
                           const PageSnapshot& snapshot) {
  result->chars_in = static_cast<int>(snapshot.text_sample.size());
  result->stayed_on_device = true;
  if (result->destination.empty()) {
    result->destination = "local";
  }
}

SummarizeResult RejectedPreparedSummary(const PageSnapshot& snapshot,
                                        std::string error) {
  SummarizeResult result;
  result.ok = false;
  result.url = snapshot.url;
  result.backend = "unavailable";
  result.model_ready = false;
  result.worker_ready = false;
  result.error = std::move(error);
  AttachLocalProvenance(&result, snapshot);
  return result;
}

SummarizeResult ValidatedHeuristic(const PageSnapshot& snapshot,
                                   const PreparedSummary& prepared) {
  SummarizeResult result;
  result.ok = true;
  result.url = snapshot.url;
  result.worker_ready = true;
  result.summary = prepared.summary;
  result.backend = "heuristic";
  result.model_ready = false;
  result.bullets = prepared.bullets;
  result.risks = prepared.risks;
  AttachLocalProvenance(&result, snapshot);
  return result;
}

bool ParseModelJson(const std::string& raw, SummarizeResult* result) {
  const size_t start = raw.find('{');
  const size_t end = raw.rfind('}');
  if (start == std::string::npos || end == std::string::npos || end <= start) {
    return false;
  }
  std::optional<base::Value> parsed = base::JSONReader::Read(
      raw.substr(start, end - start + 1), base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!parsed || !parsed->is_dict()) {
    return false;
  }
  const base::DictValue& dict = parsed->GetDict();
  result->summary =
      dict.FindString("summary") ? *dict.FindString("summary") : "";
  result->bullets = StringList(dict, "bullets");
  result->risks = StringList(dict, "risks");
  return !result->summary.empty();
}

}  // namespace

std::optional<std::string> AegisService::SummarizePreparedPage(
    PageSnapshot original,
    PreparedSummary prepared,
    const std::string& locale,
    const std::string& provider_id,
    const std::string& base_url,
    const std::string& model,
    base::OnceCallback<void(SummarizeResult)> done) {
  if (!IsPrivacyAiEnabled() || !IsPolicyWorkerEnabled()) {
    SummarizeResult result = RejectedPreparedSummary(
        original, "privacy summary or policy worker disabled");
    std::move(done).Run(std::move(result));
    return std::nullopt;
  }

  std::string validation_error;
  if (!ValidatePreparedSummary(original, prepared, &validation_error)) {
    SummarizeResult result = RejectedPreparedSummary(
        original, "prepared summary rejected: " + validation_error);
    std::move(done).Run(std::move(result));
    return std::nullopt;
  }

  SummarizeResult heuristic = ValidatedHeuristic(original, prepared);
  std::string model_error;
  if (!IsModelSummaryAllowed(original, &model_error)) {
    heuristic.error = std::move(model_error);
    std::move(done).Run(std::move(heuristic));
    return std::nullopt;
  }
  const std::string normalized_locale = NormalizeLocale(locale);
  std::optional<ModelPrompt> prompt = BuildValidatedModelPrompt(
      original, prepared, normalized_locale, &validation_error);
  if (!prompt) {
    heuristic.error = "outbound prompt rejected: " + validation_error;
    std::move(done).Run(std::move(heuristic));
    return std::nullopt;
  }
  if (!model_client_ || !prefs_) {
    heuristic.error = "model provider unavailable";
    std::move(done).Run(std::move(heuristic));
    return std::nullopt;
  }
  const std::optional<ModelProvider> provider = ParseModelProvider(provider_id);
  const GURL parsed_base_url(base_url);
  if (!provider || !IsAllowedModelBaseUrl(*provider, parsed_base_url) ||
      !IsValidModelName(*provider, model)) {
    heuristic.error = "invalid model provider configuration";
    std::move(done).Run(std::move(heuristic));
    return std::nullopt;
  }
  const bool local = IsLocalModelEndpoint(*provider, parsed_base_url);
  const std::string api_key =
      EffectiveModelApiKey(provider_id, base_url, std::string());
  if (ModelProviderRequiresApiKey(*provider) && api_key.empty()) {
    heuristic.error = "model provider API key is not configured";
    std::move(done).Run(std::move(heuristic));
    return std::nullopt;
  }
  if (model_client_->busy()) {
    heuristic.error = "model request already in progress";
    std::move(done).Run(std::move(heuristic));
    return std::nullopt;
  }

  heuristic.chars_sent = static_cast<int>(prompt->user.size());
  heuristic.destination = base_url;
  heuristic.stayed_on_device = local;
  return model_client_->Chat(
      *provider, base_url, api_key, model, prompt->system, prompt->user,
      base::BindOnce(&AegisService::OnModelChat, weak_ptr_factory_.GetWeakPtr(),
                     provider_id, std::move(heuristic), std::move(done)));
}

bool AegisService::CancelModelSummaryRequest(const std::string& request_id) {
  return model_client_ && model_client_->CancelChat(request_id);
}

void AegisService::OnModelChat(std::string provider,
                               SummarizeResult fallback,
                               base::OnceCallback<void(SummarizeResult)> done,
                               bool ok,
                               std::string error,
                               std::string content) {
  if (!ok) {
    fallback.error = std::move(error);
    std::move(done).Run(std::move(fallback));
    return;
  }
  SummarizeResult result = fallback;
  result.backend = std::move(provider);
  result.model_ready = true;
  if (!ParseModelJson(content, &result)) {
    result.summary = content.size() > 500 ? content.substr(0, 500) : content;
    if (result.summary.empty()) {
      fallback.error = "model returned an empty summary";
      std::move(done).Run(std::move(fallback));
      return;
    }
  }
  std::move(done).Run(std::move(result));
}

std::string AegisService::ConfiguredModelProvider() const {
  if (!prefs_) {
    return std::string(ModelProviderId(ModelProvider::kOpenAI));
  }
  const std::string configured = prefs_->GetString(prefs::kModelProvider);
  const std::optional<ModelProvider> provider = ParseModelProvider(configured);
  return provider ? std::string(ModelProviderId(*provider))
                  : std::string(ModelProviderId(ModelProvider::kOpenAI));
}

std::string AegisService::ConfiguredModelBaseUrl() const {
  const ModelProvider provider = ParseModelProvider(ConfiguredModelProvider())
                                     .value_or(ModelProvider::kOpenAI);
  if (!prefs_) {
    return std::string(DefaultModelBaseUrl(provider));
  }
  const std::optional<std::string> configured =
      NormalizeModelBaseUrl(provider, prefs_->GetString(prefs::kModelBaseUrl));
  return configured.value_or(std::string(DefaultModelBaseUrl(provider)));
}

std::string AegisService::ConfiguredModelName() const {
  const ModelProvider provider = ParseModelProvider(ConfiguredModelProvider())
                                     .value_or(ModelProvider::kOpenAI);
  if (!prefs_) {
    return std::string(DefaultModelName(provider));
  }
  const std::string configured = prefs_->GetString(prefs::kModelName);
  return IsValidModelName(provider, configured)
             ? configured
             : std::string(DefaultModelName(provider));
}

std::optional<std::string> AegisService::ResolveModelBaseUrl(
    const std::string& provider,
    const std::string& base_url) const {
  const std::optional<ModelProvider> parsed_provider =
      ParseModelProvider(provider);
  return parsed_provider ? NormalizeModelBaseUrl(*parsed_provider, base_url)
                         : std::nullopt;
}

bool AegisService::HasModelApiKey(const std::string& provider,
                                  const std::string& base_url) const {
  const std::optional<ModelProvider> parsed_provider =
      ParseModelProvider(provider);
  const std::optional<std::string> normalized_base_url =
      ResolveModelBaseUrl(provider, base_url);
  return parsed_provider && normalized_base_url &&
         model_api_keys_.contains(
             ModelCredentialKey(*parsed_provider, *normalized_base_url));
}

std::optional<std::string> AegisService::ModelApiKeyForBrowserAgent(
    const Profile* requesting_profile,
    const std::string& provider,
    const std::string& base_url) const {
  if (!IsInitializedForProfile(requesting_profile) ||
      model_credentials_loading_ || !model_credentials_loaded_) {
    return std::nullopt;
  }
  const std::optional<ModelProvider> parsed_provider =
      ParseModelProvider(provider);
  const std::optional<std::string> normalized_base_url =
      ResolveModelBaseUrl(provider, base_url);
  if (!parsed_provider || !normalized_base_url) {
    return std::nullopt;
  }
  return EffectiveModelApiKey(provider, *normalized_base_url, std::string());
}

std::string AegisService::ModelCredentialState(
    const std::string& provider,
    const std::string& base_url) const {
  if (!ResolveModelBaseUrl(provider, base_url)) {
    return "invalid";
  }
  if (model_credentials_loading_ || !model_credentials_loaded_) {
    return "loading";
  }
  return model_credentials_available_ ? "ready" : "unavailable";
}

void AegisService::PersistModelConfiguration(const std::string& provider,
                                             const std::string& base_url,
                                             const std::string& model) {
  prefs_->SetString(prefs::kModelProvider, provider);
  prefs_->SetString(prefs::kModelBaseUrl, base_url);
  prefs_->SetString(prefs::kModelName, model);
}

void AegisService::SetModelSettings(
    const std::string& provider_id,
    const std::string& base_url,
    const std::string& model,
    const std::string& api_key,
    bool clear_api_key,
    base::OnceCallback<void(bool, std::string)> done) {
  if (!prefs_) {
    std::move(done).Run(false, "profile preferences unavailable");
    return;
  }
  const std::optional<ModelProvider> provider = ParseModelProvider(provider_id);
  if (!provider) {
    std::move(done).Run(false, "unsupported model provider");
    return;
  }
  const std::string normalized_provider(ModelProviderId(*provider));
  const std::optional<std::string> normalized_base_url =
      NormalizeModelBaseUrl(*provider, base_url);
  if (!normalized_base_url) {
    std::move(done).Run(false, "invalid model provider base URL");
    return;
  }
  std::string trimmed_model(base::TrimWhitespaceASCII(model, base::TRIM_ALL));
  if (trimmed_model.empty()) {
    trimmed_model = std::string(DefaultModelName(*provider));
  }
  if (!IsValidModelName(*provider, trimmed_model)) {
    std::move(done).Run(false, "invalid model name");
    return;
  }
  if (clear_api_key && !api_key.empty()) {
    std::move(done).Run(false, "cannot set and clear an API key together");
    return;
  }
  if (!api_key.empty() && !IsValidModelApiKey(api_key)) {
    std::move(done).Run(false, "invalid API key");
    return;
  }

  if (clear_api_key) {
    if (model_credentials_loading_) {
      std::move(done).Run(false, "model credentials are still loading");
      return;
    }
    const std::string credential_key =
        ModelCredentialKey(*provider, *normalized_base_url);
    model_api_keys_.erase(credential_key);
    ScopedDictPrefUpdate update(prefs_, prefs::kModelApiKeyCiphertexts);
    update->Remove(credential_key);
    PersistModelConfiguration(normalized_provider, *normalized_base_url,
                              trimmed_model);
    NotifyObservers();
    std::move(done).Run(true, std::string());
    return;
  }
  if (api_key.empty()) {
    PersistModelConfiguration(normalized_provider, *normalized_base_url,
                              trimmed_model);
    NotifyObservers();
    std::move(done).Run(true, std::string());
    return;
  }
  if (model_credentials_loading_) {
    std::move(done).Run(false, "model credentials are still loading");
    return;
  }
  if (!g_browser_process || !g_browser_process->os_crypt_async()) {
    std::move(done).Run(false, "secure credential storage unavailable");
    return;
  }
  g_browser_process->os_crypt_async()->GetInstance(base::BindOnce(
      &AegisService::SaveModelApiKey, weak_ptr_factory_.GetWeakPtr(),
      normalized_provider, *normalized_base_url, trimmed_model, api_key,
      std::move(done)));
}

void AegisService::SaveModelApiKey(
    std::string provider,
    std::string base_url,
    std::string model,
    std::string api_key,
    base::OnceCallback<void(bool, std::string)> done,
    scoped_refptr<os_crypt_async::Encryptor> encryptor) {
  if (!prefs_ || !encryptor || !encryptor->IsEncryptionAvailable()) {
    std::move(done).Run(false, "secure credential storage unavailable");
    return;
  }
  std::optional<std::vector<uint8_t>> ciphertext =
      encryptor->EncryptString(api_key);
  if (!ciphertext) {
    std::move(done).Run(false, "failed to encrypt API key");
    return;
  }
  ScopedDictPrefUpdate update(prefs_, prefs::kModelApiKeyCiphertexts);
  const std::optional<ModelProvider> parsed_provider =
      ParseModelProvider(provider);
  const std::optional<std::string> normalized_base_url =
      parsed_provider ? NormalizeModelBaseUrl(*parsed_provider, base_url)
                      : std::nullopt;
  if (!parsed_provider || !normalized_base_url) {
    std::move(done).Run(false, "invalid model provider configuration");
    return;
  }
  const std::string credential_key =
      ModelCredentialKey(*parsed_provider, *normalized_base_url);
  update->Set(credential_key, base::Base64Encode(*ciphertext));
  model_api_keys_[credential_key] = std::move(api_key);
  model_credentials_loaded_ = true;
  model_credentials_available_ = true;
  PersistModelConfiguration(provider, *normalized_base_url, model);
  NotifyObservers();
  std::move(done).Run(true, std::string());
}

void AegisService::LoadModelCredentials() {
  model_api_keys_.clear();
  model_credentials_loading_ = false;
  model_credentials_loaded_ = false;
  model_credentials_available_ = true;
  if (!prefs_) {
    model_credentials_loaded_ = true;
    model_credentials_available_ = false;
    return;
  }
  if (prefs_->GetDict(prefs::kModelApiKeyCiphertexts).empty()) {
    model_credentials_loaded_ = true;
    return;
  }
  if (!g_browser_process || !g_browser_process->os_crypt_async()) {
    model_credentials_loaded_ = true;
    model_credentials_available_ = false;
    return;
  }
  model_credentials_loading_ = true;
  g_browser_process->os_crypt_async()->GetInstance(base::BindOnce(
      &AegisService::OnModelCredentialsLoaded, weak_ptr_factory_.GetWeakPtr()));
}

void AegisService::OnModelCredentialsLoaded(
    scoped_refptr<os_crypt_async::Encryptor> encryptor) {
  model_credentials_loading_ = false;
  model_credentials_loaded_ = true;
  model_credentials_available_ =
      encryptor && encryptor->IsEncryptionAvailable();
  if (!prefs_ || !model_credentials_available_) {
    NotifyObservers();
    return;
  }
  for (const auto [credential_key, value] :
       prefs_->GetDict(prefs::kModelApiKeyCiphertexts)) {
    if (!IsValidModelCredentialKey(credential_key) || !value.is_string()) {
      continue;
    }
    std::optional<std::vector<uint8_t>> ciphertext =
        base::Base64Decode(value.GetString());
    if (!ciphertext) {
      continue;
    }
    std::optional<std::string> api_key = encryptor->DecryptData(*ciphertext);
    if (api_key && IsValidModelApiKey(*api_key)) {
      model_api_keys_[credential_key] = std::move(*api_key);
    }
  }
  NotifyObservers();
}

std::string AegisService::EffectiveModelApiKey(
    const std::string& provider,
    const std::string& base_url,
    const std::string& candidate) const {
  if (!candidate.empty()) {
    return candidate;
  }
  const std::optional<ModelProvider> parsed_provider =
      ParseModelProvider(provider);
  const std::optional<std::string> normalized_base_url =
      ResolveModelBaseUrl(provider, base_url);
  if (!parsed_provider || !normalized_base_url) {
    return std::string();
  }
  const auto it = model_api_keys_.find(
      ModelCredentialKey(*parsed_provider, *normalized_base_url));
  return it == model_api_keys_.end() ? std::string() : it->second;
}

void AegisService::ListModels(
    const std::string& provider_id,
    const std::string& base_url,
    const std::string& api_key,
    base::OnceCallback<void(bool, std::string, std::vector<std::string>)>
        done) {
  const std::optional<ModelProvider> provider = ParseModelProvider(provider_id);
  if (!provider || !model_client_) {
    std::move(done).Run(false, "unsupported model provider", {});
    return;
  }
  const std::optional<std::string> normalized_base_url =
      NormalizeModelBaseUrl(*provider, base_url);
  if (!normalized_base_url) {
    std::move(done).Run(false, "invalid model provider base URL", {});
    return;
  }
  if (!api_key.empty() && !IsValidModelApiKey(api_key)) {
    std::move(done).Run(false, "invalid API key", {});
    return;
  }
  const std::string normalized_provider(ModelProviderId(*provider));
  const std::string effective_key =
      EffectiveModelApiKey(normalized_provider, *normalized_base_url, api_key);
  if (ModelProviderRequiresApiKey(*provider) && effective_key.empty()) {
    std::move(done).Run(false, "model provider API key is not configured", {});
    return;
  }
  model_client_->ListModels(*provider, *normalized_base_url, effective_key,
                            std::move(done));
}

void AegisService::UpdateFilterLists(base::OnceCallback<void(bool)> done) {
  if (!filter_list_updater_) {
    std::move(done).Run(false);
    return;
  }
  filter_list_updater_->UpdateNow(std::move(done));
}

bool AegisService::ShouldBlockUrl(const GURL& url) const {
  if (!IsTrackerBlockingEnabled()) {
    return false;
  }
  return FilterListMatcher::GetInstance()->ShouldBlock(url);
}

bool AegisService::ShouldShowPhishInterstitial(const GURL& url) const {
  return EvaluatePhish(url).has_value();
}

std::optional<PhishAssessment> AegisService::EvaluatePhish(
    const GURL& url) const {
  if (!IsPhishInterstitialEnabled()) {
    return std::nullopt;
  }
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || !url.has_host()) {
    return std::nullopt;
  }
  PhishAssessment assessment = AssessPhishUrl(url);
  if (MatchesBuiltinPhishRule(url)) {
    assessment.reasons.push_back({"seed_host", 100, std::string(url.host())});
    assessment.score = std::min(100, assessment.score + 100);
    assessment.should_block = true;
  }
  if (!assessment.should_block) {
    return std::nullopt;
  }
  return assessment;
}

PhishAssessment AegisService::AssessPhishUrl(const GURL& url) const {
  PhishAssessment assessment = AssessPhishingUrl(url);
  if (!threat_feed_updater_) {
    return assessment;
  }
  const std::optional<ThreatMatch> match =
      threat_feed_updater_->Match(url, NowUnixSeconds());
  if (!match) {
    return assessment;
  }
  const std::vector<std::string> source_names =
      ThreatSourceNames(match->sources);
  const std::string detail = base::JoinString(source_names, "+");
  const bool exact_url = match->kind == ThreatEntryKind::kUrl;
  const int weight = match->stale ? 25 : (exact_url ? 100 : 35);
  const std::string code =
      match->stale
          ? "stale_threat_feed_match"
          : (exact_url ? "threat_feed_match" : "threat_feed_domain_match");
  assessment.reasons.push_back({code, weight, detail});
  assessment.score = std::min(100, assessment.score + weight);
  assessment.should_block = assessment.score >= kPhishBlockThreshold;
  return assessment;
}

void AegisService::PushPrivacyEvent(PrivacyEvent event) {
  privacy_events_.Record(std::move(event));
  if (!observer_notification_timer_.IsRunning()) {
    observer_notification_timer_.Start(
        FROM_HERE, kObserverNotificationInterval,
        base::BindRepeating(&AegisService::NotifyObservers,
                            base::Unretained(this)));
  }
}

void AegisService::NotifyObservers() {
  for (AegisServiceObserver& observer : observers_) {
    observer.OnAegisStateChanged();
  }
}

void AegisService::RecordStrippedParams(const std::string& host,
                                        const std::vector<std::string>& keys,
                                        const std::string& document_id,
                                        const std::string& site_key) {
  if (keys.empty()) {
    return;
  }
  PrivacyEvent event;
  event.document_id = document_id;
  event.site_key = SiteKeyForHost(site_key.empty() ? host : site_key);
  event.kind = "param";
  event.reason = "navigation";
  event.display_domain = SiteKeyForHost(host);
  event.details = SafeDetails(keys);
  event.first_unix_seconds = NowUnixSeconds();
  event.last_unix_seconds = event.first_unix_seconds;
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordStrippedReferrer(const std::string& host,
                                          const std::vector<std::string>& keys,
                                          const std::string& document_id,
                                          const std::string& site_key) {
  if (keys.empty()) {
    return;
  }
  PrivacyEvent event;
  event.document_id = document_id;
  event.site_key = SiteKeyForHost(site_key.empty() ? host : site_key);
  event.kind = "param";
  event.reason = "referrer";
  event.display_domain = SiteKeyForHost(host);
  event.details = SafeDetails(keys);
  event.first_unix_seconds = NowUnixSeconds();
  event.last_unix_seconds = event.first_unix_seconds;
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordDeletedCookie(const std::string& name,
                                       const std::string& domain,
                                       const std::string& category) {
  PrivacyEvent event;
  event.site_key = SiteKeyForHost(domain);
  event.kind = "cookie";
  event.reason = SafeToken(category, 64);
  event.display_domain = SiteKeyForHost(domain);
  event.first_unix_seconds = NowUnixSeconds();
  event.last_unix_seconds = event.first_unix_seconds;
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordBounceClear(const std::string& site) {
  if (site.empty()) {
    return;
  }
  PrivacyEvent event;
  event.site_key = SiteKeyForHost(site);
  event.kind = "bounce";
  event.reason = "storage-clear";
  event.display_domain = SiteKeyForHost(site);
  event.first_unix_seconds = NowUnixSeconds();
  event.last_unix_seconds = event.first_unix_seconds;
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordBlockedRequest(const GURL& url,
                                        const std::string& reason,
                                        const std::string& cname_alias,
                                        const std::string& document_id,
                                        const std::string& site_key) {
  if (!url.is_valid() || !url.has_host()) {
    return;
  }
  PrivacyEvent event;
  event.document_id = document_id;
  event.site_key =
      SiteKeyForHost(site_key.empty() ? std::string(url.host()) : site_key);
  event.kind = "block";
  event.reason = SafeToken(reason, 64);
  event.display_domain = SiteKeyForHost(std::string(url.host()));
  if (!cname_alias.empty()) {
    event.details = {SiteKeyForHost(cname_alias)};
  }
  event.first_unix_seconds = NowUnixSeconds();
  event.last_unix_seconds = event.first_unix_seconds;
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordPhishBlock(const std::string& host,
                                    const std::string& reason,
                                    const std::string& document_id) {
  if (host.empty()) {
    return;
  }
  PrivacyEvent event;
  event.document_id = document_id;
  event.site_key = SiteKeyForHost(host);
  event.kind = "phish";
  event.reason = SafeToken(reason, 64);
  event.display_domain = SiteKeyForHost(host);
  event.first_unix_seconds = NowUnixSeconds();
  event.last_unix_seconds = event.first_unix_seconds;
  PushPrivacyEvent(std::move(event));
}

std::vector<PrivacyEvent> AegisService::RecentPrivacyEvents() const {
  return privacy_events_.Recent();
}

std::string AegisService::ResolveDocumentContext(
    const std::string& local_frame_token,
    int render_process_id,
    std::string* site_key) const {
  const std::optional<base::UnguessableToken> token =
      base::UnguessableToken::DeserializeFromString(local_frame_token);
  if (!token) {
    *site_key = SiteKeyForHost(*site_key);
    return std::string();
  }
  content::RenderFrameHost* frame = content::RenderFrameHost::FromFrameToken(
      content::GlobalRenderFrameHostToken{render_process_id,
                                          blink::LocalFrameToken(*token)});
  if (!frame || !frame->GetOutermostMainFrame()) {
    *site_key = SiteKeyForHost(*site_key);
    return local_frame_token;
  }
  content::RenderFrameHost* main_frame = frame->GetOutermostMainFrame();
  *site_key =
      SiteKeyForHost(std::string(main_frame->GetLastCommittedURL().host()));
  return main_frame->GetReportingSource().ToString();
}

}  // namespace aegis
