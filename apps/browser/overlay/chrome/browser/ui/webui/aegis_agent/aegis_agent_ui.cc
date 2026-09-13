// Copyright 2026 GCSA

#include "chrome/browser/ui/webui/aegis_agent/aegis_agent_ui.h"

#include <string>

#include "base/feature_list.h"
#include "base/strings/string_util.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/webui/aegis_agent/aegis_agent_page_handler.h"
#if !BUILDFLAG(IS_ANDROID)
#include "chrome/browser/ui/webui/theme_source.h"
#endif
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
  source->AddString("language", g_browser_process->GetApplicationLocale());
  auto add = [&](const char* key, const char* en, const char* zh_cn,
                 const char* zh_tw) {
    source->AddString(key, Localized(language, en, zh_cn, zh_tw));
  };
  add("title", "GCSA Aegis AI Assistant", "GCSA Aegis AI 助手",
      "GCSA Aegis AI 助手");
  add("subtitle", "Tell Aegis the goal. It understands, plans, then acts.",
      "说出目标，Aegis 会先理解、制定计划，再操作浏览器。",
      "說出目標，Aegis 會先理解、制定計畫，再操作瀏覽器。");
  add("taskWorkspace", "Common tasks", "常用任务", "常用任務");
  add("automationWorkspace", "Automations", "自动化", "自動化");
  add("target", "Where Aegis will work", "Aegis 将在哪里操作",
      "Aegis 將在哪裡操作");
  add("goal", "What should Aegis do?", "希望 Aegis 做什么？",
      "希望 Aegis 做什麼？");
  add("goalPlaceholder",
      "For example: compare three reliable USB hubs and summarize the "
      "differences",
      "例如：帮我找三款靠谱的 USB 扩展坞，对比后告诉我区别",
      "例如：幫我找三款可靠的 USB 擴充座，比較後告訴我差異");
  add("origins", "Allowed origins (optional)", "允许访问的来源（可选）",
      "允許存取的來源（選填）");
  add("plan", "Start task", "开始任务", "開始任務");
  add("start", "Approve and start", "同意并开始", "同意並開始");
  add("scope", "What Aegis is doing", "Aegis 正在做什么", "Aegis 正在做什麼");
  add("timeline", "Timeline", "执行时间线", "執行時間軸");
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
  add("disabled", "Aegis will be enabled for this profile when you start.",
      "点击“开始任务”后，会为当前浏览器用户启用 Aegis。",
      "點擊「開始任務」後，會為目前瀏覽器使用者啟用 Aegis。");
  add("noTarget",
      "Aegis understands the goal first, then decides whether a page or search "
      "is needed.",
      "Aegis 会先理解目标，再决定是否需要打开或搜索网页。",
      "Aegis 會先理解目標，再決定是否需要開啟或搜尋網頁。");
  add("simpleHelp", "Choose a common task or describe the result you want.",
      "选择一个常用场景，或者直接说出你想要的结果。",
      "選擇一個常用情境，或直接說出你想要的結果。");
  add("modelSettings", "AI model", "AI 模型", "AI 模型");
  add("modelMissing", "Connect an AI model before the first task",
      "首次使用前，先连接一个 AI 模型", "首次使用前，先連接一個 AI 模型");
  add("workspaceLabel", "AI assistant workspace", "AI 助手工作区",
      "AI 助手工作區");
  add("quickActionsLabel", "Common tasks", "常用任务", "常用任務");
  add("automationTemplatesLabel", "Automation templates", "自动化模板",
      "自動化範本");
  add("controlsLabel", "Task controls", "任务操作", "任務操作");
  add("openaiCompatible", "OpenAI compatible", "OpenAI 兼容", "OpenAI 相容");
  add("modelReady", "Model configured", "已配置模型", "已設定模型");
  add("modelHint",
      "API key requirements depend on the service. Saved keys are not "
      "displayed again.",
      "是否需要 API 密钥取决于所选服务。已保存的密钥不会再次显示。",
      "是否需要 API 金鑰取決於所選服務。已儲存的金鑰不會再次顯示。");
  add("providerLabel", "API format", "API 格式", "API 格式");
  add("baseUrlLabel", "Service address", "服务地址", "服務位址");
  add("modelNameLabel", "Model name", "模型名称", "模型名稱");
  add("apiKeyLabel", "API key (optional)", "API 密钥（可选）",
      "API 金鑰（選填）");
  add("detectModels", "Detect models", "检测可用模型", "偵測可用模型");
  add("saveModel", "Save model settings", "保存模型设置", "儲存模型設定");
  add("modelDetected", "Model list retrieved", "模型列表获取成功",
      "模型清單取得成功");
  add("modelSaved", "Model settings saved", "模型设置已保存", "模型設定已儲存");
  add("modelConfigurationError",
      "The API format, service address, model name, or key format is invalid. "
      "Check the inputs and save again.",
      "API 格式、服务地址、模型名称或密钥格式无效，请检查输入后重新保存。",
      "API 格式、服務位址、模型名稱或金鑰格式無效，請檢查輸入後重新儲存。");
  add("modelStorageError",
      "The browser cannot securely save the key yet. Check any system access "
      "prompt, then enter the key again and retry. Plaintext storage is not "
      "used.",
      "浏览器暂时无法安全保存密钥。请检查系统授权提示后，重新输入密钥并保存。"
      "不会改用明文保存。",
      "瀏覽器暫時無法安全儲存金鑰。請檢查系統授權提示後，重新輸入金鑰並儲存。"
      "不會改用明文儲存。");
  add("modelSaveError",
      "The save result could not be confirmed. Your non-sensitive inputs are "
      "kept for retry. Re-enter the key if one is needed.",
      "暂时无法确认保存结果，已保留非敏感输入供重试。如需密钥，请重新输入。",
      "暫時無法確認儲存結果，已保留非敏感輸入供重試。如需金鑰，請重新輸入。");
  add("modelConnectionError",
      "Aegis could not reach the model service. Make sure it is running, then "
      "try Detect models again.",
      "无法连接模型服务。请确认服务正在运行，再点“检测可用模型”。",
      "無法連接模型服務。請確認服務正在執行，再點「偵測可用模型」。");
  add("quickSummary", "Summarize this page", "总结当前页", "總結目前頁面");
  add("quickSummaryGoal", "Summarize this page and list the key points",
      "总结当前页面内容，并列出重点", "總結目前頁面內容，並列出重點");
  add("quickResearch", "Compare products", "对比商品", "比較商品");
  add("quickResearchGoal",
      "Compare three reliable USB hubs and summarize the differences",
      "帮我找三款靠谱的 USB 扩展坞，对比后告诉我区别",
      "幫我找三款可靠的 USB 擴充座，比較後告訴我差異");
  add("quickSteward", "Tidy bookmarks", "整理书签", "整理書籤");
  add("quickStewardGoal",
      "Organize my bookmarks by topic and show a preview before changing "
      "anything",
      "按主题整理我的书签，修改前先给我看预览",
      "按主題整理我的書籤，修改前先讓我看預覽");
  add("quickUrlCheck", "Check dead links", "检查失效链接", "檢查失效連結");
  add("quickUrlCheckGoal",
      "Check my bookmarks for unreachable links and summarize the results "
      "without changing anything",
      "检查书签里无法访问或已经失效的链接，只汇总结果，不要修改",
      "檢查書籤裡無法存取或已經失效的連結，只彙總結果，不要修改");
  add("quickDownload", "Find download", "找官方下载", "找官方下載");
  add("quickDownloadGoal",
      "Find the official safe download for the app I describe",
      "帮我找到我说的软件的官方安全下载地址",
      "幫我找到我說的軟體的官方安全下載位址");
  add("quickGather", "Research a topic", "搜集资料", "蒐集資料");
  add("quickGatherGoal",
      "Research the topic I describe, compare reliable sources, and give me a "
      "concise conclusion with links",
      "围绕我说的主题搜集可靠资料，对比来源后给我简明结论和链接",
      "圍繞我說的主題蒐集可靠資料，比較來源後給我簡明結論和連結");
  add("automationTitle", "Create an automation", "创建定时自动化",
      "建立定時自動化");
  add("automationHelp",
      "Aegis checks while the browser is running. It never purchases, submits, "
      "or downloads automatically.",
      "浏览器运行时，Aegis 会按频率检查；不会自动购买、提交或运行下载内容。",
      "瀏覽器執行時，Aegis 會按頻率檢查；不會自動購買、提交或執行下載內容。");
  add("automationGoal", "What should Aegis keep checking?",
      "希望持续检查什么？", "希望持續檢查什麼？");
  add("automationGoalPlaceholder",
      "For example: monitor this product and notify me when the price drops",
      "例如：持续关注这个商品，降价时提醒我",
      "例如：持續關注這個商品，降價時提醒我");
  add("scheduleLabel", "Run frequency", "运行频率", "執行頻率");
  add("scheduleHelp",
      "Missed runs collapse into one check after the browser restarts.",
      "浏览器关闭期间不会后台运行；重新打开后只补做一次检查。",
      "瀏覽器關閉期間不會在背景執行；重新開啟後只補做一次檢查。");
  add("schedule15Minutes", "Every 15 minutes", "每 15 分钟", "每 15 分鐘");
  add("scheduleHourly", "Every hour", "每小时", "每小時");
  add("schedule6Hours", "Every 6 hours", "每 6 小时", "每 6 小時");
  add("scheduleDaily", "Every day", "每天", "每天");
  add("scheduleWeekly", "Every week", "每周", "每週");
  add("createAutomation", "Create automation", "创建自动化", "建立自動化");
  add("automationsTitle", "My automations", "我的自动化", "我的自動化");
  add("emptyAutomations", "No automations yet.", "还没有自动化任务。",
      "還沒有自動化任務。");
  add("automationPrice", "Price drop", "降价提醒", "降價提醒");
  add("automationPriceGoal",
      "Monitor the product on this page and notify me when its price drops",
      "监控当前页面商品的价格变化，降价时提醒我",
      "監控目前頁面商品的價格變化，降價時提醒我");
  add("automationInventory", "Back in stock", "到货提醒", "到貨提醒");
  add("automationInventoryGoal",
      "Monitor the product on this page and notify me when it is back in stock",
      "监控当前页面商品的库存，恢复到货时提醒我",
      "監控目前頁面商品的庫存，恢復到貨時提醒我");
  add("automationPageChange", "Page updates", "网页更新", "網頁更新");
  add("automationPageChangeGoal",
      "Monitor this page and summarize meaningful changes",
      "监控当前页面的内容变化，有重要更新时总结变化",
      "監控目前頁面的內容變化，有重要更新時總結變化");
  add("automationUrlStatus", "URL health", "链接可用性", "链接可用性");
  add("automationUrlStatusGoal",
      "Check whether this page remains reachable and notify me if it "
      "fails",
      "定期检查当前页面是否还能访问，失效时提醒我",
      "定期檢查目前頁面是否還能存取，失效時提醒我");
  add("automationPaused", "Paused", "已暂停", "已暫停");
  add("automationPausedHelp", "This automation will not run until resumed.",
      "恢复前不会继续运行。", "恢復前不會繼續執行。");
  add("automationNextRun", "Next run: $1", "下次运行：$1", "下次執行：$1");
  add("automationSessionOnly", "This browser session only", "仅本次浏览器会话",
      "僅本次瀏覽器工作階段");
  add("automationSessionOnlyHelp",
      "Secure storage is unavailable. Keep this browser open; this automation "
      "will not resume after restart.",
      "安全存储暂不可用。保持浏览器开启时仍会按计划检查；关闭后不会恢复。",
      "安全儲存空間暫不可用。保持瀏覽器開啟時仍會按計畫檢查；關閉後不會恢復。");
  add("automationFailures", "Recent failures: $1", "连续失败：$1 次",
      "連續失敗：$1 次");
  add("automationCheckStatus1", "Last check succeeded.", "上次检查成功。",
      "上次檢查成功。");
  add("automationCheckStatus2", "The page returned an HTTP error.",
      "页面返回 HTTP 错误，请查看状态码。",
      "頁面傳回 HTTP 錯誤，請查看狀態碼。");
  add("automationCheckStatus3",
      "Access requires login or was denied; URL health is unconfirmed.",
      "页面要求登录或拒绝访问，尚不能判定链接失效。",
      "頁面要求登入或拒絕存取，尚不能判定連結失效。");
  add("automationCheckStatus4",
      "The site is rate-limiting requests; a later check is scheduled.",
      "网站正在限制请求，已安排稍后检查。",
      "網站正在限制請求，已安排稍後檢查。");
  add("automationCheckStatus5",
      "Network or secure connection failed; URL health is unconfirmed.",
      "网络或安全连接失败，尚不能判定链接失效。",
      "網路或安全連線失敗，尚不能判定連結失效。");
  add("automationCheckStatus6",
      "The check timed out; a later check is scheduled.",
      "检查超时，已安排稍后重试。", "檢查逾時，已安排稍後重試。");
  add("automationCheckStatus7",
      "A redirect left the approved site or exceeded the redirect limit.",
      "跳转离开了批准的网站或次数过多，已停止跟随。",
      "跳轉離開了核准的網站或次數過多，已停止跟隨。");
  add("automationCheckStatus8",
      "The saved target or its permission is unavailable.",
      "保存的目标或访问权限不可用，请重新创建任务。",
      "儲存的目標或存取權限不可用，請重新建立任務。");
  add("automationCheckStatus9",
      "The check page was closed, taken over, or could not be opened.",
      "检查页面被关闭、接管或无法打开，本次没有完成检查。",
      "檢查頁面被關閉、接管或無法開啟，本次沒有完成檢查。");
  add("automationCheckStatus10",
      "The approved request budget is exhausted; this automation is paused.",
      "已用完批准的请求额度，自动化已暂停。",
      "已用完核准的請求額度，自動化已暫停。");
  add("automationCheckStatus11",
      "The last check failed; review the target and retry.",
      "上次检查未完成，请检查目标后重试。",
      "上次檢查未完成，請檢查目標後重試。");
  add("automationCheckStatus12",
      "The page did not provide an unambiguous price, stock status, or "
      "content. No change was inferred.",
      "页面没有提供明确的价格、库存或正文，本次未推断变化。",
      "頁面沒有提供明確的價格、庫存或正文，本次未推斷變化。");
  add("automationCheckStatus13",
      "Secure storage is unavailable. No plaintext fallback was used; check "
      "system authorization and retry.",
      "安全存储暂不可用，未改用明文保存；请检查系统授权后重试。",
      "安全儲存暫不可用，未改用明文儲存；請檢查系統授權後重試。");
  add("automationCheckStatus14",
      "Page content was read, but the AI change summary was unavailable. The "
      "previous record is retained for retry.",
      "已读取页面，但 AI 变化摘要未生成；已保留上次记录，稍后重试。",
      "已讀取頁面，但 AI 變化摘要未產生；已保留上次記錄，稍後重試。");
  add("automationChangeSummary", "AI change summary", "AI 变化摘要",
      "AI 變化摘要");
  add("automationChangeSummaryPartial",
      "Only the observed excerpts are summarized; more changes may exist.",
      "仅总结已读取的变化片段，可能还有其他更新。",
      "僅總結已讀取的變化片段，可能還有其他更新。");
  add("details", "Technical details", "技术详情", "技術詳情");
  add("statusIdle", "Ready", "可以开始", "可以開始");
  add("statusUnderstanding", "Understanding your goal…", "正在理解你的需求…",
      "正在理解你的需求…");
  add("statusPlanning", "Making a plan…", "正在制定计划…", "正在制定計畫…");
  add("statusRunning", "Working…", "正在执行…", "正在執行…");
  add("statusPaused", "Paused", "已暂停", "已暫停");
  add("statusScheduled", "Waiting for next check", "等待定时检查",
      "等待定時檢查");
  add("statusRecovering", "Task restored", "任务已恢复", "任務已恢復");
  add("statusCancelled", "Stopped", "已停止", "已停止");
  add("statusExpired", "Task expired", "任务已到期", "任務已到期");
  add("automationScheduledHelp",
      "The automation is ready and waiting for its next scheduled check. "
      "Keep the browser open; you can pause it in My automations.",
      "自动化已就绪，正在等待下一次定时检查。请保持浏览器开启；"
      "可在“我的自动化”中暂停。",
      "自動化已就緒，正在等待下一次定時檢查。請保持瀏覽器開啟；"
      "可在「我的自動化」中暫停。");
  add("statusApproval", "Needs your approval", "需要你的确认", "需要你的確認");
  add("statusTakeover", "Your turn", "需要你接管", "需要你接管");
  add("statusCompleted", "Done", "已完成", "已完成");
  add("statusPartial", "Partially done", "部分完成", "部分完成");
  add("statusEnded", "Execution ended", "执行已结束", "執行已結束");
  add("resultPartialTitle", "Partial result", "部分完成的结果",
      "部分完成的結果");
  add("resultPartialHelp",
      "Some items remain unfinished. Review them before deciding what to do "
      "next.",
      "仍有事项尚未完成，请查看下方说明后再决定下一步。",
      "仍有事項尚未完成，請查看下方說明後再決定下一步。");
  add("timelinePartialDetail", "Results checked; some items remain unfinished",
      "已核对现有结果，仍有事项未完成", "已核對現有結果，仍有事項未完成");
  add("timelineEndedDetail",
      "Execution ended; no complete result is available yet",
      "执行已结束，尚无完整结果", "執行已結束，尚無完整結果");
  add("statusFailed", "Needs attention", "遇到问题", "遇到問題");
  add("pageContextUnavailableError",
      "The task page was still loading, was closed, or left the approved "
      "site. Aegis stopped without reading other pages. Wait for the page "
      "to load or check your connection, then retry this task.",
      "任务网页尚未加载完成、已关闭，或离开了允许的网站。Aegis 已停止，"
      "没有读取其他网页。请等待页面加载或检查网络后重试本任务。",
      "任務網頁尚未載入完成、已關閉，或離開了允許的網站。Aegis 已停止，"
      "沒有讀取其他網頁。請等待頁面載入或檢查網路後重試本任務。");
  add("planFailed", "The task did not start. Edit the goal and try again.",
      "任务未开始，可以修改目标后重试。", "任務未開始，可以修改目標後重試。");
  add("taskInputError",
      "The task or schedule is invalid. Edit it and try again.",
      "任务内容或定时设置无效，请修改后重试。",
      "任務內容或定時設定無效，請修改後重試。");
  add("automationPlanError",
      "The AI did not include the required scheduled check. No automation was "
      "created. Keep this page open and try again.",
      "AI "
      "没有生成必需的定时检查步骤，因此没有创建自动化。请保留当前页面并重试。",
      "AI "
      "沒有產生必要的定時檢查步驟，因此沒有建立自動化。請保留目前頁面並重試。");
  add("automationTargetError",
      "Aegis could not verify the page to monitor. Reopen the page and retry.",
      "Aegis 无法确认要监控的网页。请重新打开该网页后重试。",
      "Aegis 無法確認要監控的網頁。請重新開啟該網頁後重試。");
  add("automationRuntimeError",
      "The automation could not be created. Keep the browser open and retry.",
      "自动化未能创建。请保持浏览器开启后重试。",
      "自動化未能建立。請保持瀏覽器開啟後重試。");
  add("relatedPageOpenError",
      "The related page could not be opened. Check the network and retry this "
      "task.",
      "无法打开相关网页。请检查网络后，直接重试这个任务。",
      "無法開啟相關網頁。請檢查網路後，直接重試這個任務。");
  add("currentPageUnavailableError",
      "Open a normal public webpage, then ask Aegis to work with this page.",
      "请先打开一个普通公开网页，再让 Aegis 处理当前页面。",
      "請先開啟一個普通公開網頁，再讓 Aegis 處理目前頁面。");
  add("planningScopeError",
      "Aegis did not recognize the target correctly. Nothing was changed. "
      "Please try again.",
      "Aegis 没有正确识别目标，本次未执行任何操作。请直接重试。",
      "Aegis 沒有正確識別目標，本次未執行任何操作。請直接重試。");
  add("planningFormatError",
      "The AI returned an invalid plan. Nothing was changed. Please try again.",
      "AI 返回的计划格式不正确，本次未执行任何操作。请直接重试。",
      "AI 返回的計畫格式不正確，本次未執行任何操作。請直接重試。");
  add("planningGenericError",
      "The task did not start. Nothing was changed. Check the model connection "
      "and try again.",
      "任务没有成功开始，本次未执行任何操作。请检查模型连接后重试。",
      "任務沒有成功開始，本次未執行任何操作。請檢查模型連線後重試。");
  add("startupError",
      "Aegis could not connect to its browser runtime. Restart the browser "
      "and try again.",
      "Aegis 无法连接浏览器执行引擎。请重启浏览器后重试。",
      "Aegis 無法連接瀏覽器執行引擎。請重新啟動瀏覽器後重試。");
  add("executionFormatError",
      "The AI did not produce the next planned action correctly. Aegis stopped "
      "safely; retry the task.",
      "AI 没有正确生成计划中的下一步操作，Aegis 已安全停止。请直接重试任务。",
      "AI 沒有正確產生計畫中的下一步操作，Aegis 已安全停止。請直接重試任務。");
  add("executionRequiredToolError",
      "The model did not call the required $1 action after two attempts. Aegis "
      "stopped safely at that step; retry the task.",
      "模型连续两次没有调用计划要求的 $1，Aegis "
      "已在该步骤安全停止。请重试任务。",
      "模型連續兩次沒有呼叫計畫要求的 $1，Aegis "
      "已在該步驟安全停止。請重試任務。");
  add("executionCompletionError",
      "The page was read, but the AI did not produce the final answer "
      "correctly. Aegis stopped safely; retry the task.",
      "页面已经读取，但 AI 没有正确生成最终回答。Aegis "
      "已安全停止，请重试任务。",
      "頁面已經讀取，但 AI 沒有正確產生最終回答。Aegis "
      "已安全停止，請重試任務。");
  add("executionGenericError",
      "The task started but could not continue. Aegis stopped safely; retry "
      "the task or open technical details for the exact cause.",
      "任务已经开始，但未能继续完成。Aegis "
      "已安全停止；请重试，或展开技术详情查看准确原因。",
      "任務已經開始，但未能繼續完成。Aegis "
      "已安全停止；請重試，或展開技術詳情查看準確原因。");
  add("bookmarkUrlLimitError",
      "This task can safely check up to 100 bookmark links at a time. No "
      "bookmark was changed; narrow the selection and retry.",
      "一次任务最多安全检查 100 个收藏链接。本次未修改书签；请缩小范围后重试。",
      "一次任務最多安全檢查 100 "
      "個書籤連結。本次未修改書籤；請縮小範圍後重試。");
  add("bookmarkUrlSafetyError",
      "A bookmark address could not be checked safely (for example, a local, "
      "private-network, duplicate, or invalid address). No bookmark was "
      "changed; remove it from the selection and retry.",
      "收藏链接中包含浏览器无法安全检查的地址（例如本机、内网、重复或格式异常地"
      "址）。"
      "本次未修改书签；请排除该地址后重试。",
      "書籤連結中包含瀏覽器無法安全檢查的位址（例如本機、內網、重複或格式異常位"
      "址）。"
      "本次未修改書籤；請排除該位址後重試。");
  add("technicalErrorLabel", "Exact failure detail", "准确失败原因",
      "準確失敗原因");
  add("goalRoutingError",
      "The AI could not determine a safe browser entry. Nothing was opened. "
      "Please clarify the goal and try again.",
      "AI "
      "没有判断出可靠的浏览器入口，本次没有打开网页。请把目标说得更具体后重试"
      "。",
      "AI "
      "沒有判斷出可靠的瀏覽器入口，本次沒有開啟網頁。請把目標說得更具體後重試"
      "。");
  add("timelinePlanning", "Understanding the task", "正在理解任务",
      "正在理解任務");
  add("timelinePlanningDetail", "Identifying the target and planning steps",
      "正在识别目标并生成步骤", "正在識別目標並產生步驟");
  add("timelinePlanningRepair", "Correcting the plan format",
      "正在修正计划格式", "正在修正計畫格式");
  add("timelinePlanningRepairDetail",
      "The browser asked the AI to correct the plan once",
      "浏览器已让 AI 自动修正一次，无需你处理",
      "瀏覽器已讓 AI 自動修正一次，無需你處理");
  add("timelinePlanningRecovery", "Using a safe read-only fallback",
      "正在使用安全的只读方案", "正在使用安全的唯讀方案");
  add("timelinePlanningRecoveryDetail",
      "The AI plan format failed twice; the browser kept only approved "
      "read-only steps",
      "AI 两次没有按格式生成计划，浏览器已改用批准的只读步骤",
      "AI 兩次沒有按格式產生計畫，瀏覽器已改用批准的唯讀步驟");
  add("timelineReady", "Plan ready", "计划已准备", "計畫已準備");
  add("timelineReadyDetail", "The browser safety check passed",
      "计划已通过浏览器安全检查", "計畫已通過瀏覽器安全檢查");
  add("timelineRunning", "Using the webpage", "正在操作网页", "正在操作網頁");
  add("timelineRunningDetail", "Started with this task's permission",
      "已按当前任务授权开始执行", "已按目前任務授權開始執行");
  add("timelineVerifying", "Checking the result", "正在检查结果",
      "正在檢查結果");
  add("timelineVerifyingDetail", "Web actions finished; checking the result",
      "网页操作已完成，正在核对结果", "網頁操作已完成，正在核對結果");
  add("timelineCompleted", "Task complete", "任务完成", "任務完成");
  add("timelineCompletedDetail", "Result checked", "结果已核对", "結果已核對");
  add("timelineMonitorReady", "Automation ready", "监控已创建", "監控已建立");
  add("timelineMonitorReadyDetail",
      "The setup plan was checked; the independent monitor handles future "
      "checks",
      "创建计划已核对，后续检查由独立监控执行",
      "建立計畫已核對，後續檢查由獨立監控執行");
  add("timelineFailed", "Task not completed", "任务未完成", "任務未完成");
  add("timelineRestartedDetail",
      "The browser restarted. Saved automations were restored; previous web "
      "actions were not repeated.",
      "浏览器已重启，已保存的自动化已恢复；之前的网页操作没有重复执行。",
      "瀏覽器已重新啟動，已儲存的自動化已恢復；先前的網頁操作沒有重複執行。");
  add("timelineFailedDetail", "The plan did not pass; no web action ran",
      "计划未通过检查，没有执行网页操作", "計畫未通過檢查，沒有執行網頁操作");
  add("timelineExecutionFormatFailed",
      "The AI could not form the next planned action",
      "AI 未能按计划生成下一步操作", "AI 未能按計畫產生下一步操作");
  add("timelineRequiredToolFailed",
      "Required action $1 was not produced after retrying",
      "重试后仍未生成计划要求的 $1", "重試後仍未產生計畫要求的 $1");
  add("timelineBrowserActionFailed",
      "A browser action still failed after retrying",
      "浏览器操作重试后仍未成功", "瀏覽器操作重試後仍未成功");
  add("timelineBrowserActionRetry", "Retrying one browser action",
      "浏览器正在自动重试一次操作", "瀏覽器正在自動重試一次操作");
  add("timelineBrowserActionRetrySucceeded", "The retry succeeded",
      "自动重试已成功", "自動重試已成功");
  add("timelineCompletionEvidenceRejected",
      "The AI summary did not match the browser result",
      "AI 的总结与浏览器结果不一致", "AI 的總結與瀏覽器結果不一致");
  add("resultTitle", "Result", "任务结果", "任務結果");
  add("resultSources", "Sources", "来源", "來源");
  add("unfinishedItems", "Not finished", "未完成事项", "未完成事項");
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
    : AegisAgentUIConfigBase(content::kChromeUIUntrustedScheme,
                             chrome::kChromeUIUntrustedAegisAgentHost) {}

AegisAgentUIConfig::~AegisAgentUIConfig() = default;

bool AegisAgentUIConfig::IsWebUIEnabled(
    content::BrowserContext* browser_context) {
  Profile* profile =
      browser_context ? Profile::FromBrowserContext(browser_context) : nullptr;
  if (!base::FeatureList::IsEnabled(aegis::features::kAegisAgent) ||
      !aegis::IsAegisProfileSupported(profile)) {
    return false;
  }
#if BUILDFLAG(IS_ANDROID)
  return !profile->IsOffTheRecord();
#else
  return true;
#endif
}

AegisAgentUI::AegisAgentUI(content::WebUI* web_ui)
    : AegisAgentUIControllerBase(web_ui) {
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

#if !BUILDFLAG(IS_ANDROID)
  Profile* profile = Profile::FromWebUI(web_ui);
  content::URLDataSource::Add(profile, std::make_unique<ThemeSource>(
                                           profile, /*serve_untrusted=*/true));
#endif
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
