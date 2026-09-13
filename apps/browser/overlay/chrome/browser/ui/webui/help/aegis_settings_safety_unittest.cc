// Copyright 2026 GCSA
#include "base/test/bind.h"
#include "base/test/task_environment.h"
#include "build/branding_buildflags.h"
#include "chrome/browser/profile_resetter/reset_report_uploader.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/test/test_url_loader_factory.h"
#include "testing/gtest/include/gtest/gtest.h"

#if !BUILDFLAG(GOOGLE_CHROME_BRANDING)
TEST(AegisResetReportTest, OldFeedbackArgumentsNeverSendSettings) {
  base::test::TaskEnvironment tasks;
  network::TestURLLoaderFactory factory;
  int requests = 0;
  factory.SetInterceptor(base::BindLambdaForTesting(
      [&](const network::ResourceRequest&) { ++requests; }));
  ResetReportUploader uploader(factory.GetSafeWeakWrapper());
  uploader.DispatchReportInternal("representative reset report");
  uploader.DispatchReportInternal("another report from old UI");
  tasks.RunUntilIdle();
  EXPECT_EQ(requests, 0);
  EXPECT_EQ(factory.NumPending(), 0);
}
#endif
