// Copyright 2026 GCSA

#include "chrome/browser/ui/webui/aegis_agent/aegis_agent_ui.h"

#include <string>

#include "base/feature_list.h"
#include "base/strings/string_util.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/webui/aegis_agent/aegis_agent_page_handler.h"
#include "chrome/browser/ui/webui/theme_source.h"
#include "chrome/browser/ui/webui/webui_embedding_context.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/webui_url_constants.h"
#include "chrome/grit/aegis_agent_resources.h"
#include "chrome/grit/aegis_agent_resources_map.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/url_data_source.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_data_source.h"
#include "ui/base/webui/web_ui_util.h"
#include "ui/webui/webui_util.h"

namespace {

enum class UiLanguage {
  kEnglish,
  kSimplifiedChinese,
  kTraditionalChinese,
};

UiLanguage CurrentLanguage() {
  const std::string locale =
      g_browser_process ? g_browser_process->GetApplicationLocale() : "en";
  if (base::StartsWith(locale, "zh-TW") || base::StartsWith(locale, "zh-HK") ||
      base::StartsWith(locale, "zh-Hant")) {
    return UiLanguage::kTraditionalChinese;
  }
  return base::StartsWith(locale, "zh") ? UiLanguage::kSimplifiedChinese
                                        : UiLanguage::kEnglish;
}

const char* Localized(UiLanguage language,
                      const char* english,
                      const char* simplified,
                      const char* traditional) {
  switch (language) {
    case UiLanguage::kEnglish:
      return english;
    case UiLanguage::kSimplifiedChinese:
      return simplified;
    case UiLanguage::kTraditionalChinese:
      return traditional;
  }
}

void AddStrings(content::WebUIDataSource* source) {
  const UiLanguage language = CurrentLanguage();
  auto add = [&](const char* key, const char* en, const char* zh_cn,
                 const char* zh_tw) {
    source->AddString(key, Localized(language, en, zh_cn, zh_tw));
  };
  add("title", "Aegis Agent", "Aegis 浏览器智能体", "Aegis 瀏覽器智慧代理");
  add("subtitle", "Plan first. Browser verifies every action.",
      "先生成计划，再由浏览器验证每一步。",
      "先產生計畫，再由瀏覽器驗證每一步。");
  add("ask", "Ask", "询问", "詢問");
  add("act", "Act", "执行", "執行");
  add("automate", "Automate", "自动化", "自動化");
  add("target", "Task target", "任务目标", "任務目標");
  add("goal", "What should Aegis do?", "希望 Aegis 做什么？",
      "希望 Aegis 做什麼？");
  add("goalPlaceholder", "Describe the result, boundaries, and constraints…",
      "描述目标、范围和限制……", "描述目標、範圍和限制……");
  add("origins", "Allowed origins (optional)", "允许访问的来源（可选）",
      "允許存取的來源（選填）");
  add("originsPlaceholder",
      "Leave empty to search and open related pages automatically",
      "留空时自动搜索并打开相关网页", "留空時自動搜尋並開啟相關網頁");
  add("workflow", "Workflow", "工作流", "工作流程");
  add("research", "Research", "深度研究", "深度研究");
  add("steward", "Browser steward", "浏览器管家", "瀏覽器管家");
  add("download", "Safe download", "安全下载", "安全下載");
  add("shopping", "Shopping", "购物助手", "購物助手");
  add("plan", "Find pages and generate plan", "自动找网页并生成计划",
      "自動找網頁並產生計畫");
  add("start", "Approve and start", "同意并开始", "同意並開始");
  add("scope", "Plan and scope", "计划与授权范围", "計畫與授權範圍");
  add("timeline", "Timeline", "执行时间线", "執行時間軸");
  add("monitors", "Monitors", "监控", "監控");
  add("pauseMonitor", "Pause monitor", "暂停监控", "暫停監控");
  add("resumeMonitor", "Resume monitor", "恢复监控", "恢復監控");
  add("deleteMonitor", "Delete monitor", "删除监控", "刪除監控");
  add("pause", "Pause", "暂停", "暫停");
  add("resume", "Resume", "继续", "繼續");
  add("takeover", "Take over", "接管", "接管");
  add("finishTakeover", "I finished", "我已完成", "我已完成");
  add("stop", "Stop", "停止", "停止");
  add("approve", "Approve exact action", "批准这一个操作", "批准這一個操作");
  add("undo", "Undo", "撤销", "復原");
  add("disabled", "Enable Browser Agent in chrome://aegis first.",
      "请先在 chrome://aegis 启用浏览器智能体。",
      "請先在 chrome://aegis 啟用瀏覽器智慧代理。");
  add("noTarget", "Aegis will open the right pages for this task.",
      "无需先打开网页，Aegis 会自动查找。",
      "無需先開啟網頁，Aegis 會自動查找。");
  add("noTask", "No active task", "暂无任务", "暫無任務");
  add("provider", "Model", "模型", "模型");
  add("budget", "Budget", "预算", "預算");
  add("data", "Data", "数据", "資料");
  add("tools", "Tools", "工具", "工具");
  add("risk", "Highest risk", "最高风险", "最高風險");
  add("steps", "Steps", "步骤", "步驟");
  add("waitingApproval", "Waiting for your approval", "等待你的批准",
      "等待你的批准");
  add("exactArguments", "Exact action parameters", "本次操作的精确参数",
      "本次操作的精確參數");
  add("actionFingerprint", "Action fingerprint", "操作指纹", "操作指紋");
  add("takeoverReady", "Final step is yours", "最终步骤由你完成",
      "最終步驟由你完成");
  add("takeoverNotice",
      "Aegis re-read this checkout and stopped before the final purchase. "
      "Review the live page, then complete or cancel it yourself.",
      "Aegis "
      "已重新读取结账信息，并在最终购买前停止。请核对当前页面后自行完成或取消"
      "。",
      "Aegis "
      "已重新讀取結帳資訊，並在最終購買前停止。請核對目前頁面後自行完成或取消"
      "。");
  add("merchant", "Merchant", "商家", "商家");
  add("product", "Product", "商品", "商品");
  add("quantity", "Quantity", "数量", "數量");
  add("unitPrice", "Unit price", "单价", "單價");
  add("shipping", "Shipping", "运费", "運費");
  add("tax", "Tax", "税费", "稅費");
  add("discount", "Discount", "优惠", "優惠");
  add("total", "Current total", "当前总额", "目前總額");
  add("delivery", "Delivery", "配送", "配送");
  add("returns", "Returns", "退货", "退貨");
  add("sources", "Browser sources", "浏览器来源", "瀏覽器來源");
}

}  // namespace

