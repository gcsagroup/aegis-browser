// Copyright 2026 The GCSA Aegis Authors
// 验证真实 Win32 窗口的阶段与生命周期，不启动安装或写入用户注册表。
#include "chrome/installer/mini_installer/aegis_install_ui.h"

#include <string>

#include "testing/gtest/include/gtest/gtest.h"

namespace mini_installer {
namespace {
HWND OwnWindow() {
  HWND window = ::FindWindow(L"GCSAAegisInstallProgress", nullptr);
  DWORD pid = 0;
  ::GetWindowThreadProcessId(window, &pid);
  return pid == ::GetCurrentProcessId() ? window : nullptr;
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
    EXPECT_TRUE(WaitForText(window, L"正在准备安装"));
    ::SendMessage(window, WM_CLOSE, 0, 0);
    EXPECT_TRUE(::IsWindow(window));  // 安装提交期间关闭窗口不能中断文件写入。
    ui.Installing();
    EXPECT_TRUE(WaitForText(window, L"正在安装 GCSA Aegis"));
    ui.Finish(0);
    EXPECT_TRUE(WaitForText(window, L"安装完成"));
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

TEST(AegisInstallUiTest, FailureRemainsUntilAcknowledged) {
  {
    AegisInstallUi ui(true);
    HWND window = OwnWindow();
    ui.Finish(31);
    EXPECT_TRUE(WaitForText(window, L"错误代码：31"));
    ::Sleep(1800);  // 超过成功页收起时间，失败仍应可读。
    EXPECT_TRUE(::IsWindow(window));
    ::SendMessage(window, WM_CLOSE, 0, 0);
  }
  EXPECT_EQ(nullptr, OwnWindow());
}
}  // namespace mini_installer
