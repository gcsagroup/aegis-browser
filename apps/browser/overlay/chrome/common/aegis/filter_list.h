// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/filter_list.h
// Keep the parser aligned with packages/core/src/tracker/easylist.ts.

#ifndef CHROME_COMMON_AEGIS_FILTER_LIST_H_
#define CHROME_COMMON_AEGIS_FILTER_LIST_H_

#include <string>
#include <string_view>
#include <vector>

namespace aegis {

// Profile 磁盘缓存格式。升级此值会让旧 compiled.json 失效并重新拉取。
inline constexpr int kCompiledCacheFormat = 1;

struct CompiledFilterList {
  int version = 1;
  std::string source;
  std::string generated_at;
  std::vector<std::string> hosts;
  std::vector<std::string> path_rules;
  std::vector<std::string> exceptions;
  int parsed = 0;
  int skipped = 0;
};

// Parse a single EasyList network rule. Returns false for cosmetics / regex /
// site-specific rules.
bool ParseEasyListRule(std::string_view line,
                       bool* is_exception,
                       std::string* rule,
                       bool* is_path);

CompiledFilterList CompileEasyList(std::string_view text,
                                   std::string_view source);

CompiledFilterList MergeCompiledFilterLists(
    const std::vector<CompiledFilterList>& lists,
    std::string_view source);

std::string CompiledFilterListToJson(const CompiledFilterList& list);
bool CompiledFilterListFromJson(std::string_view json,
                                CompiledFilterList* list);

std::string JoinNewline(const std::vector<std::string>& values);
std::vector<std::string> SplitNewline(std::string_view blob);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_FILTER_LIST_H_
