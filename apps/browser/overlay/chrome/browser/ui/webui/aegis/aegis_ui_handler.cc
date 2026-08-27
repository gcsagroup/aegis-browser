// Copyright 2026 GCSA
// Intended path: chrome/browser/ui/webui/aegis/aegis_ui_handler.cc

#include "chrome/browser/ui/webui/aegis/aegis_ui_handler.h"

#include <cstdint>
#include <string>

#include "base/functional/bind.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/aegis/aegis_service.h"
#if !BUILDFLAG(IS_ANDROID)
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#endif
#include "chrome/common/chrome_render_frame.mojom.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "ui/base/l10n/l10n_util.h"
#include "url/gurl.h"

namespace {

content::WebContents* FindHttpTab(content::WebContents* skip) {
#if BUILDFLAG(IS_ANDROID)
  // Android 没有桌面 TabStrip。摘要/截图先只用当前 WebUI 页；设置页本身不是 http。
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
        for (int i = 0; i < model->count(); ++i) {
          content::WebContents* contents = model->GetWebContentsAt(i);
          if (!contents || contents == skip) {
            continue;
          }
          const GURL& url = contents->GetLastCommittedURL();
          if (!url.SchemeIsHTTPOrHTTPS()) {
            continue;
          }
          found = contents;
          if (contents == model->GetActiveWebContents()) {
            return false;
          }
        }
        return true;
      },
      BrowserCollection::Order::kActivation);
  return found;
#endif
}

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

}  // namespace

AegisUIHandler::AegisUIHandler() = default;
AegisUIHandler::~AegisUIHandler() = default;

