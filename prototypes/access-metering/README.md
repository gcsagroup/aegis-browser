# W2 local isolated metering fixture

This prototype exercises one local TCP relay, an independent loopback origin, and a central SQLite byte-permit ledger. It is a **local fixture only**. It does not implement or validate Xray, VLESS/REALITY/Vision, Linux splice, browser integration, authenticated accounts, remote nodes, a hosted accounting service, or production quotas.

## Run

From the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s prototypes/access-metering -p 'test_*.py' -v
```

The same command is exposed as `pnpm run test:access-metering` and included in `quality:fast`. Tests bind only `127.0.0.1`, create temporary SQLite files, use no credentials or external network, and kill only their own relay subprocesses. Every socket, process readiness, marker, and settlement wait in the tests has a timeout.

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
