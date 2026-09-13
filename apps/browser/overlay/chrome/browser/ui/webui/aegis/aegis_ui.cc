// Copyright 2026 GCSA
// Intended path: chrome/browser/ui/webui/aegis/aegis_ui.cc

#include "chrome/browser/ui/webui/aegis/aegis_ui.h"

#include <string>

#include "build/build_config.h"
#include "chrome/browser/aegis/aegis_service_factory.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/webui/aegis/aegis_ui_handler.h"
#include "chrome/common/webui_url_constants.h"
#include "chrome/grit/aegis_resources.h"
#include "chrome/grit/aegis_resources_map.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_data_source.h"
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
  const char* fingerprint_details;
  const char* technical_details;
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
  const char* browser_agent_title;
  const char* browser_agent_label;
  const char* browser_agent_hint;
  const char* browser_agent_open;
  const char* browser_agent_status;
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
        .title = "GCSA Aegis",
        .subtitle = "防護中心",
        .overview_title = "防護概覽",
        .overview_blocked = "已攔截請求",
        .overview_links = "已清理連結",
        .overview_storage = "Cookie／跳轉清理",
        .overview_scope =
            "顯示本次瀏覽期間的防護記錄。記錄數量不代表網站可信。",
        .modules_title = "防護設定",
        .tracker_label = "追蹤器攔截",
        .tracker_hint = "攔截已識別的廣告和跟蹤請求。",
        .phish_label = "釣魚網站防護",
        .phish_hint = "打開高風險仿冒站前顯示攔截頁，可選擇繼續造訪。",
        .fingerprint_label = "指紋防護",
        .fingerprint_hint = "減少網站透過裝置特徵跨站識別您的機會。",
        .fingerprint_details =
            "對 Canvas、WebGL、Audio、WebGPU 做穩定化。檢測兩次時，同頁 Audio "
            "讀數應相同；WebGPU 的 maxBufferSize 會隨開關變化。",
        .technical_details = "技術詳情",
        .fingerprint_probe = "檢測本頁指紋",
        .miner_guard_label = "挖礦腳本偵測（僅觀察）",
        .miner_guard_hint =
            "檢測可能的挖礦活動並記錄提醒，不終止指令碼或連線。重新啟用後請重新"
            "整理網頁。",
        .filter_list_title = "廣告與跟蹤過濾規則",
        .filter_list_auto_update = "自動更新過濾列表",
        .filter_list_auto_update_hint =
            "約每 24 小時檢查一次。更新失敗時繼續使用現有規則。",
        .filter_list_update_now = "立即更新",
        .filter_list_meta =
            "尚未下載過濾列表。更新後會編譯 EasyList / EasyPrivacy。",
        .downloads_title = "下載中心",
        .downloads_meta = "管理普通下載、映象下載、種子和磁力連結下載。",
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
        .link_sanitize_label = "清理跟蹤引數",
        .link_sanitize_hint = "移除網址和來源資訊中的已知跟蹤引數。",
        .cookie_janitor_label = "清理跟蹤 Cookie",
        .cookie_janitor_hint =
            "清理已識別的廣告和分析 Cookie，並保留規則中的登入例外。",
        .cname_uncloak_label = "偽裝跟蹤防護",
        .cname_uncloak_hint = "識別借用網站域名的已知跟蹤服務並攔截請求。",
        .bounce_tracking_label = "跳轉跟蹤防護",
        .bounce_tracking_hint = "識別用於跟蹤的頁面跳轉，並清理相關 Cookie。",
        .policy_worker_label = "本地隱私處理",
        .policy_worker_hint =
            "在本機分析可疑網址、隱藏敏感資訊並準備網頁摘要。",
        .privacy_ai_label = "網頁摘要",
        .privacy_ai_hint =
            "先隱藏敏感資訊，再使用所選模型服務生成摘要。傳送到非本機服務前會請"
            "您確認。",
        .privacy_ai_title = "摘要與模型設定",
        .privacy_ai_meta =
            "支援 OpenAI 相容、Claude（Anthropic）相容或 Gemini 相容 API；"
            "模型不可用時使用本機啟發式摘要。",
        .privacy_ai_summarize = "摘要目前分頁",
        .summary_preview_title = "摘要前確認",
        .summary_preview_read = "將讀取的頁面文字",
        .summary_preview_redacted = "脫敏後文字",
        .summary_preview_destination = "處理位置",
        .summary_preview_scope =
            "不會傳送完整網址查詢引數。傳送到非本機服務前，請確認處理位置和文字"
            "範圍。",
        .summary_preview_cancel = "取消",
        .summary_preview_confirm = "確認並摘要",
        .model_provider_label = "API 格式",
        .model_openai_compatible = "OpenAI 相容",
        .model_anthropic_compatible = "Claude（Anthropic）相容",
        .model_gemini_compatible = "Gemini 相容",
        .model_endpoint_label = "服務地址",
        .model_api_key_label = "API 金鑰",
        .model_api_key_hint =
            "可選；如保存，會安全綁定目前 API 格式與服務地址且不回顯。",
        .model_select_label = "模型",
        .model_custom_label = "自訂模型 ID",
        .model_load = "載入模型列表",
        .model_save = "保存模型設定",
        .model_key_clear = "清除 API 金鑰",
        .model_hint = "填寫模型服務地址，並從該服務獲取可用模型。",
        .model_data_note =
            "金鑰與所選服務繫結，加密儲存且不回顯。非本機服務會收到確認後的脫敏"
            "文字。",
        .activity_title = "本次瀏覽記錄",
        .activity_hint =
            "檢視已攔截的請求、已清理的跟蹤資訊和本機工具連線記錄。",
        .activity_empty = "暫無防護記錄。瀏覽網頁後，相關記錄會顯示在這裡。",
        .browser_agent_title = "AI 助手",
        .browser_agent_label = "啟用 AI 助手",
        .browser_agent_hint =
            "依計畫執行網頁與瀏覽器操作；寫入、下載與交易步驟仍由瀏覽器"
            "政策檢查，付款前必須由你接管。",
        .browser_agent_open = "開啟 AI 助手",
        .browser_agent_status = "Agent 功能旗標未啟用。",
        .ai_control_title = "本機 AI 工具連線",
        .ai_control_label = "允許本機 AI 工具讀取和操作網頁",
        .ai_control_hint =
            "預設關閉。開啟後允許本機工具連線瀏覽器，讀取網頁內容時不會自動隱藏"
            "敏感資訊。",
        .ai_control_status = "調試埠與綁定",
        .ai_control_connect =
            "Playwright：chromium.connectOverCDP('http://127.0.0.1:PORT')",
        .ai_control_limit =
            "連線只對本機開放。工具無法透過此介面列出內部頁面，但可以讀取普通網"
            "頁內容。",
        .note = "模組狀態會立即套用；過濾列表約每天自動更新一次。",
    };
  }
  if (locale.starts_with("zh")) {
    return {
        .title = "GCSA Aegis",
        .subtitle = "防护中心",
        .overview_title = "防护概览",
        .overview_blocked = "已拦截请求",
        .overview_links = "已清理链接",
        .overview_storage = "Cookie／跳转清理",
        .overview_scope =
            "显示本次浏览期间的防护记录。记录数量不代表网站可信。",
        .modules_title = "防护设置",
        .tracker_label = "跟踪器拦截",
        .tracker_hint = "拦截已识别的广告和跟踪请求。",
        .phish_label = "钓鱼网站防护",
        .phish_hint = "打开高风险仿冒站前显示拦截页，可选择继续访问。",
        .fingerprint_label = "指纹防护",
        .fingerprint_hint = "减少网站通过设备特征跨站识别您的机会。",
        .fingerprint_details =
            "对 Canvas、WebGL、Audio、WebGPU 做稳定化。检测两次时，同页 Audio "
            "读数应相同；WebGPU 的 maxBufferSize 会随开关变化。",
        .technical_details = "技术详情",
        .fingerprint_probe = "检测本页指纹",
        .miner_guard_label = "挖矿脚本检测（仅观察）",
        .miner_guard_hint =
            "检测可能的挖矿活动并记录提醒，不终止脚本或连接。重新启用后请刷新网"
            "页。",
        .filter_list_title = "广告与跟踪过滤规则",
        .filter_list_auto_update = "自动更新过滤列表",
        .filter_list_auto_update_hint =
            "约每 24 小时检查一次。更新失败时继续使用现有规则。",
        .filter_list_update_now = "立即更新",
        .filter_list_meta =
            "尚未下载过滤列表。更新后会编译 EasyList / EasyPrivacy。",
        .downloads_title = "下载中心",
        .downloads_meta = "管理普通下载、镜像下载、种子和磁力链接下载。",
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
        .link_sanitize_label = "清理跟踪参数",
        .link_sanitize_hint = "移除网址和来源信息中的已知跟踪参数。",
        .cookie_janitor_label = "清理跟踪 Cookie",
        .cookie_janitor_hint =
            "清理已识别的广告和分析 Cookie，并保留规则中的登录例外。",
        .cname_uncloak_label = "伪装跟踪防护",
        .cname_uncloak_hint = "识别借用网站域名的已知跟踪服务并拦截请求。",
        .bounce_tracking_label = "跳转跟踪防护",
        .bounce_tracking_hint = "识别用于跟踪的页面跳转，并清理相关 Cookie。",
        .policy_worker_label = "本地隐私处理",
        .policy_worker_hint =
            "在本机分析可疑网址、隐藏敏感信息并准备网页摘要。",
        .privacy_ai_label = "网页摘要",
        .privacy_ai_hint =
            "先隐藏敏感信息，再使用所选模型服务生成摘要。发送到非本机服务前会请"
            "您确认。",
        .privacy_ai_title = "摘要与模型设置",
        .privacy_ai_meta =
            "支持 OpenAI 兼容、Claude（Anthropic）兼容或 Gemini 兼容 API；"
            "模型不可用时使用本机启发式摘要。",
        .privacy_ai_summarize = "摘要当前标签页",
        .summary_preview_title = "摘要前确认",
        .summary_preview_read = "将读取的页面文字",
        .summary_preview_redacted = "脱敏后文字",
        .summary_preview_destination = "处理位置",
        .summary_preview_scope =
            "不会发送完整网址查询参数。发送到非本机服务前，请确认处理位置和文字"
            "范围。",
        .summary_preview_cancel = "取消",
        .summary_preview_confirm = "确认并摘要",
        .model_provider_label = "API 格式",
        .model_openai_compatible = "OpenAI 兼容",
        .model_anthropic_compatible = "Claude（Anthropic）兼容",
        .model_gemini_compatible = "Gemini 兼容",
        .model_endpoint_label = "服务地址",
        .model_api_key_label = "API 密钥",
        .model_api_key_hint =
            "可选；如保存，会安全绑定当前 API 格式与服务地址且不回显。",
        .model_select_label = "模型",
        .model_custom_label = "自定义模型 ID",
        .model_load = "加载模型列表",
        .model_save = "保存模型设置",
        .model_key_clear = "清除 API 密钥",
        .model_hint = "填写模型服务地址，并从该服务获取可用模型。",
        .model_data_note =
            "密钥与所选服务绑定，加密保存且不回显。非本机服务会收到确认后的脱敏"
            "文本。",
        .activity_title = "本次浏览记录",
        .activity_hint =
            "查看已拦截的请求、已清理的跟踪信息和本机工具连接记录。",
        .activity_empty = "暂无防护记录。浏览网页后，相关记录会显示在这里。",
        .browser_agent_title = "AI 助手",
        .browser_agent_label = "启用 AI 助手",
        .browser_agent_hint =
            "按计划执行网页与浏览器操作；写入、下载和交易步骤仍由浏览器"
            "策略检查，付款前必须由你接管。",
        .browser_agent_open = "打开 AI 助手",
        .browser_agent_status = "Agent 功能开关尚未启用。",
        .ai_control_title = "本机 AI 工具连接",
        .ai_control_label = "允许本机 AI 工具读取和操作网页",
        .ai_control_hint =
            "默认关闭。开启后允许本机工具连接浏览器，读取网页内容时不会自动隐藏"
            "敏感信息。",
        .ai_control_status = "调试端口与绑定",
        .ai_control_connect =
            "Playwright：chromium.connectOverCDP('http://127.0.0.1:PORT')",
        .ai_control_limit =
            "连接只对本机开放。工具无法通过此接口列出内部页面，但可以读取普通网"
            "页内容。",
        .note = "模块状态会立即生效；过滤列表大约每天自动更新一次。",
    };
  }
  return {
      .title = "GCSA Aegis",
      .subtitle = "Protection center",
      .overview_title = "Protection overview",
      .overview_blocked = "Requests blocked",
      .overview_links = "Links cleaned",
      .overview_storage = "Cookie / bounce cleanup",
      .overview_scope =
          "Protection activity during this browser session. Counts do not "
          "establish that a website is trustworthy.",
      .modules_title = "Protection settings",
      .tracker_label = "Tracker blocking",
      .tracker_hint = "Block recognized advertising and tracking requests.",
      .phish_label = "Phishing protection",
      .phish_hint =
          "Shows a warning before high-risk lookalike sites. You can continue.",
      .fingerprint_label = "Fingerprint Guard",
      .fingerprint_hint =
          "Reduce cross-site identification through device characteristics.",
      .fingerprint_details =
          "Canvas, WebGL, Audio and WebGPU stabilization. Audio should remain "
          "stable on repeated probes; maxBufferSize changes with protection.",
      .technical_details = "Technical details",
      .fingerprint_probe = "Probe this page fingerprints",
      .miner_guard_label = "Mining script detection (observe-only)",
      .miner_guard_hint =
          "Detect possible mining activity and record alerts without stopping "
          "scripts or connections. Reload pages after re-enabling.",
      .filter_list_title = "Advertising and tracking filters",
      .filter_list_auto_update = "Auto-update filter lists",
      .filter_list_auto_update_hint =
          "Check about every 24 hours. Keep existing rules if an update fails.",
      .filter_list_update_now = "Update now",
      .filter_list_meta =
          "No compiled filter list yet. Update to compile EasyList / "
          "EasyPrivacy.",
      .downloads_title = "Downloads",
      .downloads_meta = "Manage regular, mirror, torrent and magnet downloads.",
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
      .link_sanitize_label = "Remove tracking parameters",
      .link_sanitize_hint =
          "Remove known tracking parameters from URLs and referrer "
          "information.",
      .cookie_janitor_label = "Clear tracking cookies",
      .cookie_janitor_hint =
          "Clear recognized advertising and analytics cookies while preserving "
          "sign-in exceptions in the rules.",
      .cname_uncloak_label = "Disguised tracking protection",
      .cname_uncloak_hint =
          "Block known tracking services that use aliases under a website’s "
          "domain.",
      .bounce_tracking_label = "Redirect tracking protection",
      .bounce_tracking_hint =
          "Detect tracking redirects and clear related cookies.",
      .policy_worker_label = "Local privacy processing",
      .policy_worker_hint =
          "Analyze suspicious URLs, redact sensitive information and prepare "
          "summaries on this device.",
      .privacy_ai_label = "Page summaries",
      .privacy_ai_hint =
          "Redact sensitive information before summarizing with the selected "
          "model service. Sending to a non-local service requires "
          "confirmation.",
      .privacy_ai_title = "Summaries and model settings",
      .privacy_ai_meta =
          "Supports OpenAI-compatible, Anthropic (Claude)-compatible, or "
          "Gemini-compatible APIs, with on-device heuristic fallback.",
      .privacy_ai_summarize = "Summarize current tab",
      .summary_preview_title = "Confirm before summarizing",
      .summary_preview_read = "Page text to read",
      .summary_preview_redacted = "Text after redaction",
      .summary_preview_destination = "Processing destination",
      .summary_preview_scope =
          "Full URL query values are not sent. Confirm the destination and "
          "text scope before sending to a non-local service.",
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
          "Enter the model service address and retrieve its available models.",
      .model_data_note =
          "Keys are bound to the selected service, stored encrypted and not "
          "shown again. Non-local services receive redacted text after "
          "confirmation.",
      .activity_title = "This session",
      .activity_hint =
          "View blocked requests, tracking cleanup and local tool connections.",
      .activity_empty =
          "No protection activity yet. Relevant activity will appear as you "
          "browse.",
      .browser_agent_title = "AI assistant",
      .browser_agent_label = "Enable AI assistant",
      .browser_agent_hint =
          "Runs planned page and browser actions. Browser policy still gates "
          "writes, downloads, and transactions; you must take over before "
          "payment.",
      .browser_agent_open = "Open AI assistant",
      .browser_agent_status = "The Agent feature flag is not enabled.",
      .ai_control_title = "Local AI tool access",
      .ai_control_label = "Allow local AI tools to read and control pages",
      .ai_control_hint =
          "Off by default. Enabling allows local tools to connect to the "
          "browser. Page content they read is not automatically redacted.",
      .ai_control_status = "Debug port and bind",
      .ai_control_connect =
          "Playwright: chromium.connectOverCDP('http://127.0.0.1:PORT')",
      .ai_control_limit =
          "Connections are local only. Tools cannot list internal pages "
          "through this interface, but can read regular page content.",
      .note =
          "Changes apply immediately. Filter lists refresh about once a day.",
  };
}

}  // namespace

