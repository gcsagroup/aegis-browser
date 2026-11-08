# P-mac-4 — macOS DEV ALLOW / BLOCK debug panel

## Scope

DEV/Alpha debug panel for **explicit-host** ALLOW (proxy intent) and BLOCK
(local refuse). Depends on the P-mac-1 site intent API. Beta/Release must not
register this panel or a general Access rule editor.

| Piece | Role |
| --- | --- |
| `AccessDevAllowBlockPanelAdmissionFor` | DEV / Canary / Unknown admit; Beta / Stable refuse |
| `IsGeneralAccessRuleEditorRegistered` | Always false for this feat |
| `ApplyAccessDevAllowBlock` | Intent-only allow/block/off on a normalized exact host |
| `BuildAccessDevAllowBlockPanelSnapshot` | Presentation; `panel_registered` false off-channel |
| `AccessSiteProxyBubbleController` | Channel-gated apply + snapshot wrappers |
| Toolbar `AppendDevAllowBlockSection` | Renders only when the panel is registered |
| Patch `0353` | Keeps Chromium series synced with the overlay |

## Mapping

| Action | Intent | Ordinary publication |
| --- | --- | --- |
| ALLOW | `AccessSiteIntent::kAllow` | Not claimed here (product toggle / P-mac-3) |
| BLOCK | `AccessSiteIntent::kBlock` | `kBlockNotOrdinary` — no silent DIRECT |
| Clear | `AccessSiteIntent::kOff` | Intent cleared; connection idle |

## Non-goals

- General Prepare/Commit/ListAccessRules rule editor (any channel)
- Beta/Release debug mutation WebUI registration
- Fault fail-closed product drill (P-mac-5)
- Five-step evidence PASS claim (P-mac-6)
