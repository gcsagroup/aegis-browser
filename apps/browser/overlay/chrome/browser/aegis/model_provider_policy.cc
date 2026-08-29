// Copyright 2026 GCSA

#include "chrome/browser/aegis/model_provider_policy.h"

#include <algorithm>

#include "base/strings/string_util.h"
#include "net/base/ip_address.h"
#include "net/base/load_flags.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr size_t kMaxModelNameBytes = 256;
constexpr std::string_view kOpenAIBaseUrl = "https://api.openai.com/v1";
constexpr std::string_view kAnthropicBaseUrl = "https://api.anthropic.com/v1";
constexpr std::string_view kGeminiBaseUrl =
    "https://generativelanguage.googleapis.com/v1beta";

bool HasControlCharacter(std::string_view value) {
  return std::ranges::any_of(
      value, [](unsigned char ch) { return ch < 0x20 || ch == 0x7f; });
}

}  // namespace

std::optional<ModelProvider> ParseModelProvider(std::string_view id) {
  if (id == "openai") {
    return ModelProvider::kOpenAI;
  }
  if (id == "anthropic") {
    return ModelProvider::kAnthropic;
  }
  if (id == "gemini") {
    return ModelProvider::kGemini;
  }
  return std::nullopt;
}

std::string_view ModelProviderId(ModelProvider provider) {
  switch (provider) {
    case ModelProvider::kOpenAI:
      return "openai";
    case ModelProvider::kAnthropic:
      return "anthropic";
    case ModelProvider::kGemini:
      return "gemini";
  }
}

std::string_view DefaultModelBaseUrl(ModelProvider provider) {
  switch (provider) {
    case ModelProvider::kOpenAI:
      return kOpenAIBaseUrl;
    case ModelProvider::kAnthropic:
      return kAnthropicBaseUrl;
    case ModelProvider::kGemini:
      return kGeminiBaseUrl;
  }
}

std::string_view DefaultModelName(ModelProvider provider) {
  switch (provider) {
    case ModelProvider::kOpenAI:
      return "gpt-4.1-mini";
    case ModelProvider::kAnthropic:
      return "claude-sonnet-4-5";
    case ModelProvider::kGemini:
      return "gemini-2.5-flash";
  }
}

bool IsLocalModelEndpoint(ModelProvider provider, const GURL& base_url) {
  (void)provider;
  if (!base_url.is_valid() || !base_url.SchemeIsHTTPOrHTTPS() ||
      base_url.has_username() || base_url.has_password() ||
      base_url.has_query() || base_url.has_ref() ||
      base_url.EffectiveIntPort() <= 0) {
    return false;
  }
  net::IPAddress address;
  return address.AssignFromIPLiteral(base_url.HostNoBracketsPiece()) &&
         address.IsLoopback();
}

bool IsAllowedModelBaseUrl(ModelProvider provider, const GURL& base_url) {
  (void)provider;
  if (!base_url.is_valid() || base_url.has_username() ||
      base_url.has_password() || base_url.has_query() || base_url.has_ref() ||
      base_url.EffectiveIntPort() <= 0) {
    return false;
  }
  if (base_url.SchemeIs("http")) {
    return IsLocalModelEndpoint(provider, base_url);
  }
  return base_url.SchemeIs("https") && !base_url.host().empty();
}

bool ModelProviderRequiresApiKey(ModelProvider provider) {
  (void)provider;
  return false;
}

bool IsValidModelName(ModelProvider provider, std::string_view model) {
  (void)provider;
  return !model.empty() && model.size() <= kMaxModelNameBytes &&
         base::IsStringUTF8(model) && !HasControlCharacter(model) &&
         base::TrimWhitespaceASCII(model, base::TRIM_ALL) == model;
}

int ModelProviderRequestLoadFlags(ModelProvider provider,
                                  const GURL& base_url) {
  int flags = net::LOAD_DISABLE_CACHE | net::LOAD_BYPASS_CACHE |
              net::LOAD_DO_NOT_SAVE_COOKIES;
  if (IsLocalModelEndpoint(provider, base_url)) {
    flags |= net::LOAD_BYPASS_PROXY;
  }
  return flags;
}

base::TimeDelta ModelProviderChatTimeout(ModelProvider provider,
                                         const GURL& base_url) {
  return IsLocalModelEndpoint(provider, base_url) ? base::Minutes(3)
                                                  : base::Seconds(45);
}

}  // namespace aegis
