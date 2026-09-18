// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/browser_request_metadata_seed_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestMetadataSeedObserver : public BrowserRequestMetadataSeedTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(BrowserRequestMetadataSeedTest, SharedUnitContract) {
  GtestMetadataSeedObserver observer;
  RunBrowserRequestMetadataSeedUnitTests(observer);
}

TEST(BrowserRequestMetadataSeedRegressionTest, SharedRegressionContract) {
  GtestMetadataSeedObserver observer;
  RunBrowserRequestMetadataSeedRegressionTests(observer);
}

}  // namespace
}  // namespace aegis_access::test
