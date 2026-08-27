// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/model_provider_client_unittest.cc

#include "chrome/browser/aegis/model_provider_client.h"

#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "base/values.h"
#include "chrome/test/base/testing_browser_process.h"
#include "net/base/load_flags.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_status_code.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "services/network/test/test_url_loader_factory.h"
#include "services/network/test/test_utils.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

using testing::ElementsAre;
using testing::HasSubstr;
using testing::Not;
using testing::SizeIs;

TEST(ModelProviderPolicyTest, UsesApiFormatIdsAndVersionedDefaults) {
  EXPECT_EQ(ModelProvider::kOpenAI, ParseModelProvider("openai"));
  EXPECT_EQ(ModelProvider::kAnthropic, ParseModelProvider("anthropic"));
  EXPECT_EQ(ModelProvider::kGemini, ParseModelProvider("gemini"));
  EXPECT_FALSE(ParseModelProvider("ollama"));
  EXPECT_FALSE(ParseModelProvider("claude"));
  EXPECT_FALSE(ParseModelProvider("OPENAI"));

  EXPECT_EQ("https://api.openai.com/v1",
            DefaultModelBaseUrl(ModelProvider::kOpenAI));
  EXPECT_EQ("https://api.anthropic.com/v1",
            DefaultModelBaseUrl(ModelProvider::kAnthropic));
  EXPECT_EQ("https://generativelanguage.googleapis.com/v1beta",
            DefaultModelBaseUrl(ModelProvider::kGemini));
  EXPECT_EQ("gpt-4.1-mini", DefaultModelName(ModelProvider::kOpenAI));
  EXPECT_EQ("claude-sonnet-4-5", DefaultModelName(ModelProvider::kAnthropic));
  EXPECT_EQ("gemini-2.5-flash", DefaultModelName(ModelProvider::kGemini));

  for (ModelProvider provider :
       {ModelProvider::kOpenAI, ModelProvider::kAnthropic,
        ModelProvider::kGemini}) {
    EXPECT_EQ(provider, ParseModelProvider(ModelProviderId(provider)));
    EXPECT_FALSE(ModelProviderRequiresApiKey(provider));
  }
}

TEST(ModelProviderPolicyTest, AllowsHttpsAndNumericLoopbackHttpWithPrefixes) {
  EXPECT_TRUE(IsAllowedModelBaseUrl(ModelProvider::kOpenAI,
                                    GURL("http://127.0.0.1:8000/v1")));
  EXPECT_TRUE(
      IsAllowedModelBaseUrl(ModelProvider::kAnthropic,
                            GURL("http://[::1]:8080/proxy/anthropic/v1/")));
  EXPECT_TRUE(IsAllowedModelBaseUrl(
      ModelProvider::kGemini,
      GURL("https://gateway.example.test/google/v1beta")));
  EXPECT_TRUE(IsAllowedModelBaseUrl(ModelProvider::kOpenAI,
                                    GURL("https://localhost/custom/v1")));

  EXPECT_TRUE(IsLocalModelEndpoint(ModelProvider::kOpenAI,
                                   GURL("http://127.0.0.1:8000/v1")));
  EXPECT_TRUE(IsLocalModelEndpoint(ModelProvider::kGemini,
                                   GURL("https://[::1]/google/v1beta")));
  EXPECT_FALSE(IsLocalModelEndpoint(ModelProvider::kOpenAI,
                                    GURL("https://localhost/custom/v1")));
  EXPECT_FALSE(
      IsLocalModelEndpoint(ModelProvider::kAnthropic,
                           GURL("https://gateway.example.test/anthropic/v1")));
}

TEST(ModelProviderPolicyTest, RejectsUnsafeOrAmbiguousBaseUrls) {
  for (ModelProvider provider :
       {ModelProvider::kOpenAI, ModelProvider::kAnthropic,
        ModelProvider::kGemini}) {
    EXPECT_FALSE(IsAllowedModelBaseUrl(provider,
                                       GURL("http://gateway.example.test/v1")));
    EXPECT_FALSE(
        IsAllowedModelBaseUrl(provider, GURL("http://localhost:8000/v1")));
    EXPECT_FALSE(IsAllowedModelBaseUrl(
        provider, GURL("https://user@gateway.example.test/v1")));
    EXPECT_FALSE(IsAllowedModelBaseUrl(
        provider, GURL("https://gateway.example.test/v1?key=secret")));
    EXPECT_FALSE(IsAllowedModelBaseUrl(
        provider, GURL("https://gateway.example.test/v1#fragment")));
    EXPECT_FALSE(
        IsAllowedModelBaseUrl(provider, GURL("http://127.0.0.1:0/v1")));
    EXPECT_FALSE(IsAllowedModelBaseUrl(provider, GURL("ftp://127.0.0.1/v1")));
    EXPECT_FALSE(IsAllowedModelBaseUrl(provider, GURL("not a url")));
  }
}

