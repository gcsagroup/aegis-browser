// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_LOCAL_CORE_WIN_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_LOCAL_CORE_WIN_H_

#include "base/process/process.h"
#include "base/win/scoped_handle.h"

namespace base {
class CommandLine;
class File;
class FilePath;
class ScopedTempDir;
}  // namespace base

namespace aegis::access {

bool CreatePrivateCoreDirectory(base::ScopedTempDir& directory);

// The browser owns the only job handle. Windows assigns the child to the job
// at creation and terminates its processes if the browser exits unexpectedly.
base::Process LaunchOwnedCore(const base::CommandLine& command,
                              const base::FilePath& directory,
                              base::win::ScopedHandle& job,
                              base::File* log_read = nullptr);

// Bounds the job rundown and the retry window for deleting locked files.
void StopOwnedCore(base::win::ScopedHandle& job, base::ScopedTempDir& directory);

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_LOCAL_CORE_WIN_H_
