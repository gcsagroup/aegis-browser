// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_service.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_SERVICE_H_
#define CHROME_BROWSER_AEGIS_AEGIS_SERVICE_H_

#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/singleton.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/scoped_observation.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/aegis/privacy_event_store.h"
#include "chrome/browser/aegis/summary_policy.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/common/aegis/miner_guard_model.h"
#include "chrome/common/aegis/phish_score.h"
#include "chrome/common/renderer_configuration.mojom.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/receiver_set.h"

class GURL;
class PrefService;
class Profile;

namespace os_crypt_async {
class Encryptor;
}

namespace content {
class WebContents;
}

namespace aegis {

class FilterListUpdater;
class ThreatFeedUpdater;
class CookieJanitor;
class ModelProviderClient;
class AiControl;

struct PageSnapshot {
  std::string url;
  std::string title;
  std::string text_sample;
  int password_fields = 0;
  int forms = 0;
};

struct SummarizeResult {
  bool ok = false;
  std::string error;
  std::string url;
  std::string summary;
  std::vector<std::string> bullets;
  std::vector<std::string> risks;
  std::string backend;
  bool model_ready = false;
  bool worker_ready = false;
  int chars_in = 0;
  int chars_sent = 0;
  bool stayed_on_device = true;
  std::string destination;
};

struct PagePrivacySummary {
  std::string site_key;
  int total = 0;
  int blocked = 0;
  int params = 0;
  int cookies = 0;
  int bounces = 0;
  int phishing = 0;
  int miner_alerts = 0;
  bool paused = false;
  std::vector<PrivacyEvent> events;
};

class AegisServiceObserver : public base::CheckedObserver {
 public:
  virtual void OnAegisStateChanged() = 0;
};

class AegisService : public chrome::mojom::AegisHost, public ProfileObserver {
 public:
  static AegisService* GetInstance();

  AegisService(const AegisService&) = delete;
  AegisService& operator=(const AegisService&) = delete;

  // Called from browser startup once Profile is ready.
  void InitializeForProfile(Profile* profile);

  // 进程单例的临时边界：只有当前服务所属的普通 Profile 可访问，
  // 其他 Profile 与无痕 Profile 必须 fail closed。长期仍需改为
  // ProfileKeyedService。
  bool IsInitializedForProfile(const Profile* profile) const;

  bool IsEnabled() const;
  bool IsTrackerBlockingEnabled() const;
  bool IsPhishInterstitialEnabled() const;
  bool IsFingerprintGuardEnabled() const;
  bool IsMinerGuardEnabled() const;
  bool IsFilterListAutoUpdateEnabled() const;
  bool IsLinkSanitizeEnabled() const;
  bool IsCookieJanitorEnabled() const;
  bool IsCnameUncloakEnabled() const;
  bool IsBounceTrackingEnabled() const;
  bool IsPolicyWorkerEnabled() const;
  bool IsPrivacyAiEnabled() const;
  bool IsAiControlEnabled() const;
  bool IsFilterListUpdating() const;
  int FilterListHostCount() const;
  int64_t FilterListLastUpdated() const;
  std::string FilterListLastError() const;

  void SetTrackerBlockingEnabled(bool enabled);
  void SetPhishInterstitialEnabled(bool enabled);
  void SetFingerprintGuardEnabled(bool enabled);
  void SetMinerGuardEnabled(bool enabled);
  void SetFilterListAutoUpdateEnabled(bool enabled);
  void SetLinkSanitizeEnabled(bool enabled);
  void SetCookieJanitorEnabled(bool enabled);
  void SetCnameUncloakEnabled(bool enabled);
  void SetBounceTrackingEnabled(bool enabled);
  void SetPolicyWorkerEnabled(bool enabled);
  void SetPrivacyAiEnabled(bool enabled);
  void SetAiControlEnabled(bool enabled);
  void UpdateFilterLists(base::OnceCallback<void(bool)> done);

  void AddObserver(AegisServiceObserver* observer);
  void RemoveObserver(AegisServiceObserver* observer);

