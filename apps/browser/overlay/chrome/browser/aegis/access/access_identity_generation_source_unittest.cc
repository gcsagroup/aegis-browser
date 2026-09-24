// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_identity_generation_source.h"

#include <memory>

#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class AccessIdentityGenerationSourceTest : public testing::Test {
 protected:
  content::BrowserTaskEnvironment task_environment_;
};

aegis_access::AccessIdentityBinding GuestIdentity() {
  return {aegis_access::AccessIdentityKind::kInstallationGuest,
          "visitor-principal", "visitor-entitlement", "prod", "access"};
}

aegis_access::AccessIdentityBinding AccountIdentity() {
  return {aegis_access::AccessIdentityKind::kAuthenticated,
          "account-principal", "account-entitlement", "prod", "access"};
}

TEST_F(AccessIdentityGenerationSourceTest,
     StartsUnpublishedUntilCommittedIdentity) {
  auto profile = TestingProfile::Builder().Build();
  auto* source = AccessIdentityGenerationSource::GetOrCreate(profile.get());
  ASSERT_TRUE(source);
  EXPECT_EQ(source->identity_generation(), 0u);
  EXPECT_FALSE(source->binding().has_value());

  const auto committed = source->CommitIdentity(GuestIdentity());
  EXPECT_EQ(committed.status,
            aegis_access::IdentityGenerationCommitStatus::kCommitted);
  EXPECT_EQ(committed.generation, 1u);
  EXPECT_EQ(source->identity_generation(), 1u);
}

TEST_F(AccessIdentityGenerationSourceTest,
     CommittedIdentityTransitionsAdvanceGeneration) {
  auto profile = TestingProfile::Builder().Build();
  auto* source = AccessIdentityGenerationSource::GetOrCreate(profile.get());
  ASSERT_TRUE(source);

  ASSERT_EQ(source->CommitIdentity(GuestIdentity()).generation, 1u);
  EXPECT_EQ(source->CommitIdentity(GuestIdentity()).status,
            aegis_access::IdentityGenerationCommitStatus::kUnchanged);
  EXPECT_EQ(source->CommitIdentity(AccountIdentity()).generation, 2u);

  const aegis_access::AccessIdentityBinding signed_out{
      aegis_access::AccessIdentityKind::kSignedOut, "", "", "prod", "access"};
  EXPECT_EQ(source->CommitIdentity(signed_out).generation, 3u);
  EXPECT_EQ(source->CommitIdentity(GuestIdentity()).generation, 4u);
}

TEST_F(AccessIdentityGenerationSourceTest, ProfileOwnedSourcesAreIsolated) {
  auto first_profile = TestingProfile::Builder().Build();
  auto second_profile = TestingProfile::Builder().Build();
  auto* first =
      AccessIdentityGenerationSource::GetOrCreate(first_profile.get());
  auto* second =
      AccessIdentityGenerationSource::GetOrCreate(second_profile.get());
  ASSERT_TRUE(first);
  ASSERT_TRUE(second);

  ASSERT_EQ(first->CommitIdentity(GuestIdentity()).generation, 1u);
  EXPECT_EQ(first->identity_generation(), 1u);
  EXPECT_EQ(second->identity_generation(), 0u);
  EXPECT_FALSE(second->binding().has_value());
}

TEST_F(AccessIdentityGenerationSourceTest, InvalidIdentityNeverPublishes) {
  auto profile = TestingProfile::Builder().Build();
  auto* source = AccessIdentityGenerationSource::GetOrCreate(profile.get());
  ASSERT_TRUE(source);

  aegis_access::AccessIdentityBinding invalid = GuestIdentity();
  invalid.entitlement_account_id.clear();
  EXPECT_EQ(source->CommitIdentity(invalid).status,
            aegis_access::IdentityGenerationCommitStatus::kInvalidIdentity);
  EXPECT_EQ(source->identity_generation(), 0u);
  EXPECT_FALSE(source->binding().has_value());
}

}  // namespace
}  // namespace aegis::access
