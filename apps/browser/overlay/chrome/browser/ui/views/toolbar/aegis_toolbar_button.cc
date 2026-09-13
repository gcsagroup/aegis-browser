// Copyright 2026 GCSA

#include "chrome/browser/ui/views/toolbar/aegis_toolbar_button.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "build/build_config.h"
#include "chrome/browser/aegis/aegis_service_factory.h"
#include "chrome/browser/aegis/summary_session.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/views/location_bar/location_bar_bubble_delegate_view.h"
#include "chrome/common/webui_url_constants.h"
#include "components/vector_icons/vector_icons.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/referrer.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/models/image_model.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "ui/color/color_id.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/controls/button/md_text_button.h"
#include "ui/views/controls/label.h"
#include "ui/views/controls/scroll_view.h"
#include "ui/views/controls/throbber.h"
#include "ui/views/layout/box_layout.h"
#include "ui/views/style/typography.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"

namespace {

constexpr int kBubbleWidth = 440;
constexpr int kResultMaxHeight = 300;
constexpr base::TimeDelta kIntroDuration = base::Seconds(4);

aegis::AegisService* ServiceForBrowser(Browser* browser) {
  if (!browser) {
    return nullptr;
  }
  return aegis::AegisServiceFactory::GetForProfile(browser->profile());
}

aegis::AegisService* ServiceForWebContents(Browser* browser,
                                           content::WebContents* web_contents) {
  aegis::AegisService* service = ServiceForBrowser(browser);
  if (!service || !web_contents) {
    return nullptr;
  }
  Profile* source_profile =
      Profile::FromBrowserContext(web_contents->GetBrowserContext());
  return source_profile == browser->profile() &&
                 service->IsInitializedForProfile(source_profile)
             ? service
             : nullptr;
}

bool UseChinese() {
  return g_browser_process &&
         base::StartsWith(g_browser_process->GetApplicationLocale(), "zh",
                          base::CompareCase::INSENSITIVE_ASCII);
}

std::u16string Copy(std::u16string chinese,
                    std::u16string english,
                    std::u16string traditional) {
  const auto& locale = g_browser_process->GetApplicationLocale();
  if (locale.starts_with("zh-TW") || locale.starts_with("zh-HK")) {
    return traditional;
  }
  return UseChinese() ? std::move(chinese) : std::move(english);
}

std::u16string EventKind(const std::string& kind) {
  if (kind == "block") {
    return Copy(u"拦截", u"Blocked", u"攔截");
  }
  if (kind == "param") {
    return Copy(u"参数清理", u"Cleaned parameters", u"引數清理");
  }
  if (kind == "cookie") {
    return Copy(u"Cookie 清理", u"Cleaned cookies", u"Cookie 清理");
  }
  if (kind == "bounce") {
    return Copy(u"跳转清理", u"Cleared bounce tracking", u"跳轉清理");
  }
  if (kind == "phish") {
    return Copy(u"钓鱼拦截", u"Blocked phishing", u"釣魚攔截");
  }
  if (kind == "miner") {
    return Copy(u"挖矿风险（仅观察）", u"Mining risk (observe-only)",
                u"挖礦風險（僅觀察）");
  }
  return Copy(u"保护动作", u"Protection action", u"保護動作");
}

std::u16string ModelFormat(const std::string& provider) {
  if (provider == "anthropic") {
    return Copy(u"Claude（Anthropic）兼容", u"Anthropic compatible",
                u"Claude（Anthropic）相容");
  }
  if (provider == "gemini") {
    return Copy(u"Gemini 兼容", u"Gemini compatible", u"Gemini 相容");
  }
  return Copy(u"OpenAI 兼容", u"OpenAI compatible", u"OpenAI 相容");
}

views::Label* AddLabel(
    views::View* parent,
    std::u16string text,
    int text_context = views::style::CONTEXT_DIALOG_BODY_TEXT) {
  auto label = std::make_unique<views::Label>(std::move(text), text_context);
  label->SetHorizontalAlignment(gfx::ALIGN_LEFT);
  label->SetMultiLine(true);
  label->SetAllowCharacterBreak(true);
  return parent->AddChildView(std::move(label));
}

std::unique_ptr<views::View> CreatePanel() {
  auto panel = std::make_unique<views::View>();
  auto* layout = panel->SetLayoutManager(std::make_unique<views::BoxLayout>(
      views::BoxLayout::Orientation::kVertical, gfx::Insets(), 10));
  layout->set_cross_axis_alignment(
      views::BoxLayout::CrossAxisAlignment::kStretch);
  return panel;
}

std::unique_ptr<views::View> CreateButtonRow() {
  auto row = std::make_unique<views::View>();
  auto* layout = row->SetLayoutManager(std::make_unique<views::BoxLayout>(
      views::BoxLayout::Orientation::kHorizontal, gfx::Insets(), 8));
  layout->set_main_axis_alignment(views::BoxLayout::MainAxisAlignment::kEnd);
  return row;
}

class AegisPageBubble : public LocationBarBubbleDelegateView {
  METADATA_HEADER(AegisPageBubble, LocationBarBubbleDelegateView)

