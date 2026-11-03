// Copyright 2026 The GCSA Aegis Authors
// 安装器的轻量原生界面；不依赖 CRT，不执行安装、提权或浏览器启动。
#ifndef CHROME_INSTALLER_MINI_INSTALLER_AEGIS_INSTALL_UI_H_
#define CHROME_INSTALLER_MINI_INSTALLER_AEGIS_INSTALL_UI_H_

#include <windows.h>

namespace mini_installer {

// 安装工作留在调用线程；窗口和控件仅由独立消息线程持有。
// Finish 必须在销毁前调用：成功短暂展示完成状态，失败保留窗口供用户关闭。
class AegisInstallUi {
 public:
  explicit AegisInstallUi(bool interactive);
  ~AegisInstallUi();
  AegisInstallUi(const AegisInstallUi&) = delete;
  AegisInstallUi& operator=(const AegisInstallUi&) = delete;

  void Installing();
  void Finish(DWORD exit_code);

 private:
  static DWORD WINAPI ThreadMain(void* context);
  static LRESULT CALLBACK WindowProc(HWND window,
                                     UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam);
  void CreateControls();
  int Scale(int value) const;

  HANDLE thread_ = nullptr;
  HANDLE ready_ = nullptr;
  HWND window_ = nullptr;
  HWND status_ = nullptr;
  HWND detail_ = nullptr;
  HWND progress_ = nullptr;
  HWND close_ = nullptr;
  HFONT font_ = nullptr;
  HFONT title_font_ = nullptr;
  UINT dpi_ = 96;
  bool interactive_;
  bool complete_ = false;
};

}  // namespace mini_installer
#endif  // CHROME_INSTALLER_MINI_INSTALLER_AEGIS_INSTALL_UI_H_
