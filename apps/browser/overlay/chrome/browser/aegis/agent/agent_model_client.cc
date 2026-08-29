// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_model_client.h"

#include <algorithm>
#include <optional>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/escape.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/unguessable_token.h"
#include "net/base/net_errors.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

namespace aegis::agent {
namespace {

constexpr size_t kMaxResponseBytes = 2 * 1024 * 1024;
constexpr size_t kMaxApiKeyBytes = 4096;

constexpr net::NetworkTrafficAnnotationTag kLocalTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("aegis_agent_local_model", R"(
      semantics {
        sender: "Aegis Browser Agent"
        description:
          "Sends a user-approved, policy-reduced Agent planning or tool-call "
          "request to a numeric-loopback model endpoint."
        trigger:
          "The user starts or resumes an Agent task configured for a local "
          "model."
        data:
          "The user goal, fixed Agent contract, approved tool schemas, and "
          "policy-reduced page or browser observations. Secrets are excluded."
        destination: LOCAL
        internal {
          contacts { email: "aegis@gcsa.local" }
        }
        user_data { type: PAGE_CONTENT }
        last_reviewed: "2026-08-28"
      }
      policy {
        cookies_allowed: NO
        setting:
          "Users can disable Aegis Agent and choose its model destination."
        policy_exception_justification:
          "The profile setting is implemented and disabled by default."
      })");

constexpr net::NetworkTrafficAnnotationTag kWebsiteTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("aegis_agent_website_model", R"(
      semantics {
        sender: "Aegis Browser Agent"
        description:
          "Sends a user-approved, policy-reduced Agent planning or tool-call "
          "request to the configured HTTPS model provider."
        trigger:
          "The user starts or resumes an Agent task after reviewing the "
          "provider, host, model, data classes, and task scope."
        data:
          "An API credential in a header, the user goal, fixed Agent contract, "
          "approved tool schemas, and policy-reduced observations. Secrets "
          "are excluded."
        destination: WEBSITE
        internal {
          contacts { email: "aegis@gcsa.local" }
        }
        user_data { type: PAGE_CONTENT }
        last_reviewed: "2026-08-28"
      }
      policy {
        cookies_allowed: NO
        setting:
          "Users can disable Aegis Agent and remove or change the configured "
          "model provider."
        policy_exception_justification:
          "The profile setting is implemented and disabled by default."
      })");

bool HasControlCharacter(std::string_view value) {
  return std::ranges::any_of(
      value, [](unsigned char ch) { return ch < 0x20 || ch == 0x7f; });
}

bool IsValidApiKey(std::string_view api_key) {
  return api_key.size() <= kMaxApiKeyBytes && base::IsStringUTF8(api_key) &&
         !HasControlCharacter(api_key) &&
         base::TrimWhitespaceASCII(api_key, base::TRIM_ALL) == api_key;
}

AgentModelProvider ProtocolProvider(ModelProvider provider) {
  switch (provider) {
    case ModelProvider::kOpenAI:
      return AgentModelProvider::kOpenAICompatible;
    case ModelProvider::kAnthropic:
      return AgentModelProvider::kAnthropic;
    case ModelProvider::kGemini:
      return AgentModelProvider::kGemini;
  }
}

GURL AppendPath(const GURL& base_url, std::string_view relative_path) {
  std::string path(base_url.path());
  while (path.size() > 1 && path.ends_with('/')) {
    path.pop_back();
  }
  if (!path.ends_with('/')) {
    path.push_back('/');
  }
  while (relative_path.starts_with('/')) {
    relative_path.remove_prefix(1);
  }
  path.append(relative_path);
  GURL::Replacements replacements;
  replacements.SetPathStr(path);
  replacements.ClearQuery();
  replacements.ClearRef();
  return base_url.ReplaceComponents(replacements);
}

std::string GeminiModelId(std::string_view model) {
  if (model.starts_with("models/")) {
    model.remove_prefix(7);
  }
  return std::string(model);
}

int ResponseCode(const network::SimpleURLLoader* loader) {
  if (!loader || !loader->ResponseInfo() || !loader->ResponseInfo()->headers) {
    return 0;
  }
  return loader->ResponseInfo()->headers->response_code();
}

std::string RequestError(int response_code, int net_error) {
  if (net_error == net::ERR_TIMED_OUT) {
    return "agent model request timed out";
  }
  if (response_code >= 300 && response_code <= 599) {
    return base::StrCat({"agent model request failed (HTTP ",
                         base::NumberToString(response_code), ")"});
  }
  if (net_error != net::OK) {
    return base::StrCat({"agent model network request failed (",
                         net::ErrorToString(net_error), ")"});
  }
  return "agent model request failed";
}

}  // namespace

GURL BuildAgentModelEndpoint(ModelProvider provider,
                             const GURL& base_url,
                             std::string_view model,
                             bool stream) {
  switch (provider) {
    case ModelProvider::kOpenAI:
      return AppendPath(base_url, "responses");
    case ModelProvider::kAnthropic:
      return AppendPath(base_url, "messages");
    case ModelProvider::kGemini: {
      GURL endpoint = AppendPath(
          base_url,
          base::StrCat(
              {"models/", base::EscapeAllExceptUnreserved(GeminiModelId(model)),
               stream ? ":streamGenerateContent" : ":generateContent"}));
      if (!stream) {
        return endpoint;
      }
      GURL::Replacements replacements;
      replacements.SetQueryStr("alt=sse");
      return endpoint.ReplaceComponents(replacements);
    }
  }
}

AgentModelClient::AgentModelClient(
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory)
    : url_loader_factory_(std::move(url_loader_factory)) {}
AgentModelClient::~AgentModelClient() = default;

std::optional<AgentModelClient::RequestId> AgentModelClient::Start(
    AgentModelClientConfig config,
    AgentModelRequest request,
    Callback done) {
  if (loader_) {
    std::move(done).Run(false, "agent model request already in progress", {});
    return std::nullopt;
  }
  if (!url_loader_factory_) {
    std::move(done).Run(false, "agent model network unavailable", {});
    return std::nullopt;
  }
  const GURL base_url(config.base_url.empty()
                          ? std::string(DefaultModelBaseUrl(config.provider))
                          : config.base_url);
  if (!IsAllowedModelBaseUrl(config.provider, base_url) ||
      !IsValidApiKey(config.api_key) ||
      !IsValidModelName(config.provider, request.model) ||
      ProtocolProvider(config.provider) != request.provider) {
    std::move(done).Run(false, "invalid agent model configuration", {});
    return std::nullopt;
  }

  std::string error;
  std::optional<std::string> body = BuildAgentModelRequestBody(request, &error);
  if (!body) {
    std::move(done).Run(false, std::move(error), {});
    return std::nullopt;
  }
  const GURL endpoint = BuildAgentModelEndpoint(config.provider, base_url,
                                                request.model, request.stream);
  auto resource_request = std::make_unique<network::ResourceRequest>();
  resource_request->url = endpoint;
  resource_request->method = "POST";
  resource_request->redirect_mode = network::mojom::RedirectMode::kError;
  resource_request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  resource_request->load_flags =
      ModelProviderRequestLoadFlags(config.provider, base_url);
  resource_request->headers.SetHeader(
      net::HttpRequestHeaders::kAccept,
      request.stream ? "text/event-stream" : "application/json");
  switch (config.provider) {
    case ModelProvider::kOpenAI:
      if (!config.api_key.empty()) {
        resource_request->headers.SetHeader(
            net::HttpRequestHeaders::kAuthorization,
            base::StrCat({"Bearer ", config.api_key}));
      }
      break;
    case ModelProvider::kAnthropic:
      if (!config.api_key.empty()) {
        resource_request->headers.SetHeader("x-api-key", config.api_key);
      }
      resource_request->headers.SetHeader("anthropic-version", "2023-06-01");
      break;
    case ModelProvider::kGemini:
      if (!config.api_key.empty()) {
        resource_request->headers.SetHeader("x-goog-api-key", config.api_key);
      }
      break;
  }

  active_provider_ = request.provider;
  active_stream_ = request.stream;
  active_tools_ = std::move(request.tools);
  request_id_ = base::UnguessableToken::Create().ToString();
  loader_ = network::SimpleURLLoader::Create(
      std::move(resource_request),
      IsLocalModelEndpoint(config.provider, base_url)
          ? kLocalTrafficAnnotation
          : kWebsiteTrafficAnnotation);
  loader_->AttachStringForUpload(*body, "application/json");
  loader_->SetTimeoutDuration(
      ModelProviderChatTimeout(config.provider, base_url));
  loader_->DownloadToString(
      url_loader_factory_.get(),
      base::BindOnce(&AgentModelClient::OnComplete, weak_factory_.GetWeakPtr(),
                     std::move(done)),
      kMaxResponseBytes);
  return request_id_;
}

bool AgentModelClient::Cancel(RequestId request_id) {
  if (!request_id_ || *request_id_ != request_id) {
    return false;
  }
  weak_factory_.InvalidateWeakPtrs();
  loader_.reset();
  request_id_.reset();
  active_tools_.clear();
  return true;
}

void AgentModelClient::OnComplete(Callback done,
                                  std::optional<std::string> body) {
  const int response_code = ResponseCode(loader_.get());
  const int net_error = loader_ ? loader_->NetError() : net::ERR_FAILED;
  const bool request_ok = loader_ && net_error == net::OK && body &&
                          response_code >= 200 && response_code < 300;
  loader_.reset();
  request_id_.reset();
  if (!request_ok) {
    active_tools_.clear();
    std::move(done).Run(false, RequestError(response_code, net_error), {});
    return;
  }
  AgentModelParseResult result = ParseAgentModelResponse(
      active_provider_, *body, active_stream_, active_tools_);
  active_tools_.clear();
  if (!result.ok()) {
    std::string error = std::move(result.error);
    std::move(done).Run(false, std::move(error), {});
    return;
  }
  std::move(done).Run(true, std::string(), std::move(result));
}

}  // namespace aegis::agent
