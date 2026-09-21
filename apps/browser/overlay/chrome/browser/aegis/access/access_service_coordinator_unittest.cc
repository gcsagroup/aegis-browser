// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_service_coordinator.h"

#include <memory>

#include "build/chromeos_buildflags.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_testing_helper.h"
#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class AccessServiceCoordinatorTest : public testing::Test {
 protected:
  content::BrowserTaskEnvironment task_environment_;
};

TEST_F(AccessServiceCoordinatorTest, RejectsNullProfile) {
  EXPECT_EQ(AccessServiceCoordinator::Get(nullptr), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(nullptr), nullptr);
}

TEST_F(AccessServiceCoordinatorTest, ReusesProfileOwnedCoordinator) {
  auto profile = TestingProfile::Builder().Build();
  EXPECT_EQ(AccessServiceCoordinator::Get(profile.get()), nullptr);

  auto* first = AccessServiceCoordinator::GetOrCreate(profile.get());
  auto* second = AccessServiceCoordinator::GetOrCreate(profile.get());

  ASSERT_TRUE(first);
  EXPECT_EQ(first, second);
  EXPECT_EQ(AccessServiceCoordinator::Get(profile.get()), first);
  EXPECT_EQ(first->state_generation(), 0u);
}

TEST_F(AccessServiceCoordinatorTest, ProfilesNeverShareCoordinatorState) {
  auto first_profile = TestingProfile::Builder().Build();
  auto second_profile = TestingProfile::Builder().Build();

  auto* first = AccessServiceCoordinator::GetOrCreate(first_profile.get());
  auto* second = AccessServiceCoordinator::GetOrCreate(second_profile.get());

  ASSERT_TRUE(first);
  ASSERT_TRUE(second);
  EXPECT_NE(first, second);
  EXPECT_EQ(first->state_generation(), 0u);
  EXPECT_EQ(second->state_generation(), 0u);
}

class AccessServiceCoordinatorProfileSupportTest
    : public testing::Test,
      public ProfileTestingHelper {
 public:
  void SetUp() override {
    testing::Test::SetUp();
    ProfileTestingHelper::SetUp();
  }
};

TEST_F(AccessServiceCoordinatorProfileSupportTest,
       FollowsAegisProfileSupportContract) {
  auto* regular = AccessServiceCoordinator::GetOrCreate(regular_profile());
  auto* incognito = AccessServiceCoordinator::GetOrCreate(incognito_profile());

  ASSERT_TRUE(regular);
  ASSERT_TRUE(incognito);
  EXPECT_NE(regular, incognito);
  EXPECT_EQ(AccessServiceCoordinator::Get(regular_profile()), regular);
  EXPECT_EQ(AccessServiceCoordinator::Get(incognito_profile()), incognito);

  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(guest_profile()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(guest_profile_otr()), nullptr);

#if !BUILDFLAG(IS_CHROMEOS) && !BUILDFLAG(IS_ANDROID)
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(system_profile()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(system_profile_otr()), nullptr);
#endif

#if BUILDFLAG(IS_CHROMEOS)
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(signin_profile()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(signin_profile_otr()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(lockscreen_profile()), nullptr);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(lockscreen_profile_otr()),
            nullptr);
#endif

  Profile* auxiliary_off_the_record = regular_profile()->GetOffTheRecordProfile(
      Profile::OTRProfileID::CreateUniqueForTesting(),
      /*create_if_needed=*/true);
  ASSERT_TRUE(auxiliary_off_the_record);
  EXPECT_EQ(AccessServiceCoordinator::GetOrCreate(auxiliary_off_the_record),
            nullptr);
}

}  // namespace
}  // namespace aegis::access
