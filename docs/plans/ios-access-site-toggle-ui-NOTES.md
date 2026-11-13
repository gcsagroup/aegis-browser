# P-iOS-3 — per-site proxy toggle UI

## Scope

Current-page 「本站代理」 entry in the iOS Current Site sheet. Thin UI in
`AegisApp`; AccessKit keeps intent + session logic.

| Piece | Role |
| --- | --- |
| `AccessSiteProxyToggleModel` | Trusted host resolve + snapshot; switch ≠ connection |
| `AccessSiteProxyToggleView` | Host, toggle, intent line, connection line |
| `AccessSiteProxySessionStore` | Window-scoped controller + fail-closed orchestrator |
| `AccessSiteProxyToggleModelTests` | Trusted host, toggle ≠ ready, off copy, fail-closed |

## Mapping

| UI | Source |
| --- | --- |
| Domain | Current tab http(s) URL → `AccessSiteHost.normalize` |
| Switch on/off | `AccessSiteSessionController.enable` / `disable` |
| Intent status | Product copy; allow + not-ready ⇒ “开启 · 连接尚未就绪” |
| Connection status | Independent line: idle / connecting / ready / unavailable |
| Off copy | “未使用本服务代理 / 使用浏览器原有连接” |

## Non-goals

- DEV ALLOW/BLOCK panel (P-iOS-4)
- Fault-injection product drill (P-iOS-5)
- Full String Catalog localization pass (en/zh-Hans source keys first)
- Claiming five-step evidence PASS (P-iOS-6)

## PBX IDs

`00CA`–`00CD` (App side; `00CE` reserved unused)
