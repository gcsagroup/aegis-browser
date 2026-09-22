// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/typesafe_goal_router_client.h"

#include "chrome/browser/aegis/agent/typesafe_goal_response_parser.h"

#include <array>
#include <memory>
#include <optional>
#include <string>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
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
    },
    "reasoning_need":{
      "type":"choice","choice":"strong","confidence":0.91,
      "probabilities":{"unknown":0.03,"basic":0.06,"strong":0.91}
    },
    "context_need":{
      "type":"choice","choice":"long","confidence":0.88,
      "probabilities":{"unknown":0.04,"short":0.08,"long":0.88}
    },
    "output_need":{
      "type":"choice","choice":"comprehensive","confidence":0.90,
      "probabilities":{"unknown":0.02,"short_extraction":0.03,"comprehensive":0.90,"multi_step":0.05}
    }
  },
  "usage":{"input_tokens":42,"output_tokens":18}
})";

constexpr char kValidUnknownNeedsResponse[] = R"({
  "model":"jev-1.13.0",
  "answers":{
    "workflow":{
      "type":"choice","choice":"research","confidence":0.92,
      "probabilities":{"research":0.92,"browser_steward":0.03,"safe_download":0.03,"shopping":0.02}
    },
    "entry_kind":{
      "type":"choice","choice":"web_search","confidence":0.90,
      "probabilities":{"browser_only":0.05,"web_search":0.95}
    },
    "reasoning_need":{
      "type":"choice","choice":"unknown","confidence":0.90,
      "probabilities":{"unknown":0.90,"basic":0.05,"strong":0.05}
    },
    "context_need":{
      "type":"choice","choice":"unknown","confidence":0.90,
      "probabilities":{"unknown":0.90,"short":0.05,"long":0.05}
    },
    "output_need":{
      "type":"choice","choice":"unknown","confidence":0.85,
      "probabilities":{"unknown":0.85,"short_extraction":0.05,"comprehensive":0.05,"multi_step":0.05}
    }
  }
})";

std::optional<std::string> WriteJson(const base::DictValue& value) {
  std::string json;
  if (!base::JSONWriter::Write(value, &json)) {
    return std::nullopt;
  }
  return json;
}

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
  base::test::TestFuture<bool, std::string,
                         std::optional<TypeSafeGoalAnalysis>> done;
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
  EXPECT_EQ(questions->size(), 5u);
  for (std::string_view name : {"workflow", "entry_kind", "reasoning_need",
                                "context_need", "output_need"}) {
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
  EXPECT_EQ(done.Get<2>()->route.workflow, AgentWorkflowKind::kResearch);
  EXPECT_EQ(done.Get<2>()->route.entry_kind, AgentGoalEntryKind::kWebSearch);
  EXPECT_EQ(done.Get<2>()->route.target, kGoal);
  EXPECT_EQ(done.Get<2>()->requirements.reasoning,
            AgentReasoningNeed::kStrong);
  EXPECT_EQ(done.Get<2>()->requirements.context, AgentContextNeed::kLong);
  EXPECT_EQ(done.Get<2>()->requirements.output,
            AgentOutputNeed::kComprehensive);
  EXPECT_EQ(done.Get<2>()->model, "jev-1.13.0");
  EXPECT_EQ(done.Get<2>()->input_tokens, 42);
  EXPECT_EQ(done.Get<2>()->output_tokens, 18);
  EXPECT_GE(done.Get<2>()->latency, base::TimeDelta());
}

TEST_F(TypeSafeGoalRouterClientTest,
       RejectsLowConfidenceAndContradictoryDistributions) {
  std::string error;
  std::optional<base::DictValue> low_confidence =
      base::JSONReader::ReadDict(kValidResponse, base::JSON_PARSE_RFC);
  ASSERT_TRUE(low_confidence);
  base::DictValue* low_answers = low_confidence->FindDict("answers");
  ASSERT_TRUE(low_answers);
  base::DictValue* low_workflow = low_answers->FindDict("workflow");
  ASSERT_TRUE(low_workflow);
  low_workflow->Set("confidence", 0.79);
  std::optional<std::string> low_body = WriteJson(*low_confidence);
  ASSERT_TRUE(low_body);
  EXPECT_FALSE(
      TypeSafeGoalResponseParser::Parse(*low_body, kGoal, &error));
  EXPECT_EQ(error,
            "TypeSafe choice confidence is below the routing threshold");

  std::optional<base::DictValue> contradictory =
      base::JSONReader::ReadDict(kValidResponse, base::JSON_PARSE_RFC);
  ASSERT_TRUE(contradictory);
  base::DictValue* contradictory_answers = contradictory->FindDict("answers");
  ASSERT_TRUE(contradictory_answers);
  base::DictValue* contradictory_workflow =
      contradictory_answers->FindDict("workflow");
  ASSERT_TRUE(contradictory_workflow);
  base::DictValue* probabilities =
      contradictory_workflow->FindDict("probabilities");
  ASSERT_TRUE(probabilities);
  contradictory_workflow->Set("confidence", 0.95);
  probabilities->Set("research", 0.02);
  probabilities->Set("shopping", 0.92);
  std::optional<std::string> contradictory_body = WriteJson(*contradictory);
  ASSERT_TRUE(contradictory_body);
  EXPECT_FALSE(TypeSafeGoalResponseParser::Parse(*contradictory_body, kGoal,
                                                 &error));
  EXPECT_NE(error.find("contradicts"), std::string::npos);
}

