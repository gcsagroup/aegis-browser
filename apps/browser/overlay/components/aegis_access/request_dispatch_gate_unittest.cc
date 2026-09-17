// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/request_dispatch_gate_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestDispatchGateObserver : public RequestOwnershipRegistryTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(RequestDispatchGateTest, SharedUnitContract) {
  GtestDispatchGateObserver observer;
  RunRequestDispatchGateUnitTests(observer);
}

TEST(RequestDispatchGateRegressionTest, SharedRegressionContract) {
  GtestDispatchGateObserver observer;
  RunRequestDispatchGateRegressionTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
