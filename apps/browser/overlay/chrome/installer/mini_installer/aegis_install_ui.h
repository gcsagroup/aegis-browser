// Copyright 2026 The GCSA Aegis Authors
// 安装器的轻量原生界面；不依赖 CRT，不执行安装、提权或浏览器启动。
#ifndef CHROME_INSTALLER_MINI_INSTALLER_AEGIS_INSTALL_UI_H_
#define CHROME_INSTALLER_MINI_INSTALLER_AEGIS_INSTALL_UI_H_

#include <windows.h>

#include "chrome/installer/aegis_install_progress.h"
#include "chrome/installer/mini_installer/aegis_overall_progress.h"

namespace mini_installer {

// 安装工作留在调用线程；窗口和控件仅由独立消息线程持有。
// Finish 必须在销毁前调用：成功短暂展示完成状态，失败保留窗口供用户关闭。
class AegisInstallUi {
 public:
  explicit AegisInstallUi(bool interactive);
  ~AegisInstallUi();
  AegisInstallUi(const AegisInstallUi&) = delete;
  AegisInstallUi& operator=(const AegisInstallUi&) = delete;

  // 通知 setup 启动，不预判其阶段；最终状态之后的迟到通知会被忽略。
  void Installing();
  // 用当前阶段观测校准整体预估进度，调用方不持有窗口或跨线程 UI 状态。
  void UpdateProgress(aegis_installer::Progress progress);
  // 0 表示安装成功；3 表示已打开现有版本，均自动收起；其他值显示错误码。
  void Finish(DWORD exit_code);

 private:
  friend class AegisInstallUiTestPeer;
  static DWORD WINAPI ThreadMain(void* context);
  static LRESULT CALLBACK WindowProc(HWND window,
                                     UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam);
  // 保留原生进度控件的辅助功能角色，仅接管绘制。
  static LRESULT CALLBACK ProgressProc(HWND window,
                                       UINT message,
                                       WPARAM wparam,
                                       LPARAM lparam,
                                       UINT_PTR subclass_id,
                                       DWORD_PTR context);
  // 保留原生按钮的键盘/辅助功能语义，仅补充悬停与绘制。
  static LRESULT CALLBACK CloseButtonProc(HWND window,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam,
                                          UINT_PTR subclass_id,
                                          DWORD_PTR context);
  void CreateControls();
  void UpdateFrame();
  void ShowProgress(aegis_installer::Progress progress);
  void LayoutControls();
  void UpdateAppearance();
  // 仅更新变化的进度条和状态文字，不使品牌、图标或父窗口失效。
  void RefreshProgress();
  void PaintProgress(HWND window);
  void DrawProgressFrame(HDC dc, const RECT& track);
  void PaintCloseButton(const DRAWITEMSTRUCT& item);
  int Scale(int value) const;

  HANDLE thread_ = nullptr;
  HANDLE ready_ = nullptr;
  HWND window_ = nullptr;
  HWND logo_ = nullptr;
  HWND title_ = nullptr;
  HWND status_ = nullptr;
  HWND progress_ = nullptr;
  HWND close_ = nullptr;
  HFONT font_ = nullptr;
  HFONT title_font_ = nullptr;
  HICON logo_icon_ = nullptr;
  ULONG_PTR graphics_token_ = 0;
  UINT dpi_ = 96;
  bool interactive_;
  bool complete_ = false;
  bool failed_ = false;
  bool high_contrast_ = false;
  bool animate_ = true;
  bool close_hover_ = false;
  AegisOverallProgress overall_progress_{0};
  int displayed_percent_ = -1;
  bool displayed_rollback_ = false;
};

}  // namespace mini_installer
#endif  // CHROME_INSTALLER_MINI_INSTALLER_AEGIS_INSTALL_UI_H_
