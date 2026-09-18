// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_BROWSER_REQUEST_METADATA_SEED_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_BROWSER_REQUEST_METADATA_SEED_CONTRACT_TEST_H_

#include <string>

#include "components/aegis_access/browser_request_metadata_seed.h"

namespace aegis_access::test {

class BrowserRequestMetadataSeedTestObserver {
 public:
  virtual ~BrowserRequestMetadataSeedTestObserver() = default;
  virtual void Expect(bool condition, const std::string& label) = 0;
};

inline OwnershipKey MetadataSeedOwner() {
  return {ChannelNamespace::kDev, "profile-a", "partition-a"};
}

inline void RunBrowserReleaseChannelUnitTests(
    BrowserRequestMetadataSeedTestObserver& observer) {
  observer.Expect(MapBrowserReleaseChannel(BrowserReleaseChannel::kStable) ==
                      ChannelNamespace::kRelease,
                  "metadata seed unit stable maps release");
  observer.Expect(MapBrowserReleaseChannel(BrowserReleaseChannel::kBeta) ==
                      ChannelNamespace::kBeta,
                  "metadata seed unit beta maps beta");
  observer.Expect(MapBrowserReleaseChannel(BrowserReleaseChannel::kDev) ==
                      ChannelNamespace::kDev,
                  "metadata seed unit dev maps dev");
  observer.Expect(MapBrowserReleaseChannel(BrowserReleaseChannel::kCanary) ==
                      ChannelNamespace::kAlpha,
                  "metadata seed unit canary maps alpha");
  observer.Expect(MapBrowserReleaseChannel(BrowserReleaseChannel::kUnknown) ==
                      ChannelNamespace::kDev,
                  "metadata seed unit unknown maps dev");
  observer.Expect(MapBrowserReleaseChannel(BrowserReleaseChannel::kInvalid) ==
                      ChannelNamespace::kInvalid,
                  "metadata seed unit invalid stays invalid");
}

inline void RunMetadataSeedAttributionUnitTests(
    BrowserRequestMetadataSeedTestObserver& observer) {
  const auto document = PrepareBrowserRequestMetadataSeed(
      {"request-document", MetadataSeedOwner(), "document-a", "",
       "https://example.test"});
  observer.Expect(document.error == BrowserRequestMetadataSeedError::kNone &&
                      document.seed.has_value() &&
                      document.seed->attribution_kind ==
                          BrowserRequestAttributionKind::kDocument &&
                      document.seed->document_token == "document-a" &&
                      document.seed->top_frame_site == "https://example.test",
                  "metadata seed unit document attribution");

  const auto pending = PrepareBrowserRequestMetadataSeed(
      {"request-navigation", MetadataSeedOwner(), "", "navigation-a", ""});
  observer.Expect(pending.error == BrowserRequestMetadataSeedError::kNone &&
                      pending.seed.has_value() &&
                      pending.seed->attribution_kind ==
                          BrowserRequestAttributionKind::kPendingNavigation &&
                      pending.seed->pending_navigation_token == "navigation-a",
                  "metadata seed unit pending attribution");

  const auto profile = PrepareBrowserRequestMetadataSeed(
      {"request-profile", MetadataSeedOwner(), "", "", ""});
  observer.Expect(profile.error == BrowserRequestMetadataSeedError::kNone &&
                      profile.seed.has_value() &&
                      profile.seed->attribution_kind ==
                          BrowserRequestAttributionKind::kProfileOnly,
                  "metadata seed unit profile-only attribution");
}

inline void RunMetadataSeedValidationUnitTests(
    BrowserRequestMetadataSeedTestObserver& observer) {
  OwnershipKey invalid_owner = MetadataSeedOwner();
  invalid_owner.profile_token.clear();
  observer.Expect(PrepareBrowserRequestMetadataSeed(
                      {"request-invalid-owner", invalid_owner, "", "", ""})
                          .error == BrowserRequestMetadataSeedError::kInvalidOwner,
                  "metadata seed unit invalid owner rejected");
  observer.Expect(PrepareBrowserRequestMetadataSeed(
                      {"", MetadataSeedOwner(), "", "", ""})
                          .error == BrowserRequestMetadataSeedError::kInvalidRequestId,
                  "metadata seed unit empty request rejected");
  observer.Expect(PrepareBrowserRequestMetadataSeed(
                      {"request-document-no-site", MetadataSeedOwner(),
                       "document-a", "", ""})
                          .error ==
                      BrowserRequestMetadataSeedError::kInvalidAttribution,
                  "metadata seed unit document requires top site");
  observer.Expect(PrepareBrowserRequestMetadataSeed(
                      {"request-orphan-site", MetadataSeedOwner(), "", "",
                       "https://borrowed.test"})
                          .error ==
                      BrowserRequestMetadataSeedError::kInvalidAttribution,
                  "metadata seed unit orphan top site rejected");
}

inline void RunBrowserRequestMetadataSeedUnitTests(
    BrowserRequestMetadataSeedTestObserver& observer) {
  RunBrowserReleaseChannelUnitTests(observer);
  RunMetadataSeedAttributionUnitTests(observer);
  RunMetadataSeedValidationUnitTests(observer);
}

inline void RunNavigationMetadataSeedRegressionTests(
    BrowserRequestMetadataSeedTestObserver& observer) {
  const auto navigation_over_old_document = PrepareBrowserRequestMetadataSeed(
      {"request-navigation-priority", MetadataSeedOwner(), "old-document",
       "navigation-new", "https://old.example"});
  observer.Expect(
      navigation_over_old_document.error ==
              BrowserRequestMetadataSeedError::kNone &&
          navigation_over_old_document.seed.has_value() &&
          navigation_over_old_document.seed->attribution_kind ==
              BrowserRequestAttributionKind::kPendingNavigation &&
          navigation_over_old_document.seed->document_token.empty() &&
          navigation_over_old_document.seed->top_frame_site.empty() &&
          navigation_over_old_document.seed->pending_navigation_token ==
              "navigation-new",
      "metadata seed regression navigation never borrows old document");

  observer.Expect(MapBrowserReleaseChannel(BrowserReleaseChannel::kUnknown) !=
                      ChannelNamespace::kRelease,
                  "metadata seed regression unknown build never claims release");
}

inline void RunOwnershipMetadataSeedRegressionTests(
    BrowserRequestMetadataSeedTestObserver& observer) {
  OwnershipKey other_profile = MetadataSeedOwner();
  other_profile.profile_token = "profile-b";
  const auto profile_result = PrepareBrowserRequestMetadataSeed(
      {"request-other-profile", other_profile, "document-b", "",
       "https://example.test"});
  observer.Expect(profile_result.seed.has_value() &&
                      profile_result.seed->owner.profile_token == "profile-b" &&
                      profile_result.seed->owner.storage_partition_token ==
                          "partition-a",
                  "metadata seed regression profile identity is preserved");

  OwnershipKey other_partition = MetadataSeedOwner();
  other_partition.storage_partition_token = "partition-b";
  const auto partition_result = PrepareBrowserRequestMetadataSeed(
      {"request-other-partition", other_partition, "document-a", "",
       "https://example.test"});
  observer.Expect(partition_result.seed.has_value() &&
                      partition_result.seed->owner.profile_token == "profile-a" &&
                      partition_result.seed->owner.storage_partition_token ==
                          "partition-b",
                  "metadata seed regression partition identity is preserved");
}

inline void RunFailClosedMetadataSeedRegressionTests(
    BrowserRequestMetadataSeedTestObserver& observer) {
  OwnershipKey invalid_channel = MetadataSeedOwner();
  invalid_channel.channel = ChannelNamespace::kInvalid;
  observer.Expect(PrepareBrowserRequestMetadataSeed(
                      {"request-invalid-channel", invalid_channel, "", "", ""})
                          .error == BrowserRequestMetadataSeedError::kInvalidOwner,
                  "metadata seed regression invalid channel fails closed");

  const auto worker_like = PrepareBrowserRequestMetadataSeed(
      {"request-worker-like", MetadataSeedOwner(), "", "", ""});
  observer.Expect(worker_like.seed.has_value() &&
                      worker_like.seed->attribution_kind ==
                          BrowserRequestAttributionKind::kProfileOnly &&
                      worker_like.seed->top_frame_site.empty(),
                  "metadata seed regression background request cannot borrow site");
}

inline void RunBrowserRequestMetadataSeedRegressionTests(
    BrowserRequestMetadataSeedTestObserver& observer) {
  RunNavigationMetadataSeedRegressionTests(observer);
  RunOwnershipMetadataSeedRegressionTests(observer);
  RunFailClosedMetadataSeedRegressionTests(observer);
}

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_BROWSER_REQUEST_METADATA_SEED_CONTRACT_TEST_H_
