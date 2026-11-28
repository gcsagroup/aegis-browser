// 后台与账号页运行相同的同步协议。每轮释放隐藏文档，退出或销毁 Profile
// 时停止调度。
#include "chrome/browser/ui/webui/aegis/link_background_sync.h"

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/supports_user_data.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/common/aegis/link_account.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"

namespace aegis::link {
namespace {
const char kSchedulerKey = 0;
class Scheduler : public base::SupportsUserData::Data, public ProfileObserver {
 public:
  explicit Scheduler(Profile* profile) : profile_(profile) {
    observation_.Observe(profile);
    prefs_.Init(profile->GetPrefs());
    prefs_.Add(kEmail,
               base::BindRepeating(&Scheduler::Schedule, weak_.GetWeakPtr()));
    Schedule();
  }

  void Finish(content::WebContents* source) {
    if (source != document_.get()) {
      return;
    }
    // 延迟到当前桥接回调返回，避免在 WebUI 消息处理过程中销毁它自身。
    timer_.Start(FROM_HERE, base::TimeDelta(), this, &Scheduler::Rest);
  }

  void RequestNow() {
    if (document_) {
      queued_ = true;
    } else {
      Schedule();
    }
  }

 private:
  void Schedule() {
    timer_.Start(FROM_HERE, base::TimeDelta(), this, &Scheduler::Run);
  }
  void Rest() {
    document_.reset();
    if (queued_) {
      Schedule();
      return;
    }
    if (!profile_->GetPrefs()->GetString(kEmail).empty()) {
      timer_.Start(FROM_HERE, base::Minutes(2), this, &Scheduler::Run);
    }
  }
  void Run() {
    queued_ = false;
    document_.reset();
    if (profile_->GetPrefs()->GetString(kEmail).empty()) {
      return;
    }
    content::WebContents::CreateParams params(profile_);
    params.initially_hidden = true;
    document_ = content::WebContents::Create(params);
    document_->GetController().LoadURL(GURL(kBackgroundPage),
                                       content::Referrer(),
                                       ui::PAGE_TRANSITION_AUTO_TOPLEVEL, {});
    // 网络中断或渲染进程退出时释放本轮并重试，页面自身不持有长期计时器。
    timer_.Start(FROM_HERE, base::Minutes(2), this, &Scheduler::Rest);
  }
  void OnProfileWillBeDestroyed(Profile* profile) override {
    weak_.InvalidateWeakPtrs();
    timer_.Stop();
    prefs_.RemoveAll();
    document_.reset();
    observation_.Reset();
  }
  const raw_ptr<Profile> profile_;
  base::ScopedObservation<Profile, ProfileObserver> observation_{this};
  PrefChangeRegistrar prefs_;
  base::OneShotTimer timer_;
  bool queued_ = false;
  std::unique_ptr<content::WebContents> document_;
  base::WeakPtrFactory<Scheduler> weak_{this};
};
}  // namespace
void StartBackgroundSync(Profile* profile) {
  if (profile->IsRegularProfile() && !profile->IsOffTheRecord() &&
      !profile->GetUserData(&kSchedulerKey)) {
    profile->SetUserData(&kSchedulerKey, std::make_unique<Scheduler>(profile));
  }
}
void RequestBackgroundSync(Profile* profile) {
  StartBackgroundSync(profile);
  if (auto* scheduler =
          static_cast<Scheduler*>(profile->GetUserData(&kSchedulerKey))) {
    scheduler->RequestNow();
  }
}
void FinishBackgroundSync(Profile* profile, content::WebContents* source) {
  if (auto* scheduler =
          static_cast<Scheduler*>(profile->GetUserData(&kSchedulerKey))) {
    scheduler->Finish(source);
  }
}
}  // namespace aegis::link
