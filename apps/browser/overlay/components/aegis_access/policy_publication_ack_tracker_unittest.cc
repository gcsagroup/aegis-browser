// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/policy_publication_ack_tracker_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestPolicyPublicationAckTrackerObserver
    : public PolicyPublicationAckTrackerTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(PolicyPublicationAckTrackerTest, SharedUnitContract) {
  GtestPolicyPublicationAckTrackerObserver observer;
  RunPolicyPublicationAckTrackerUnitTests(observer);
}

TEST(PolicyPublicationAckTrackerRegressionTest, SharedRegressionContract) {
  GtestPolicyPublicationAckTrackerObserver observer;
  RunPolicyPublicationAckTrackerRegressionTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
