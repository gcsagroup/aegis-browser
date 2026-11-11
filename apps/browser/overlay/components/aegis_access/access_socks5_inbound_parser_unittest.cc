// Copyright 2026 GCSA

#include "components/aegis_access/access_socks5_inbound_parser.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access {
namespace {

TEST(AccessSocks5InboundParserTest, AcceptsNoAuthGreetingAndDomainConnect) {
  const std::vector<uint8_t> greeting = {0x05, 0x01, 0x00};
  const Socks5GreetingParseResult greet = ParseSocks5NoAuthGreeting(greeting);
  EXPECT_EQ(greet.status, Socks5InboundParseStatus::kOk);
  EXPECT_EQ(greet.consumed, 3u);
  ASSERT_EQ(greet.method_reply.size(), 2u);
  EXPECT_EQ(greet.method_reply[0], 0x05);
  EXPECT_EQ(greet.method_reply[1], 0x00);

  std::vector<uint8_t> request = {0x05, 0x01, 0x00, 0x03, 0x0b};
  const std::string host = "example.com";
  request.insert(request.end(), host.begin(), host.end());
  request.push_back(0x01);
  request.push_back(0xbb);  // 443
  const Socks5ConnectParseResult connect = ParseSocks5ConnectRequest(request);
  EXPECT_EQ(connect.status, Socks5InboundParseStatus::kOk);
  ASSERT_TRUE(connect.target.has_value());
  EXPECT_EQ(connect.target->host, "example.com");
  EXPECT_EQ(connect.target->port, 443u);
}

TEST(AccessSocks5InboundParserTest, RejectsUsernamePasswordOnlyGreeting) {
  const std::vector<uint8_t> greeting = {0x05, 0x01, 0x02};
  const Socks5GreetingParseResult greet = ParseSocks5NoAuthGreeting(greeting);
  EXPECT_EQ(greet.status, Socks5InboundParseStatus::kUsernamePasswordNotAdmitted);
}

TEST(AccessSocks5InboundParserTest, RejectsBindCommand) {
  const std::vector<uint8_t> request = {0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1,
                                        0x00, 0x50};
  const Socks5ConnectParseResult connect = ParseSocks5ConnectRequest(request);
  EXPECT_EQ(connect.status, Socks5InboundParseStatus::kUnsupportedCommand);
}

TEST(AccessSocks5InboundParserTest, SuccessReplyHasFixedShape) {
  const std::vector<uint8_t> reply = Socks5SuccessReply();
  ASSERT_EQ(reply.size(), 10u);
  EXPECT_EQ(reply[0], 0x05);
  EXPECT_EQ(reply[1], 0x00);
}

}  // namespace
}  // namespace aegis_access