 public:
  AegisPageBubble(AegisToolbarButton* anchor,
                  Browser* browser,
                  aegis::PagePrivacySummary summary)
      : LocationBarBubbleDelegateView(
            views::BubbleAnchor(anchor),
            browser->tab_strip_model()->GetActiveWebContents(),
            /*autosize=*/true),
        browser_(browser),
        summary_(std::move(summary)) {
    SetButtons(static_cast<int>(ui::mojom::DialogButton::kNone));
    SetShowCloseButton(true);
    set_margins(gfx::Insets::VH(16, 18));
    const std::u16string title = Copy(
        u"Aegis 当前站点保护", u"Aegis site protection", u"Aegis 當前站點保護");
    SetTitle(title);
    SetAccessibleTitle(title);
    set_fixed_width(kBubbleWidth);
  }

  AegisPageBubble(const AegisPageBubble&) = delete;
  AegisPageBubble& operator=(const AegisPageBubble&) = delete;
  ~AegisPageBubble() override {
    if (summary_session_) {
      summary_session_->Cancel();
    }
  }

 private:
  void Init() override {
    auto* layout = SetLayoutManager(std::make_unique<views::BoxLayout>(
        views::BoxLayout::Orientation::kVertical, gfx::Insets(), 10));
    layout->set_cross_axis_alignment(
        views::BoxLayout::CrossAxisAlignment::kStretch);

    BuildProtectionPanel();
    BuildProgressPanel();
    BuildPreviewPanel();
    BuildResultPanel();
    ShowPanel(protection_panel_);
  }

