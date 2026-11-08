# P-iOS-5 — iOS site-session fault fail-closed (no DIRECT)

## Scope

After a node/runtime fault on an enabled site session, new requests must
**Fail** or **Wait**. The product path never silently treats DIRECT / native
success as Access success. Recovery re-runs Prepare → Publish → ACK →
activate. Acceptance: A2-3 / A2-4.

Depends on P-iOS-2 (`AccessSiteSessionController`). Mirrors macOS P-mac-5
concepts from `docs/plans/macos-access-fault-no-direct-NOTES.md`, adapted to
the iOS session / connection-state model (no Chromium Network Service rebuild).

| Piece | Role |
| --- | --- |
| `AccessSiteSessionFaultMode` | `none` / `fail-closed` / `wait` |
| `NotifyRuntimeFault` | Keep intent=`allow`; no DIRECT success; no tear-down |
| `RecoverFromFault` | Re-run enable (Prepare → Publish → ACK → activate) |
| `AccessSiteSessionRequestRoute` | Route planner proof: Fail/Wait/UseProxy, never PreserveNative on allow |
| `AccessSiteSessionFaultFixture` | healthy → on → fault → recovery → off drill |
| Snapshot `faultMode` | Intent ≠ connection ≠ fault disposition |
| `AccessSiteSessionFaultTests` | Fail vs Wait, no DIRECT, recovery, drill |

## Flow

1. **Enable (P-iOS-2):** intent=`allow` → Prepare → Publish → ACK → ready
2. **Fault:** intent stays `allow`; connection=`unavailable` (fail) or
   `connecting` (wait); published candidate is retained; new request plans
   are `fail` / `wait`
3. **Recovery:** enable path again → ready (PROXY / reality only)
4. **Off:** local intent off; native / browser-default is only admitted here

## Toggle note

The existing site-proxy toggle already separates intent from connection
(`allowNotConnected` vs `allowConnected`, connection=`unavailable`). Fault
mode lives on the session snapshot so UI can keep showing allow intent while
connection is unavailable / connecting — without claiming Access success.

## Non-goals

- DEV ALLOW/BLOCK panel (P-iOS-4)
- Five-step simulator evidence PASS claim (P-iOS-6)
- Chromium Network Service rebuild API (macOS-only)
- Changing macOS / browser overlay fault fixtures

## PBX IDs

`00F4`–`00F7` (plan originally `00D3`–`00D6`; F13 consumed `00D0`–`00D4`)