bool AegisUIConfig::IsWebUIEnabled(content::BrowserContext* browser_context) {
  Profile* profile = Profile::FromBrowserContext(browser_context);
#if BUILDFLAG(IS_ANDROID)
  return profile && profile->IsRegularProfile();
#else
  return aegis::IsAegisProfileSupported(profile);
#endif
}

AegisUI::AegisUI(content::WebUI* web_ui) : content::WebUIController(web_ui) {
  Profile* profile = Profile::FromWebUI(web_ui);
  content::WebUIDataSource* source = content::WebUIDataSource::CreateAndAdd(
      profile, chrome::kChromeUIAegisHost);
  // 默认 language 仅保留基础语言；动态文案需要地区信息区分简繁体。
  source->AddString("aegisLocale", g_browser_process->GetApplicationLocale());

  const AegisStrings strings =
      StringsForLocale(g_browser_process->GetApplicationLocale());
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
  source->AddString("fingerprintDetails", strings.fingerprint_details);
  source->AddString("technicalDetails", strings.technical_details);
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
  source->AddString("browserAgentTitle", strings.browser_agent_title);
  source->AddString("browserAgentLabel", strings.browser_agent_label);
  source->AddString("browserAgentHint", strings.browser_agent_hint);
  source->AddString("browserAgentOpen", strings.browser_agent_open);
  source->AddString("browserAgentStatus", strings.browser_agent_status);
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
