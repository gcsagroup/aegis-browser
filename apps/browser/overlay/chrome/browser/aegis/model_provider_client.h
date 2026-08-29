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
#include "chrome/browser/aegis/model_provider_policy.h"

class GURL;

namespace network {
class SimpleURLLoader;
}  // namespace network

namespace aegis {

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
