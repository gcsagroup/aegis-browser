// 原生登录的范围仅限主动发起登录的 WebContents 及受信任门户表单。
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_BROWSER_LOGIN_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_BROWSER_LOGIN_H_
class GURL;
namespace content {
class WebContents;
}
namespace aegis::link {
// 打开编译进包的登录入口，并在门户确认会话后返回浏览器账号页。
void BeginBrowserLogin(content::WebContents* tab);
// 密码管理器在展示保存或更新提示前用此函数核对本次凭据的来源。
bool IsBrowserLoginCredential(content::WebContents* tab, const GURL& form);
}  // namespace aegis::link
#endif
