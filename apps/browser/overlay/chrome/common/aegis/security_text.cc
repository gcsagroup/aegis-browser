// Copyright 2026 GCSA
#include "chrome/common/aegis/security_text.h"

#include "base/strings/utf_string_conversion_utils.h"

namespace aegis {
namespace {

// 仅精确匹配合法序列，不能让任意“黑旗 + 标签”成为走私白名单。
constexpr std::string_view kSubdivisionFlags[] = {
    "\U0001f3f4\U000e0067\U000e0062\U000e0065\U000e006e\U000e0067\U000e007f",
    "\U0001f3f4\U000e0067\U000e0062\U000e0073\U000e0063\U000e0074\U000e007f",
    "\U0001f3f4\U000e0067\U000e0062\U000e0077\U000e006c\U000e0073\U000e007f",
};

}  // namespace

SecurityText NormalizeSecurityText(std::string_view input) {
  SecurityText result;
  result.text.reserve(input.size());
  for (size_t index = 0; index < input.size(); ++index) {
    bool flag_matched = false;
    for (std::string_view flag : kSubdivisionFlags) {
      if (input.substr(index).starts_with(flag)) {
        result.text.append(flag);
        index += flag.size() - 1;
        flag_matched = true;
        break;
      }
    }
    if (flag_matched) {
      continue;
    }
    const size_t start = index;
    base_icu::UChar32 codepoint;
    if (!base::ReadUnicodeCharacter(input, &index, &codepoint)) {
      result.valid_utf8 = false;
      result.text.clear();
      return result;
    }
    if ((codepoint >= 0xe0000 && codepoint <= 0xe007f) || codepoint == 0x00ad ||
        codepoint == 0x200b || codepoint == 0x2060 || codepoint == 0xfeff) {
      ++result.removed_hidden_codepoints;
      continue;
    }
    if (codepoint == 0x00a0 || codepoint == 0x202f) {
      result.text.push_back(' ');
    } else {
      result.text.append(input.substr(start, index - start + 1));
    }
  }
  return result;
}

}  // namespace aegis
