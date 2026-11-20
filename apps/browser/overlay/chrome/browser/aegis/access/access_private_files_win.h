// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PRIVATE_FILES_WIN_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PRIVATE_FILES_WIN_H_

#include "base/files/platform_file.h"

namespace base {
class FilePath;
}
namespace aegis::access {

bool CreatePrivateAccessDirectory(const base::FilePath& path);
bool IsOwnedAccessDirectory(const base::FilePath& path);
bool IsPrivateAccessDirectory(const base::FilePath& path);
bool IsPrivateAccessFile(base::PlatformFile file);
bool HasPrivateAccessAcl(base::PlatformFile file, bool private_directory);

}  // namespace aegis::access
#endif
