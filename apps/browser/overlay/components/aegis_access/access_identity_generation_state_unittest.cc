// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/access_identity_generation_state_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestIdentityGenerationStateObserver
    : public IdentityGenerationStateTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(IdentityGenerationStateTest, SharedUnitContract) {
  GtestIdentityGenerationStateObserver observer;
  RunIdentityGenerationStateUnitTests(observer);
}

TEST(IdentityGenerationStateRegressionTest, SharedRegressionContract) {
  GtestIdentityGenerationStateObserver observer;
  RunIdentityGenerationStateRegressionTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
