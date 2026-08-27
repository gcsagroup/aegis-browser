// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_infobar_copy_unittest.cc

#include "chrome/common/aegis/cdp_infobar_copy.h"

#include <string>

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {

TEST(CdpInfobarCopyTest, SimplifiedChinese) {
  EXPECT_NE(CdpInfobarMessage("zh-CN").find(u"本机 AI agent"),
            std::u16string::npos);
  EXPECT_EQ(CdpInfobarButton("zh-CN"), u"打开设置");
}

TEST(CdpInfobarCopyTest, TraditionalChinese) {
  EXPECT_NE(CdpInfobarMessage("zh-TW").find(u"本機 AI agent"),
            std::u16string::npos);
  EXPECT_EQ(CdpInfobarButton("zh-HK"), u"打開設定");
}

TEST(CdpInfobarCopyTest, English) {
  EXPECT_NE(CdpInfobarMessage("en-US").find(u"local AI agent"),
            std::u16string::npos);
  EXPECT_EQ(CdpInfobarButton("en"), u"Open settings");
}

}  // namespace aegis
