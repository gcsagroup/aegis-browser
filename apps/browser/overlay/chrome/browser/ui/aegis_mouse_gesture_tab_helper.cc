// Copyright 2026 GCSA
#include "chrome/browser/ui/aegis_mouse_gesture_tab_helper.h"

#include <algorithm>
#include <utility>

#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "cc/paint/paint_flags.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "chrome/common/extensions/extension_constants.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/input/web_mouse_wheel_event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/font_list.h"
#include "ui/gfx/geometry/point_conversions.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"

namespace aegis {
namespace {
constexpr int kBypassModifiers =
    blink::WebInputEvent::kAltKey | blink::WebInputEvent::kControlKey |
    blink::WebInputEvent::kMetaKey | blink::WebInputEvent::kShiftKey;

bool IsPdfViewer(content::RenderFrameHost* frame) {
  const GURL& url = frame->GetLastCommittedURL();
  return url.SchemeIs("chrome-extension") &&
         url.host() == extension_misc::kPdfExtensionId;
}

std::u16string PatternLabel(const std::string& pattern) {
  std::u16string result;
  for (char c : pattern) {
    switch (c) {
      case 'L':
        result += u"← ";
        break;
      case 'R':
        result += u"→ ";
        break;
      case 'U':
        result += u"↑ ";
        break;
      case 'D':
        result += u"↓ ";
        break;
    }
  }
  return result;
}
}  // namespace

// 独立的原生透明层；不进入网页 DOM，也不接收鼠标和键盘输入。
class GestureTrailView : public views::View {
 public:
  void Update(std::vector<gfx::PointF> points, std::u16string label) {
    points_ = std::move(points);
    label_ = std::move(label);
    SchedulePaint();
  }
  void OnPaint(gfx::Canvas* canvas) override {
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setStrokeWidth(4);
    flags.setStrokeCap(cc::PaintFlags::kRound_Cap);
    flags.setColor(SkColorSetRGB(44, 139, 255));
    for (size_t i = 1; i < points_.size(); ++i) {
      canvas->DrawLine(points_[i - 1], points_[i], flags);
    }
    const int width = std::min(420, std::max(0, this->width() - 24));
    const gfx::Rect box((this->width() - width) / 2, std::max(8, height() - 72),
                        width, 48);
    flags.setColor(SkColorSetARGB(235, 24, 32, 47));
    flags.setStyle(cc::PaintFlags::kFill_Style);
    canvas->DrawRoundRect(box, 12, flags);
    canvas->DrawStringRect(label_, gfx::FontList().DeriveWithSizeDelta(2),
                           SK_ColorWHITE, box);
  }

