// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_DISK_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_DISK_H_

#include <string>
#include "base/files/file_path.h"

namespace aegis::access {
inline constexpr char kCoreLogDirectory[] = "AegisAccessDiagnostics";
enum class CoreLogProfile { kRegular, kPrivate };

// A missing historical file is an empty history. Save with an empty snapshot
// removes the file. These operations run on the diagnostics I/O sequence.
bool ReadCoreLogHistory(const base::FilePath& profile,
                        CoreLogProfile scope,
                        std::string* history);
bool SaveCoreLogHistory(const base::FilePath& profile,
                        CoreLogProfile scope,
                        const std::string& history);
}  // namespace aegis::access
#endif
