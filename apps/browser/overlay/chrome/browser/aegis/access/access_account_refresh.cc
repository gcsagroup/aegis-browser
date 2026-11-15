// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_account_refresh.h"

#include <array>
#include <cstdint>

#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"

namespace aegis::access {

std::u16string FormatAccessUsageBytes(std::string_view raw) {
  uint64_t bytes;
  if (!base::StringToUint64(raw, &bytes) || base::NumberToString(bytes) != raw) {
    return u"—";
  }
  const auto exact = base::ASCIIToUTF16(raw) + u" B";
  if (bytes < 1024) {
    return exact;
  }

  constexpr auto units =
      std::to_array<std::u16string_view>({u"B", u"KiB", u"MiB", u"GiB",
                                         u"TiB", u"PiB", u"EiB"});
  uint64_t divisor = 1;
  size_t unit = 0;
  while (unit + 1 < units.size() && bytes / divisor >= 1024) {
    divisor *= 1024;
    ++unit;
  }
  // On macOS the full-width product preserves truncation even at EiB scale.
  const uint64_t fraction =
      static_cast<unsigned __int128>(bytes % divisor) * 100 / divisor;
  std::u16string result = base::NumberToString16(bytes / divisor);
  result += fraction < 10 ? u".0" : u".";
  result += base::NumberToString16(fraction);
  result += u" ";
  result += units[unit];
  result += u" (";
  result += exact;
  result += u")";
  return result;
}

AccessAccountRefresh::AccessAccountRefresh() = default;
AccessAccountRefresh::~AccessAccountRefresh() = default;

}  // namespace aegis::access
