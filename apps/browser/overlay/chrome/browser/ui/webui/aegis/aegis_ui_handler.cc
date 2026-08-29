// Copyright 2026 GCSA
// Intended path: chrome/browser/ui/webui/aegis/aegis_ui_handler.cc

#include "chrome/browser/ui/webui/aegis/aegis_ui_handler.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>

#include "base/base64.h"
#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/aegis/aegis_torrent_client.h"
#include "chrome/browser/aegis/agent/aegis_agent_service.h"
#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"
#include "chrome/browser/aegis/metalink_download_verifier.h"
#include "chrome/browser/aegis/metalink_parser.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/pref_names.h"
#if !BUILDFLAG(IS_ANDROID)
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/side_panel/side_panel_entry.h"
#include "chrome/browser/ui/side_panel/side_panel_ui.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#endif
#include "chrome/common/aegis/features.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "ui/base/l10n/l10n_util.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace {

constexpr base::TimeDelta kSummaryRequestTtl = base::Minutes(1);
constexpr base::TimeDelta kMetalinkRequestTtl = base::Minutes(1);
constexpr base::TimeDelta kTorrentRequestTtl = base::Minutes(1);
constexpr size_t kMaxTorrentBytes = 4 * 1024 * 1024;
constexpr size_t kMaxMagnetBytes = 16 * 1024;
constexpr size_t kMaxTorrentFiles = 2048;
constexpr size_t kMaxCaptureUrlBytes = 8192;
constexpr size_t kMaxCaptureTitleBytes = 4096;
constexpr size_t kMaxCaptureTextBytes = 64 * 1024;
constexpr int32_t kMaxCaptureFieldCount = 1'000'000;
constexpr char kProfileUnavailableError[] =
    "Aegis is unavailable for this profile";

std::optional<int> ReadInteger(const base::DictValue& dict, const char* key) {
  if (std::optional<int> value = dict.FindInt(key)) {
    return *value >= 0 && *value <= 1000000 ? value : std::nullopt;
  }
  const std::optional<double> value = dict.FindDouble(key);
  if (!value || !std::isfinite(*value) || std::trunc(*value) != *value ||
      *value < 0 || *value > 1000000) {
    return std::nullopt;
  }
  return static_cast<int>(*value);
}

bool ReadStringList(const base::DictValue& dict,
                    const char* key,
                    size_t max_items,
                    std::vector<std::string>* out) {
  const base::ListValue* values = dict.FindList(key);
  if (!values || values->size() > max_items) {
    return false;
  }
  for (const base::Value& value : *values) {
    if (!value.is_string()) {
      return false;
    }
    out->push_back(value.GetString());
  }
  return true;
}

std::optional<aegis::PreparedSummary> ParsePreparedSummary(
    const base::Value& value) {
  if (!value.is_dict()) {
    return std::nullopt;
  }
  const base::DictValue& root = value.GetDict();
  if (root.size() != 3 || root.contains("system") || root.contains("user") ||
      root.contains("prompt")) {
    return std::nullopt;
  }
  const std::optional<int> version = ReadInteger(root, "schemaVersion");
  const base::DictValue* snapshot = root.FindDict("sanitizedSnapshot");
  const base::DictValue* heuristic = root.FindDict("heuristic");
  if (!version || !snapshot || !heuristic || snapshot->size() != 5 ||
      heuristic->size() != 3) {
    return std::nullopt;
  }
  const std::string* url = snapshot->FindString("url");
  const std::string* title = snapshot->FindString("title");
  const std::string* text = snapshot->FindString("textSample");
  const std::optional<int> password_fields =
      ReadInteger(*snapshot, "passwordFields");
  const std::optional<int> forms = ReadInteger(*snapshot, "forms");
  const std::string* summary = heuristic->FindString("summary");
  if (!url || !title || !text || !password_fields || !forms || !summary) {
    return std::nullopt;
  }

  aegis::PreparedSummary prepared;
  prepared.schema_version = *version;
  prepared.snapshot.url = *url;
  prepared.snapshot.title = *title;
  prepared.snapshot.text_sample = *text;
  prepared.snapshot.password_fields = *password_fields;
  prepared.snapshot.forms = *forms;
  prepared.summary = *summary;
  if (!ReadStringList(*heuristic, "bullets", 3, &prepared.bullets) ||
      !ReadStringList(*heuristic, "risks", 8, &prepared.risks)) {
    return std::nullopt;
  }
  return prepared;
}

}  // namespace

namespace aegis {

content::WebContents* FindSummarySourceTabInModel(
    TabStripModel* model,
    content::WebContents* settings_tab) {
#if BUILDFLAG(IS_ANDROID)
  (void)model;
  (void)settings_tab;
  return nullptr;
#else
  if (!model || !settings_tab) {
    return nullptr;
  }
  const int settings_index = model->GetIndexOfWebContents(settings_tab);
  if (settings_index == TabStripModel::kNoTab) {
    return nullptr;
  }
  auto candidate_at = [model, settings_tab](int index) {
    content::WebContents* contents = model->GetWebContentsAt(index);
    if (!contents || contents == settings_tab) {
      return static_cast<content::WebContents*>(nullptr);
    }
    const GURL& url = contents->GetLastCommittedURL();
    return url.SchemeIsHTTPOrHTTPS() ? contents : nullptr;
  };
  for (int distance = 1; distance < model->count(); ++distance) {
    const int left = settings_index - distance;
    if (left >= 0) {
      if (content::WebContents* candidate = candidate_at(left)) {
        return candidate;
      }
    }
    const int right = settings_index + distance;
    if (right < model->count()) {
      if (content::WebContents* candidate = candidate_at(right)) {
        return candidate;
      }
    }
  }
  return nullptr;
#endif
}

}  // namespace aegis