TEST(ModelProviderPolicyTest, ValidatesNamesCookiesCacheAndProxyFlags) {
  EXPECT_TRUE(
      IsValidModelName(ModelProvider::kOpenAI, "ft:gpt-4.1-mini:team:id"));
  EXPECT_TRUE(IsValidModelName(ModelProvider::kAnthropic, "claude-sonnet-4-5"));
  EXPECT_TRUE(
      IsValidModelName(ModelProvider::kGemini, "models/gemini-2.5-flash"));
  EXPECT_FALSE(IsValidModelName(ModelProvider::kOpenAI, ""));
  EXPECT_FALSE(IsValidModelName(ModelProvider::kOpenAI, " leading-space"));
  EXPECT_FALSE(IsValidModelName(ModelProvider::kOpenAI, "bad\nmodel"));
  EXPECT_FALSE(
      IsValidModelName(ModelProvider::kOpenAI, std::string("bad\xFF", 4)));
  EXPECT_FALSE(IsValidModelName(ModelProvider::kOpenAI, std::string(257, 'a')));

  const int local_flags = ModelProviderRequestLoadFlags(
      ModelProvider::kOpenAI, GURL("http://127.0.0.1:8000/v1"));
  EXPECT_NE(0, local_flags & net::LOAD_DISABLE_CACHE);
  EXPECT_NE(0, local_flags & net::LOAD_BYPASS_CACHE);
  EXPECT_NE(0, local_flags & net::LOAD_DO_NOT_SAVE_COOKIES);
  EXPECT_NE(0, local_flags & net::LOAD_BYPASS_PROXY);
  EXPECT_EQ(base::Minutes(3),
            ModelProviderChatTimeout(ModelProvider::kOpenAI,
                                     GURL("http://127.0.0.1:8000/v1")));

  const int remote_flags = ModelProviderRequestLoadFlags(
      ModelProvider::kOpenAI, GURL("https://gateway.example.test/v1"));
  EXPECT_NE(0, remote_flags & net::LOAD_DISABLE_CACHE);
  EXPECT_NE(0, remote_flags & net::LOAD_BYPASS_CACHE);
  EXPECT_NE(0, remote_flags & net::LOAD_DO_NOT_SAVE_COOKIES);
  EXPECT_EQ(0, remote_flags & net::LOAD_BYPASS_PROXY);
  EXPECT_EQ(base::Seconds(45),
            ModelProviderChatTimeout(ModelProvider::kOpenAI,
                                     GURL("https://gateway.example.test/v1")));
}

class ModelProviderClientNetworkTest : public testing::Test {
 protected:
  void SetUp() override {
    TestingBrowserProcess::GetGlobal()->SetSharedURLLoaderFactory(
        test_url_loader_factory_.GetSafeWeakWrapper());
  }

  void TearDown() override {
    TestingBrowserProcess::GetGlobal()->SetSharedURLLoaderFactory(nullptr);
  }

  const network::ResourceRequest& PendingRequest(const GURL& endpoint) {
    test_url_loader_factory_.WaitForRequest(endpoint);
    EXPECT_THAT(*test_url_loader_factory_.pending_requests(), SizeIs(1));
    return test_url_loader_factory_.GetPendingRequest(0)->request;
  }

  base::test::TaskEnvironment task_environment_;
  network::TestURLLoaderFactory test_url_loader_factory_;
};

