// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Windows 原生卸载确认窗口；只展示品牌与选项，实际卸载仍由 setup 管理。

#ifndef CHROME_BROWSER_UI_VIEWS_UNINSTALL_VIEW_H_
#define CHROME_BROWSER_UI_VIEWS_UNINSTALL_VIEW_H_

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/raw_ref.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/views/metadata/view_factory.h"
#include "ui/views/window/dialog_delegate.h"

namespace views {
class Checkbox;
class Label;
}  // namespace views

// 返回 Chromium 既有的取消、保留资料或删除资料退出码；默认不授予卸载许可。
// 调用方必须让 user_selection 和 quit_closure 的依赖存活到窗口销毁。
class UninstallView : public views::DialogDelegateView {
  METADATA_HEADER(UninstallView, views::DialogDelegateView)

 public:
  explicit UninstallView(int* user_selection,
                         const base::RepeatingClosure& quit_closure);
  UninstallView(const UninstallView&) = delete;
  UninstallView& operator=(const UninstallView&) = delete;
  ~UninstallView() override;

  // 控件仍归 Views 所有；初始化后设置视觉样式，主题变化时遵循高对比度。
  void OnWidgetInitialized() override;
  void OnThemeChanged() override;

 private:
  friend class UninstallViewTestPeer;
  void SetupControls();
  void UpdateColors();
  // 只有接受回调读取删除选项；取消和关闭永远返回取消。
  void OnDialogAccepted();
  void OnDialogCancelled();

  raw_ptr<views::Label> title_ = nullptr;
  raw_ptr<views::Label> message_ = nullptr;
  raw_ptr<views::Checkbox> delete_profile_ = nullptr;
  const raw_ref<int> user_selection_;
  base::RepeatingClosure quit_closure_;
};

BEGIN_VIEW_BUILDER(, UninstallView, views::DialogDelegateView)
END_VIEW_BUILDER

DEFINE_VIEW_BUILDER(, UninstallView)

#endif  // CHROME_BROWSER_UI_VIEWS_UNINSTALL_VIEW_H_
