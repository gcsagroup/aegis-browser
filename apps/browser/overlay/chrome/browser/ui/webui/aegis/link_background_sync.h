// 普通桌面资料的后台账号同步，使用该 Profile 自己的 Cookie 和浏览器存储。
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_BACKGROUND_SYNC_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_BACKGROUND_SYNC_H_
class Profile;
namespace content {
class WebContents;
}
namespace aegis::link {
// 每个普通 Profile 安装一次调度器，已登录时才打开一次性同步文档。
void StartBackgroundSync(Profile* profile);
// 用户提交选择时立即排队。正在运行的同步完成后再读取最新选择。
void RequestBackgroundSync(Profile* profile);
// 只有调度器创建的文档可以结束本轮，普通账号页不能关闭其他页面。
void FinishBackgroundSync(Profile* profile, content::WebContents* source);
}  // namespace aegis::link
#endif
