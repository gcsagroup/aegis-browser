// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/typesafe_goal_router_client.h"

#include <memory>
#include <optional>
#include <string>

#include "base/json/json_reader.h"
#include "base/test/test_future.h"
#include "base/test/task_environment.h"
#include "mojo/core/embedder/embedder.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_status_code.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/test/test_url_loader_factory.h"
#include "services/network/test/test_utils.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis::agent {
namespace {

constexpr char kApiKey[] = "ts-fixture-secret";
constexpr char kGoal[] = "Compare three reliable USB hubs";
constexpr char kValidResponse[] = R"({
  "model":"jev-1.13.0",
  "answers":{
    "workflow":{
      "type":"choice","choice":"research","confidence":0.92,
      "probabilities":{"research":0.92,"browser_steward":0.03,"safe_download":0.03,"shopping":0.02}
    },
    "entry_kind":{
      "type":"choice","choice":"web_search","confidence":0.90,
      "probabilities":{"browser_only":0.05,"web_search":0.95}
    }
  },
  "usage":{"input_tokens":42,"output_tokens":18}
})";

class TypeSafeGoalRouterClientTest : public testing::Test {
 protected:
  static void SetUpTestSuite() { mojo::core::Init(); }

  TypeSafeGoalRouterClientTest()
      : client_(factory_.GetSafeWeakWrapper()) {}

  base::test::TaskEnvironment task_environment_{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME};
  network::TestURLLoaderFactory factory_;
  TypeSafeGoalRouterClient client_;
};

TEST_F(TypeSafeGoalRouterClientTest, SendsOnlyBoundedGoalDecisionRequest) {
  base::test::TestFuture<bool, std::string, std::optional<AgentGoalRoute>> done;
  ASSERT_TRUE(client_.Start(kGoal, kApiKey, done.GetCallback()));
  const GURL endpoint(kTypeSafeSystemOneEndpoint);
  factory_.WaitForRequest(endpoint);
  ASSERT_EQ(factory_.NumPending(), 1);
  const network::ResourceRequest& request =
      factory_.GetPendingRequest(0)->request;
  EXPECT_EQ(request.method, "POST");
  EXPECT_EQ(request.credentials_mode,
            network::mojom::CredentialsMode::kOmit);
  EXPECT_EQ(request.redirect_mode, network::mojom::RedirectMode::kError);
  EXPECT_EQ(request.headers.GetHeader(net::HttpRequestHeaders::kAuthorization),
            "Bearer ts-fixture-secret");
  const std::string upload = network::GetUploadData(request);
  const std::optional<base::DictValue> payload =
      base::JSONReader::ReadDict(upload, base::JSON_PARSE_RFC);
  ASSERT_TRUE(payload);
  const std::string* state = payload->FindString("state");
  const std::string* model = payload->FindString("model");
  ASSERT_TRUE(state);
  ASSERT_TRUE(model);
  EXPECT_EQ(*state, kGoal);
  EXPECT_EQ(*model, kTypeSafeGoalRouterModel);
  EXPECT_EQ(payload->size(), 3u);
  const base::DictValue* questions = payload->FindDict("questions");
  ASSERT_TRUE(questions);
  EXPECT_EQ(questions->size(), 2u);
  for (std::string_view name : {"workflow", "entry_kind"}) {
    const base::DictValue* question = questions->FindDict(name);
    ASSERT_TRUE(question);
    EXPECT_EQ(question->size(), 3u);
    const std::string* type = question->FindString("type");
    ASSERT_TRUE(type);
    EXPECT_EQ(*type, "choice");
    EXPECT_TRUE(question->FindString("instructions"));
    EXPECT_TRUE(question->FindDict("criteria"));
  }
  EXPECT_FALSE(payload->contains("page"));
  EXPECT_FALSE(payload->contains("history"));
  EXPECT_FALSE(payload->contains("cookies"));
  EXPECT_FALSE(payload->contains("model_credentials"));

  ASSERT_TRUE(factory_.SimulateResponseForPendingRequest(endpoint.spec(),
                                                          kValidResponse));
  EXPECT_TRUE(done.Get<0>()) << done.Get<1>();
  ASSERT_TRUE(done.Get<2>());
  EXPECT_EQ(done.Get<2>()->workflow, AgentWorkflowKind::kResearch);
  EXPECT_EQ(done.Get<2>()->entry_kind, AgentGoalEntryKind::kWebSearch);
  EXPECT_EQ(done.Get<2>()->target, kGoal);
}