  PagePrivacySummary GetPageSummary(content::WebContents* web_contents) const;
  bool IsSitePaused(const std::string& host) const;
  void SetSitePaused(const std::string& host,
                     bool paused,
                     base::TimeDelta duration = base::Minutes(10));
  bool ShouldShowAwarenessIntro() const;
  void MarkAwarenessIntroShown();

  static std::string DocumentIdForWebContents(
      content::WebContents* web_contents);

  // Privacy AI accepts only a request-scoped, browser-validated structured
  // preparation. The browser owns the outbound prompt template.
  std::optional<std::string> SummarizePreparedPage(
      PageSnapshot original,
      PreparedSummary prepared,
      const std::string& locale,
      const std::string& provider_id,
      const std::string& base_url,
      const std::string& model,
      base::OnceCallback<void(SummarizeResult)> done);
  bool CancelModelSummaryRequest(const std::string& request_id);
  std::string ConfiguredModelProvider() const;
  std::string ConfiguredModelBaseUrl() const;
  std::string ConfiguredModelName() const;
  std::optional<std::string> ResolveModelBaseUrl(
      const std::string& provider,
      const std::string& base_url) const;
  bool HasModelApiKey(const std::string& provider,
                      const std::string& base_url) const;
  // Browser-process-only credential access for the Profile-scoped Agent
  // transport. The secret is never exposed through Mojo or WebUI.
  std::optional<std::string> ModelApiKeyForBrowserAgent(
      const Profile* requesting_profile,
      const std::string& provider,
      const std::string& base_url) const;
  std::string ModelCredentialState(const std::string& provider,
                                   const std::string& base_url) const;
  void SetModelSettings(
      const std::string& provider,
      const std::string& base_url,
      const std::string& model,
      const std::string& api_key,
      bool clear_api_key,
      base::OnceCallback<void(bool ok, std::string error)> done);
  void ListModels(
      const std::string& provider,
      const std::string& base_url,
      const std::string& api_key,
      base::OnceCallback<void(bool ok,
                              std::string error,
                              std::vector<std::string> models)> done);
  int AiControlPort() const;
  std::string AiControlAddress() const;
  bool AiControlLoopbackOnly() const;
  bool AiControlRunning() const;
  size_t CdpWebSocketClientCount() const;
  void SetCdpWebSocketClientCount(size_t count);

  // Renderer → browser：把拦截记到会话清单。
  void BindAegisHost(mojo::PendingReceiver<chrome::mojom::AegisHost> receiver,
                     int render_process_id);

  // chrome.mojom.AegisHost:
  void ReportBlockedRequest(const std::string& url,
                            const std::string& reason,
                            const std::string& cname_alias,
                            const std::string& source_site,
                            const std::string& local_frame_token) override;
  void ReportStrippedReferrer(const std::string& host,
                              const std::vector<std::string>& keys,
                              const std::string& source_site,
                              const std::string& local_frame_token) override;
  void ReportStrippedParams(const std::string& host,
                            const std::vector<std::string>& keys,
                            const std::string& source_site,
                            const std::string& local_frame_token) override;
  // ProfileObserver:
  void OnProfileWillBeDestroyed(Profile* profile) override;

  // Host-rule match against builtin seed + compiled EasyList. Callers should
  // skip main-document navigations (RequestDestination::kDocument).
  bool ShouldBlockUrl(const GURL& url) const;

  // Main-frame phishing interstitial decision (seed rules + URL heuristics).
  // Returns the assessment when the page should be blocked.
  std::optional<PhishAssessment> EvaluatePhish(const GURL& url) const;
  PhishAssessment AssessPhishUrl(const GURL& url) const;
  bool ShouldShowPhishInterstitial(const GURL& url) const;

