// Copyright 2026 GCSA
#include "base/run_loop.h"
#include "base/test/run_until.h"
#include "base/time/time.h"
#include "chrome/browser/aegis/gestures/gesture_settings.h"
#include "chrome/browser/pdf/pdf_extension_test_base.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/context_menu_interceptor.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "ui/base/base_window.h"
#include "ui/base/test/ui_controls.h"
#include "ui/events/keycodes/dom/dom_code.h"
#include "ui/events/keycodes/dom/dom_key.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/geometry/point.h"
#include "ui/views/widget/widget.h"

namespace aegis {
namespace {
using Type = blink::WebInputEvent::Type;
using Button = blink::WebMouseEvent::Button;

void Mouse(content::RenderWidgetHost* host,
           Type type,
           gfx::Point point,
           Button button = Button::kRight,
           int extra_modifiers = 0) {
  const gfx::Rect bounds = host->GetView()->GetViewBounds();
  auto* widget = views::Widget::GetTopLevelWidgetForNativeView(
      host->GetView()->GetNativeView());
  ASSERT_TRUE(widget);
  const auto window = widget->GetNativeWindow();
  base::RunLoop move;
  ASSERT_TRUE(ui_controls::SendMouseMoveNotifyWhenDone(
      point.x() + bounds.x(), point.y() + bounds.y(), move.QuitClosure(),
      window));
  move.Run();
  if (type == Type::kMouseDown || type == Type::kMouseUp) {
    base::RunLoop click;
    ASSERT_TRUE(ui_controls::SendMouseEventsNotifyWhenDone(
        button == Button::kRight ? ui_controls::RIGHT : ui_controls::LEFT,
        type == Type::kMouseDown ? ui_controls::DOWN : ui_controls::UP,
        click.QuitClosure(),
        extra_modifiers & blink::WebInputEvent::kShiftKey
            ? ui_controls::kShift
            : ui_controls::kNoAccelerator));
    click.Run();
  }
  if (type != Type::kMouseUp) {
    content::RunUntilInputProcessed(host);
  }
}

void Gesture(content::RenderWidgetHost* host,
             const std::string& pattern,
             gfx::Point start = gfx::Point(250, 180),
             int modifiers = 0) {
  gfx::Point point = start;
  Mouse(host, Type::kMouseDown, point, Button::kRight, modifiers);
  for (char direction : pattern) {
    switch (direction) {
      case 'L':
        point.Offset(-60, 0);
        break;
      case 'R':
        point.Offset(60, 0);
        break;
      case 'U':
        point.Offset(0, -60);
        break;
      case 'D':
        point.Offset(0, 60);
        break;
    }
    Mouse(host, Type::kMouseMove, point, Button::kRight, modifiers);
  }
  Mouse(host, Type::kMouseUp, point, Button::kRight, modifiers);
  base::RunLoop().RunUntilIdle();
}

bool Activate(BrowserWindowInterface* browser) {
  browser->GetWindow()->Activate();
  return base::test::RunUntil([&] { return browser->GetWindow()->IsActive(); });
}
}  // namespace

class AegisGestureBrowserTest : public InProcessBrowserTest {
 protected:
  void SetUpOnMainThread() override {
    InProcessBrowserTest::SetUpOnMainThread();
    ASSERT_TRUE(embedded_test_server()->Start());
    ASSERT_TRUE(Activate(browser()));
  }
  content::WebContents* contents() {
    return browser()->GetTabStripModel()->GetActiveWebContents();
  }
  content::RenderWidgetHost* host() {
    return contents()->GetPrimaryMainFrame()->GetRenderWidgetHost();
  }
  void Navigate(const char* path) {
    ASSERT_TRUE(ui_test_utils::NavigateToURL(
        browser(), embedded_test_server()->GetURL(path)));
  }
  void SetSettings(GestureSettings settings) {
    browser()->GetProfile()->GetPrefs()->SetDict(kMouseGesturesPref,
                                                 settings.ToValue());
  }
};

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest, BackForwardOnWebPages) {
  Navigate("/title1.html");
  Navigate("/title2.html");
  Gesture(host(), "L");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents()->GetLastCommittedURL() ==
           embedded_test_server()->GetURL("/title1.html");
  }));
  Gesture(host(), "R");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents()->GetLastCommittedURL() ==
           embedded_test_server()->GetURL("/title2.html");
  }));
}

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest, RightClickKeepsContextMenu) {
  Navigate("/title1.html");
  content::ContextMenuInterceptor menu(
      contents()->GetPrimaryMainFrame(),
      content::ContextMenuInterceptor::kPreventShow);
  Mouse(host(), Type::kMouseDown, {100, 100});
  Mouse(host(), Type::kMouseMove, {103, 104});
  Mouse(host(), Type::kMouseUp, {103, 104});
  menu.Wait();
}

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest,
                       LeftClickAndSelectionUnchanged) {
  Navigate("/title1.html");
  ASSERT_TRUE(content::ExecJs(contents(), R"(
    document.body.innerHTML = '<button id="target" style="position:absolute;left:50px;top:50px;width:150px;height:100px">选择与点击</button>';
    window.clicks = 0;
    document.getElementById('target').onclick = () => ++window.clicks;
  )"));
  Mouse(host(), Type::kMouseDown, {90, 80}, Button::kLeft);
  Mouse(host(), Type::kMouseUp, {90, 80}, Button::kLeft);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(contents(), "window.clicks").ExtractInt() == 1;
  }));
  ASSERT_TRUE(content::ExecJs(contents(), R"(
    document.body.innerHTML = '<p style="position:absolute;left:50px;top:80px;margin:0;font:20px monospace">selection remains available</p>';
  )"));
  Mouse(host(), Type::kMouseDown, {51, 90}, Button::kLeft);
  Mouse(host(), Type::kMouseMove, {230, 90}, Button::kLeft);
  Mouse(host(), Type::kMouseUp, {230, 90}, Button::kLeft);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(contents(), "getSelection().toString().length > 0")
        .ExtractBool();
  }));
}

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest, ScrollReloadAndTabActions) {
  Navigate("/title1.html");
  ASSERT_TRUE(content::ExecJs(
      contents(),
      "document.body.style.height='5000px'; window.marker='before reload';"));
  Gesture(host(), "D");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(contents(), "scrollY > 0").ExtractBool();
  }));
  Gesture(host(), "U");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(contents(), "scrollY === 0").ExtractBool();
  }));
  Gesture(host(), "UD");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !contents()->IsLoading() &&
           content::EvalJs(contents(), "typeof window.marker === 'undefined'")
               .ExtractBool();
  }));
  ui_test_utils::NavigateToURLWithDisposition(
      browser(), embedded_test_server()->GetURL("/title2.html"),
      WindowOpenDisposition::NEW_FOREGROUND_TAB,
      ui_test_utils::BROWSER_TEST_WAIT_FOR_LOAD_STOP);
  ASSERT_EQ(2, browser()->GetTabStripModel()->count());
  Gesture(host(), "UL");
  ASSERT_EQ(0, browser()->GetTabStripModel()->active_index());
  Gesture(host(), "UR");
  ASSERT_EQ(1, browser()->GetTabStripModel()->active_index());
  Gesture(host(), "DR");
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return browser()->GetTabStripModel()->count() == 1; }));
  Gesture(host(), "DL");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return browser()->GetTabStripModel()->count() == 2 &&
           contents()->GetLastCommittedURL() ==
               embedded_test_server()->GetURL("/title2.html");
  }));
}

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest, OutsideAndNavigationCancel) {
  Navigate("/title1.html");
  auto settings = GestureSettings::Defaults();
  settings.show_trail = false;
  SetSettings(settings);
  Mouse(host(), Type::kMouseDown, {200, 160});
  Mouse(host(), Type::kMouseMove, {200, 220});
  Mouse(host(), Type::kMouseMove, {260, 220});
  Mouse(host(), Type::kMouseMove, {-10, 220});
  Mouse(host(), Type::kMouseUp, {260, 220});
  base::RunLoop().RunUntilIdle();
  ASSERT_EQ(1, browser()->GetTabStripModel()->count());
  Mouse(host(), Type::kMouseDown, {200, 160});
  Mouse(host(), Type::kMouseMove, {200, 220});
  Navigate("/title2.html");
  Mouse(host(), Type::kMouseMove, {260, 220});
  Mouse(host(), Type::kMouseUp, {260, 220});
  base::RunLoop().RunUntilIdle();
  ASSERT_EQ(1, browser()->GetTabStripModel()->count());
  EXPECT_EQ(contents()->GetLastCommittedURL(),
            embedded_test_server()->GetURL("/title2.html"));
}

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest,
                       EscapeCancelsCloseAndNextGestureWorks) {
  Navigate("/title1.html");
  const int count = browser()->GetTabStripModel()->count();
  Mouse(host(), Type::kMouseDown, {200, 160});
  Mouse(host(), Type::kMouseMove, {200, 220});
  Mouse(host(), Type::kMouseMove, {260, 220});
  // 通用 JS 按键助手设置 skip_if_unhandled，会跳过原生监听器。
  input::NativeWebKeyboardEvent escape(Type::kRawKeyDown, 0,
                                       base::TimeTicks::Now());
  escape.windows_key_code = ui::VKEY_ESCAPE;
  escape.dom_key = ui::DomKey::ESCAPE;
  escape.dom_code = static_cast<int>(ui::DomCode::ESCAPE);
  escape.skip_if_unhandled = false;
  host()->ForwardKeyboardEvent(escape);
  Mouse(host(), Type::kMouseUp, {260, 220});
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(browser()->GetTabStripModel()->count(), count);
  Navigate("/title2.html");
  Gesture(host(), "L");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents()->GetLastCommittedURL() ==
           embedded_test_server()->GetURL("/title1.html");
  }));
}

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest,
                       SiteExclusionAndModifierBypass) {
  Navigate("/title1.html");
  Navigate("/title2.html");
  ASSERT_TRUE(content::ExecJs(
      contents(),
      "window.addEventListener('contextmenu', e => e.preventDefault());"));
  auto settings = GestureSettings::Defaults();
  settings.disabled_sites.emplace_back(
      contents()->GetLastCommittedURL().host());
  SetSettings(settings);
  Gesture(host(), "L");
  EXPECT_EQ(contents()->GetLastCommittedURL(),
            embedded_test_server()->GetURL("/title2.html"));
  SetSettings(GestureSettings::Defaults());
  Gesture(host(), "L", {250, 180}, blink::WebInputEvent::kShiftKey);
  EXPECT_EQ(contents()->GetLastCommittedURL(),
            embedded_test_server()->GetURL("/title2.html"));
}

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest, SettingsPageAndPracticeSafety) {
  Navigate("/title1.html");
  ASSERT_TRUE(
      ui_test_utils::NavigateToURL(browser(), GURL("chrome://settings/")));
  Gesture(host(), "L");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents()->GetLastCommittedURL() ==
           embedded_test_server()->GetURL("/title1.html");
  }));
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), GURL("chrome://aegis/gestures.html")));
  ASSERT_EQ("设置已加载", content::EvalJs(contents(), R"(
    new Promise(resolve => {
      const status = document.getElementById('status');
      if (status.textContent === '设置已加载') { resolve(status.textContent); return; }
      new MutationObserver(() => {
        if (status.textContent === '设置已加载') resolve(status.textContent);
      }).observe(status, {childList:true, subtree:true});
    })
  )"));
  // 练习区里的“关闭标签”必须只显示提示。
  const auto region = content::EvalJs(contents(), R"(
    document.getElementById('practice').scrollIntoView({block:'center'});
    new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => {
      const rect = document.getElementById('practice').getBoundingClientRect();
      resolve([Math.round(rect.left + 130), Math.round(rect.top + 45)]);
    })));
  )")
                          .ExtractList()
                          .Clone();
  const int count = browser()->GetTabStripModel()->count();
  Gesture(host(), "DR", {region[0].GetInt(), region[1].GetInt()});
  EXPECT_EQ(count, browser()->GetTabStripModel()->count());
  EXPECT_EQ(GURL("chrome://aegis/gestures.html"),
            contents()->GetLastCommittedURL());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(contents(),
                           "document.getElementById('practiceResult')."
                           "textContent.includes('练习不执行')")
        .ExtractBool();
  }))
      << content::EvalJs(
             contents(),
             "document.getElementById('practiceResult').textContent");
}

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest,
                       WebUiSavesAndRejectsInvalidConfig) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), GURL("chrome://aegis/gestures.html")));
  EXPECT_EQ(false, content::EvalJs(contents(), R"(
    (async () => {
      const {sendWithPromise} = await import('chrome://resources/js/cr.js');
      const data = await sendWithPromise('aegisGetGestureSettings');
      data.settings.enabled = false;
      const saved = await sendWithPromise('aegisSaveGestureSettings', data.settings);
      return saved.settings.enabled;
    })()
  )"));
  EXPECT_FALSE(browser()
                   ->GetProfile()
                   ->GetPrefs()
                   ->GetDict(kMouseGesturesPref)
                   .FindBool("enabled")
                   .value_or(true));
  EXPECT_EQ("rejected", content::EvalJs(contents(), R"(
    (async () => {
      const {sendWithPromise} = await import('chrome://resources/js/cr.js');
      const data = await sendWithPromise('aegisGetGestureSettings');
      data.settings.bindings.L = 'execute_javascript';
      try { await sendWithPromise('aegisSaveGestureSettings', data.settings); }
      catch { return 'rejected'; }
      return 'incorrectly accepted';
    })()
  )"));
  EXPECT_FALSE(browser()
                   ->GetProfile()
                   ->GetPrefs()
                   ->GetDict(kMouseGesturesPref)
                   .FindBool("enabled")
                   .value_or(true));
}

IN_PROC_BROWSER_TEST_F(AegisGestureBrowserTest,
                       CrossFrameAndFocusCancellation) {
  Navigate("/title1.html");
  Navigate("/title2.html");
  auto add_frame = [&] {
    return content::ExecJs(
        contents(), content::JsReplace(R"(
      new Promise(resolve => {
        const frame = document.createElement('iframe');
        frame.style.cssText = 'position:absolute;left:30px;top:30px;width:480px;height:320px';
        frame.onload = () => resolve(true);
        frame.src = $1;
        document.body.appendChild(frame);
      });
    )",
                                       embedded_test_server()->GetURL(
                                           "localhost", "/title1.html")));
  };
  ASSERT_TRUE(add_frame());
  auto* frame = content::ChildFrameAt(contents()->GetPrimaryMainFrame(), 0);
  ASSERT_TRUE(frame);
  ASSERT_NE(frame->GetProcess(),
            contents()->GetPrimaryMainFrame()->GetProcess());
  Gesture(frame->GetRenderWidgetHost(), "L");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents()->GetLastCommittedURL() ==
           embedded_test_server()->GetURL("/title1.html");
  }));
  Navigate("/title2.html");
  ASSERT_TRUE(add_frame());
  frame = content::ChildFrameAt(contents()->GetPrimaryMainFrame(), 0);
  Mouse(host(), Type::kMouseDown, {650, 180});
  Mouse(host(), Type::kMouseMove, {590, 180});
  ASSERT_TRUE(content::NavigateToURLFromRenderer(
      frame, embedded_test_server()->GetURL("localhost", "/title2.html")));
  Mouse(host(), Type::kMouseUp, {590, 180});
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(contents()->GetLastCommittedURL(),
            embedded_test_server()->GetURL("/title2.html"));
  Mouse(host(), Type::kMouseDown, {650, 180});
  Mouse(host(), Type::kMouseMove, {590, 180});
  auto* other = CreateBrowser(browser()->GetProfile());
  ASSERT_TRUE(Activate(other));
  ASSERT_TRUE(Activate(browser()));
  Mouse(host(), Type::kMouseUp, {590, 180});
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(contents()->GetLastCommittedURL(),
            embedded_test_server()->GetURL("/title2.html"));
  CloseBrowserSynchronously(other);
}

