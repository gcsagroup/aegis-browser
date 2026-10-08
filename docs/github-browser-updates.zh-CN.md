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

SHA-256 证明下载文件与 GitHub 发布元数据一致，不代替发行签名、公证或安装验收。安装包保留系统互联网来源检查。历史实现未包含自动创建 tag、上传安装包或发布 Release；2026-10-05 的自动发布授权已覆盖该范围，但授权不等于已完成实现或发行验收。

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

## 2026-10-05 发行资产一致性检查

`apps/browser/scripts/release-assets.py` 已接入脚本质量检查。它验证 Mac ARM64、Windows x64、Android ARM64 三个平台的真实文件、产品版本递增、名称、大小和 SHA-256，并可核对 GitHub 草稿或公开 Release 的回读 JSON。Android 保留现有打包名称，不套用桌面资产选择器。

构建清单格式如下；示例值必须由实际产物生成，不能用示例作为验收凭据：

```json
{
  "schemaVersion": 1,
  "repository": "gcsagroup/aegis-browser",
  "productVersion": "2.0.0.106",
  "previousProductVersion": "2.0.0.105",
  "productCommit": "完整的40位产品提交",
  "assets": [
    {
      "platform": "mac-arm64",
      "name": "GCSA-aegis-2.0.0.106-mac-arm64.dmg",
      "size": 123,
      "sha256": "实际文件SHA-256"
    },
    {
      "platform": "win-x64",
      "name": "GCSA-aegis-2.0.0.106-win-x64.exe",
      "size": 123,
      "sha256": "实际文件SHA-256"
    },
    {
      "platform": "android-arm64",
      "chromiumVersion": "154.0.8037.126",
      "name": "GCSA-aegis-2.0.0.106-chromium-154.0.8037.126-android-arm64.apk",
      "size": 123,
      "sha256": "实际文件SHA-256"
    }
  ]
}
```

```bash
python3 apps/browser/scripts/release-assets.py --manifest /绝对路径/manifest.json --asset-dir /绝对路径/dist
# 从 GitHub API 保存同一草稿的完整 JSON 后核对：
python3 apps/browser/scripts/release-assets.py --manifest /绝对路径/manifest.json --asset-dir /绝对路径/dist --release-json /绝对路径/draft.json
# 正式发布后的只读核对增加 --published。
```

退出码 0 只证明所检查的文件和 API 元数据一致；输出始终标记 `releaseReady: false`。本工具没有签名、公证、构建来源证明、远端 tag 提交核对、发布操作或旧客户端安装能力，不能单独打开正式发布门槛。必须另外完成三平台正式签名、实机回归、受保护分支合入、tag 来源核对和公开更新链路验收。测试夹具不算真实发行证据。

## 分阶段 GitHub 发行编排

`apps/browser/scripts/release-github.py` 使用既有 `gh` 认证，提供 `preflight`（默认只读）、`prepare`（同一草稿及缺失资产上传）、`publish`（再次核验后公开）三个阶段。它要求远端产品tag已经存在、指向被测产品提交，且提交已进入默认分支；不代替分支保护、合并审核、tag创建、签名、公证或安装验收。

每次执行都读取前三平台资产清单，并要求额外的验收凭据：

```json
{
  "schemaVersion": 1,
  "productCommit": "与资产清单相同的完整提交",
  "productVersion": "2.0.0.106",
  "platforms": {
    "mac-arm64": {
      "artifactSha256": "实际DMG摘要",
      "checks": {
        "build": {
          "status": "passed",
          "file": "mac/build.log",
          "sha256": "该日志的实际摘要"
        }
      }
    }
  }
}
```

以上只展示字段格式，**缺少其余平台和检查，不能执行**。三平台均须包含 `build`、`native_tests`、`security_regressions`、`permissions`、`profile_compatibility`、`device_acceptance`、`signature`、`update_failure_paths`；Mac增加`notarization`，Android增加`package_identity`、`signer_continuity`、`version_code_increase`、`install_confirmation`。所有检查均使用相同的`status/file/sha256`格式，指向凭据目录内真实非空日志并绑定本次安装包摘要。凭据必须来自实际平台验收程序，不能人工填写通过；当前尚未接齐所有平台的凭据生成程序。该工具核对文件一致性，不认证日志内容的真伪。

```bash
python3 apps/browser/scripts/release-github.py \
  --manifest /发行目录/manifest.json --asset-dir /发行目录/assets \
  --qualification /发行目录/qualification.json --notes /发行目录/release-notes.md \
  --stage preflight --output /发行目录/preflight-本次运行.json
# 前提通过后依次执行 prepare、publish；每次使用新的 --output 路径。
```

输出文件必须不存在；脚本先独占该文件，再进行远端操作。资产目录的`.aegis-release.lock`防止本机重复启动。遇到遗留锁需先确认原进程已经退出，不自动删除其他进程的锁。上传中断后再次`prepare`会回读同一草稿，只上传缺失的资产；已有资产、说明或tag不一致时停止，绝不使用`--clobber`或覆盖旧包。API错误不当成没有Release。存在更高的正式四段产品版本时拒绝倒退latest。

`publish`再次检查本地包、凭据、远端tag和默认分支、同一草稿、三平台远端摘要与发布说明，随后公开并回读该Release及latest API。已有正式版本只核验复用，不重复上传或修改。输出仍标记`releaseReady: false`、`oldClientUpdateAcceptance: pending`：这仅表明发布阶段结果，必须另外通过GitHub页面、旧客户端真实下载、签名和隔离安装回读才能完成整条链路。网络在公开后断开时可能已经发布，下一轮先回读，不能新建另一发行版本。

2026-10-05：17项本地编排测试及14项资产检查通过，含临时文件CLI代表性输入、上传中断、缺包、损坏资产、权限/tag/默认分支错误、验收缺项、更高版本、旧证据输出和并发锁。远端调用使用测试替身，没有生成线上Release或真实签名验收凭据。

接口依据：[GitHub Release创建](https://cli.github.com/manual/gh_release_create)、[资产上传](https://cli.github.com/manual/gh_release_upload)、[Release修改](https://cli.github.com/manual/gh_release_edit)、[REST回读](https://docs.github.com/en/rest/releases/releases)。