  void BuildProtectionPanel() {
    protection_panel_ = AddChildView(CreatePanel());

    const std::u16string site =
        summary_.site_key.empty()
            ? Copy(u"当前内部页面", u"this internal page", u"當前內部頁面")
            : base::UTF8ToUTF16(summary_.site_key);
    AddLabel(protection_panel_,
             summary_.paused
                 ? Copy(u"此站的跟踪与清理规则已暂停 10 分钟",
                        u"Tracking and cleanup rules are paused for 10 minutes",
                        u"此站的跟蹤與清理規則已暫停 10 分鐘")
                 : Copy(u"Aegis 正在保护 ", u"Aegis is protecting ",
                        u"Aegis 正在保護 ") +
                       site,
             views::style::CONTEXT_DIALOG_TITLE);

    AddLabel(protection_panel_,
             Copy(u"本页已处理 ", u"Handled ", u"本頁已處理 ") +
                 base::NumberToString16(summary_.total) +
                 Copy(u" 项", u" items on this page", u" 項"));
    AddLabel(protection_panel_,
             Copy(u"阻止跟踪请求：", u"Blocked requests: ", u"阻止跟蹤請求：") +
                 base::NumberToString16(summary_.blocked));
    AddLabel(protection_panel_, Copy(u"清理链接与来源跟踪参数：",
                                     u"Cleaned link/referrer parameters: ",
                                     u"清理連結與來源跟蹤引數：") +
                                    base::NumberToString16(summary_.params));
    AddLabel(protection_panel_,
             Copy(u"清理跟踪 Cookie：", u"Cleaned tracking cookies: ",
                  u"清理跟蹤 Cookie：") +
                 base::NumberToString16(summary_.cookies));
    AddLabel(protection_panel_,
             Copy(u"挖矿风险提醒（仅观察）：",
                  u"Mining risk alerts (observe-only): ",
                  u"挖礦風險提醒（僅觀察）：") +
                 base::NumberToString16(summary_.miner_alerts));

    if (!summary_.events.empty()) {
      AddLabel(protection_panel_,
               Copy(u"最近发生了什么", u"Recent actions", u"最近發生了什麼"),
               views::style::CONTEXT_DIALOG_TITLE);
      const size_t visible_events = std::min<size_t>(5, summary_.events.size());
      for (size_t index = 0; index < visible_events; ++index) {
        const aegis::PrivacyEvent& event = summary_.events[index];
        const std::u16string domain = base::UTF8ToUTF16(
            event.display_domain.empty() ? event.site_key
                                         : event.display_domain);
        AddLabel(
            protection_panel_,
            u"• " + EventKind(event.kind) + u" · " + domain +
                (event.count > 1 ? u" ×" + base::NumberToString16(event.count)
                                 : std::u16string()));
      }
    }

    auto summarize_button = std::make_unique<views::MdTextButton>(
        base::BindRepeating(&AegisPageBubble::OpenSummary,
                            base::Unretained(this)),
        Copy(u"AI 摘要当前页", u"Summarize this page with AI",
             u"AI 摘要當前頁"));
    summarize_button->SetEnabled(CanSummarizeCurrentPage());
    if (!summarize_button->GetEnabled()) {
      summarize_button->SetTooltipText(
          Copy(u"AI 摘要仅支持普通网页", u"AI summary supports web pages only",
               u"AI 摘要僅支援一般網頁"));
    }
    protection_panel_->AddChildView(std::move(summarize_button));

    if (!summary_.site_key.empty()) {
      protection_panel_->AddChildView(std::make_unique<views::MdTextButton>(
          base::BindRepeating(&AegisPageBubble::TogglePause,
                              base::Unretained(this)),
          summary_.paused
              ? Copy(u"恢复此站默认保护", u"Restore protection for this site",
                     u"恢復此站預設保護")
              : Copy(u"为此站暂停 10 分钟并重新加载",
                     u"Pause this site for 10 minutes and reload",
                     u"為此站暫停 10 分鐘並重新載入")));
    }
    protection_panel_->AddChildView(std::make_unique<views::MdTextButton>(
        base::BindRepeating(&AegisPageBubble::OpenSettings,
                            base::Unretained(this)),
        Copy(u"打开防护中心", u"Open full settings", u"開啟防護中心")));
    AddLabel(protection_panel_,
             Copy(u"临时暂停不关闭钓鱼防护，也不会改变全局默认。",
                  u"Temporary pause keeps phishing protection on and "
                  u"does not change global defaults.",
                  u"臨時暫停不關閉釣魚防護，也不會改變全域性預設。"));
  }

  void BuildProgressPanel() {
    progress_panel_ = AddChildView(CreatePanel());
    progress_panel_->SetVisible(false);
    throbber_ =
        progress_panel_->AddChildView(std::make_unique<views::Throbber>());
    AddLabel(progress_panel_,
             Copy(u"AI 摘要当前页", u"AI page summary", u"AI 摘要當前頁"),
             views::style::CONTEXT_DIALOG_TITLE);
    progress_label_ = AddLabel(progress_panel_,
                               Copy(u"正在读取并脱敏当前页…",
                                    u"Reading and redacting the current page…",
                                    u"正在讀取並脫敏當前頁…"));
    progress_panel_->AddChildView(std::make_unique<views::MdTextButton>(
        base::BindRepeating(&AegisPageBubble::CancelSummary,
                            base::Unretained(this)),
        Copy(u"取消摘要", u"Cancel summary", u"取消摘要")));
  }