TEST_F(TypeSafeGoalRouterClientTest,
       RejectsLowConfidenceAndContradictoryDistributions) {
  std::string error;
  EXPECT_FALSE(ParseTypeSafeGoalResponse(
      R"({"model":"jev","answers":{"workflow":{"type":"choice","choice":"research","confidence":0.79,"probabilities":{"research":0.92,"browser_steward":0.03,"safe_download":0.03,"shopping":0.02}},"entry_kind":{"type":"choice","choice":"web_search","confidence":0.9,"probabilities":{"browser_only":0.05,"web_search":0.95}}}})",
      kGoal, &error));
  EXPECT_FALSE(error.empty());

  EXPECT_FALSE(ParseTypeSafeGoalResponse(
      R"({"model":"jev","answers":{"workflow":{"type":"choice","choice":"research","confidence":0.95,"probabilities":{"research":0.02,"browser_steward":0.03,"safe_download":0.03,"shopping":0.92}},"entry_kind":{"type":"choice","choice":"web_search","confidence":0.9,"probabilities":{"browser_only":0.05,"web_search":0.95}}}})",
      kGoal, &error));
  EXPECT_NE(error.find("contradicts"), std::string::npos);
}

TEST_F(TypeSafeGoalRouterClientTest,
       RejectsIncompatibleWorkflowAndOversizedDerivedSearch) {
  std::string error;
  EXPECT_FALSE(ParseTypeSafeGoalResponse(
      R"({"model":"jev","answers":{"workflow":{"type":"choice","choice":"browser_steward","confidence":0.95,"probabilities":{"research":0.02,"browser_steward":0.92,"safe_download":0.03,"shopping":0.03}},"entry_kind":{"type":"choice","choice":"web_search","confidence":0.9,"probabilities":{"browser_only":0.05,"web_search":0.95}}}})",
      kGoal, &error));
  EXPECT_EQ(error, "goal route contains an invalid search query");

  const std::string oversized_goal(1025, 'a');
  EXPECT_FALSE(
      ParseTypeSafeGoalResponse(kValidResponse, oversized_goal, &error));
  EXPECT_EQ(error, "goal route contains an invalid search query");
}

TEST_F(TypeSafeGoalRouterClientTest, DoesNotRetryHttpFailure) {
  base::test::TestFuture<bool, std::string, std::optional<AgentGoalRoute>> done;
  ASSERT_TRUE(client_.Start(kGoal, kApiKey, done.GetCallback()));
  const GURL endpoint(kTypeSafeSystemOneEndpoint);
  factory_.WaitForRequest(endpoint);
  ASSERT_TRUE(factory_.SimulateResponseForPendingRequest(
      endpoint.spec(), "rate limited", net::HTTP_TOO_MANY_REQUESTS));
  EXPECT_FALSE(done.Get<0>());
  EXPECT_EQ(factory_.NumPending(), 0);
}

TEST_F(TypeSafeGoalRouterClientTest, CancelSettlesCallbackAndStopsRequest) {
  base::test::TestFuture<bool, std::string, std::optional<AgentGoalRoute>> done;
  const std::optional<std::string> request_id =
      client_.Start(kGoal, kApiKey, done.GetCallback());
  ASSERT_TRUE(request_id);
  factory_.WaitForRequest(GURL(kTypeSafeSystemOneEndpoint));
  EXPECT_TRUE(client_.Cancel(*request_id));
  EXPECT_FALSE(done.Get<0>());
  EXPECT_NE(done.Get<1>().find("cancelled"), std::string::npos);
  EXPECT_FALSE(client_.busy());
}

TEST_F(TypeSafeGoalRouterClientTest, TimesOutWithoutRetry) {
  base::test::TestFuture<bool, std::string, std::optional<AgentGoalRoute>> done;
  ASSERT_TRUE(client_.Start(kGoal, kApiKey, done.GetCallback()));
  factory_.WaitForRequest(GURL(kTypeSafeSystemOneEndpoint));
  task_environment_.FastForwardBy(base::Seconds(2));
  EXPECT_FALSE(done.Get<0>());
  EXPECT_EQ(factory_.NumPending(), 0);
}

}  // namespace
}  // namespace aegis::agent
