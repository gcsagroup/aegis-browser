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


## Native checkpoint (2026-11-10, patches through 0405)

The current product candidate retains exact destination-host rules constrained by the Browser-owned top-level site. Paths on that host share the persisted Profile intent; an explicit proxy retry reloads only its initiating tab. Subdomains and cross-host page resources are not yet covered by this checkpoint.

Implemented: Browser-private full-policy publication and per-hop routing, an asynchronously restored ordinary Profile rule store, a managed authenticated Xray child with certificate-validated HTTPS readiness, and the error-page action wired to an original-tab one-shot retry. Native navigation no longer rejects legitimate selection-generation zero, and subdomain rules/cancellation selectors now use Chromium SchemefulSite identities.

Validation: complete native chrome builds through 0405; affected intent/session/coordinator tests 6/17/24 pass, including six real-core product scenarios. The navigation helper has 15 passing tests, including interaction with Chromium error auto-reloading. Actual Aegis computer use verifies controlled DIRECT DNS failure, one retry click, real readiness and a single original-tab/original-URL reload. This controlled fault is not a natural GFW measurement.

The requested 100-site run remains incomplete: the sealed checkpoint contains 15 natural-connection observations and 14 proxy main-document observations with matching browser NetLog routes. Twelve have page-content observations; Pinterest remains blank because its CDN requests retain native routing, and TikTok needs additional rendering evidence. These results do not close full browser, recovery or isolation acceptance.

Approved follow-up: extend the selection to the trusted top-level website context, including its page resources/CDNs, while retaining Browser attribution, unrelated-site and Profile isolation. That expansion is deliberately not implemented in this checkpoint. Cold-start automatic core preparation, actual runtime-exit/recovery/off coverage, the remaining website matrix and final-candidate acceptance also remain open.
