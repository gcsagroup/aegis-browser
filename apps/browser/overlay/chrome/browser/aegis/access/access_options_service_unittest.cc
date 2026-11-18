// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_options_service.h"
#include "chrome/browser/aegis/access/access_service_coordinator.h"
#include "chrome/browser/aegis/access/access_build_channel.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/test/test_future.h"
#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
TEST(AccessOptionsServiceTest, ProductChannelConflictPreservesExistingDatabase) {
  content::BrowserTaskEnvironment environment;
  base::ScopedTempDir dir;
  ASSERT_TRUE(dir.CreateUniqueTempDir());
  auto profile = TestingProfile::Builder().SetPath(dir.GetPath()).Build();
  const auto other_channel = AccessChannelForCurrentBuild() == ChannelNamespace::kBeta
      ? ChannelNamespace::kDev : ChannelNamespace::kBeta;
  {
    auto binding = TrustedAccessStoreBindingFactory::CreatePersistent(
        other_channel, "aegis-access-profile:" + dir.GetPath().AsUTF8Unsafe(),
        "previous-runtime", dir.GetPath());
    ASSERT_TRUE(binding);
    AccessRuleStore previous(*binding);
    ASSERT_EQ(previous.Open(), StoreStatus::kValid);
  }
  std::string original;
  ASSERT_TRUE(base::ReadFileToString(dir.GetPath().AppendASCII("access.db"), &original));
  network::mojom::NetworkContextParams params;
  ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(profile.get(), {}, &params));
  auto* coordinator = AccessServiceCoordinator::GetOrCreate(profile.get());
  ASSERT_TRUE(coordinator);
  base::test::TestFuture<StoreStatus> checked;
  coordinator->CheckOptionsStoreBinding(checked.GetCallback());
  EXPECT_EQ(checked.Get(), StoreStatus::kConflict);
  if (auto* options = AccessOptionsService::GetOrCreate(profile.get())) {
    base::test::TestFuture<StoreResult<AccessOptionsSnapshot>> read;
    options->Read(read.GetCallback());
    EXPECT_EQ(read.Get().status, StoreStatus::kConflict);
    EXPECT_FALSE(read.Get().value);
  }
  EXPECT_FALSE(base::PathExists(dir.GetPath().AppendASCII("AccessOptions")));
  std::string current;
  ASSERT_TRUE(base::ReadFileToString(dir.GetPath().AppendASCII("access.db"), &current));
  EXPECT_EQ(current, original);
}
}  // namespace aegis::access
