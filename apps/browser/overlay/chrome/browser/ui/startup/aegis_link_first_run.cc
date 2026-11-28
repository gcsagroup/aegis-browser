// 普通浏览器窗口尚未创建时显示的独立 Views
// 窗口。登录门户与欢迎页都使用即将打开的 Profile。
#include "chrome/browser/ui/startup/aegis_link_first_run.h"

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/webui/aegis/link_first_run_choice.h"
#include "chrome/common/aegis/link_account.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "components/prefs/pref_service.h"
#include "ui/views/controls/webview/webview.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"

namespace aegis::link {
namespace {
class WelcomeWindow {
 public:
  WelcomeWindow(Profile* profile,
                std::unique_ptr<ScopedProfileKeepAlive> hold,
                base::OnceClosure resume)
      : profile_(profile),
        profile_hold_(std::move(hold)),
        resume_(std::move(resume)) {
    delegate_.SetTitle(u"Aegis Browser");
    delegate_.SetHasWindowSizeControls(true);
    auto* view =
        delegate_.SetContentsView(std::make_unique<views::WebView>(profile));
    view->SetPreferredSize(gfx::Size(960, 680));
    FirstRunChoice::Attach(view->GetWebContents(),
                           base::BindOnce(&WelcomeWindow::ScheduleCompletion,
                                          weak_factory_.GetWeakPtr()));
    delegate_.RegisterWindowClosingCallback(base::BindOnce(
        &WelcomeWindow::WindowClosing, weak_factory_.GetWeakPtr()));
    views::Widget::InitParams params(
        views::Widget::InitParams::CLIENT_OWNS_WIDGET,
        views::Widget::InitParams::TYPE_WINDOW);
    params.delegate = &delegate_;
    widget_.Init(std::move(params));
    view->LoadInitialURL(GURL(kWelcomePage));
    widget_.Show();
  }
  static std::unique_ptr<WelcomeWindow>& Active() {
    static base::NoDestructor<std::unique_ptr<WelcomeWindow>> instance;
    return *instance;
  }
  void Activate() { widget_.Activate(); }

 private:
  void WindowClosing() {
    weak_factory_.InvalidateWeakPtrs();
    // widget 的关闭通知处理中不能销毁它自身。
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce([] { Active().reset(); }));
  }
  void ScheduleCompletion() {
    // 离开 WebUI 消息回调栈再显示主窗，避免标签页/资料被嵌套销毁。
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce(&WelcomeWindow::Finish, weak_factory_.GetWeakPtr()));
  }
  void Finish() {
    if (!resume_)
      return;
    profile_->GetPrefs()->SetBoolean(kWelcomeSeen, true);
    profile_->GetPrefs()->ClearPref(kWelcomePending);
    profile_->GetPrefs()->CommitPendingWrite();
    std::move(resume_).Run();
    widget_.Close();
  }
  ScopedKeepAlive process_hold_{KeepAliveOrigin::USER_MANAGER_VIEW,
                                KeepAliveRestartOption::DISABLED};
  raw_ptr<Profile> profile_;
  std::unique_ptr<ScopedProfileKeepAlive> profile_hold_;
  base::OnceClosure resume_;
  views::WidgetDelegate delegate_;
  views::Widget widget_;
  base::WeakPtrFactory<WelcomeWindow> weak_factory_{this};
};
}  // namespace

void ShowFirstRunWindow(Profile* profile, base::OnceClosure resume_startup) {
  if (auto& active = WelcomeWindow::Active()) {
    active->Activate();
    return;
  }
  auto hold = ScopedProfileKeepAlive::TryAcquire(
      profile, ProfileKeepAliveOrigin::kProfilePickerView);
  if (!hold)
    return;
  // 用户关闭窗口仍可在下次正常启动继续，已经使用过的旧资料不会因引入此功能被拦截。
  profile->GetPrefs()->SetBoolean(kWelcomePending, true);
  profile->GetPrefs()->CommitPendingWrite();
  WelcomeWindow::Active() = std::make_unique<WelcomeWindow>(
      profile, std::move(hold), std::move(resume_startup));
}
}  // namespace aegis::link
