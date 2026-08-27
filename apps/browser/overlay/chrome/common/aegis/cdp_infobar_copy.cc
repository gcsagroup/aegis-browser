// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_infobar_copy.cc

#include "chrome/common/aegis/cdp_infobar_copy.h"

namespace aegis {

std::u16string CdpInfobarMessage(std::string_view locale) {
  if (locale.starts_with("zh-TW") || locale.starts_with("zh-HK")) {
    return u"本機 AI agent 已透過 CDP 連線。網頁內容仍可被讀取。";
  }
  if (locale.starts_with("zh")) {
    return u"本机 AI agent 已通过 CDP 连接。网页内容仍可被读取。";
  }
  return u"A local AI agent is connected over CDP. Page content can still "
         u"be read.";
}

std::u16string CdpInfobarButton(std::string_view locale) {
  if (locale.starts_with("zh-TW") || locale.starts_with("zh-HK")) {
    return u"打開設定";
  }
  if (locale.starts_with("zh")) {
    return u"打开设置";
  }
  return u"Open settings";
}

}  // namespace aegis