  void BuildPreviewPanel() {
    preview_panel_ = AddChildView(CreatePanel());
    preview_panel_->SetVisible(false);
    AddLabel(preview_panel_,
             Copy(u"摘要前确认", u"Confirm summary", u"摘要前確認"),
             views::style::CONTEXT_DIALOG_TITLE);
    preview_site_label_ = AddLabel(preview_panel_, std::u16string());
    preview_read_label_ = AddLabel(preview_panel_, std::u16string());
    preview_redacted_label_ = AddLabel(preview_panel_, std::u16string());
    preview_destination_label_ = AddLabel(preview_panel_, std::u16string());
    AddLabel(
        preview_panel_,
        Copy(u"不会显示或送出完整网址查询参数；非本机地址只有确认后才会发送脱敏"
             u"文本。",
             u"Full URL query values are never shown or sent. Redacted text "
             u"is sent to a non-local endpoint only after confirmation.",
             u"不會顯示或送出完整網址查詢引數；非本機地址只有確認後才會傳送脫敏"
             u"文字。"));

    auto buttons = CreateButtonRow();
    buttons->AddChildView(std::make_unique<views::MdTextButton>(
        base::BindRepeating(&AegisPageBubble::CancelSummary,
                            base::Unretained(this)),
        Copy(u"取消", u"Cancel", u"取消")));
    auto confirm = std::make_unique<views::MdTextButton>(
        base::BindRepeating(&AegisPageBubble::ConfirmSummary,
                            base::Unretained(this)),
        Copy(u"确认并摘要", u"Confirm and summarize", u"確認並摘要"));
    confirm->SetStyle(ui::ButtonStyle::kProminent);
    confirm_button_ = buttons->AddChildView(std::move(confirm));
    preview_panel_->AddChildView(std::move(buttons));
  }

  void BuildResultPanel() {
    result_panel_ = AddChildView(CreatePanel());
    result_panel_->SetVisible(false);
    AddLabel(result_panel_,
             Copy(u"AI 摘要结果", u"AI summary result", u"AI 摘要結果"),
             views::style::CONTEXT_DIALOG_TITLE);

    auto scroll_view = std::make_unique<views::ScrollView>();
    scroll_view->SetHorizontalScrollBarMode(
        views::ScrollView::ScrollBarMode::kDisabled);
    scroll_view->ClipHeightTo(80, kResultMaxHeight);
    auto result_contents = CreatePanel();
    result_label_ = AddLabel(result_contents.get(), std::u16string());
    result_label_->SetSelectable(true);
    result_label_->SetMaximumWidth(kBubbleWidth - 48);
    scroll_view->SetContents(std::move(result_contents));
    result_panel_->AddChildView(std::move(scroll_view));
    result_panel_->AddChildView(std::make_unique<views::MdTextButton>(
        base::BindRepeating(&AegisPageBubble::CancelSummary,
                            base::Unretained(this)),
        Copy(u"返回站点保护", u"Back to site protection", u"返回站點保護")));
  }

  void TogglePause() {
    content::WebContents* source =
        browser_->tab_strip_model()->GetActiveWebContents();
    aegis::AegisService* service = ServiceForWebContents(browser_, source);
    if (!service || summary_.site_key.empty()) {
      return;
    }
    service->SetSitePaused(summary_.site_key, !summary_.paused,
                           base::Minutes(10));
    if (GetWidget()) {
      GetWidget()->Close();
    }
    chrome::Reload(browser_, WindowOpenDisposition::CURRENT_TAB);
  }

  bool CanSummarizeCurrentPage() const {
    content::WebContents* source =
        browser_->tab_strip_model()->GetActiveWebContents();
    return ServiceForWebContents(browser_, source) &&
           source->GetLastCommittedURL().SchemeIsHTTPOrHTTPS();
  }

  void OpenSummary() {
    content::WebContents* source =
        browser_->tab_strip_model()->GetActiveWebContents();
    if (!ServiceForWebContents(browser_, source) ||
        !source->GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) {
      return;
    }
    summary_session_ = std::make_unique<aegis::SummarySession>(
        source, g_browser_process ? g_browser_process->GetApplicationLocale()
                                  : std::string("en"));
    ShowPanel(progress_panel_);
    progress_label_->SetText(Copy(u"正在读取并脱敏当前页…",
                                  u"Reading and redacting the current page…",
                                  u"正在讀取並脫敏當前頁…"));
    summary_session_->Begin(base::BindOnce(&AegisPageBubble::OnSummaryPrepared,
                                           weak_factory_.GetWeakPtr()));
  }

