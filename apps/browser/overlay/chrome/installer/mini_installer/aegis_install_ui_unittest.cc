// Copyright 2026 The GCSA Aegis Authors
// 验证真实 Win32 窗口的阶段与生命周期，不启动安装或写入用户注册表。
#include "chrome/installer/mini_installer/aegis_install_ui.h"

#include <commctrl.h>

#include <atomic>
#include <string>

#include "chrome/installer/util/util_constants.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace mini_installer {
static_assert(installer::EXISTING_VERSION_LAUNCHED == 3);

class AegisInstallUiTestPeer {
 public:
  static void SimulateWindowCreationFailure(AegisInstallUi& ui) {
    // Constructed silently: no worker or window exists. Exercise the same
    // interactive fallback reached when creating the production window fails.
    ui.interactive_ = true;
  }
};
namespace {
HWND OwnWindow() {
  // 允许桌面存在其他安装预览；只读取当前测试进程的窗口，避免干扰用户。
  HWND window = nullptr;
  while ((window = ::FindWindowEx(nullptr, window, L"GCSAAegisInstallProgress",
                                  nullptr))) {
    DWORD pid = 0;
    ::GetWindowThreadProcessId(window, &pid);
    if (pid == ::GetCurrentProcessId())
      return window;
  }
  return nullptr;
}

bool WaitForText(HWND window, const wchar_t* expected) {
  for (int attempt = 0; attempt < 100; ++attempt) {
    for (HWND child = ::GetWindow(window, GW_CHILD); child;
         child = ::GetWindow(child, GW_HWNDNEXT)) {
      wchar_t text[256] = {};
      ::GetWindowText(child, text, sizeof(text) / sizeof(text[0]));
      if (std::wstring(text).find(expected) != std::wstring::npos)
        return true;
    }
    ::Sleep(25);
  }
  return false;
}

// 验证各 DPI 下的真实控件与单行最大错误码提示可完整容纳。
void ExpectReadableLayout(HWND window) {
  RECT client = {};
  ASSERT_TRUE(::GetClientRect(window, &client));
  for (HWND child = ::GetWindow(window, GW_CHILD); child;
       child = ::GetWindow(child, GW_HWNDNEXT)) {
    RECT bounds = {};
    ::GetWindowRect(child, &bounds);
    ::MapWindowPoints(nullptr, window, reinterpret_cast<POINT*>(&bounds), 2);
    EXPECT_GE(bounds.left, 0);
    EXPECT_GE(bounds.top, 0);
    EXPECT_LE(bounds.right, client.right);
    EXPECT_LE(bounds.bottom, client.bottom);
    wchar_t name[32] = {};
    ::GetClassName(child, name, 32);
    if (std::wstring(name) != L"Static" ||
        (::GetWindowLongPtr(child, GWL_STYLE) & SS_TYPEMASK) == SS_ICON)
      continue;
    wchar_t text[256] = {};
    ::GetWindowText(child, text, 256);
    HDC dc = ::GetDC(child);
    HGDIOBJ previous = ::SelectObject(
        dc, reinterpret_cast<HFONT>(::SendMessage(child, WM_GETFONT, 0, 0)));
    RECT measured = {0, 0, bounds.right - bounds.left, 0};
    ::DrawText(dc, text, -1, &measured,
               DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX | DT_CENTER);
    EXPECT_LE(measured.bottom, bounds.bottom - bounds.top);
    EXPECT_LE(measured.right, bounds.right - bounds.left);
    ::SelectObject(dc, previous);
    ::ReleaseDC(child, dc);
  }
}
// 消息观察器只记录本测试窗口；原子字段允许 UI 线程与断言线程安全通信。
std::atomic<HWND> observed_parent = nullptr;
std::atomic<HWND> observed_brand = nullptr;
std::atomic<int> unrelated_paints = 0;
LRESULT CALLBACK ObservePaint(int code, WPARAM wparam, LPARAM lparam) {
  if (code >= 0) {
    const auto& message = *reinterpret_cast<const CWPSTRUCT*>(lparam);
    if ((message.hwnd == observed_parent.load() &&
         message.message == WM_ERASEBKGND) ||
        (message.hwnd == observed_brand.load() && message.message == WM_PAINT))
      ++unrelated_paints;
  }
  return ::CallNextHookEx(nullptr, code, wparam, lparam);
}
}  // namespace

