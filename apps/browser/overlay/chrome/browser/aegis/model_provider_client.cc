// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/model_provider_client.cc

#include "chrome/browser/aegis/model_provider_client.h"

#include <algorithm>
#include <optional>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/escape.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "chrome/browser/browser_process.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr size_t kMaxResponseBytes = 2 * 1024 * 1024;
constexpr size_t kMaxModels = 200;
constexpr size_t kMaxApiKeyBytes = 4096;
constexpr size_t kMaxSystemPromptBytes = 2048;
constexpr size_t kMaxUserPromptBytes = 16 * 1024;
constexpr size_t kMaxChatContentBytes = 64 * 1024;

constexpr net::NetworkTrafficAnnotationTag kLocalTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("aegis_local_model_provider", R"(
      semantics {
        sender: "GCSA-aegis"
        description:
          "User-requested model discovery or privacy summary sent to a "
          "numeric-loopback model API endpoint."
        trigger:
          "The user loads local models or confirms a page summary in "
          "the native Aegis site popup."
        data: "Model configuration or a PII-redacted page summary prompt."
        destination: LOCAL
        internal {
          contacts {
            email: "aegis@gcsa.local"
          }
        }
        user_data {
          type: PAGE_CONTENT
        }
        last_reviewed: "2026-08-27"
      }
      policy {
        cookies_allowed: NO
        setting: "Users can disable Privacy AI on chrome://aegis."
        policy_exception_justification: "Not yet implemented."
      })");

constexpr net::NetworkTrafficAnnotationTag kWebsiteTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("aegis_website_model_provider", R"(
      semantics {
        sender: "GCSA-aegis"
        description:
          "User-requested model discovery or privacy summary sent to the "
          "configured HTTPS model provider."
        trigger:
          "The user loads remote models or confirms a remote page summary in "
          "the native Aegis site popup."
        data:
          "An API credential in a request header, model configuration, or a "
          "PII-redacted page summary prompt."
        destination: WEBSITE
        internal {
          contacts {
            email: "aegis@gcsa.local"
          }
        }
        user_data {
          type: PAGE_CONTENT
        }
        last_reviewed: "2026-08-27"
      }
      policy {
        cookies_allowed: NO
        setting:
          "Users choose and configure the remote model provider and can "
          "disable Privacy AI on chrome://aegis."
        policy_exception_justification: "Not yet implemented."
      })");

bool HasControlCharacter(std::string_view value) {
  return std::ranges::any_of(
      value, [](unsigned char ch) { return ch < 0x20 || ch == 0x7f; });
}

bool HasUnsafeTextControlCharacter(std::string_view value) {
  return std::ranges::any_of(value, [](unsigned char ch) {
    return (ch < 0x20 && ch != '\t' && ch != '\n' && ch != '\r') || ch == 0x7f;
  });
}

bool IsValidApiKey(ModelProvider provider, std::string_view api_key) {
  if (api_key.empty()) {
    return !ModelProviderRequiresApiKey(provider);
  }
  return api_key.size() <= kMaxApiKeyBytes && base::IsStringUTF8(api_key) &&
         !HasControlCharacter(api_key) &&
         base::TrimWhitespaceASCII(api_key, base::TRIM_ALL) == api_key;
}

bool IsValidPrompt(std::string_view value, size_t max_bytes) {
  return value.size() <= max_bytes && base::IsStringUTF8(value) &&
         !HasUnsafeTextControlCharacter(value);
}

bool IsValidChatContent(std::string_view value) {
  return !value.empty() && value.size() <= kMaxChatContentBytes &&
         base::IsStringUTF8(value) && !HasUnsafeTextControlCharacter(value);
}