TEST_F(ModelProviderClientNetworkTest,
       UsesOpenAICompatibleLoopbackV1WithoutApiKey) {
  constexpr std::string_view kBaseUrl = "http://127.0.0.1:8000/v1";
  const GURL models_endpoint("http://127.0.0.1:8000/v1/models");
  ModelProviderClient client;
  base::test::TestFuture<bool, std::string, std::vector<std::string>>
      models_result;
  client.ListModels(ModelProvider::kOpenAI, std::string(kBaseUrl), "",
                    models_result.GetCallback());

  const network::ResourceRequest& models_request =
      PendingRequest(models_endpoint);
  EXPECT_EQ("GET", models_request.method);
  EXPECT_EQ(network::mojom::RedirectMode::kError, models_request.redirect_mode);
  EXPECT_EQ(network::mojom::CredentialsMode::kOmit,
            models_request.credentials_mode);
  EXPECT_NE(0, models_request.load_flags & net::LOAD_BYPASS_PROXY);
  EXPECT_FALSE(models_request.headers.HasHeader(
      net::HttpRequestHeaders::kAuthorization));

  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      models_endpoint.spec(),
      R"({"data":[{"id":"local-chat"},{"id":"local-embedding"}]})"));
  EXPECT_TRUE(models_result.Get<0>());
  EXPECT_THAT(models_result.Get<2>(),
              ElementsAre("local-chat", "local-embedding"));

  const GURL chat_endpoint("http://127.0.0.1:8000/v1/chat/completions");
  base::test::TestFuture<bool, std::string, std::string> chat_result;
  client.Chat(ModelProvider::kOpenAI, std::string(kBaseUrl), "", "local-chat",
              "fixed system", "redacted user", chat_result.GetCallback());

  const network::ResourceRequest& chat_request = PendingRequest(chat_endpoint);
  EXPECT_EQ("POST", chat_request.method);
  EXPECT_FALSE(
      chat_request.headers.HasHeader(net::HttpRequestHeaders::kAuthorization));
  const std::string upload = network::GetUploadData(chat_request);
  const std::optional<base::Value> payload =
      base::JSONReader::Read(upload, base::JSON_PARSE_RFC);
  ASSERT_TRUE(payload && payload->is_dict());
  EXPECT_EQ("local-chat", *payload->GetDict().FindString("model"));
  ASSERT_EQ(2u, payload->GetDict().FindList("messages")->size());

  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      chat_endpoint.spec(),
      R"({"choices":[{"message":{"content":"{\"summary\":\"local\"}"}}]})"));
  EXPECT_TRUE(chat_result.Get<0>());
  EXPECT_EQ(R"({"summary":"local"})", chat_result.Get<2>());
}

TEST_F(ModelProviderClientNetworkTest,
       UsesAnthropicFormatWithThirdPartyHttpsPrefixAndNoKey) {
  constexpr std::string_view kBaseUrl =
      "https://gateway.example.test/tenant/claude/v1/";
  const GURL models_endpoint(
      "https://gateway.example.test/tenant/claude/v1/models");
  ModelProviderClient client;
  base::test::TestFuture<bool, std::string, std::vector<std::string>>
      models_result;
  client.ListModels(ModelProvider::kAnthropic, std::string(kBaseUrl), "",
                    models_result.GetCallback());

  const network::ResourceRequest& models_request =
      PendingRequest(models_endpoint);
  EXPECT_EQ(0, models_request.load_flags & net::LOAD_BYPASS_PROXY);
  EXPECT_FALSE(models_request.headers.HasHeader("x-api-key"));
  EXPECT_EQ("2023-06-01",
            models_request.headers.GetHeader("anthropic-version").value_or(""));
  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      models_endpoint.spec(), R"({"data":[{"id":"claude-compatible"}]})"));
  EXPECT_TRUE(models_result.Get<0>());
  EXPECT_THAT(models_result.Get<2>(), ElementsAre("claude-compatible"));

  const GURL chat_endpoint(
      "https://gateway.example.test/tenant/claude/v1/messages");
  base::test::TestFuture<bool, std::string, std::string> chat_result;
  client.Chat(ModelProvider::kAnthropic, std::string(kBaseUrl), "",
              "claude-compatible", "fixed system", "redacted user",
              chat_result.GetCallback());

  const network::ResourceRequest& chat_request = PendingRequest(chat_endpoint);
  EXPECT_FALSE(chat_request.headers.HasHeader("x-api-key"));
  const std::string upload = network::GetUploadData(chat_request);
  const std::optional<base::Value> payload =
      base::JSONReader::Read(upload, base::JSON_PARSE_RFC);
  ASSERT_TRUE(payload && payload->is_dict());
  EXPECT_EQ("fixed system", *payload->GetDict().FindString("system"));
  EXPECT_EQ(1024, payload->GetDict().FindInt("max_tokens"));

  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      chat_endpoint.spec(),
      R"({"content":[{"type":"text","text":"part one"},{"type":"tool_use","id":"x"},{"type":"text","text":"part two"}]})"));
  EXPECT_TRUE(chat_result.Get<0>());
  EXPECT_EQ("part one\npart two", chat_result.Get<2>());
}