TEST_F(TypeSafeGoalRouterClientTest,
       RequiresEveryModelNeedAnswerToBeAChoiceDistribution) {
  constexpr std::array<std::string_view, 3> kRequiredAnswers = {
      "reasoning_need", "context_need", "output_need"};
  enum class InvalidShape { kMissing, kNull, kString, kList };
  constexpr std::array<InvalidShape, 4> kInvalidShapes = {
      InvalidShape::kMissing, InvalidShape::kNull, InvalidShape::kString,
      InvalidShape::kList};

  for (std::string_view answer_name : kRequiredAnswers) {
    for (InvalidShape shape : kInvalidShapes) {
      SCOPED_TRACE(testing::Message()
                   << "answer=" << answer_name
                   << " shape=" << static_cast<int>(shape));
      std::optional<base::DictValue> response =
          base::JSONReader::ReadDict(kValidResponse, base::JSON_PARSE_RFC);
      ASSERT_TRUE(response);
      base::DictValue* answers = response->FindDict("answers");
      ASSERT_TRUE(answers);
      switch (shape) {
        case InvalidShape::kMissing:
          answers->Remove(answer_name);
          break;
        case InvalidShape::kNull:
          answers->Set(answer_name, base::Value());
          break;
        case InvalidShape::kString:
          answers->Set(answer_name, "not-a-choice");
          break;
        case InvalidShape::kList:
          answers->Set(answer_name, base::ListValue());
          break;
      }
      std::optional<std::string> body = WriteJson(*response);
      ASSERT_TRUE(body);
      std::string error;
      EXPECT_FALSE(TypeSafeGoalResponseParser::Parse(*body, kGoal, &error));
      EXPECT_EQ(error, "TypeSafe returned an invalid answer type");
    }
  }
}

TEST_F(TypeSafeGoalRouterClientTest,
       AcceptsCompleteHighConfidenceExplicitUnknownNeeds) {
  std::string error;
  std::optional<TypeSafeGoalAnalysis> analysis =
      TypeSafeGoalResponseParser::Parse(kValidUnknownNeedsResponse, kGoal,
                                        &error);
  ASSERT_TRUE(analysis) << error;
  EXPECT_EQ(analysis->reasoning_need.choice, "unknown");
  EXPECT_EQ(analysis->context_need.choice, "unknown");
  EXPECT_EQ(analysis->output_need.choice, "unknown");
  EXPECT_GE(analysis->reasoning_need.confidence,
            kTypeSafeGoalRouteMinimumConfidence);
  EXPECT_GE(analysis->context_need.confidence,
            kTypeSafeGoalRouteMinimumConfidence);
  EXPECT_GE(analysis->output_need.confidence,
            kTypeSafeGoalRouteMinimumConfidence);
  EXPECT_EQ(analysis->requirements.reasoning, AgentReasoningNeed::kUnknown);
  EXPECT_EQ(analysis->requirements.context, AgentContextNeed::kUnknown);
  EXPECT_EQ(analysis->requirements.output, AgentOutputNeed::kUnknown);
}

TEST_F(TypeSafeGoalRouterClientTest,
       RejectsLowConfidenceForEveryModelNeedAnswer) {
  for (std::string_view answer_name :
       {"reasoning_need", "context_need", "output_need"}) {
    SCOPED_TRACE(testing::Message() << "answer=" << answer_name);
    std::optional<base::DictValue> response =
        base::JSONReader::ReadDict(kValidResponse, base::JSON_PARSE_RFC);
    ASSERT_TRUE(response);
    base::DictValue* answers = response->FindDict("answers");
    ASSERT_TRUE(answers);
    base::DictValue* answer = answers->FindDict(answer_name);
    ASSERT_TRUE(answer);
    answer->Set("confidence", 0.79);
    std::optional<std::string> body = WriteJson(*response);
    ASSERT_TRUE(body);
    std::string error;
    EXPECT_FALSE(TypeSafeGoalResponseParser::Parse(*body, kGoal, &error));
    EXPECT_EQ(error,
              "TypeSafe choice confidence is below the routing threshold");
  }
}

