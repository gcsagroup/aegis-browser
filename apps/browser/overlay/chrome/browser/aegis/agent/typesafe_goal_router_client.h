// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_GOAL_ROUTER_CLIENT_H_
#define CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_GOAL_ROUTER_CLIENT_H_

#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/aegis/agent/agent_planner.h"

namespace network {
class SharedURLLoaderFactory;
class SimpleURLLoader;
}  // namespace network

namespace aegis::agent {

inline constexpr char kTypeSafeSystemOneEndpoint[] =
    "https://api.typesafe.ai/v1/systemone";
inline constexpr char kTypeSafeGoalRouterModel[] = "jev-latest";
inline constexpr double kTypeSafeGoalRouteMinimumConfidence = 0.8;

std::optional<std::string> BuildTypeSafeGoalRequestBody(
    std::string_view goal,
    std::string* error);
std::optional<AgentGoalRoute> ParseTypeSafeGoalResponse(
    std::string_view body,
    std::string_view original_goal,
    std::string* error);

class TypeSafeGoalRouterClient {
 public:
  using RequestId = std::string;
  using Callback = base::OnceCallback<void(
      bool ok,
      std::string error,
      std::optional<AgentGoalRoute> route)>;

  explicit TypeSafeGoalRouterClient(
      scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory);
  TypeSafeGoalRouterClient(const TypeSafeGoalRouterClient&) = delete;
  TypeSafeGoalRouterClient& operator=(const TypeSafeGoalRouterClient&) = delete;
  ~TypeSafeGoalRouterClient();

  std::optional<RequestId> Start(std::string goal,
                                 std::string api_key,
                                 Callback callback);
  bool Cancel(const RequestId& request_id);
  bool busy() const { return loader_ != nullptr; }

 private:
  void OnComplete(std::optional<std::string> body);

  std::unique_ptr<network::SimpleURLLoader> loader_;
  scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory_;
  std::optional<RequestId> request_id_;
  std::string original_goal_;
  Callback callback_;
  base::WeakPtrFactory<TypeSafeGoalRouterClient> weak_ptr_factory_{this};
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_TYPESAFE_GOAL_ROUTER_CLIENT_H_
