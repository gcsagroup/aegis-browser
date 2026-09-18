// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_browser_request_adapter.h"

#include <memory>

#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/test/base/testing_profile.h"
#include "components/aegis_access/request_policy_context.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/test/browser_task_environment.h"
#include "net/base/network_change_notifier.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

class AccessBrowserRequestAdapterTest : public testing::Test {
 protected:
  void SetUp() override {
    network_change_notifier_ =
        net::NetworkChangeNotifier::CreateMockIfNeeded();
    profile_ = TestingProfile::Builder().Build();
    partition_ = profile_->GetDefaultStoragePartition();
    ASSERT_TRUE(partition_);
  }

  void ConfigureDefaultPartition() {
    network::mojom::NetworkContextParams params;
    ASSERT_TRUE(AccessNetworkContextTransport::ConfigureNetworkContext(
        profile_.get(), base::FilePath(), &params));
    ASSERT_TRUE(params.initial_custom_proxy_config);
    ASSERT_TRUE(params.custom_proxy_config_client_receiver.is_valid());
  }

  content::BrowserTaskEnvironment task_environment_;
  std::unique_ptr<net::NetworkChangeNotifier> network_change_notifier_;
  std::unique_ptr<TestingProfile> profile_;
  raw_ptr<content::StoragePartition> partition_ = nullptr;
};

TEST_F(AccessBrowserRequestAdapterTest,
       BackgroundMetadataDoesNotCreateTransport) {
  EXPECT_EQ(AccessNetworkContextTransport::Get(profile_.get()), nullptr);

  const AccessBrowserRequestMetadataResult result =
      BuildBrowserOwnedProfileRequestMetadata(profile_.get(), partition_);

  EXPECT_EQ(result.status,
            AccessBrowserRequestMetadataStatus::kMissingTransport);
  EXPECT_FALSE(result.metadata.has_value());
  EXPECT_EQ(AccessNetworkContextTransport::Get(profile_.get()), nullptr);
}

TEST_F(AccessBrowserRequestAdapterTest,
       BackgroundMetadataRequiresConfiguredPartition) {
  ASSERT_TRUE(AccessNetworkContextTransport::GetOrCreate(profile_.get()));

  const AccessBrowserRequestMetadataResult result =
      BuildBrowserOwnedProfileRequestMetadata(profile_.get(), partition_);

  EXPECT_EQ(result.status,
            AccessBrowserRequestMetadataStatus::kUnconfiguredPartition);
  EXPECT_FALSE(result.metadata.has_value());
}

TEST_F(AccessBrowserRequestAdapterTest,
       BackgroundMetadataUsesProfileOnlyConfiguredPartitionOwnership) {
  AccessNetworkContextTransport* transport =
      AccessNetworkContextTransport::GetOrCreate(profile_.get());
  ASSERT_TRUE(transport);
  ConfigureDefaultPartition();

  const AccessBrowserRequestMetadataResult result =
      BuildBrowserOwnedProfileRequestMetadata(profile_.get(), partition_);

  ASSERT_EQ(result.status, AccessBrowserRequestMetadataStatus::kOk);
  ASSERT_TRUE(result.metadata.has_value());
  EXPECT_FALSE(result.metadata->request_id.empty());
  EXPECT_TRUE(transport->OwnsConfiguredPartition(result.metadata->owner));
  EXPECT_EQ(result.metadata->attribution_kind,
            aegis_access::RequestAttributionKind::kProfileOnly);
  EXPECT_TRUE(result.metadata->document_token.empty());
  EXPECT_TRUE(result.metadata->pending_navigation_token.empty());
  EXPECT_FALSE(result.metadata->top_frame_site.has_value());

  const aegis_access::RequestPolicyContextResult context =
      aegis_access::CanonicalizeBrowserOwnedRequest(
          *result.metadata, GURL("https://background.example/resource"));
  ASSERT_EQ(context.error, aegis_access::RequestContextError::kNone);
  ASSERT_TRUE(context.context.has_value());
  EXPECT_FALSE(context.context->site_ownership_reliable());
  EXPECT_TRUE(context.context->top_level_site().empty());
}

TEST_F(AccessBrowserRequestAdapterTest,
       BackgroundMetadataRejectsCrossProfilePartition) {
  ASSERT_TRUE(AccessNetworkContextTransport::GetOrCreate(profile_.get()));
  ConfigureDefaultPartition();

  std::unique_ptr<TestingProfile> other_profile =
      TestingProfile::Builder().Build();
  content::StoragePartition* other_partition =
      other_profile->GetDefaultStoragePartition();
  ASSERT_TRUE(other_partition);

  const AccessBrowserRequestMetadataResult result =
      BuildBrowserOwnedProfileRequestMetadata(profile_.get(), other_partition);

  EXPECT_EQ(result.status,
            AccessBrowserRequestMetadataStatus::kInvalidPartitionPath);
  EXPECT_FALSE(result.metadata.has_value());
}

TEST_F(AccessBrowserRequestAdapterTest,
       BackgroundMetadataRejectsMissingPartition) {
  ASSERT_TRUE(AccessNetworkContextTransport::GetOrCreate(profile_.get()));

  const AccessBrowserRequestMetadataResult result =
      BuildBrowserOwnedProfileRequestMetadata(profile_.get(), nullptr);

  EXPECT_EQ(result.status,
            AccessBrowserRequestMetadataStatus::kMissingStoragePartition);
  EXPECT_FALSE(result.metadata.has_value());
}

}  // namespace
}  // namespace aegis::access
