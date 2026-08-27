// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_service.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_SERVICE_H_
#define CHROME_BROWSER_AEGIS_AEGIS_SERVICE_H_

#include <cstdint>
#include <deque>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/containers/flat_set.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/singleton.h"
#include "chrome/common/aegis/phish_score.h"
#include "chrome/common/renderer_configuration.mojom.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/receiver_set.h"

class GURL;
class PrefService;
class Profile;

namespace aegis {

class FilterListUpdater;
class CookieJanitor;
class OllamaSidecar;
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

struct PrivacyEvent {
  std::string kind;
  std::string label;
  int64_t unix_seconds = 0;
};

class AegisService : public chrome::mojom::AegisHost {
 public:
  static AegisService* GetInstance();

  AegisService(const AegisService&) = delete;
  AegisService& operator=(const AegisService&) = delete;

  // Called from browser startup once Profile is ready.
  void InitializeForProfile(Profile* profile);

  bool IsEnabled() const;
  bool IsTrackerBlockingEnabled() const;
  bool IsPhishInterstitialEnabled() const;
  bool IsFingerprintGuardEnabled() const;
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
  void SetFilterListAutoUpdateEnabled(bool enabled);
  void SetLinkSanitizeEnabled(bool enabled);
  void SetCookieJanitorEnabled(bool enabled);
  void SetCnameUncloakEnabled(bool enabled);
  void SetBounceTrackingEnabled(bool enabled);
  void SetPolicyWorkerEnabled(bool enabled);
  void SetPrivacyAiEnabled(bool enabled);
  void SetAiControlEnabled(bool enabled);
  void UpdateFilterLists(base::OnceCallback<void(bool)> done);

  // Privacy AI: heuristic summary via the JS policy worker, then optional
  // Ollama sidecar on loopback. Fails closed to the heuristic if the model
  // is missing.
  void SummarizePage(PageSnapshot snapshot,
                     const std::string& locale,
                     base::OnceCallback<void(SummarizeResult)> done);
  // Loopback Ollama only. |system|/|user| must already be PII-redacted.
  void ChatWithOllama(const std::string& system,
                      const std::string& user,
                      base::OnceCallback<void(SummarizeResult)> done);
  std::string OllamaBaseUrl() const;
  std::string OllamaModel() const;
  // |url| 必须是 loopback；空字符串回退到默认值。
  bool SetOllamaSettings(const std::string& url, const std::string& model);
  int AiControlPort() const;
  std::string AiControlAddress() const;
  bool AiControlLoopbackOnly() const;
  bool AiControlRunning() const;
  size_t CdpWebSocketClientCount() const;
  void SetCdpWebSocketClientCount(size_t count);

  // Renderer → browser：把拦截记到会话清单。
  void BindAegisHost(
      mojo::PendingReceiver<chrome::mojom::AegisHost> receiver);

  // chrome.mojom.AegisHost:
  void ReportBlockedRequest(const std::string& url,
                            const std::string& reason,
                            const std::string& cname_alias) override;
  void ReportStrippedReferrer(const std::string& host,
                              const std::vector<std::string>& keys) override;
  void ReportStrippedParams(const std::string& host,
                            const std::vector<std::string>& keys) override;
  void ProbeOllama(
      const std::string& url,
      base::OnceCallback<void(bool ok,
                              std::string error,
                              std::vector<std::string> models)> done);
  bool IsPolicyWorkerReady() const;
  std::string PolicyWorkerError() const;

  // Host-rule match against builtin seed + compiled EasyList. Callers should
  // skip main-document navigations (RequestDestination::kDocument).
  bool ShouldBlockUrl(const GURL& url) const;

  // Main-frame phishing interstitial decision (seed rules + URL heuristics +
  // session allow). Returns the assessment when the page should be blocked.
  std::optional<PhishAssessment> EvaluatePhish(const GURL& url) const;
  bool ShouldShowPhishInterstitial(const GURL& url) const;
  void AllowPhishHostForSession(const std::string& host);
  bool IsPhishHostAllowedForSession(const std::string& host) const;

  void RecordStrippedParams(const std::string& host,
                            const std::vector<std::string>& keys);
  void RecordStrippedReferrer(const std::string& host,
                              const std::vector<std::string>& keys);
  void RecordDeletedCookie(const std::string& name,
                           const std::string& domain,
                           const std::string& category);
  void RecordBounceClear(const std::string& site);
  void RecordBlockedRequest(const GURL& url,
                            const std::string& reason,
                            const std::string& cname_alias);
  void RecordPhishBlock(const std::string& host, const std::string& reason);
  std::vector<PrivacyEvent> RecentPrivacyEvents() const;

  PrefService* prefs() const { return prefs_; }

 private:
  friend struct base::DefaultSingletonTraits<AegisService>;
  AegisService();
  ~AegisService() override;

  bool initialized_ = false;
  raw_ptr<PrefService> prefs_ = nullptr;
  raw_ptr<Profile> profile_ = nullptr;
  base::flat_set<std::string> session_allowed_phish_hosts_;
  std::deque<PrivacyEvent> privacy_events_;
  std::unique_ptr<FilterListUpdater> filter_list_updater_;
  std::unique_ptr<CookieJanitor> cookie_janitor_;
  std::unique_ptr<OllamaSidecar> ollama_;
  std::unique_ptr<AiControl> ai_control_;
  mojo::ReceiverSet<chrome::mojom::AegisHost> host_receivers_;
  size_t cdp_ws_clients_ = 0;

  void InstallReporterCallbacks();
  void OnHeuristicSummary(PageSnapshot snapshot,
                          std::string locale,
                          base::OnceCallback<void(SummarizeResult)> done,
                          std::string json);
  void OnPromptReady(SummarizeResult heuristic,
                     std::string locale,
                     base::OnceCallback<void(SummarizeResult)> done,
                     std::string json);
  void OnOllamaReady(SummarizeResult heuristic,
                     std::string system,
                     std::string user,
                     base::OnceCallback<void(SummarizeResult)> done,
                     bool ok,
                     std::string body);
  void OnOllamaChat(SummarizeResult heuristic,
                    base::OnceCallback<void(SummarizeResult)> done,
                    bool ok,
                    std::string body);
  void OnOllamaProbed(
      base::OnceCallback<void(bool, std::string, std::vector<std::string>)>
          done,
      bool ok,
      std::string body);
  void PushPrivacyEvent(PrivacyEvent event);
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_SERVICE_H_
