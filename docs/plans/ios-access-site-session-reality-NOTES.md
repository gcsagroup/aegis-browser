# P-iOS-2 — site session orchestration onto reality path

## Scope

Per-host Access session controller that turns site intent into a reality_vision
path using existing F8 / F9 / F11 seams.

| Type | Role |
| --- | --- |
| `AccessSiteSessionError` | Readable fail-closed errors (no DIRECT success) |
| `AccessSiteSessionPhase` / `ConnectionState` / `Snapshot` | Intent ≠ connection |
| `AccessSiteSessionCandidate` / `Publication` / `Ack` | Prepare → Publish → ACK |
| `AccessSiteSessionOrchestrating` | Injectable pipeline seam |
| `AccessSiteSessionController` | `enable` / `block` / `disable` |
| `AccessSiteSessionControllerTests` | Happy path + fail-closed |

## Flow

1. **enable (allow):** PrepareCandidate → Publish → ACK → activate reality path → `ready`
2. **block:** tear down any published proxy; intent=`block`; connection=`unavailable`
3. **disable (off):** tear down / clear proxy; return idle

## Non-goals

- SwiftUI toggle (P-iOS-3)
- DEV ALLOW/BLOCK panel (P-iOS-4)
- Fault-injection product drill (P-iOS-5)
- HTTPS inbound → reality confluence (F12)

## PBX IDs

`00C5`–`00C9`
