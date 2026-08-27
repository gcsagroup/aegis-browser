// Copyright 2026 GCSA
// Intended path: chrome/browser/ui/webui/aegis/aegis_ui.cc

#include "chrome/browser/ui/webui/aegis/aegis_ui.h"

#include <string>

#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/webui/aegis/aegis_ui_handler.h"
#include "chrome/common/webui_url_constants.h"
#include "chrome/grit/aegis_resources.h"
#include "chrome/grit/aegis_resources_map.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_data_source.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/webui/webui_util.h"

namespace {

struct AegisStrings {
  const char* title;
  const char* subtitle;
  const char* tracker_label;
  const char* tracker_hint;
  const char* phish_label;
  const char* phish_hint;
  const char* fingerprint_label;
  const char* fingerprint_hint;
  const char* fingerprint_probe;
  const char* filter_list_title;
  const char* filter_list_auto_update;
  const char* filter_list_auto_update_hint;
  const char* filter_list_update_now;
  const char* filter_list_meta;
  const char* link_sanitize_label;
  const char* link_sanitize_hint;
  const char* cookie_janitor_label;
  const char* cookie_janitor_hint;
  const char* cname_uncloak_label;
  const char* cname_uncloak_hint;
  const char* bounce_tracking_label;
  const char* bounce_tracking_hint;
  const char* policy_worker_label;
  const char* policy_worker_hint;
  const char* privacy_ai_label;
  const char* privacy_ai_hint;
  const char* privacy_ai_title;
  const char* privacy_ai_meta;
  const char* privacy_ai_summarize;
  const char* ollama_url_label;
  const char* ollama_model_label;
  const char* ollama_probe;
  const char* ollama_save;
  const char* ollama_hint;
  const char* casper_note;
  const char* activity_title;
  const char* activity_hint;
  const char* activity_empty;
  const char* ai_control_title;
  const char* ai_control_label;
  const char* ai_control_hint;
  const char* ai_control_status;
  const char* ai_control_connect;
  const char* ai_control_limit;
  const char* note;
};

AegisStrings StringsForLocale(const std::string& locale) {
  if (locale.starts_with("zh-TW") || locale.starts_with("zh-HK")) {
    return {
        .title = "GCSA-aegis",
        .subtitle = "隱私與安全模組",
        .tracker_label = "追蹤器攔截",
        .tracker_hint =
            "攔截廣告／分析域名的子資源，以及第一方 /g/collect、gtm.js 等收集路徑。",
        .phish_label = "釣魚攔截頁",
        .phish_hint =
            "打開高風險仿冒站前顯示攔截頁，可選擇繼續造訪。",
        .fingerprint_label = "指紋防護",
        .fingerprint_hint =
            "對 Canvas、WebGL、Audio、WebGPU 做穩定化，降低跨站指紋追蹤。"
            "檢測兩次，同一頁的 Audio 讀數應相同；WebGPU 的 maxBufferSize 會隨開關變化。",
        .fingerprint_probe = "檢測本頁指紋",
        .filter_list_title = "EasyList 規則",
        .filter_list_auto_update = "自動更新過濾列表",
        .filter_list_auto_update_hint =
            "啟動用本地快取。約每 24 小時後台檢查；未變化不重編譯，失敗保留舊快取。",
        .filter_list_update_now = "立即更新",
        .filter_list_meta =
            "尚未下載過濾列表。更新後會編譯 EasyList / EasyPrivacy。",
        .link_sanitize_label = "清洗追蹤參數",
        .link_sanitize_hint =
            "導覽與跳轉時去掉 utm_、fbclid、gclid，並清洗 Referer 裡的追蹤參數。",
        .cookie_janitor_label = "清理廣告/分析 Cookie",
        .cookie_janitor_hint =
            "按 Cookie 名稱查表分類。刪除的第一方追蹤 Cookie 會標「first-party / name-hit」。"
            "Facebook 登入 Cookie（c_user / datr）會保留；facebook.com 不當廣告網路域。",
        .cname_uncloak_label = "揭開 CNAME 偽裝追蹤",
        .cname_uncloak_hint =
            "解析子資源 CNAME，命中追蹤域名則攔截。",
        .bounce_tracking_label = "攔截跳轉追蹤並立即清 Cookie",
        .bounce_tracking_hint =
            "識別 bounce tracking 跳轉，並立即清掉對應 Cookie。",
        .policy_worker_label = "JS 策略 worker（packages/core）",
        .policy_worker_hint =
            "在 chrome://aegis 執行 packages/core：釣魚評分、PII 脫敏與摘要。",
        .privacy_ai_label = "本地隱私摘要",
        .privacy_ai_hint =
            "用本機啟發式或 Ollama 總結當前網頁。文本先脫敏，不上傳雲端。",
        .privacy_ai_title = "隱私 AI",
        .privacy_ai_meta =
            "對目前網頁做本地摘要。有 Ollama 時走 loopback，否則用啟發式。",
        .privacy_ai_summarize = "摘要目前分頁",
        .ollama_url_label = "Ollama 地址（僅本機）",
        .ollama_model_label = "模型",
        .ollama_probe = "檢測本機模型",
        .ollama_save = "保存模型設定",
        .ollama_hint =
            "只允許 127.0.0.1 / localhost。未啟動 Ollama 時自動回退啟發式摘要。",
        .casper_note =
            "發給 Ollama 的是脫敏後文本，且僅發往 127.0.0.1。",
        .activity_title = "本次會話",
        .activity_hint =
            "攔截（EasyList / 第一方 collect / CNAME）、Referer 去參、廣告 Cookie、bounce 與本機 CDP 連線會自動更新。",
        .activity_empty =
            "還沒有記錄。打開帶廣告請求或 utm_ 的頁面後，攔截與清理會出現在這裡。",
        .ai_control_title = "AI 控制",
        .ai_control_label = "允許本機 AI agent 經 CDP 控制",
        .ai_control_hint =
            "預設關閉。開啟後只在 127.0.0.1 / localhost 提供 DevTools，不綁 0.0.0.0。"
            "遠端 CDP 不列出 chrome://、file:// 等內部頁。",
        .ai_control_status = "調試埠與綁定",
        .ai_control_connect =
            "Playwright：chromium.connectOverCDP('http://127.0.0.1:PORT')",
        .ai_control_limit =
            "限制：遠端 CDP 不列出 chrome:// 與 file://，但網頁 DOM 仍可讀。"
            "這是你主動打開的能力；chrome://aegis 摘要會先脫敏，CDP 讀 DOM 不會自動脫敏。",
        .note = "模組狀態會立即套用；過濾列表約每天自動更新一次。",
    };
  }
  if (locale.starts_with("zh")) {
    return {
        .title = "GCSA-aegis",
        .subtitle = "隐私与安全模块",
        .tracker_label = "跟踪器拦截",
        .tracker_hint =
            "拦截广告／分析域名的子资源，以及第一方 /g/collect、gtm.js 等收集路径。",
        .phish_label = "钓鱼拦截页",
        .phish_hint =
            "打开高风险仿冒站前显示拦截页，可选择继续访问。",
        .fingerprint_label = "指纹防护",
        .fingerprint_hint =
            "对 Canvas、WebGL、Audio、WebGPU 做稳定化，降低跨站指纹追踪。"
            "检测两次，同一页的 Audio 读数应相同；WebGPU 的 maxBufferSize 会随开关变化。",
        .fingerprint_probe = "检测本页指纹",
        .filter_list_title = "EasyList 规则",
        .filter_list_auto_update = "自动更新过滤列表",
        .filter_list_auto_update_hint =
            "启动用本地缓存。约每 24 小时后台检查；未变化不重编译，失败保留旧缓存。",
        .filter_list_update_now = "立即更新",
        .filter_list_meta =
            "尚未下载过滤列表。更新后会编译 EasyList / EasyPrivacy。",
        .link_sanitize_label = "清洗跟踪参数",
        .link_sanitize_hint =
            "导航与跳转时去掉 utm_、fbclid、gclid，并清洗 Referer 里的跟踪参数。",
        .cookie_janitor_label = "清理广告/分析 Cookie",
        .cookie_janitor_hint =
            "按 Cookie 名称查表分类。删除的第一方跟踪 Cookie 会标「first-party / name-hit」。"
            "Facebook 登录 Cookie（c_user / datr）会保留；facebook.com 不当广告网络域。",
        .cname_uncloak_label = "揭开 CNAME 伪装跟踪",
        .cname_uncloak_hint =
            "解析子资源 CNAME，命中跟踪域名则拦截。",
        .bounce_tracking_label = "拦截跳转跟踪并立即清 Cookie",
        .bounce_tracking_hint =
            "识别 bounce tracking 跳转，并立即清掉对应 Cookie。",
        .policy_worker_label = "JS 策略 worker（packages/core）",
        .policy_worker_hint =
            "在 chrome://aegis 运行 packages/core：钓鱼评分、PII 脱敏与摘要。",
        .privacy_ai_label = "本地隐私摘要",
        .privacy_ai_hint =
            "用本机启发式或 Ollama 总结当前网页。文本先脱敏，不上传云端。",
        .privacy_ai_title = "隐私 AI",
        .privacy_ai_meta =
            "对当前网页做本地摘要。有 Ollama 时走 loopback，否则用启发式。",
        .privacy_ai_summarize = "摘要当前标签页",
        .ollama_url_label = "Ollama 地址（仅本机）",
        .ollama_model_label = "模型",
        .ollama_probe = "检测本机模型",
        .ollama_save = "保存模型设置",
        .ollama_hint =
            "只允许 127.0.0.1 / localhost。未启动 Ollama 时自动回退启发式摘要。",
        .casper_note =
            "发给 Ollama 的是脱敏后文本，且仅发往 127.0.0.1。",
        .activity_title = "本次会话",
        .activity_hint =
            "拦截（EasyList / 第一方 collect / CNAME）、Referer 去参、广告 Cookie、bounce 与本机 CDP 连接会自动更新。",
        .activity_empty =
            "还没有记录。打开带广告请求或 utm_ 的页面后，拦截与清理会出现在这里。",
        .ai_control_title = "AI 控制",
        .ai_control_label = "允许本机 AI agent 经 CDP 控制",
        .ai_control_hint =
            "默认关闭。开启后只在 127.0.0.1 / localhost 提供 DevTools，不绑 0.0.0.0。"
            "远程 CDP 不列出 chrome://、file:// 等内部页。",
        .ai_control_status = "调试端口与绑定",
        .ai_control_connect =
            "Playwright：chromium.connectOverCDP('http://127.0.0.1:PORT')",
        .ai_control_limit =
            "限制：远程 CDP 不列出 chrome:// 与 file://，但网页 DOM 仍可读。"
            "这是你主动打开的能力；chrome://aegis 摘要会先脱敏，CDP 读 DOM 不会自动脱敏。",
        .note = "模块状态会立即生效；过滤列表大约每天自动更新一次。",
    };
  }
  return {
      .title = "GCSA-aegis",
      .subtitle = "Privacy & security modules",
      .tracker_label = "Tracker blocking",
      .tracker_hint =
          "Blocks ad/analytics subresources and first-party collect paths "
          "such as /g/collect and gtm.js. Does not block pages you open.",
      .phish_label = "Phish interstitial",
      .phish_hint =
          "Shows a warning before high-risk lookalike sites. You can continue.",
      .fingerprint_label = "Fingerprint Guard",
      .fingerprint_hint =
          "Stabilizes Canvas, WebGL, Audio, and WebGPU to reduce cross-site "
          "fingerprinting. Probe twice; Audio on this page should stay the "
          "same. WebGPU maxBufferSize changes with the guard.",
      .fingerprint_probe = "Probe this page fingerprints",
      .filter_list_title = "EasyList rules",
      .filter_list_auto_update = "Auto-update filter lists",
      .filter_list_auto_update_hint =
          "Uses the local cache on startup. Rechecks about every 24h in the "
          "background; unchanged lists skip recompile, failures keep the cache.",
      .filter_list_update_now = "Update now",
      .filter_list_meta =
          "No compiled filter list yet. Update to compile EasyList / EasyPrivacy.",
      .link_sanitize_label = "Strip tracking parameters",
      .link_sanitize_hint =
          "Removes utm_, fbclid, gclid and similar tracking params from "
          "navigations, redirects, and the Referer header.",
      .cookie_janitor_label = "Clear ads/analytics cookies",
      .cookie_janitor_hint =
          "Looks up cookie names. Deleted first-party tracking cookies are "
          "labeled first-party / name-hit. Facebook login cookies (c_user / "
          "datr) are kept; facebook.com is not treated as an ad network.",
      .cname_uncloak_label = "Uncloak CNAME tracker aliases",
      .cname_uncloak_hint =
          "Resolves subresource CNAMEs and blocks aliases of tracker hosts.",
      .bounce_tracking_label = "Clear bounce-tracker cookies immediately",
      .bounce_tracking_hint =
          "Detects bounce-tracking hops and clears matching cookies at once.",
      .policy_worker_label = "JS policy worker (packages/core)",
      .policy_worker_hint =
          "Runs packages/core on chrome://aegis for phish scoring, PII "
          "redaction, and summaries.",
      .privacy_ai_label = "Local privacy summary",
      .privacy_ai_hint =
          "Summarizes the current page locally with heuristics or Ollama. "
          "Text is redacted first and never sent to the cloud.",
      .privacy_ai_title = "Privacy AI",
      .privacy_ai_meta =
          "Summarize the current page locally. Uses loopback Ollama when "
          "available, otherwise heuristics.",
      .privacy_ai_summarize = "Summarize current tab",
      .ollama_url_label = "Ollama URL (loopback only)",
      .ollama_model_label = "Model",
      .ollama_probe = "Detect local models",
      .ollama_save = "Save model settings",
      .ollama_hint =
          "Only 127.0.0.1 / localhost. Falls back to heuristics if Ollama is "
          "not running.",
      .casper_note =
          "Text sent to Ollama is redacted first, and only to 127.0.0.1.",
      .activity_title = "This session",
      .activity_hint =
          "Blocks (EasyList / first-party collect / CNAME), Referer stripping, "
          "ads cookies, bounce clears, and local CDP connections update live.",
      .activity_empty =
          "Nothing recorded yet. Open a page with ad requests or a utm_ link.",
      .ai_control_title = "AI control",
      .ai_control_label = "Allow a local AI agent over CDP",
      .ai_control_hint =
          "Off by default. When on, DevTools binds only 127.0.0.1 / localhost, "
          "never 0.0.0.0. Remote CDP does not list chrome:// or file:// pages.",
      .ai_control_status = "Debug port and bind",
      .ai_control_connect =
          "Playwright: chromium.connectOverCDP('http://127.0.0.1:PORT')",
      .ai_control_limit =
          "Limit: remote CDP hides chrome:// and file://, but page DOM is still "
          "readable. That is an explicit user choice. chrome://aegis summaries "
          "are redacted; CDP DOM reads are not.",
      .note =
          "Changes apply immediately. Filter lists refresh about once a day.",
  };
}

}  // namespace

