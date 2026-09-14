// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/access_route_planner_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestObserver : public ContractTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(AccessRoutePlannerTest, SharedRoutePlannerContract) {
  GtestObserver observer;
  RunRoutePlannerContractTests(observer);
}

TEST(SiteProxyRuleGroupTest, CompleteAtomicGroupContract) {
  GtestObserver observer;
  RunSiteProxyRuleGroupContractTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
