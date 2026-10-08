// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_UI_AEGIS_MOUSE_GESTURE_TAB_HELPER_H_
#define CHROME_BROWSER_UI_AEGIS_MOUSE_GESTURE_TAB_HELPER_H_

#include <map>
#include <memory>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_multi_source_observation.h"
#include "base/scoped_observation.h"
#include "base/timer/timer.h"
#include "chrome/browser/aegis/gestures/gesture_recognizer.h"
#include "chrome/browser/aegis/gestures/gesture_settings.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_observer.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "ui/views/widget/widget_observer.h"

namespace content {
class WeakDocumentPtr;
}
namespace views {
class Widget;
}

namespace aegis {
class GestureTrailView;

// 在输入发往渲染进程前识别；同一标签中的子框架与 PDF 共用一次手势。
class MouseGestureTabHelper
    : public content::WebContentsObserver,
      public content::WebContentsUserData<MouseGestureTabHelper>,
      public content::RenderWidgetHostObserver,
      public views::WidgetObserver {
 public:
  ~MouseGestureTabHelper() override;
  MouseGestureTabHelper(const MouseGestureTabHelper&) = delete;
  MouseGestureTabHelper& operator=(const MouseGestureTabHelper&) = delete;

  void RenderFrameCreated(content::RenderFrameHost* frame) override;
  void DidStartNavigation(content::NavigationHandle* navigation) override;
  void PrimaryPageChanged(content::Page& page) override;
  void InnerWebContentsAttached(content::WebContents* inner,
                                content::RenderFrameHost* frame) override;
  void WebContentsDestroyed() override;
  void OnVisibilityChanged(content::Visibility visibility) override;
  void OnWebContentsLostFocus(content::RenderWidgetHost* host) override;
  void RenderWidgetHostDestroyed(content::RenderWidgetHost* host) override;
  void OnWidgetActivationChanged(views::Widget* widget, bool active) override;
  void OnWidgetDestroyed(views::Widget* widget) override;

 private:
  friend class content::WebContentsUserData<MouseGestureTabHelper>;
  explicit MouseGestureTabHelper(content::WebContents* contents);
  void DetachInput();
  void ObserveFrames();
  void Attach(content::RenderWidgetHost* host);
  MouseGestureTabHelper* RootHelper();
  bool OnMouse(content::RenderWidgetHost* host,
               content::WebContents* source,
               const blink::WebMouseEvent& event);
  bool OnKey(const input::NativeWebKeyboardEvent& event);
  void Cancel();
  void ClearTrail();
  void UpdateTrail(const gfx::PointF& point);
  void Execute(std::string action,
               content::WeakDocumentPtr document,
               content::WeakDocumentPtr target,
               blink::WebMouseEvent start);
  bool InPracticeRegion(const blink::WebMouseEvent& event) const;

  struct Callbacks {
    content::RenderWidgetHost::MouseEventCallback mouse;
    content::RenderWidgetHost::KeyPressEventCallback key;
  };
  std::map<content::RenderWidgetHost*, Callbacks> callbacks_;
  base::ScopedMultiSourceObservation<content::RenderWidgetHost,
                                     content::RenderWidgetHostObserver>
      host_observations_{this};
  base::ScopedObservation<views::Widget, views::WidgetObserver>
      window_observation_{this};
  GestureRecognizer recognizer_;
  GestureSettings settings_;
  bool pending_ = false;
  bool replaying_ = false;
  raw_ptr<content::RenderWidgetHost> origin_host_ = nullptr;
  blink::WebMouseEvent down_event_;
  content::WeakDocumentPtr origin_document_;
  base::OneShotTimer timeout_;
  std::vector<gfx::PointF> points_;
  std::unique_ptr<views::Widget> trail_widget_;
  raw_ptr<GestureTrailView> trail_view_ = nullptr;
  base::WeakPtrFactory<MouseGestureTabHelper> weak_factory_{this};
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};
}  // namespace aegis
#endif
