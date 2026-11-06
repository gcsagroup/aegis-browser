// Copyright 2026 The GCSA Aegis Authors
// 轻量原生安装展示：品牌、阶段、活动条分层；不执行安装或依赖 CRT。
#include "chrome/installer/mini_installer/aegis_install_ui.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <objidl.h>
#include <windowsx.h>

// GDI+ 的图像接口依赖 objidl 中的 COM 类型，必须在其后包含。
#include <gdiplus.h>

#include "chrome/installer/mini_installer/mini_installer_resource.h"

namespace mini_installer {
namespace {
constexpr UINT kFinished = WM_APP + 2;
// setup 的稳定退出码 installer::EXISTING_VERSION_LAUNCHED；避免引入 util/CRT 依赖。
constexpr DWORD kExistingVersionLaunched = 3;
constexpr UINT kProgress = WM_APP + 3;
constexpr UINT_PTR kCloseTimer = 1;
constexpr UINT_PTR kAnimationTimer = 2;
constexpr int kWidth = 640;
constexpr int kHeight = 400;
constexpr COLORREF kInk = RGB(23, 36, 54);
constexpr COLORREF kMuted = RGB(102, 116, 134);
constexpr COLORREF kAccent = RGB(0, 128, 160);
constexpr COLORREF kTrack = RGB(231, 238, 244);
constexpr COLORREF kError = RGB(176, 55, 49);
constexpr wchar_t kWindowClass[] = L"GCSAAegisInstallProgress";
constexpr wchar_t kTitle[] = L"GCSA Aegis 安装程序";

// 使用系统 GDI+ 抗锯齿；资源不足时退回 GDI，不影响安装或文字可读性。
// 图形对象在本次绘制内释放，文字仍使用 ClearType，不缩放整块位图。
void FillRounded(HDC dc, const RECT& rect, int radius, COLORREF color) {
  using namespace Gdiplus;
  using namespace Gdiplus::DllExports;
  if (rect.right <= rect.left || rect.bottom <= rect.top)
    return;
  GpGraphics* graphics = nullptr;
  GpPath* path = nullptr;
  GpSolidFill* brush = nullptr;
  ARGB argb = 0xff000000u | (GetRValue(color) << 16) | (GetGValue(color) << 8) |
              GetBValue(color);
  bool painted = false;
  if (GdipCreateFromHDC(dc, &graphics) == Ok &&
      GdipCreatePath(FillModeWinding, &path) == Ok &&
      GdipCreateSolidFill(argb, &brush) == Ok) {
    REAL x = static_cast<REAL>(rect.left), y = static_cast<REAL>(rect.top);
    REAL w = static_cast<REAL>(rect.right - rect.left),
         h = static_cast<REAL>(rect.bottom - rect.top);
    REAL d = static_cast<REAL>(radius);
    if (d > w)
      d = w;
    if (d > h)
      d = h;
    GdipSetSmoothingMode(graphics, SmoothingModeAntiAlias);
    GdipSetPixelOffsetMode(graphics, PixelOffsetModeHalf);
    if (GdipAddPathArc(path, x, y, d, d, 180, 90) == Ok &&
        GdipAddPathArc(path, x + w - d, y, d, d, 270, 90) == Ok &&
        GdipAddPathArc(path, x + w - d, y + h - d, d, d, 0, 90) == Ok &&
        GdipAddPathArc(path, x, y + h - d, d, d, 90, 90) == Ok &&
        GdipClosePathFigure(path) == Ok)
      painted = GdipFillPath(graphics, brush, path) == Ok;
  }
  if (brush)
    GdipDeleteBrush(brush);
  if (path)
    GdipDeletePath(path);
  if (graphics)
    GdipDeleteGraphics(graphics);
  if (painted)
    return;
  ::SelectObject(dc, ::GetStockObject(DC_BRUSH));
  ::SelectObject(dc, ::GetStockObject(NULL_PEN));
  ::SetDCBrushColor(dc, color);
  ::RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius, radius);
}
}  // namespace

