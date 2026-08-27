// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_infobar_copy.h

#ifndef CHROME_COMMON_AEGIS_CDP_INFOBAR_COPY_H_
#define CHROME_COMMON_AEGIS_CDP_INFOBAR_COPY_H_

#include <string>
#include <string_view>

namespace aegis {

// 远程 CDP 已连接时，浏览器横幅的文案。|locale| 如 zh-CN / zh-TW / en。
std::u16string CdpInfobarMessage(std::string_view locale);
std::u16string CdpInfobarButton(std::string_view locale);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_CDP_INFOBAR_COPY_H_