TEST(AegisInstallUiTest, SilentDoesNotCreateWindow) {
  AegisInstallUi ui(false);
  ui.Installing();
  ui.Finish(0);
  EXPECT_EQ(nullptr, OwnWindow());
}

TEST(AegisInstallUiTest, SuccessShowsStagesAndClosesAutomatically) {
  {
    AegisInstallUi ui(true);
    HWND window = OwnWindow();
    EXPECT_TRUE(window);
    EXPECT_TRUE(WaitForText(window, L"正在安装"));
    ::SendMessage(window, WM_CLOSE, 0, 0);
    EXPECT_TRUE(::IsWindow(window));  // 安装提交期间关闭窗口不能中断文件写入。
    ui.Installing();
    EXPECT_TRUE(WaitForText(window, L"正在安装"));
    HWND progress = ::FindWindowEx(window, nullptr, PROGRESS_CLASS, nullptr);
    EXPECT_TRUE(::IsWindowVisible(progress));
    EXPECT_EQ(0, ::GetWindowLongPtr(progress, GWL_STYLE) & PBS_MARQUEE);
    EXPECT_FALSE(::IsWindowVisible(::GetDlgItem(window, IDOK)));
    ui.Finish(0);
    EXPECT_TRUE(WaitForText(window, L"安装完成"));
    EXPECT_EQ(100, ::SendMessage(progress, PBM_GETPOS, 0, 0));
  }
  EXPECT_EQ(nullptr, OwnWindow());
}

TEST(AegisInstallUiTest, ExistingVersionShowsInformationAndClosesAutomatically) {
  {
    AegisInstallUi ui(true);
    HWND window = OwnWindow();
    EXPECT_TRUE(window);
    ui.Finish(3);
    EXPECT_TRUE(WaitForText(window, L"已打开现有版本"));
    EXPECT_TRUE(WaitForText(window, L"本次未执行安装"));
    HWND progress = ::FindWindowEx(window, nullptr, PROGRESS_CLASS, nullptr);
    EXPECT_FALSE(::IsWindowVisible(progress));
    EXPECT_LT(::SendMessage(progress, PBM_GETPOS, 0, 0), 100);
    ExpectReadableLayout(window);
    ui.UpdateProgress({aegis_installer::Phase::kFinishing, 99});
    ::SendMessage(window, WM_NULL, 0, 0);
    EXPECT_TRUE(WaitForText(window, L"本次未执行安装"));
    EXPECT_FALSE(::IsWindowVisible(progress));
    EXPECT_FALSE(::IsWindowVisible(::GetDlgItem(window, IDOK)));
    for (int attempt = 0; attempt < 120 && ::IsWindow(window); ++attempt)
      ::Sleep(25);
    EXPECT_FALSE(::IsWindow(window));
    // 回归为错误页时也关闭窗口，避免析构等待阻塞整个测试进程。
    if (::IsWindow(window))
      ::SendMessage(window, WM_CLOSE, 0, 0);
  }
  EXPECT_EQ(nullptr, OwnWindow());
}

TEST(AegisInstallUiTest, ExistingVersionWithoutWindowDoesNotShowError) {
  AegisInstallUi ui(false);
  AegisInstallUiTestPeer::SimulateWindowCreationFailure(ui);
  // A regressed MessageBox pumps this thread's timers. Dismiss it so the
  // regression fails promptly instead of leaving the suite blocked on a dialog.
  static bool dismissed_error = false;
  dismissed_error = false;
  const UINT_PTR timer = ::SetTimer(nullptr, 0, 100,
      [](HWND, UINT, UINT_PTR, DWORD) {
        HWND dialog = ::FindWindow(L"#32770", L"GCSA Aegis 安装程序");
        DWORD pid = 0;
        const DWORD thread = ::GetWindowThreadProcessId(dialog, &pid);
        if (pid == ::GetCurrentProcessId() &&
            thread == ::GetCurrentThreadId()) {
          dismissed_error = true;
          ::EndDialog(dialog, IDCANCEL);
        }
      });
  ASSERT_NE(0u, timer);
  ui.Finish(3);
  ::KillTimer(nullptr, timer);
  EXPECT_FALSE(dismissed_error);
}