 private:
  std::vector<gfx::PointF> points_;
  std::u16string label_;
};

MouseGestureTabHelper::MouseGestureTabHelper(content::WebContents* contents)
    : content::WebContentsObserver(contents),
      content::WebContentsUserData<MouseGestureTabHelper>(*contents) {
  ObserveFrames();
}

MouseGestureTabHelper::~MouseGestureTabHelper() {
  DetachInput();
}

void MouseGestureTabHelper::DetachInput() {
  Cancel();
  pending_ = false;
  origin_host_ = nullptr;
  window_observation_.Reset();
  for (const auto& [host, callbacks] : callbacks_) {
    host->RemoveMouseEventCallback(callbacks.mouse);
    host->RemoveKeyPressEventCallback(callbacks.key);
  }
  callbacks_.clear();
  host_observations_.RemoveAllObservations();
}

MouseGestureTabHelper* MouseGestureTabHelper::RootHelper() {
  if (!web_contents()) {
    return this;
  }
  auto* root = FromWebContents(web_contents()->GetOutermostWebContents());
  return root ? root : this;
}

void MouseGestureTabHelper::ObserveFrames() {
  web_contents()->ForEachRenderFrameHost([this](
                                             content::RenderFrameHost* frame) {
    if (content::WebContents::FromRenderFrameHost(frame) == web_contents()) {
      Attach(frame->GetRenderWidgetHost());
    }
  });
  for (auto* inner : web_contents()->GetInnerWebContents()) {
    CreateForWebContents(inner);
  }
}

void MouseGestureTabHelper::Attach(content::RenderWidgetHost* host) {
  if (!host || callbacks_.contains(host)) {
    return;
  }
  Callbacks callbacks{
      base::BindRepeating(&MouseGestureTabHelper::OnMouse,
                          base::Unretained(this), host, web_contents()),
      base::BindRepeating(&MouseGestureTabHelper::OnKey,
                          base::Unretained(this))};
  host->AddMouseEventCallback(callbacks.mouse);
  host->AddKeyPressEventCallback(callbacks.key);
  callbacks_.emplace(host, std::move(callbacks));
  host_observations_.AddObservation(host);
}

void MouseGestureTabHelper::RenderFrameCreated(
    content::RenderFrameHost* frame) {
  Attach(frame->GetRenderWidgetHost());
}

void MouseGestureTabHelper::DidStartNavigation(content::NavigationHandle*) {
  // 任意框架开始导航都取消，避免同进程子框架复用输入目标。
  RootHelper()->Cancel();
}

void MouseGestureTabHelper::PrimaryPageChanged(content::Page&) {
  RootHelper()->Cancel();
  web_contents()->RemoveUserData(kGesturePracticeKey);
  ObserveFrames();
}

void MouseGestureTabHelper::InnerWebContentsAttached(
    content::WebContents* inner,
    content::RenderFrameHost*) {
  CreateForWebContents(inner);
}

// WebContents 先于部分 RenderWidget 销毁，必须在观察对象脱离前解除回调。
void MouseGestureTabHelper::WebContentsDestroyed() {
  DetachInput();
}

void MouseGestureTabHelper::OnVisibilityChanged(
    content::Visibility visibility) {
  if (visibility != content::Visibility::VISIBLE) {
    RootHelper()->Cancel();
  }
}

void MouseGestureTabHelper::OnWebContentsLostFocus(content::RenderWidgetHost*) {
  VLOG(1) << "鼠标手势取消：页面失焦";
  RootHelper()->Cancel();
}

void MouseGestureTabHelper::RenderWidgetHostDestroyed(
    content::RenderWidgetHost* host) {
  auto* root = RootHelper();
  if (root->origin_host_ == host) {
    root->Cancel();
    root->origin_host_ = nullptr;
  }
  const auto found = callbacks_.find(host);
  if (found != callbacks_.end()) {
    host->RemoveMouseEventCallback(found->second.mouse);
    host->RemoveKeyPressEventCallback(found->second.key);
    callbacks_.erase(found);
  }
  host_observations_.RemoveObservation(host);
}

void MouseGestureTabHelper::OnWidgetActivationChanged(views::Widget*,
                                                      bool active) {
  if (!active) {
    VLOG(1) << "鼠标手势取消：窗口失去激活";
    Cancel();
  }
}

void MouseGestureTabHelper::OnWidgetDestroyed(views::Widget*) {
  window_observation_.Reset();
  Cancel();
}

bool MouseGestureTabHelper::InPracticeRegion(
    const blink::WebMouseEvent& event) const {
  if (web_contents()->GetLastCommittedURL() !=
      GURL("chrome://aegis/gestures.html")) {
    return false;
  }
  const auto* region = static_cast<GesturePracticeRegion*>(
      web_contents()->GetUserData(kGesturePracticeKey));
  auto* view = web_contents()->GetRenderWidgetHostView();
  if (!region || !view || view->GetViewBounds().IsEmpty()) {
    return false;
  }
  const auto bounds = view->GetViewBounds();
  return region->Contains(
      (event.PositionInScreen().x() - bounds.x()) / bounds.width(),
      (event.PositionInScreen().y() - bounds.y()) / bounds.height());
}

bool MouseGestureTabHelper::OnMouse(content::RenderWidgetHost* host,
                                    content::WebContents* source,
                                    const blink::WebMouseEvent& event) {
  auto* root = RootHelper();
  if (root != this) {
    return root->OnMouse(host, source, event);
  }
  if (replaying_) {
    return false;
  }
  using Type = blink::WebInputEvent::Type;
  const bool right = event.button == blink::WebMouseEvent::Button::kRight;
  if (event.GetType() == Type::kMouseDown && right) {
    Cancel();
    pending_ = false;
    origin_host_ = nullptr;
    auto* prefs =
        Profile::FromBrowserContext(web_contents()->GetBrowserContext())
            ->GetPrefs();
    settings_ = GestureSettings::Parse(prefs->GetDict(kMouseGesturesPref))
                    .value_or(GestureSettings::Defaults());
    auto* view = host->GetView();
    auto* window = views::Widget::GetWidgetForNativeWindow(
        web_contents()->GetTopLevelNativeWindow());
    if (!settings_.EnabledFor(web_contents()->GetLastCommittedURL()) ||
        event.GetModifiers() & kBypassModifiers || !view ||
        view->IsPointerLocked() || !window || !window->IsActive() ||
        web_contents()->GetVisibility() != content::Visibility::VISIBLE ||
        InPracticeRegion(event)) {
      return false;
    }
    if (window_observation_.GetSource() != window) {
      window_observation_.Reset();
      window_observation_.Observe(window);
    }
    pending_ = true;
    origin_host_ = host;
    down_event_ = event;
    // 把动作绑定到按下时的文档；子框架导航后不能误作用于新页面。
    content::RenderFrameHost* target = nullptr;
    source->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
      if (!target && frame->GetRenderWidgetHost() == host) {
        target = frame;
      }
    });
    origin_document_ =
        (target ? target : source->GetPrimaryMainFrame())->GetWeakDocumentPtr();
    recognizer_.Start(event.PositionInScreen().x(),
                      event.PositionInScreen().y(), settings_.threshold);
    points_ = {event.PositionInScreen()};
    timeout_.Start(FROM_HERE, base::Seconds(10), this,
                   &MouseGestureTabHelper::Cancel);
    return true;
  }
  if (!pending_) {
    return false;
  }
  auto* content_view = web_contents()->GetRenderWidgetHostView();
  if (!content_view ||
      !content_view->GetViewBounds().Contains(
          gfx::ToRoundedPoint(event.PositionInScreen())) ||
      event.GetModifiers() & kBypassModifiers ||
      (event.GetType() == Type::kMouseDown && !right)) {
    Cancel();
  }
  if (event.GetType() == Type::kMouseMove) {
    // 丢失抬键或捕获时，不允许下一次移动继续执行旧手势。
    if (!(event.GetModifiers() & blink::WebInputEvent::kRightButtonDown)) {
      VLOG(1) << "鼠标手势取消：没有右键按下状态";
      Cancel();
      pending_ = false;
      origin_host_ = nullptr;
      return false;
    }
    recognizer_.Move(event.PositionInScreen().x(),
                     event.PositionInScreen().y());
    if (!recognizer_.cancelled() && recognizer_.moved()) {
      UpdateTrail(event.PositionInScreen());
    }
    return true;
  }
  if (event.GetType() != Type::kMouseUp || !right) {
    return false;
  }

  recognizer_.Move(event.PositionInScreen().x(), event.PositionInScreen().y());
  pending_ = false;
  timeout_.Stop();
  ClearTrail();
  auto* origin = origin_host_.get();
  origin_host_ = nullptr;
  if (!recognizer_.moved() && !recognizer_.cancelled() && origin) {
    // Windows 在抬键时、macOS 在按下时打开菜单；补发完整的一对事件。
    // 保持原始目标和位置，既能显示网页自定义菜单，也能显示 PDF 菜单。
    base::AutoReset<bool> replay(&replaying_, true);
    origin->ForwardMouseEvent(down_event_);
    blink::WebMouseEvent up = down_event_;
    up.SetType(Type::kMouseUp);
    up.SetModifiers(event.GetModifiers());
    up.SetTimeStamp(event.TimeStamp());
    origin->ForwardMouseEvent(up);
    return true;
  }
  const std::string action = settings_.ActionFor(recognizer_.Match());
  VLOG(1) << "鼠标手势结束：pattern=" << recognizer_.directions()
          << " cancelled=" << recognizer_.cancelled() << " action=" << action;
  if (action.empty() || !origin) {
    return true;
  }
  if (!origin_document_.AsRenderFrameHostIfValid()) {
    return true;
  }
  // 关闭标签和切换窗口延后执行，避免销毁当前事件回调正在遍历的对象。
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          &MouseGestureTabHelper::Execute, weak_factory_.GetWeakPtr(), action,
          web_contents()->GetPrimaryMainFrame()->GetWeakDocumentPtr(),
          origin_document_, down_event_));
  return true;
}

