// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/access_proxy_selection_generation_state_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestProxySelectionGenerationStateObserver
    : public ProxySelectionGenerationStateTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(ProxySelectionGenerationStateTest, SharedUnitContract) {
  GtestProxySelectionGenerationStateObserver observer;
  RunProxySelectionGenerationStateUnitTests(observer);
}

TEST(ProxySelectionGenerationStateRegressionTest, SharedRegressionContract) {
  GtestProxySelectionGenerationStateObserver observer;
  RunProxySelectionGenerationStateRegressionTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
