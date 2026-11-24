// Copyright 2020 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// 只创建真实确认控件并验证返回契约；测试不执行 setup 或删除任何浏览资料。

#include "chrome/browser/ui/views/uninstall_view.h"

#include <algorithm>
#include <string>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "chrome/common/chrome_result_codes.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/base/hit_test.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/color/color_provider.h"
#include "ui/native_theme/native_theme.h"
#include "ui/views/bubble/bubble_frame_view.h"
#include "ui/views/controls/button/checkbox.h"
#include "ui/views/controls/button/md_text_button.h"
#include "ui/views/controls/label.h"
#include "ui/views/test/views_test_base.h"
#include "ui/views/widget/widget.h"

// 只暴露测试所需的用户选项和换行标签，不增加产品 API。
class UninstallViewTestPeer {
 public:
  static views::Checkbox* DeleteProfile(UninstallView& view) {
    return view.delete_profile_;
  }
  static views::Label* Message(UninstallView& view) { return view.message_; }
};

using UninstallViewTest = views::ViewsTestBase;

TEST_F(UninstallViewTest, AcceptKeepsProfileByDefault) {
  // 未勾选的确认只卸载程序，不能被视觉更新变成默认删除资料。
  int result = -1;
  UninstallView view(&result, base::DoNothing());
  EXPECT_FALSE(UninstallViewTestPeer::DeleteProfile(view)->GetChecked());
  view.Accept();
  EXPECT_EQ(result, content::RESULT_CODE_NORMAL_EXIT);
}

TEST_F(UninstallViewTest, DeleteProfileRequiresExplicitOptIn) {
  int result = -1;
  UninstallView view(&result, base::DoNothing());
  UninstallViewTestPeer::DeleteProfile(view)->SetChecked(true);
  view.Accept();
  EXPECT_EQ(result, CHROME_RESULT_CODE_UNINSTALL_DELETE_PROFILE);
}

TEST_F(UninstallViewTest, CancelDiscardsDeleteSelection) {
  int result = -1;
  UninstallView view(&result, base::DoNothing());
  UninstallViewTestPeer::DeleteProfile(view)->SetChecked(true);
  view.Cancel();
  EXPECT_EQ(result, CHROME_RESULT_CODE_UNINSTALL_USER_CANCEL);
}

TEST_F(UninstallViewTest, CloseDiscardsDeleteSelection) {
  int result = -1;
  UninstallView view(&result, base::DoNothing());
  UninstallViewTestPeer::DeleteProfile(view)->SetChecked(true);
  view.Close();
  EXPECT_EQ(result, CHROME_RESULT_CODE_UNINSTALL_USER_CANCEL);
}

TEST_F(UninstallViewTest, DestructionWithoutChoiceCancelsAndQuits) {
  // 窗口创建失败或直接销毁都必须保守取消，同时释放调用方消息循环。
  int result = content::RESULT_CODE_NORMAL_EXIT;
  int quit_count = 0;
  {
    UninstallView view(&result, base::BindRepeating(
                                   [](int* count) { ++*count; }, &quit_count));
  }
  EXPECT_EQ(result, CHROME_RESULT_CODE_UNINSTALL_USER_CANCEL);
  EXPECT_EQ(quit_count, 1);
}

TEST_F(UninstallViewTest, BrandLayoutKeepsSafeKeyboardDefault) {
  int result = -1;
  auto* view = new UninstallView(&result, base::DoNothing());
  auto* widget =
      views::DialogDelegate::CreateDialogWidget(view, GetContext(), nullptr);
  widget->Show();
  EXPECT_FALSE(view->ShouldShowWindowTitle());
  EXPECT_FALSE(view->ShouldShowCloseButton());
  EXPECT_EQ(view->GetInitiallyFocusedView(), view->GetCancelButton());
  EXPECT_EQ(view->GetDefaultDialogButton(),
            static_cast<int>(ui::mojom::DialogButton::kCancel));
  EXPECT_EQ(view->width(), 640);
  auto* frame = view->GetBubbleFrameView();
  const gfx::Rect client = frame->GetBoundsForClientView();
  EXPECT_EQ(frame->NonClientHitTest(client.origin() + gfx::Vector2d(100, 20)),
            HTCAPTION);
  EXPECT_EQ(frame->NonClientHitTest(client.origin() + gfx::Vector2d(100, 240)),
            HTCLIENT);
  EXPECT_GE(view->GetOkButton()->height(), 40);
  EXPECT_GE(view->GetCancelButton()->height(), 40);
  const auto* checkbox = UninstallViewTestPeer::DeleteProfile(*view);
  EXPECT_TRUE(view->GetLocalBounds().Contains(checkbox->bounds()));
  const gfx::Rect ok = view->GetOkButton()->GetBoundsInScreen();
  const gfx::Rect cancel = view->GetCancelButton()->GetBoundsInScreen();
  EXPECT_FALSE(ok.Intersects(cancel));
  const int button_center =
      (std::min(ok.x(), cancel.x()) + std::max(ok.right(), cancel.right())) / 2;
  EXPECT_NEAR(button_center, view->GetBoundsInScreen().CenterPoint().x(), 1);
  widget->CloseNow();
}

TEST_F(UninstallViewTest, LongTranslationExpandsWithoutCoveringChoices) {
  // 固定品牌宽度不应截断较长译文，也不能让正文覆盖删除选项或按钮。
  int result = -1;
  auto* view = new UninstallView(&result, base::DoNothing());
  auto* message = UninstallViewTestPeer::Message(*view);
  message->SetText(std::u16string(240, u'W'));
  message->SizeToFit(560);
  auto* widget =
      views::DialogDelegate::CreateDialogWidget(view, GetContext(), nullptr);
  widget->Show();
  EXPECT_GT(message->height(), 20);
  auto* checkbox = UninstallViewTestPeer::DeleteProfile(*view);
  EXPECT_LE(message->bounds().bottom(), checkbox->y());
  EXPECT_LE(checkbox->GetBoundsInScreen().bottom(),
            view->GetOkButton()->GetBoundsInScreen().y());
  widget->CloseNow();
}

TEST_F(UninstallViewTest, HighContrastRestoresSystemButtonColors) {
  // 模拟运行时强制色切换；离开高对比度后应恢复安装器的品牌色。
  int result = -1;
  auto* view = new UninstallView(&result, base::DoNothing());
  auto* widget =
      views::DialogDelegate::CreateDialogWidget(view, GetContext(), nullptr);
  auto* theme = view->GetNativeTheme();
  const auto original = theme->forced_colors();
  theme->set_forced_colors(ui::ColorProviderKey::ForcedColors::kSystem);
  view->OnThemeChanged();
  EXPECT_FALSE(view->GetOkButton()->GetBgColorOverrideDeprecated().has_value());
  EXPECT_FALSE(
      view->GetCancelButton()->GetStrokeColorOverrideDeprecated().has_value());
  theme->set_forced_colors(ui::ColorProviderKey::ForcedColors::kNone);
  view->OnThemeChanged();
  EXPECT_EQ(view->GetOkButton()->GetBgColorOverrideDeprecated(),
            SkColorSetRGB(0, 128, 160));
  theme->set_forced_colors(original);
  widget->CloseNow();
}