  void RecordStrippedParams(const std::string& host,
                            const std::vector<std::string>& keys,
                            const std::string& document_id = std::string(),
                            const std::string& site_key = std::string());
  void RecordStrippedReferrer(const std::string& host,
                              const std::vector<std::string>& keys,
                              const std::string& document_id = std::string(),
                              const std::string& site_key = std::string());
  void RecordDeletedCookie(const std::string& name,
                           const std::string& domain,
                           const std::string& category);
  void RecordBounceClear(const std::string& site);
  void RecordBlockedRequest(const GURL& url,
                            const std::string& reason,
                            const std::string& cname_alias,
                            const std::string& document_id = std::string(),
                            const std::string& site_key = std::string());
  void RecordPhishBlock(const std::string& host,
                        const std::string& reason,
                        const std::string& document_id = std::string());
  std::vector<PrivacyEvent> RecentPrivacyEvents() const;

  PrefService* prefs() const { return prefs_; }

 private:
  friend struct base::DefaultSingletonTraits<AegisService>;
  AegisService();
  ~AegisService() override;

  bool initialized_ = false;
  raw_ptr<PrefService> prefs_ = nullptr;
  raw_ptr<Profile> profile_ = nullptr;
  PrivacyEventStore privacy_events_;
  std::unique_ptr<FilterListUpdater> filter_list_updater_;
  std::unique_ptr<ThreatFeedUpdater> threat_feed_updater_;
  std::unique_ptr<CookieJanitor> cookie_janitor_;
  std::unique_ptr<ModelProviderClient> model_client_;
  std::map<std::string, std::string> model_api_keys_;
  bool model_credentials_loading_ = false;
  bool model_credentials_loaded_ = false;
  bool model_credentials_available_ = true;
  std::unique_ptr<AiControl> ai_control_;
  mojo::ReceiverSet<chrome::mojom::AegisHost, int> host_receivers_;
  base::ScopedObservation<Profile, ProfileObserver> profile_observation_{this};
  base::ObserverList<AegisServiceObserver> observers_;
  base::RetainingOneShotTimer observer_notification_timer_;
  size_t cdp_ws_clients_ = 0;

  struct MinerDocumentState {
    MinerSignalWindow window;
    base::TimeTicks last_update;
    bool likely_mining_reported = false;
  };
  std::map<std::string, MinerDocumentState> miner_documents_;

  void InstallReporterCallbacks();
  void ClearReporterCallbacks();
  void OnBlockedReport(GURL url,
                       std::string reason,
                       std::string cname_alias,
                       std::string source_site,
                       std::string document_id);
  void OnStrippedReferrerReport(std::string host,
                                std::vector<std::string> keys,
                                std::string source_site,
                                std::string document_id);
  void OnStrippedParamsReport(std::string host,
                              std::vector<std::string> keys,
                              std::string source_site,
                              std::string document_id);
  void OnMinerSignals(std::string document_id,
                      std::string site_key,
                      std::string display_domain,
                      MinerRuntimeSignals signals);
  bool IsCurrentProfileDocument(const std::string& document_id,
                                const std::string& site_key) const;
  void ShutdownForProfile();
  void OnModelChat(std::string provider,
                   SummarizeResult fallback,
                   base::OnceCallback<void(SummarizeResult)> done,
                   bool ok,
                   std::string error,
                   std::string content);
  void LoadModelCredentials();
  void OnModelCredentialsLoaded(
      scoped_refptr<os_crypt_async::Encryptor> encryptor);
  void SaveModelApiKey(std::string provider,
                       std::string base_url,
                       std::string model,
                       std::string api_key,
                       base::OnceCallback<void(bool, std::string)> done,
                       scoped_refptr<os_crypt_async::Encryptor> encryptor);
  void PersistModelConfiguration(const std::string& provider,
                                 const std::string& base_url,
                                 const std::string& model);
  std::string EffectiveModelApiKey(const std::string& provider,
                                   const std::string& base_url,
                                   const std::string& candidate) const;
  void PushPrivacyEvent(PrivacyEvent event);
  void NotifyObservers();
  std::string ResolveDocumentContext(const std::string& local_frame_token,
                                     int render_process_id,
                                     std::string* site_key) const;

  base::WeakPtrFactory<AegisService> weak_ptr_factory_{this};
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_SERVICE_H_