  void OnSummaryPrepared(aegis::SummarySession::Preview preview) {
    if (!preview.ok) {
      ShowError(base::UTF8ToUTF16(preview.error));
      return;
    }
    preview_ = std::move(preview);
    preview_site_label_->SetText(
        Copy(u"来源站点：", u"Source site: ", u"來源站點：") +
        base::UTF8ToUTF16(preview_.site));
    preview_read_label_->SetText(Copy(u"将读取的页面文字：",
                                      u"Page characters read: ",
                                      u"將讀取的頁面文字：") +
                                 base::NumberToString16(preview_.chars_read));
    preview_redacted_label_->SetText(
        Copy(u"脱敏后文字：", u"Characters after redaction: ",
             u"脫敏後文字：") +
        base::NumberToString16(preview_.chars_redacted));

    const std::u16string processing =
        !preview_.model_allowed ? Copy(u"在本机处理，不调用模型",
                                       u"On-device heuristic; no model call",
                                       u"在本機處理，不呼叫模型")
        : preview_.stayed_on_device
            ? Copy(u"本机处理", u"On-device processing", u"本機處理")
            : Copy(u"远程处理", u"Remote processing", u"遠端處理");
    preview_destination_label_->SetText(
        processing +
        Copy(u" · API 格式：", u" · API format: ", u" · API 格式：") +
        ModelFormat(preview_.provider) +
        Copy(u" · 模型：", u" · Model: ", u" · 模型：") +
        base::UTF8ToUTF16(preview_.model) +
        Copy(u" · 目标：", u" · Destination: ", u" · 目標：") +
        base::UTF8ToUTF16(preview_.base_url));
    ShowPanel(preview_panel_);
    confirm_button_->RequestFocus();
  }

  void ConfirmSummary() {
    if (!summary_session_) {
      return;
    }
    ShowPanel(progress_panel_);
    progress_label_->SetText(
        !preview_.model_allowed
            ? Copy(u"正在生成本机启发式摘要，不调用模型…",
                   u"Generating an on-device heuristic summary without a "
                   u"model call…",
                   u"正在生成本機啟發式摘要，不呼叫模型…")
        : preview_.stayed_on_device
            ? Copy(u"本机模型正在生成，最长等待 3 分钟…",
                   u"The local model is generating; allow up to 3 minutes…",
                   u"本機模型正在生成，最長等待 3 分鐘…")
            : Copy(u"兼容模型服务正在生成，最长等待 45 秒…",
                   u"The compatible model service is generating; allow up "
                   u"to 45 seconds…",
                   u"相容模型服務正在生成，最長等待 45 秒…"));
    summary_session_->Confirm(base::BindOnce(
        &AegisPageBubble::OnSummaryFinished, weak_factory_.GetWeakPtr()));
  }

  void OnSummaryFinished(aegis::SummarizeResult result) {
    std::u16string text;
    if (!result.ok && result.summary.empty()) {
      text = Copy(u"摘要失败：", u"Summary failed: ", u"摘要失敗：") +
             base::UTF8ToUTF16(result.error);
    } else {
      text = result.stayed_on_device
                 ? Copy(u"本机处理 · 未出网",
                        u"On-device · did not leave this computer",
                        u"本機處理 · 未出網")
                 : Copy(u"远程处理", u"Remote processing", u"遠端處理");
      text += Copy(u"\nAPI 格式：", u"\nAPI format: ", u"\nAPI 格式：") +
              ModelFormat(preview_.provider);
      text += Copy(u"\n模型：", u"\nModel: ", u"\n模型：") +
              base::UTF8ToUTF16(preview_.model);
      if (!result.summary.empty()) {
        text += u"\n\n" + base::UTF8ToUTF16(result.summary);
      }
      for (const std::string& item : result.bullets) {
        text += u"\n• " + base::UTF8ToUTF16(item);
      }
      if (!result.risks.empty()) {
        text += Copy(u"\n\n风险提示", u"\n\nRisk notes", u"\n\n風險提示");
        for (const std::string& item : result.risks) {
          text += u"\n• " + base::UTF8ToUTF16(item);
        }
      }
      if (!result.error.empty()) {
        text += Copy(u"\n\n模型调用未完成，已显示本机启发式结果：",
                     u"\n\nThe model call did not complete; showing the "
                     u"on-device heuristic result: ",
                     u"\n\n模型呼叫未完成，已顯示本機啟發式結果：") +
                base::UTF8ToUTF16(result.error);
      }
    }
    result_label_->SetText(text);
    ShowPanel(result_panel_);
    result_label_->GetViewAccessibility().AnnounceText(text);
  }