TEST_F(ModelProviderClientNetworkTest,
       UsesGeminiFormatWithNormalizedHttpsPrefixAndNoKey) {
  constexpr std::string_view kBaseUrl =
      "https://gateway.example.test/google/v1beta//";
  const GURL models_endpoint(
      "https://gateway.example.test/google/v1beta/models");
  ModelProviderClient client;
  base::test::TestFuture<bool, std::string, std::vector<std::string>>
      models_result;
  client.ListModels(ModelProvider::kGemini, std::string(kBaseUrl), "",
                    models_result.GetCallback());

  const network::ResourceRequest& models_request =
      PendingRequest(models_endpoint);
  EXPECT_FALSE(models_request.headers.HasHeader("x-goog-api-key"));
  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      models_endpoint.spec(),
      R"({"models":[{"name":"models/gemini-compatible","supportedGenerationMethods":["generateContent"]},{"name":"models/embed-only","supportedGenerationMethods":["embedContent"]}]})"));
  EXPECT_TRUE(models_result.Get<0>());
  EXPECT_THAT(models_result.Get<2>(), ElementsAre("gemini-compatible"));

  const GURL chat_endpoint(
      "https://gateway.example.test/google/v1beta/models/"
      "gemini-compatible:generateContent");
  base::test::TestFuture<bool, std::string, std::string> chat_result;
  client.Chat(ModelProvider::kGemini, std::string(kBaseUrl), "",
              "models/gemini-compatible", "fixed system", "redacted user",
              chat_result.GetCallback());

  const network::ResourceRequest& chat_request = PendingRequest(chat_endpoint);
  EXPECT_FALSE(chat_request.headers.HasHeader("x-goog-api-key"));
  const std::string upload = network::GetUploadData(chat_request);
  const std::optional<base::Value> payload =
      base::JSONReader::Read(upload, base::JSON_PARSE_RFC);
  ASSERT_TRUE(payload && payload->is_dict());
  EXPECT_TRUE(payload->GetDict().FindDict("systemInstruction"));
  EXPECT_TRUE(payload->GetDict().FindList("contents"));

  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      chat_endpoint.spec(),
      R"({"candidates":[{"content":{"parts":[{"text":"gemini result"}]}}]})"));
  EXPECT_TRUE(chat_result.Get<0>());
  EXPECT_EQ("gemini result", chat_result.Get<2>());
}

TEST_F(ModelProviderClientNetworkTest, BoundsAndDeduplicatesModelList) {
  const GURL endpoint("https://api.openai.com/v1/models");
  ModelProviderClient client;
  base::test::TestFuture<bool, std::string, std::vector<std::string>> result;
  client.ListModels(ModelProvider::kOpenAI, "", "", result.GetCallback());
  PendingRequest(endpoint);

  base::ListValue data;
  data.Append(base::DictValue().Set("id", "valid-model"));
  data.Append(base::DictValue().Set("id", "valid-model"));
  data.Append(base::DictValue().Set("id", "bad\x01model"));
  data.Append(base::DictValue().Set("id", std::string(257, 'x')));
  for (int i = 0; i < 205; ++i) {
    data.Append(
        base::DictValue().Set("id", "model-" + base::NumberToString(i)));
  }
  base::DictValue response_dict;
  response_dict.Set("data", std::move(data));
  std::string response;
  ASSERT_TRUE(base::JSONWriter::Write(response_dict, &response));
  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      endpoint.spec(), response));

  EXPECT_TRUE(result.Get<0>());
  EXPECT_THAT(result.Get<2>(), SizeIs(200));
  EXPECT_EQ("valid-model", result.Get<2>().front());
  EXPECT_THAT(result.Get<2>(), Not(testing::Contains("bad\x01model")));
}

TEST_F(ModelProviderClientNetworkTest, SendsConfiguredKeyButNeverLeaksIt) {
  constexpr std::string_view kApiKey = "sk-test-secret";
  constexpr std::string_view kResponseSecret = "provider-private-error-body";
  const GURL endpoint("https://proxy.example.test/openai/v1/models");
  ModelProviderClient client;
  base::test::TestFuture<bool, std::string, std::vector<std::string>> result;
  client.ListModels(ModelProvider::kOpenAI,
                    "https://proxy.example.test/openai/v1",
                    std::string(kApiKey), result.GetCallback());

  const network::ResourceRequest& request = PendingRequest(endpoint);
  EXPECT_EQ("Bearer sk-test-secret",
            request.headers.GetHeader(net::HttpRequestHeaders::kAuthorization)
                .value_or(""));
  EXPECT_EQ(std::string::npos, request.url.spec().find(kApiKey));
  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      endpoint.spec(), kResponseSecret, net::HTTP_UNAUTHORIZED));

  EXPECT_FALSE(result.Get<0>());
  EXPECT_THAT(result.Get<1>(), HasSubstr("HTTP 401"));
  EXPECT_THAT(result.Get<1>(), Not(HasSubstr(kApiKey)));
  EXPECT_THAT(result.Get<1>(), Not(HasSubstr(kResponseSecret)));
  EXPECT_TRUE(result.Get<2>().empty());
}

