// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_service.cc

#include "chrome/browser/aegis/aegis_service.h"

#include <algorithm>

#include "base/logging.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/singleton.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/aegis/aegis_ai_control.h"
#include "chrome/browser/aegis/aegis_bounce_observer.h"
#include "chrome/browser/aegis/aegis_cookie_janitor.h"
#include "chrome/browser/aegis/filter_list_updater.h"
#include "chrome/browser/aegis/ollama_sidecar.h"
#include "chrome/browser/aegis/policy_worker.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/aegis_block_reporter.h"
#include "chrome/common/aegis/builtin_phish_hosts.h"
#include "chrome/common/aegis/cdp_ws_hook.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/filter_list_matcher.h"
#include "chrome/common/aegis/phish_score.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/btm_service.h"
#include "url/gurl.h"

namespace aegis {

// static
AegisService* AegisService::GetInstance() {
  return base::Singleton<AegisService>::get();
}

AegisService::AegisService() = default;

AegisService::~AegisService() {
  CdpWsHook::SetClientCountCallback({});
}

void AegisService::InitializeForProfile(Profile* profile) {
  if (!IsEnabled()) {
    VLOG(1) << "Aegis disabled by feature flag";
    return;
  }
  prefs_ = profile->GetPrefs();
  profile_ = profile;
  initialized_ = true;
  if (base::FeatureList::IsEnabled(features::kAegisFilterListUpdater)) {
    filter_list_updater_ = std::make_unique<FilterListUpdater>(profile);
    // LoadFromDisk 完成后再决定是否自动更新，避免缓存未读完就重新下载。
    filter_list_updater_->LoadFromDisk();
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
  if (base::FeatureList::IsEnabled(features::kAegisPolicyWorker) &&
      IsPolicyWorkerEnabled()) {
    // JS bundle is evaluated in chrome://aegis. Do not boot V8 in the browser
    // process — LoadV8Snapshot() is fatal when the snapshot file is absent.
    PolicyWorker::GetInstance()->Start();
  }
  ollama_ = std::make_unique<OllamaSidecar>();
  InstallReporterCallbacks();
#if !BUILDFLAG(IS_ANDROID)
  ai_control_ = std::make_unique<AiControl>();
  if (IsAiControlEnabled()) {
    ai_control_->Start();
  }
#endif
  LOG(INFO) << "GCSA-aegis initialized for profile"
            << (IsTrackerBlockingEnabled() ? " (tracker blocking on)"
                                           : " (tracker blocking off)");
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
  if (!IsEnabled() ||
      !base::FeatureList::IsEnabled(features::kAegisFingerprintGuard)) {
    return false;
  }
  if (!prefs_) {
    return true;
  }
  return prefs_->GetBoolean(prefs::kFingerprintGuardEnabled);
}

void AegisService::SetTrackerBlockingEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kTrackerBlockingEnabled, enabled);
  }
}

void AegisService::SetPhishInterstitialEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kPhishInterstitialEnabled, enabled);
  }
}

void AegisService::SetFingerprintGuardEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kFingerprintGuardEnabled, enabled);
  }
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
}

void AegisService::SetCookieJanitorEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kCookieJanitorEnabled, enabled);
  }
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
}

void AegisService::SetBounceTrackingEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kBounceTrackingEnabled, enabled);
  }
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
  if (enabled && base::FeatureList::IsEnabled(features::kAegisPolicyWorker)) {
    PolicyWorker::GetInstance()->Start();
  }
}

void AegisService::SetPrivacyAiEnabled(bool enabled) {
  if (prefs_) {
    prefs_->SetBoolean(prefs::kPrivacyAiEnabled, enabled);
  }
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
    ai_control_->Start();
    return;
  }
  ai_control_->Stop();
#endif
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
  return true;
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
  if (count == 0) {
    event.label = "agent disconnected";
  } else {
    event.label = "agent connected (" + base::NumberToString(count) + ")";
  }
  event.unix_seconds =
      (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
  PushPrivacyEvent(std::move(event));
}

void AegisService::BindAegisHost(
    mojo::PendingReceiver<chrome::mojom::AegisHost> receiver) {
  host_receivers_.Add(this, std::move(receiver));
}

void AegisService::ReportBlockedRequest(const std::string& url,
                                        const std::string& reason,
                                        const std::string& cname_alias) {
  RecordBlockedRequest(GURL(url), reason, cname_alias);
}

