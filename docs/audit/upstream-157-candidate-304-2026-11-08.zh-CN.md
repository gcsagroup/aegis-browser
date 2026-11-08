# Chromium 157 固定路径候选 304

本次为后续 Mac 原生编译递增产品版本至 Ver 6.1 (304)，保留当前 Chromium
157 桌面及 Android pin。源码检查通过不代表安装包已构建、签名或发布。

- 桌面 359 个补丁完整重放通过，树为 `a2f20c5f805a44305bf1768423cdc575efc01edd`。
- Android 329 个补丁完整重放通过，树为 `8de7c0726a72018780e028602f97591e1cf8f846`。
- V8 未改动，沿用同一 pin 和三个补丁的已验证重放收据。
- 第三方声明的 Chromium 版本、提交及 Vitest 版本已跟随当前候选更新；
  解决声明仍停留在旧版本而导致质量入口提前失败的问题，检查规则未放宽。
- 按锁文件安装依赖后，`quality:fast` 和 `ci:test` 均通过；后者 183 项，零跳过。
- Windows 实机执行发行流程脚本测试 68 项，零跳过；四份日志已下载并核对
  SHA-256。这仅证明脚本在 Windows 上可运行，不代表 Chromium 157 编译或界面验收。

用户已允许正常退出固定路径 App，并在保留可恢复开发现场后使用原构建目录。
115 份开发文件已保存在保护提交 `f716afb3c425b2dc8717e347550678c2d3f37d8e`，
原始备份和二进制差异同时保留。源码切换使用普通 Git 操作，空间低于 40 GiB
停止，不清理缓存、用户资料或历史产物。固定 App、输出和构建目录不另建副本。

原生编译、三平台实际产物验收、正式签名及公证、GitHub Release 写权限、
旧客户端下载安装回读仍须逐项取得实际收据。当前提交不解除这些发布门槛，
不创建正式 tag 或 Release。

本轮本地证据目录：
`/Users/lazy/Projects/GCSA-aegis/.artifacts/chromium-upstream/continue-20261108/`。
其中 `desktop-304/result.json`、`android-304/result.json`、
`windows-attempt-02/result.json`、`ci-tests-fixed-metadata.log`、
`quality-fast-304.log` 分别保留本轮验证结果；源码切换及后续构建状态另行记录。
