// Copyright 2026 GCSA

#include "chrome/services/aegis_torrent/torrent_safety.h"

#include <cstdint>
#include <string>
#include <vector>

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::torrent {
namespace {

std::vector<uint8_t> Bytes(std::string value) {
  return std::vector<uint8_t>(value.begin(), value.end());
}

std::string PieceHash() {
  return std::string(20, 'a');
}

TEST(AegisTorrentSafetyTest, AcceptsBoundedV1Torrent) {
  const std::string encoded =
      "d4:infod6:lengthi4e4:name8:test.bin12:piece lengthi4e6:pieces20:" +
      PieceHash() + "ee";
  const SafeTorrentPreview result = ValidateTorrentBytes(Bytes(encoded));

  ASSERT_TRUE(result.ok) << result.error;
  EXPECT_EQ("test.bin", result.name);
  EXPECT_EQ(4u, result.total_size);
  ASSERT_EQ(1u, result.files.size());
  EXPECT_EQ("test.bin", result.files[0].path);
  EXPECT_TRUE(result.has_v1);
}

TEST(AegisTorrentSafetyTest, RejectsParentTraversalBeforeSanitization) {
  const std::string encoded =
      "d4:infod5:filesld6:lengthi4e4:pathl2:..8:evil.bineee4:name4:root"
      "12:piece lengthi4e6:pieces20:" +
      PieceHash() + "ee";
  const SafeTorrentPreview result = ValidateTorrentBytes(Bytes(encoded));

  EXPECT_FALSE(result.ok);
  EXPECT_EQ("torrent contains an unsafe file path", result.error);
}

TEST(AegisTorrentSafetyTest, RejectsSymlinkEntry) {
  const std::string encoded =
      "d4:infod5:filesld4:attr1:l6:lengthi0e4:pathl8:link.bine"
      "12:symlink pathl10:target.bineee4:name4:root12:piece lengthi4e"
      "6:pieces20:" +
      PieceHash() + "ee";
  const SafeTorrentPreview result = ValidateTorrentBytes(Bytes(encoded));

  EXPECT_FALSE(result.ok);
}

TEST(AegisTorrentSafetyTest, AcceptsMagnetWithoutExposingTrackers) {
  const SafeTorrentPreview result = ValidateMagnetUri(
      "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&"
      "dn=Fixture&tr=http%3A%2F%2Ftracker.example%2Fannounce%3Ftoken%3Dsecret");

  ASSERT_TRUE(result.ok) << result.error;
  EXPECT_EQ("Fixture", result.name);
  EXPECT_TRUE(result.has_v1);
  EXPECT_EQ(1u, result.tracker_count);
}

TEST(AegisTorrentSafetyTest, RejectsMagnetWithoutInfoHash) {
  const SafeTorrentPreview result =
      ValidateMagnetUri("magnet:?dn=NoHash&tr=http://tracker.example/announce");
  EXPECT_FALSE(result.ok);
}

}  // namespace
}  // namespace aegis::torrent