namespace {

content::WebContents* FindHttpTab(content::WebContents* skip) {
#if BUILDFLAG(IS_ANDROID)
  // Android 没有桌面 TabStrip。摘要/截图先只用当前 WebUI 页；设置页本身不是
  // http。
  (void)skip;
  return nullptr;
#else
  content::WebContents* found = nullptr;
  GlobalBrowserCollection* collection = GlobalBrowserCollection::GetInstance();
  if (!collection) {
    return nullptr;
  }
  collection->ForEach(
      [&](BrowserWindowInterface* browser) {
        TabStripModel* model = browser->GetTabStripModel();
        if (!model) {
          return true;
        }
        if (model->GetIndexOfWebContents(skip) == TabStripModel::kNoTab) {
          return true;
        }
        found = aegis::FindSummarySourceTabInModel(model, skip);
        return false;
      },
      BrowserCollection::Order::kActivation);
  return found;
#endif
}

#if !BUILDFLAG(IS_ANDROID)
BrowserWindowInterface* FindOwningBrowser(content::WebContents* contents) {
  if (!contents) {
    return nullptr;
  }
  BrowserWindowInterface* found = nullptr;
  GlobalBrowserCollection* collection = GlobalBrowserCollection::GetInstance();
  if (!collection) {
    return nullptr;
  }
  collection->ForEach(
      [&](BrowserWindowInterface* browser) {
        TabStripModel* model = browser->GetTabStripModel();
        if (model &&
            model->GetIndexOfWebContents(contents) != TabStripModel::kNoTab) {
          found = browser;
          return false;
        }
        return true;
      },
      BrowserCollection::Order::kActivation);
  return found;
}
#endif

base::DictValue SummarizeToDict(const aegis::SummarizeResult& result) {
  base::DictValue dict;
  dict.Set("ok", result.ok);
  dict.Set("error", result.error);
  dict.Set("url", result.url);
  dict.Set("summary", result.summary);
  dict.Set("backend", result.backend);
  dict.Set("modelReady", result.model_ready);
  dict.Set("workerReady", result.worker_ready);
  dict.Set("charsIn", result.chars_in);
  dict.Set("charsSent", result.chars_sent);
  dict.Set("stayedOnDevice", result.stayed_on_device);
  dict.Set("destination", result.destination);
  base::ListValue bullets;
  for (const std::string& item : result.bullets) {
    bullets.Append(item);
  }
  dict.Set("bullets", std::move(bullets));
  base::ListValue risks;
  for (const std::string& item : result.risks) {
    risks.Append(item);
  }
  dict.Set("risks", std::move(risks));
  return dict;
}

base::DictValue MetalinkToPreview(const aegis::MetalinkParseResult& result) {
  base::DictValue dict;
  dict.Set("ok", result.ok);
  dict.Set("error", result.error);
  if (!result.ok) {
    return dict;
  }
  dict.Set("fileName", result.file_name);
  dict.Set("fileSize", static_cast<double>(result.file_size));
  dict.Set("hashAlgorithm", result.hash_algorithm);
  dict.Set("hashHex", result.hash_hex);
  base::ListValue mirrors;
  for (const aegis::MetalinkMirror& mirror : result.mirrors) {
    // Only expose origins to the settings renderer. Paths, queries, and
    // fragments can contain credentials or signed download tokens.
    mirrors.Append(url::Origin::Create(mirror.url).Serialize());
  }
  dict.Set("mirrorOrigins", std::move(mirrors));
  return dict;
}

base::DictValue TorrentToPreview(const aegis::mojom::TorrentPreview& preview) {
  base::DictValue dict;
  dict.Set("ok", preview.ok);
  dict.Set("error", preview.error);
  if (!preview.ok) {
    return dict;
  }
  dict.Set("name", preview.name);
  dict.Set("totalSize", static_cast<double>(preview.total_size));
  dict.Set("hasV1", preview.has_v1);
  dict.Set("hasV2", preview.has_v2);
  dict.Set("trackerCount", static_cast<int>(preview.tracker_count));
  base::ListValue files;
  for (const auto& source : preview.files) {
    base::DictValue file;
    file.Set("index", static_cast<int>(source->index));
    file.Set("path", source->path);
    file.Set("size", static_cast<double>(source->size));
    files.Append(std::move(file));
  }
  dict.Set("files", std::move(files));
  return dict;
}

base::DictValue TorrentStatusToDict(const aegis::mojom::TorrentStatus& status) {
  base::DictValue dict;
  dict.Set("found", status.found);
  dict.Set("error", status.error);
  dict.Set("name", status.name);
  dict.Set("state", status.state);
  dict.Set("totalBytes", static_cast<double>(status.total_bytes));
  dict.Set("completedBytes", static_cast<double>(status.completed_bytes));
  dict.Set("progressPpm", static_cast<int>(status.progress_ppm));
  dict.Set("downloadRate", static_cast<double>(status.download_rate));
  dict.Set("uploadRate", static_cast<double>(status.upload_rate));
  dict.Set("peers", static_cast<int>(status.peers));
  dict.Set("seeds", static_cast<int>(status.seeds));
  dict.Set("paused", status.paused);
  dict.Set("finished", status.finished);
  return dict;
}

}  // namespace

AegisUIHandler::AegisUIHandler() = default;
AegisUIHandler::~AegisUIHandler() {
  if (active_model_request_id_) {
    if (aegis::AegisService* service = ServiceForWebUI()) {
      service->CancelModelSummaryRequest(*active_model_request_id_);
    }
  }
}

