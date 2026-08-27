// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/ollama_sidecar.cc

#include "chrome/browser/aegis/ollama_sidecar.h"

#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/browser_process.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr size_t kMaxBodyBytes = 2 * 1024 * 1024;

constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("aegis_ollama_sidecar", R"(
      semantics {
        sender: "GCSA-aegis"
        description:
          "Optional local Privacy AI call to an Ollama sidecar on loopback. "
          "Page text is PII-redacted before send. Never leaves the device."
        trigger:
          "User clicks Summarize on chrome://aegis when Privacy AI is on."
        data: "Redacted page excerpt and a local-only chat prompt."
        destination: LOCAL
        internal {
          contacts {
            email: "aegis@gcsa.local"
          }
        }
        user_data {
          type: PAGE_CONTENT
        }
        last_reviewed: "2026-08-13"
      }
      policy {
        cookies_allowed: NO
        setting: "Users can disable Privacy AI on chrome://aegis."
        policy_exception_justification: "Not yet implemented."
      })");

std::string JoinUrl(const std::string& base, const char* path) {
  std::string trimmed = base;
  while (!trimmed.empty() && trimmed.back() == '/') {
    trimmed.pop_back();
  }
  return trimmed + path;
}

bool IsLoopback(const GURL& url) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  const std::string host(url.host());
  return host == "127.0.0.1" || host == "localhost" || host == "::1" ||
         host == "[::1]";
}

}  // namespace

OllamaSidecar::OllamaSidecar() = default;
OllamaSidecar::~OllamaSidecar() = default;

void OllamaSidecar::Probe(const std::string& base_url, ChatCallback done) {
  if (!g_browser_process || !g_browser_process->shared_url_loader_factory()) {
    std::move(done).Run(false, "no url loader");
    return;
  }
  const GURL url(JoinUrl(base_url, "/api/tags"));
  if (!IsLoopback(url)) {
    std::move(done).Run(false, "ollama url must be loopback");
    return;
  }
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = url;
  request->method = "GET";
  request->load_flags = net::LOAD_DISABLE_CACHE | net::LOAD_BYPASS_CACHE;
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  loader_ = network::SimpleURLLoader::Create(std::move(request),
                                             kTrafficAnnotation);
  loader_->SetTimeoutDuration(base::Seconds(3));
  loader_->DownloadToString(
      g_browser_process->shared_url_loader_factory().get(),
      base::BindOnce(&OllamaSidecar::OnProbe, weak_factory_.GetWeakPtr(),
                     std::move(done)),
      kMaxBodyBytes);
}

void OllamaSidecar::Chat(const std::string& base_url,
                         const std::string& model,
                         const std::string& system,
                         const std::string& user,
                         ChatCallback done) {
  if (!g_browser_process || !g_browser_process->shared_url_loader_factory()) {
    std::move(done).Run(false, "no url loader");
    return;
  }
  const GURL url(JoinUrl(base_url, "/api/chat"));
  if (!IsLoopback(url)) {
    std::move(done).Run(false, "ollama url must be loopback");
    return;
  }

  base::DictValue payload;
  payload.Set("model", model);
  payload.Set("stream", false);
  base::ListValue messages;
  base::DictValue sys;
  sys.Set("role", "system");
  sys.Set("content", system);
  base::DictValue usr;
  usr.Set("role", "user");
  usr.Set("content", user);
  messages.Append(std::move(sys));
  messages.Append(std::move(usr));
  payload.Set("messages", std::move(messages));
  std::string json;
  if (!base::JSONWriter::Write(payload, &json)) {
    std::move(done).Run(false, "failed to encode chat request");
    return;
  }

  auto request = std::make_unique<network::ResourceRequest>();
  request->url = url;
  request->method = "POST";
  request->load_flags = net::LOAD_DISABLE_CACHE | net::LOAD_BYPASS_CACHE;
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  loader_ = network::SimpleURLLoader::Create(std::move(request),
                                             kTrafficAnnotation);
  loader_->AttachStringForUpload(json, "application/json");
  loader_->SetTimeoutDuration(base::Seconds(45));
  loader_->DownloadToString(
      g_browser_process->shared_url_loader_factory().get(),
      base::BindOnce(&OllamaSidecar::OnChat, weak_factory_.GetWeakPtr(),
                     std::move(done)),
      kMaxBodyBytes);
}

void OllamaSidecar::OnProbe(ChatCallback done,
                            std::optional<std::string> body) {
  const bool ok = body.has_value() && loader_ && loader_->NetError() == net::OK;
  loader_.reset();
  std::move(done).Run(ok, ok ? *body : "ollama not reachable");
}

void OllamaSidecar::OnChat(ChatCallback done, std::optional<std::string> body) {
  const bool ok = body.has_value() && loader_ && loader_->NetError() == net::OK;
  loader_.reset();
  std::move(done).Run(ok, ok ? *body : "ollama chat failed");
}

}  // namespace aegis