void AegisService::ReportStrippedReferrer(
    const std::string& host,
    const std::vector<std::string>& keys) {
  RecordStrippedReferrer(host, keys);
}

void AegisService::ReportStrippedParams(
    const std::string& host,
    const std::vector<std::string>& keys) {
  RecordStrippedParams(host, keys);
}

void AegisService::InstallReporterCallbacks() {
  BlockReporter::SetBlockedCallback(base::BindRepeating(
      [](const GURL& url, const std::string& reason,
         const std::string& cname_alias) {
        AegisService::GetInstance()->RecordBlockedRequest(url, reason,
                                                          cname_alias);
      }));
  BlockReporter::SetReferrerCallback(base::BindRepeating(
      [](const std::string& host, const std::vector<std::string>& keys) {
        AegisService::GetInstance()->RecordStrippedReferrer(host, keys);
      }));
  BlockReporter::SetParamsCallback(base::BindRepeating(
      [](const std::string& host, const std::vector<std::string>& keys) {
        AegisService::GetInstance()->RecordStrippedParams(host, keys);
      }));
  CdpWsHook::SetClientCountCallback(base::BindRepeating(
      [](size_t count) {
        AegisService::GetInstance()->SetCdpWebSocketClientCount(count);
      }));
}

bool AegisService::IsPolicyWorkerReady() const {
  // Renderer-side bundle is always packed with chrome://aegis.
  return IsPolicyWorkerEnabled();
}

