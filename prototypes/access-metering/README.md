# W2 local isolated metering fixture

This prototype exercises one local TCP relay, an independent loopback origin, and a central SQLite byte-permit ledger. A separate two-logical-node model exercises durable byte leases and independent node journals. Both are **local fixtures only**. They do not implement or validate Xray, VLESS/REALITY/Vision, Linux splice, browser integration, authenticated accounts, remote nodes, a hosted accounting service, or production quotas.

## Run

From the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s prototypes/access-metering -p 'test_*.py' -v
```

The same command is exposed as `pnpm run test:access-metering` and included in `quality:fast`. Tests bind only `127.0.0.1`, create temporary SQLite files, use no credentials or external network, and kill only their own relay subprocesses. Every socket, process readiness, marker, and settlement wait in the tests has a timeout.

## Synthetic SM-00 manifest preflight

[`sm00_preflight.py`](sm00_preflight.py) is a **check-only, offline** preparation for the [P3c/A118 SM-00 design](../../docs/plans/access-service-v1.0/W2-SERVER-METERING-DESIGN-20260928.zh-CN.md). It reads a bounded local JSON file and emits `LOCAL_PREFLIGHT_ONLY` plus its SHA-256. It has no endpoint, socket, process, API, deployment, or resource-discovery action. Run the committed synthetic example from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 prototypes/access-metering/sm00_preflight.py \
  --check-only --manifest prototypes/access-metering/sm00_synthetic_manifest.json
```

The example contains invented `synthetic-*` identities and fingerprints, including a fabricated 40-character source value. None identifies a real Xray build, operator, server, credential, or origin. The validator accepts only schema `sm00-synthetic-v1` with `SYNTHETIC_ONLY` classification, synthetic resource and identity references, six fixed-format build digests, explicit target-byte boundaries, and evidence fields for every declared writer and both synthetic fast directions. It requires finite byte, time, concurrency, failure, retry, storage, and stop budgets, plus a durable request/recovery contract. Missing fields, extra endpoint/credential fields, placeholders such as `TBD`, duplicate JSON keys, invalid numeric types, broken account/realm mappings, omitted path evidence, symlinked manifest files, and oversized/nonregular input fail closed. Error output does not print manifest values.

Static hash shape and `synthetic-all-paths-enumerated` are **input checks**, not proof that a real binary has those hashes or that an actual Xray path has been found. This schema intentionally rejects real deployment identities. A future production manifest needs separately reviewed code locations, authenticated resource binding, owners, frozen thresholds, a runtime watchdog, and independent evidence. Passing this command is neither a runnable SM-00 service result nor A118/PF04/PF09 acceptance. The supplied WS+TLS candidate stays a development-complete retest TODO.

## Two logical nodes and central leases

`lease_ledger.py` and `lease_node.py` are separate from the TCP relay. Tests create the central SQLite file and each node's journal explicitly with `create=True`; reopening uses the default `create=False`, so a missing file fails closed instead of silently starting a new balance. Two logical nodes share one finite account quota. A central grant reserves a bounded byte lease in a durable transaction. Repeating the same boot or grant request key returns its original result, including partial grants and denials; a changed request with the same key fails.

Each node persists a chunk PREPARE before invoking a test sink. Immediately before the sink, the journal checks lease expiry and any **known** epoch fence again. A durable local COMPLETE advances that node's two-direction cumulative counters. The center accepts only bound, monotonic reports and moves accepted bytes from `held` to `actual` without increasing available quota. Latest identical reports are idempotent; older reports return STALE and do not debit again. `uncertain` is the remaining held portion of leases whose node restart or expiry is known to the center. Unknown crashes may leave held bytes without an uncertain flag until that notification; read-only snapshots never perform recovery. Expiry and epoch changes do not automatically release reservations.

An offline old node may continue within its already issued, unexpired lease until it learns of a newer epoch; the center keeps that old lease reserved while a new session uses only the remaining account budget. This models quota conservation, **not** instantaneous remote revocation. A failed adoption of a newer session stops the active local scope. A valid fence that cannot be stored for an inactive scope stops all sends in that process; rejected invalid identifiers are not retained. The node journals simulated sends, not authoritative origin receipt; a sink callback is useful for the controlled tests but is not Xray's target-connection byte counter. These tests do not demonstrate real two-server independence, RateLease, physical rate/burst limits, server authentication, power-loss durability, Vision/splice accounting, UI latency, or A118/PF04/PF09 acceptance. The [design boundary](../../docs/plans/access-service-v1.0/W2-MULTINODE-PREP-20260928.zh-CN.md) lists the fixed fixture caps and pending real-resource inputs.

## Two independent loopback relay processes

`lease_relay.py` joins the central lease and node journal to one local TCP data path. `test_lease_relay.py` creates one temporary central database, two node journals, two relay subprocesses, and two independently counted loopback origin subprocesses. A relay replays durable old cumulative reports before adopting a fresh session and one finite lease; it handles one client connection at a time. The center SQLite file stands in for a shared service and has no network protocol or real authentication.

Each forwarded block has a durable full-size PREPARE. The journal commits `SENDING`, rechecks expiry and persisted fences, then performs exactly one nonblocking `socket.send` while holding a short journal write lock. It never waits for socket writability or calls `sendall` under that lock. Only the returned byte count enters a durable COMPLETE and cumulative report; a short write closes the connection and leaves the unsent part reserved. A returned send count means local OS enqueue, so the separately sampled origin/client count can differ during a crash or disconnect. No old PREPARED/SENDING block is replayed after restart.

