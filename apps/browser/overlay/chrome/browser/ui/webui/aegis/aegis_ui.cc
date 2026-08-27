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
  const char* overview_title;
  const char* overview_blocked;
  const char* overview_links;
  const char* overview_storage;
  const char* overview_scope;
  const char* modules_title;
  const char* tracker_label;
  const char* tracker_hint;
  const char* phish_label;
  const char* phish_hint;
  const char* fingerprint_label;
  const char* fingerprint_hint;
  const char* fingerprint_probe;
  const char* miner_guard_label;
  const char* miner_guard_hint;
  const char* filter_list_title;
  const char* filter_list_auto_update;
  const char* filter_list_auto_update_hint;
  const char* filter_list_update_now;
  const char* filter_list_meta;
  const char* downloads_title;
  const char* downloads_meta;
  const char* metalink_file_label;
  const char* metalink_inspect;
  const char* metalink_download;
  const char* metalink_safety;
  const char* torrent_title;
  const char* torrent_meta;
  const char* torrent_file_label;
  const char* magnet_label;
  const char* torrent_inspect;
  const char* torrent_start;
  const char* torrent_dht;
  const char* torrent_pex;
  const char* torrent_download_limit;
  const char* torrent_upload_limit;
  const char* torrent_disclosure;
  const char* torrent_pause;
  const char* torrent_resume;
  const char* torrent_cancel;
  const char* torrent_safety;
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
  const char* summary_preview_title;
  const char* summary_preview_read;
  const char* summary_preview_redacted;
  const char* summary_preview_destination;
  const char* summary_preview_scope;
  const char* summary_preview_cancel;
  const char* summary_preview_confirm;
  const char* model_provider_label;
  const char* model_openai_compatible;
  const char* model_anthropic_compatible;
  const char* model_gemini_compatible;
  const char* model_endpoint_label;
  const char* model_api_key_label;
  const char* model_api_key_hint;
  const char* model_select_label;
  const char* model_custom_label;
  const char* model_load;
  const char* model_save;
  const char* model_key_clear;
  const char* model_hint;
  const char* model_data_note;
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
        .overview_title = "保護概覽",
        .overview_blocked = "已攔截請求",
        .overview_links = "已清理連結",
        .overview_storage = "Cookie／跳轉清理",
        .overview_scope =
            "這裡只顯示 Aegis 的本次會話動作與模組狀態，不代表網站本身可信。",
        .modules_title = "保護模組",
        .tracker_label = "追蹤器攔截",
        .tracker_hint =
            "攔截廣告／分析域名的子資源，以及第一方 /g/collect、gtm.js "
            "等收集路徑。",
        .phish_label = "釣魚攔截頁",
        .phish_hint = "打開高風險仿冒站前顯示攔截頁，可選擇繼續造訪。",
        .fingerprint_label = "指紋防護",
        .fingerprint_hint =
            "對 Canvas、WebGL、Audio、WebGPU 做穩定化，降低跨站指紋追蹤。"
            "檢測兩次，同一頁的 Audio 讀數應相同；WebGPU 的 maxBufferSize "
            "會隨開關變化。",
        .fingerprint_probe = "檢測本頁指紋",
        .miner_guard_label = "挖礦腳本偵測（僅觀察）",
        .miner_guard_hint =
            "由瀏覽器側組合估算頁面 CPU、Worker／Wasm／WebGPU 與挖礦端點訊號。"
            "符合目前規則時只記錄提醒，不會中止腳本或連線；重新啟用後請重新整理"
            "頁面。",
        .filter_list_title = "EasyList 規則",
        .filter_list_auto_update = "自動更新過濾列表",
        .filter_list_auto_update_hint =
            "啟動用本地快取。約每 24 "
            "小時後台檢查；未變化不重編譯，失敗保留舊快取。",
        .filter_list_update_now = "立即更新",
        .filter_list_meta =
            "尚未下載過濾列表。更新後會編譯 EasyList / EasyPrivacy。",
        .downloads_title = "下載與鏡像",
        .downloads_meta =
            "一般 HTTP(S) 下載會自動使用有界智能並行；也可匯入單文件 "
            "RFC 5854 Metalink。",
        .metalink_file_label = "Metalink 文件（.meta4 / .metalink）",
        .metalink_inspect = "檢查文件",
        .metalink_download = "確認並下載",
        .metalink_safety =
            "只接受公開 HTTP(S) 鏡像與 SHA-256/SHA-512。開始前僅顯示鏡像來源，"
            "不顯示路徑、查詢參數或憑證；散列不符會刪除文件並嘗試下一鏡像。",
        .torrent_title = "BT / Magnet",
        .torrent_meta =
            "先在本機檢查 .torrent 或 Magnet，再由 Network 沙箱服務下載。",
        .torrent_file_label = "Torrent 文件（.torrent）",
        .magnet_label = "Magnet 連結",
        .torrent_inspect = "檢查 BT 內容",
        .torrent_start = "確認並開始 BT 下載",
        .torrent_dht = "啟用 DHT 找節點",
        .torrent_pex = "啟用 PEX 節點交換",
        .torrent_download_limit = "下載上限（KiB/s，0 為不限）",
        .torrent_upload_limit = "上傳上限（KiB/s，0 為不限）",
        .torrent_disclosure =
            "我知道 BT 會向節點、Tracker 或 DHT 公開我的 IP；我只下載有權取得的"
            "內容。Aegis 完成後會自動停止做種。",
        .torrent_pause = "暫停",
        .torrent_resume = "繼續",
        .torrent_cancel = "取消任務（保留文件）",
        .torrent_safety =
            "限制 4 MiB 元資料、2048 個文件和 2 TiB；拒絕路徑穿越與符號連結。"
            "預設關閉 UPnP、NAT-PMP 與 LSD，完成即停種。",
        .link_sanitize_label = "清洗追蹤參數",
        .link_sanitize_hint =
            "導覽與跳轉時去掉 utm_、fbclid、gclid，並清洗 Referer "
            "裡的追蹤參數。",
        .cookie_janitor_label = "清理廣告/分析 Cookie",
        .cookie_janitor_hint =
            "按 Cookie 名稱查表分類。刪除的第一方追蹤 Cookie 會標「first-party "
            "/ name-hit」。"
            "Facebook 登入 Cookie（c_user / datr）會保留；facebook.com "
            "不當廣告網路域。",
        .cname_uncloak_label = "揭開 CNAME 偽裝追蹤",
        .cname_uncloak_hint = "解析子資源 CNAME，命中追蹤域名則攔截。",
        .bounce_tracking_label = "攔截跳轉追蹤並立即清 Cookie",
        .bounce_tracking_hint =
            "識別 bounce tracking 跳轉，並立即清掉對應 Cookie。",
        .policy_worker_label = "JS 策略 worker（packages/core）",
        .policy_worker_hint =
            "在 chrome://aegis 執行 packages/core：釣魚評分、PII 脫敏與摘要。",
        .privacy_ai_label = "隱私 AI 摘要",
        .privacy_ai_hint =
            "先脫敏，再用所選相容 API 格式和服務地址摘要。服務地址不是"
            "數值 loopback 時，傳送前會再次確認。",
        .privacy_ai_title = "隱私 AI",
        .privacy_ai_meta =
            "支援 OpenAI 相容、Claude（Anthropic）相容或 Gemini 相容 API；"
            "模型不可用時使用本機啟發式摘要。",
        .privacy_ai_summarize = "摘要目前分頁",
        .summary_preview_title = "摘要前確認",
        .summary_preview_read = "將讀取的頁面文字",
        .summary_preview_redacted = "脫敏後文字",
        .summary_preview_destination = "處理位置",
        .summary_preview_scope =
            "不會顯示或送出完整網址查詢參數；服務地址不是數值 "
            "loopback 時，確認後才傳送脫敏文本。",
        .summary_preview_cancel = "取消",
        .summary_preview_confirm = "確認並摘要",
        .model_provider_label = "API 格式",
        .model_openai_compatible = "OpenAI 相容",
        .model_anthropic_compatible = "Claude（Anthropic）相容",
        .model_gemini_compatible = "Gemini 相容",
        .model_endpoint_label = "服務地址",
        .model_api_key_label = "API Key",
        .model_api_key_hint =
            "可選；如保存，會安全綁定目前 API 格式與服務地址且不回顯。",
        .model_select_label = "模型",
        .model_custom_label = "自訂模型 ID",
        .model_load = "載入模型列表",
        .model_save = "保存模型設定",
        .model_key_clear = "清除 API Key",
        .model_hint =
            "選擇相容 API 格式並填寫可編輯的服務地址；模型列表從目前"
            "地址載入。",
        .model_data_note =
            "API Key 按 API 格式與標準化服務地址隔離，以系統加密保存"
            "且不回顯。非本機地址會收到脫敏後的頁面摘錄。",
        .activity_title = "本次會話",
        .activity_hint =
            "攔截（EasyList / 第一方 collect / CNAME）、Referer 去參、廣告 "
            "Cookie、bounce 與本機 CDP 連線會自動更新。",
        .activity_empty =
            "還沒有記錄。打開帶廣告請求或 utm_ "
            "的頁面後，攔截與清理會出現在這裡。",
        .ai_control_title = "AI 控制",
        .ai_control_label = "允許本機 AI agent 經 CDP 控制",
        .ai_control_hint =
            "預設關閉。開啟後只在數值 loopback 提供 DevTools，不綁 0.0.0.0。"
            "遠端 CDP 不列出 chrome://、file:// 等內部頁。",
        .ai_control_status = "調試埠與綁定",
        .ai_control_connect =
            "Playwright：chromium.connectOverCDP('http://127.0.0.1:PORT')",
        .ai_control_limit =
            "限制：遠端 CDP 不列出 chrome:// 與 file://，但網頁 DOM 仍可讀。"
            "這是你主動打開的能力；chrome://aegis 摘要會先脫敏，CDP 讀 DOM "
            "不會自動脫敏。",
        .note = "模組狀態會立即套用；過濾列表約每天自動更新一次。",
    };
  }
  if (locale.starts_with("zh")) {
    return {
        .title = "GCSA-aegis",
        .subtitle = "隐私与安全模块",
        .overview_title = "保护概览",
        .overview_blocked = "已拦截请求",
        .overview_links = "已清理链接",
        .overview_storage = "Cookie／跳转清理",
        .overview_scope =
            "这里只显示 Aegis 的本次会话动作与模块状态，不代表网站本身可信。",
        .modules_title = "保护模块",
        .tracker_label = "跟踪器拦截",
        .tracker_hint =
            "拦截广告／分析域名的子资源，以及第一方 /g/collect、gtm.js "
            "等收集路径。",
        .phish_label = "钓鱼拦截页",
        .phish_hint = "打开高风险仿冒站前显示拦截页，可选择继续访问。",
        .fingerprint_label = "指纹防护",
        .fingerprint_hint =
            "对 Canvas、WebGL、Audio、WebGPU 做稳定化，降低跨站指纹追踪。"
            "检测两次，同一页的 Audio 读数应相同；WebGPU 的 maxBufferSize "
            "会随开关变化。",
        .fingerprint_probe = "检测本页指纹",
        .miner_guard_label = "挖矿脚本检测（仅观察）",
        .miner_guard_hint =
            "由浏览器侧组合估算页面 CPU、Worker／Wasm／WebGPU 与挖矿端点信号。"
            "符合当前规则时只记录提醒，不会终止脚本或连接；重新启用后请刷新页面"
            "。",
        .filter_list_title = "EasyList 规则",
        .filter_list_auto_update = "自动更新过滤列表",
        .filter_list_auto_update_hint =
            "启动用本地缓存。约每 24 "
            "小时后台检查；未变化不重编译，失败保留旧缓存。",
        .filter_list_update_now = "立即更新",
        .filter_list_meta =
            "尚未下载过滤列表。更新后会编译 EasyList / EasyPrivacy。",
        .downloads_title = "下载与镜像",
        .downloads_meta =
            "普通 HTTP(S) 下载会自动使用有界智能并行；也可导入单文件 "
            "RFC 5854 Metalink。",
        .metalink_file_label = "Metalink 文件（.meta4 / .metalink）",
        .metalink_inspect = "检查文件",
        .metalink_download = "确认并下载",
        .metalink_safety =
            "只接受公网 HTTP(S) 镜像与 SHA-256/SHA-512。开始前仅显示镜像来源，"
            "不显示路径、查询参数或凭据；散列不符会删除文件并尝试下一镜像。",
        .torrent_title = "BT / Magnet",
        .torrent_meta =
            "先在本机检查 .torrent 或 Magnet，再由 Network 沙箱服务下载。",
        .torrent_file_label = "Torrent 文件（.torrent）",
        .magnet_label = "Magnet 链接",
        .torrent_inspect = "检查 BT 内容",
        .torrent_start = "确认并开始 BT 下载",
        .torrent_dht = "启用 DHT 找节点",
        .torrent_pex = "启用 PEX 节点交换",
        .torrent_download_limit = "下载上限（KiB/s，0 为不限）",
        .torrent_upload_limit = "上传上限（KiB/s，0 为不限）",
        .torrent_disclosure =
            "我知道 BT 会向节点、Tracker 或 DHT 公开我的 IP；我只下载有权获取的"
            "内容。Aegis 完成后会自动停止做种。",
        .torrent_pause = "暂停",
        .torrent_resume = "继续",
        .torrent_cancel = "取消任务（保留文件）",
        .torrent_safety =
            "限制 4 MiB 元数据、2048 个文件和 2 TiB；拒绝路径穿越与符号链接。"
            "默认关闭 UPnP、NAT-PMP 与 LSD，完成即停种。",
        .link_sanitize_label = "清洗跟踪参数",
        .link_sanitize_hint =
            "导航与跳转时去掉 utm_、fbclid、gclid，并清洗 Referer "
            "里的跟踪参数。",
        .cookie_janitor_label = "清理广告/分析 Cookie",
        .cookie_janitor_hint =
            "按 Cookie 名称查表分类。删除的第一方跟踪 Cookie 会标「first-party "
            "/ name-hit」。"
            "Facebook 登录 Cookie（c_user / datr）会保留；facebook.com "
            "不当广告网络域。",
        .cname_uncloak_label = "揭开 CNAME 伪装跟踪",
        .cname_uncloak_hint = "解析子资源 CNAME，命中跟踪域名则拦截。",
        .bounce_tracking_label = "拦截跳转跟踪并立即清 Cookie",
        .bounce_tracking_hint =
            "识别 bounce tracking 跳转，并立即清掉对应 Cookie。",
        .policy_worker_label = "JS 策略 worker（packages/core）",
        .policy_worker_hint =
            "在 chrome://aegis 运行 packages/core：钓鱼评分、PII 脱敏与摘要。",
        .privacy_ai_label = "隐私 AI 摘要",
        .privacy_ai_hint =
            "先脱敏，再用所选兼容 API 格式和服务地址摘要。服务地址不是"
            "数值 loopback 时，发送前会再次确认。",
        .privacy_ai_title = "隐私 AI",
        .privacy_ai_meta =
            "支持 OpenAI 兼容、Claude（Anthropic）兼容或 Gemini 兼容 API；"
            "模型不可用时使用本机启发式摘要。",
        .privacy_ai_summarize = "摘要当前标签页",
        .summary_preview_title = "摘要前确认",
        .summary_preview_read = "将读取的页面文字",
        .summary_preview_redacted = "脱敏后文字",
        .summary_preview_destination = "处理位置",
        .summary_preview_scope =
            "不会显示或送出完整网址查询参数；服务地址不是数值 "
            "loopback 时，确认后才发送脱敏文本。",
        .summary_preview_cancel = "取消",
        .summary_preview_confirm = "确认并摘要",
        .model_provider_label = "API 格式",
        .model_openai_compatible = "OpenAI 兼容",
        .model_anthropic_compatible = "Claude（Anthropic）兼容",
        .model_gemini_compatible = "Gemini 兼容",
        .model_endpoint_label = "服务地址",
        .model_api_key_label = "API Key",
        .model_api_key_hint =
            "可选；如保存，会安全绑定当前 API 格式与服务地址且不回显。",
        .model_select_label = "模型",
        .model_custom_label = "自定义模型 ID",
        .model_load = "加载模型列表",
        .model_save = "保存模型设置",
        .model_key_clear = "清除 API Key",
        .model_hint =
            "选择兼容 API 格式并填写可编辑的服务地址；模型列表从当前"
            "地址加载。",
        .model_data_note =
            "API Key 按 API 格式与规范化服务地址隔离，使用系统加密保存"
            "且不回显。非本机地址会收到脱敏后的页面摘录。",
        .activity_title = "本次会话",
        .activity_hint =
            "拦截（EasyList / 第一方 collect / CNAME）、Referer 去参、广告 "
            "Cookie、bounce 与本机 CDP 连接会自动更新。",
        .activity_empty =
            "还没有记录。打开带广告请求或 utm_ "
            "的页面后，拦截与清理会出现在这里。",
        .ai_control_title = "AI 控制",
        .ai_control_label = "允许本机 AI agent 经 CDP 控制",
        .ai_control_hint =
            "默认关闭。开启后只在数值 loopback 提供 DevTools，不绑 0.0.0.0。"
            "远程 CDP 不列出 chrome://、file:// 等内部页。",
        .ai_control_status = "调试端口与绑定",
        .ai_control_connect =
            "Playwright：chromium.connectOverCDP('http://127.0.0.1:PORT')",
        .ai_control_limit =
            "限制：远程 CDP 不列出 chrome:// 与 file://，但网页 DOM 仍可读。"
            "这是你主动打开的能力；chrome://aegis 摘要会先脱敏，CDP 读 DOM "
            "不会自动脱敏。",
        .note = "模块状态会立即生效；过滤列表大约每天自动更新一次。",
    };
  }
  return {
      .title = "GCSA-aegis",
      .subtitle = "Privacy & security modules",
      .overview_title = "Protection overview",
      .overview_blocked = "Requests blocked",
      .overview_links = "Links cleaned",
      .overview_storage = "Cookie / bounce cleanup",
      .overview_scope =
          "This shows Aegis actions for this session and module health. It "
          "does not mean a site is trustworthy.",
      .modules_title = "Protection modules",
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
      .miner_guard_label = "Mining script detection (observe-only)",
      .miner_guard_hint =
          "Combines estimated page CPU, Worker/Wasm/WebGPU use, and strong "
          "mining endpoint indicators. Rule matches are reported without "
          "stopping scripts or connections; reload after re-enabling it.",
      .filter_list_title = "EasyList rules",
      .filter_list_auto_update = "Auto-update filter lists",
      .filter_list_auto_update_hint =
          "Uses the local cache on startup. Rechecks about every 24h in the "
          "background; unchanged lists skip recompile, failures keep the "
          "cache.",
      .filter_list_update_now = "Update now",
      .filter_list_meta =
          "No compiled filter list yet. Update to compile EasyList / "
          "EasyPrivacy.",
      .downloads_title = "Downloads and mirrors",
      .downloads_meta =
          "Regular HTTP(S) downloads use bounded smart parallelism. You can "
          "also import a single-file RFC 5854 Metalink.",
      .metalink_file_label = "Metalink file (.meta4 / .metalink)",
      .metalink_inspect = "Inspect file",
      .metalink_download = "Confirm and download",
      .metalink_safety =
          "Only public HTTP(S) mirrors and SHA-256/SHA-512 are accepted. The "
          "preview shows origins, never paths, queries, or credentials. Hash "
          "mismatches are deleted before trying the next mirror.",
      .torrent_title = "BitTorrent / Magnet",
      .torrent_meta =
          "Inspect a .torrent or Magnet locally, then download in a Network-"
          "sandboxed service.",
      .torrent_file_label = "Torrent file (.torrent)",
      .magnet_label = "Magnet link",
      .torrent_inspect = "Inspect BT content",
      .torrent_start = "Confirm and start BT download",
      .torrent_dht = "Use DHT peer discovery",
      .torrent_pex = "Use PEX peer exchange",
      .torrent_download_limit = "Download limit (KiB/s, 0 unlimited)",
      .torrent_upload_limit = "Upload limit (KiB/s, 0 unlimited)",
      .torrent_disclosure =
          "I understand that BT reveals my IP to peers, trackers, or DHT. I "
          "will download only content I am authorized to obtain. Aegis stops "
          "seeding when complete.",
      .torrent_pause = "Pause",
      .torrent_resume = "Resume",
      .torrent_cancel = "Cancel task (keep files)",
      .torrent_safety =
          "Metadata is limited to 4 MiB, 2,048 files, and 2 TiB. Path "
          "traversal and symlinks are rejected. UPnP, NAT-PMP, and LSD are "
          "off; completed tasks stop seeding.",
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
      .privacy_ai_label = "Privacy AI summary",
      .privacy_ai_hint =
          "Redacts first, then summarizes through the selected compatible API "
          "format and endpoint. Non-loopback sending requires confirmation.",
      .privacy_ai_title = "Privacy AI",
      .privacy_ai_meta =
          "Supports OpenAI-compatible, Anthropic (Claude)-compatible, or "
          "Gemini-compatible APIs, with on-device heuristic fallback.",
      .privacy_ai_summarize = "Summarize current tab",
      .summary_preview_title = "Confirm before summarizing",
      .summary_preview_read = "Page text to read",
      .summary_preview_redacted = "Text after redaction",
      .summary_preview_destination = "Processing destination",
      .summary_preview_scope =
          "Full URL query parameters are neither shown nor sent. For a "
          "non-loopback endpoint, redacted text is sent only after "
          "confirmation.",
      .summary_preview_cancel = "Cancel",
      .summary_preview_confirm = "Confirm and summarize",
      .model_provider_label = "API format",
      .model_openai_compatible = "OpenAI compatible",
      .model_anthropic_compatible = "Anthropic (Claude) compatible",
      .model_gemini_compatible = "Gemini compatible",
      .model_endpoint_label = "Service endpoint",
      .model_api_key_label = "API key",
      .model_api_key_hint =
          "Optional. If saved, it is securely bound to this API format and "
          "endpoint and is never shown again.",
      .model_select_label = "Model",
      .model_custom_label = "Custom model ID",
      .model_load = "Load model list",
      .model_save = "Save model settings",
      .model_key_clear = "Clear API key",
      .model_hint =
          "Choose a compatible API format and enter an editable endpoint. "
          "The model list is loaded from the current endpoint.",
      .model_data_note =
          "API keys are isolated by API format and normalized endpoint, "
          "OS-encrypted, and never shown again. Non-local endpoints receive "
          "the redacted page excerpt.",
      .activity_title = "This session",
      .activity_hint =
          "Blocks (EasyList / first-party collect / CNAME), Referer stripping, "
          "ads cookies, bounce clears, and local CDP connections update live.",
      .activity_empty =
          "Nothing recorded yet. Open a page with ad requests or a utm_ link.",
      .ai_control_title = "AI control",
      .ai_control_label = "Allow a local AI agent over CDP",
      .ai_control_hint =
          "Off by default. When on, DevTools binds only numeric loopback, "
          "never 0.0.0.0. Remote CDP does not list chrome:// or file:// pages.",
      .ai_control_status = "Debug port and bind",
      .ai_control_connect =
          "Playwright: chromium.connectOverCDP('http://127.0.0.1:PORT')",
      .ai_control_limit =
          "Limit: remote CDP hides chrome:// and file://, but page DOM is "
          "still "
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
  source->AddString("overviewTitle", strings.overview_title);
  source->AddString("overviewBlocked", strings.overview_blocked);
  source->AddString("overviewLinks", strings.overview_links);
  source->AddString("overviewStorage", strings.overview_storage);
  source->AddString("overviewScope", strings.overview_scope);
  source->AddString("modulesTitle", strings.modules_title);
  source->AddString("trackerLabel", strings.tracker_label);
  source->AddString("trackerHint", strings.tracker_hint);
  source->AddString("phishLabel", strings.phish_label);
  source->AddString("phishHint", strings.phish_hint);
  source->AddString("fingerprintLabel", strings.fingerprint_label);
  source->AddString("fingerprintHint", strings.fingerprint_hint);
  source->AddString("fingerprintProbe", strings.fingerprint_probe);
  source->AddString("minerGuardLabel", strings.miner_guard_label);
  source->AddString("minerGuardHint", strings.miner_guard_hint);
  source->AddString("filterListTitle", strings.filter_list_title);
  source->AddString("filterListAutoUpdate", strings.filter_list_auto_update);
  source->AddString("filterListAutoUpdateHint",
                    strings.filter_list_auto_update_hint);
  source->AddString("filterListUpdateNow", strings.filter_list_update_now);
  source->AddString("filterListMeta", strings.filter_list_meta);
  source->AddString("downloadsTitle", strings.downloads_title);
  source->AddString("downloadsMeta", strings.downloads_meta);
  source->AddString("metalinkFileLabel", strings.metalink_file_label);
  source->AddString("metalinkInspect", strings.metalink_inspect);
  source->AddString("metalinkDownload", strings.metalink_download);
  source->AddString("metalinkSafety", strings.metalink_safety);
  source->AddString("torrentTitle", strings.torrent_title);
  source->AddString("torrentMeta", strings.torrent_meta);
  source->AddString("torrentFileLabel", strings.torrent_file_label);
  source->AddString("magnetLabel", strings.magnet_label);
  source->AddString("torrentInspect", strings.torrent_inspect);
  source->AddString("torrentStart", strings.torrent_start);
  source->AddString("torrentDht", strings.torrent_dht);
  source->AddString("torrentPex", strings.torrent_pex);
  source->AddString("torrentDownloadLimit", strings.torrent_download_limit);
  source->AddString("torrentUploadLimit", strings.torrent_upload_limit);
  source->AddString("torrentDisclosure", strings.torrent_disclosure);
  source->AddString("torrentPause", strings.torrent_pause);
  source->AddString("torrentResume", strings.torrent_resume);
  source->AddString("torrentCancel", strings.torrent_cancel);
  source->AddString("torrentSafety", strings.torrent_safety);
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
  source->AddString("summaryPreviewTitle", strings.summary_preview_title);
  source->AddString("summaryPreviewRead", strings.summary_preview_read);
  source->AddString("summaryPreviewRedacted", strings.summary_preview_redacted);
  source->AddString("summaryPreviewDestination",
                    strings.summary_preview_destination);
  source->AddString("summaryPreviewScope", strings.summary_preview_scope);
  source->AddString("summaryPreviewCancel", strings.summary_preview_cancel);
  source->AddString("summaryPreviewConfirm", strings.summary_preview_confirm);
  source->AddString("modelProviderLabel", strings.model_provider_label);
  source->AddString("modelOpenAiCompatible", strings.model_openai_compatible);
  source->AddString("modelAnthropicCompatible",
                    strings.model_anthropic_compatible);
  source->AddString("modelGeminiCompatible", strings.model_gemini_compatible);
  source->AddString("modelEndpointLabel", strings.model_endpoint_label);
  source->AddString("modelApiKeyLabel", strings.model_api_key_label);
  source->AddString("modelApiKeyHint", strings.model_api_key_hint);
  source->AddString("modelSelectLabel", strings.model_select_label);
  source->AddString("modelCustomLabel", strings.model_custom_label);
  source->AddString("modelLoad", strings.model_load);
  source->AddString("modelSave", strings.model_save);
  source->AddString("modelKeyClear", strings.model_key_clear);
  source->AddString("modelHint", strings.model_hint);
  source->AddString("modelDataNote", strings.model_data_note);
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
