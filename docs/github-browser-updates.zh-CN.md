# 从 GitHub 检查和下载浏览器更新

本功能更新 GCSA-aegis 浏览器本身，与开发环境的 Chromium 上游检测无关。

## 用户流程

打开“设置 → 关于 GCSA Aegis”后，浏览器检查 `gcsagroup/aegis-browser` 的最新正式 Release。发现更高的产品版本时，自动下载当前系统、芯片对应的安装包，显示下载进度，并校验文件大小和 SHA-256。成功后显示“查看安装包”，可打开所在文件夹，退出浏览器后进行安装。

请保持关于页打开。关闭页面会取消尚未完成的网络下载；网络下载已经完成时，校验、系统来源标记与文件保存会独立完成。本轮不包含启动时定时轮询、静默安装、自动替换正在运行的 App 或自动重启。下载完成只表示安装包可供使用，不表示浏览器已升级。

GitHub 没有正式 Release 时显示“暂无可用的正式版更新。”；网络错误、请求限流、缺少对应平台安装包、校验失败分别显示原因，可重新检查。预发布、草稿、同版本及更旧版本不会触发下载。

## 发布约定

固定检测接口为 [GitHub 最新 Release API](https://api.github.com/repos/gcsagroup/aegis-browser/releases/latest)，发布说明在[产品 Releases](https://github.com/gcsagroup/aegis-browser/releases)。公开客户端不携带 GitHub Token、Cookie 或浏览历史。

产品版本使用四段数字，例如 `1.1.0.4`，对应 tag `v1.1.0.4`。第三段为修订号，第四段为递增构建号；界面显示 `Ver 1.1 (004)`。产品版本不能用 Chromium 的内核版本代替。

上传的资产必须严格匹配：

| 平台 | 安装包示例 |
| --- | --- |
| macOS Apple Silicon | `GCSA-aegis-1.1.0.4-mac-arm64.dmg` |
| macOS Intel | `GCSA-aegis-1.1.0.4-mac-x64.dmg` |
| Windows x64 | `GCSA-aegis-1.1.0.4-win-x64.exe` |
| Windows ARM64 | `GCSA-aegis-1.1.0.4-win-arm64.exe` |
| Linux x64 | `GCSA-aegis-1.1.0.4-linux-x64.tar.xz` |
| Linux ARM64 | `GCSA-aegis-1.1.0.4-linux-arm64.tar.xz` |

客户端要求资产状态为 `uploaded`，大小为正整数且不超过 2 GiB，GitHub API 的 `digest` 为 `sha256:` 加 64 位十六进制值。资产必须属于同仓库同 tag，禁止选择源码归档、重复同名资产或缺少校验值的文件。发布方应先上传全部安装包，再发布 Release，避免客户端看到不完整的发行版本。GitHub API 格式见[官方文档](https://docs.github.com/en/rest/releases/releases)。

macOS `package.sh` 默认从 `1.1.0.3` 开始使用上述资产命名。构建和打包之前需同步递增更新模块中的产品版本、关于页显示、App 模板的 `AegisProductVersion` / `AegisProductVersionLabel` 和打包默认版本；修改后的 Chromium 文件须重新导出有序补丁。打包脚本会检查安装包版本与 App 的产品版本相同，不能仅通过修改文件名或环境变量伪装成新版本。App 的 Chromium 标准版本字段仍服务于内核及框架定位，不能改成产品版本破坏其兼容性。

SHA-256 证明下载文件与 GitHub 发布元数据一致，不代替发行签名、公证或安装验收。安装包保留系统互联网来源检查。本轮不会自动创建 tag、上传安装包或发布 Release。

## 验证

原生测试目标：

```bash
# 在配置的 Chromium src 内执行，使用当前工作区匹配的构建工具。
autoninja -C out/AegisRelease aegis_github_update_unittests
out/AegisRelease/aegis_github_update_unittests
```

测试使用本地 HTTP 响应夹具和真实临时文件，覆盖版本顺序、降级拒绝、预发布、资产与重定向限制、损坏包删除、下载成功、404、限流重试和请求去重。关于页增加了进度、下载完成不显示重启升级、重试按钮和下载定位入口测试。

2026-09-13 实际 GitHub 查询返回没有 Release；因此本轮线上验收只能覆盖“尚未发布”分支。正式安装包发布后的真实下载、签名、公证、安装后版本回读仍需单独验收。

## 018 界面整改后的状态

关于页与安全检查共用产品更新结果，显示 Ver 1.1 (018)，与 Chromium 内核版本分开。未检查、无正式版、当前正式版、本地版本较新和安装包就绪分别表述；下载与校验成功仍需手动安装。2026-09-13 的真实通道验收为无正式版，18 项原生测试通过；完整记录见[018 验收](ui-copy-acceptance.zh-CN.md)。

此处记录本地验收结果。App 模板与打包脚本中的版本仍需在下一次正式打包前同步核对；此次源码提交不代表已生成可发行的 018 安装包。
