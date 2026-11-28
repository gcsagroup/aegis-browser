// 桌面首次启动窗口。启动器在用户完成选择后才恢复原来的浏览器启动请求。
#ifndef CHROME_BROWSER_UI_STARTUP_AEGIS_LINK_FIRST_RUN_H_
#define CHROME_BROWSER_UI_STARTUP_AEGIS_LINK_FIRST_RUN_H_
#include "base/functional/callback.h"
class Profile;
namespace aegis::link {
void ShowFirstRunWindow(Profile* profile, base::OnceClosure resume_startup);
}
#endif