TEST_F(TypeSafeGoalRouterClientTest,
       RejectsIncompatibleWorkflowAndOversizedDerivedSearch) {
  std::string error;
  std::optional<base::DictValue> incompatible =
      base::JSONReader::ReadDict(kValidResponse, base::JSON_PARSE_RFC);
  ASSERT_TRUE(incompatible);
  base::DictValue* answers = incompatible->FindDict("answers");
  ASSERT_TRUE(answers);
  base::DictValue* workflow = answers->FindDict("workflow");
  ASSERT_TRUE(workflow);
  base::DictValue* probabilities = workflow->FindDict("probabilities");
  ASSERT_TRUE(probabilities);
  workflow->Set("choice", "browser_steward");
  workflow->Set("confidence", 0.95);
  probabilities->Set("research", 0.02);
  probabilities->Set("browser_steward", 0.92);
  std::optional<std::string> incompatible_body = WriteJson(*incompatible);
  ASSERT_TRUE(incompatible_body);
  EXPECT_FALSE(TypeSafeGoalResponseParser::Parse(*incompatible_body, kGoal,
                                                 &error));
  EXPECT_EQ(error, "goal route contains an invalid search query");

  const std::string oversized_goal(1025, 'a');
  EXPECT_FALSE(
      TypeSafeGoalResponseParser::Parse(kValidResponse, oversized_goal,
                                        &error));
  EXPECT_EQ(error, "goal route contains an invalid search query");
}

TEST_F(TypeSafeGoalRouterClientTest, DoesNotRetryHttpFailure) {
  base::test::TestFuture<bool, std::string,
                         std::optional<TypeSafeGoalAnalysis>> done;
  ASSERT_TRUE(client_.Start(kGoal, kApiKey, done.GetCallback()));
  const GURL endpoint(kTypeSafeSystemOneEndpoint);
  factory_.WaitForRequest(endpoint);
  ASSERT_TRUE(factory_.SimulateResponseForPendingRequest(
      endpoint.spec(), "rate limited", net::HTTP_TOO_MANY_REQUESTS));
  EXPECT_FALSE(done.Get<0>());
  EXPECT_EQ(factory_.NumPending(), 0);
}

TEST_F(TypeSafeGoalRouterClientTest, CancelSettlesCallbackAndStopsRequest) {
  base::test::TestFuture<bool, std::string,
                         std::optional<TypeSafeGoalAnalysis>> done;
  const std::optional<std::string> request_id =
      client_.Start(kGoal, kApiKey, done.GetCallback());
  ASSERT_TRUE(request_id);
  factory_.WaitForRequest(GURL(kTypeSafeSystemOneEndpoint));
  EXPECT_TRUE(client_.Cancel(*request_id));
  EXPECT_FALSE(done.Get<0>());
  EXPECT_NE(done.Get<1>().find("cancelled"), std::string::npos);
  EXPECT_FALSE(client_.busy());
}

TEST_F(TypeSafeGoalRouterClientTest,
       CancelledRequestDoesNotAffectReplacementRequest) {
  base::test::TestFuture<bool, std::string,
                         std::optional<TypeSafeGoalAnalysis>> first;
  const std::optional<std::string> first_id =
      client_.Start(kGoal, kApiKey, first.GetCallback());
  ASSERT_TRUE(first_id);
  const GURL endpoint(kTypeSafeSystemOneEndpoint);
  factory_.WaitForRequest(endpoint);
  ASSERT_TRUE(client_.Cancel(*first_id));

  base::test::TestFuture<bool, std::string,
                         std::optional<TypeSafeGoalAnalysis>>
      replacement;
  const std::optional<std::string> replacement_id =
      client_.Start(kGoal, kApiKey, replacement.GetCallback());
  ASSERT_TRUE(replacement_id);
  EXPECT_NE(*first_id, *replacement_id);
  factory_.WaitForRequest(endpoint);
  ASSERT_TRUE(factory_.SimulateResponseForPendingRequest(endpoint.spec(),
                                                          kValidResponse));
  EXPECT_TRUE(replacement.Get<0>()) << replacement.Get<1>();
  EXPECT_TRUE(replacement.Get<2>().has_value());
}

TEST_F(TypeSafeGoalRouterClientTest, TimesOutWithoutRetry) {
  base::test::TestFuture<bool, std::string,
                         std::optional<TypeSafeGoalAnalysis>> done;
  ASSERT_TRUE(client_.Start(kGoal, kApiKey, done.GetCallback()));
  factory_.WaitForRequest(GURL(kTypeSafeSystemOneEndpoint));
  task_environment_.FastForwardBy(base::Seconds(2));
  EXPECT_FALSE(done.Get<0>());
  EXPECT_EQ(factory_.NumPending(), 0);
}

}  // namespace
}  // namespace aegis::agent
