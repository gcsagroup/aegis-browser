# Correlation ID convention (iOS Access Phase 1)

## Format

```text
aegis-ios-p1/<candidate8>/<run_id>/<step>
```

| Field | Rule |
| --- | --- |
| prefix | literal `aegis-ios-p1` |
| `candidate8` | first 8 lowercase hex chars of the candidate / source SHA |
| `run_id` | `[A-Za-z0-9_-]{1,64}` unique per continuous five-step attempt |
| `step` | exactly one of `on`, `load`, `fault`, `recovery`, `off` |

Examples:

```text
aegis-ios-p1/a01308c9/20261108-ios-1/on
aegis-ios-p1/a01308c9/20261108-ios-1/load
aegis-ios-p1/a01308c9/20261108-ios-1/fault
aegis-ios-p1/a01308c9/20261108-ios-1/recovery
aegis-ios-p1/a01308c9/20261108-ios-1/off
```

## Mapping to acceptance

| Step | Acceptance | Meaning |
| --- | --- | --- |
| `on` | A2-1 | Trusted enable → ready or readable failure |
| `load` | A2-2 | Page/subresource via specified PROXY exit |
| `fault` | A2-3 | New requests Fail/Wait; never silent DIRECT (needs P-iOS-5) |
| `recovery` | A2-4 | Restore → PROXY ready again |
| `off` | A2-5 | Native / cleared ProxyConfiguration; no stale PROXY selection |

## Join rules

1. One `run_id` covers all five steps under one `candidate8`.
2. AccessKit / app log lines, node-side traces, and UI filenames must embed the full ID.
3. Changing the candidate SHA starts a new pack — do not join old UI with new logs.
4. Unit-test IDs may use a synthetic run token; they cannot alone set product
   `status=SIMULATOR_PASS` (A4-2 / A4-3).
5. Device / TestFlight evidence is a separate track (`NOT_RUN` here).
