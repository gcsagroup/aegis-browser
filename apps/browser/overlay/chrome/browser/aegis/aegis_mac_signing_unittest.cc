// Copyright 2026 The GCSA Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <Kernel/kern/cs_blobs.h>
#include <Security/Security.h>

#include <cstdint>

#include "base/apple/scoped_cftyperef.h"
#include "base/containers/span.h"
#include "base/mac/code_signature_spi.h"
#include "base/mac/process_requirement.h"
#include "base/strings/sys_string_conversions.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace {

class GcsaSigningProvider
    : public base::mac::ProcessRequirement::CSOpsSystemCallProvider {
 public:
  int csops(pid_t, unsigned int op, void* data, size_t size) override {
    if (op == CS_OPS_VALIDATION_CATEGORY) {
      *static_cast<unsigned int*>(data) = CS_VALIDATION_CATEGORY_ENTERPRISE;
      return 0;
    }
    struct TeamResult {
      uint32_t type;
      uint32_t length;
      char identifier[CS_MAX_TEAMID_LEN + 1];
    };
    if (op == CS_OPS_TEAMID && size >= sizeof(TeamResult)) {
      auto* result = static_cast<TeamResult*>(data);
      *result = {};
      base::span(result->identifier).copy_prefix_from(team);
      return 0;
    }
    errno = EINVAL;
    return -1;
  }
  std::string team = "R3JK7R29AC";
};

class GcsaMacSigningTest : public testing::Test {
 protected:
  void SetUp() override {
    base::mac::ProcessRequirement::SetCSOpsSystemCallProviderForTesting(
        &provider);
  }
  void TearDown() override {
    base::mac::ProcessRequirement::SetCSOpsSystemCallProviderForTesting(
        nullptr);
  }
  GcsaSigningProvider provider;
};

TEST_F(GcsaMacSigningTest, EnterpriseKeepsExactCertificateAndAppleAnchor) {
  auto requirement =
      base::mac::ProcessRequirement::Builder().SignedWithSameIdentity().Build();
  ASSERT_TRUE(requirement);
  auto ref = requirement->AsSecRequirement();
  ASSERT_TRUE(ref);
  base::apple::ScopedCFTypeRef<CFStringRef> text;
  ASSERT_EQ(errSecSuccess,
            SecRequirementCopyString(ref.get(), kSecCSDefaultFlags,
                                     text.InitializeInto()));
  std::string value = base::SysCFStringRefToUTF8(text.get());
  EXPECT_NE(value.find("anchor apple generic"), std::string::npos);
  EXPECT_NE(value.find("7c33b517942161311a087ce893d2f1ce9b204b44"),
            std::string::npos);
  EXPECT_NE(value.find("R3JK7R29AC"), std::string::npos);
}

TEST_F(GcsaMacSigningTest, OtherEnterpriseTeamCannotMatchGcsaIdentity) {
  provider.team = "OTHERTEAM1";
  auto requirement =
      base::mac::ProcessRequirement::Builder().SignedWithSameIdentity().Build();
  ASSERT_TRUE(requirement);
  auto ref = requirement->AsSecRequirement();
  ASSERT_TRUE(ref);
  base::apple::ScopedCFTypeRef<CFStringRef> text;
  ASSERT_EQ(errSecSuccess,
            SecRequirementCopyString(ref.get(), kSecCSDefaultFlags,
                                     text.InitializeInto()));
  std::string value = base::SysCFStringRefToUTF8(text.get());
  // 两个不同团队同时以 and 限制，其他企业证书不能匹配。
  EXPECT_NE(value.find("OTHERTEAM1 and"), std::string::npos);
  EXPECT_NE(value.find("R3JK7R29AC"), std::string::npos);
}

}  // namespace