AegisInstallUi::AegisInstallUi(bool interactive) : interactive_(interactive) {
  if (!interactive_)
    return;
  ready_ = ::CreateEvent(nullptr, TRUE, FALSE, nullptr);
  if (ready_) {
    thread_ = ::CreateThread(nullptr, 0, ThreadMain, this, 0, nullptr);
    if (thread_)
      ::WaitForSingleObject(ready_, INFINITE);
  }
}

AegisInstallUi::~AegisInstallUi() {
  // 等待消息线程退出后才释放实例，禁止回调访问已销毁的状态。
  if (thread_) {
    ::WaitForSingleObject(thread_, INFINITE);
    ::CloseHandle(thread_);
  }
  if (ready_)
    ::CloseHandle(ready_);
}

void AegisInstallUi::Installing() {
  // setup 启动不等于进入文件提交阶段；真实解压观测到达前保留准备预算。
  UpdateProgress({aegis_installer::Phase::kPreparing, -1});
}

void AegisInstallUi::UpdateProgress(aegis_installer::Progress progress) {
  if (window_)
    ::PostMessage(window_, kProgress, static_cast<WPARAM>(progress.phase),
                  static_cast<LPARAM>(progress.percent));
}

void AegisInstallUi::Finish(DWORD exit_code) {
  if (window_) {
    ::PostMessage(window_, kFinished, exit_code, 0);
  } else if (interactive_ && exit_code != 0 &&
             exit_code != kExistingVersionLaunched) {
    // 窗口创建失败也不能把安装失败变成无声退出；不改变安装器原有退出码。
    ::MessageBox(nullptr, L"安装未完成，请重新运行安装程序。", kTitle,
                 MB_OK | MB_ICONERROR);
  }
}

int AegisInstallUi::Scale(int value) const {
  return ::MulDiv(value, static_cast<int>(dpi_), 96);
}

void AegisInstallUi::CreateControls() {
  // 正文仅两处可访问文本：品牌名与一行真实状态，不叠加宣传或重复说明。
  auto label = [this](const wchar_t* value) {
    return ::CreateWindow(L"STATIC", value,
                          WS_CHILD | WS_VISIBLE | SS_CENTER | SS_NOPREFIX, 0, 0,
                          0, 0, window_, nullptr, nullptr, nullptr);
  };
  logo_ = ::CreateWindow(L"STATIC", nullptr, WS_CHILD | WS_VISIBLE | SS_ICON, 0,
                         0, 0, 0, window_, nullptr, nullptr, nullptr);
  title_ = label(L"GCSA Aegis");
  status_ = label(L"正在安装  0%");
  progress_ = ::CreateWindow(PROGRESS_CLASS, nullptr, WS_CHILD | WS_VISIBLE, 0,
                             0, 0, 0, window_, nullptr, nullptr, nullptr);
  ::SetWindowSubclass(progress_, ProgressProc, 1,
                      reinterpret_cast<DWORD_PTR>(this));
  // 正常安装和成功态没有窗口按钮；失败时才出现可键盘操作的关闭入口。
  close_ = ::CreateWindow(
      L"BUTTON", L"关闭", WS_CHILD | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 0, 0,
      window_, reinterpret_cast<HMENU>(IDOK), nullptr, nullptr);
  ::SetWindowSubclass(close_, CloseButtonProc, 1,
                      reinterpret_cast<DWORD_PTR>(this));
  LayoutControls();
  UpdateAppearance();
  UpdateFrame();
}

