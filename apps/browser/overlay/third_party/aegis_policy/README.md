# third_party/aegis_policy

Policy snapshot exported from `packages/core`.

| File | Role |
|------|------|
| `policy_snapshot.json` | Portable JSON (trackers / phish seeds / params / collect paths) |
| `policy_worker.js` | Bundled `packages/core` JS policy worker (IIFE) |
| `easylist_compiled.json` | Optional local compile of EasyList (gitignored, GPL/CC) |
| `../chrome/common/aegis/generated/*.inc` | C++ string tables included by builtin_*.cc |
| `../chrome/browser/aegis/generated/policy_worker_source.inc` | C++ raw-string of `policy_worker.js` |

Regenerate:

```bash
pnpm --filter @gcsa-aegis/browser sync-core-snapshot
pnpm --filter @gcsa-aegis/browser sync-policy-worker
pnpm --filter @gcsa-aegis/browser sync-easylist   # optional; runtime updater also fetches
```

Do not hand-edit generated `.inc` files — edit TypeScript under `packages/core` instead.