  void ShowError(std::u16string error) {
    result_label_->SetText(
        Copy(u"摘要失败：", u"Summary failed: ", u"摘要失敗：") + error);
    ShowPanel(result_panel_);
  }

  void CancelSummary() {
    summary_session_.reset();
    preview_ = aegis::SummarySession::Preview();
    ShowPanel(protection_panel_);
  }

  void ShowPanel(views::View* panel) {
    protection_panel_->SetVisible(panel == protection_panel_);
    progress_panel_->SetVisible(panel == progress_panel_);
    preview_panel_->SetVisible(panel == preview_panel_);
    result_panel_->SetVisible(panel == result_panel_);
    if (panel == progress_panel_) {
      throbber_->Start();
    } else {
      throbber_->Stop();
    }
    const std::u16string title =
        panel == protection_panel_
            ? Copy(u"Aegis 当前站点保护", u"Aegis site protection",
                   u"Aegis 當前站點保護")
            : Copy(u"AI 摘要当前页", u"AI page summary", u"AI 摘要當前頁");
    SetTitle(title);
    SetAccessibleTitle(title);
    PreferredSizeChanged();
  }

  void OpenSettings() {
    browser_->OpenURL(content::OpenURLParams(
                          GURL(chrome::kChromeUIAegisURL), content::Referrer(),
                          WindowOpenDisposition::NEW_FOREGROUND_TAB,
                          ui::PAGE_TRANSITION_LINK, false),
                      /*navigation_handle_callback=*/{});
    if (GetWidget()) {
      GetWidget()->Close();
    }
  }

  const raw_ptr<Browser> browser_;
  const aegis::PagePrivacySummary summary_;
  raw_ptr<views::View> protection_panel_ = nullptr;
  raw_ptr<views::View> progress_panel_ = nullptr;
  raw_ptr<views::View> preview_panel_ = nullptr;
  raw_ptr<views::View> result_panel_ = nullptr;
  raw_ptr<views::Throbber> throbber_ = nullptr;
  raw_ptr<views::Label> progress_label_ = nullptr;
  raw_ptr<views::Label> preview_site_label_ = nullptr;
  raw_ptr<views::Label> preview_read_label_ = nullptr;
  raw_ptr<views::Label> preview_redacted_label_ = nullptr;
  raw_ptr<views::Label> preview_destination_label_ = nullptr;
  raw_ptr<views::MdTextButton> confirm_button_ = nullptr;
  raw_ptr<views::Label> result_label_ = nullptr;
  aegis::SummarySession::Preview preview_;
  std::unique_ptr<aegis::SummarySession> summary_session_;
  base::WeakPtrFactory<AegisPageBubble> weak_factory_{this};
};

BEGIN_METADATA(AegisPageBubble)
END_METADATA

}  // namespace

AegisToolbarButton::AegisToolbarButton(Browser* browser)
    : ToolbarButton(base::BindRepeating(&AegisToolbarButton::OnPressed,
                                        base::Unretained(this))),
      browser_(browser) {
  SetVectorIcon(vector_icons::kShieldIcon);
  SetFlipCanvasOnPaintForRTLUI(false);
  SetLabelSideSpacing(4);
  GetViewAccessibility().SetHasPopup(ax::mojom::HasPopup::kDialog);
  if (aegis::AegisService* service = ServiceForBrowser(browser_)) {
    service->AddObserver(this);
    observed_service_ = service;
  }
  Update(browser_->tab_strip_model()->GetActiveWebContents());
}

AegisToolbarButton::~AegisToolbarButton() {
  if (observed_service_) {
    observed_service_->RemoveObserver(this);
    observed_service_ = nullptr;
  }
  if (bubble_tracker_.view() && bubble_tracker_.view()->GetWidget()) {
    bubble_tracker_.view()->GetWidget()->Close();
  }
}

void AegisToolbarButton::Update(content::WebContents* web_contents) {
  web_contents_ = web_contents ? web_contents->GetWeakPtr() : nullptr;
  Refresh();
}

