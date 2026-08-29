// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_MODEL_PROVIDER_POLICY_H_
#define CHROME_BROWSER_AEGIS_MODEL_PROVIDER_POLICY_H_

#include <optional>
#include <string_view>

#include "base/time/time.h"

class GURL;

namespace aegis {

enum class ModelProvider {
  kOpenAI,
  kAnthropic,
  kGemini,
};

std::optional<ModelProvider> ParseModelProvider(std::string_view id);
std::string_view ModelProviderId(ModelProvider provider);
std::string_view DefaultModelBaseUrl(ModelProvider provider);
std::string_view DefaultModelName(ModelProvider provider);

// Only numeric loopback HTTP(S) endpoints are local. Hostnames such as
// localhost remain remote because DNS, proxies, and hosts files can redirect.
bool IsLocalModelEndpoint(ModelProvider provider, const GURL& base_url);

// Plain HTTP is allowed only for numeric loopback. Remote destinations require
// HTTPS. Base URLs reject userinfo, query, fragment, and invalid ports.
bool IsAllowedModelBaseUrl(ModelProvider provider, const GURL& base_url);
bool ModelProviderRequiresApiKey(ModelProvider provider);
bool IsValidModelName(ModelProvider provider, std::string_view model);
int ModelProviderRequestLoadFlags(ModelProvider provider, const GURL& base_url);
base::TimeDelta ModelProviderChatTimeout(ModelProvider provider,
                                         const GURL& base_url);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_MODEL_PROVIDER_POLICY_H_
