// 跟踪一次浏览器账号登录，不改变整个 Profile 的密码管理器设置。
#include "chrome/browser/ui/webui/aegis/link_browser_login.h"

#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/ui/webui/aegis/link_first_run_choice.h"
#include "chrome/browser/ui/webui/aegis/link_portal_origin.h"
#include "chrome/common/aegis/link_account.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "url/origin.h"

namespace {
// 专用页面仅提供账号登录；是否来自原生操作仍由当前标签的 LoginReturn 状态判定。
constexpr char kLoginPath[] = "/login/browser";
constexpr char kRegisterPath[] = "/login/browser/register";
GURL Portal() {
  return GURL(AEGIS_LINK_PORTAL_ORIGIN);
}
// 只有从原生登录按钮开始的本次标签页导航可以返回账号页。普通网页不能发起特权导航。
class LoginReturn : public content::WebContentsObserver,
                    public content::WebContentsUserData<LoginReturn> {
 public:
  void Begin() {
    waiting_ = true;
    opening_login_ = true;
    submitted_here_ = false;
    web_contents()->GetController().LoadURL(
        Portal().Resolve(kLoginPath), content::Referrer(),
        ui::PAGE_TRANSITION_AUTO_BOOKMARK, {});
  }
  void DidFinishNavigation(content::NavigationHandle* nav) override {
    if (!nav->IsInPrimaryMainFrame() || !nav->HasCommitted()) {
      return;
    }
    const auto& url = nav->GetURL();
    if (opening_login_) {
      opening_login_ = false;
      submitted_here_ = !nav->IsErrorPage() &&
                        url == Portal().Resolve(kLoginPath);
    }
    // SPA 切到 /account
    // 后密码管理器可能才收到提交结果，保留到原生账号页完成返回。
    const bool login_page =
        url::Origin::Create(url) == url::Origin::Create(Portal()) &&
        (url.path() == kLoginPath || url.path().starts_with("/login/browser/"));
    if (!login_page && url != Portal().Resolve("/account") &&
        url.GetWithoutRef() != GURL(aegis::link::kPage)) {
      submitted_here_ = false;
    }
    if (!waiting_ || nav->IsErrorPage()) {
      return;
    }
    if (nav->GetURL() != Portal().Resolve("/account")) {
      return;
    }
    waiting_ = false;
    // 同文档 SPA 登录回跳也会到这里。延迟导航避免在提交回调内重入。
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::WeakPtr<content::WebContents> tab) {
                         if (tab && tab->GetLastCommittedURL() ==
                                        Portal().Resolve("/account")) {
                           tab->GetController().LoadURL(
                               GURL(aegis::link::FirstRunChoice::From(tab.get())
                                        ? aegis::link::kWelcomePage
                                        : aegis::link::kPage),
                               content::Referrer(),
                               ui::PAGE_TRANSITION_AUTO_BOOKMARK, {});
                         }
                       },
                       web_contents()->GetWeakPtr()));
  }

  bool Matches(const GURL& form) const {
    // 登录与注册共用门户表单，只有原生发起且同源的这两个凭据表单由客户端管理。
    return submitted_here_ &&
           (form.path() == kLoginPath || form.path() == kRegisterPath) &&
           url::Origin::Create(form) == url::Origin::Create(Portal());
  }

 private:
  friend class content::WebContentsUserData<LoginReturn>;
  explicit LoginReturn(content::WebContents* tab)
      : content::WebContentsObserver(tab),
        content::WebContentsUserData<LoginReturn>(*tab) {}
  bool waiting_ = false;
  bool opening_login_ = false;
  bool submitted_here_ = false;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};
WEB_CONTENTS_USER_DATA_KEY_IMPL(LoginReturn);

}  // namespace

namespace aegis::link {
void BeginBrowserLogin(content::WebContents* tab) {
  LoginReturn::CreateForWebContents(tab);
  LoginReturn::FromWebContents(tab)->Begin();
}
bool IsBrowserLoginCredential(content::WebContents* tab, const GURL& form) {
  auto* login = LoginReturn::FromWebContents(tab);
  return login && login->Matches(form);
}
}  // namespace aegis::link