AegisUI::AegisUI(content::WebUI* web_ui) : content::WebUIController(web_ui) {
  Profile* profile = Profile::FromWebUI(web_ui);
  content::WebUIDataSource* source = content::WebUIDataSource::CreateAndAdd(
      profile, chrome::kChromeUIAegisHost);

  const AegisStrings strings =
      StringsForLocale(l10n_util::GetApplicationLocale(std::string()));
  source->AddString("title", strings.title);
  source->AddString("subtitle", strings.subtitle);
  source->AddString("trackerLabel", strings.tracker_label);
  source->AddString("trackerHint", strings.tracker_hint);
  source->AddString("phishLabel", strings.phish_label);
  source->AddString("phishHint", strings.phish_hint);
  source->AddString("fingerprintLabel", strings.fingerprint_label);
  source->AddString("fingerprintHint", strings.fingerprint_hint);
  source->AddString("fingerprintProbe", strings.fingerprint_probe);
  source->AddString("filterListTitle", strings.filter_list_title);
  source->AddString("filterListAutoUpdate", strings.filter_list_auto_update);
  source->AddString("filterListAutoUpdateHint",
                    strings.filter_list_auto_update_hint);
  source->AddString("filterListUpdateNow", strings.filter_list_update_now);
  source->AddString("filterListMeta", strings.filter_list_meta);
  source->AddString("linkSanitizeLabel", strings.link_sanitize_label);
  source->AddString("linkSanitizeHint", strings.link_sanitize_hint);
  source->AddString("cookieJanitorLabel", strings.cookie_janitor_label);
  source->AddString("cookieJanitorHint", strings.cookie_janitor_hint);
  source->AddString("cnameUncloakLabel", strings.cname_uncloak_label);
  source->AddString("cnameUncloakHint", strings.cname_uncloak_hint);
  source->AddString("bounceTrackingLabel", strings.bounce_tracking_label);
  source->AddString("bounceTrackingHint", strings.bounce_tracking_hint);
  source->AddString("policyWorkerLabel", strings.policy_worker_label);
  source->AddString("policyWorkerHint", strings.policy_worker_hint);
  source->AddString("privacyAiLabel", strings.privacy_ai_label);
  source->AddString("privacyAiHint", strings.privacy_ai_hint);
  source->AddString("privacyAiTitle", strings.privacy_ai_title);
  source->AddString("privacyAiMeta", strings.privacy_ai_meta);
  source->AddString("privacyAiSummarize", strings.privacy_ai_summarize);
  source->AddString("ollamaUrlLabel", strings.ollama_url_label);
  source->AddString("ollamaModelLabel", strings.ollama_model_label);
  source->AddString("ollamaProbe", strings.ollama_probe);
  source->AddString("ollamaSave", strings.ollama_save);
  source->AddString("ollamaHint", strings.ollama_hint);
  source->AddString("casperNote", strings.casper_note);
  source->AddString("activityTitle", strings.activity_title);
  source->AddString("activityHint", strings.activity_hint);
  source->AddString("activityEmpty", strings.activity_empty);
  source->AddString("aiControlTitle", strings.ai_control_title);
  source->AddString("aiControlLabel", strings.ai_control_label);
  source->AddString("aiControlHint", strings.ai_control_hint);
  source->AddString("aiControlStatus", strings.ai_control_status);
  source->AddString("aiControlConnect", strings.ai_control_connect);
  source->AddString("aiControlLimit", strings.ai_control_limit);
  source->AddString("note", strings.note);

  webui::SetupWebUIDataSource(source, kAegisResources, IDR_AEGIS_AEGIS_HTML);
  web_ui->AddMessageHandler(std::make_unique<AegisUIHandler>());
}

AegisUI::~AegisUI() = default;

WEB_UI_CONTROLLER_TYPE_IMPL(AegisUI)