AegisAgentUIConfig::AegisAgentUIConfig()
    : DefaultTopChromeWebUIConfig(content::kChromeUIUntrustedScheme,
                                  chrome::kChromeUIUntrustedAegisAgentHost) {}

AegisAgentUIConfig::~AegisAgentUIConfig() = default;

bool AegisAgentUIConfig::IsWebUIEnabled(
    content::BrowserContext* browser_context) {
  Profile* profile =
      browser_context ? Profile::FromBrowserContext(browser_context) : nullptr;
  return base::FeatureList::IsEnabled(aegis::features::kAegisAgent) &&
         profile && profile->IsRegularProfile();
}

AegisAgentUI::AegisAgentUI(content::WebUI* web_ui)
    : UntrustedTopChromeWebUIController(web_ui) {
  content::WebUIDataSource* source = content::WebUIDataSource::CreateAndAdd(
      web_ui->GetWebContents()->GetBrowserContext(),
      chrome::kChromeUIUntrustedAegisAgentURL);
  webui::SetupWebUIDataSource(source, kAegisAgentResources,
                              IDR_AEGIS_AGENT_AGENT_HTML);
  AddStrings(source);
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::ScriptSrc,
      "script-src 'self' chrome-untrusted://resources;");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::StyleSrc,
      "style-src 'self' chrome-untrusted://resources;");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::ImgSrc, "img-src 'self' data:;");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::ConnectSrc, "connect-src 'none';");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::ObjectSrc, "object-src 'none';");
  source->OverrideContentSecurityPolicy(
      network::mojom::CSPDirectiveName::TrustedTypes,
      "trusted-types static-types;");

  Profile* profile = Profile::FromWebUI(web_ui);
  content::URLDataSource::Add(profile, std::make_unique<ThemeSource>(
                                           profile, /*serve_untrusted=*/true));
}

AegisAgentUI::~AegisAgentUI() = default;

WEB_UI_CONTROLLER_TYPE_IMPL(AegisAgentUI)

void AegisAgentUI::BindInterface(
    mojo::PendingReceiver<aegis_agent::mojom::PageHandlerFactory> receiver) {
  page_factory_receiver_.reset();
  page_factory_receiver_.Bind(std::move(receiver));
}

void AegisAgentUI::CreatePageHandler(
    mojo::PendingRemote<aegis_agent::mojom::Page> page,
    mojo::PendingReceiver<aegis_agent::mojom::PageHandler> receiver) {
  page_handler_ = std::make_unique<AegisAgentPageHandler>(
      Profile::FromWebUI(web_ui()),
      webui::GetBrowserWindowInterface(web_ui()->GetWebContents()), this,
      std::move(page), std::move(receiver));
}