TEST_F(ModelProviderClientNetworkTest, RejectsUnsafeUrlWithoutRequest) {
  ModelProviderClient client;
  base::test::TestFuture<bool, std::string, std::vector<std::string>> result;
  client.ListModels(ModelProvider::kOpenAI, "http://gateway.example.test/v1",
                    "", result.GetCallback());

  EXPECT_FALSE(result.Get<0>());
  EXPECT_EQ("invalid model provider base URL", result.Get<1>());
  EXPECT_TRUE(result.Get<2>().empty());
  EXPECT_TRUE(test_url_loader_factory_.pending_requests()->empty());
}

TEST_F(ModelProviderClientNetworkTest, RejectsConcurrentRequest) {
  const GURL endpoint("http://127.0.0.1:8000/v1/models");
  ModelProviderClient client;
  base::test::TestFuture<bool, std::string, std::vector<std::string>> first;
  base::test::TestFuture<bool, std::string, std::string> second;
  client.ListModels(ModelProvider::kOpenAI, "http://127.0.0.1:8000/v1", "",
                    first.GetCallback());
  PendingRequest(endpoint);
  client.Chat(ModelProvider::kOpenAI, "http://127.0.0.1:8000/v1", "",
              "local-chat", "system", "user", second.GetCallback());

  EXPECT_FALSE(second.Get<0>());
  EXPECT_EQ("model request already in progress", second.Get<1>());
  EXPECT_TRUE(client.busy());

  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      endpoint.spec(), R"({"data":[]})"));
  EXPECT_TRUE(first.Get<0>());
  EXPECT_FALSE(client.busy());
}

TEST_F(ModelProviderClientNetworkTest, ReportsTimeoutInsteadOfHttpStatus) {
  const GURL endpoint("http://127.0.0.1:8000/v1/chat/completions");
  test_url_loader_factory_.AddResponse(
      endpoint, network::mojom::URLResponseHead::New(), std::string(),
      network::URLLoaderCompletionStatus(net::ERR_TIMED_OUT));

  ModelProviderClient client;
  base::test::TestFuture<bool, std::string, std::string> result;
  client.Chat(ModelProvider::kOpenAI, "http://127.0.0.1:8000/v1", "",
              "local-chat", "system", "user", result.GetCallback());

  EXPECT_FALSE(result.Get<0>());
  EXPECT_EQ("model request timed out", result.Get<1>());
  EXPECT_TRUE(result.Get<2>().empty());
}

TEST_F(ModelProviderClientNetworkTest, CancelsOnlyOwnedChatAndReleasesSlot) {
  const GURL chat_endpoint("http://127.0.0.1:8000/v1/chat/completions");
  ModelProviderClient client;
  base::test::TestFuture<bool, std::string, std::string> abandoned;
  const std::optional<ModelProviderClient::ChatRequestId> request_id =
      client.Chat(ModelProvider::kOpenAI, "http://127.0.0.1:8000/v1", "",
                  "local-chat", "system", "user", abandoned.GetCallback());
  ASSERT_TRUE(request_id);
  PendingRequest(chat_endpoint);

  EXPECT_FALSE(client.CancelChat("wrong-" + *request_id));
  EXPECT_TRUE(client.busy());
  EXPECT_TRUE(client.CancelChat(*request_id));
  EXPECT_FALSE(client.busy());
  EXPECT_FALSE(client.CancelChat(*request_id));
  EXPECT_EQ(0, test_url_loader_factory_.NumPending());

  const GURL models_endpoint("http://127.0.0.1:8000/v1/models");
  base::test::TestFuture<bool, std::string, std::vector<std::string>> models;
  client.ListModels(ModelProvider::kOpenAI, "http://127.0.0.1:8000/v1", "",
                    models.GetCallback());
  test_url_loader_factory_.WaitForRequest(models_endpoint);
  EXPECT_EQ(1, test_url_loader_factory_.NumPending());
  EXPECT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      models_endpoint.spec(), R"({"data":[]})"));
  EXPECT_TRUE(models.Get<0>());
}

}  // namespace
}  // namespace aegis
