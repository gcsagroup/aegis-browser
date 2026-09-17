// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/request_ownership_registry_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestOwnershipObserver : public RequestOwnershipRegistryTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(RequestOwnershipRegistryTest, SharedUnitContract) {
  GtestOwnershipObserver observer;
  RunRequestOwnershipRegistryUnitTests(observer);
}

TEST(RequestOwnershipRegistryRegressionTest, SharedRegressionContract) {
  GtestOwnershipObserver observer;
  RunRequestOwnershipRegistryRegressionTests(observer);
}

TEST(TargetedRequestCancellationTest, SharedUnitContract) {
  GtestOwnershipObserver observer;
  RunTargetedRequestCancellationUnitTests(observer);
}

TEST(TargetedRequestCancellationRegressionTest, SharedRegressionContract) {
  GtestOwnershipObserver observer;
  RunTargetedRequestCancellationRegressionTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
