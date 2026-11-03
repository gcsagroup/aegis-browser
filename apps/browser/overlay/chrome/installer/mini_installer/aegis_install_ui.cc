// Copyright 2026 The GCSA Aegis Authors
// 双击安装时显示真实阶段；没有可用总进度时使用活动条，不伪造百分比。
#include "chrome/installer/mini_installer/aegis_install_ui.h"

#include <commctrl.h>

#include "chrome/installer/mini_installer/mini_installer_resource.h"

namespace mini_installer {
namespace {
constexpr UINT kInstalling = WM_APP + 1;
constexpr UINT kFinished = WM_APP + 2;
constexpr wchar_t kWindowClass[] = L"GCSAAegisInstallProgress";
constexpr wchar_t kTitle[] = L"GCSA Aegis 安装程序";
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
  if (window_)
    ::PostMessage(window_, kInstalling, 0, 0);
}

void AegisInstallUi::Finish(DWORD exit_code) {
  if (window_) {
    ::PostMessage(window_, kFinished, exit_code, 0);
  } else if (interactive_ && exit_code != 0) {
    // 窗口创建失败也不能把安装失败变成无声退出；不改变安装器原有退出码。
    ::MessageBox(nullptr, L"安装未完成，请重新运行安装程序。", kTitle,
                 MB_OK | MB_ICONERROR);
  }
}

int AegisInstallUi::Scale(int value) const {
  return ::MulDiv(value, static_cast<int>(dpi_), 96);
}

void AegisInstallUi::CreateControls() {
  font_ = ::CreateFont(Scale(-15), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                       DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                       CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  title_font_ =
      ::CreateFont(Scale(-25), 0, 0, 0, FW_MEDIUM, FALSE, FALSE, FALSE,
                   DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                   CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  auto label = [this](const wchar_t* text, int x, int y, int w, int h) {
    HWND control = ::CreateWindow(L"STATIC", text, WS_CHILD | WS_VISIBLE,
                                  Scale(x), Scale(y), Scale(w), Scale(h),
                                  window_, nullptr, nullptr, nullptr);
    ::SendMessage(control, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
    return control;
  };
  HWND logo = ::CreateWindow(
      L"STATIC", nullptr, WS_CHILD | WS_VISIBLE | SS_ICON, Scale(36), Scale(32),
      Scale(48), Scale(48), window_, nullptr, nullptr, nullptr);
  ::SendMessage(
      logo, STM_SETICON,
      reinterpret_cast<WPARAM>(::LoadImage(
          ::GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_MINI_INSTALLER),
          IMAGE_ICON, Scale(48), Scale(48), LR_SHARED)),
      0);
  HWND title = label(L"GCSA Aegis", 104, 30, 360, 36);
  ::SendMessage(title, WM_SETFONT, reinterpret_cast<WPARAM>(title_font_), TRUE);
  label(L"安全、流畅的浏览体验", 106, 70, 360, 28);
  status_ = label(L"正在准备安装…", 36, 132, 448, 28);
  progress_ = ::CreateWindow(
      PROGRESS_CLASS, nullptr, WS_CHILD | WS_VISIBLE | PBS_MARQUEE, Scale(36),
      Scale(174), Scale(448), Scale(6), window_, nullptr, nullptr, nullptr);
  ::SendMessage(progress_, PBM_SETMARQUEE, TRUE, 24);
  detail_ = label(L"正在解压安装文件，请稍候。", 36, 202, 448, 50);
  close_ = ::CreateWindow(L"BUTTON", L"关闭",
                          WS_CHILD | WS_TABSTOP | BS_DEFPUSHBUTTON, Scale(394),
                          Scale(260), Scale(90), Scale(34), window_,
                          reinterpret_cast<HMENU>(IDOK), nullptr, nullptr);
  ::SendMessage(close_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
}

DWORD WINAPI AegisInstallUi::ThreadMain(void* context) {
  auto* self = static_cast<AegisInstallUi*>(context);
  // 使用系统 DPI，跨屏移动交由 Windows 缩放，避免固定像素字体在高 DPI 下过小。
  ::SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_SYSTEM_AWARE);
  self->dpi_ = ::GetDpiForSystem();
  INITCOMMONCONTROLSEX controls = {sizeof(controls), ICC_PROGRESS_CLASS};
  ::InitCommonControlsEx(&controls);
  WNDCLASS wc = {};
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = ::GetModuleHandle(nullptr);
  wc.hIcon = ::LoadIcon(wc.hInstance, MAKEINTRESOURCE(IDI_MINI_INSTALLER));
  wc.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = static_cast<HBRUSH>(::GetStockObject(WHITE_BRUSH));
  wc.lpszClassName = kWindowClass;
  ::RegisterClass(&wc);
  constexpr DWORD style =
      WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
  RECT bounds = {0, 0, self->Scale(520), self->Scale(320)};
  ::AdjustWindowRect(&bounds, style, FALSE);
  RECT work = {};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  self->window_ = ::CreateWindow(
      kWindowClass, kTitle, style,
      work.left + (work.right - work.left - (bounds.right - bounds.left)) / 2,
      work.top + (work.bottom - work.top - (bounds.bottom - bounds.top)) / 2,
      bounds.right - bounds.left, bounds.bottom - bounds.top, nullptr, nullptr,
      wc.hInstance, self);
  if (self->window_) {
    self->CreateControls();
    // 解压/提交文件期间不允许关闭窗口来中断安装；失败后恢复关闭入口。
    ::EnableMenuItem(::GetSystemMenu(self->window_, FALSE), SC_CLOSE,
                     MF_BYCOMMAND | MF_GRAYED);
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
  ::UnregisterClass(kWindowClass, wc.hInstance);
  return 0;
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
    case WM_CTLCOLORSTATIC:
      ::SetTextColor(reinterpret_cast<HDC>(wparam), RGB(40, 44, 52));
      ::SetBkMode(reinterpret_cast<HDC>(wparam), TRANSPARENT);
      return reinterpret_cast<LRESULT>(::GetStockObject(WHITE_BRUSH));
    case kInstalling:
      ::SetWindowText(self->status_, L"正在安装 GCSA Aegis…");
      ::SetWindowText(self->detail_, L"正在安装浏览器并创建快捷方式，请稍候。");
      return 0;
    case kFinished: {
      self->complete_ = true;
      ::SendMessage(self->progress_, PBM_SETMARQUEE, FALSE, 0);
      ::ShowWindow(self->progress_, SW_HIDE);
      ::EnableMenuItem(::GetSystemMenu(window, FALSE), SC_CLOSE,
                       MF_BYCOMMAND | MF_ENABLED);
      if (wparam == 0) {
        ::SetWindowText(self->status_, L"安装完成");
        ::SetWindowText(self->detail_, L"GCSA Aegis 已准备就绪。");
        ::SetTimer(window, 1, 1400, nullptr);
      } else {
        wchar_t detail[160] = {};
        // FormatMessage 使用系统格式化，保持 mini_installer 不链接 CRT 的边界。
        DWORD_PTR code = wparam;
        ::FormatMessage(
            FORMAT_MESSAGE_FROM_STRING | FORMAT_MESSAGE_ARGUMENT_ARRAY,
            L"安装未完成（错误代码：%1!u!"
            L"）。请关闭浏览器后重试。\n若仍失败，请保留此错误代码以便排查。",
            0, 0, detail, sizeof(detail) / sizeof(detail[0]),
            reinterpret_cast<va_list*>(&code));
        ::SetWindowText(self->status_, L"安装未完成");
        ::SetWindowText(self->detail_, detail[0] ? detail : L"安装未完成，请重新运行安装程序。");
        ::ShowWindow(self->close_, SW_SHOW);
        ::SetFocus(self->close_);
      }
      return 0;
    }
    case WM_TIMER:
      if (wparam == 1 && self->complete_)
        ::DestroyWindow(window);
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
      ::PostQuitMessage(0);
      return 0;
  }
  return ::DefWindowProc(window, message, wparam, lparam);
}
}  // namespace mini_installer
