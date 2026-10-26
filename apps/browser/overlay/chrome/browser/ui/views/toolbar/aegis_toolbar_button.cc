// Copyright 2026 GCSA

#include "chrome/browser/ui/views/toolbar/aegis_toolbar_button.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "build/build_config.h"
#include "chrome/browser/aegis/aegis_service_factory.h"
#include "chrome/browser/aegis/enhancements/enhancement_store.h"
#include "chrome/browser/aegis/enhancements/enhancement_tab_helper.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "ui/views/controls/button/checkbox.h"
#include "url/origin.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
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
constexpr base::TimeDelta kIntroDuration = base::Seconds(4);

aegis::AegisService* ServiceForBrowser(BrowserWindowInterface* browser) {
  if (!browser) {
    return nullptr;
  }
  return aegis::AegisServiceFactory::GetForProfile(browser->GetProfile());
}

aegis::AegisService* ServiceForWebContents(
    BrowserWindowInterface* browser,
    content::WebContents* web_contents) {
  aegis::AegisService* service = ServiceForBrowser(browser);
  if (!service || !web_contents) {
    return nullptr;
  }
  Profile* source_profile =
      Profile::FromBrowserContext(web_contents->GetBrowserContext());
  return source_profile == browser->GetProfile() &&
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
    return Copy(u"疑似钓鱼（已拦截）", u"Suspected phishing (blocked)",
                u"疑似釣魚（已攔截）");
  }
  if (kind == "miner") {
    return Copy(u"挖矿风险（仅观察）", u"Mining risk (observe-only)",
                u"挖礦風險（僅觀察）");
  }
  return Copy(u"保护动作", u"Protection action", u"保護動作");
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

