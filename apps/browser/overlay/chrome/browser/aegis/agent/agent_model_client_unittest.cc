// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_model_client.h"

#include <optional>
#include <string>

#include "base/json/json_reader.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "mojo/core/embedder/embedder.h"
#include "net/base/load_flags.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_status_code.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/test/test_url_loader_factory.h"
#include "services/network/test/test_utils.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::agent {
namespace {

using testing::HasSubstr;
using testing::Not;
using testing::SizeIs;

AgentModelToolDefinition ObserveTool() {
  AgentModelToolDefinition tool;
  tool.name = "page.observe";
  tool.description = "Read an approved page.";
  tool.input_schema.Set("type", "object");
  base::DictValue properties;
  base::DictValue tab_id;
  tab_id.Set("type", "integer");
  tab_id.Set("minimum", 1);
  properties.Set("tab_id", std::move(tab_id));
  tool.input_schema.Set("properties", std::move(properties));
  base::ListValue required;
  required.Append("tab_id");
  tool.input_schema.Set("required", std::move(required));
  tool.input_schema.Set("additionalProperties", false);
  return tool;
}

AgentModelRequest Request(AgentModelProvider provider, bool stream) {
  AgentModelRequest request;
  request.provider = provider;
  request.model = "fixture-model";
  request.system_prompt = "Fixed browser policy.";
  request.user_prompt = "Observe the approved page.";
  request.tools.push_back(ObserveTool());
  request.stream = stream;
  return request;
}

class AgentModelClientTest : public testing::Test {
 protected:
  static void SetUpTestSuite() { mojo::core::Init(); }

  const network::ResourceRequest& Pending(const GURL& endpoint) {
    factory_.WaitForRequest(endpoint);
    EXPECT_THAT(*factory_.pending_requests(), SizeIs(1));
    return factory_.GetPendingRequest(0)->request;
  }

  base::test::TaskEnvironment task_environment_;
  network::TestURLLoaderFactory factory_;
};

TEST_F(AgentModelClientTest, SendsRestrictedOpenAIRequestToLoopback) {
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  AgentModelClient client(factory_.GetSafeWeakWrapper());
  AgentModelClientConfig config{.provider = ModelProvider::kOpenAI,
                                .base_url = "http://127.0.0.1:8765/v1"};
  base::test::TestFuture<bool, std::string, AgentModelParseResult> result;
  const std::optional<std::string> request_id = client.Start(
      std::move(config), Request(AgentModelProvider::kOpenAICompatible, false),
      result.GetCallback());
  ASSERT_TRUE(request_id);

  const network::ResourceRequest& request = Pending(endpoint);
  EXPECT_EQ("POST", request.method);
  EXPECT_EQ(network::mojom::RedirectMode::kError, request.redirect_mode);
  EXPECT_EQ(network::mojom::CredentialsMode::kOmit, request.credentials_mode);
  EXPECT_NE(0, request.load_flags & net::LOAD_BYPASS_PROXY);
  EXPECT_FALSE(
      request.headers.HasHeader(net::HttpRequestHeaders::kAuthorization));
  const std::optional<base::Value> body = base::JSONReader::Read(
      network::GetUploadData(request), base::JSON_PARSE_RFC);
  ASSERT_TRUE(body && body->is_dict());
  EXPECT_EQ(body->GetDict().FindBool("store"), false);
  EXPECT_EQ(body->GetDict().FindBool("parallel_tool_calls"), false);
  ASSERT_EQ(body->GetDict().FindList("tools")->size(), 1u);

  EXPECT_TRUE(factory_.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"status":"completed","output":[{"type":"function_call","call_id":"call-1","name":"page.observe","arguments":"{\"tab_id\":7}"}]})"));
  EXPECT_TRUE(result.Get<0>()) << result.Get<1>();
  ASSERT_EQ(result.Get<2>().events.size(), 2u);
  EXPECT_EQ(result.Get<2>().events[0].tool_name, "page.observe");
}

