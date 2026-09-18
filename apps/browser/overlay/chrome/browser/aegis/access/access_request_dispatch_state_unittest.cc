// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_request_dispatch_state.h"

#include <memory>

#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class AccessRequestDispatchStateTest : public testing::Test {
 protected:
  content::BrowserTaskEnvironment task_environment_;
};

TEST_F(AccessRequestDispatchStateTest, RejectsNullProfile) {
  EXPECT_EQ(AccessRequestDispatchState::Get(nullptr), nullptr);
  EXPECT_EQ(AccessRequestDispatchState::GetOrCreate(nullptr), nullptr);
}

TEST_F(AccessRequestDispatchStateTest, ProfileOwnsOneStableState) {
  auto profile = TestingProfile::Builder().Build();
  auto* first = AccessRequestDispatchState::GetOrCreate(profile.get());
  ASSERT_NE(first, nullptr);
  EXPECT_EQ(first, AccessRequestDispatchState::Get(profile.get()));
  EXPECT_EQ(first, AccessRequestDispatchState::GetOrCreate(profile.get()));
}

TEST_F(AccessRequestDispatchStateTest, ProfilesAreIsolated) {
  auto first_profile = TestingProfile::Builder().Build();
  auto second_profile = TestingProfile::Builder().Build();

  auto* first = AccessRequestDispatchState::GetOrCreate(first_profile.get());
  auto* second = AccessRequestDispatchState::GetOrCreate(second_profile.get());
  ASSERT_NE(first, nullptr);
  ASSERT_NE(second, nullptr);
  EXPECT_NE(first, second);
}

}  // namespace
}  // namespace aegis::access