class AegisGesturePdfTest : public PDFExtensionTestBase,
                            public testing::WithParamInterface<bool> {
 protected:
  bool UseOopif() const override { return GetParam(); }
};
INSTANTIATE_TEST_SUITE_P(AllPdfModes, AegisGesturePdfTest, testing::Bool());

IN_PROC_BROWSER_TEST_P(AegisGesturePdfTest, PdfPagesFitAndGenericBack) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(Activate(browser()));
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/title1.html")));
  auto* pdf = LoadPdfGetExtensionHost(
      embedded_test_server()->GetURL("/pdf/accessibility/multi-page.pdf"));
  ASSERT_TRUE(pdf);
  ASSERT_GT(
      content::EvalJs(pdf, "document.querySelector('pdf-viewer').docLength_")
          .ExtractInt(),
      1);
  auto settings = GestureSettings::Defaults();
  settings.bindings["R"] = "pdf_next";
  settings.bindings["RL"] = "pdf_previous";
  settings.bindings["D"] = "pdf_width";
  settings.bindings["U"] = "pdf_page";
  browser()->GetProfile()->GetPrefs()->SetDict(kMouseGesturesPref,
                                               settings.ToValue());
  ASSERT_TRUE(content::ExecJs(pdf, R"(
    window.aegisLastGesture = '';
    window.addEventListener('aegis-pdf-gesture', e => window.aegisLastGesture = e.detail);
  )"));
  auto* host = pdf->GetRenderWidgetHost();
  // 小幅 PDF 可能同时完整显示两页，先以整页模式建立可翻动的视口。
  Gesture(host, "U");
  ASSERT_EQ(
      "fit-to-page",
      content::EvalJs(
          pdf, "document.querySelector('pdf-viewer').viewport.fittingType"));
  ASSERT_TRUE(content::ExecJs(
      pdf, "document.querySelector('pdf-viewer').viewport.goToPage(0)"));
  Gesture(host, "R");
  EXPECT_EQ("pdf_next", content::EvalJs(pdf, "window.aegisLastGesture"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(pdf,
                           "document.querySelector('pdf-viewer').viewport."
                           "getMostVisiblePage()")
               .ExtractInt() == 1;
  }));
  Gesture(host, "R");
  EXPECT_EQ(1, content::EvalJs(pdf,
                               "document.querySelector('pdf-viewer').viewport."
                               "getMostVisiblePage()"));
  Gesture(host, "RL");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(pdf,
                           "document.querySelector('pdf-viewer').viewport."
                           "getMostVisiblePage()")
               .ExtractInt() == 0;
  }));
  Gesture(host, "D");
  EXPECT_EQ(
      "fit-to-width",
      content::EvalJs(
          pdf, "document.querySelector('pdf-viewer').viewport.fittingType"));
  Gesture(host, "U");
  EXPECT_EQ(
      "fit-to-page",
      content::EvalJs(
          pdf, "document.querySelector('pdf-viewer').viewport.fittingType"));
  Gesture(host, "L");
  ASSERT_TRUE(base::test::RunUntil([&] {
    return GetActiveWebContents()->GetLastCommittedURL() ==
           embedded_test_server()->GetURL("/title1.html");
  }));
}
}  // namespace aegis
