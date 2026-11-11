# P-mac-5 — macOS site-proxy fault fail-closed (no DIRECT)

## Scope

After a node/runtime fault on an enabled site-proxy session, new requests
must **Fail** or **Wait**. The product path never silently falls back to
DIRECT (or another proxy). Recovery and Network Service restart rebuild
the PROXY publication. Acceptance: B2-3 / B2-4.

| Piece | Role |
| --- | --- |
| `AccessSiteProxyFaultMode` | `none` / `fail-closed` / `wait` |
| `NotifyRuntimeFault` | Keep intent=`allow`; no DIRECT publication; no tear-down |
| `RecoverFromFault` | Re-run Ensure → Publish → ACK (PROXY only) |
| `RebuildAfterNetworkServiceRestart` | Republish PROXY for allow hosts |
| `PlanSiteProxySessionRequestRoute` | Route planner proof: Fail/Wait/UseProxy, never PreserveNative on allow |
| `RunSiteProxyFaultProductDrill` | healthy → on → fault → recovery → off fixture |
| Bubble `NotifyHostProxyRuntimeFault` | UI connection line; does not ClearProxy/DIRECT |
| Browser fixture | `ControlledOnFaultRecoveryOffPreservesRoute` |
| Patch `0353` | Keeps Chromium series synced with overlay |

## Flow

1. **Enable (P-mac-3):** intent=`allow` → local proxy ready → Publish/ACK → ready
2. **Fault:** intent stays `allow`; connection=`unavailable` (fail) or
   `connecting` (wait); published PROXY selection is retained; new request
   plans are `kFail` / `kWait`
3. **Recovery:** EnsureLocalProxy → Publish PROXY → ACK → ready
4. **Network Service restart:** same PROXY republish; never DIRECT while allow
5. **Off:** local intent off; native/DIRECT publication is only admitted here

## Non-goals

- DEV ALLOW/BLOCK panel (P-mac-4)
- Five-step evidence PASS claim (P-mac-6)
- Changing iOS AccessKit fault drill (P-iOS-5)