void AegisUIHandler::RegisterMessages() {
  web_ui()->RegisterMessageCallback(
      "getStatus",
      base::BindRepeating(&AegisUIHandler::HandleGetStatus,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "setModuleEnabled",
      base::BindRepeating(&AegisUIHandler::HandleSetModuleEnabled,
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
      "captureActiveTab",
      base::BindRepeating(&AegisUIHandler::HandleCaptureActiveTab,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "ollamaChat",
      base::BindRepeating(&AegisUIHandler::HandleOllamaChat,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "setOllamaSettings",
      base::BindRepeating(&AegisUIHandler::HandleSetOllamaSettings,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "probeOllama",
      base::BindRepeating(&AegisUIHandler::HandleProbeOllama,
                          base::Unretained(this)));
}

base::DictValue AegisUIHandler::BuildStatus() const {
  auto* service = aegis::AegisService::GetInstance();
  base::DictValue status;
  status.Set("enabled", service->IsEnabled());
  status.Set("trackerBlocking", service->IsTrackerBlockingEnabled());
  status.Set("phishInterstitial", service->IsPhishInterstitialEnabled());
  status.Set("fingerprintGuard", service->IsFingerprintGuardEnabled());
  status.Set("filterListAutoUpdate", service->IsFilterListAutoUpdateEnabled());
  status.Set("filterListUpdating", service->IsFilterListUpdating());
  status.Set("filterListHostCount", service->FilterListHostCount());
  status.Set("filterListLastUpdated",
             static_cast<double>(service->FilterListLastUpdated()));
  status.Set("filterListLastError", service->FilterListLastError());
  status.Set("linkSanitize", service->IsLinkSanitizeEnabled());
  status.Set("cookieJanitor", service->IsCookieJanitorEnabled());
  status.Set("cnameUncloak", service->IsCnameUncloakEnabled());
  status.Set("bounceTracking", service->IsBounceTrackingEnabled());
  status.Set("policyWorker", service->IsPolicyWorkerEnabled());
  status.Set("policyWorkerReady", service->IsPolicyWorkerReady());
  status.Set("policyWorkerError", service->PolicyWorkerError());
  status.Set("privacyAi", service->IsPrivacyAiEnabled());
#if BUILDFLAG(IS_ANDROID)
  status.Set("isAndroid", true);
#else
  status.Set("isAndroid", false);
#endif
  status.Set("aiControl", service->IsAiControlEnabled());
  status.Set("aiControlRunning", service->AiControlRunning());
  status.Set("aiControlPort", service->AiControlPort());
  status.Set("aiControlAddress", service->AiControlAddress());
  status.Set("aiControlLoopbackOnly", service->AiControlLoopbackOnly());
  status.Set("aiControlClients",
             static_cast<double>(service->CdpWebSocketClientCount()));
  status.Set("ollamaUrl", service->OllamaBaseUrl());
  status.Set("ollamaModel", service->OllamaModel());
  base::ListValue events;
  for (const auto& event : service->RecentPrivacyEvents()) {
    base::DictValue row;
    row.Set("kind", event.kind);
    row.Set("label", event.label);
    row.Set("time", static_cast<double>(event.unix_seconds));
    events.Append(std::move(row));
  }
  status.Set("recentEvents", std::move(events));
  return status;
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

  auto* service = aegis::AegisService::GetInstance();
  if (module == "trackerBlocking") {
    service->SetTrackerBlockingEnabled(enabled);
  } else if (module == "phishInterstitial") {
    service->SetPhishInterstitialEnabled(enabled);
  } else if (module == "fingerprintGuard") {
    service->SetFingerprintGuardEnabled(enabled);
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
  }

  ResolveJavascriptCallback(callback_id, BuildStatus());
}

void AegisUIHandler::HandleUpdateFilterLists(const base::ListValue& args) {
  AllowJavascript();
  if (args.empty() || !args[0].is_string()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  aegis::AegisService::GetInstance()->UpdateFilterLists(base::BindOnce(
      &AegisUIHandler::OnFilterListsUpdated, weak_factory_.GetWeakPtr(),
      callback_id));
}

void AegisUIHandler::OnFilterListsUpdated(std::string callback_id, bool ok) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  base::DictValue status = BuildStatus();
  status.Set("ok", ok);
  ResolveJavascriptCallback(base::Value(callback_id), status);
}

void AegisUIHandler::HandleSummarizeActiveTab(const base::ListValue& args) {
  AllowJavascript();
  if (args.empty() || !args[0].is_string()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  content::WebContents* skip = web_ui()->GetWebContents();
  content::WebContents* target = FindHttpTab(skip);
  if (!target) {
    aegis::SummarizeResult result;
    result.error = "no http(s) tab";
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
  const std::string url(target->GetLastCommittedURL().spec());
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
  raw->CollectAegisPageSignals(base::BindOnce(
      [](std::unique_ptr<
             mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>>
             keep_alive,
         base::WeakPtr<AegisUIHandler> self, std::string callback_id,
         std::string url, int32_t password_fields, int32_t forms,
         const std::string& title, const std::string& text_sample) {
        if (!self) {
          return;
        }
        self->OnPageSignals(std::move(callback_id), std::move(url),
                            password_fields, forms, title, text_sample);
      },
      std::move(client), weak_factory_.GetWeakPtr(), callback_id, url));
}

void AegisUIHandler::OnPageSignals(std::string callback_id,
                                   std::string url,
                                   int32_t password_fields,
                                   int32_t forms,
                                   const std::string& title,
                                   const std::string& text_sample) {
  aegis::PageSnapshot snapshot;
  snapshot.url = std::move(url);
  snapshot.title = title;
  snapshot.text_sample = text_sample;
  snapshot.password_fields = password_fields;
  snapshot.forms = forms;
  const std::string locale =
      l10n_util::GetApplicationLocale(std::string());
  aegis::AegisService::GetInstance()->SummarizePage(
      std::move(snapshot), locale,
      base::BindOnce(&AegisUIHandler::OnSummarized, weak_factory_.GetWeakPtr(),
                     std::move(callback_id)));
}

void AegisUIHandler::OnSummarized(std::string callback_id,
                                 aegis::SummarizeResult result) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  ResolveJavascriptCallback(base::Value(callback_id),
                            SummarizeToDict(result));
}

void AegisUIHandler::HandleCaptureActiveTab(const base::ListValue& args) {
  AllowJavascript();
  if (args.empty() || !args[0].is_string()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  content::WebContents* skip = web_ui()->GetWebContents();
  content::WebContents* target = FindHttpTab(skip);
  if (!target) {
    base::DictValue dict;
    dict.Set("error", "no http(s) tab");
    ResolveJavascriptCallback(base::Value(callback_id), dict);
    return;
  }
  content::RenderFrameHost* rfh = target->GetPrimaryMainFrame();
  if (!rfh) {
    base::DictValue dict;
    dict.Set("error", "no render frame");
    ResolveJavascriptCallback(base::Value(callback_id), dict);
    return;
  }
  const std::string url(target->GetLastCommittedURL().spec());
  auto client = std::make_unique<
      mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>>();
  rfh->GetRemoteAssociatedInterfaces()->GetInterface(client.get());
  if (!client->is_bound()) {
    base::DictValue dict;
    dict.Set("error", "renderer unavailable");
    ResolveJavascriptCallback(base::Value(callback_id), dict);
    return;
  }
  chrome::mojom::ChromeRenderFrame* raw = client->get();
  raw->CollectAegisPageSignals(base::BindOnce(
      [](std::unique_ptr<
             mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>>
             keep_alive,
         base::WeakPtr<AegisUIHandler> self, std::string callback_id,
         std::string url, int32_t password_fields, int32_t forms,
         const std::string& title, const std::string& text_sample) {
        if (!self) {
          return;
        }
        self->OnCaptured(std::move(callback_id), std::move(url),
                         password_fields, forms, title, text_sample);
      },
      std::move(client), weak_factory_.GetWeakPtr(), callback_id, url));
}

void AegisUIHandler::OnCaptured(std::string callback_id,
                               std::string url,
                               int32_t password_fields,
                               int32_t forms,
                               const std::string& title,
                               const std::string& text_sample) {
  if (!IsJavascriptAllowed()) {
    return;
  }
  base::DictValue dict;
  dict.Set("url", url);
  dict.Set("title", title);
  dict.Set("textSample", text_sample);
  dict.Set("passwordFields", password_fields);
  dict.Set("forms", forms);
  ResolveJavascriptCallback(base::Value(callback_id), dict);
}

void AegisUIHandler::HandleOllamaChat(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() < 3 || !args[0].is_string() || !args[1].is_string() ||
      !args[2].is_string()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  const std::string system = args[1].GetString();
  const std::string user = args[2].GetString();
  aegis::AegisService::GetInstance()->ChatWithOllama(
      system, user,
      base::BindOnce(&AegisUIHandler::OnSummarized, weak_factory_.GetWeakPtr(),
                     callback_id));
}

void AegisUIHandler::HandleSetOllamaSettings(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() < 3 || !args[0].is_string() || !args[1].is_string() ||
      !args[2].is_string()) {
    return;
  }
  const base::Value& callback_id = args[0];
  const bool ok = aegis::AegisService::GetInstance()->SetOllamaSettings(
      args[1].GetString(), args[2].GetString());
  base::DictValue status = BuildStatus();
  status.Set("ok", ok);
  if (!ok) {
    status.Set("error", "ollama url must be loopback");
  }
  ResolveJavascriptCallback(callback_id, status);
}

void AegisUIHandler::HandleProbeOllama(const base::ListValue& args) {
  AllowJavascript();
  if (args.size() < 2 || !args[0].is_string() || !args[1].is_string()) {
    return;
  }
  const std::string callback_id = args[0].GetString();
  aegis::AegisService::GetInstance()->ProbeOllama(
      args[1].GetString(),
      base::BindOnce(&AegisUIHandler::OnOllamaProbed,
                     weak_factory_.GetWeakPtr(), callback_id));
}

void AegisUIHandler::OnOllamaProbed(std::string callback_id,
                                   bool ok,
                                   std::string error,
                                   std::vector<std::string> models) {
  auto* service = aegis::AegisService::GetInstance();
  base::DictValue dict;
  dict.Set("ok", ok);
  dict.Set("error", error);
  dict.Set("ollamaUrl", service->OllamaBaseUrl());
  dict.Set("ollamaModel", service->OllamaModel());
  base::ListValue list;
  for (const std::string& name : models) {
    list.Append(name);
  }
  dict.Set("models", std::move(list));
  ResolveJavascriptCallback(base::Value(callback_id), dict);
}