Test-only files inject an integer clock, temporary center unavailability, fatal report conflict, and four bounded pause stages. Only the explicit temporary-unavailability marker permits a live process to spend an already held, unexpired lease while retaining its pending report; semantic ledger, journal integrity, or ACK errors stop its future sends. Idle report retries have a 100 ms minimum interval and a 32-attempt process cap that includes successful retries and old-journal replay, without resetting after success. These controls never use the supplied WS+TLS candidate, and they do not prove Linux/Xray, a remote center, real node independence, physical rate control, or PF04/PF09. [The relay design and test inputs](../../docs/plans/access-service-v1.0/W2-LOCAL-RELAY-PREP-20260928.zh-CN.md) state the exact fault windows and resource boundary.

The subprocess launcher trusts the test interpreter, repository checkout and inherited environment. It executes `sys.executable` with this checkout's `relay.py`, an argv list of fixture values, and explicit `shell=False`; external request data never supplies launch arguments. Database and fault-marker paths come from the test's temporary directory. The import and this one launcher carry narrowly scoped exceptions for Bandit `B404`/`B603` and Semgrep `python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit`, documenting the audited test-code use. Other calls and rules remain enabled. Re-audit these exceptions if the launcher begins accepting external inputs; the separate process is required to preserve the real kill/restart tests.

For manual local inspection, start the origin and relay in separate terminals, using a fresh local database path:

```sh
python3 prototypes/access-metering/origin.py --port 18080
python3 prototypes/access-metering/relay.py --db /tmp/aegis-w2-demo.db --account test-account --period test-period --quota 1024 --origin-port 18080 --listen-port 0
```

Both print `READY <port>`. The relay accepts only loopback clients and connects only to a loopback origin. The account and period arguments are fixture labels, not authenticated identity. Reusing a database with a different period or quota is rejected. Delete demo files only after you no longer need their audit state; the fixture does not automatically release pending bytes.

## Byte and crash contract

- Quota is a nonnegative integer of **target TCP payload bytes in both directions combined**. No IP/TCP framing, retransmissions, TLS, proxy protocol overhead, or origin application processing is included.
- `PREPARE` commits a finite permit before forwarding. A single permit is at most 16 KiB; at most **8 pending permits exist across the whole database** (maximum 128 KiB unresolved reservation). At the cap, the relay closes the affected connection. The SQLite transaction serializes competing streams against one account/period quota.
- The relay reads at most one configured chunk per direction, reserves no more than remaining quota, forwards only the granted prefix, and closes at the cutoff. It issues a new sequence only after the previous chunk has been sent and settled. `COMPLETE` records a full successful `asyncio` `sock_sendall` and commits `actual_bytes`; duplicate identical completion does not double count.
- One connection-level idle clock is reset by a durable `PREPARE` or completed forward in **either** direction. Sustained upload-only or download-only traffic therefore stays open while the other direction is quiet. A connection with no permit or completed forwarding closes after the configured idle interval; an individual stalled socket send is also bounded by that interval. Once settled account `actual_bytes` reaches quota, one shared notification closes **all** open fixture connections without waiting for another payload or idle timeout; newly accepted connections close immediately. When quota is held by a permit on the same connection, that permit is allowed to settle before closing. A connection with no local permit to settle closes immediately at the cutoff.
- A successful socket send means bytes were accepted into the **local OS send path**. It does **not** prove peer receipt. `asyncio`/Node buffered `write` or `drain` would likewise prove enqueue rather than receipt. The integration tests separately inspect the origin's received byte counter; that evidence is limited to those controlled runs.
- If the process dies or a send/settlement fails anywhere between durable `PREPARE` and durable `COMPLETE`, the full permit remains **held**. On relay startup, `recover()` marks old pending permits **uncertain** while retaining their reservation. A new process cannot call ordinary `COMPLETE` on an uncertain permit. The snapshot exposes `actual_bytes`, `held_bytes`, and `uncertain_bytes` separately; uncertain bytes are an upper bound on unresolved forwarding, not zero usage and not confirmed consumption. No reconciliation or automatic expiry API is provided, so such capacity may remain unavailable indefinitely.
- Period rollover is explicit, requires the expected old period, rejects any pending permit, and never reuses a period ID. Stale-period calls fail closed. Corrupt, uninitialized, incompatible, or unavailable SQLite state fails closed before forwarding. SQLite uses full synchronous commits; this fixture does not simulate power-loss durability or a remote filesystem.

The fault-injection flags `--pause-after-prepare-marker` and `--pause-after-send-marker` are test-only kill windows, bounded to 30 seconds. The latter proves that the origin may receive bytes while the ledger still reports `actual_bytes=0`, `held_bytes>0`, and `uncertain_bytes>0` after a kill. The relay assumes **one owning process** for a database at a time, though it handles multiple concurrent TCP streams. Starting another owner against the same database while the first is active is outside this fixture's contract.

The tests provide local evidence for bounded permits, shared two-direction quota, live long-connection updates, one-direction traffic beyond the idle interval, true idle close, immediate exact-quota close, data-path cutoff, duplicate/sequence/period rejection, independent origin counts, and crash/restart conservation. They do not satisfy W2's real Linux node, fixed Xray/Vision/splice path, authoritative target-byte reconciliation, real identity, network loss, expiry/revocation, multi-node, or performance acceptance.
