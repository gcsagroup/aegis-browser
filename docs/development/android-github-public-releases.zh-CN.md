# Aegis Android GitHub 公开发布

这套流程从已经上传过的 Android Release 包发布 GitHub tag 与 Release，不会重新打 App Bundle。入口是带管理员门禁的 `Android Delivery · Bot` 控制器。

## 上游晋升后，再在上游实测

Android 交付与公开发布实现经 fork 分支 PR 进入 `gcsagroup/aegis-browser` 的 `main`。PR 上保持无凭据合同与 Android 矩阵绿：`scripts/release/test_android*.py`、`scripts/ci/tests/android-*.test.mjs`。Play 上传、candidate Draft、公开 GitHub Release 仍只允许上游 `gcsagroup/aegis-browser` / `1348409663` 的当前 `main`。合并并配齐下方门禁之前，不要打开 `AEGIS_ANDROID_RELEASE_ENABLED` 或 `AEGIS_ANDROID_GITHUB_RELEASE_ENABLED`；真实打包、签名与分渠道上传在合并后的上游上执行。

## 操作

在 **Actions → Android Delivery · Bot** 中选择：

- 产品选 **Release**，操作 **Preview GitHub release**：只读预览即将发布的 prerelease。
- 产品选 **Release**，操作 **Publish prerelease**：创建公开 tag 与 GitHub prerelease。不会成为 Latest，也不进入 production Environment。
- 产品选 **Release**，操作 **Promote to stable**：审核后把同一条 Release 标为正式版。发起控制器的 Admin 可以批准这份精确的晋升计划。Alpha / Beta 包不会公开发布。

每次操作都会先跑 **Release Wait**（只读查询 Play `generatedApks`）。只有近期 `VALID`、且密封的 Release 包、Play draft 记录与状态证据都对齐当前 `main` 的 versionCode 才能发布。没有「仅预览」坐标。生产者必须是当前 `main`。

公开 tag 形如 `android/<version>-release.<versionCode>`，例如 `android/7.2.0.339-release.2007000339`。首次发布设 `prerelease=true`、`make_latest=false`。提升 stable 保留同一 tag，并把同一条 GitHub Release 改为 `prerelease=false`、`make_latest=true`。审批用的 plan digest 绑定源码 commit/tree、package 与 status 运行、两份 Actions artifact ID 与 ZIP 的 SHA-256、Play 构建身份，以及公开资产哈希。即便公开内容相同，替换过的 artifact 也要重新预览并重新审批。release identity digest 绑定不可变的包/源码与公开资产哈希，且不含 prerelease 标志，因此晋升不会改动 tag 注解。

公开文件只有已签名的 AAB、原生符号 zip、白名单内的公开 `android-manifest.json` 及其 SHA-256。公开清单不含上传证书和签名文件；那些留在密封包里。`apps/browser/args/aegis-android.gn` 里 `symbol_level` 为 `0`，因此在 `out/AegisAndroid/lib.unstripped` 没有真实 `.so` 时 Release 打包会失败关闭。剥离符号的库不能当符号发布。

简单模式对 Release 的 **打包并上传** 只把 AAB 传到 Play `internal` 轨道，状态为 `draft`，不会 rollout production。Alpha 只走 `internal`。Beta 可用 `internal` 或 `beta`。production 的 `completed` 只允许完整模式里显式的 **submit**，且必须在 Play 已报告 `VALID` 之后。

## 仓库配置要求

除非 `AEGIS_ANDROID_RELEASE_ENABLED`，以及公开发布所需的 `AEGIS_ANDROID_GITHUB_RELEASE_ENABLED`，取值恰好为 `true`，否则工作流保持关闭。在 `gcsagroup/aegis-browser` 配好下列门禁之前不要打开。这次源码改动本身不创建 ruleset、Environment、变量、tag 或 Release，也不发布任何包。

1. 按 [`.github/android-public-release-tag-ruleset.json`](../../.github/android-public-release-tag-ruleset.json) 创建生效中的 tag ruleset。旁路只保留 Admin。保护 tag 的 update 与 deletion。创建创建保持开放，以便 job 作用域的 Actions token 能新建 tag。include 为 `refs/tags/android/*`，不覆盖 `candidate/android/*`。
2. 创建 Environment `aegis-android-github-production`。要求一名或多名命名的 User 审核人；关闭 **Prevent self-review**，以便发起的 Admin 可以批准；关闭 **Allow administrators to bypass configured protection rules**；部署限制在受保护分支。prerelease 发布不进入该 Environment。
3. 将 `AEGIS_ANDROID_GITHUB_RELEASE_ADMIN_IDS` 设为晋升审核人的逗号分隔数字 ID。当前 Environment 审核人与批准人都必须仍是仓库 Admin，且在该列表中。发起的 Admin 可以是批准人。
4. 设置 `AEGIS_ANDROID_DELIVERY_BOT` 为固定 App `{actorId, appId, slug}`，以及 `AEGIS_ANDROID_BOT_INSTALLATION_ID` 和密钥 `AEGIS_ANDROID_BOT_PRIVATE_KEY`。安装令牌仅限 Actions write 与 contents read。为控制器创建 Environment `aegis-android-bot`。不要把 GitHub App 权限扩到 dispatch 以外。
5. 保留既有 Play 相关 Environment：打包用 `aegis-release-android`，draft 上传与状态用 `aegis-play`，以及 `aegis-android-distribute`、`aegis-android-submit`，candidate-tag draft 用 `aegis-android-draft`。在 `AEGIS_ANDROID_RELEASE_RUNNERS_READY` 恰好为 `true` 之前，runner 保持关闭。

晋升审批作业使用受保护 Environment，且没有仓库写 token。只有该作业成功后，发布者才进入队列 `android-public-release-<repository>`。prerelease 发布跳过审批作业，直接进入同一队列。Environment 审批评论必须恰好是晋升预览摘要里的 `publish <plan SHA-256>`。批准后会重算 plan，摘要必须一致。

## 安全与恢复

发布工作流只接受规范 `main` 上、attempt 为 1 的 App 派发。预览不进发布队列。控制器把子 run ID 与精确输入记入 `android-github-release-dispatch-<run>-1`，子流程先核对这份回执再继续。prerelease 作业在创建带注解的 tag 与公开 prerelease 之前，会核验 package artifact、manifest、Play draft 的 intent/result、新鲜的 Release Wait，以及 tag ruleset。晋升核验同样字节与部署批准，然后清除 prerelease 并设为 Latest。不会创建第二个 tag。

资产先上传到 draft。发布者在公开 Release 前会重新读取每一份资产摘要。仅当注解、identity digest、元数据与 SHA-256 都匹配时，才复用已有 tag 或 Release。若 GitHub 或 Play 的变更响应含糊，保留 run URL，先通过读回对账，再发起下一次变更。

`versionCode` 必须在 1 到 2100000000 之间，且 `versionCode % 10000` 等于产品版本第四段。仓库中的示例是 `7.2.0.339` / `2007000339`。不要用主版本号重算 versionCode。

英文说明见 [android-github-public-releases.md](android-github-public-releases.md)。
