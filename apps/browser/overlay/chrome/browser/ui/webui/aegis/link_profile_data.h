// 在浏览器 UI
// 线程读写当前账号的专用书签目录及两项字号；恢复前核对完整本地快照。
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_PROFILE_DATA_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_PROFILE_DATA_H_
#include <string_view>
#include "base/types/expected.h"
#include "base/values.h"
class Profile;
namespace aegis::link {
base::expected<base::Value, const char*> ProfileData(
    Profile* profile,
    std::string_view account,
    std::string_view email,
    std::string_view collection,
    const base::DictValue& input);
}
#endif
