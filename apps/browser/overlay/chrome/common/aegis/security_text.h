// Copyright 2026 GCSA
#ifndef CHROME_COMMON_AEGIS_SECURITY_TEXT_H_
#define CHROME_COMMON_AEGIS_SECURITY_TEXT_H_

#include <cstddef>
#include <string>
#include <string_view>

namespace aegis {

struct SecurityText {
  std::string text;
  size_t removed_hidden_codepoints = 0;
  bool valid_utf8 = true;
};

// 仅用于检测、脱敏和模型文本副本；不得改写导航 URL、授权范围或操作参数。
// 删除 Tags 走私载体及少量无显示分隔符，不解码隐藏指令。
// 精确保留三个 RGI 地区旗帜、ZWJ/ZWNJ、变体选择符及普通多语言文本。
SecurityText NormalizeSecurityText(std::string_view input);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_SECURITY_TEXT_H_
