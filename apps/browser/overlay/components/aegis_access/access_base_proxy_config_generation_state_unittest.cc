// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/access_base_proxy_config_generation_state_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestBaseProxyConfigGenerationStateObserver
    : public BaseProxyConfigGenerationStateTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(BaseProxyConfigGenerationStateTest, SharedUnitContract) {
  GtestBaseProxyConfigGenerationStateObserver observer;
  RunBaseProxyConfigGenerationStateUnitTests(observer);
}

TEST(BaseProxyConfigGenerationStateRegressionTest, SharedRegressionContract) {
  GtestBaseProxyConfigGenerationStateObserver observer;
  RunBaseProxyConfigGenerationStateRegressionTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
