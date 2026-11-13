# iOS I0 路由能力 — 2026-11-10

状态：**原合同范围门 FAIL。** 生产接线（I1–I3）继续 BLOCKED。本文只记录公开 WebKit API 的反例，不扩大授权。

## 原合同要求

- 按规范化精确 host 授权。
- 子域名不自动加入。
- 另一个顶层页面引用同一 host，不继承本站权限。

## 已观察的公开 API 限制

`WKWebsiteDataStore.proxyConfigurations` 作用于共享数据存储，不是单个标签或单次导航。`ProxyConfiguration.matchDomains` 是域名后缀匹配。

1. `matchDomains = ["target.invalid"]` 时，`child.target.invalid` 也会进入同一代理。
2. 同一数据存储上的另一个顶层 `WKWebView` 请求该 host 时也会进入代理。代理端看不到可信顶层页面。

对应测试：`apps/ios/Tests/AegisTests/AccessWebKitRoutingCapabilityTests.swift`。测试通过只表示反例被稳定重现，**不是**精确 host 合同通过。setter 返回、代理收到请求，都不等于目标路由版本 ACK，也不证明目标网页或 VLESS 可达。

## 未授权

扩大子域或跨顶层权限、按标签迁移存储、VPN/TUN、替换引擎。以上都没有获得授权。保持原合同时，需要另外的请求级架构；当前没有可行的公开 API 实现证据。
