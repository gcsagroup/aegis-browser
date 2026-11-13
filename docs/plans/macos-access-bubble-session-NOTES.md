# P-mac-3 — macOS bubble session publish + local proxy ready

## Scope

Wires the toolbar site-proxy bubble onto PrepareCandidate → Publish → ACK,
requiring local loopback proxy readiness. Failures stay readable. Disable
commits locally even when the Access service is unavailable. Switch state
remains distinct from connectivity.

| Piece | Role |
| --- | --- |
| `AccessSiteProxySessionError` | Readable fail-closed errors (no DIRECT success) |
| `AccessSiteProxySessionPhase` / `Snapshot` | Intent ≠ connection |
| `AccessSiteProxySessionOrchestrating` | Injectable EnsureLocalProxy → Publish/ACK seam |
| `AccessSiteProxySessionController` | Sync `enable` / `disable` for unit coverage |
| `RequestHostProxySession` | Bubble controller product path onto coordinator |
| `TrustedAccessStoreBindingFactory` | Ephemeral store bindings for first mutation |
| Toolbar bubble | Calls publication path; shows `failure_reason` |
| Patch `0352` | Keeps Chromium series synced with overlay |

## Flow

1. **Enable:** intent=`allow`, connection=`connecting` → EnsureLocalProxyReady →
   BuildOrdinarySiteGroupMutation(`kProxy`) → `CommitSiteGroupMutation`
   (Prepare → Publish → ACK) → `ready` or readable `unavailable`
2. **Disable:** local intent=`off` + `idle` first; best-effort DIRECT publication;
   service/proxy absence does not block the local commit

## Non-goals

- DEV ALLOW/BLOCK panel (P-mac-4)
- Fault fail-closed product drill (P-mac-5)
- Five-step evidence PASS claim (P-mac-6)