bool MouseGestureTabHelper::OnKey(const input::NativeWebKeyboardEvent& event) {
  auto* root = RootHelper();
  if (event.windows_key_code != ui::VKEY_ESCAPE || !root->pending_) {
    return false;
  }
  root->Cancel();
  return true;
}

void MouseGestureTabHelper::Cancel() {
  recognizer_.Cancel();
  timeout_.Stop();
  ClearTrail();
}

void MouseGestureTabHelper::ClearTrail() {
  trail_view_ = nullptr;
  trail_widget_.reset();
  points_.clear();
}

void MouseGestureTabHelper::UpdateTrail(const gfx::PointF& point) {
  if (!settings_.show_trail) {
    return;
  }
  auto* contents_view = web_contents()->GetRenderWidgetHostView();
  if (!contents_view) {
    return;
  }
  const gfx::Rect bounds = contents_view->GetViewBounds();
  // 有界采样；长笔画不会持续分配内存。
  if (points_.size() >= 256) {
    std::vector<gfx::PointF> reduced;
    for (size_t i = 0; i < points_.size(); i += 2) {
      reduced.push_back(points_[i]);
    }
    points_ = std::move(reduced);
  }
  points_.push_back(point);
  if (!trail_widget_) {
    views::Widget::InitParams params(
        views::Widget::InitParams::CLIENT_OWNS_WIDGET,
        views::Widget::InitParams::TYPE_POPUP);
    params.name = "AegisMouseGestureTrail";
    params.SetParent(web_contents()->GetNativeView());
    params.accept_events = false;
    params.activatable = views::Widget::InitParams::Activatable::kNo;
    params.opacity = views::Widget::InitParams::WindowOpacity::kTranslucent;
    params.shadow_type = views::Widget::InitParams::ShadowType::kNone;
    params.bounds = bounds;
    trail_widget_ = std::make_unique<views::Widget>();
    trail_widget_->Init(std::move(params));
    trail_view_ =
        trail_widget_->SetContentsView(std::make_unique<GestureTrailView>());
    trail_widget_->ShowInactive();
  }
  std::vector<gfx::PointF> local;
  for (const auto& p : points_) {
    local.emplace_back(p.x() - bounds.x(), p.y() - bounds.y());
  }
  const auto* action =
      FindGestureAction(settings_.ActionFor(recognizer_.Match()));
  const std::u16string label =
      PatternLabel(recognizer_.directions()) +
      (action ? base::UTF8ToUTF16(action->label) : u"未匹配，不执行") +
      u"  ·  Esc 取消";
  trail_view_->Update(std::move(local), label);
}

