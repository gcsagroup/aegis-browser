// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_core_log.h"

#include "chrome/browser/aegis/access/access_build_channel.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {
constexpr char kTime[] = "2026/11/11 13:14:15.123456 ";
TEST(AccessCoreLogTest, BuildChannelsChooseDiagnosticDefaults) {
  using Channel = aegis_access::BrowserReleaseChannel;
  using Bundled = aegis_access::ChannelNamespace;
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kDev, Bundled::kInvalid), "debug");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kCanary, Bundled::kInvalid), "info");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kBeta, Bundled::kInvalid), "warning");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kStable, Bundled::kInvalid), "warning");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kUnknown, Bundled::kInvalid), "warning");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kInvalid, Bundled::kInvalid), "warning");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kUnknown, Bundled::kAlpha), "info");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kUnknown, Bundled::kBeta), "warning");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kDev, Bundled::kAlpha), "debug");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kStable, Bundled::kAlpha), "warning");
  EXPECT_EQ(DefaultCoreLogLevelForBuild(Channel::kInvalid, Bundled::kAlpha), "warning");
}

TEST(AccessCoreLogTest, ChannelDefaultsRetainThresholdRedactionAndManualOff) {
  using Channel = aegis_access::BrowserReleaseChannel;
  for (const auto channel : {Channel::kDev, Channel::kCanary, Channel::kBeta,
                            Channel::kStable, Channel::kUnknown}) {
    AccessCoreLog log;
    const auto level = DefaultCoreLogLevelForBuild(
        channel, aegis_access::ChannelNamespace::kInvalid);
    log.SetLevel(level);
    EXPECT_EQ(log.Add(std::string(kTime) + "[Info] untrusted/node: SECRET"),
              channel == Channel::kDev || channel == Channel::kCanary);
    EXPECT_TRUE(log.Add(std::string(kTime) + "[Warning] untrusted/node: SECRET"));
    EXPECT_EQ(log.Snapshot().find("SECRET"), std::string::npos);
    log.SetLevel("none");
    EXPECT_TRUE(log.Snapshot().empty());
    EXPECT_FALSE(log.Add(std::string(kTime) + "[Error] core: SECRET"));
  }
}

TEST(AccessCoreLogTest, ThresholdAndRealLineGrammar) {
  AccessCoreLog log;
  ASSERT_EQ(log.level(), "warning");
  log.Add(std::string(kTime) +
          "[Info] proxy/http: request to Method [GET] Host [site] with URL "
          "[secret]");
  log.Add(std::string(kTime) + "[Warning] core: Xray 26.1.18 started");
  EXPECT_EQ(log.Snapshot(),
            std::string(kTime) + "[Warning] core: Xray 26.1.18 started");
  log.SetLevel("error");
  EXPECT_TRUE(log.Snapshot().empty());
  log.Add(std::string(kTime) +
          "[Error] [307] app/dispatcher: failed to pick route for token");
  EXPECT_EQ(
      log.Snapshot(),
      std::string(kTime) +
          "[Error] [307] app/dispatcher: failed to pick route for [redacted]");
  log.SetLevel("none");
  log.Add(std::string(kTime) + "[Error] token");
  EXPECT_TRUE(log.Snapshot().empty());
  log.SetLevel("invalid");
  EXPECT_EQ(log.level(), "warning");
}
TEST(AccessCoreLogTest, StripAccessSecretsKeepOnlyDestination) {
  AccessCoreLog log;
  log.SetLevel("debug");
  auto line = [](std::string target) {
    return std::string(kTime) + "from SECRET_LOCAL accepted " + target +
           " [SECRET_NODE] email: SECRET_EMAIL";
  };
  log.Add(line("tcp:private.example.test:443"));
  EXPECT_EQ(log.Snapshot(),
            std::string(kTime) +
                "from [redacted] accepted tcp:private.example.test:443");
  log.Clear();
  log.Add(line("https://private.example.test/path?api_key=SECRET"));
  EXPECT_EQ(
      log.Snapshot(),
      std::string(kTime) + "from [redacted] accepted private.example.test:443");
  for (std::string target : {"tcp:user:SECRET@host:443", "tcp:host/SECRET:443",
                             "tcp:DANGEROUS.example:443", "tcp:host:99999"}) {
    log.Clear();
    log.Add(line(target), {"dangerous"});
    EXPECT_EQ(log.Snapshot(),
              std::string(kTime) + "from [redacted] accepted [redacted]");
  }
  log.Clear();
  log.Add(std::string(kTime) + "[Debug] untrusted/node: secret-token");
  EXPECT_EQ(log.Snapshot(), std::string(kTime) + "[Debug] [redacted]");
}
TEST(AccessCoreLogTest, FragmentOversizeAndBoundedHistory) {
  CoreLogFramer framer;
  AccessCoreLog log;
  auto accept = [&log](std::string_view value) { log.Add(value); };
  const std::string record =
      std::string(kTime) + "[Warning] core: Xray 26.1.18 started";
  framer.Feed(std::string(4097, 'x') + record + "\n", accept);
  framer.Feed(record.substr(0, 11), accept);
  EXPECT_TRUE(log.Snapshot().empty());
  framer.Feed(record.substr(11) + "\n", accept);
  EXPECT_EQ(log.Snapshot(), record);
  for (int i = 0; i < 200; ++i)
    framer.Feed(record + "\n", accept);
  const auto bounded = log.Snapshot();
  EXPECT_EQ(std::count(bounded.begin(), bounded.end(), '\n'), 127);
  EXPECT_LE(bounded.size(), 65536u);
}
}  // namespace
}  // namespace aegis::access
