# K evidence index (desensitized)

Product five-step pack stays in the parent directory. This folder only holds
**templates** for the in-process core (K) receipt produced by
`scripts/release/ios-access-core-tests.sh`.

| File | Role |
| --- | --- |
| `receipt.template.json` | Schema for a single K run |
| (operator) `../artifacts/K/<run>/k-receipt.json` | Real receipt stays under `.artifacts` / local artifacts; do not commit node files |

`NOT_RUN` when lock, verified slices, xcframework, or node file is missing.
Simulator PASS ≠ device (D) PASS.
