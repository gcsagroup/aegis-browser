# Correlation ID convention (macOS Access Phase 1)

## Format

```text
aegis-mac-p1/<candidate8>/<run_id>/<step>
```

| Field | Rule |
| --- | --- |
| prefix | literal `aegis-mac-p1` |
| `candidate8` | first 8 lowercase hex chars of the candidate / source SHA |
| `run_id` | `[A-Za-z0-9_-]{1,64}` unique per continuous five-step attempt |
| `step` | exactly one of `on`, `load`, `fault`, `recovery`, `off` |

Examples:

```text
aegis-mac-p1/8ba3848a/20261108-mac-1/on
aegis-mac-p1/8ba3848a/20261108-mac-1/load
aegis-mac-p1/8ba3848a/20261108-mac-1/fault
aegis-mac-p1/8ba3848a/20261108-mac-1/recovery
aegis-mac-p1/8ba3848a/20261108-mac-1/off
```

## Mapping to acceptance

| Step | Acceptance | Meaning |
| --- | --- | --- |
| `on` | B2-1 | Trusted enable → ready or readable failure |
| `load` | B2-2 | Page/subresource via specified PROXY exit |
| `fault` | B2-3 | New requests Fail/Wait; never silent DIRECT |
| `recovery` | B2-4 | Restore → PROXY ready again |
| `off` | B2-5 | Native / PreserveNative; no stale PROXY selection |

## Join rules

1. One `run_id` covers all five steps under one `candidate8`.
2. Browser log lines, node-side traces, and UI filenames must embed the full ID.
3. Changing the candidate SHA starts a new pack — do not join old UI with new logs.
4. Unit-test / overlay-only IDs may use a synthetic run token; they cannot alone
   set product `status=PASS` (B4-2 / B4-3).
