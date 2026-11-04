# Terminal receipt receiver

This standard-library module records one task-bound terminal observation. It grants no execution authority. `RECEIVED` means the controller-observation frame was complete, matched the expected context, and arrived before the receiver deadline. It is not a product pass, remote wait attestation, all-writers retirement proof, or execution admission. A nonzero observed exit is retained without conversion to zero.

## Trusted caller and API

A trusted control-plane caller constructs `ExpectedContext`, including a one-use nonce, exact product/native Git SHA-1 values, target host/boot, receiver clock boot/timebase, absolute continuous deadline and fixed byte caps. Context validation checks shape and bounds, not the caller's authority, nonce uniqueness across tasks, network identity or authentication. Wire context is compared in full and never used to grant roles. `feed` must be wired only to the intended controller-observation channel; the literal source label cannot authenticate its sender. Producer claims such as group absence or all writers retired are not supported frame fields.

Construct `Receiver(expected, clock, directory)` with a callable returning a validated `ClockSample(continuousNS, bootID, timebase)`. The caller performs tick-to-nanosecond conversion. Use a receiver-local continuous clock including suspend as required by the deployment; wire timestamps cannot replace it. No deadline setter exists. The clock must not re-enter receiver methods. Public operations serialize access. `result` returns a deep copy or `None` while open.

- `feed(bytes)` accepts exactly one complete JSON data or terminal frame and returns `None` while open, or a detached terminal result. Supply frames with exact increasing sequence numbers starting at zero.
- A data frame names stdout or stderr, canonical base64 and its decoded byte count. Counts and SHA-256 cover accepted data separately for each stream; content is not retained. Invalid data does not enter the accepted stream hash. The raw hash/count covers all in-budget attempted frames, including a rejected malformed frame; an over-budget frame is not hashed or charged as accepted input.
- A terminal frame requires a strict integer actual exit, both EOF booleans, wait observation and `controller-observation` source. Empty streams are legitimate only with complete terminal observations. Truncated JSON is an error, not an EOF. No process is started or waited by this module.
- `poll()` checks the clock without a frame. `abort("LOSS")`, `abort("CANCELLED")` or `abort("INCOMPLETE")` closes an unfinished reception and preserves partial counts/hashes with unknown exit `null`.
- Subsequent feed/abort calls raise `ClosedReceipt`. Poll/result preserve the first decision and reason. No API reopens a slot.

The deadline is checked on creation, before frames, and after validation immediately before accepting data or the complete terminal decision. Equality, regression, a different receiver boot/timebase, or a clock exception closes UNKNOWN. Invalid frames/binding/sequence/limits close FAILED. A complete valid terminal closes RECEIVED regardless of its exit code. Storage errors downgrade the exposed result to UNKNOWN while retaining `decisionReason` and any already observed exit. These are receiver states, not execution states.

This is a cooperative receive cutoff. It cannot enforce a hardware deadline, interrupt a blocked clock/fsync, stop a sender or establish a physical UTC bound. The decision's `observedContinuousNS` describes receipt time, not fsync completion. The caller must poll on loss/deadline, abort on orderly shutdown, and provide independent external deadline/recovery enforcement. If it crashes without aborting, the reserved slot prevents restart from reopening reception.

## Bounds and wire schema

`terminal_receipt.schema.json` describes the two wire shapes and exact context fields. Code additionally enforces lexical JSON constraints that JSON Schema cannot express: duplicate keys, nonfinite constants, and float spellings of integer fields are rejected. Schema validation alone does not enforce state, binding, clock, canonical base64, serialized-frame size or cumulative decoded-byte limits.

A frame is at most 1 MiB; total accepted raw input is bounded by context.rawMax (at most 16 MiB). Each stream is bounded independently at at most 8 MiB. A terminal record cap is 4096..65536 bytes. Base64 size and remaining stream budget are checked before decoding. The API accepts bytes already supplied by the caller; transport framing must itself use bounded reads before allocating these bytes. This module never reads a transport. Existing slot content is read only up to recordMax+1. Identifiers, nonce, hashes and numeric values have fixed bounds. No caller-provided error string is copied into the receipt.

## One-use persistence and restart

The deployment must pre-create one receiver-owned, suitably protected directory per task. The module opens it with O_DIRECTORY/O_NOFOLLOW, checks effective ownership and no group/world write bits, and reserves the fixed `terminal-receipt.json` name with O_CREAT/O_EXCL/O_NOFOLLOW and mode 0600. The directory is fsynced before receiving. The slot is never deleted, truncated or reused. An existing name, including an empty/partial/oversized file or a symlink, always closes the new instance UNKNOWN. A bounded prefix hash is informational, not an acceptance signal. Restarts conservatively close UNKNOWN even when the existing record appears complete; they never replay a disk RECEIVED value as new authority.

At the first terminal decision the record cap is charged before writing. Positive short writes are completed; zero progress, write/fsync/close failures stay closed UNKNOWN and preserve the original decision reason. File and directory fsync are attempted once. The on-disk record deliberately says storage=UNCONFIRMED: a completed byte sequence alone cannot prove its later fsync succeeded. Only the live result reports FSYNC_COMPLETED when the calls returned successfully. A failed write can leave partial bytes; a failed fsync can leave a complete proposal. Neither is repaired into success, and restart never trusts either. There is no claim of atomic power-loss persistence or independent physical storage verification.

Checking this directory does not protect its ancestors or establish producer exclusion. Deployment must prevent adversarial replacement, writable ancestors/aliases, shared inherited descriptors and storage exhaustion, and reserve the total disk budget. The module creates no protection service and implements no cross-task nonce registry, guardian, authentication backend, spawn/kill, sockets, SSH, installation or runner wiring.

## Finite semantic reuse

The historical witness receiver supplied exact challenge/count checks, two EOF requirements and preservation of actual exit 23. The deadline receiver supplied first cutoff sealing and rejection of late exit 29. The loss receiver supplied partial-output UNKNOWN and rejection of a later exit 0. The fixture slot supplied charge-before-write and no-refund semantics. These semantics are generalized here with synthetic regression inputs; hardcoded probe secrets, transport calls and remote programs are not copied. The scope envelope, FD launcher, Linux guardian and stage runners remain separate infrastructure; this module does not replace or activate them.

## Validation recipe (requires separate execution admission)

From a checkout containing this directory, run:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s apps/browser/scripts/native_validation -p terminal_receipt_test.py -v
```

`ReceiverTests` are unit tests; `HistoricalReceiverRegressions` are synthetic historical-semantic regressions, not replay of authenticated remote evidence. Tests create only bounded temporary directories/files and mocked write/fsync failures, including partial slots and restart. They create no sockets or subprocesses. Set TMPDIR to an admitted scratch location and capture the command's stdout/stderr outside the source checkout. Expected writes are these temporary slots and any explicit caller-owned output captures; no bytecode or repository writes are required. POSIX O_NOFOLLOW/O_DIRECTORY support is required.

The current source-only delivery ran only source text/hash/diff and AST checks. These test definitions have not run. Compilation, runtime, hosted CI, independent review, remote-host results, authorization and execution qualification remain separate gates.