void AegisUIHandler::RegisterMessages() {
  if (aegis::AegisService* service = ServiceForWebUI()) {
    service_observation_.Observe(service);
  }
  web_ui()->RegisterMessageCallback(
      "getStatus", base::BindRepeating(&AegisUIHandler::HandleGetStatus,
                                       base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "setModuleEnabled",
      base::BindRepeating(&AegisUIHandler::HandleSetModuleEnabled,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "openBrowserAgent",
      base::BindRepeating(&AegisUIHandler::HandleOpenBrowserAgent,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "updateFilterLists",
      base::BindRepeating(&AegisUIHandler::HandleUpdateFilterLists,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "summarizeActiveTab",
      base::BindRepeating(&AegisUIHandler::HandleSummarizeActiveTab,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "completePreparedSummary",
      base::BindRepeating(&AegisUIHandler::HandleCompletePreparedSummary,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "cancelPreparedSummary",
      base::BindRepeating(&AegisUIHandler::HandleCancelPreparedSummary,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "setModelSettings",
      base::BindRepeating(&AegisUIHandler::HandleSetModelSettings,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "listModels", base::BindRepeating(&AegisUIHandler::HandleListModels,
                                        base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "parseMetalink", base::BindRepeating(&AegisUIHandler::HandleParseMetalink,
                                           base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "startMetalinkDownload",
      base::BindRepeating(&AegisUIHandler::HandleStartMetalinkDownload,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "parseTorrent", base::BindRepeating(&AegisUIHandler::HandleParseTorrent,
                                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "parseMagnet", base::BindRepeating(&AegisUIHandler::HandleParseMagnet,
                                         base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "startTorrent", base::BindRepeating(&AegisUIHandler::HandleStartTorrent,
                                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "getTorrentStatus",
      base::BindRepeating(&AegisUIHandler::HandleGetTorrentStatus,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "controlTorrent",
      base::BindRepeating(&AegisUIHandler::HandleControlTorrent,
                          base::Unretained(this)));
}

// 这是当前进程单例的 fail-closed 过渡边界；在 AegisService 改为
// ProfileKeyedService 前，每个 WebUI 入口都必须经过此校验。
aegis::AegisService* AegisUIHandler::ServiceForWebUI() {
  if (!web_ui()) {
    return nullptr;
  }
  Profile* profile = Profile::FromWebUI(web_ui());
  aegis::AegisService* service = aegis::AegisService::GetInstance();
  return service->IsInitializedForProfile(profile) ? service : nullptr;
}

base::DictValue AegisUIHandler::BuildStatus() {
  aegis::AegisService* service = ServiceForWebUI();
  Profile* profile = Profile::FromWebUI(web_ui());
  const bool regular_profile = profile && !profile->IsOffTheRecord();
  base::DictValue status;
  status.Set("profileAvailable", regular_profile && service != nullptr);
  status.Set("enabled", service && service->IsEnabled());
  status.Set("trackerBlocking", service && service->IsTrackerBlockingEnabled());
  status.Set("phishInterstitial",
             service && service->IsPhishInterstitialEnabled());
  status.Set("fingerprintGuard",
             service && service->IsFingerprintGuardEnabled());
  status.Set("minerGuard", service && service->IsMinerGuardEnabled());
  status.Set("filterListAutoUpdate",
             service && service->IsFilterListAutoUpdateEnabled());
  status.Set("filterListUpdating", service && service->IsFilterListUpdating());
  status.Set("filterListHostCount",
             service ? service->FilterListHostCount() : 0);
  status.Set(
      "filterListLastUpdated",
      service ? static_cast<double>(service->FilterListLastUpdated()) : 0.0);
  status.Set("filterListLastError",
             service ? service->FilterListLastError() : std::string());
  status.Set("linkSanitize", service && service->IsLinkSanitizeEnabled());
  status.Set("cookieJanitor", service && service->IsCookieJanitorEnabled());
  status.Set("cnameUncloak", service && service->IsCnameUncloakEnabled());
  status.Set("bounceTracking", service && service->IsBounceTrackingEnabled());
  status.Set("policyWorker", service && service->IsPolicyWorkerEnabled());
  // Runtime readiness belongs to this chrome://aegis renderer and is filled
  // from an aegisEvaluate("ping") result in aegis.ts.
  status.Set("policyWorkerReady", false);
  status.Set("policyWorkerError", "");
  status.Set("privacyAi", service && service->IsPrivacyAiEnabled());
#if BUILDFLAG(IS_ANDROID)
  status.Set("isAndroid", true);
  status.Set("torrentSupported", false);
  status.Set("browserAgentAvailable", false);
  status.Set("browserAgentEnabled", false);
#else
  status.Set("isAndroid", false);
  const bool browser_agent_available =
      regular_profile &&
      base::FeatureList::IsEnabled(aegis::features::kAegisAgent);
  status.Set("browserAgentAvailable", browser_agent_available);
  status.Set("browserAgentEnabled",
             browser_agent_available &&
                 profile->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled));
#if BUILDFLAG(IS_MAC)
  status.Set("torrentSupported", service != nullptr);
#else
  status.Set("torrentSupported", false);
#endif
#endif
  status.Set("torrentDisclosureAcknowledged",
             profile && profile->GetPrefs()->GetBoolean(
                            aegis::prefs::kTorrentDisclosureAcknowledged));
  status.Set("torrentTaskId", profile ? profile->GetPrefs()->GetString(
                                            aegis::prefs::kLastTorrentTaskId)
                                      : std::string());
  status.Set("aiControl", service && service->IsAiControlEnabled());
  status.Set("aiControlRunning", service && service->AiControlRunning());
  status.Set("aiControlPort", service ? service->AiControlPort() : 0);
  status.Set("aiControlAddress",
             service ? service->AiControlAddress() : std::string());
  status.Set("aiControlLoopbackOnly",
             service && service->AiControlLoopbackOnly());
  status.Set(
      "aiControlClients",
      service ? static_cast<double>(service->CdpWebSocketClientCount()) : 0.0);
  const std::string model_provider =
      service ? service->ConfiguredModelProvider() : std::string();
  const std::string model_base_url =
      service ? service->ConfiguredModelBaseUrl() : std::string();
  status.Set("modelProvider", model_provider);
  status.Set("modelBaseUrl", model_base_url);
  status.Set("modelName",
             service ? service->ConfiguredModelName() : std::string());
  status.Set(
      "modelApiKeyConfigured",
      service && service->HasModelApiKey(model_provider, model_base_url));
  status.Set("modelCredentialState",
             service
                 ? service->ModelCredentialState(model_provider, model_base_url)
                 : std::string());
  base::ListValue events;
  if (service) {
    for (const auto& event : service->RecentPrivacyEvents()) {
      base::DictValue row;
      row.Set("kind", event.kind);
      row.Set("reason", event.reason);
      row.Set("site", event.site_key);
      row.Set("domain", event.display_domain);
      row.Set("count", event.count);
      row.Set("firstTime", static_cast<double>(event.first_unix_seconds));
      row.Set("lastTime", static_cast<double>(event.last_unix_seconds));
      base::ListValue details;
      for (const std::string& detail : event.details) {
        if (!detail.empty()) {
          details.Append(detail);
        }
      }
      row.Set("details", std::move(details));
      events.Append(std::move(row));
    }
  }
  status.Set("recentEvents", std::move(events));
  if (!service) {
    status.Set("error", kProfileUnavailableError);
  }
  return status;
}

void AegisUIHandler::OnAegisStateChanged() {
  if (IsJavascriptAllowed()) {
    FireWebUIListener("aegis-status-changed", BuildStatus());
  }
}

void AegisUIHandler::HandleGetStatus(const base::ListValue& args) {
  AllowJavascript();
  const base::Value& callback_id = args[0];
  ResolveJavascriptCallback(callback_id, BuildStatus());
}

void AegisUIHandler::HandleSetModuleEnabled(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() < 3 || !args[1].is_string() || !args[2].is_bool()) {
    return;
  }
  const base::Value& callback_id = args[0];
  const std::string& module = args[1].GetString();
  const bool enabled = args[2].GetBool();

  aegis::AegisService* service = ServiceForWebUI();
  if (!service) {
    base::DictValue status = BuildStatus();
    status.Set("ok", false);
    ResolveJavascriptCallback(callback_id, status);
    return;
  }
  if (module == "trackerBlocking") {
    service->SetTrackerBlockingEnabled(enabled);
  } else if (module == "phishInterstitial") {
    service->SetPhishInterstitialEnabled(enabled);
  } else if (module == "fingerprintGuard") {
    service->SetFingerprintGuardEnabled(enabled);
  } else if (module == "minerGuard") {
    service->SetMinerGuardEnabled(enabled);
  } else if (module == "filterListAutoUpdate") {
    service->SetFilterListAutoUpdateEnabled(enabled);
  } else if (module == "linkSanitize") {
    service->SetLinkSanitizeEnabled(enabled);
  } else if (module == "cookieJanitor") {
    service->SetCookieJanitorEnabled(enabled);
  } else if (module == "cnameUncloak") {
    service->SetCnameUncloakEnabled(enabled);
  } else if (module == "bounceTracking") {
    service->SetBounceTrackingEnabled(enabled);
  } else if (module == "policyWorker") {
    service->SetPolicyWorkerEnabled(enabled);
  } else if (module == "privacyAi") {
    service->SetPrivacyAiEnabled(enabled);
  } else if (module == "aiControl") {
    service->SetAiControlEnabled(enabled);
  } else if (module == "browserAgent") {
#if BUILDFLAG(IS_ANDROID)
    base::DictValue status = BuildStatus();
    status.Set("ok", false);
    status.Set("error", "Browser Agent is not available on Android in v1");
    ResolveJavascriptCallback(callback_id, status);
    return;
#else
    Profile* profile = Profile::FromWebUI(web_ui());
    if (!profile || !profile->IsRegularProfile() ||
        !base::FeatureList::IsEnabled(aegis::features::kAegisAgent)) {
      base::DictValue status = BuildStatus();
      status.Set("ok", false);
      status.Set("error", "Browser Agent feature is unavailable");
      ResolveJavascriptCallback(callback_id, status);
      return;
    }
    aegis::agent::AegisAgentService* agent_service =
        aegis::agent::AegisAgentServiceFactory::GetForProfileIfExists(profile);
    profile->GetPrefs()->SetBoolean(aegis::prefs::kAgentEnabled, enabled);
    if (!enabled && agent_service) {
      agent_service->CancelAllForDisable();
    } else if (enabled && agent_service) {
      agent_service->ResumeMonitorsAfterEnable();
    } else if (enabled) {
      // Creating the service restores and schedules persisted monitors.
      aegis::agent::AegisAgentServiceFactory::GetForProfile(profile);
    }
#endif
  }

  ResolveJavascriptCallback(callback_id, BuildStatus());
}

void AegisUIHandler::HandleOpenBrowserAgent(const base::ListValue& args) {
  AllowJavascript();
  if (args.empty()) {
    return;
  }
  const base::Value& callback_id = args[0];
  base::DictValue status = BuildStatus();
#if BUILDFLAG(IS_ANDROID)
  status.Set("ok", false);
  status.Set("error", "Browser Agent is not available on Android in v1");
#else
  Profile* profile = Profile::FromWebUI(web_ui());
  BrowserWindowInterface* browser =
      FindOwningBrowser(web_ui()->GetWebContents());
  SidePanelUI* side_panel =
      browser ? browser->GetFeatures().side_panel_ui() : nullptr;
  if (!profile || !profile->IsRegularProfile() || !browser || !side_panel ||
      !base::FeatureList::IsEnabled(aegis::features::kAegisAgent) ||
      !profile->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled)) {
    status.Set("ok", false);
    status.Set("error", "Enable Browser Agent before opening it");
  } else {
    side_panel->Show(SidePanelEntry::Id::kAegisAgent,
                     SidePanelOpenTrigger::kAegisAgent);
    status.Set("ok", true);
  }
#endif
  ResolveJavascriptCallback(callback_id, status);
}

void AegisUIHandler::HandleUpdateFilterLists(const base::ListValue& args) {
  AllowJavascript();
  if (args.empty() || !args[0].is_string()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  aegis::AegisService* service = ServiceForWebUI();
  if (!service) {
    OnFilterListsUpdated(callback_id, false);
    return;
  }
  service->UpdateFilterLists(
      base::BindOnce(&AegisUIHandler::OnFilterListsUpdated,
                     weak_factory_.GetWeakPtr(), callback_id));
}

void AegisUIHandler::OnFilterListsUpdated(std::string callback_id, bool ok) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  if (!ServiceForWebUI()) {
    ok = false;
  }
  base::DictValue status = BuildStatus();
  status.Set("ok", ok);
  ResolveJavascriptCallback(base::Value(callback_id), status);
}

void AegisUIHandler::HandleSummarizeActiveTab(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 1 || !args[0].is_string()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  aegis::AegisService* service = ServiceForWebUI();
  if (!service) {
    aegis::SummarizeResult result;
    result.error = kProfileUnavailableError;
    OnSummarized(callback_id, std::move(result));
    return;
  }
  content::WebContents* skip = web_ui()->GetWebContents();
  content::WebContents* target = FindHttpTab(skip);
  if (!service->IsPrivacyAiEnabled() || !service->IsPolicyWorkerEnabled()) {
    aegis::SummarizeResult result;
    result.error = "privacy summary or policy worker disabled";
    OnSummarized(callback_id, std::move(result));
    return;
  }
  if (!target) {
    aegis::SummarizeResult result;
    result.error = "no http(s) tab";
    OnSummarized(callback_id, std::move(result));
    return;
  }
  Profile* target_profile =
      Profile::FromBrowserContext(target->GetBrowserContext());
  if (!service->IsInitializedForProfile(target_profile)) {
    aegis::SummarizeResult result;
    result.error = "summary source profile is unavailable";
    OnSummarized(callback_id, std::move(result));
    return;
  }
  content::RenderFrameHost* rfh = target->GetPrimaryMainFrame();
  if (!rfh) {
    aegis::SummarizeResult result;
    result.error = "no render frame";
    OnSummarized(callback_id, std::move(result));
    return;
  }
  const content::NavigationEntry* entry =
      target->GetController().GetLastCommittedEntry();
  if (!entry) {
    aegis::SummarizeResult result;
    result.error = "no committed document";
    OnSummarized(callback_id, std::move(result));
    return;
  }
  const std::string url(target->GetLastCommittedURL().spec());
  const content::GlobalRenderFrameHostId frame_id = rfh->GetGlobalId();
  const int64_t document_sequence = entry->GetMainFrameDocumentSequenceNumber();
  auto client = std::make_unique<
      mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>>();
  rfh->GetRemoteAssociatedInterfaces()->GetInterface(client.get());
  if (!client->is_bound()) {
    aegis::SummarizeResult result;
    result.error = "renderer unavailable";
    OnSummarized(callback_id, std::move(result));
    return;
  }
  chrome::mojom::ChromeRenderFrame* raw = client->get();
  raw->CollectAegisPageSignals(
      /*include_text=*/true,
      base::BindOnce(
          [](std::unique_ptr<mojo::AssociatedRemote<
                 chrome::mojom::ChromeRenderFrame>> keep_alive,
             base::WeakPtr<AegisUIHandler> self, std::string callback_id,
             content::GlobalRenderFrameHostId frame_id,
             int64_t document_sequence, std::string url,
             int32_t password_fields, int32_t forms,
             const std::vector<std::string>& form_actions,
             const std::string& title, const std::string& text_sample) {
            if (!self) {
              return;
            }
            self->OnPageSignals(std::move(callback_id), frame_id,
                                document_sequence, std::move(url),
                                password_fields, forms, title, text_sample);
          },
          std::move(client), weak_factory_.GetWeakPtr(), callback_id, frame_id,
          document_sequence, url));
}

void AegisUIHandler::OnPageSignals(std::string callback_id,
                                   content::GlobalRenderFrameHostId frame_id,
                                   int64_t document_sequence,
                                   std::string url,
                                   int32_t password_fields,
                                   int32_t forms,
                                   const std::string& title,
                                   const std::string& text_sample) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  content::RenderFrameHost* rfh = content::RenderFrameHost::FromID(frame_id);
  content::WebContents* target =
      rfh ? content::WebContents::FromRenderFrameHost(rfh) : nullptr;
  aegis::AegisService* service = ServiceForWebUI();
  Profile* target_profile =
      target ? Profile::FromBrowserContext(target->GetBrowserContext())
             : nullptr;
  if (!service || !service->IsInitializedForProfile(target_profile)) {
    aegis::SummarizeResult result;
    result.error = "summary source profile changed during capture";
    OnSummarized(std::move(callback_id), std::move(result));
    return;
  }
  const content::NavigationEntry* entry =
      target ? target->GetController().GetLastCommittedEntry() : nullptr;
  const GURL parsed_url(url);
  if (!target || target->GetPrimaryMainFrame() != rfh || !entry ||
      entry->GetMainFrameDocumentSequenceNumber() != document_sequence ||
      target->GetLastCommittedURL().spec() != url ||
      !parsed_url.SchemeIsHTTPOrHTTPS() || url.size() > kMaxCaptureUrlBytes ||
      !base::IsStringUTF8(title) || !base::IsStringUTF8(text_sample) ||
      text_sample.size() > kMaxCaptureTextBytes || password_fields < 0 ||
      password_fields > kMaxCaptureFieldCount || forms < 0 ||
      forms > kMaxCaptureFieldCount) {
    aegis::SummarizeResult result;
    result.error = "page navigated during summary capture";
    OnSummarized(std::move(callback_id), std::move(result));
    return;
  }

  aegis::PageSnapshot snapshot;
  snapshot.url = std::move(url);
  snapshot.title = base::TruncateUTF8ToByteSize(title, kMaxCaptureTitleBytes);
  snapshot.text_sample = text_sample;
  snapshot.password_fields = password_fields;
  snapshot.forms = forms;

  PendingSummary pending;
  pending.request_id = base::UnguessableToken::Create().ToString();
  pending.original = snapshot;
  pending.frame_id = frame_id;
  pending.document_sequence = document_sequence;
  pending.model_provider = service->ConfiguredModelProvider();
  pending.model_base_url = service->ConfiguredModelBaseUrl();
  pending.model_name = service->ConfiguredModelName();
  pending.created = base::TimeTicks::Now();
  pending_summary_ = pending;

  base::DictValue response;
  response.Set("ok", true);
  response.Set("requestId", pending.request_id);
  response.Set("modelProvider", pending.model_provider);
  response.Set("modelBaseUrl", pending.model_base_url);
  response.Set("modelName", pending.model_name);
  base::DictValue snapshot_value;
  snapshot_value.Set("url", snapshot.url);
  snapshot_value.Set("title", snapshot.title);
  snapshot_value.Set("textSample", snapshot.text_sample);
  snapshot_value.Set("passwordFields", snapshot.password_fields);
  snapshot_value.Set("forms", snapshot.forms);
  response.Set("snapshot", std::move(snapshot_value));
  ResolveJavascriptCallback(base::Value(callback_id), response);
}

void AegisUIHandler::HandleCompletePreparedSummary(
    const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 3 || !args[0].is_string() || !args[1].is_string()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  const std::string request_id = args[1].GetString();
  auto reject = [this, &callback_id](std::string error) {
    aegis::SummarizeResult result;
    result.error = std::move(error);
    OnSummarized(callback_id, std::move(result));
  };

  aegis::AegisService* service = ServiceForWebUI();
  if (!service) {
    pending_summary_.reset();
    reject(kProfileUnavailableError);
    return;
  }

  if (!pending_summary_ || pending_summary_->request_id != request_id) {
    reject("invalid or replayed summary request");
    return;
  }
  PendingSummary pending = std::move(*pending_summary_);
  pending_summary_.reset();
  if (base::TimeTicks::Now() - pending.created > kSummaryRequestTtl) {
    reject("summary request expired");
    return;
  }

  content::RenderFrameHost* rfh =
      content::RenderFrameHost::FromID(pending.frame_id);
  content::WebContents* target =
      rfh ? content::WebContents::FromRenderFrameHost(rfh) : nullptr;
  Profile* target_profile =
      target ? Profile::FromBrowserContext(target->GetBrowserContext())
             : nullptr;
  const content::NavigationEntry* entry =
      target ? target->GetController().GetLastCommittedEntry() : nullptr;
  if (!service->IsInitializedForProfile(target_profile)) {
    reject("summary source profile changed before completion");
    return;
  }
  if (!target || target->GetPrimaryMainFrame() != rfh || !entry ||
      entry->GetMainFrameDocumentSequenceNumber() !=
          pending.document_sequence ||
      target->GetLastCommittedURL().spec() != pending.original.url) {
    reject("page navigated before summary completion");
    return;
  }

  std::optional<aegis::PreparedSummary> prepared =
      ParsePreparedSummary(args[2]);
  if (!prepared) {
    reject("invalid prepared summary payload");
    return;
  }
  const std::string locale = l10n_util::GetApplicationLocale(std::string());
  if (active_model_request_id_) {
    aegis::SummarizeResult result;
    result.error = "model request already in progress";
    ResolveJavascriptCallback(base::Value(callback_id),
                              SummarizeToDict(result));
    return;
  }
  active_model_request_id_ = service->SummarizePreparedPage(
      std::move(pending.original), std::move(*prepared), locale,
      pending.model_provider, pending.model_base_url, pending.model_name,
      base::BindOnce(&AegisUIHandler::OnSummarized, weak_factory_.GetWeakPtr(),
                     std::move(callback_id)));
}

void AegisUIHandler::HandleCancelPreparedSummary(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 2 || !args[0].is_string() || !args[1].is_string()) {
    return;
  }
  const base::Value& callback_id = args[0];
  const std::string& request_id = args[1].GetString();
  const bool cancelled =
      pending_summary_ && pending_summary_->request_id == request_id;
  if (cancelled) {
    pending_summary_.reset();
  }
  base::DictValue result;
  result.Set("ok", cancelled);
  ResolveJavascriptCallback(callback_id, result);
}

void AegisUIHandler::OnSummarized(std::string callback_id,
                                  aegis::SummarizeResult result) {
  active_model_request_id_.reset();
  if (!IsJavascriptAllowed()) {
    return;
  }
  if (!ServiceForWebUI()) {
    result = aegis::SummarizeResult();
    result.error = kProfileUnavailableError;
  }
  ResolveJavascriptCallback(base::Value(callback_id), SummarizeToDict(result));
}

void AegisUIHandler::HandleSetModelSettings(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 6 || !args[0].is_string() || !args[1].is_string() ||
      !args[2].is_string() || !args[3].is_string() || !args[4].is_string() ||
      !args[5].is_bool()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  aegis::AegisService* service = ServiceForWebUI();
  if (!service) {
    OnModelSettingsSaved(callback_id, false, kProfileUnavailableError);
    return;
  }
  service->SetModelSettings(
      args[1].GetString(), args[2].GetString(), args[3].GetString(),
      args[4].GetString(), args[5].GetBool(),
      base::BindOnce(&AegisUIHandler::OnModelSettingsSaved,
                     weak_factory_.GetWeakPtr(), callback_id));
}

void AegisUIHandler::OnModelSettingsSaved(std::string callback_id,
                                          bool ok,
                                          std::string error) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  if (!ServiceForWebUI()) {
    ok = false;
    error = kProfileUnavailableError;
  }
  base::DictValue status = BuildStatus();
  status.Set("ok", ok);
  if (!ok) {
    status.Set("error", std::move(error));
  }
  ResolveJavascriptCallback(base::Value(callback_id), status);
}

void AegisUIHandler::HandleListModels(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 4 || !args[0].is_string() || !args[1].is_string() ||
      !args[2].is_string() || !args[3].is_string()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  const std::string provider = args[1].GetString();
  const std::string requested_base_url = args[2].GetString();
  aegis::AegisService* service = ServiceForWebUI();
  if (!service) {
    OnModelsListed(callback_id, provider, std::string(), false,
                   kProfileUnavailableError, {});
    return;
  }
  const std::optional<std::string> normalized_base_url =
      service->ResolveModelBaseUrl(provider, requested_base_url);
  const std::string reported_base_url =
      normalized_base_url.value_or(std::string(
          base::TrimWhitespaceASCII(requested_base_url, base::TRIM_ALL)));
  service->ListModels(provider, requested_base_url, args[3].GetString(),
                      base::BindOnce(&AegisUIHandler::OnModelsListed,
                                     weak_factory_.GetWeakPtr(), callback_id,
                                     provider, reported_base_url));
}

void AegisUIHandler::OnModelsListed(std::string callback_id,
                                    std::string provider,
                                    std::string base_url,
                                    bool ok,
                                    std::string error,
                                    std::vector<std::string> models) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  base::DictValue dict;
  dict.Set("ok", ok);
  dict.Set("error", std::move(error));
  dict.Set("modelProvider", provider);
  dict.Set("modelBaseUrl", base_url);
  aegis::AegisService* service = ServiceForWebUI();
  if (!service) {
    dict.Set("ok", false);
    dict.Set("error", kProfileUnavailableError);
    dict.Set("modelApiKeyConfigured", false);
    dict.Set("modelCredentialState", "");
    models.clear();
  } else {
    dict.Set("modelApiKeyConfigured",
             service->HasModelApiKey(provider, base_url));
    dict.Set("modelCredentialState",
             service->ModelCredentialState(provider, base_url));
  }
  base::ListValue list;
  for (const std::string& name : models) {
    list.Append(name);
  }
  dict.Set("models", std::move(list));
  ResolveJavascriptCallback(base::Value(callback_id), dict);
}

void AegisUIHandler::HandleParseMetalink(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 2 || !args[0].is_string() || !args[1].is_string()) {
    return;
  }
  pending_metalink_.reset();
  aegis::ParseMetalink(
      args[1].GetString(),
      base::BindOnce(&AegisUIHandler::OnMetalinkParsed,
                     weak_factory_.GetWeakPtr(), args[0].GetString()));
}

void AegisUIHandler::OnMetalinkParsed(std::string callback_id,
                                      aegis::MetalinkParseResult result) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  base::DictValue response = MetalinkToPreview(result);
  if (result.ok) {
    PendingMetalink pending;
    pending.request_id = base::UnguessableToken::Create().ToString();
    pending.result = std::move(result);
    pending.created = base::TimeTicks::Now();
    response.Set("requestId", pending.request_id);
    pending_metalink_ = std::move(pending);
  }
  ResolveJavascriptCallback(base::Value(callback_id), response);
}

void AegisUIHandler::HandleStartMetalinkDownload(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 2 || !args[0].is_string() || !args[1].is_string()) {
    return;
  }
  const base::Value& callback_id = args[0];
  const std::string& request_id = args[1].GetString();
  base::DictValue response;
  if (!pending_metalink_ || pending_metalink_->request_id != request_id) {
    response.Set("ok", false);
    response.Set("error", "invalid or replayed Metalink request");
    ResolveJavascriptCallback(callback_id, response);
    return;
  }
  PendingMetalink pending = std::move(*pending_metalink_);
  pending_metalink_.reset();
  if (base::TimeTicks::Now() - pending.created > kMetalinkRequestTtl) {
    response.Set("ok", false);
    response.Set("error", "Metalink request expired");
    ResolveJavascriptCallback(callback_id, response);
    return;
  }
  aegis::StartVerifiedMetalinkDownload(Profile::FromWebUI(web_ui()),
                                       std::move(pending.result));
  response.Set("ok", true);
  response.Set("error", "");
  ResolveJavascriptCallback(callback_id, response);
}

void AegisUIHandler::HandleParseTorrent(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 2 || !args[0].is_string() || !args[1].is_string()) {
    return;
  }
  pending_torrent_.reset();
  const std::string& encoded = args[1].GetString();
  base::DictValue failure;
  if (encoded.size() > ((kMaxTorrentBytes + 2) / 3) * 4 + 4) {
    failure.Set("ok", false);
    failure.Set("error", "torrent metadata exceeds the 4 MiB limit");
    ResolveJavascriptCallback(args[0], failure);
    return;
  }
  std::optional<std::vector<uint8_t>> decoded = base::Base64Decode(encoded);
  if (!decoded || decoded->empty() || decoded->size() > kMaxTorrentBytes) {
    failure.Set("ok", false);
    failure.Set("error", "torrent metadata is not valid base64");
    ResolveJavascriptCallback(args[0], failure);
    return;
  }
  std::vector<uint8_t> pending_bytes = *decoded;
  aegis::AegisTorrentClient::GetInstance()->ValidateTorrent(
      std::move(*decoded),
      base::BindOnce(&AegisUIHandler::OnTorrentValidated,
                     weak_factory_.GetWeakPtr(), args[0].GetString(),
                     std::move(pending_bytes), std::string()));
}

void AegisUIHandler::HandleParseMagnet(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 2 || !args[0].is_string() || !args[1].is_string()) {
    return;
  }
  pending_torrent_.reset();
  const std::string& magnet_uri = args[1].GetString();
  base::DictValue failure;
  if (magnet_uri.empty() || magnet_uri.size() > kMaxMagnetBytes) {
    failure.Set("ok", false);
    failure.Set("error", "magnet link is invalid or too large");
    ResolveJavascriptCallback(args[0], failure);
    return;
  }
  aegis::AegisTorrentClient::GetInstance()->ValidateMagnet(
      magnet_uri,
      base::BindOnce(&AegisUIHandler::OnTorrentValidated,
                     weak_factory_.GetWeakPtr(), args[0].GetString(),
                     std::vector<uint8_t>(), magnet_uri));
}

void AegisUIHandler::OnTorrentValidated(
    std::string callback_id,
    std::vector<uint8_t> torrent_data,
    std::string magnet_uri,
    aegis::mojom::TorrentPreviewPtr preview) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  if (!preview) {
    preview = aegis::mojom::TorrentPreview::New();
    preview->error = "torrent service disconnected";
  }
  base::DictValue response = TorrentToPreview(*preview);
  if (preview->ok) {
    PendingTorrent pending;
    pending.request_id = base::UnguessableToken::Create().ToString();
    pending.torrent_data = std::move(torrent_data);
    pending.magnet_uri = std::move(magnet_uri);
    pending.created = base::TimeTicks::Now();
    response.Set("requestId", pending.request_id);
    pending_torrent_ = std::move(pending);
  }
  ResolveJavascriptCallback(base::Value(callback_id), response);
}

void AegisUIHandler::HandleStartTorrent(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 5 || !args[0].is_string() || !args[1].is_string() ||
      !args[2].is_list() || !args[3].is_dict() || !args[4].is_bool()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  const std::string& request_id = args[1].GetString();
  auto fail = [this, &callback_id](std::string error) {
    base::DictValue response;
    response.Set("ok", false);
    response.Set("error", std::move(error));
    ResolveJavascriptCallback(base::Value(callback_id), response);
  };
  if (!pending_torrent_ || pending_torrent_->request_id != request_id) {
    fail("invalid or replayed torrent request");
    return;
  }
  PendingTorrent pending = std::move(*pending_torrent_);
  pending_torrent_.reset();
  if (base::TimeTicks::Now() - pending.created > kTorrentRequestTtl) {
    fail("torrent request expired");
    return;
  }

  std::vector<uint32_t> selected_files;
  if (args[2].GetList().size() > kMaxTorrentFiles) {
    fail("too many selected torrent files");
    return;
  }
  for (const base::Value& value : args[2].GetList()) {
    if (!value.is_int() || value.GetInt() < 0) {
      fail("selected torrent file index is invalid");
      return;
    }
    selected_files.push_back(static_cast<uint32_t>(value.GetInt()));
  }
  std::ranges::sort(selected_files);
  selected_files.erase(
      std::unique(selected_files.begin(), selected_files.end()),
      selected_files.end());

  const base::DictValue& source_options = args[3].GetDict();
  const std::optional<bool> enable_dht = source_options.FindBool("enableDht");
  const std::optional<bool> enable_pex = source_options.FindBool("enablePex");
  const std::optional<int> download_limit =
      ReadInteger(source_options, "downloadLimitKib");
  const std::optional<int> upload_limit =
      ReadInteger(source_options, "uploadLimitKib");
  if (!enable_dht || !enable_pex || !download_limit || !upload_limit) {
    fail("torrent options are invalid");
    return;
  }

  Profile* profile = Profile::FromWebUI(web_ui());
  PrefService* prefs = profile->GetPrefs();
  if (!prefs->GetBoolean(aegis::prefs::kTorrentDisclosureAcknowledged)) {
    if (!args[4].GetBool()) {
      fail("torrent privacy disclosure must be acknowledged");
      return;
    }
    prefs->SetBoolean(aegis::prefs::kTorrentDisclosureAcknowledged, true);
  }
  DownloadPrefs* download_prefs = DownloadPrefs::FromBrowserContext(profile);
  const base::FilePath destination = download_prefs->DownloadPath();
  if (destination.empty()) {
    fail("download directory is unavailable");
    return;
  }

  auto options = aegis::mojom::TorrentOptions::New();
  options->enable_dht = *enable_dht;
  options->enable_pex = *enable_pex;
  options->download_limit_kib = static_cast<uint32_t>(*download_limit);
  options->upload_limit_kib = static_cast<uint32_t>(*upload_limit);
  aegis::AegisTorrentClient::GetInstance()->StartTorrent(
      std::move(pending.torrent_data), std::move(pending.magnet_uri),
      destination, std::move(selected_files), std::move(options),
      base::BindOnce(&AegisUIHandler::OnTorrentStarted,
                     weak_factory_.GetWeakPtr(), std::move(callback_id)));
}

void AegisUIHandler::OnTorrentStarted(std::string callback_id,
                                      bool ok,
                                      const std::string& error,
                                      const std::string& task_id) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  if (ok) {
    Profile::FromWebUI(web_ui())->GetPrefs()->SetString(
        aegis::prefs::kLastTorrentTaskId, task_id);
  }
  base::DictValue response;
  response.Set("ok", ok);
  response.Set("error", error);
  response.Set("taskId", task_id);
  ResolveJavascriptCallback(base::Value(callback_id), response);
}

void AegisUIHandler::HandleGetTorrentStatus(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 2 || !args[0].is_string() || !args[1].is_string()) {
    return;
  }
  const std::string& task_id = args[1].GetString();
  const std::string& expected =
      Profile::FromWebUI(web_ui())->GetPrefs()->GetString(
          aegis::prefs::kLastTorrentTaskId);
  if (task_id.empty() || task_id != expected) {
    base::DictValue response;
    response.Set("found", false);
    response.Set("error", "torrent task is not available in this profile");
    ResolveJavascriptCallback(args[0], response);
    return;
  }
  aegis::AegisTorrentClient::GetInstance()->GetStatus(
      task_id, base::BindOnce(&AegisUIHandler::OnTorrentStatus,
                              weak_factory_.GetWeakPtr(), args[0].GetString()));
}

