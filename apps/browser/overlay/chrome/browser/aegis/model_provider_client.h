// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/model_provider_client.h

#ifndef CHROME_BROWSER_AEGIS_MODEL_PROVIDER_CLIENT_H_
#define CHROME_BROWSER_AEGIS_MODEL_PROVIDER_CLIENT_H_

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"

class GURL;

namespace network {
class SimpleURLLoader;
}  // namespace network

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

// 只有数值 loopback HTTP(S) 属于本机目标。localhost 等名称不会被视为
// 本机目标，以免 DNS、代理或 hosts 配置改变请求去向。
bool IsLocalModelEndpoint(ModelProvider provider, const GURL& base_url);

// HTTP 仅允许数值 loopback；其他主机必须使用 HTTPS。允许安全的路径前缀，
// 但拒绝 userinfo、query、fragment 和无效端口。
bool IsAllowedModelBaseUrl(ModelProvider provider, const GURL& base_url);
bool ModelProviderRequiresApiKey(ModelProvider provider);
bool IsValidModelName(ModelProvider provider, std::string_view model);

// 所有请求都禁用缓存；只有数值 loopback 绕过系统代理。
int ModelProviderRequestLoadFlags(ModelProvider provider, const GURL& base_url);

// 本机大模型通常比外网 API 慢，给数值 loopback 更长的生成窗口。
base::TimeDelta ModelProviderChatTimeout(ModelProvider provider,
                                         const GURL& base_url);

class ModelProviderClient {
 public:
  using ChatRequestId = std::string;
  using ListModelsCallback = base::OnceCallback<
      void(bool ok, std::string error, std::vector<std::string> models)>;
  using ChatCallback =
      base::OnceCallback<void(bool ok, std::string error, std::string content)>;

  ModelProviderClient();
  ModelProviderClient(const ModelProviderClient&) = delete;
  ModelProviderClient& operator=(const ModelProviderClient&) = delete;
  ~ModelProviderClient();

  void ListModels(ModelProvider provider,
                  const std::string& base_url,
                  const std::string& api_key,
                  ListModelsCallback done);
  std::optional<ChatRequestId> Chat(ModelProvider provider,
                                    const std::string& base_url,
                                    const std::string& api_key,
                                    const std::string& model,
                                    const std::string& system,
                                    const std::string& user,
                                    ChatCallback done);
  bool CancelChat(ChatRequestId request_id);

  bool busy() const { return request_in_flight_; }

 private:
  void OnListModels(ModelProvider provider,
                    ListModelsCallback done,
                    std::optional<std::string> body);
  void OnChat(ModelProvider provider,
              ChatCallback done,
              std::optional<std::string> body);

  std::unique_ptr<network::SimpleURLLoader> loader_;
  bool request_in_flight_ = false;
  std::optional<ChatRequestId> active_chat_request_id_;
  base::WeakPtrFactory<ModelProviderClient> weak_factory_{this};
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_MODEL_PROVIDER_CLIENT_H_