void AegisInstallUi::LayoutControls() {
  auto move = [this](HWND control, int x, int y, int width, int height) {
    ::SetWindowPos(control, nullptr, Scale(x), Scale(y), Scale(width),
                   Scale(height), SWP_NOZORDER | SWP_NOACTIVATE);
  };
  move(logo_, 280, 62, 80, 80);
  move(title_, 40, 164, 560, 48);
  move(progress_, 96, 280, 448, 4);
  move(status_, 60, 308, 520, 28);
  move(close_, 264, 344, 112, 40);

  // 先替换字体、图标再释放旧资源；低资源时沿用原资源保持可读。
  auto font = [this](HFONT* target, int size, int weight, const wchar_t* face) {
    HFONT replacement =
        ::CreateFont(Scale(-size), 0, 0, 0, weight, FALSE, FALSE, FALSE,
                     DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                     CLEARTYPE_QUALITY, DEFAULT_PITCH, face);
    HFONT previous = replacement ? *target : nullptr;
    if (replacement)
      *target = replacement;
    return previous;
  };
  HFONT old_title = font(&title_font_, 34, FW_SEMIBOLD, L"Segoe UI");
  HFONT old_body = font(&font_, 14, FW_NORMAL, L"Microsoft YaHei UI");
  ::SendMessage(title_, WM_SETFONT, reinterpret_cast<WPARAM>(title_font_),
                TRUE);
  ::SendMessage(status_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
  ::SendMessage(close_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
  if (old_title)
    ::DeleteObject(old_title);
  if (old_body)
    ::DeleteObject(old_body);
  HICON replacement = nullptr;
  // 非标准尺寸从较大图标缩小，避免 80px 品牌图标被低分辨率资源放大模糊。
  ::LoadIconWithScaleDown(::GetModuleHandle(nullptr),
                          MAKEINTRESOURCE(IDI_MINI_INSTALLER), Scale(80),
                          Scale(80), &replacement);
  if (replacement) {
    ::SendMessage(logo_, STM_SETICON, reinterpret_cast<WPARAM>(replacement), 0);
    if (logo_icon_)
      ::DestroyIcon(logo_icon_);
    logo_icon_ = replacement;
  }
}

void AegisInstallUi::UpdateFrame() {
  // 窗口不带系统边框样式，仅请求 DWM 圆角和阴影；不能用 THICKFRAME 模拟无边框。
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
  HRESULT rounded = ::DwmSetWindowAttribute(
      window_, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));
  MARGINS margins = {1, 1, 1, 1};
  ::DwmExtendFrameIntoClientArea(window_, &margins);
  COLORREF border =
      high_contrast_ ? ::GetSysColor(COLOR_WINDOWTEXT) : DWMWA_COLOR_NONE;
  ::DwmSetWindowAttribute(window_, DWMWA_BORDER_COLOR, &border, sizeof(border));
  if (FAILED(rounded)) {
    RECT bounds;
    ::GetWindowRect(window_, &bounds);
    HRGN region = ::CreateRoundRectRgn(0, 0, bounds.right - bounds.left + 1,
                                       bounds.bottom - bounds.top + 1,
                                       Scale(18), Scale(18));
    if (region && !::SetWindowRgn(window_, region, TRUE))
      ::DeleteObject(region);
  }
}

void AegisInstallUi::ShowProgress(aegis_installer::Progress progress) {
  if (complete_)
    return;
  overall_progress_.Update(progress, ::GetTickCount64());
  RefreshProgress();
}

void AegisInstallUi::RefreshProgress() {
  if (complete_)
    return;
  // 阶段观测只校准目标值；动画/预估都不触发整窗背景擦除。
  if (overall_progress_.Advance(::GetTickCount64(), animate_))
    ::InvalidateRect(progress_, nullptr, FALSE);
  int percent = overall_progress_.percent();
  bool rolling_back = overall_progress_.rolling_back();
  if (percent == displayed_percent_ && rolling_back == displayed_rollback_)
    return;
  displayed_percent_ = percent;
  displayed_rollback_ = rolling_back;
  wchar_t value[80] = {};
  DWORD_PTR arguments[] = {
      reinterpret_cast<DWORD_PTR>(rolling_back ? L"正在回滚" : L"正在安装"),
      static_cast<DWORD_PTR>(percent)};
  ::FormatMessage(FORMAT_MESSAGE_FROM_STRING | FORMAT_MESSAGE_ARGUMENT_ARRAY,
                  L"%1!s!  %2!u!%%", 0, 0, value, _countof(value),
                  reinterpret_cast<va_list*>(arguments));
  ::SetWindowText(status_, value);
  // 原生控件保留可访问百分比；实际像素由本窗口的离屏帧绘制。
  ::SendMessage(progress_, PBM_SETPOS, percent, 0);
}

void AegisInstallUi::UpdateAppearance() {
  HIGHCONTRAST contrast = {sizeof(contrast)};
  high_contrast_ = ::SystemParametersInfo(SPI_GETHIGHCONTRAST, sizeof(contrast),
                                          &contrast, 0) &&
                   (contrast.dwFlags & HCF_HIGHCONTRASTON);
  BOOL animations = TRUE;
  ::SystemParametersInfo(SPI_GETCLIENTAREAANIMATION, 0, &animations, 0);
  animate_ = animations != FALSE;
  ::KillTimer(window_, kAnimationTimer);
  // 系统外观只在初始化/设置变化时读取；关闭动画时跳过插值但保留整体估算。
  if (!complete_)
    ::SetTimer(window_, kAnimationTimer, animate_ ? 30 : 100, nullptr);
  ::RedrawWindow(window_, nullptr, nullptr,
                 RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
}

void AegisInstallUi::PaintProgress(HWND window) {
  PAINTSTRUCT paint;
  HDC dc = ::BeginPaint(window, &paint);
  RECT track;
  ::GetClientRect(window, &track);
  // 背景、轨道和前景先在内存绘完，再一次性提交，避免白底中间帧可见。
  // 缓冲仅有进度条大小；每帧释放，DPI 改变后不会复用错误尺寸的位图。
  HDC buffer = ::CreateCompatibleDC(dc);
  HBITMAP bitmap = buffer
                       ? ::CreateCompatibleBitmap(dc, track.right, track.bottom)
                       : nullptr;
  HGDIOBJ previous = bitmap ? ::SelectObject(buffer, bitmap) : nullptr;
  bool buffered = previous && previous != HGDI_ERROR;
  // 位图创建或选入失败均退回直接绘制，不能把空缓冲提交到窗口。
  DrawProgressFrame(buffered ? buffer : dc, track);
  if (buffered) {
    ::BitBlt(dc, 0, 0, track.right, track.bottom, buffer, 0, 0, SRCCOPY);
    ::SelectObject(buffer, previous);
  }
  if (bitmap)
    ::DeleteObject(bitmap);
  if (buffer)
    ::DeleteDC(buffer);
  ::EndPaint(window, &paint);
}

void AegisInstallUi::DrawProgressFrame(HDC dc, const RECT& track) {
  int saved = ::SaveDC(dc);
  ::FillRect(dc, &track,
             high_contrast_
                 ? ::GetSysColorBrush(COLOR_WINDOW)
                 : static_cast<HBRUSH>(::GetStockObject(WHITE_BRUSH)));
  FillRounded(dc, track, Scale(4),
              high_contrast_ ? ::GetSysColor(COLOR_WINDOWTEXT) : kTrack);
  if (!failed_) {
    RECT segment = track;
    int position = complete_ ? 10000 : overall_progress_.position();
    segment.right = track.left + (track.right - track.left) * position / 10000;
    FillRounded(dc, segment, Scale(4),
                high_contrast_ ? ::GetSysColor(COLOR_HIGHLIGHT) : kAccent);
  }
  ::RestoreDC(dc, saved);
}

void AegisInstallUi::PaintCloseButton(const DRAWITEMSTRUCT& item) {
  int saved = ::SaveDC(item.hDC);
  const bool focused =
      (item.itemState & ODS_FOCUS) && !(item.itemState & ODS_NOFOCUSRECT);
  const bool pressed = (item.itemState & ODS_SELECTED) != 0;
  COLORREF fill = pressed        ? RGB(0, 96, 126)
                  : close_hover_ ? RGB(0, 110, 141)
                  : focused      ? RGB(0, 116, 148)
                                 : kAccent;
  if (high_contrast_)
    fill = ::GetSysColor(COLOR_HIGHLIGHT);
  // 清空整个控件，不保留默认底纹或外圈；焦点使用内部颜色和下划线表示。
  ::FillRect(item.hDC, &item.rcItem,
             high_contrast_
                 ? ::GetSysColorBrush(COLOR_WINDOW)
                 : static_cast<HBRUSH>(::GetStockObject(WHITE_BRUSH)));
  RECT body = item.rcItem;
  ::InflateRect(&body, -Scale(2), -Scale(2));
  FillRounded(item.hDC, body, Scale(12), fill);
  ::SetBkMode(item.hDC, TRANSPARENT);
  ::SetTextColor(item.hDC, high_contrast_ ? ::GetSysColor(COLOR_HIGHLIGHTTEXT)
                                          : RGB(255, 255, 255));
  ::SelectObject(item.hDC, font_);
  ::DrawText(item.hDC, L"关闭", -1, &body,
             DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
  if (focused) {
    RECT marker = {body.left + (body.right - body.left - Scale(24)) / 2,
                   body.bottom - Scale(6), 0, body.bottom - Scale(5)};
    marker.right = marker.left + Scale(24);
    ::FillRect(item.hDC, &marker,
               high_contrast_
                   ? ::GetSysColorBrush(COLOR_HIGHLIGHTTEXT)
                   : static_cast<HBRUSH>(::GetStockObject(WHITE_BRUSH)));
  }
  ::RestoreDC(item.hDC, saved);
}

LRESULT CALLBACK AegisInstallUi::CloseButtonProc(HWND window,
                                                 UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam,
                                                 UINT_PTR subclass_id,
                                                 DWORD_PTR context) {
  auto* self = reinterpret_cast<AegisInstallUi*>(context);
  if (message == WM_MOUSEMOVE && !self->close_hover_) {
    self->close_hover_ = true;
    TRACKMOUSEEVENT tracking = {sizeof(tracking), TME_LEAVE, window, 0};
    ::TrackMouseEvent(&tracking);
    ::InvalidateRect(window, nullptr, FALSE);
  } else if (message == WM_MOUSELEAVE) {
    self->close_hover_ = false;
    ::InvalidateRect(window, nullptr, FALSE);
  } else if (message == WM_NCDESTROY) {
    ::RemoveWindowSubclass(window, CloseButtonProc, subclass_id);
  }
  return ::DefSubclassProc(window, message, wparam, lparam);
}

DWORD WINAPI AegisInstallUi::ThreadMain(void* context) {
  auto* self = static_cast<AegisInstallUi*>(context);
  self->overall_progress_ = AegisOverallProgress(::GetTickCount64());
  Gdiplus::GdiplusStartupInput graphics_input;
  // 只初始化系统绘图，不加载外部图像解码器；退出 UI 线程前统一释放。
  graphics_input.SuppressExternalCodecs = TRUE;
  Gdiplus::GdiplusStartup(&self->graphics_token_, &graphics_input, nullptr);
  // 每屏独立缩放字体、图标和间距，不让跨屏移动退化为整窗位图拉伸。
  ::SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  self->dpi_ = ::GetDpiForSystem();
  INITCOMMONCONTROLSEX controls = {sizeof(controls), ICC_PROGRESS_CLASS};
  ::InitCommonControlsEx(&controls);
  WNDCLASS wc = {};
  wc.style = CS_DROPSHADOW;
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = ::GetModuleHandle(nullptr);
  wc.hIcon = ::LoadIcon(wc.hInstance, MAKEINTRESOURCE(IDI_MINI_INSTALLER));
  wc.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kWindowClass;
  ::RegisterClass(&wc);
  // 父窗口擦背景时排除子控件，防止进度变化把品牌、文字和图标一同擦白。
  constexpr DWORD style = WS_POPUP | WS_CLIPCHILDREN;
  RECT bounds = {0, 0, self->Scale(kWidth), self->Scale(kHeight)};
  RECT work = {};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  self->window_ = ::CreateWindowEx(
      WS_EX_APPWINDOW, kWindowClass, kTitle, style,
      work.left + (work.right - work.left - (bounds.right - bounds.left)) / 2,
      work.top + (work.bottom - work.top - (bounds.bottom - bounds.top)) / 2,
      bounds.right - bounds.left, bounds.bottom - bounds.top, nullptr, nullptr,
      wc.hInstance, self);
  if (self->window_) {
    self->dpi_ = ::GetDpiForWindow(self->window_);
    self->CreateControls();
    ::ShowWindow(self->window_, SW_SHOWNORMAL);
    ::UpdateWindow(self->window_);
  }
  // 发布 window_ 和控件后再放行安装线程；此后 UI 状态只在此线程改变。
  ::SetEvent(self->ready_);
  if (self->window_) {
    MSG message;
    while (::GetMessage(&message, nullptr, 0, 0) > 0) {
      if (!::IsDialogMessage(self->window_, &message)) {
        ::TranslateMessage(&message);
        ::DispatchMessage(&message);
      }
    }
  }
  if (self->font_)
    ::DeleteObject(self->font_);
  if (self->title_font_)
    ::DeleteObject(self->title_font_);
  if (self->logo_icon_)
    ::DestroyIcon(self->logo_icon_);
  ::UnregisterClass(kWindowClass, wc.hInstance);
  if (self->graphics_token_)
    Gdiplus::GdiplusShutdown(self->graphics_token_);
  return 0;
}

LRESULT CALLBACK AegisInstallUi::ProgressProc(HWND window,
                                              UINT message,
                                              WPARAM wparam,
                                              LPARAM lparam,
                                              UINT_PTR subclass_id,
                                              DWORD_PTR context) {
  auto* self = reinterpret_cast<AegisInstallUi*>(context);
  if (message == WM_PAINT) {
    self->PaintProgress(window);
    return 0;
  }
  if (message == WM_ERASEBKGND)
    return 1;  // 整个控件由完整离屏帧覆盖，不允许系统先擦白。
  if (message == WM_NCDESTROY)
    ::RemoveWindowSubclass(window, ProgressProc, subclass_id);
  return ::DefSubclassProc(window, message, wparam, lparam);
}

LRESULT CALLBACK AegisInstallUi::WindowProc(HWND window,
                                            UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* creation = reinterpret_cast<CREATESTRUCT*>(lparam);
    ::SetWindowLongPtr(window, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(creation->lpCreateParams));
  }
  auto* self = reinterpret_cast<AegisInstallUi*>(
      ::GetWindowLongPtr(window, GWLP_USERDATA));
  if (!self)
    return ::DefWindowProc(window, message, wparam, lparam);
  switch (message) {
    case WM_NCCALCSIZE:
      return 0;  // 客户区占满整个窗口，DWM 继续管理阴影和圆角。
    case WM_NCHITTEST: {
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ::ScreenToClient(window, &point);
      return point.y < self->Scale(52) ? HTCAPTION : HTCLIENT;
    }
    case WM_NCLBUTTONDBLCLK:
      return 0;  // 固定尺寸安装窗不接受标题区双击最大化。
    case WM_SYSCOMMAND:
      if ((wparam & 0xfff0) == SC_SIZE || (wparam & 0xfff0) == SC_MAXIMIZE ||
          ((wparam & 0xfff0) == SC_CLOSE && !self->complete_))
        return 0;
      break;
    case WM_ERASEBKGND: {
      RECT client;
      ::GetClientRect(window, &client);
      ::FillRect(reinterpret_cast<HDC>(wparam), &client,
                 self->high_contrast_
                     ? ::GetSysColorBrush(COLOR_WINDOW)
                     : static_cast<HBRUSH>(::GetStockObject(WHITE_BRUSH)));
      return 1;
    }
    case WM_CTLCOLORSTATIC: {
      HWND control = reinterpret_cast<HWND>(lparam);
      COLORREF color = control == self->status_ ? kMuted : kInk;
      if (control == self->status_ && self->complete_)
        color = self->failed_ ? kError : kAccent;
      ::SetTextColor(
          reinterpret_cast<HDC>(wparam),
          self->high_contrast_ ? ::GetSysColor(COLOR_WINDOWTEXT) : color);
      ::SetBkMode(reinterpret_cast<HDC>(wparam), TRANSPARENT);
      return reinterpret_cast<LRESULT>(
          self->high_contrast_
              ? ::GetSysColorBrush(COLOR_WINDOW)
              : static_cast<HBRUSH>(::GetStockObject(WHITE_BRUSH)));
    }
    case WM_DRAWITEM:
      if (wparam == IDOK) {
        self->PaintCloseButton(*reinterpret_cast<DRAWITEMSTRUCT*>(lparam));
        return TRUE;
      }
      break;
    case WM_DPICHANGED: {
      self->dpi_ = HIWORD(wparam);
      const auto* bounds = reinterpret_cast<RECT*>(lparam);
      ::SetWindowPos(window, nullptr, bounds->left, bounds->top,
                     bounds->right - bounds->left, bounds->bottom - bounds->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
      if (self->title_) {
        self->LayoutControls();
        self->UpdateFrame();
      }
      return 0;
    }
    case WM_SETTINGCHANGE:
    case WM_SYSCOLORCHANGE:
      self->UpdateAppearance();
      return 0;
    case kProgress:
      self->ShowProgress({static_cast<aegis_installer::Phase>(wparam),
                          static_cast<int>(lparam)});
      return 0;
    case kFinished: {
      if (self->complete_)
        return 0;
      self->complete_ = true;
      const bool existing_version = wparam == kExistingVersionLaunched;
      self->failed_ = wparam != 0 && !existing_version;
      ::KillTimer(window, kAnimationTimer);
      // 仅实际安装成功显示满条；打开现有版本没有执行安装，也不是错误。
      if (self->failed_ || existing_version)
        ::ShowWindow(self->progress_, SW_HIDE);
      else {
        ::SendMessage(self->progress_, PBM_SETPOS, 100, 0);
        ::InvalidateRect(self->progress_, nullptr, FALSE);
      }
      if (!self->failed_) {
        ::SetWindowText(self->status_, existing_version
            ? L"已打开现有版本（本次未执行安装）" : L"安装完成");
        // 低资源导致计时器创建失败时直接收起，不能让安装线程永久等待 UI。
        if (!::SetTimer(window, kCloseTimer, 1400, nullptr))
          ::DestroyWindow(window);
      } else {
        wchar_t detail[160] = {};
        // 使用系统格式化保留数字错误码；不引入 CRT 或暴露安装路径等细节。
        DWORD_PTR code = wparam;
        ::FormatMessage(
            FORMAT_MESSAGE_FROM_STRING | FORMAT_MESSAGE_ARGUMENT_ARRAY,
            L"安装未完成（错误代码：%1!u!）", 0, 0, detail,
            sizeof(detail) / sizeof(detail[0]),
            reinterpret_cast<va_list*>(&code));
        ::SetWindowText(self->status_, detail[0] ? detail : L"安装未完成");
        ::ShowWindow(self->close_, SW_SHOW);
        ::SetFocus(self->close_);
      }
      return 0;
    }
    case WM_TIMER:
      if (wparam == kCloseTimer && self->complete_ && !self->failed_)
        ::DestroyWindow(window);
      else if (wparam == kAnimationTimer && !self->complete_ &&
               !::IsIconic(window))
        self->RefreshProgress();
      return 0;
    case WM_COMMAND:
      if (LOWORD(wparam) == IDOK && self->complete_)
        ::DestroyWindow(window);
      return 0;
    case WM_CLOSE:
      if (self->complete_)
        ::DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      ::KillTimer(window, kAnimationTimer);
      ::KillTimer(window, kCloseTimer);
      ::PostQuitMessage(0);
      return 0;
  }
  return ::DefWindowProc(window, message, wparam, lparam);
}
}  // namespace mini_installer