GURL BuildEndpoint(const GURL& base_url, std::string_view relative_path) {
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

std::optional<GURL> ResolveBaseUrl(ModelProvider provider,
                                   const std::string& base_url,
                                   std::string* error) {
  const GURL parsed(
      base_url.empty() ? std::string(DefaultModelBaseUrl(provider)) : base_url);
  if (!IsAllowedModelBaseUrl(provider, parsed)) {
    *error = "invalid model provider base URL";
    return std::nullopt;
  }
  return parsed;
}

std::unique_ptr<network::ResourceRequest> BuildResourceRequest(
    ModelProvider provider,
    const GURL& base_url,
    const GURL& endpoint,
    const std::string& method,
    const std::string& api_key) {
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = endpoint;
  request->method = method;
  request->redirect_mode = network::mojom::RedirectMode::kError;
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->load_flags = ModelProviderRequestLoadFlags(provider, base_url);
  request->headers.SetHeader(net::HttpRequestHeaders::kAccept,
                             "application/json");

  switch (provider) {
    case ModelProvider::kOpenAI:
      if (!api_key.empty()) {
        request->headers.SetHeader(net::HttpRequestHeaders::kAuthorization,
                                   base::StrCat({"Bearer ", api_key}));
      }
      break;
    case ModelProvider::kAnthropic:
      if (!api_key.empty()) {
        request->headers.SetHeader("x-api-key", api_key);
      }
      request->headers.SetHeader("anthropic-version", "2023-06-01");
      break;
    case ModelProvider::kGemini:
      if (!api_key.empty()) {
        request->headers.SetHeader("x-goog-api-key", api_key);
      }
      break;
  }
  return request;
}

GURL ListModelsEndpoint(ModelProvider provider, const GURL& base_url) {
  switch (provider) {
    case ModelProvider::kOpenAI:
    case ModelProvider::kAnthropic:
      return BuildEndpoint(base_url, "models");
    case ModelProvider::kGemini:
      return BuildEndpoint(base_url, "models");
  }
}

std::string GeminiModelId(std::string_view model) {
  constexpr std::string_view kPrefix = "models/";
  if (model.starts_with(kPrefix)) {
    model.remove_prefix(kPrefix.size());
  }
  return std::string(model);
}

GURL ChatEndpoint(ModelProvider provider,
                  const GURL& base_url,
                  std::string_view model) {
  switch (provider) {
    case ModelProvider::kOpenAI:
      return BuildEndpoint(base_url, "chat/completions");
    case ModelProvider::kAnthropic:
      return BuildEndpoint(base_url, "messages");
    case ModelProvider::kGemini:
      return BuildEndpoint(
          base_url,
          base::StrCat({"models/",
                        base::EscapeAllExceptUnreserved(GeminiModelId(model)),
                        ":generateContent"}));
  }
}

base::DictValue TextMessage(std::string_view role, std::string_view content) {
  base::DictValue message;
  message.Set("role", role);
  message.Set("content", content);
  return message;
}

base::DictValue GeminiTextPart(std::string_view text) {
  base::DictValue part;
  part.Set("text", text);
  return part;
}

std::optional<std::string> BuildChatBody(ModelProvider provider,
                                         const std::string& model,
                                         const std::string& system,
                                         const std::string& user) {
  base::DictValue payload;
  payload.Set("model", model);

  switch (provider) {
    case ModelProvider::kOpenAI: {
      base::ListValue messages;
      messages.Append(TextMessage("system", system));
      messages.Append(TextMessage("user", user));
      payload.Set("messages", std::move(messages));
      payload.Set("stream", false);
      break;
    }
    case ModelProvider::kAnthropic: {
      payload.Set("system", system);
      payload.Set("max_tokens", 1024);
      base::ListValue messages;
      messages.Append(TextMessage("user", user));
      payload.Set("messages", std::move(messages));
      break;
    }
    case ModelProvider::kGemini: {
      payload.Remove("model");
      base::DictValue system_instruction;
      base::ListValue system_parts;
      system_parts.Append(GeminiTextPart(system));
      system_instruction.Set("parts", std::move(system_parts));
      payload.Set("systemInstruction", std::move(system_instruction));

      base::DictValue content;
      content.Set("role", "user");
      base::ListValue user_parts;
      user_parts.Append(GeminiTextPart(user));
      content.Set("parts", std::move(user_parts));
      base::ListValue contents;
      contents.Append(std::move(content));
      payload.Set("contents", std::move(contents));

      base::DictValue generation_config;
      generation_config.Set("responseMimeType", "application/json");
      payload.Set("generationConfig", std::move(generation_config));
      break;
    }
  }

  std::string json;
  if (!base::JSONWriter::Write(payload, &json)) {
    return std::nullopt;
  }
  return json;
}

void AppendModel(ModelProvider provider,
                 std::string_view raw_name,
                 std::vector<std::string>* models) {
  if (models->size() >= kMaxModels) {
    return;
  }
  std::string name(raw_name);
  if (provider == ModelProvider::kGemini) {
    name = GeminiModelId(name);
  }
  if (!IsValidModelName(provider, name) ||
      std::ranges::find(*models, name) != models->end()) {
    return;
  }
  models->push_back(std::move(name));
}

bool GeminiSupportsGenerateContent(const base::DictValue& model) {
  const base::ListValue* methods = model.FindList("supportedGenerationMethods");
  if (!methods) {
    return false;
  }
  return std::ranges::any_of(*methods, [](const base::Value& method) {
    return method.is_string() && method.GetString() == "generateContent";
  });
}

std::optional<std::vector<std::string>> ParseModelList(
    ModelProvider provider,
    const std::string& body) {
  if (body.size() > kMaxResponseBytes) {
    return std::nullopt;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(body, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    return std::nullopt;
  }
  const base::DictValue& root = parsed->GetDict();
  const char* list_key = provider == ModelProvider::kGemini ? "models" : "data";
  const base::ListValue* list = root.FindList(list_key);
  if (!list) {
    return std::nullopt;
  }

  std::vector<std::string> models;
  for (const base::Value& value : *list) {
    if (models.size() >= kMaxModels) {
      break;
    }
    const base::DictValue* dict = value.GetIfDict();
    if (!dict) {
      continue;
    }
    if (provider == ModelProvider::kGemini &&
        !GeminiSupportsGenerateContent(*dict)) {
      continue;
    }
    const char* name_key = provider == ModelProvider::kOpenAI ||
                                   provider == ModelProvider::kAnthropic
                               ? "id"
                               : "name";
    const std::string* name = dict->FindString(name_key);
    if (name) {
      AppendModel(provider, *name, &models);
    }
  }
  return models;
}

std::optional<std::string> JoinTextParts(const base::ListValue* parts,
                                         const char* text_key,
                                         const char* required_type) {
  if (!parts) {
    return std::nullopt;
  }
  std::string content;
  for (const base::Value& value : *parts) {
    const base::DictValue* dict = value.GetIfDict();
    if (!dict) {
      continue;
    }
    if (required_type) {
      const std::string* type = dict->FindString("type");
      if (!type || *type != required_type) {
        continue;
      }
    }
    const std::string* text = dict->FindString(text_key);
    if (!text || text->empty()) {
      continue;
    }
    if (!content.empty()) {
      content.push_back('\n');
    }
    if (content.size() + text->size() > kMaxChatContentBytes) {
      return std::nullopt;
    }
    content.append(*text);
  }
  return IsValidChatContent(content)
             ? std::optional<std::string>(std::move(content))
             : std::nullopt;
}

std::optional<std::string> ParseChatContent(ModelProvider provider,
                                            const std::string& body) {
  if (body.size() > kMaxResponseBytes) {
    return std::nullopt;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(body, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict()) {
    return std::nullopt;
  }
  const base::DictValue& root = parsed->GetDict();
  const std::string* direct = nullptr;

  switch (provider) {
    case ModelProvider::kOpenAI: {
      const base::ListValue* choices = root.FindList("choices");
      const base::DictValue* choice =
          choices && !choices->empty() ? (*choices)[0].GetIfDict() : nullptr;
      const base::DictValue* message =
          choice ? choice->FindDict("message") : nullptr;
      direct = message ? message->FindString("content") : nullptr;
      break;
    }
    case ModelProvider::kAnthropic:
      return JoinTextParts(root.FindList("content"), "text", "text");
    case ModelProvider::kGemini: {
      const base::ListValue* candidates = root.FindList("candidates");
      const base::DictValue* candidate = candidates && !candidates->empty()
                                             ? (*candidates)[0].GetIfDict()
                                             : nullptr;
      const base::DictValue* content =
          candidate ? candidate->FindDict("content") : nullptr;
      return JoinTextParts(content ? content->FindList("parts") : nullptr,
                           "text", nullptr);
    }
  }

  if (!direct || !IsValidChatContent(*direct)) {
    return std::nullopt;
  }
  return *direct;
}

int ResponseCode(const network::SimpleURLLoader* loader) {
  if (!loader || !loader->ResponseInfo() || !loader->ResponseInfo()->headers) {
    return 0;
  }
  return loader->ResponseInfo()->headers->response_code();
}

bool RequestSucceeded(const network::SimpleURLLoader* loader,
                      const std::optional<std::string>& body) {
  const int response_code = ResponseCode(loader);
  return loader && loader->NetError() == net::OK && body.has_value() &&
         response_code >= 200 && response_code < 300;
}

std::string RequestFailedError(int response_code, int net_error) {
  if (net_error == net::ERR_TIMED_OUT) {
    return "model request timed out";
  }
  if (response_code >= 300 && response_code <= 599) {
    return base::StrCat({"model request failed (HTTP ",
                         base::NumberToString(response_code), ")"});
  }
  if (net_error != net::OK) {
    return base::StrCat(
        {"model network request failed (", net::ErrorToString(net_error), ")"});
  }
  return "model request failed";
}

}  // namespace

ModelProviderClient::ModelProviderClient() = default;
ModelProviderClient::~ModelProviderClient() = default;

void ModelProviderClient::ListModels(ModelProvider provider,
                                     const std::string& base_url,
                                     const std::string& api_key,
                                     ListModelsCallback done) {
  if (request_in_flight_) {
    std::move(done).Run(false, "model request already in progress", {});
    return;
  }
  if (!g_browser_process || !g_browser_process->shared_url_loader_factory()) {
    std::move(done).Run(false, "model network unavailable", {});
    return;
  }
  std::string error;
  const std::optional<GURL> parsed_base =
      ResolveBaseUrl(provider, base_url, &error);
  if (!parsed_base) {
    std::move(done).Run(false, std::move(error), {});
    return;
  }
  if (!IsValidApiKey(provider, api_key)) {
    std::move(done).Run(false, "invalid API key", {});
    return;
  }

  const GURL endpoint = ListModelsEndpoint(provider, *parsed_base);
  auto request =
      BuildResourceRequest(provider, *parsed_base, endpoint, "GET", api_key);
  request_in_flight_ = true;
  loader_ = network::SimpleURLLoader::Create(
      std::move(request), IsLocalModelEndpoint(provider, *parsed_base)
                              ? kLocalTrafficAnnotation
                              : kWebsiteTrafficAnnotation);
  loader_->SetTimeoutDuration(base::Seconds(10));
  loader_->DownloadToString(
      g_browser_process->shared_url_loader_factory().get(),
      base::BindOnce(&ModelProviderClient::OnListModels,
                     weak_factory_.GetWeakPtr(), provider, std::move(done)),
      kMaxResponseBytes);
}

std::optional<ModelProviderClient::ChatRequestId> ModelProviderClient::Chat(
    ModelProvider provider,
    const std::string& base_url,
    const std::string& api_key,
    const std::string& model,
    const std::string& system,
    const std::string& user,
    ChatCallback done) {
  if (request_in_flight_) {
    std::move(done).Run(false, "model request already in progress", {});
    return std::nullopt;
  }
  if (!g_browser_process || !g_browser_process->shared_url_loader_factory()) {
    std::move(done).Run(false, "model network unavailable", {});
    return std::nullopt;
  }
  std::string error;
  const std::optional<GURL> parsed_base =
      ResolveBaseUrl(provider, base_url, &error);
  if (!parsed_base) {
    std::move(done).Run(false, std::move(error), {});
    return std::nullopt;
  }
  if (!IsValidApiKey(provider, api_key)) {
    std::move(done).Run(false, "invalid API key", {});
    return std::nullopt;
  }
  if (!IsValidModelName(provider, model)) {
    std::move(done).Run(false, "invalid model name", {});
    return std::nullopt;
  }
  if (!IsValidPrompt(system, kMaxSystemPromptBytes) || system.empty() ||
      !IsValidPrompt(user, kMaxUserPromptBytes) || user.empty()) {
    std::move(done).Run(false, "invalid model prompt", {});
    return std::nullopt;
  }
  const std::optional<std::string> body =
      BuildChatBody(provider, model, system, user);
  if (!body) {
    std::move(done).Run(false, "failed to encode model request", {});
    return std::nullopt;
  }

  const GURL endpoint = ChatEndpoint(provider, *parsed_base, model);
  auto request =
      BuildResourceRequest(provider, *parsed_base, endpoint, "POST", api_key);
  request_in_flight_ = true;
  active_chat_request_id_ = base::UnguessableToken::Create().ToString();
  loader_ = network::SimpleURLLoader::Create(
      std::move(request), IsLocalModelEndpoint(provider, *parsed_base)
                              ? kLocalTrafficAnnotation
                              : kWebsiteTrafficAnnotation);
  loader_->AttachStringForUpload(*body, "application/json");
  loader_->SetTimeoutDuration(ModelProviderChatTimeout(provider, *parsed_base));
  loader_->DownloadToString(
      g_browser_process->shared_url_loader_factory().get(),
      base::BindOnce(&ModelProviderClient::OnChat, weak_factory_.GetWeakPtr(),
                     provider, std::move(done)),
      kMaxResponseBytes);
  return active_chat_request_id_;
}

bool ModelProviderClient::CancelChat(ChatRequestId request_id) {
  if (!active_chat_request_id_ || *active_chat_request_id_ != request_id) {
    return false;
  }
  weak_factory_.InvalidateWeakPtrs();
  loader_.reset();
  request_in_flight_ = false;
  active_chat_request_id_.reset();
  return true;
}

void ModelProviderClient::OnListModels(ModelProvider provider,
                                       ListModelsCallback done,
                                       std::optional<std::string> body) {
  const int response_code = ResponseCode(loader_.get());
  const int net_error = loader_ ? loader_->NetError() : net::ERR_FAILED;
  const bool ok = RequestSucceeded(loader_.get(), body);
  request_in_flight_ = false;
  loader_.reset();
  if (!ok) {
    std::move(done).Run(false, RequestFailedError(response_code, net_error),
                        {});
    return;
  }
  std::optional<std::vector<std::string>> models =
      ParseModelList(provider, *body);
  if (!models) {
    std::move(done).Run(false, "invalid model list response", {});
    return;
  }
  std::move(done).Run(true, std::string(), std::move(*models));
}

void ModelProviderClient::OnChat(ModelProvider provider,
                                 ChatCallback done,
                                 std::optional<std::string> body) {
  const int response_code = ResponseCode(loader_.get());
  const int net_error = loader_ ? loader_->NetError() : net::ERR_FAILED;
  const bool ok = RequestSucceeded(loader_.get(), body);
  request_in_flight_ = false;
  active_chat_request_id_.reset();
  loader_.reset();
  if (!ok) {
    std::move(done).Run(false, RequestFailedError(response_code, net_error),
                        {});
    return;
  }
  std::optional<std::string> content = ParseChatContent(provider, *body);
  if (!content) {
    std::move(done).Run(false, "invalid model chat response", {});
    return;
  }
  std::move(done).Run(true, std::string(), std::move(*content));
}

}  // namespace aegis
