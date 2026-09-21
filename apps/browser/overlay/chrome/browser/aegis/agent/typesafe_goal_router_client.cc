// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/typesafe_goal_router_client.h"

#include <algorithm>
#include <optional>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/unguessable_token.h"
#include "chrome/browser/aegis/agent/typesafe_goal_response_parser.h"
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

namespace aegis::agent {
namespace {

constexpr size_t kMaxGoalBytes = 4096;
constexpr size_t kMaxApiKeyBytes = 4096;
constexpr base::TimeDelta kRequestTimeout = base::Seconds(2);
constexpr size_t kMaxResponseBytes = 64 * 1024;

constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("aegis_agent_typesafe_goal_router", R"(
      semantics {
        sender: "Aegis Browser Agent"
        description:
          "Optionally sends only the user-entered Agent goal to TypeSafe Jev "
          "to select a bounded workflow and entry kind."
        trigger:
          "The user starts an Agent task after separately enabling TypeSafe "
          "goal routing and saving a TypeSafe API key."
        data:
          "The user-entered goal and an API credential in the Authorization "
          "header. Page content, browsing history, cookies, and model-provider "
          "credentials are excluded."
        destination: WEBSITE
        internal {
          contacts { email: "aegis@gcsa.local" }
        }
        user_data { type: WEB_CONTENT }
        last_reviewed: "2026-09-21"
      }
      policy {
        cookies_allowed: NO
        setting:
          "Users must separately enable TypeSafe goal routing in Aegis Agent "
          "settings. It is disabled by default and unavailable in Incognito."
        policy_exception_justification:
          "The request is initiated by an explicit per-profile user setting."
      })");

bool HasControlCharacter(std::string_view value) {
  return std::ranges::any_of(
      value, [](unsigned char ch) { return ch < 0x20 || ch == 0x7f; });
}

bool IsValidGoal(std::string_view goal) {
  return !goal.empty() && goal.size() <= kMaxGoalBytes &&
         base::IsStringUTF8(goal) && goal.find('\0') == std::string_view::npos;
}

bool IsValidApiKey(std::string_view api_key) {
  return !api_key.empty() && api_key.size() <= kMaxApiKeyBytes &&
         base::IsStringUTF8(api_key) && !HasControlCharacter(api_key) &&
         base::TrimWhitespaceASCII(api_key, base::TRIM_ALL) == api_key;
}

base::DictValue ChoiceQuestion(std::string instructions,
                               base::DictValue criteria) {
  base::DictValue question;
  question.Set("type", "choice");
  question.Set("instructions", std::move(instructions));
  question.Set("criteria", std::move(criteria));
  return question;
}

base::DictValue WorkflowQuestion() {
  base::DictValue criteria;
  criteria.Set("research",
               "Read, compare, summarize, or find public information");
  criteria.Set(
      "browser_steward",
      "Work with native browser data such as bookmarks, tabs, history, "
      "downloads, permissions, or workspaces");
  criteria.Set("safe_download",
               "Find or verify an official software download");
  criteria.Set("shopping",
               "A user-authorized purchase, cart, or checkout workflow");
  return ChoiceQuestion("Which fixed Aegis workflow best matches the user goal?",
                        std::move(criteria));
}

base::DictValue EntryKindQuestion() {
  base::DictValue criteria;
  criteria.Set(
      "browser_only",
      "Use native browser data such as bookmarks, tabs, history, downloads, "
      "permissions, or workspaces; do not open a search result");
  criteria.Set(
      "web_search",
      "The goal needs a public web search before the browser can continue");
  return ChoiceQuestion(
      "Should Aegis use only existing browser context or begin with a public "
      "web search?",
      std::move(criteria));
}

int ResponseCode(network::SimpleURLLoader* loader) {
  if (!loader || !loader->ResponseInfo() ||
      !loader->ResponseInfo()->headers) {
    return 0;
  }
  return loader->ResponseInfo()->headers->response_code();
}

}  // namespace

std::optional<std::string> BuildTypeSafeGoalRequestBody(
    std::string_view goal,
    std::string* error) {
  if (!error) {
    return std::nullopt;
  }
  error->clear();
  if (!IsValidGoal(goal)) {
    *error = "invalid TypeSafe goal routing input";
    return std::nullopt;
  }

  base::DictValue questions;
  questions.Set("workflow", WorkflowQuestion());
  questions.Set("entry_kind", EntryKindQuestion());

  base::DictValue request;
  request.Set("state", std::string(goal));
  request.Set("model", kTypeSafeGoalRouterModel);
  request.Set("questions", std::move(questions));
  std::optional<std::string> body = base::WriteJson(request);
  if (!body) {
    *error = "failed to serialize TypeSafe goal routing request";
  }
  return body;
}

TypeSafeGoalRouterClient::TypeSafeGoalRouterClient(
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory)
    : url_loader_factory_(std::move(url_loader_factory)) {}

TypeSafeGoalRouterClient::~TypeSafeGoalRouterClient() = default;

std::optional<TypeSafeGoalRouterClient::RequestId>
TypeSafeGoalRouterClient::Start(std::string goal,
                                std::string api_key,
                                Callback callback) {
  if (loader_) {
    std::move(callback).Run(false, "TypeSafe goal request already in progress",
                            std::nullopt);
    return std::nullopt;
  }
  if (!url_loader_factory_ || !IsValidApiKey(api_key)) {
    std::move(callback).Run(false, "TypeSafe goal routing is unavailable",
                            std::nullopt);
    return std::nullopt;
  }
  std::string error;
  std::optional<std::string> body = BuildTypeSafeGoalRequestBody(goal, &error);
  if (!body) {
    std::move(callback).Run(false, std::move(error), std::nullopt);
    return std::nullopt;
  }

  auto request = std::make_unique<network::ResourceRequest>();
  request->url = GURL(kTypeSafeSystemOneEndpoint);
  request->method = "POST";
  request->redirect_mode = network::mojom::RedirectMode::kError;
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->load_flags = net::LOAD_BYPASS_CACHE | net::LOAD_DISABLE_CACHE |
                        net::LOAD_DO_NOT_SAVE_COOKIES;
  request->headers.SetHeader(net::HttpRequestHeaders::kAccept,
                             "application/json");
  request->headers.SetHeader(net::HttpRequestHeaders::kAuthorization,
                             base::StrCat({"Bearer ", api_key}));

  request_id_ = base::UnguessableToken::Create().ToString();
  original_goal_ = std::move(goal);
  callback_ = std::move(callback);
  loader_ = network::SimpleURLLoader::Create(std::move(request),
                                              kTrafficAnnotation);
  loader_->AttachStringForUpload(*body, "application/json");
  loader_->SetTimeoutDuration(kRequestTimeout);
  loader_->SetRetryOptions(0, network::SimpleURLLoader::RETRY_NEVER);
  loader_->DownloadToString(
      url_loader_factory_.get(),
      base::BindOnce(&TypeSafeGoalRouterClient::OnComplete,
                     weak_ptr_factory_.GetWeakPtr(), *request_id_),
      kMaxResponseBytes);
  return request_id_;
}

bool TypeSafeGoalRouterClient::Cancel(const RequestId& request_id) {
  if (!request_id_ || *request_id_ != request_id) {
    return false;
  }
  loader_.reset();
  request_id_.reset();
  original_goal_.clear();
  Callback callback = std::move(callback_);
  if (callback) {
    std::move(callback).Run(false, "TypeSafe goal routing was cancelled",
                            std::nullopt);
  }
  return true;
}

void TypeSafeGoalRouterClient::OnComplete(RequestId request_id,
                                          std::optional<std::string> body) {
  if (!request_id_ || *request_id_ != request_id) {
    return;
  }
  Callback callback = std::move(callback_);
  std::string original_goal = std::move(original_goal_);
  const int response_code = ResponseCode(loader_.get());
  const int net_error = loader_ ? loader_->NetError() : net::ERR_FAILED;
  const bool request_ok = loader_ && net_error == net::OK && body &&
                          response_code >= 200 && response_code < 300;
  loader_.reset();
  request_id_.reset();
  if (!callback) {
    return;
  }
  if (!request_ok) {
    std::move(callback).Run(false, "TypeSafe goal routing request failed",
                            std::nullopt);
    return;
  }
  std::string error;
  std::optional<AgentGoalRoute> route =
      TypeSafeGoalResponseParser::Parse(*body, original_goal, &error);
  std::move(callback).Run(route.has_value(), std::move(error),
                          std::move(route));
}

}  // namespace aegis::agent
