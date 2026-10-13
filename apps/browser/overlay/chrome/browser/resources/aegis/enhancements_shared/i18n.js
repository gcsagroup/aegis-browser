// Copyright 2026 GCSA
// 仅翻译已知界面文字；不会观察或改写脚本、文档、用户输入。
(function () {
  "use strict";
  const messages = {"为以下网址启用脚本？\n": ["Enable the script on these URLs?\n", "為以下網址啟用腳本？\n"], "\n权限：": ["\nPermissions: ", "\n權限："], "\n脚本能读取和修改网页内容。": ["\nThe script can read and change page content.", "\n腳本能讀取和修改網頁內容。"], "确认持久启用脚本？\n": ["Enable this script persistently?\n", "確認持久啟用腳本？\n"], "\n将按上述网址运行；下一次页面加载生效。": ["\nRuns on the URLs above, starting with the next page load.", "\n將按上述網址執行；下一次頁面載入生效。"], "在以下真实网页试运行？\n": ["Try the script on this live page?\n", "在以下真實網頁試執行？\n"], "\n脚本会修改网页，可能产生外部请求。试运行的 GM 存储为临时值。": ["\nThe script changes the page and may make external requests. Trial GM storage is temporary.", "\n腳本會修改網頁，可能產生外部請求。試執行的 GM 儲存為臨時值。"],
  "主题": [
    "Theme",
    "主題"
  ],
  "保存": [
    "Save",
    "保存"
  ],
  "保存设置": [
    "Save settings",
    "保存設定"
  ],
  "允许": [
    "Allow",
    "允許"
  ],
  "全部": [
    "All",
    "全部"
  ],
  "关闭": [
    "Close",
    "關閉"
  ],
  "删除": [
    "Delete",
    "刪除"
  ],
  "刷新": [
    "Reload",
    "刷新"
  ],
  "原文": [
    "Original",
    "原文"
  ],
  "取消": [
    "Cancel",
    "取消"
  ],
  "外观": [
    "Appearance",
    "外觀"
  ],
  "已取消": [
    "Cancelled",
    "已取消"
  ],
  "应用": [
    "App",
    "應用"
  ],
  "开启": [
    "On",
    "開啟"
  ],
  "当前网站": [
    "Current site",
    "當前網站"
  ],
  "搜索": [
    "Search",
    "搜索"
  ],
  "操作": [
    "Action",
    "操作"
  ],
  "新建": [
    "New tab",
    "新建"
  ],
  "普通": [
    "Regular",
    "普通"
  ],
  "暂停": [
    "Pause",
    "暫停"
  ],
  "更多": [
    "More",
    "更多"
  ],
  "更新过滤规则": [
    "Update filter rules",
    "更新過濾規則"
  ],
  "来源": [
    "Source",
    "來源"
  ],
  "查找下一个": [
    "Find next",
    "查找下一個"
  ],
  "标签": [
    "Tabs",
    "標籤"
  ],
  "模型服务": [
    "Model service",
    "模型服務"
  ],
  "正在处理": [
    "Processing",
    "正在處理"
  ],
  "浅色": [
    "Light",
    "淺色"
  ],
  "浏览": [
    "Browsing",
    "瀏覽"
  ],
  "深色": [
    "Dark",
    "深色"
  ],
  "目标": [
    "Goal",
    "目標"
  ],
  "确认": [
    "Confirmation",
    "確認"
  ],
  "确认发送": [
    "Confirm and send",
    "確認發送"
  ],
  "私密": [
    "Private",
    "私密"
  ],
  "移除": [
    "Remove",
    "移除"
  ],
  "简体中文": [
    "简体中文",
    "简体中文"
  ],
  "翻译": [
    "Translate",
    "翻譯"
  ],
  "范围": [
    "Scope",
    "範圍"
  ],
  "设置": [
    "Settings",
    "設定"
  ],
  "资料": [
    "Library",
    "資料"
  ],
  "跟随系统": [
    "System",
    "跟隨系統"
  ],
  "重试": [
    "Retry",
    "重試"
  ],
  "1 描述需求 → 2 检查草稿与权限 → 3 试运行 → 4 确认启用": [
    "1 Describe → 2 Review source and permissions → 3 Trial run → 4 Enable",
    "1 描述需求 → 2 檢查草稿與權限 → 3 試運行 → 4 確認啓用"
  ],
  "AI 编写与修复": [
    "Write or repair with AI",
    "AI 編寫與修復"
  ],
  "Markdown 文档将在这里显示。": [
    "Your Markdown document will appear here.",
    "Markdown 文檔將在這裡顯示。"
  ],
  "Markdown 自动预览网站": [
    "Sites with automatic Markdown preview",
    "Markdown 自動預覽網站"
  ],
  "Markdown 阅读": [
    "Markdown reader",
    "Markdown 閱讀"
  ],
  "Markdown 阅读内容": [
    "Markdown content",
    "Markdown 閱讀內容"
  ],
  "PDF 专用动作仅在内置 PDF 阅读器内生效。普通动作在 PDF 中含义不变。": [
    "PDF actions work only in the built-in PDF viewer. Other actions keep their usual behavior.",
    "PDF 專用動作僅在內置 PDF 閱讀器內生效。普通動作在 PDF 中含義不變。"
  ],
  "← 返回脚本列表": [
    "← Back to scripts",
    "← 返回腳本列表"
  ],
  "← 返回设置": [
    "← Back to settings",
    "← 返回設定"
  ],
  "← 阅读库": [
    "← Reading library",
    "← 閱讀庫"
  ],
  "← 隐私与安全": [
    "← Privacy and security",
    "← 隱私與安全"
  ],
  "上下左右可以组合；松开后查看匹配结果。": [
    "Combine directions, then release to see the matching action.",
    "上下左右可以組合；松開後查看匹配結果。"
  ],
  "中文": [
    "Chinese",
    "中文"
  ],
  "临时暂停由当前网站盾牌控制，保留钓鱼防护。": [
    "Pause protection from the current site's shield. Phishing protection stays active.",
    "臨時暫停由當前網站盾牌控制，保留釣魚防護。"
  ],
  "也应用于子域名": [
    "Also apply to subdomains",
    "也應用於子域名"
  ],
  "仅对已授权来源的 Markdown 原文响应自动预览。": [
    "Automatically preview Markdown responses only from approved origins.",
    "僅對已授權來源的 Markdown 原文響應自動預覽。"
  ],
  "仅对此次打开的文档生效。": [
    "Applies only while this document is open.",
    "僅對此次打開的文檔生效。"
  ],
  "例如：隐藏右侧栏并加宽正文": [
    "For example: hide the sidebar and widen the article",
    "例如：隱藏右側欄並加寬正文"
  ],
  "保存修改会撤销旧授权。试运行只使用临时存储；启用前再次确认网址和权限。": [
    "Saving changes revokes previous permissions. Trial runs use temporary storage; review sites and permissions before enabling.",
    "保存修改會撤銷舊授權。試運行只使用臨時存儲；啓用前再次確認網址和權限。"
  ],
  "保存到阅读库": [
    "Save to reading library",
    "保存到閱讀庫"
  ],
  "保存网站规则": [
    "Save site rule",
    "保存網站規則"
  ],
  "保存草稿": [
    "Save draft",
    "保存草稿"
  ],
  "停用": [
    "Disable",
    "停用"
  ],
  "停用全部脚本并恢复当前页": [
    "Disable all scripts and reload this page",
    "停用全部腳本並恢復當前頁"
  ],
  "停用此配置中的全部脚本，并重新载入目标页。未提交的输入可能丢失；已发出的请求无法撤销。": [
    "Disable all scripts in this profile and reload the target page. Unsent input may be lost; sent requests cannot be undone.",
    "停用此配置中的全部腳本，並重新載入目標頁。未提交的輸入可能丟失；已發出的請求無法撤銷。"
  ],
  "像素": [
    "pixels",
    "像素"
  ],
  "允许选取和复制": [
    "Allow selection and copying",
    "允許選取和複製"
  ],
  "先试一试": [
    "Try it first",
    "先試一試"
  ],
  "全局保护": [
    "Global protection",
    "全局保護"
  ],
  "关闭文档助手": [
    "Close document assistant",
    "關閉文檔助手"
  ],
  "减小字体": [
    "Decrease font size",
    "減小字型"
  ],
  "刷新列表": [
    "Refresh list",
    "刷新列表"
  ],
  "刷新状态": [
    "Refresh status",
    "刷新狀態"
  ],
  "加载 / 停用外部图片": [
    "Load / disable external images",
    "載入 / 停用外部圖片"
  ],
  "加载外部图片": [
    "Load external images",
    "載入外部圖片"
  ],
  "发送内容": [
    "Content to send",
    "發送內容"
  ],
  "发送内容与当前模型": [
    "Content and current model",
    "發送內容與當前模型"
  ],
  "发送并生成": [
    "Send and generate",
    "發送並生成"
  ],
  "发送需求、编辑器源码及已预览的结构。不会读取密码、Cookie 或表单值。": [
    "Send your request, editor source and reviewed page structure. Passwords, cookies and form values are excluded.",
    "發送需求、編輯器原始碼及已預覽的結構。不會讀取密碼、Cookie 或表單值。"
  ],
  "取消生成": [
    "Cancel generation",
    "取消生成"
  ],
  "只发送上方可编辑的内容，最多 32 KiB。": [
    "Only the editable content above is sent, up to 32 KiB.",
    "只發送上方可編輯的內容，最多 32 KiB。"
  ],
  "右键轻点仍打开菜单。按住 Shift 再右键可临时跳过手势。": [
    "A right click still opens the menu. Hold Shift to temporarily skip gestures.",
    "右鍵輕點仍打開菜單。按住 Shift 再右鍵可臨時跳過手勢。"
  ],
  "启用": [
    "Enable",
    "啓用"
  ],
  "启用鼠标手势": [
    "Enable mouse gestures",
    "啓用滑鼠手勢"
  ],
  "回退上一版": [
    "Revert to previous version",
    "回退上一版"
  ],
  "图片权限": [
    "Image permissions",
    "圖片權限"
  ],
  "在匹配的子框架运行": [
    "Run in matching subframes",
    "在匹配的子框架運行"
  ],
  "在浏览器中打开或导入文档": [
    "Open or import a document",
    "在瀏覽器中打開或導入文檔"
  ],
  "在线文本页面": [
    "Online text page",
    "在線文本頁面"
  ],
  "基本设置": [
    "Basic settings",
    "基本設定"
  ],
  "增大字体": [
    "Increase font size",
    "增大字型"
  ],
  "处理部分网页的调试干扰，保留普通断点和导航。": [
    "Handle some debugger interference while keeping normal breakpoints and navigation.",
    "處理部分網頁的調試干擾，保留普通斷點和導航。"
  ],
  "复制原文": [
    "Copy original text",
    "複製原文"
  ],
  "外部图片每次打开文档时询问；本地图片需选择所属目录。阅读外观不会授予图片访问权限。": [
    "External images require permission each time. Choose a folder for local images. Appearance settings do not grant image access.",
    "外部圖片每次打開文檔時詢問；本地圖片需選擇所屬目錄。閱讀外觀不會授予圖片訪問權限。"
  ],
  "字体": [
    "Font",
    "字型"
  ],
  "字号": [
    "Font size",
    "字號"
  ],
  "宽": [
    "Wide",
    "寬"
  ],
  "宽度": [
    "Width",
    "寬度"
  ],
  "宽松": [
    "Loose",
    "寬松"
  ],
  "导入 .user.js": [
    "Import .user.js",
    "導入 .user.js"
  ],
  "导出 PDF": [
    "Export PDF",
    "導出 PDF"
  ],
  "导出源码": [
    "Export source",
    "導出原始碼"
  ],
  "已保存": [
    "Saved",
    "已保存"
  ],
  "已停用 / 待授权": [
    "Disabled / needs permission",
    "已停用 / 待授權"
  ],
  "已启用": [
    "Enabled",
    "已啓用"
  ],
  "已启用 · 无执行回执": [
    "Enabled · no execution receipt",
    "已啓用 · 無執行回執"
  ],
  "已复制。": [
    "Copied.",
    "已複製。"
  ],
  "已安装脚本": [
    "Installed scripts",
    "已安裝腳本"
  ],
  "已执行": [
    "Completed",
    "已執行"
  ],
  "当前操作的网页": [
    "Target page",
    "當前操作的網頁"
  ],
  "恢复右键菜单": [
    "Restore context menu",
    "恢復右鍵菜單"
  ],
  "恢复操作": [
    "Recovery",
    "恢復操作"
  ],
  "恢复默认": [
    "Restore defaults",
    "恢復默認"
  ],
  "手势与动作": [
    "Gestures and actions",
    "手勢與動作"
  ],
  "手势练习区：按住右键画方向，松开查看结果": [
    "Gesture practice: hold the right mouse button, draw, then release",
    "手勢練習區：按住右鍵畫方向，松開查看結果"
  ],
  "打印": [
    "Print",
    "打印"
  ],
  "打印 / 导出 PDF": [
    "Print / export PDF",
    "打印 / 導出 PDF"
  ],
  "打开 Markdown 文件": [
    "Open Markdown file",
    "打開 Markdown 檔案"
  ],
  "打开 Markdown 文档": [
    "Open Markdown document",
    "打開 Markdown 文檔"
  ],
  "打开其他文件": [
    "Open another file",
    "打開其他檔案"
  ],
  "打开在线原文": [
    "Open online source",
    "打開在線原文"
  ],
  "打开所选原文": [
    "Open selected source",
    "打開所選原文"
  ],
  "打开文件": [
    "Open file",
    "打開檔案"
  ],
  "打开文档后查看来源": [
    "Open a document to see its source",
    "打開文檔後查看來源"
  ],
  "打开网页调试工具": [
    "Open developer tools",
    "打開網頁調試工具"
  ],
  "执行中": [
    "Running",
    "執行中"
  ],
  "执行失败": [
    "Failed",
    "執行失敗"
  ],
  "执行环境": [
    "Execution environment",
    "執行環境"
  ],
  "执行环境与子框架": [
    "Environment and subframes",
    "執行環境與子框架"
  ],
  "拖入文件，或打开正在浏览的在线原文。": [
    "Drop a file here or open an online source page.",
    "拖入檔案，或打開正在瀏覽的在線原文。"
  ],
  "按住右键，在这里画一笔": [
    "Hold the right mouse button and draw here",
    "按住右鍵，在這裡畫一筆"
  ],
  "按住鼠标右键画出方向，松开执行。支持网页、设置页和内置 PDF 阅读器。": [
    "Hold the right mouse button to draw, then release. Works on webpages, settings and the built-in PDF viewer.",
    "按住滑鼠右鍵畫出方向，松開執行。支持網頁、設定頁和內置 PDF 閱讀器。"
  ],
  "文档助手": [
    "Document assistant",
    "文檔助手"
  ],
  "文档助手任务": [
    "Assistant task",
    "文檔助手任務"
  ],
  "文档图片权限": [
    "Document image permissions",
    "文檔圖片權限"
  ],
  "文档操作": [
    "Document actions",
    "文檔操作"
  ],
  "文档来源": [
    "Document source",
    "文檔來源"
  ],
  "文档目录": [
    "Document outline",
    "文檔目錄"
  ],
  "新建 / AI 编写": [
    "New / write with AI",
    "新建 / AI 編寫"
  ],
  "显示轨迹与动作提示": [
    "Show trail and action hints",
    "顯示軌跡與動作提示"
  ],
  "暂停本站增强": [
    "Pause enhancements on this site",
    "暫停本站增強"
  ],
  "更多文档操作": [
    "More document actions",
    "更多文檔操作"
  ],
  "更多选项与适用范围": [
    "More options and scope",
    "更多選項與適用範圍"
  ],
  "本地导入 · 只读": [
    "Local import · read only",
    "本地導入 · 唯讀"
  ],
  "本站已停用": [
    "Disabled on this site",
    "本站已停用"
  ],
  "本页运行详情": [
    "Execution details",
    "本頁運行詳情"
  ],
  "查找": [
    "Find",
    "查找"
  ],
  "查找文档内容": [
    "Find in document",
    "查找文檔內容"
  ],
  "查看源码": [
    "View source",
    "查看原始碼"
  ],
  "标准": [
    "Standard",
    "標準"
  ],
  "检查权限与语法": [
    "Check permissions and syntax",
    "檢查權限與語法"
  ],
  "正在加载设置…": [
    "Loading settings…",
    "正在載入設定…"
  ],
  "正在生成草稿…": [
    "Generating draft…",
    "正在生成草稿…"
  ],
  "正在读取设置…": [
    "Loading settings…",
    "正在讀取設定…"
  ],
  "正文宽度": [
    "Text width",
    "正文寬度"
  ],
  "此网站自动预览 Markdown": [
    "Automatically preview Markdown on this site",
    "此網站自動預覽 Markdown"
  ],
  "此页面没有适用脚本。": [
    "No scripts apply to this page.",
    "此頁面沒有適用腳本。"
  ],
  "每行一个完整域名，例如 example.com。子域名请单独添加。": [
    "One full domain per line, such as example.com. Add subdomains separately.",
    "每行一個完整域名，例如 example.com。子域名請單獨添加。"
  ],
  "源码": [
    "Source",
    "原始碼"
  ],
  "生成或修复草稿": [
    "Generate or repair draft",
    "生成或修復草稿"
  ],
  "用中文总结": [
    "Summarize in Chinese",
    "用中文總結"
  ],
  "画到哪里、将执行什么，一眼看清。": [
    "See the trail and the action before it runs.",
    "畫到哪裡、將執行什麼，一眼看清。"
  ],
  "目录": [
    "Outline",
    "目錄"
  ],
  "目标网页": [
    "Target page",
    "目標網頁"
  ],
  "确认发送并生成": [
    "Confirm, send and generate",
    "確認發送並生成"
  ],
  "确认启用": [
    "Confirm and enable",
    "確認啓用"
  ],
  "窄": [
    "Narrow",
    "窄"
  ],
  "等待重新加载": [
    "Waiting for reload",
    "等待重新載入"
  ],
  "系统字体": [
    "System font",
    "系統字型"
  ],
  "紧凑": [
    "Compact",
    "緊湊"
  ],
  "练习不执行操作": [
    "Practice does not run actions",
    "練習不執行操作"
  ],
  "编辑所选网站规则": [
    "Edit selected site rule",
    "編輯所選網站規則"
  ],
  "网址：": [
    "Sites:",
    "網址："
  ],
  "网站例外与权限": [
    "Site exceptions and permissions",
    "網站例外與權限"
  ],
  "网站增强": [
    "Site enhancements",
    "網站增強"
  ],
  "网站增强与脚本": [
    "Site enhancements and scripts",
    "網站增強與腳本"
  ],
  "网站权限与数据": [
    "Site permissions and data",
    "網站權限與數據"
  ],
  "网站来源": [
    "Site origin",
    "網站來源"
  ],
  "网站规则 · 右键、选取和复制": [
    "Site rules · menus, selection and copying",
    "網站規則 · 右鍵、選取和複製"
  ],
  "网页调试兼容": [
    "Debugger compatibility",
    "網頁調試兼容"
  ],
  "翻译为简体中文": [
    "Translate to Simplified Chinese",
    "翻譯為簡體中文"
  ],
  "翻译为英语": [
    "Translate to English",
    "翻譯為英語"
  ],
  "脚本草稿": [
    "Script draft",
    "腳本草稿"
  ],
  "脚本超过 64 KiB。": [
    "Script exceeds 64 KiB.",
    "腳本超過 64 KiB。"
  ],
  "行距": [
    "Line spacing",
    "行距"
  ],
  "衬线字体": [
    "Serif",
    "襯線字型"
  ],
  "设置保存后不自动刷新。也可直接从地址栏盾牌调整当前网站。": [
    "Saving does not reload the page. You can also adjust this site from the address bar shield.",
    "設定保存後不自動刷新。也可直接從地址欄盾牌調整當前網站。"
  ],
  "识别距离": [
    "Recognition distance",
    "識別距離"
  ],
  "试运行": [
    "Trial run",
    "試運行"
  ],
  "读取当前页结构供检查": [
    "Load page structure for review",
    "讀取當前頁結構供檢查"
  ],
  "距离越大，越不容易被小幅抖动触发。斜线方向不明确时不执行；按 Esc 或切换窗口可取消。": [
    "Higher distances reduce accidental gestures. Ambiguous diagonals are ignored. Press Esc or switch windows to cancel.",
    "距離越大，越不容易被小幅抖動觸發。斜線方向不明確時不執行；按 Esc 或切換窗口可取消。"
  ],
  "输入 L / R / U / D，分别代表 ← → ↑ ↓。最多 8 个方向，同一手势不能重复绑定。": [
    "Enter L / R / U / D for ← → ↑ ↓, up to 8 directions. Each gesture can have one binding.",
    "輸入 L / R / U / D，分別代表 ← → ↑ ↓。最多 8 個方向，同一手勢不能重復綁定。"
  ],
  "返回阅读库": [
    "Back to reading library",
    "返回閱讀庫"
  ],
  "这些网站不使用手势": [
    "Disable gestures on these sites",
    "這些網站不使用手勢"
  ],
  "选择本地图片目录": [
    "Choose local image folder",
    "選擇本地圖片目錄"
  ],
  "重新加载当前页": [
    "Reload current page",
    "重新載入當前頁"
  ],
  "重新载入": [
    "Reload",
    "重新載入"
  ],
  "阅读": [
    "Reading",
    "閱讀"
  ],
  "阅读外观": [
    "Reading appearance",
    "閱讀外觀"
  ],
  "阅读工具": [
    "Reading tools",
    "閱讀工具"
  ],
  "阅读库": [
    "Reading library",
    "閱讀庫"
  ],
  "阅读选项": [
    "Reading options",
    "閱讀選項"
  ],
  "防护记录": [
    "Protection history",
    "防護記錄"
  ],
  "隔离环境": [
    "Isolated environment",
    "隔離環境"
  ],
  "需求或错误反馈": [
    "Request or error feedback",
    "需求或錯誤反饋"
  ],
  "页面环境（无 GM 权限）": [
    "Page environment (no GM permissions)",
    "頁面環境（無 GM 權限）"
  ],
  "默认阅读外观": [
    "Default reading appearance",
    "默認閱讀外觀"
  ],
  "鼠标手势": [
    "Mouse gestures",
    "滑鼠手勢"
  ],
  "（子框架）": [
    " (subframe)",
    "（子框架）"
  ],
  "＋ 添加手势": [
    "＋ Add gesture",
    "＋ 添加手勢"
  ],
  "阅读已保存原文": [
    "Read saved text",
    "閱讀已保存原文"
  ],
  "打开来源": [
    "Open source",
    "打開來源"
  ],
  "已保存的原文": [
    "Saved original text",
    "已保存的原文"
  ],
  "阅读库为空。在文档的更多操作中保存原文。": [
    "Your library is empty. Save original text from a document's More menu.",
    "閱讀庫為空。在文檔的更多操作中保存原文。"
  ],
  "尚未授权自动预览网站。可以从在线文档的来源菜单开启。": [
    "No sites approved for automatic preview. Enable it in an online document's Source menu.",
    "尚未授權自動預覽網站。可以從在線文檔的來源菜單開啓。"
  ],
  "阅读外观已保存，下次打开文档时应用。": [
    "Appearance saved. It applies the next time you open a document.",
    "閱讀外觀已保存，下次打開文檔時應用。"
  ],
  "网站预览设置已保存。": [
    "Site preview preference saved.",
    "網站預覽設定已保存。"
  ],
  "拦截跟踪请求": [
    "Block tracking requests",
    "攔截跟蹤請求"
  ],
  "钓鱼网站保护": [
    "Phishing protection",
    "釣魚網站保護"
  ],
  "指纹防护": [
    "Fingerprint protection",
    "指紋防護"
  ],
  "清理链接参数": [
    "Clean link parameters",
    "清理鏈接參數"
  ],
  "清理跟踪 Cookie": [
    "Clear tracking cookies",
    "清理跟蹤 Cookie"
  ],
  "识别别名跟踪": [
    "Detect CNAME tracking",
    "識別別名跟蹤"
  ],
  "跳转跟踪清理": [
    "Clear bounce tracking",
    "跳轉跟蹤清理"
  ],
  "挖矿风险观察": [
    "Observe mining risks",
    "挖礦風險觀察"
  ],
  "自动更新过滤规则": [
    "Update filter rules automatically",
    "自動更新過濾規則"
  ],
  "设置未保存，请重试。": [
    "Settings could not be saved. Try again.",
    "設定未保存，請重試。"
  ],
  "设置已保存。": [
    "Settings saved.",
    "設定已保存。"
  ],
  "暂无防护记录。": [
    "No protection events yet.",
    "暫無防護記錄。"
  ],
  "已保存的文档不可用。": [
    "The saved document is unavailable.",
    "已保存的文檔不可用。"
  ],
  "阅读外观已保存。": [
    "Reading appearance saved.",
    "閱讀外觀已保存。"
  ],
  "没有找到匹配内容。": [
    "No matches found.",
    "沒有找到匹配內容。"
  ],
  "停用外部图片": [
    "Disable external images",
    "停用外部圖片"
  ],
  "外部图片已获准加载，仅对此次打开的文档生效。": [
    "External images are allowed for this document session only.",
    "外部圖片已獲准載入，僅對此次打開的文檔生效。"
  ],
  " · 第 ": [
    " · version ",
    " · 第 "
  ],
  " 发送需求、编辑器源码和已预览结构？": [
    ": send the request, source and reviewed structure?",
    " 發送需求、編輯器源碼和已預覽結構？"
  ],
  " 版": [
    "",
    " 版"
  ],
  "Aegis 桌面 Chromium": [
    "Aegis desktop Chromium",
    "Aegis 桌面 Chromium"
  ],
  "仅支持普通 HTTP/HTTPS 网站。": [
    "Only regular HTTP/HTTPS sites are supported.",
    "僅支持普通 HTTP/HTTPS 網站。"
  ],
  "停用此配置中的全部用户脚本，并重新载入目标页？未提交输入可能丢失。": [
    "Disable all scripts in this profile and reload the target page? Unsent input may be lost.",
    "停用此配置中的全部用戶腳本，並重新載入目標頁？未提交輸入可能丟失。"
  ],
  "先选择已有脚本。": [
    "Select an existing script first.",
    "先選擇已有腳本。"
  ],
  "删除该脚本及其存储值？": [
    "Delete this script and its stored values?",
    "刪除該腳本及其存儲值？"
  ],
  "已保存为停用草稿，请检查后在列表启用。": [
    "Saved as a disabled draft. Review it, then enable it from the list.",
    "已保存為停用草稿，請檢查後在列表啓用。"
  ],
  "已刷新配置和运行状态。": [
    "Settings and execution status refreshed.",
    "已刷新配置和運行狀態。"
  ],
  "已取消生成。": [
    "Generation canceled.",
    "已取消生成。"
  ],
  "已启用。重新加载目标页后，请检查实际执行状态。": [
    "Enabled. Reload the target page and check its execution status.",
    "已啓用。重新加載目標頁後，請檢查實際執行狀態。"
  ],
  "已回退为草稿，请重新检查后启用。": [
    "Reverted to a draft. Review again before enabling.",
    "已回退為草稿，請重新檢查後啓用。"
  ],
  "已安排试运行：": [
    "Trial scheduled: ",
    "已安排試運行："
  ],
  "已导入编辑器，尚未保存或启用。": [
    "Imported into the editor. Not saved or enabled yet.",
    "已導入編輯器，尚未保存或啓用。"
  ],
  "已打开目标页调试工具。": [
    "Developer tools opened for the target page.",
    "已打開目標頁調試工具。"
  ],
  "已请求重新加载。请在目标页盾牌检查运行状态。": [
    "Reload requested. Check execution status in the target page's shield.",
    "已請求重新加載。請在目標頁盾牌檢查運行狀態。"
  ],
  "已调用脚本命令，请检查页面。": [
    "Script command called. Check the page.",
    "已調用腳本命令，請檢查頁面。"
  ],
  "当前模型：": [
    "Current model: ",
    "當前模型："
  ],
  "新脚本草稿": [
    "New script draft",
    "新腳本草稿"
  ],
  "普通网页 DOM": [
    "Regular webpage DOM",
    "普通網頁 DOM"
  ],
  "普通配置：网站规则、已启用脚本和值在重启后保留。": [
    "Regular profile: site rules, enabled scripts and stored values persist after restarting.",
    "普通配置：網站規則、已啓用腳本和值在重啓後保留。"
  ],
  "未配置": [
    "Not configured",
    "未配置"
  ],
  "确认向 ": [
    "Confirm sending to ",
    "確認向 "
  ],
  "私密会话：规则、脚本和值仅留在内存，不继承普通脚本。": [
    "Private session: rules, scripts and values stay in memory. Regular scripts are not inherited.",
    "私密會話：規則、腳本和值僅留在內存，不繼承普通腳本。"
  ],
  "编辑": [
    "Edit",
    "編輯"
  ],
  "网站规则已保存，重新载入网页后应用。": [
    "Site rule saved. Reload the webpage to apply.",
    "網站規則已保存，重新載入網頁後應用。"
  ],
  "脚本已停用，已请求重新载入。": [
    "Scripts disabled. Reload requested.",
    "腳本已停用，已請求重新載入。"
  ],
  "草稿已生成并通过语法检查。尚未保存、试运行或启用。": [
    "Draft generated and syntax checked. Not saved, tested or enabled yet.",
    "草稿已生成並通過語法檢查。尚未保存、試運行或啓用。"
  ],
  "草稿或停用": [
    "Draft or disabled",
    "草稿或停用"
  ],
  "设置已保存，下一次页面加载应用。": [
    "Settings saved. Applies on the next page load.",
    "設置已保存，下一次頁面加載應用。"
  ],
  "试运行 · ": [
    "Trial · ",
    "試運行 · "
  ],
  "语法和元数据检查通过；还需实际检查页面效果。": [
    "Syntax and metadata checks passed. Verify the actual page behavior next.",
    "語法和元數據檢查通過；還需實際檢查頁面效果。"
  ],
  "请先选择普通 HTTP/HTTPS 网页。": [
    "Select a regular HTTP/HTTPS webpage first.",
    "請先選擇普通 HTTP/HTTPS 網頁。"
  ],
  "请在另一个标签打开目标网页，然后刷新列表。": [
    "Open the target webpage in another tab, then refresh this list.",
    "請在另一個標籤打開目標網頁，然後刷新列表。"
  ],
  "请在防护中心配置": [
    "Configure in the protection center",
    "請在防護中心配置"
  ],
  "请描述需要增加的功能。": [
    "Describe the feature you want to add.",
    "請描述需要增加的功能。"
  ],
  "请检查上方结构；生成时才会发送。": [
    "Review the structure above. It is sent only when generating.",
    "請檢查上方結構；生成時才會發送。"
  ],
  "请检查网页效果，并刷新运行状态。": [
    "Check the page and refresh execution status.",
    "請檢查網頁效果，並刷新運行狀態。"
  ],
  "请选择目标网页。": [
    "Select a target webpage.",
    "請選擇目標網頁。"
  ],
  "返回列表将关闭未保存的编辑内容，继续？": [
    "Returning to the list will discard unsaved edits. Continue?",
    "返回列表將關閉未保存的編輯內容，繼續？"
  ],
  "还没有脚本。导入或新建后，先检查草稿和权限。": [
    "No scripts yet. Import or create one, then review the draft and permissions.",
    "還沒有腳本。導入或新建後，先檢查草稿和權限。"
  ],
  "适用网址：": [
    "Matching sites: ",
    "適用網址："
  ],
  "选择目标网页后设置网站规则，或新建用户脚本。": [
    "Select a target page to edit site rules, or create a userscript.",
    "選擇目標網頁後設置網站規則，或新建用戶腳本。"
  ],
  "重新加载当前目标页？未提交的输入可能丢失。": [
    "Reload the current target page? Unsent input may be lost.",
    "重新加載當前目標頁？未提交的輸入可能丟失。"
  ],
  "页面环境不能使用 GM 权限。": [
    "The page environment cannot use GM permissions.",
    "頁面環境不能使用 GM 權限。"
  ],
  "页面结构（不可信资料）：": [
    "Page structure (untrusted): ",
    "頁面結構（不可信資料）："
  ],
  "（暂停）": [
    " (paused)",
    "（暫停）"
  ],
  "；时机：": [
    "; timing: ",
    "；時機："
  ],
  "；权限：": [
    "; permissions: ",
    "；權限："
  ],
  " · 只读": [
    " · read only",
    " · 只讀"
  ],
  " 发送编辑后的文档内容？": [
    ": send the edited document content?",
    " 發送編輯後的文檔內容？"
  ],
  " 张图片。": [
    " images loaded.",
    " 張圖片。"
  ],
  "从本机导入，未上传原文件。": [
    "Imported locally. The original file has not been uploaded.",
    "從本機導入，未上傳原文件。"
  ],
  "保存完整原文到普通阅读库？文档会持久保留，包括从私密浏览打开的内容。": [
    "Save the full original text to the regular reading library? It will persist, including content opened in private browsing.",
    "保存完整原文到普通閱讀庫？文檔會持久保留，包括從私密瀏覽打開的內容。"
  ],
  "发送内容超过 32 KiB，请先缩小到需要处理的部分。": [
    "Content exceeds 32 KiB. Keep only the part you want to process.",
    "發送內容超過 32 KiB，請先縮小到需要處理的部分。"
  ],
  "只有本地导入文档可授权本地图片目录。": [
    "Local image folders are available only for locally imported documents.",
    "只有本地導入文檔可授權本地圖片目錄。"
  ],
  "向 ": [
    "To ",
    "向 "
  ],
  "图片合计超过 10 MiB，请选择更小的图片。": [
    "Images exceed 10 MiB in total. Select smaller images.",
    "圖片合計超過 10 MiB，請選擇更小的圖片。"
  ],
  "复制失败，请重试。": [
    "Copy failed. Try again.",
    "複製失敗，請重試。"
  ],
  "已取消。": [
    "Canceled.",
    "已取消。"
  ],
  "已在授权目录内加载 ": [
    "From the approved folder: ",
    "已在授權目錄內加載 "
  ],
  "文档已保存到加密阅读库，可从浏览器菜单的阅读库查看。": [
    "Document saved to the encrypted reading library, available from the browser menu.",
    "文檔已保存到加密閱讀庫，可從瀏覽器菜單的閱讀庫查看。"
  ],
  "文档已变化，请重新选择图片目录。": [
    "The document changed. Select the image folder again.",
    "文檔已變化，請重新選擇圖片目錄。"
  ],
  "文档超过 2 MiB，请使用原文件查看。": [
    "Document exceeds 2 MiB. View the original file instead.",
    "文檔超過 2 MiB，請使用原文件查看。"
  ],
  "未配置模型服务": [
    "No model service configured",
    "未配置模型服務"
  ],
  "本地文档 · 只读": [
    "Local document · read only",
    "本地文檔 · 只讀"
  ],
  "本地相对链接请通过“打开文件”选择目标文档：": [
    "For a local relative link, choose the target with Open file: ",
    "本地相對鏈接請通過“打開文件”選擇目標文檔："
  ],
  "正在处理…": [
    "Processing…",
    "正在處理…"
  ],
  "网站预览设置已保存，下次访问 Markdown 原文时应用。": [
    "Preview preference saved. It applies the next time you visit a Markdown source.",
    "網站預覽設置已保存，下次訪問 Markdown 原文時應用。"
  ],
  "请先打开在线 Markdown 原文页。": [
    "Open an online Markdown source page first.",
    "請先打開在線 Markdown 原文頁。"
  ],
  "请先打开文档。": [
    "Open a document first.",
    "請先打開文檔。"
  ],
  "请选择 .md 或 .markdown 文件。": [
    "Choose an .md or .markdown file.",
    "請選擇 .md 或 .markdown 文件。"
  ],
  "阅读库目前最多保存 32 KiB，请保留原文件。": [
    "The library currently saves up to 32 KiB. Keep the original file.",
    "閱讀庫目前最多保存 32 KiB，請保留原文件。"
  ],
  "页面没有可读取的文本。": [
    "No readable text found on this page.",
    "頁面沒有可讀取的文本。"
  ],
  "文档超过 2 MiB 或格式无效，请查看原始文件。": [
    "The document exceeds 2 MiB or is invalid. View the original file.",
    "文檔超過 2 MiB 或格式無效，請查看原始文件。"
  ],
  "第 {current} / {total} 处匹配": [
    "Match {current} of {total}",
    "第 {current} / {total} 處匹配"
  ],
  "{count} 张图片尚未加载。外部图片可按需加载，本地相对图片需要授权资源目录。": [
    "{count} images are blocked. Load external images as needed, or choose a folder for local images.",
    "{count} 張圖片尚未加載。外部圖片可按需加載，本地相對圖片需要授權資源目錄。"
  ]
};
  let locale = navigator.language || "zh-CN";
  const originals = new WeakMap();
  function setLocale(value) { if (typeof value === "string") locale = value; }
  function t(value, fields = {}) {
    const item = messages[value];
    let output = !item || /^zh(?![-_](?:TW|HK|MO|Hant))/i.test(locale) ? value : /^zh/i.test(locale) ? item[1] : item[0];
    for (const [key, replacement] of Object.entries(fields)) output = output.replaceAll("{" + key + "}", String(replacement));
    return output;
  }
  function translate(root = document) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const node of nodes) {
      if (node.parentElement?.closest("script,style,textarea,pre,code,#document,#source,#outline,#context-preview,#ai-output,#title,#document-title,#origin,#source-address,#source-info")) continue;
      const original = originals.get(node) || node.textContent;
      originals.set(node, original);
      const trimmed = original.trim();
      if (messages[trimmed]) node.textContent = original.replace(trimmed, t(trimmed));
    }
    for (const node of root.querySelectorAll("[aria-label],[placeholder],[title],[aria-description]")) {
      for (const attr of ["aria-label", "placeholder", "title", "aria-description"]) {
        const original = node.getAttribute("data-i18n-" + attr) || node.getAttribute(attr);
        if (!original) continue;
        node.setAttribute("data-i18n-" + attr, original);
        node.setAttribute(attr, t(original));
      }
    }
  }
  globalThis.AegisI18n = Object.freeze({t, translate, setLocale});
})();
