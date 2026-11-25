// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Windows 卸载确认展示：沿用安装器品牌与留白，只返回选择，不删除文件或资料。

#include "chrome/browser/ui/views/uninstall_view.h"

#include <algorithm>
#include <memory>
#include <optional>

#include "base/functional/bind.h"
#include "base/run_loop.h"
#include "base/task/current_thread.h"
#include "chrome/browser/ui/uninstall_browser_prompt.h"
#include "chrome/common/chrome_result_codes.h"
#include "chrome/grit/branded_strings.h"
#include "chrome/grit/chrome_unscaled_resources.h"
#include "ui/base/hit_test.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/models/image_model.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/base/resource/resource_bundle.h"
#include "ui/color/color_id.h"
#include "ui/color/color_provider.h"
#include "ui/gfx/font_list.h"
#include "ui/gfx/image/image.h"
#include "ui/native_theme/native_theme.h"
#include "ui/views/bubble/bubble_frame_view.h"
#include "ui/views/controls/button/checkbox.h"
#include "ui/views/controls/button/md_text_button.h"
#include "ui/views/controls/image_view.h"
#include "ui/views/controls/label.h"
#include "ui/views/layout/box_layout.h"
#include "ui/views/layout/layout_provider.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/widget/widget.h"
#include "ui/views/window/non_client_view.h"

namespace {
// 与 mini_installer/aegis_install_ui.cc 使用相同的 DIP 尺寸和品牌色；
// Views 负责按显示器 DPI 渲染，不缩放整窗位图。长译文可自然增加窗口高度。
constexpr int kWidth = 640;
constexpr int kContentWidth = 560;
constexpr SkColor kInk = SkColorSetRGB(23, 36, 54);
constexpr SkColor kMuted = SkColorSetRGB(102, 116, 134);
constexpr SkColor kAccent = SkColorSetRGB(0, 128, 160);
constexpr SkColor kSecondary = SkColorSetRGB(231, 238, 244);
}  // namespace

UninstallView::UninstallView(int* user_selection,
                           const base::RepeatingClosure& quit_closure)
    : user_selection_(*user_selection), quit_closure_(quit_closure) {
  // 只有明确接受才能继续卸载；窗口异常销毁也不能误报用户同意。
  *user_selection_ = CHROME_RESULT_CODE_UNINSTALL_USER_CANCEL;
  SetupControls();
}

UninstallView::~UninstallView() {
  // 选择由调用方持有，退出嵌套消息循环后才交给 setup 执行实际卸载。
  quit_closure_.Run();
}

void UninstallView::SetupControls() {
  SetTitle(IDS_UNINSTALL_CHROME);
  SetShowTitle(false);
  SetShowCloseButton(false);
  SetButtonLabel(ui::mojom::DialogButton::kOk,
                 l10n_util::GetStringUTF16(IDS_UNINSTALL_BUTTON_TEXT));
  // 保留 DialogDelegate 的输入保护、Esc、Tab 和辅助功能；默认焦点为取消，
  // 打开窗口后直接按回车不能无意卸载，更不能默认删除用户资料。
  SetDefaultButton(static_cast<int>(ui::mojom::DialogButton::kCancel));
  SetButtonStyle(ui::mojom::DialogButton::kOk, ui::ButtonStyle::kProminent);
  SetButtonStyle(ui::mojom::DialogButton::kCancel, ui::ButtonStyle::kTonal);
  SetAcceptCallback(base::BindOnce(&UninstallView::OnDialogAccepted,
                                  base::Unretained(this)));
  SetCancelCallback(base::BindOnce(&UninstallView::OnDialogCancelled,
                                  base::Unretained(this)));
  SetCloseCallback(base::BindOnce(&UninstallView::OnDialogCancelled,
                                 base::Unretained(this)));
  set_frame_margins({.contents = gfx::Insets(), .title = gfx::Insets()});

  auto* layout = SetLayoutManager(std::make_unique<views::BoxLayout>(
      views::BoxLayout::Orientation::kVertical,
      gfx::Insets::TLBR(62, 40, 0, 40)));
  layout->set_cross_axis_alignment(views::BoxLayout::CrossAxisAlignment::kCenter);
  auto* logo = AddChildView(std::make_unique<views::ImageView>());
  // 使用与安装器 ICO 相同的 256px 应用图标；通用 PRODUCT_LOGO 是透明品牌标志，
  // 不是安装器使用的蓝底图标。源图保留足够像素供高 DPI 的 80 DIP 展示采样。
  logo->SetImage(ui::ImageModel::FromImageSkia(
      ui::ResourceBundle::GetSharedInstance()
          .GetImageNamed(IDR_AEGIS_WINDOWS_APP_ICON)
          .AsImageSkia()));
  logo->SetImageSize(gfx::Size(80, 80));
  logo->SetProperty(views::kMarginsKey, gfx::Insets::TLBR(0, 0, 22, 0));

  title_ = AddChildView(std::make_unique<views::Label>(u"Aegis Browser"));
  title_->SetFontList(gfx::FontList({"Segoe UI"}, gfx::Font::NORMAL, 34,
                                  gfx::Font::Weight::SEMIBOLD));
  title_->SetPreferredSize(gfx::Size(kContentWidth, 48));
  title_->SetProperty(views::kMarginsKey, gfx::Insets::TLBR(0, 0, 24, 0));

  const gfx::FontList body_font({"Microsoft YaHei UI", "Segoe UI"},
                                gfx::Font::NORMAL, 14,
                                gfx::Font::Weight::NORMAL);
  message_ = AddChildView(std::make_unique<views::Label>(
      l10n_util::GetStringUTF16(IDS_UNINSTALL_VERIFY)));
  message_->SetFontList(body_font);
  message_->SetMultiLine(true);
  // 连续长词也允许换行，避免窄屏或较长译文被静默截断。
  message_->SetAllowCharacterBreak(true);
  message_->SetLineHeight(20);
  message_->SizeToFit(kContentWidth);
  message_->SetProperty(views::kMarginsKey, gfx::Insets::TLBR(0, 0, 16, 0));

  delete_profile_ = AddChildView(std::make_unique<views::Checkbox>(
      l10n_util::GetStringUTF16(IDS_UNINSTALL_DELETE_PROFILE)));
  delete_profile_->SetMultiLine(true);
  delete_profile_->SetMinSize(gfx::Size(0, 24));
  delete_profile_->SetMaxSize(gfx::Size(kContentWidth, 0));
  delete_profile_->SetChecked(false);
}