void AegisUIHandler::OnTorrentStatus(std::string callback_id,
                                     aegis::mojom::TorrentStatusPtr status) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  if (!status) {
    status = aegis::mojom::TorrentStatus::New();
    status->error = "torrent service disconnected";
  }
  ResolveJavascriptCallback(base::Value(callback_id),
                            TorrentStatusToDict(*status));
}

void AegisUIHandler::HandleControlTorrent(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() != 3 || !args[0].is_string() || !args[1].is_string() ||
      !args[2].is_string()) {
    return;
  }
  const std::string task_id = args[1].GetString();
  const std::string& expected =
      Profile::FromWebUI(web_ui())->GetPrefs()->GetString(
          aegis::prefs::kLastTorrentTaskId);
  if (task_id.empty() || task_id != expected) {
    OnTorrentControlled(args[0].GetString(), args[2].GetString(), task_id,
                        false);
    return;
  }
  const std::string& action = args[2].GetString();
  auto callback = base::BindOnce(&AegisUIHandler::OnTorrentControlled,
                                 weak_factory_.GetWeakPtr(),
                                 args[0].GetString(), action, task_id);
  if (action == "pause") {
    aegis::AegisTorrentClient::GetInstance()->Pause(task_id,
                                                    std::move(callback));
  } else if (action == "resume") {
    aegis::AegisTorrentClient::GetInstance()->Resume(task_id,
                                                     std::move(callback));
  } else if (action == "cancel") {
    aegis::AegisTorrentClient::GetInstance()->Cancel(task_id, false,
                                                     std::move(callback));
  } else {
    OnTorrentControlled(args[0].GetString(), action, task_id, false);
  }
}

void AegisUIHandler::OnTorrentControlled(std::string callback_id,
                                         std::string action,
                                         std::string task_id,
                                         bool ok) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  if (action == "cancel") {
    PrefService* prefs = Profile::FromWebUI(web_ui())->GetPrefs();
    if (prefs->GetString(aegis::prefs::kLastTorrentTaskId) == task_id) {
      prefs->ClearPref(aegis::prefs::kLastTorrentTaskId);
    }
    // A disconnected service owns no surviving task. Treat cancel as
    // idempotent so a cleanup-time disconnect cannot leave a stale UI card.
    ok = true;
  }
  base::DictValue response;
  response.Set("ok", ok);
  ResolveJavascriptCallback(base::Value(callback_id), response);
}
