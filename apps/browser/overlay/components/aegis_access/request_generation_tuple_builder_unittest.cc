// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/request_generation_tuple_builder_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestRequestGenerationTupleBuilderObserver
    : public RequestGenerationTupleBuilderTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(RequestGenerationTupleBuilderTest, SharedUnitContract) {
  GtestRequestGenerationTupleBuilderObserver observer;
  RunRequestGenerationTupleBuilderUnitTests(observer);
}

TEST(RequestGenerationTupleBuilderRegressionTest, SharedRegressionContract) {
  GtestRequestGenerationTupleBuilderObserver observer;
  RunRequestGenerationTupleBuilderRegressionTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
