// Copyright 2026 GCSA

#include <iostream>
#include <string>

#include "components/aegis_access/access_route_planner_contract_test.h"
#include "components/aegis_access/request_dispatch_gate_contract_test.h"
#include "components/aegis_access/request_ownership_registry_contract_test.h"

namespace {

class NativeObserver : public aegis_access::test::ContractTestObserver,
                       public aegis_access::test::RequestOwnershipRegistryTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    ++checks_;
    if (!condition) {
      ++failures_;
      std::cerr << "FAIL: " << label << '\n';
    }
  }

  int checks() const { return checks_; }
  int failures() const { return failures_; }

 private:
  int checks_ = 0;
  int failures_ = 0;
};

}  // namespace

int main() {
  NativeObserver observer;
  aegis_access::test::RunRoutePlannerContractTests(observer);
  aegis_access::test::RunSiteProxyRuleGroupContractTests(observer);
  aegis_access::test::RunRequestOwnershipRegistryUnitTests(observer);
  aegis_access::test::RunRequestOwnershipRegistryRegressionTests(observer);
  aegis_access::test::RunTargetedRequestCancellationUnitTests(observer);
  aegis_access::test::RunTargetedRequestCancellationRegressionTests(observer);
  aegis_access::test::RunRequestDispatchBarrierUnitTests(observer);
  aegis_access::test::RunRequestDispatchBarrierRegressionTests(observer);
  aegis_access::test::RunRequestDispatchGateUnitTests(observer);
  aegis_access::test::RunRequestDispatchGateRegressionTests(observer);
  if (observer.failures() != 0) {
    std::cerr << "FAIL: aegis_access native unit (" << observer.failures()
              << " failures, " << observer.checks() << " checks)\n";
    return 1;
  }
  std::cout << "PASS: aegis_access native unit (" << observer.checks()
            << " checks)\n";
  return 0;
}