void UninstallView::OnWidgetInitialized() {
  views::DialogDelegateView::OnWidgetInitialized();
  for (auto* button : {GetOkButton(), GetCancelButton()}) {
    button->SetMinSize(gfx::Size(112, 40));
    button->SetCornerRadius(8);
  }
  // 仍由框架创建和处理确认按钮；根据译文实际宽度计算居中留白。
  const int button_width =
      std::max(GetOkButton()->GetPreferredSize().width(),
               GetCancelButton()->GetPreferredSize().width());
  const int spacing = views::LayoutProvider::Get()->GetDistanceMetric(
      views::DISTANCE_RELATED_BUTTON_HORIZONTAL);
  const int inset = std::max(40, (kWidth - 2 * button_width - spacing) / 2);
  SetButtonRowInsets(gfx::Insets::TLBR(24, inset, 40, inset));
  auto* frame = GetBubbleFrameView();
  frame->bubble_border()->set_draw_border_stroke(false);
  frame->bubble_border()->set_rounded_corners(gfx::RoundedCornersF(8));
  // 顶部留白为拖动区；不把正文、复选框或按钮误判为标题栏。
  frame->set_non_client_hit_test_callback(base::BindRepeating(
      [](views::BubbleFrameView* frame, const gfx::Point& point) {
        const gfx::Rect bounds = frame->GetBoundsForClientView();
        return bounds.Contains(point) && point.y() < bounds.y() + 36
                   ? HTCAPTION
                   : HTNOWHERE;
      },
      base::Unretained(frame)));
  UpdateColors();
  // 按完成初始化后的按钮和译文尺寸居中，避免框架的初始按钮高度压缩正文。
  GetWidget()->CenterWindow(
      GetWidget()->non_client_view()->GetPreferredSize({}));
}

void UninstallView::OnThemeChanged() {
  views::DialogDelegateView::OnThemeChanged();
  // 初次加入控件树时按钮可能尚未创建；初始化完成后还会统一更新一次。
  if (GetWidget() && GetBubbleFrameView() && GetOkButton() && GetCancelButton()) {
    UpdateColors();
  }
}

void UninstallView::UpdateColors() {
  // 普通明暗主题都与白底安装器一致；系统强制高对比度时恢复系统色，
  // 不强行套用青蓝背景或白字，以免覆盖用户的可读性设置。
  const bool high_contrast =
      GetNativeTheme()->forced_colors() !=
      ui::ColorProviderKey::ForcedColors::kNone;
  const auto* colors = GetColorProvider();
  const SkColor background =
      high_contrast ? colors->GetColor(ui::kColorDialogBackground) : SK_ColorWHITE;
  const SkColor ink =
      high_contrast ? colors->GetColor(ui::kColorLabelForeground) : kInk;
  GetBubbleFrameView()->SetBackgroundColor(background);
  title_->SetEnabledColor(ink);
  message_->SetEnabledColor(high_contrast ? ink : kMuted);
  title_->SetBackgroundColor(background);
  message_->SetBackgroundColor(background);
  delete_profile_->SetEnabledTextColors(ink);
  for (auto* button : {GetOkButton(), GetCancelButton()}) {
    const bool primary = button == GetOkButton();
    button->SetBgColorOverrideDeprecated(
        high_contrast ? std::nullopt
                      : std::make_optional(primary ? kAccent : kSecondary));
    button->SetStrokeColorOverrideDeprecated(
        high_contrast ? std::nullopt : std::make_optional(SK_ColorTRANSPARENT));
    button->SetEnabledTextColors(high_contrast
                                    ? std::nullopt
                                    : std::make_optional(ui::ColorVariant(
                                          primary ? SK_ColorWHITE : kInk)));
  }
}

void UninstallView::OnDialogAccepted() {
  *user_selection_ = content::RESULT_CODE_NORMAL_EXIT;
  if (delete_profile_->GetChecked()) {
    *user_selection_ = CHROME_RESULT_CODE_UNINSTALL_DELETE_PROFILE;
  }
}

void UninstallView::OnDialogCancelled() {
  *user_selection_ = CHROME_RESULT_CODE_UNINSTALL_USER_CANCEL;
}

BEGIN_METADATA(UninstallView)
END_METADATA

int ShowUninstallBrowserPrompt() {
  CHECK(base::CurrentUIThread::IsSet(), base::NotFatalUntil::M162);
  int result = CHROME_RESULT_CODE_UNINSTALL_USER_CANCEL;
  base::RunLoop run_loop;
  auto* view = new UninstallView(&result, run_loop.QuitClosure());
  views::DialogDelegate::CreateDialogWidget(view, nullptr, nullptr)->Show();
  run_loop.Run();
  return result;
}
