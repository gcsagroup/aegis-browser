# P-iOS-4 — iOS DEV ALLOW / BLOCK debug entry

## Scope

DEV/Alpha (or Unknown) debug entry for **explicit-host** ALLOW (proxy intent)
and BLOCK (local refuse). Depends on P-iOS-1 site intent and P-iOS-2 session
seams. Beta/Release must not register this surface or a general Access rule
editor.

| Piece | Role |
| --- | --- |
| `AccessReleaseChannel` | `dev` / `alpha` / `beta` / `release` / `unknown` |
| `AccessDevAllowBlockPanel.admission` | DEV / Alpha / Unknown admit; Beta / Release refuse |
| `isGeneralAccessRuleEditorRegistered` | Always false for this feat |
| `AccessDevAllowBlockPanel.apply` | Intent-only allow/block/off on a normalized exact host |
| `buildSnapshot` | Presentation; `panelRegistered` false off-channel |
| `AccessSiteSessionController.applyDevAllowBlock` | Session seam: intent + tear-down on block/off |
| `AccessDevAllowBlockSectionView` | Thin AegisApp UI; renders only when registered |

## Mapping

| Action | Intent | Ordinary publication |
| --- | --- | --- |
| ALLOW | `AccessSiteIntent.allow` | Intent-only here (product toggle / session enable may publish) |
| BLOCK | `AccessSiteIntent.block` | Local refuse — no silent DIRECT |
| Clear | `AccessSiteIntent.off` | Intent cleared; connection idle |

## Non-goals

- General Prepare/Commit/ListAccessRules rule editor (any channel)
- Beta/Release debug mutation UI registration
- Fault fail-closed product drill (P-iOS-5)
- Five-step evidence PASS claim (P-iOS-6)

## PBX IDs

`00F0`–`00F3` (partition moved from planned `00CF`–`00D2` to avoid F13 `00D0`–`00D4`)