void AegisToolbarButton::OnAegisStateChanged() {
  Update(browser_->tab_strip_model()->GetActiveWebContents());
}

void AegisToolbarButton::OnPressed() {
  if (!aegis::IsAegisProfileSupported(browser_->profile())) {
    return;
  }
  if (bubble_tracker_.view() && bubble_tracker_.view()->GetWidget()) {
    bubble_tracker_.view()->GetWidget()->Close();
    return;
  }
  content::WebContents* const contents = web_contents_.get();
  if (!contents) {
    return;
  }
  aegis::PagePrivacySummary summary;
  if (aegis::AegisService* service =
          ServiceForWebContents(browser_, contents)) {
    summary = service->GetPageSummary(contents);
  }
  auto bubble =
      std::make_unique<AegisPageBubble>(this, browser_, std::move(summary));
  bubble_tracker_.SetView(bubble.get());
  auto* bubble_view = bubble.get();
  views::BubbleDialogDelegateView::CreateBubble(std::move(bubble));
  bubble_view->ShowForReason(LocationBarBubbleDelegateView::USER_GESTURE);
}

void AegisToolbarButton::Refresh() {
  const bool profile_supported =
      aegis::IsAegisProfileSupported(browser_->profile());
  SetVisible(profile_supported);
  SetEnabled(profile_supported);
  if (!profile_supported) {
    intro_timer_.Stop();
    SetHighlight(std::u16string(), std::nullopt);
    SetText(std::u16string());
    PreferredSizeChanged();
    return;
  }

  content::WebContents* const contents = web_contents_.get();
  aegis::AegisService* service = ServiceForWebContents(browser_, contents);
  if (!service) {
    intro_timer_.Stop();
    SetHighlight(std::u16string(), std::nullopt);
    SetText(std::u16string());
    const std::u16string status =
        Copy(u"Aegis：此用户资料不可用", u"Aegis: unavailable for this profile",
             u"Aegis：此使用者資料不可用");
    SetTooltipText(status);
    GetViewAccessibility().SetName(status);
    PreferredSizeChanged();
    return;
  }
  const aegis::PagePrivacySummary summary = service->GetPageSummary(contents);

  std::u16string label;
  if (summary.paused) {
    label = Copy(u"暂停", u"Paused", u"暫停");
  } else if (summary.miner_alerts > 0) {
    label = u"!";
  } else if (summary.total > 0) {
    label = summary.total > 99 ? u"99+" : base::NumberToString16(summary.total);
  }
  SetText(label);

  std::u16string status =
      summary.paused ? Copy(u"Aegis：此站保护已临时暂停",
                            u"Aegis: protection paused for this site",
                            u"Aegis：此站保護已臨時暫停")
      : summary.miner_alerts > 0
          ? Copy(u"Aegis：本页有挖矿风险历史提醒（仅观察，未阻断）",
                 u"Aegis: prior mining-risk alert (observe-only)",
                 u"Aegis：本頁有挖礦風險歷史提醒（僅觀察，未阻斷）")
      : summary.total > 0
          ? Copy(u"Aegis：本页已处理 ", u"Aegis: handled ",
                 u"Aegis：本頁已處理 ") +
                base::NumberToString16(summary.total) +
                Copy(u" 项", u" items on this page", u" 項")
          : Copy(u"Aegis：防护正常", u"Aegis: protection active",
                 u"Aegis：防護正常");
  SetTooltipText(status);
  GetViewAccessibility().SetName(status);
  PreferredSizeChanged();

  if (summary.total > 0 && service->ShouldShowAwarenessIntro() && GetWidget()) {
    SetHighlight(Copy(u"Aegis 已保护本页", u"Aegis protected this page",
                      u"Aegis 已保護本頁"),
                 std::nullopt);
    service->MarkAwarenessIntroShown();
    intro_timer_.Start(FROM_HERE, kIntroDuration,
                       base::BindOnce(&AegisToolbarButton::ClearIntroHighlight,
                                      base::Unretained(this)));
  }
}

void AegisToolbarButton::ClearIntroHighlight() {
  SetHighlight(std::u16string(), std::nullopt);
}

BEGIN_METADATA(AegisToolbarButton)
END_METADATA
