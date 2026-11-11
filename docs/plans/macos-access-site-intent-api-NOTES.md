# P-mac-1 — site intent API (off / allow / block)

## Scope

Product-facing exact-host Access intent under
`apps/browser/overlay/chrome/browser/aegis/access/`, mapped onto ordinary
`AccessServiceCoordinator::CommitSiteGroupMutation` boundaries.

| Type / API | Role |
| --- | --- |
| `AccessSiteIntent` | `off` / `allow` / `block` |
| `AccessSiteHost` | Canonical exact-host key + URL normalization |
| `OrdinaryAccessModeForIntent` | allow→`kProxy`, off→`kDirect`, block→none |
| `BuildOrdinarySiteGroupMutation` | Builds `SiteGroupMutationRequest` for allow/off only |
| `AccessSiteIntentStore` | In-memory product intents (off omitted) |
| `access_site_intent_unittests` | Parse / normalize / map / store |

## Mapping

| Intent | Ordinary site-group mode | Publication |
| --- | --- | --- |
| `allow` | `AccessMode::kProxy` | Caller may `CommitSiteGroupMutation` |
| `off` | `AccessMode::kDirect` | Caller may `CommitSiteGroupMutation` |
| `block` | not ordinary | `kBlockNotOrdinary` — no silent DIRECT |

Intent remains distinct from publication/ACK and connection health.

## Non-goals

- Toolbar bubble UI (P-mac-2)
- Session finalize / ACK orchestration UX (P-mac-3)
- DEV ALLOW/BLOCK panel (P-mac-4)
- Five-step product PASS claim (P-mac-6)