void MouseGestureTabHelper::Execute(std::string action,
                                    content::WeakDocumentPtr document,
                                    content::WeakDocumentPtr target_document,
                                    blink::WebMouseEvent start) {
  auto* browser = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(
      web_contents());
  auto* target = target_document.AsRenderFrameHostIfValid();
  VLOG(1) << "鼠标手势执行检查：browser=" << !!browser << " target=" << !!target
          << " document=" << !!document.AsRenderFrameHostIfValid();
  if (!document.AsRenderFrameHostIfValid() || !browser || !target ||
      browser->GetTabStripModel()->GetActiveWebContents() != web_contents() ||
      !window_observation_.IsObserving() ||
      !window_observation_.GetSource()->IsActive()) {
    return;
  }
  int command = 0;
  if (action == "back") {
    command = IDC_BACK;
  } else if (action == "forward") {
    command = IDC_FORWARD;
  } else if (action == "reload") {
    command = IDC_RELOAD;
  } else if (action == "close_tab") {
    command = IDC_CLOSE_TAB;
  } else if (action == "restore_tab") {
    command = IDC_RESTORE_TAB;
  } else if (action == "previous_tab") {
    command = IDC_SELECT_PREVIOUS_TAB;
  } else if (action == "next_tab") {
    command = IDC_SELECT_NEXT_TAB;
  }
  if (command) {
    if (chrome::IsCommandEnabled(browser, command)) {
      chrome::ExecuteCommand(browser, command);
    }
    return;
  }
  if (action == "scroll_up" || action == "scroll_down") {
    // 定位手势起点下的滚动容器，兼容设置页 Shadow DOM 与 PDF 阅读区。
    blink::WebMouseWheelEvent wheel(blink::WebInputEvent::Type::kMouseWheel, 0,
                                    base::TimeTicks::Now());
    wheel.SetPositionInWidget(start.PositionInWidget());
    wheel.SetPositionInScreen(start.PositionInScreen());
    wheel.delta_y = action == "scroll_up" ? 520 : -520;
    wheel.wheel_ticks_y = wheel.delta_y / 120;
    wheel.delta_units = ui::ScrollGranularity::kScrollByPrecisePixel;
    wheel.phase = blink::WebMouseWheelEvent::kPhaseBegan;
    target->GetRenderWidgetHost()->ForwardWheelEvent(wheel);
    wheel.delta_y = wheel.wheel_ticks_y = 0;
    wheel.phase = blink::WebMouseWheelEvent::kPhaseEnded;
    target->GetRenderWidgetHost()->ForwardWheelEvent(wheel);
    return;
  }
  const auto* definition = FindGestureAction(action);
  if (!definition || !definition->pdf_only) {
    return;
  }
  // 只向内置 PDF 查看器发送固定动作，普通页面得不到浏览器命令入口。
  content::RenderFrameHost* pdf = target;
  while (pdf && !IsPdfViewer(pdf)) {
    pdf = pdf->GetParentOrOuterDocument();
  }
  if (!pdf) {
    target->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
      if (!pdf && IsPdfViewer(frame)) {
        pdf = frame;
      }
    });
  }
  if (!pdf) {
    return;
  }
  pdf->ExecuteJavaScriptInIsolatedWorld(
      base::UTF8ToUTF16(
          "window.dispatchEvent(new CustomEvent('aegis-pdf-gesture',"
          "{detail:'" +
          action + "'}));"),
      base::NullCallback(), ISOLATED_WORLD_ID_CHROME_INTERNAL);
}

WEB_CONTENTS_USER_DATA_KEY_IMPL(MouseGestureTabHelper);
}  // namespace aegis
