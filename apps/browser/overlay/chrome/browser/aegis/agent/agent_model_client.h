// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_CLIENT_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_CLIENT_H_

#include <memory>
#include <optional>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/aegis/agent/agent_model_protocol.h"
#include "chrome/browser/aegis/model_provider_policy.h"
#include "url/gurl.h"

namespace network {
class SharedURLLoaderFactory;
class SimpleURLLoader;
}  // namespace network

namespace aegis::agent {

struct AgentModelClientConfig {
  ModelProvider provider = ModelProvider::kOpenAI;
  std::string base_url;
  std::string api_key;
};

GURL BuildAgentModelEndpoint(ModelProvider provider,
                             const GURL& base_url,
                             std::string_view model,
                             bool stream);

class AgentModelClient {
 public:
  using RequestId = std::string;
  using Callback = base::OnceCallback<
      void(bool ok, std::string error, AgentModelParseResult result)>;

  explicit AgentModelClient(
      scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory);
  AgentModelClient(const AgentModelClient&) = delete;
  AgentModelClient& operator=(const AgentModelClient&) = delete;
  ~AgentModelClient();

  std::optional<RequestId> Start(AgentModelClientConfig config,
                                 AgentModelRequest request,
                                 Callback done);
  bool Cancel(RequestId request_id);
  bool busy() const { return loader_ != nullptr; }

 private:
  void OnComplete(Callback done, std::optional<std::string> body);

  std::unique_ptr<network::SimpleURLLoader> loader_;
  scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory_;
  std::optional<RequestId> request_id_;
  AgentModelProvider active_provider_ = AgentModelProvider::kOpenAICompatible;
  bool active_stream_ = false;
  std::vector<AgentModelToolDefinition> active_tools_;
  base::WeakPtrFactory<AgentModelClient> weak_factory_{this};
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_MODEL_CLIENT_H_
