// Copyright 2026 GCSA
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "build/chromeos_buildflags.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_testing_helper.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {
namespace {

class AegisServiceFactoryProfileSupportTest : public testing::Test,
                                              public ProfileTestingHelper {
 public:
  void SetUp() override {
    testing::Test::SetUp();
    ProfileTestingHelper::SetUp();
  }
};

TEST_F(AegisServiceFactoryProfileSupportTest,
       SupportsOnlyUserRegularAndPrimaryIncognitoProfiles) {
  EXPECT_FALSE(IsAegisProfileSupported(nullptr));
  EXPECT_TRUE(IsAegisProfileSupported(regular_profile()));
  EXPECT_TRUE(IsAegisProfileSupported(incognito_profile()));
  EXPECT_FALSE(IsAegisProfileSupported(guest_profile()));
  EXPECT_FALSE(IsAegisProfileSupported(guest_profile_otr()));

#if !BUILDFLAG(IS_CHROMEOS) && !BUILDFLAG(IS_ANDROID)
  EXPECT_FALSE(IsAegisProfileSupported(system_profile()));
  EXPECT_FALSE(IsAegisProfileSupported(system_profile_otr()));
#endif

#if BUILDFLAG(IS_CHROMEOS)
  EXPECT_FALSE(IsAegisProfileSupported(signin_profile()));
  EXPECT_FALSE(IsAegisProfileSupported(signin_profile_otr()));
  EXPECT_FALSE(IsAegisProfileSupported(lockscreen_profile()));
  EXPECT_FALSE(IsAegisProfileSupported(lockscreen_profile_otr()));
#endif

  Profile* auxiliary_off_the_record = regular_profile()->GetOffTheRecordProfile(
      Profile::OTRProfileID::CreateUniqueForTesting(),
      /*create_if_needed=*/true);
  ASSERT_TRUE(auxiliary_off_the_record);
  EXPECT_FALSE(IsAegisProfileSupported(auxiliary_off_the_record));
}

}  // namespace
}  // namespace aegis