std::string AegisService::PolicyWorkerError() const {
  return PolicyWorker::GetInstance()->last_error();
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

SummarizeResult FallbackSummary(const PageSnapshot& snapshot,
                                const std::string& locale) {
  SummarizeResult result;
  result.ok = true;
  result.url = snapshot.url;
  result.backend = "mock";
  result.model_ready = true;
  std::string text = snapshot.text_sample;
  result.summary = text.size() > 220 ? text.substr(0, 220) : text;
  if (result.summary.empty()) {
    result.summary = locale == "en" ? "No readable page text was captured."
                                    : "未能提取可读页面文本。";
  }
  if (snapshot.password_fields > 0) {
    result.risks.push_back(locale == "en"
                               ? "Page contains password fields — verify the "
                                 "domain before signing in."
                               : "页面含密码字段，登录前请确认域名。");
  }
  AttachLocalProvenance(&result, snapshot);
  return result;
}

SummarizeResult ParseHeuristic(const std::string& json,
                               const PageSnapshot& snapshot) {
  std::optional<base::Value> parsed =
      base::JSONReader::Read(json, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!parsed || !parsed->is_dict()) {
    SummarizeResult failed = FallbackSummary(snapshot, "zh-CN");
    failed.worker_ready = false;
    failed.error = "invalid worker json";
    return failed;
  }
  const base::DictValue& dict = parsed->GetDict();
  if (const std::string* err = dict.FindString("error")) {
    SummarizeResult failed = FallbackSummary(snapshot, "zh-CN");
    failed.worker_ready = false;
    failed.error = *err;
    return failed;
  }
  SummarizeResult result;
  result.ok = true;
  result.url = snapshot.url;
  result.worker_ready = true;
  result.summary = dict.FindString("summary") ? *dict.FindString("summary") : "";
  result.backend = dict.FindString("backend") ? *dict.FindString("backend")
                                              : "mock";
  result.model_ready = dict.FindBool("modelReady").value_or(true);
  result.bullets = StringList(dict, "bullets");
  result.risks = StringList(dict, "risks");
  AttachLocalProvenance(&result, snapshot);
  return result;
}

std::string ExtractOllamaContent(const std::string& body) {
  std::optional<base::Value> parsed =
      base::JSONReader::Read(body, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!parsed || !parsed->is_dict()) {
    return std::string();
  }
  const base::DictValue* message = parsed->GetDict().FindDict("message");
  if (!message) {
    return std::string();
  }
  const std::string* content = message->FindString("content");
  return content ? *content : std::string();
}

bool ParseModelJson(const std::string& raw, SummarizeResult* result) {
  const size_t start = raw.find('{');
  const size_t end = raw.rfind('}');
  if (start == std::string::npos || end == std::string::npos || end <= start) {
    return false;
  }
  std::optional<base::Value> parsed = base::JSONReader::Read(
      raw.substr(start, end - start + 1),
      base::JSON_PARSE_CHROMIUM_EXTENSIONS);
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

void AegisService::SummarizePage(
    PageSnapshot snapshot,
    const std::string& locale,
    base::OnceCallback<void(SummarizeResult)> done) {
  if (!IsPrivacyAiEnabled()) {
    SummarizeResult result;
    result.error = "privacy ai disabled";
    std::move(done).Run(std::move(result));
    return;
  }
  const std::string loc = NormalizeLocale(locale);
  if (!IsPolicyWorkerEnabled() || !PolicyWorker::GetInstance()->ready()) {
    SummarizeResult result = FallbackSummary(snapshot, loc);
    result.worker_ready = PolicyWorker::GetInstance()->ready();
    std::move(done).Run(std::move(result));
    return;
  }

  base::DictValue req;
  req.Set("op", "summarize");
  req.Set("locale", loc);
  base::DictValue snap;
  snap.Set("url", snapshot.url);
  snap.Set("title", snapshot.title);
  snap.Set("textSample", snapshot.text_sample);
  snap.Set("passwordFields", snapshot.password_fields);
  snap.Set("forms", snapshot.forms);
  req.Set("snapshot", std::move(snap));
  std::string json;
  base::JSONWriter::Write(req, &json);
  PolicyWorker::GetInstance()->Evaluate(
      std::move(json),
      base::BindOnce(&AegisService::OnHeuristicSummary, base::Unretained(this),
                     std::move(snapshot), loc, std::move(done)));
}

void AegisService::OnHeuristicSummary(
    PageSnapshot snapshot,
    std::string locale,
    base::OnceCallback<void(SummarizeResult)> done,
    std::string json) {
  SummarizeResult heuristic = ParseHeuristic(json, snapshot);
  heuristic.worker_ready = true;
  if (!ollama_ || heuristic.summary.empty()) {
    std::move(done).Run(std::move(heuristic));
    return;
  }

  base::DictValue req;
  req.Set("op", "buildPrompt");
  req.Set("locale", locale);
  base::DictValue snap;
  snap.Set("url", snapshot.url);
  snap.Set("title", snapshot.title);
  snap.Set("textSample", snapshot.text_sample);
  snap.Set("passwordFields", snapshot.password_fields);
  snap.Set("forms", snapshot.forms);
  req.Set("snapshot", std::move(snap));
  std::string prompt_json;
  base::JSONWriter::Write(req, &prompt_json);
  PolicyWorker::GetInstance()->Evaluate(
      std::move(prompt_json),
      base::BindOnce(&AegisService::OnPromptReady, base::Unretained(this),
                     std::move(heuristic), std::move(locale), std::move(done)));
}

void AegisService::OnPromptReady(
    SummarizeResult heuristic,
    std::string locale,
    base::OnceCallback<void(SummarizeResult)> done,
    std::string json) {
  std::optional<base::Value> parsed =
      base::JSONReader::Read(json, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!parsed || !parsed->is_dict()) {
    std::move(done).Run(std::move(heuristic));
    return;
  }
  const base::DictValue& dict = parsed->GetDict();
  const std::string system =
      dict.FindString("system") ? *dict.FindString("system") : "";
  const std::string user =
      dict.FindString("user") ? *dict.FindString("user") : "";
  if (system.empty() || user.empty() || !ollama_ || !prefs_) {
    std::move(done).Run(std::move(heuristic));
    return;
  }
  const std::string base_url = prefs_->GetString(prefs::kOllamaBaseUrl);
  ollama_->Probe(
      base_url,
      base::BindOnce(&AegisService::OnOllamaReady, base::Unretained(this),
                     std::move(heuristic), system, user, std::move(done)));
  (void)locale;
}

void AegisService::OnOllamaReady(
    SummarizeResult heuristic,
    std::string system,
    std::string user,
    base::OnceCallback<void(SummarizeResult)> done,
    bool ok,
    std::string body) {
  if (!ok || !ollama_ || !prefs_) {
    std::move(done).Run(std::move(heuristic));
    return;
  }
  heuristic.chars_sent = static_cast<int>(user.size());
  heuristic.destination = prefs_->GetString(prefs::kOllamaBaseUrl);
  heuristic.stayed_on_device = true;
  (void)body;
  ollama_->Chat(prefs_->GetString(prefs::kOllamaBaseUrl),
                prefs_->GetString(prefs::kOllamaModel), system, user,
                base::BindOnce(&AegisService::OnOllamaChat,
                               base::Unretained(this), std::move(heuristic),
                               std::move(done)));
}

void AegisService::OnOllamaChat(SummarizeResult heuristic,
                               base::OnceCallback<void(SummarizeResult)> done,
                               bool ok,
                               std::string body) {
  if (!ok) {
    std::move(done).Run(std::move(heuristic));
    return;
  }
  const std::string content = ExtractOllamaContent(body);
  SummarizeResult result = heuristic;
  result.backend = "ollama";
  result.model_ready = true;
  if (!ParseModelJson(content, &result)) {
    result.summary = content.size() > 500 ? content.substr(0, 500) : content;
    if (result.summary.empty()) {
      std::move(done).Run(std::move(heuristic));
      return;
    }
  }
  std::move(done).Run(std::move(result));
}

void AegisService::ChatWithOllama(
    const std::string& system,
    const std::string& user,
    base::OnceCallback<void(SummarizeResult)> done) {
  SummarizeResult empty;
  empty.ok = true;
  empty.backend = "mock";
  if (!IsPrivacyAiEnabled() || !ollama_ || !prefs_ || system.empty() ||
      user.empty()) {
    empty.ok = false;
    empty.error = "privacy ai disabled";
    std::move(done).Run(std::move(empty));
    return;
  }
  ollama_->Probe(
      prefs_->GetString(prefs::kOllamaBaseUrl),
      base::BindOnce(&AegisService::OnOllamaReady, base::Unretained(this),
                     std::move(empty), system, user, std::move(done)));
}

namespace {

bool IsLoopbackOllamaUrl(const GURL& url) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  const std::string host(url.host());
  return host == "127.0.0.1" || host == "localhost" || host == "::1" ||
         host == "[::1]";
}

std::vector<std::string> ParseOllamaModels(const std::string& body) {
  std::vector<std::string> models;
  std::optional<base::Value> parsed =
      base::JSONReader::Read(body, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!parsed || !parsed->is_dict()) {
    return models;
  }
  const base::ListValue* list = parsed->GetDict().FindList("models");
  if (!list) {
    return models;
  }
  for (const base::Value& value : *list) {
    if (!value.is_dict()) {
      continue;
    }
    const std::string* name = value.GetDict().FindString("name");
    if (name && !name->empty()) {
      models.push_back(*name);
    }
  }
  return models;
}

}  // namespace

std::string AegisService::OllamaBaseUrl() const {
  if (!prefs_) {
    return "http://127.0.0.1:11434";
  }
  return prefs_->GetString(prefs::kOllamaBaseUrl);
}

std::string AegisService::OllamaModel() const {
  if (!prefs_) {
    return "llama3.2:3b";
  }
  return prefs_->GetString(prefs::kOllamaModel);
}

bool AegisService::SetOllamaSettings(const std::string& url,
                                    const std::string& model) {
  if (!prefs_) {
    return false;
  }
  std::string trimmed_url(base::TrimWhitespaceASCII(url, base::TRIM_ALL));
  if (trimmed_url.empty()) {
    trimmed_url = "http://127.0.0.1:11434";
  }
  const GURL parsed(trimmed_url);
  if (!IsLoopbackOllamaUrl(parsed)) {
    return false;
  }
  prefs_->SetString(prefs::kOllamaBaseUrl, parsed.spec());
  std::string trimmed_model(base::TrimWhitespaceASCII(model, base::TRIM_ALL));
  if (trimmed_model.empty()) {
    trimmed_model = "llama3.2:3b";
  }
  prefs_->SetString(prefs::kOllamaModel, trimmed_model);
  return true;
}

void AegisService::ProbeOllama(
    const std::string& url,
    base::OnceCallback<void(bool, std::string, std::vector<std::string>)>
        done) {
  if (!ollama_) {
    std::move(done).Run(false, "ollama sidecar missing", {});
    return;
  }
  std::string trimmed(base::TrimWhitespaceASCII(url, base::TRIM_ALL));
  if (trimmed.empty()) {
    trimmed = OllamaBaseUrl();
  }
  const GURL parsed(trimmed);
  if (!IsLoopbackOllamaUrl(parsed)) {
    std::move(done).Run(false, "ollama url must be loopback", {});
    return;
  }
  ollama_->Probe(parsed.spec(),
                 base::BindOnce(&AegisService::OnOllamaProbed,
                                base::Unretained(this), std::move(done)));
}

void AegisService::OnOllamaProbed(
    base::OnceCallback<void(bool, std::string, std::vector<std::string>)> done,
    bool ok,
    std::string body) {
  if (!ok) {
    std::move(done).Run(false, body.empty() ? "ollama not reachable" : body,
                        {});
    return;
  }
  std::move(done).Run(true, std::string(), ParseOllamaModels(body));
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
  if (IsPhishHostAllowedForSession(std::string(url.host()))) {
    return std::nullopt;
  }

  PhishAssessment assessment = AssessPhishingUrl(url);
  if (MatchesBuiltinPhishRule(url)) {
    assessment.reasons.push_back(
        {"seed_host", 100, std::string(url.host())});
    assessment.score = std::min(100, assessment.score + 100);
    assessment.should_block = true;
  }
  if (!assessment.should_block) {
    return std::nullopt;
  }
  return assessment;
}

void AegisService::AllowPhishHostForSession(const std::string& host) {
  if (host.empty()) {
    return;
  }
  session_allowed_phish_hosts_.insert(base::ToLowerASCII(host));
}

bool AegisService::IsPhishHostAllowedForSession(
    const std::string& host) const {
  if (host.empty()) {
    return false;
  }
  return session_allowed_phish_hosts_.contains(base::ToLowerASCII(host));
}

void AegisService::PushPrivacyEvent(PrivacyEvent event) {
  if (!privacy_events_.empty() &&
      privacy_events_.front().kind == event.kind &&
      privacy_events_.front().label == event.label) {
    return;
  }
  privacy_events_.push_front(std::move(event));
  while (privacy_events_.size() > 40) {
    privacy_events_.pop_back();
  }
}

void AegisService::RecordStrippedParams(const std::string& host,
                                        const std::vector<std::string>& keys) {
  if (keys.empty()) {
    return;
  }
  PrivacyEvent event;
  event.kind = "param";
  event.label = host.empty() ? base::JoinString(keys, ", ")
                             : host + ": " + base::JoinString(keys, ", ");
  event.unix_seconds =
      (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordStrippedReferrer(
    const std::string& host,
    const std::vector<std::string>& keys) {
  if (keys.empty()) {
    return;
  }
  PrivacyEvent event;
  event.kind = "param";
  event.label = "Referer " + (host.empty() ? base::JoinString(keys, ", ")
                                           : host + ": " +
                                                 base::JoinString(keys, ", "));
  event.unix_seconds =
      (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordDeletedCookie(const std::string& name,
                                       const std::string& domain,
                                       const std::string& category) {
  PrivacyEvent event;
  event.kind = "cookie";
  event.label = name + " @ " + domain + " (" + category + ")";
  event.unix_seconds =
      (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordBounceClear(const std::string& site) {
  if (site.empty()) {
    return;
  }
  PrivacyEvent event;
  event.kind = "bounce";
  event.label = site;
  event.unix_seconds =
      (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordBlockedRequest(const GURL& url,
                                        const std::string& reason,
                                        const std::string& cname_alias) {
  if (!url.is_valid() || !url.has_host()) {
    return;
  }
  std::string path(url.path());
  if (path.empty()) {
    path = "/";
  }
  if (path.size() > 96) {
    path = path.substr(0, 96) + "...";
  }
  PrivacyEvent event;
  event.kind = "block";
  event.label = std::string(url.host()) + path + " (" + reason + ")";
  if (!cname_alias.empty()) {
    event.label += " -> " + cname_alias;
  }
  event.unix_seconds =
      (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
  PushPrivacyEvent(std::move(event));
}

void AegisService::RecordPhishBlock(const std::string& host,
                                    const std::string& reason) {
  if (host.empty()) {
    return;
  }
  PrivacyEvent event;
  event.kind = "phish";
  event.label = reason.empty() ? host : host + " — " + reason;
  event.unix_seconds =
      (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
  PushPrivacyEvent(std::move(event));
}

std::vector<PrivacyEvent> AegisService::RecentPrivacyEvents() const {
  return {privacy_events_.begin(), privacy_events_.end()};
}

}  // namespace aegis
