# Aegis Android GitHub 公开发布

这套流程对标 iOS：管理员从 `Android Delivery · Bot` 发起，先做只读的 Play Release Wait，再预览、发布 prerelease，或在审核后把同一条 Release 提升为 stable。公开 tag 是 `android/<version>-release.<versionCode>`。提升 stable 不重新打 tag。

## 上游晋升后，再在上游实测

Android 交付与公开发布实现经 fork 分支 PR 进入 `gcsagroup/aegis-browser` 的 `main`。PR 上保持无凭据合同与 Android 矩阵绿：`scripts/release/test_android*.py`、`scripts/ci/tests/android-*.test.mjs`。Play 上传、candidate Draft、公开 GitHub Release 仍只允许上游 `gcsagroup/aegis-browser` / `1348409663` 的当前 `main`。合并并配齐下方门禁之前，不要打开 `AEGIS_ANDROID_RELEASE_ENABLED` 或 `AEGIS_ANDROID_GITHUB_RELEASE_ENABLED`；真实打包、签名与分渠道上传在合并后的上游上执行。

公开文件只有已签名的 AAB、原生符号 zip、公开 `android-manifest.json` 及其 SHA-256。证书和签名证据留在密封包里。当前 `symbol_level` 为 0，Release 打包在 `lib.unstripped` 里没有真实 `.so` 时会失败，不会把剥离符号的库当成符号发布。

简单模式的 Release「打包并上传」只把 AAB 传到 Play `internal` 轨道，状态是 `draft`，不会发布到 production。Alpha / Beta 也不会进入这条 GitHub 公开发布。

在 `gcsagroup/aegis-browser` 配好 tag ruleset、`aegis-android-github-production`、`aegis-android-bot`、管理员 ID 和 Bot 变量之前，`AEGIS_ANDROID_RELEASE_ENABLED` 与 `AEGIS_ANDROID_GITHUB_RELEASE_ENABLED` 保持关闭。这次源码改动本身不创建 ruleset、Environment、变量、tag 或 Release，也不发布任何包。

英文操作说明见 [android-github-public-releases.md](android-github-public-releases.md)。
