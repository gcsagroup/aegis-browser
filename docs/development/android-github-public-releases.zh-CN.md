# Aegis Android GitHub 公开发布

这套流程对标 iOS：管理员从 `Android Delivery · Bot` 发起，先做只读的 Play Release Wait，再预览、发布 prerelease，或在审核后把同一条 Release 提升为 stable。公开 tag 是 `android/<version>-release.<versionCode>`。提升 stable 不重新打 tag。

## 先 fork，再上游晋升与同步

实现先落在个人 fork `quinn521/aegis-browser`（id `1363949860`，parent 为 `gcsagroup/aegis-browser`）。在 fork 分支上把无凭据合同与完整测试矩阵跑绿：`scripts/release/test_android*.py` 与 `scripts/ci/tests/android-*.test.mjs`。Play 上传、candidate Draft、公开 GitHub Release 仍只允许上游 `gcsagroup/aegis-browser` / `1348409663` 的当前 `main`。fork 矩阵绿、上游晋升/同步 PR 合并之前，不要在上游打开 `AEGIS_ANDROID_RELEASE_ENABLED` 或 `AEGIS_ANDROID_GITHUB_RELEASE_ENABLED`。fork 上的通过证明不能直接当作合并后另一个 main SHA 的准入。

公开文件只有已签名的 AAB、原生符号 zip、公开 `android-manifest.json` 及其 SHA-256。证书和签名证据留在密封包里。当前 `symbol_level` 为 0，Release 打包在 `lib.unstripped` 里没有真实 `.so` 时会失败，不会把剥离符号的库当成符号发布。

简单模式的 Release「打包并上传」只把 AAB 传到 Play `internal` 轨道，状态是 `draft`，不会发布到 production。Alpha / Beta 也不会进入这条 GitHub 公开发布。

在 `gcsagroup/aegis-browser` 配好 tag ruleset、`aegis-android-github-production`、`aegis-android-bot`、管理员 ID 和 Bot 变量之前，`AEGIS_ANDROID_RELEASE_ENABLED` 与 `AEGIS_ANDROID_GITHUB_RELEASE_ENABLED` 保持关闭。这次源码改动本身不创建 ruleset、Environment、变量、tag 或 Release，也不发布任何包。

英文操作说明见 [android-github-public-releases.md](android-github-public-releases.md)。
