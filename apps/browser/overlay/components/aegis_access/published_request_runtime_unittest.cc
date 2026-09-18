// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/published_request_runtime_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestPublishedRequestRuntimeObserver
    : public RequestOwnershipRegistryTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(PublishedRequestRuntimeTest, SharedUnitContract) {
  GtestPublishedRequestRuntimeObserver observer;
  RunPublishedRequestRuntimeUnitTests(observer);
}

TEST(PublishedRequestRuntimeRegressionTest, SharedRegressionContract) {
  GtestPublishedRequestRuntimeObserver observer;
  RunPublishedRequestRuntimeRegressionTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
