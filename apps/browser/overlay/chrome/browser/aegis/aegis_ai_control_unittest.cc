// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_ai_control_unittest.cc

#include "chrome/browser/aegis/aegis_ai_control.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {

TEST(AiControlSecurityPolicyTest, AcceptsNumericLoopbackEndpoints) {
  int port = 0;
  EXPECT_TRUE(IsLoopbackDevToolsAddress("127.0.0.1:9222", &port));
  EXPECT_EQ(9222, port);
  EXPECT_TRUE(IsLoopbackDevToolsAddress("127.255.255.254:49152", &port));
  EXPECT_EQ(49152, port);
  EXPECT_TRUE(IsLoopbackDevToolsAddress("[::1]:9333", &port));
  EXPECT_EQ(9333, port);
}

TEST(AiControlSecurityPolicyTest, RejectsAmbiguousOrNonLoopbackEndpoints) {
  int port = 123;
  EXPECT_FALSE(IsLoopbackDevToolsAddress("", &port));
  EXPECT_EQ(0, port);
  EXPECT_FALSE(IsLoopbackDevToolsAddress("localhost:9222", &port));
  EXPECT_FALSE(IsLoopbackDevToolsAddress("127.0.0.1.evil:9222", &port));
  EXPECT_FALSE(IsLoopbackDevToolsAddress("0.0.0.0:9222", &port));
  EXPECT_FALSE(IsLoopbackDevToolsAddress("192.168.1.10:9222", &port));
  EXPECT_FALSE(IsLoopbackDevToolsAddress("[::]:9222", &port));
  EXPECT_FALSE(IsLoopbackDevToolsAddress("[::ffff:127.0.0.1]:9222", &port));
  EXPECT_FALSE(IsLoopbackDevToolsAddress("127.0.0.1:0", &port));
  EXPECT_FALSE(IsLoopbackDevToolsAddress("127.0.0.1", &port));
  EXPECT_FALSE(IsLoopbackDevToolsAddress("::1:9222", &port));
}

TEST(AiControlSecurityPolicyTest, RejectsEveryExplicitRemoteOrigin) {
  EXPECT_TRUE(HasExplicitRemoteAllowOrigins("*"));
  EXPECT_TRUE(HasExplicitRemoteAllowOrigins("http://localhost:3000, *"));
  EXPECT_TRUE(HasExplicitRemoteAllowOrigins(
      "http://localhost:3000,http://127.0.0.1:3000"));
  EXPECT_TRUE(HasExplicitRemoteAllowOrigins("https://*.example.test"));
  EXPECT_FALSE(HasExplicitRemoteAllowOrigins(""));
  EXPECT_FALSE(HasExplicitRemoteAllowOrigins(" ,  , "));
}

}  // namespace aegis
