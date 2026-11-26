# 网站加速与签名配置 TDD 计划

执行顺序采用 Superpowers TDD。各项先补可重现的测试，再实现并重跑同一用例。

1. 在 `AccessGeoSiteCacheTests` 复现旧版海外批准和撤回账本升级后离线恢复失败。修订 `AccessGeoSiteCache` 与 `AccessOverseasCacheSnapshot` 对历史凭证的恢复，保持实际下载水位和同版本摘要校验。
2. 用 XTLS 最新发布资产和两个 SHA-256 来源校验内置 DAT。用 `AccessGeoSiteAdmissionTests` 验证国内及海外投影、排除组、显式审批及离线恢复。同一文件版号用于国内和海外。用 `AccessGeoSiteCacheTests` 验证国内单域和海外排除项在过期、重启及更换内置版本后不会恢复。
3. 在 `AccessGeoSiteCacheTests` 和 `AccessGeoSiteUpdateTransportTests` 锁定 3 天默认、1／3／7 天选择与持久化、缩短周期、7 天提前、304 和失败退避。用现有前台触发验证到期后复查。用 `SettingsLayoutUITests` 验证设置入口、周期值和内置来源提示。
4. 用签名固定向量验证原始字节验签、回滚、同版本冲突、字段范围、失效及受限版本回退。用缓存用例验证暂停、无效刷新、重启和显式解禁。传输验证固定源、无 Cookie、响应大小与独立的更新周期。
5. 用 `AccessHostRecoveryWebKitTests` 检查暂停前后仅海外授权、独立隐藏位置授权以及站点手选直连。覆盖国内手动下海外更新及配置解禁。
6. 运行相关 iOS 模拟器用例和编译器测试，记录发布 tag、SHA-256、测试输出及需部署的构建输入。
7. 从仅存旧设置的场景启动协调器，验证新增域名维持原连接。用缓存和调度用例验证首次请求海外规则时的 ETag 准入及剩余有效期低于一分钟的重查时间。
8. 给发包检查传入有草稿标志或缺少下载地址的元数据，验证错误输入被拒绝。读取已打包的 App 资源，使用实际 Swift 准入逻辑验证官方版本及海外规则，并检查缺失 DAT 时发包失败。

设计见 [网站加速规则与远程配置](../specs/2026-11-25-geosite-remote-policy-design.md)。
