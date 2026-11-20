# 2026-11-18 上游候选与功能基线续作

原草稿 PR #174 的 Chromium 157 候选继续整合真实远端 `main`，冻结主线为 `e99b5ff830daed5542cf501daef28f4106a36b59`。保留已合入的截图、裁剪、本地及服务器 OCR、MCP/DevTools、移动菜单和设置，以及 iOS 独立 WebKit 交付改动。候选准备版本为 Ver 7.4 (340)，本轮未开始真实编译或打包。

## 源码与验证

- 桌面仍为 157.0.8103.79，Android 仍为 157.0.8103.78；514/346 项补丁从各平台既有已验证序列继续逐项回放，新增 19 项按真实前序树重新导出。752 个桌面覆盖文件与回放树一致；Android 保持其独立序列，不能用桌面覆盖文件一致性替代平台验收。
- Android 保留上游新增的图片菜单项，OCR 追加独立编号并同步全部映射；DevTools 保留导航提交后访问重验、对象生命周期和导航通知。
- 完整 `quality:fast` 已通过；新增实际页面逻辑的 7 项截图/OCR边界测试、MCP 定向回归、OCR 服务 4 项回归通过。过程中的补丁摘要和四端登记失败已修正并重跑，未降低检查。
- 功能合同新增截图/OCR、MCP 隔离，并同步四端目录；真实图像识别、保存分享、确认上传和 MCP 原生操作仍是本次候选的必需验收项。

## 新上游与发行边界

本轮官方渠道发现桌面 158.0.8127.37、Android 158.0.8127.42。158 正在同一候选流程内适配，不能把当前 157 源码当成已完成最新升级。158 的两套 V8 补丁各 3 项回放通过，但不等于安全回归运行通过。

GitHub CLI 的既有身份已具备仓库写权限，可读取 runner；连接器账号的权限与 CLI 分别核对。Mac 固定证书仍报告吊销，未发现正式 Developer ID 与有效公证收据。Windows 既有远程凭据本轮认证被拒绝，不据此断言机器健康或沿用旧验收状态。Android 尚无接通的原生 Linux x64 构建机和 ARM64 真机。

未创建正式 tag、三平台资产或 Release，未执行旧客户端更新安装验收。已利用漏洞的实际产物验证仍未解除；源码、脚本测试及补丁回放不替代真实平台收据。原工作区未提交现场和固定 Chromium 源码未被覆盖。

本轮本地证据：`.artifacts/chromium-upstream/heartbeat-20261118/`。

## 2026-11-20：PR #174 审查修复

以候选 `f2b391b37e73ef8f158cfddbc227cf3112566073` 为基线修复两项问题；本次未更新 Chromium pin、版本号或晋升基线。

- Android #0334 原文件是没有邮件头的裸 diff，`git apply --stat` 成功不能证明生产入口 `git am --3way` 可用。使用固定 Android Chromium 源码及前序补丁重建涉及的 17 个文件，从真实的定向提交导出邮件头；原 diff 的 SHA-256 保持 `4c228dedf59c7c0c03acba75ffbacc7cecb41588c298403364d644e8117a0832`，未改变 hunk 或 blob identity。邮件头的提交身份属于此次定向重建，不代表完整 Chromium 提交树。
- 新增桌面 #0515，将整页截图的 IDC 接入 Chromium 157 默认启用的 Action 映射和回调，并声明对应 GN 依赖。调用时读取当前活动标签页，由既有 `CaptureFullWebpage` 重新校验 URL 和禁止截图策略；保留旧命令分发路径。桌面序列现为 515 项，Android 仍为 346 项。
- `patch-series-format_test.sh` 默认覆盖桌面、Android 及两套 V8 序列，检查 format-patch commit header 和 Git 实际解析出的作者、邮箱、日期、主题及 diff。回归夹具使用真实 `git format-patch` / `git am`，并拒绝裸 diff、缺失字段和空作者。
- 新增 `ActionsAndLegacy/WebpageCaptureCommandBrowserTest.*`，在两种命令分发模式下验证菜单截图生成真实 PNG、菜单创建后禁止截图策略生效，以及内部页面不可截图；纳入 `//chrome/browser/aegis:browser_tests`。

两份修复补丁已在精确文件前序上通过 `git am --3way` 及 ordered exact lineage v2 检查；这是定向源码回放，不是完整 Chromium 回放或构建。四套补丁格式和邮件回归检查、仓库合同及 ShellCheck 通过。新增原生浏览器测试尚未编译、运行，完整 Chromium 157 GN/构建、平台设备、签名和发行验收继续保持未完成；不得以脚本结果替代这些门槛。