TEST(AegisInstallUiTest, FailureRemainsUntilAcknowledged) {
  {
    AegisInstallUi ui(true);
    HWND window = OwnWindow();
    ui.Finish(31);
    EXPECT_TRUE(WaitForText(window, L"错误代码：31"));
    EXPECT_FALSE(::IsWindowVisible(
        ::FindWindowEx(window, nullptr, PROGRESS_CLASS, nullptr)));
    EXPECT_TRUE(::IsWindowVisible(::GetDlgItem(window, IDOK)));
    ::Sleep(1800);  // 超过成功页收起时间，失败仍应可读。
    EXPECT_TRUE(::IsWindow(window));
    ::SendMessage(window, WM_CLOSE, 0, 0);
  }
  EXPECT_EQ(nullptr, OwnWindow());
}

TEST(AegisInstallUiTest, FailureRemainsReadableAcrossDpiChanges) {
  AegisInstallUi ui(true);
  HWND window = OwnWindow();
  ui.Finish(MAXDWORD);
  EXPECT_TRUE(WaitForText(window, L"错误代码：4294967295"));
  // 只给本测试窗口发送跨屏 DPI 消息，不修改用户显示设置。
  auto previous_context = ::SetThreadDpiAwarenessContext(
      DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  for (UINT dpi : {96U, 120U, 144U, 192U, 96U}) {
    RECT bounds = {0, 0, ::MulDiv(640, dpi, 96), ::MulDiv(400, dpi, 96)};
    ::SendMessage(window, WM_DPICHANGED, MAKELONG(dpi, dpi),
                  reinterpret_cast<LPARAM>(&bounds));
    ExpectReadableLayout(window);
  }
  ::SetThreadDpiAwarenessContext(previous_context);
  ::SendMessage(window, WM_COMMAND, IDOK, 0);
}

TEST(AegisInstallUiTest, TerminalStateIgnoresLateInstallingMessage) {
  AegisInstallUi ui(true);
  HWND window = OwnWindow();
  ui.Finish(31);
  EXPECT_TRUE(WaitForText(window, L"错误代码：31"));
  // 安装线程迟到的阶段消息不能覆盖失败结果或重新启动动画。
  ui.Installing();
  EXPECT_FALSE(WaitForText(window, L"正在安装"));
  EXPECT_TRUE(WaitForText(window, L"错误代码：31"));
  ::SendMessage(window, WM_COMMAND, IDOK, 0);
}
TEST(AegisInstallUiTest, OverallProgressDoesNotRestartWhenStageChanges) {
  AegisInstallUi ui(true);
  HWND window = OwnWindow();
  HWND progress = ::FindWindowEx(window, nullptr, PROGRESS_CLASS, nullptr);
  ui.Installing();  // 通用启动通知不能抢占后续真实解压阶段的预算。
  ui.UpdateProgress({aegis_installer::Phase::kDecompressing, 50});
  auto reaches = [&](int minimum) {
    for (int i = 0; i != 100; ++i) {
      if (::SendMessage(progress, PBM_GETPOS, 0, 0) >= minimum)
        return true;
      ::Sleep(25);
    }
    return false;
  };
  EXPECT_TRUE(reaches(30));
  EXPECT_LT(::SendMessage(progress, PBM_GETPOS, 0, 0), 60);
  EXPECT_TRUE(WaitForText(window, L"正在安装"));
  EXPECT_EQ(0, ::GetWindowLongPtr(progress, GWL_STYLE) & PBS_MARQUEE);
  // 阶段内 0% 进入整体下一段，不得将用户看到的进度清零。
  ui.UpdateProgress({aegis_installer::Phase::kUnpacking, 0});
  EXPECT_TRUE(reaches(59));
  ui.UpdateProgress({aegis_installer::Phase::kInstalling, 0});
  EXPECT_TRUE(reaches(77));
  ui.UpdateProgress({aegis_installer::Phase::kPreparing, -1});
  ui.UpdateProgress({aegis_installer::Phase::kFinishing, 100});
  ::Sleep(100);
  EXPECT_GE(::SendMessage(progress, PBM_GETPOS, 0, 0), 77);
  EXPECT_LT(::SendMessage(progress, PBM_GETPOS, 0, 0), 100);
  ui.Finish(0);
  EXPECT_TRUE(WaitForText(window, L"安装完成"));
  ::SendMessage(window, WM_CLOSE, 0, 0);
}

TEST(AegisInstallUiTest, FramelessWindowKeepsDraggingWithoutWindowButtons) {
  AegisInstallUi ui(true);
  HWND window = OwnWindow();
  EXPECT_EQ(0, ::GetWindowLongPtr(window, GWL_STYLE) & WS_CAPTION);
  EXPECT_EQ(0, ::GetWindowLongPtr(window, GWL_STYLE) & WS_THICKFRAME);
  EXPECT_EQ(0, ::GetWindowLongPtr(window, GWL_STYLE) & WS_BORDER);
  EXPECT_EQ(0, ::GetWindowLongPtr(window, GWL_STYLE) & WS_MINIMIZEBOX);
  EXPECT_EQ(nullptr, ::GetDlgItem(window, 100));
  EXPECT_FALSE(::IsWindowVisible(::GetDlgItem(window, IDOK)));
  int text_count = 0;
  for (HWND child = ::GetWindow(window, GW_CHILD); child;
       child = ::GetWindow(child, GW_HWNDNEXT)) {
    wchar_t name[32] = {};
    ::GetClassName(child, name, 32);
    if (std::wstring(name) == L"Static" &&
        (::GetWindowLongPtr(child, GWL_STYLE) & SS_TYPEMASK) != SS_ICON)
      ++text_count;
  }
  EXPECT_EQ(2, text_count);  // 品牌和状态各一处，不重复展示说明文案。
  POINT drag = {30, 20};
  ::ClientToScreen(window, &drag);
  EXPECT_EQ(HTCAPTION,
            ::SendMessage(window, WM_NCHITTEST, 0, MAKELPARAM(drag.x, drag.y)));
  ::SendMessage(window, WM_SYSCOMMAND, SC_MAXIMIZE, 0);
  EXPECT_FALSE(::IsZoomed(window));
  ui.Finish(0);
  // 本测试专注框架与命中；同步关闭避免跨线程窗口激活与析构等待互锁。
  EXPECT_TRUE(WaitForText(window, L"安装完成"));
  ::SendMessage(window, WM_CLOSE, 0, 0);
}
// 进度变化不得擦除整窗或重画无关品牌区域，防止只修进度条而留下整页闪烁。
TEST(AegisInstallUiTest, ProgressUpdatesDoNotRepaintUnrelatedContent) {
  AegisInstallUi ui(true);
  HWND window = OwnWindow();
  HWND brand = ::FindWindowEx(window, nullptr, L"Static", L"GCSA Aegis");
  observed_parent = window;
  observed_brand = brand;
  HHOOK hook = ::SetWindowsHookEx(WH_CALLWNDPROC, ObservePaint, nullptr,
                                  ::GetWindowThreadProcessId(window, nullptr));
  EXPECT_NE(nullptr, hook);
  if (hook) {
    ::RedrawWindow(
        window, nullptr, nullptr,
        RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
    EXPECT_GT(unrelated_paints.load(), 0);  // 先证明观察器能发现真实整窗重绘。
    ::Sleep(100);
    unrelated_paints = 0;
    for (int percent : {10, 20, 30, 40, 50, 60}) {
      ui.UpdateProgress({aegis_installer::Phase::kDecompressing, percent});
      ::Sleep(60);
    }
    ::SendMessage(window, WM_NULL, 0, 0);
    EXPECT_EQ(0, unrelated_paints.load());
    observed_parent = nullptr;
    observed_brand = nullptr;
    ::UnhookWindowsHookEx(hook);
  }
  EXPECT_NE(0, ::GetWindowLongPtr(window, GWL_STYLE) & WS_CLIPCHILDREN);
  ui.Finish(0);
  EXPECT_TRUE(WaitForText(window, L"安装完成"));
  ::SendMessage(window, WM_CLOSE, 0, 0);
}

TEST(AegisOverallProgressTest, WeightsMapStagesToOneContinuousRange) {
  AegisOverallProgress progress(0);
  progress.Update({aegis_installer::Phase::kDecompressing, 50}, 100);
  progress.Advance(100, false);
  EXPECT_EQ(3200, progress.position());
  progress.Update({aegis_installer::Phase::kUnpacking, 0}, 200);
  progress.Advance(200, false);
  EXPECT_EQ(6000, progress.position());
  progress.Update({aegis_installer::Phase::kInstalling, 50}, 300);
  progress.Advance(300, false);
  EXPECT_EQ(8600, progress.position());
}

TEST(AegisOverallProgressTest, UnknownDurationStaysWithinItsPhaseBudget) {
  AegisOverallProgress progress(0);
  progress.Advance(3000, false);
  EXPECT_EQ(200, progress.position());
  progress.Advance(10000000, false);
  EXPECT_LT(progress.position(), 400);
  progress.Update({aegis_installer::Phase::kFinishing, -1}, 10000000);
  progress.Advance(20000000, false);
  EXPECT_EQ(99, progress.percent());  // 长时间等待也不能伪造安装成功。
}

TEST(AegisOverallProgressTest, LateOrInvalidObservationsNeverResetProgress) {
  AegisOverallProgress progress(0);
  progress.Update({aegis_installer::Phase::kInstalling, 60}, 100);
  progress.Advance(100, false);
  int previous = progress.position();
  for (aegis_installer::Progress input :
       {aegis_installer::Progress{aegis_installer::Phase::kInstalling, 10},
        {aegis_installer::Phase::kPreparing, -1},
        {aegis_installer::Phase::kFinishing, 100},
        {static_cast<aegis_installer::Phase>(99), 50}}) {
    progress.Update(input, 200);
    progress.Advance(200, false);
    EXPECT_EQ(previous, progress.position());
  }
}

TEST(AegisOverallProgressTest,
     RollbackFreezesEstimateAndRejectsLateSuccessHints) {
  AegisOverallProgress progress(0);
  progress.Update({aegis_installer::Phase::kInstalling, 60}, 100);
  progress.Advance(100, false);
  int previous = progress.position();
  progress.Update({aegis_installer::Phase::kRollingBack, -1}, 200);
  progress.Update({aegis_installer::Phase::kFinishing, 99}, 300);
  EXPECT_FALSE(progress.Advance(10000));
  EXPECT_TRUE(progress.rolling_back());
  EXPECT_EQ(previous, progress.position());
}

TEST(AegisOverallProgressTest, SmoothingAndClockRegressionCannotMoveBackwards) {
  AegisOverallProgress progress(0);
  progress.Update({aegis_installer::Phase::kInstalling, 0}, 10);
  EXPECT_TRUE(progress.Advance(30));
  EXPECT_GT(progress.position(), 0);
  EXPECT_LT(progress.position(), 7800);
  int previous = progress.position();
  EXPECT_FALSE(progress.Advance(20));
  EXPECT_EQ(previous, progress.position());
  for (ULONGLONG now = 60; now < 3000; now += 30) {
    progress.Advance(now);
    EXPECT_GE(progress.position(), previous);
    EXPECT_LE(progress.position(), 7800);
    previous = progress.position();
  }
  EXPECT_EQ(7800, progress.position());
}
}  // namespace mini_installer