TEST_F(AgentModelClientTest, UsesProviderHeadersAndStreamingEndpoints) {
  {
    const GURL endpoint("https://model.example/anthropic/v1/messages");
    AgentModelClient client(factory_.GetSafeWeakWrapper());
    AgentModelClientConfig config{
        .provider = ModelProvider::kAnthropic,
        .base_url = "https://model.example/anthropic/v1",
        .api_key = "anthropic-fixture-key"};
    base::test::TestFuture<bool, std::string, AgentModelParseResult> result;
    ASSERT_TRUE(client.Start(std::move(config),
                             Request(AgentModelProvider::kAnthropic, false),
                             result.GetCallback()));
    const network::ResourceRequest& request = Pending(endpoint);
    EXPECT_EQ("anthropic-fixture-key",
              request.headers.GetHeader("x-api-key").value_or(""));
    EXPECT_EQ("2023-06-01",
              request.headers.GetHeader("anthropic-version").value_or(""));
    EXPECT_TRUE(factory_.SimulateResponseForPendingRequest(
        endpoint.spec(),
        R"({"content":[{"type":"tool_use","id":"call-a","name":"page.observe","input":{"tab_id":2}}],"stop_reason":"tool_use"})"));
    EXPECT_TRUE(result.Get<0>()) << result.Get<1>();
  }
  {
    const GURL endpoint(
        "https://model.example/google/v1beta/models/"
        "fixture-model:streamGenerateContent?alt=sse");
    AgentModelClient client(factory_.GetSafeWeakWrapper());
    AgentModelClientConfig config{
        .provider = ModelProvider::kGemini,
        .base_url = "https://model.example/google/v1beta",
        .api_key = "gemini-fixture-key"};
    base::test::TestFuture<bool, std::string, AgentModelParseResult> result;
    ASSERT_TRUE(client.Start(std::move(config),
                             Request(AgentModelProvider::kGemini, true),
                             result.GetCallback()));
    const network::ResourceRequest& request = Pending(endpoint);
    EXPECT_EQ("gemini-fixture-key",
              request.headers.GetHeader("x-goog-api-key").value_or(""));
    EXPECT_EQ("text/event-stream",
              request.headers.GetHeader(net::HttpRequestHeaders::kAccept)
                  .value_or(""));
    EXPECT_TRUE(factory_.SimulateResponseForPendingRequest(
        endpoint.spec(),
        "data: "
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":"
        "\"page.observe\",\"args\":{\"tab_id\":3}}}]}}]}\n\n"));
    EXPECT_TRUE(result.Get<0>()) << result.Get<1>();
  }
}

TEST_F(AgentModelClientTest, RejectsUnsafeConfigurationWithoutNetwork) {
  AgentModelClient client(factory_.GetSafeWeakWrapper());
  AgentModelClientConfig config{
      .provider = ModelProvider::kOpenAI,
      .base_url = "http://model.example/v1?key=secret"};
  base::test::TestFuture<bool, std::string, AgentModelParseResult> result;
  EXPECT_FALSE(client.Start(
      std::move(config), Request(AgentModelProvider::kOpenAICompatible, false),
      result.GetCallback()));
  EXPECT_FALSE(result.Get<0>());
  EXPECT_EQ(result.Get<1>(), "invalid agent model configuration");
  EXPECT_TRUE(factory_.pending_requests()->empty());
}

TEST_F(AgentModelClientTest, DoesNotLeakProviderErrorOrApiKey) {
  const GURL endpoint("https://model.example/v1/responses");
  AgentModelClient client(factory_.GetSafeWeakWrapper());
  AgentModelClientConfig config{.provider = ModelProvider::kOpenAI,
                                .base_url = "https://model.example/v1",
                                .api_key = "sk-fixture-secret"};
  base::test::TestFuture<bool, std::string, AgentModelParseResult> result;
  ASSERT_TRUE(client.Start(
      std::move(config), Request(AgentModelProvider::kOpenAICompatible, false),
      result.GetCallback()));
  const network::ResourceRequest& request = Pending(endpoint);
  EXPECT_EQ("Bearer sk-fixture-secret",
            request.headers.GetHeader(net::HttpRequestHeaders::kAuthorization)
                .value_or(""));
  EXPECT_TRUE(factory_.SimulateResponseForPendingRequest(
      endpoint.spec(), "provider-private-body", net::HTTP_UNAUTHORIZED));
  EXPECT_FALSE(result.Get<0>());
  EXPECT_THAT(result.Get<1>(), HasSubstr("HTTP 401"));
  EXPECT_THAT(result.Get<1>(), Not(HasSubstr("sk-fixture-secret")));
  EXPECT_THAT(result.Get<1>(), Not(HasSubstr("provider-private-body")));
}

TEST_F(AgentModelClientTest, CancelsOnlyMatchingRequest) {
  const GURL endpoint("http://127.0.0.1:8765/v1/responses");
  AgentModelClient client(factory_.GetSafeWeakWrapper());
  AgentModelClientConfig config{.provider = ModelProvider::kOpenAI,
                                .base_url = "http://127.0.0.1:8765/v1"};
  base::test::TestFuture<bool, std::string, AgentModelParseResult> abandoned;
  const std::optional<std::string> id = client.Start(
      std::move(config), Request(AgentModelProvider::kOpenAICompatible, false),
      abandoned.GetCallback());
  ASSERT_TRUE(id);
  Pending(endpoint);
  EXPECT_FALSE(client.Cancel("wrong-id"));
  EXPECT_TRUE(client.busy());
  EXPECT_TRUE(client.Cancel(*id));
  EXPECT_FALSE(client.busy());
  EXPECT_FALSE(client.Cancel(*id));
}

}  // namespace
}  // namespace aegis::agent
