# P-mac-2 — macOS toolbar bubble for per-site proxy

## Scope

Toolbar bubble surfaces current navigation host, a site-proxy switch, and
short status with **switch state ≠ connectivity**.

| Piece | Role |
| --- | --- |
| `AccessSiteConnectionState` | idle / connecting / ready / unavailable |
| `AccessSiteProxyBubbleSnapshot` | host + intent + connection + toggle flags |
| `ResolveTrustedNavigationHost` | last-committed http(s) only |
| `BuildSiteProxyBubbleSnapshot` | intent from store; connection is separate input |
| `ApplySiteProxyToggle` | allow/off intent only — no publish/ACK |
| `AccessSiteProxyBubbleController` | Profile-owned store + connection holder |
| Toolbar `AegisPageBubble` | Renders host / toggle / intent line / connection line |
| Patch `0351` | Keeps Chromium series synced with overlay |

## Mapping

| UI | Source |
| --- | --- |
| Domain | Trusted committed URL → exact host |
| Switch on/off | `AccessSiteIntent::kAllow` / `kOff` |
| Intent status | Product copy; allow+idle ⇒ “on · connection not ready” |
| Connection status | Independent line; default idle until P-mac-3 |

## Non-goals

- Publish / ACK / ready orchestration (P-mac-3)
- DEV ALLOW/BLOCK panel (P-mac-4)
- Fault fail-closed product path (P-mac-5)
- Five-step evidence PASS claim (P-mac-6)