// 面板始终绑定打开时的文档；切换标签或导航后关闭，避免操作落到别的网页。
class AegisPageBubble : public LocationBarBubbleDelegateView {
  METADATA_HEADER(AegisPageBubble, LocationBarBubbleDelegateView)
 public:
  AegisPageBubble(AegisToolbarButton* anchor,
                  BrowserWindowInterface* browser,
                  aegis::PagePrivacySummary summary)
      : LocationBarBubbleDelegateView(views::BubbleAnchor(anchor),
            browser->GetTabStripModel()->GetActiveWebContents(), true),
        browser_(browser), summary_(std::move(summary)),
        source_(browser->GetTabStripModel()->GetActiveWebContents()->GetWeakPtr()) {
    SetButtons(static_cast<int>(ui::mojom::DialogButton::kNone));
    SetShowCloseButton(true);
    set_margins(gfx::Insets::VH(16, 18));
    const auto title = Copy(u"当前网站", u"Current website", u"目前網站");
    SetTitle(title);
    SetAccessibleTitle(title);
    set_fixed_width(kBubbleWidth);
    address_ = source_->GetLastCommittedURL();
    if (auto* helper = Helper()) {
      document_ = aegis::EnhancementField(helper->Snapshot(), "document");
      tab_ = aegis::EnhancementField(helper->Snapshot(), "id");
    }
  }
 private:
  aegis::EnhancementTabHelper* Helper() const {
    return source_ ? aegis::EnhancementTabHelper::FromWebContents(source_.get()) : nullptr;
  }
  bool Valid() const {
    return source_ && browser_->GetTabStripModel()->GetActiveWebContents() == source_.get() &&
           source_->GetLastCommittedURL() == address_ &&
           (!Helper() || aegis::EnhancementField(Helper()->Snapshot(), "document") == document_);
  }
  void Init() override {
    SetLayoutManager(std::make_unique<views::BoxLayout>(
        views::BoxLayout::Orientation::kVertical));
    auto scroll = std::make_unique<views::ScrollView>();
    scroll->SetHorizontalScrollBarMode(views::ScrollView::ScrollBarMode::kDisabled);
    scroll->ClipHeightTo(80, 580);
    panel_ = scroll->SetContents(CreatePanel());
    AddChildView(std::move(scroll));
    Build();
    timer_.Start(FROM_HERE, base::Milliseconds(500), this, &AegisPageBubble::Poll);
  }
  void Poll() {
    if (!Valid()) {
      if (GetWidget()) GetWidget()->Close();
      return;
    }
    auto* store = aegis::EnhancementStore::Get(browser_->GetProfile());
    const auto snapshot = Helper() ? Helper()->Snapshot() : base::DictValue();
    const int revision = store->state().FindInt("revision").value_or(0);
    if (revision != revision_ || snapshot != snapshot_) Build();
  }
  void RefreshSoon() {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&AegisPageBubble::Build, weak_.GetWeakPtr()));
  }
  void Button(views::View* parent, std::u16string title, base::RepeatingClosure action) {
    parent->AddChildView(std::make_unique<views::MdTextButton>(std::move(action), std::move(title)));
  }
  void Toggle(views::View* parent, std::u16string title, bool value,
              base::RepeatingClosure action) {
    auto checkbox = std::make_unique<views::Checkbox>(std::move(title), std::move(action));
    checkbox->SetChecked(value);
    parent->AddChildView(std::move(checkbox));
  }
  void Expand(const std::string& key) {
    if (!expanded_.erase(key)) expanded_.insert(key);
    RefreshSoon();
  }
  void Mutate(base::DictValue request) {
    if (!Valid()) return;
    aegis::EnhancementStore::Get(browser_->GetProfile())->Mutate(
        request, base::BindOnce([](base::WeakPtr<AegisPageBubble> self, std::string error) {
          if (!self || !self->Valid()) return;
          self->notice_ = error.empty()
              ? Copy(u"已保存，重新加载后生效。", u"Saved. Reload to apply.", u"已儲存，重新載入後生效。")
              : base::UTF8ToUTF16(error);
          self->RefreshSoon();
        }, weak_.GetWeakPtr()));
  }
  void ChangeRule(std::string key) {
    if (!Valid()) return;
    auto* store = aegis::EnhancementStore::Get(browser_->GetProfile());
    // 快捷开关只写当前精确来源；不意外改变父域名已有的子域规则。
    base::DictValue rule = store->Rule(address_) ? store->Rule(address_)->Clone() : base::DictValue();
    const auto origin = url::Origin::Create(address_).Serialize();
    if (aegis::EnhancementField(rule, "origin") != origin) rule.Set("subdomains", false);
    rule.Set("origin", origin);
    for (const auto* field : {"menu", "copy", "debug", "subdomains", "disabled"})
      if (!rule.FindBool(field)) rule.Set(field, false);
    rule.Set(key, !rule.FindBool(key).value_or(false));
    Mutate(base::DictValue().Set("op", "site-save").Set("rule", std::move(rule)));
  }
  void SiteScript(std::string id) {
    if (!Valid()) return;
    const auto* script = aegis::EnhancementStore::Get(browser_->GetProfile())->Script(id);
    if (!script || !script->FindBool("enabled").value_or(false)) return;
    Mutate(base::DictValue().Set("op", "script-site").Set("id", id)
               .Set("revision", script->FindInt("revision").value_or(0))
               .Set("origin", url::Origin::Create(address_).Serialize())
               .Set("enabled", aegis::EnhancementStore::PausedAt(*script, address_)));
  }
  void Menu(std::string id) {
    if (!Valid() || !Helper()) return;
    Helper()->RunMenu(id, base::BindOnce([](base::WeakPtr<AegisPageBubble> self, base::DictValue result) {
      if (!self || !self->Valid()) return;
      const auto error = aegis::EnhancementField(result, "error");
      self->notice_ = !error.empty() ? base::UTF8ToUTF16(error)
          : result.FindDictByDottedPath("result.exceptionDetails")
              ? Copy(u"脚本命令执行失败，请查看详情。", u"Script command failed. See details.", u"腳本命令執行失敗，請查看詳情。")
              : Copy(u"已调用脚本命令，请检查页面。", u"Command called. Check the page.", u"已呼叫腳本命令，請檢查頁面。");
      self->RefreshSoon();
    }, weak_.GetWeakPtr()));
  }
  void OpenDetails() {
    if (!source_) return;
    source_->OpenURL(content::OpenURLParams(GURL("chrome://aegis/?workspace=protection"),
        content::Referrer(), WindowOpenDisposition::NEW_FOREGROUND_TAB,
        ui::PAGE_TRANSITION_LINK, false), {});
    if (GetWidget()) GetWidget()->Close();
  }
  void OpenReading() {
    if (!Valid()) return;
    content::OpenURLParams params(GURL("chrome://aegis/markdown.html#tab=" + tab_),
        content::Referrer(), WindowOpenDisposition::NEW_FOREGROUND_TAB,
        ui::PAGE_TRANSITION_LINK, false);
    source_->OpenURL(params, {});
    if (GetWidget()) GetWidget()->Close();
  }
  void OpenManager(std::string script) {
    if (!Valid()) return;
    content::OpenURLParams params(
        GURL((script.empty() ? "chrome://settings/aegisEnhancements#tab=" : "chrome://aegis/enhancements.html#tab=") + tab_ + "&script=" + script),
        content::Referrer(), WindowOpenDisposition::NEW_FOREGROUND_TAB,
        ui::PAGE_TRANSITION_LINK, false);
    source_->OpenURL(params, {});
    if (GetWidget()) GetWidget()->Close();
  }
  void Reload() {
    if (!Valid()) return;
    if (GetWidget()) GetWidget()->Close();
    chrome::Reload(browser_, WindowOpenDisposition::CURRENT_TAB);
  }
  void Pause() {
    if (!Valid()) return;
    if (auto* service = ServiceForWebContents(browser_, source_.get())) {
      service->SetSitePaused(summary_.site_key, !summary_.paused, base::Minutes(10));
      summary_ = service->GetPageSummary(source_.get());
      notice_ = Copy(u"保护设置已保存，重新加载后应用。", u"Protection saved. Reload to apply.", u"保護設定已儲存，重新載入後套用。");
      RefreshSoon();
    }
  }
  void Build() {
    if (!Valid()) return;
    auto* store = aegis::EnhancementStore::Get(browser_->GetProfile());
    snapshot_ = Helper() ? Helper()->Snapshot() : base::DictValue();
    revision_ = store->state().FindInt("revision").value_or(0);
    panel_->RemoveAllChildViews();
    if (!address_.SchemeIsHTTPOrHTTPS()) {
      AddLabel(panel_, Copy(u"浏览器内部页面", u"Browser internal page", u"瀏覽器內部頁面"), views::style::CONTEXT_DIALOG_TITLE);
      AddLabel(panel_, Copy(u"此页面不支持网站增强与用户脚本。", u"Website enhancements and scripts are unavailable here.", u"此頁面不支援網站增強與使用者腳本。"));
      Button(panel_, Copy(u"网站增强与脚本设置", u"Enhancement and script settings", u"網站增強與腳本設定"),
             base::BindRepeating(&AegisPageBubble::OpenManager, base::Unretained(this), std::string()));
      return;
    }
    AddLabel(panel_, base::UTF8ToUTF16(address_.host()), views::style::CONTEXT_DIALOG_TITLE);
    if (browser_->GetProfile()->IsOffTheRecord())
      AddLabel(panel_, Copy(u"私密会话 · 设置与脚本仅保留在本次会话", u"Private session · settings and scripts stay in this session", u"私密階段 · 設定與腳本僅保留於本次階段"));
    AddLabel(panel_, Copy(u"隐私保护", u"Privacy protection", u"隱私保護"), views::style::CONTEXT_DIALOG_TITLE);
    AddLabel(panel_, (summary_.paused ? Copy(u"本站保护已暂停 · ", u"Protection paused · ", u"本站保護已暫停 · ")
                                    : Copy(u"保护已开启 · ", u"Protection on · ", u"保護已開啟 · ")) +
                         base::NumberToString16(summary_.total) + Copy(u" 项处理", u" actions", u" 項處理"));
    if (summary_.miner_alerts > 0)
      AddLabel(panel_, Copy(u"发现挖矿风险（仅观察）", u"Mining risk detected (observe-only)", u"發現挖礦風險（僅觀察）"));
    Button(panel_, Copy(u"保护明细", u"Protection details", u"保護明細"),
           base::BindRepeating(&AegisPageBubble::Expand, base::Unretained(this), "privacy"));
    if (expanded_.contains("privacy")) {
      AddLabel(panel_, Copy(u"拦截请求 / 参数清理 / Cookie：", u"Blocked / parameters / cookies: ", u"攔截請求 / 參數清理 / Cookie：") +
                        base::NumberToString16(summary_.blocked) + u" / " + base::NumberToString16(summary_.params) + u" / " + base::NumberToString16(summary_.cookies));
      for (size_t i = 0; i < std::min<size_t>(3, summary_.events.size()); ++i)
        AddLabel(panel_, EventKind(summary_.events[i].kind) + u" · " + base::UTF8ToUTF16(summary_.events[i].display_domain));
      Button(panel_, summary_.paused ? Copy(u"恢复本站保护", u"Resume protection", u"恢復本站保護")
                                     : Copy(u"暂停本站保护 10 分钟", u"Pause protection for 10 minutes", u"暫停本站保護 10 分鐘"),
             base::BindRepeating(&AegisPageBubble::Pause, base::Unretained(this)));
      AddLabel(panel_, Copy(u"临时暂停不关闭钓鱼保护。", u"Temporary pause keeps phishing protection on.", u"臨時暫停不關閉釣魚保護。"));
    }
    AddLabel(panel_, Copy(u"网站增强", u"Website enhancements", u"網站增強"), views::style::CONTEXT_DIALOG_TITLE);
    if (!store->ready() || !store->error().empty()) {
      AddLabel(panel_, base::UTF8ToUTF16(store->error().empty() ? "正在读取设置…" : store->error()));
      return;
    }
    const auto* rule = store->Rule(address_);
    const auto flag = [&](const char* key) { return rule && rule->FindBool(key).value_or(false); };
    Toggle(panel_, Copy(u"恢复右键菜单", u"Restore context menu", u"恢復右鍵選單"), flag("menu"),
           base::BindRepeating(&AegisPageBubble::ChangeRule, base::Unretained(this), "menu"));
    Toggle(panel_, Copy(u"允许选取和复制", u"Allow selection and copy", u"允許選取與複製"), flag("copy"),
           base::BindRepeating(&AegisPageBubble::ChangeRule, base::Unretained(this), "copy"));
    if (flag("disabled")) AddLabel(panel_, Copy(u"本站增强已暂停", u"Enhancements paused for this site", u"本站增強已暫停"));
    Button(panel_, Copy(u"更多选项与适用范围", u"More options and scope", u"更多選項與適用範圍"),
           base::BindRepeating(&AegisPageBubble::Expand, base::Unretained(this), "scope"));
    if (expanded_.contains("scope")) {
      Toggle(panel_, Copy(u"网页调试兼容", u"Web debugging compatibility", u"網頁偵錯相容"), flag("debug"),
             base::BindRepeating(&AegisPageBubble::ChangeRule, base::Unretained(this), "debug"));
      AddLabel(panel_, Copy(u"处理部分网页的调试干扰，不关闭普通断点。", u"Handles some page debugging interference; keeps normal breakpoints.", u"處理部分網頁的偵錯干擾，保留一般中斷點。"));
      Toggle(panel_, Copy(u"将当前网站规则也用于其子域名", u"Also apply this site's rules to its subdomains", u"將目前網站規則也用於其子網域"), flag("subdomains"),
             base::BindRepeating(&AegisPageBubble::ChangeRule, base::Unretained(this), "subdomains"));
      Toggle(panel_, Copy(u"暂停本站增强", u"Pause site enhancements", u"暫停本站增強"), flag("disabled"),
             base::BindRepeating(&AegisPageBubble::ChangeRule, base::Unretained(this), "disabled"));
      AddLabel(panel_, base::UTF8ToUTF16(url::Origin::Create(address_).Serialize()));
    }
    AddLabel(panel_, Copy(u"本页脚本", u"Scripts on this page", u"本頁腳本"), views::style::CONTEXT_DIALOG_TITLE);
    const auto* statuses = snapshot_.FindDict("statuses");
    const auto* menus = snapshot_.FindList("menus");
    size_t visible = 0;
    for (const auto& value : *store->state().FindList("scripts")) {
      const auto& script = value.GetDict();
      const auto id = aegis::EnhancementField(script, "id");
      const auto* status = statuses ? statuses->FindDict(id) : nullptr;
      if (!status && !aegis::EnhancementStore::Applies(script, address_, true)) continue;
      if (++visible > 4 && !expanded_.contains("all")) continue;
      const bool enabled = script.FindBool("enabled").value_or(false);
      const bool paused = aegis::EnhancementStore::PausedAt(script, address_);
      std::u16string state;
      const auto result = status ? aegis::EnhancementField(*status, "status") : "";
      if (status && status->FindBool("trial").value_or(false))
        state = Copy(u"试运行 · ", u"Trial · ", u"試執行 · ");
      state += result == "completed" ? Copy(u"已执行", u"Executed", u"已執行")
             : result == "running" ? Copy(u"执行中", u"Running", u"執行中")
             : result == "failed" ? Copy(u"执行失败", u"Failed", u"執行失敗")
             : !enabled ? Copy(u"已停用 / 待授权", u"Disabled / needs permission", u"已停用 / 待授權")
             : paused ? Copy(u"本站已停用", u"Disabled on this site", u"本站已停用")
             : aegis::EnhancementField(script, "world") == "page"
                 ? Copy(u"已启用 · 无执行回执", u"Enabled · no execution receipt", u"已啟用 · 無執行回報")
                 : Copy(u"等待重新加载", u"Waiting for reload", u"等待重新載入");
      if (status && !status->FindBool("mainFrame").value_or(true))
        state += Copy(u"（子框架）", u" (subframe)", u"（子框架）");
      Button(panel_, base::UTF8ToUTF16(aegis::EnhancementField(*script.FindDict("metadata"), "name")) + u" · " + state,
             base::BindRepeating(&AegisPageBubble::Expand, base::Unretained(this), id));
      if (expanded_.contains(id)) {
        if (status && !aegis::EnhancementField(*status, "error").empty())
          AddLabel(panel_, base::UTF8ToUTF16(aegis::EnhancementField(*status, "error")));
        if (enabled)
          Toggle(panel_, Copy(u"在本站启用", u"Enable on this site", u"在本站啟用"), !paused,
                 base::BindRepeating(&AegisPageBubble::SiteScript, base::Unretained(this), id));
        Button(panel_, Copy(u"源码、权限与全局设置", u"Source, permissions and global settings", u"原始碼、權限與全域設定"),
               base::BindRepeating(&AegisPageBubble::OpenManager, base::Unretained(this), id));
        if (menus) for (const auto& item : *menus) {
          const auto& menu = item.GetDict();
          if (aegis::EnhancementField(menu, "script") == id)
            Button(panel_, base::UTF8ToUTF16(aegis::EnhancementField(menu, "label")),
                   base::BindRepeating(&AegisPageBubble::Menu, base::Unretained(this), aegis::EnhancementField(menu, "id")));
        }
      }
    }
    if (!visible) AddLabel(panel_, Copy(u"此页面没有适用脚本。", u"No scripts apply to this page.", u"此頁面沒有適用腳本。"));
    if (visible > 4)
      Button(panel_, Copy(u"查看全部脚本", u"Show all scripts", u"查看全部腳本"),
             base::BindRepeating(&AegisPageBubble::Expand, base::Unretained(this), "all"));
    Button(panel_, Copy(u"新建或用 AI 编写脚本", u"Create a script or write with AI", u"新增或用 AI 編寫腳本"),
           base::BindRepeating(&AegisPageBubble::OpenManager, base::Unretained(this), std::string("new")));
    const auto runtime_error = aegis::EnhancementField(snapshot_, "error");
    if (!runtime_error.empty()) AddLabel(panel_, base::UTF8ToUTF16(runtime_error));
    if (!notice_.empty()) {
      AddLabel(panel_, notice_);
      Button(panel_, Copy(u"重新加载", u"Reload", u"重新載入"), base::BindRepeating(&AegisPageBubble::Reload, base::Unretained(this)));
      AddLabel(panel_, Copy(u"重载会清除页面修改，未提交的输入可能丢失。", u"Reload clears page changes; unsent input may be lost.", u"重新載入會清除頁面修改，未送出的輸入可能遺失。"));
    }
    if (address_.SchemeIsHTTPOrHTTPS())
      Button(panel_, Copy(u"将本页原文作为 Markdown 阅读", u"Read this page as Markdown", u"將本頁原文作為 Markdown 閱讀"),
             base::BindRepeating(&AegisPageBubble::OpenReading, base::Unretained(this)));
    Button(panel_, Copy(u"此网站的全部设置", u"All settings for this site", u"此網站的全部設定"),
           base::BindRepeating(&AegisPageBubble::OpenManager, base::Unretained(this), std::string()));
    Button(panel_, Copy(u"防护详情与本次浏览记录", u"Protection details and browsing events", u"防護詳情與本次瀏覽記錄"),
           base::BindRepeating(&AegisPageBubble::OpenDetails, base::Unretained(this)));
    InvalidateLayout();
    SizeToContents();
  }
  raw_ptr<BrowserWindowInterface> browser_;
  aegis::PagePrivacySummary summary_;
  base::WeakPtr<content::WebContents> source_;
  GURL address_;
  std::string document_, tab_;
  raw_ptr<views::View> panel_ = nullptr;
  base::DictValue snapshot_;
  int revision_ = -1;
  std::set<std::string> expanded_;
  std::u16string notice_;
  base::RepeatingTimer timer_;
  base::WeakPtrFactory<AegisPageBubble> weak_{this};
};

BEGIN_METADATA(AegisPageBubble)
END_METADATA

}  // namespace

AegisToolbarButton::AegisToolbarButton(
    BrowserWindowInterface* browser)
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
  Update(browser_->GetTabStripModel()->GetActiveWebContents());
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
  Update(browser_->GetTabStripModel()->GetActiveWebContents());
}

void AegisToolbarButton::OnPressed() {
  if (!aegis::IsAegisProfileSupported(browser_->GetProfile())) {
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
      aegis::IsAegisProfileSupported(browser_->GetProfile());
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
      : summary.total > 0 ? Copy(u"Aegis：本页已处理 ", u"Aegis: handled ",
                                 u"Aegis：本頁已處理 ") +
                                base::NumberToString16(summary.total) +
                                Copy(u" 项", u" items on this page", u" 項")
      : !summary.site_history.empty()
          ? Copy(u"Aegis：本站有保护历史，未计入本页",
                 u"Aegis: site history is separate from this page",
                 u"Aegis：本站有防護歷史，未計入本頁")
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
