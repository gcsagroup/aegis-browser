# Access account entitlement (S1)

Both clients can call `GET /v1/me/entitlement` with their own Aegis session in
the `Authorization: Bearer` header. The service derives the account, plan and
metering period from that session. It requests only the bound client's counters
from [3X-UI v3.11.0](https://github.com/MHSanaei/3x-ui/blob/v3.11.0/internal/web/controller/client.go).
The base URL may include the panel's configured path prefix. The query performs
no panel writes and never sends panel credentials or client identifiers to the browser.

## Run with controlled accounts

Use Python 3.11 and SQLite 3.37 or later. Initialize a private database with
`umask 077; sqlite3 accounts.sqlite < services/access_account/schema.sql`.
For each test account, a trusted operator creates an `accounts` row, generates
a separate session with `secrets.token_urlsafe(32)`, and inserts
`hashlib.sha256(token.encode("ascii")).digest()` as the `sessions.token_hash`
BLOB together with the account ID, absolute session expiry and a null revocation
time. Deliver that opaque session privately to its account. No Aegis paid login
issuer is present in this repository. The B1 installation guest credential and
the VLESS client credential have different owners and are unsuitable for this session.

A subscribed account needs one `plans` row with a plan ID, unique period ID,
start, end and the dedicated 3X-UI client key (the panel calls it `email`).
Timestamps are UTC Unix milliseconds. Enable foreign keys on every writer.
Provision a new, unused finite client with an absolute expiry for each account
and period. Disable automatic resets and keep its counters for the full period.
For rollover, remove the old plan and insert the new binding in one transaction.
A shared Alpha/Beta smoke-test node cannot identify an individual paying account.

Supply the panel token via the server environment or secret manager, and run:

```sh
python3 -m services.access_account.server --database accounts.sqlite \
  --panel-url https://panel.example.test/private-prefix --port 8787
```

The listener binds to 127.0.0.1. Remote clients require an HTTPS frontend.
In 3.11.0 the `monitor` role cannot read these routes. Keep the credential for
`GET /panel/api/clients/traffic/:email` and `GET /panel/api/clients/get/:email` on the service host. Redirects are
refused. Set `AEGIS_3XUI_TOKEN` before starting the command above.
For controlled, timestamped source snapshots, run the same command with
`--stored-snapshots` in place of `--panel-url …` and provision the
`snapshots` row with the matching account and period. The choice is explicit.
In panel mode every subscribed query reads the panel and rechecks the Aegis
session and plan after the response. A failed read returns 503.

## Explicit Alpha single-client panel adapter

The default remains strict: a finite quota, absolute positive panel expiry and
no automatic traffic resets are required. To read an operator-approved Alpha
client whose panel `expiryTime` is zero, explicitly supply
`--alpha-panel-client <email>` together with `--panel-url`. This option cannot
be combined with `--stored-snapshots` or `--sandbox-orders`.

```sh
# Supply PANEL_URL and ALPHA_CLIENT through the operator's private configuration.
# AEGIS_3XUI_TOKEN stays in the service environment/secret manager, not source or logs.
python3 -m services.access_account.server --database accounts.sqlite --port 8787 \
  --panel-url "${PANEL_URL:?}" --alpha-panel-client "${ALPHA_CLIENT:?}"
```

The explicit Alpha client may use the panel's `never` or `daily` traffic reset
policy. Daily readings show that client's current panel counters, including a
legitimate decrease after its scheduled reset. Measurement time remains unknown.
The ordinary finite-period adapter still requires `never`.

Only the exact configured client is readable: an authenticated plan bound to any
other client fails with 503 **before any panel HTTP request**. There is no list,
search, fallback, or main-account query. Bind the approved client in the private
account database; the caller cannot select a client using request parameters.
Invalid Aegis sessions return 401 without querying the panel. A panel credential
failure or unreadable panel response returns 503, not a cached success. The
session and plan are still rechecked after the panel response.

Alpha accepts `expiryTime=0` only as **no panel expiry**, not permanent service
authorization. Its `expiresAt` remains positive and equals the local `periodEnd`.
For positive panel expiry it equals `min(periodEnd, panel expiry)`. Local period
expiry takes precedence over quota exhaustion. Negative relative expiries,
unlimited `totalGB=0`, invalid counters, unsupported reset policies and manually disabled
clients remain rejected (a disabled exhausted/expired client can still report
that terminal status, as in strict mode). `totalGB` is already bytes: for example
`1000000000` is returned as the decimal string `"1000000000"`, without conversion.

A subscribed Alpha response adds all three fields:

- `quotaSource: "3xui_alpha"`
- `panelExpiryMode: "none" | "absolute"`
- `panelExpiresAt: null | <positive UTC Unix milliseconds>`

`not_subscribed` and all strict-mode responses retain the original schema and do
not add those fields. Alpha still reports `measuredAt=null`, `snapshotAgeMs=null`
and `freshness="unavailable"`: a successful read is not a measurement watermark.
This is a read-only panel observation, **not a real-time usage ledger, idempotent
settlement, node authorization or hard quota enforcement**. Existing cumulative
traffic is not reset or relabeled as newly measured period consumption. Keep its
original account/period binding. Deployment, HTTPS exposure and any real-node
operations need separate authorization.

## Controlled native sessions

On macOS the trusted `chrome://aegis` operation `getCurrentAccessAccount`
reads the current regular Profile. Provision `AegisAccessAccount.json` inside that Profile through the
operator account, using an atomic replacement and file mode 0600. Supply the
service `origin`, expected `accountId`, opaque Aegis `token` and a fresh UUID
`generation` for each bind, switch or rotation. Remove the file to sign out.

On iOS the active app scene reads a device-only Keychain session bound to the
configured service origin. The [iOS account guide](../../apps/ios/README.md#current-account-entitlement)
describes controlled simulator provisioning and the app-hosted integration test.

## Response

For subscribed accounts, `evaluatedAt` is the server time used to determine the entitlement status. A client can add monotonic elapsed time since receipt to evaluate expiry at delivery. The original source receipt and measurement timestamps retain their separate meanings.

A successful response identifies the account and returns `status`,
`planId`, `periodId`, `periodStart`, `periodEnd`, `expiresAt`, byte
counters and freshness. Exact byte counts are decimal strings, including
`usedBytes = uploadedBytes + downloadedBytes` and
`remainingBytes = max(0, quotaBytes - usedBytes)`. Status is `active`,
`exhausted`, or `expired` (expiry takes precedence). `not_subscribed`
returns null plan, usage and timing fields. `401` indicates an invalid session.
`503` indicates an unreadable, inconsistent, manually disabled or unsupported
source. All responses specify `Cache-Control: no-store`.

Subscribed responses also include `evaluatedAt`, the UTC Unix millisecond time
at which the service evaluated status. It is independent of `measuredAt` and
`receivedAt`; reading an idle account does not create a new traffic measurement.

3X-UI returns cumulative counters and `lastOnline` but no measurement
watermark. In panel mode `receivedAt` is the time of the successful panel
read, `measuredAt` and `snapshotAgeMs` are null, and `freshness` is
`unavailable`. A timestamped source can return `current` through 5 seconds,
`delayed` through 15 seconds and `unavailable` thereafter. The observed
bytes remain visible. Neither this query nor its business status authorizes
traffic or enforces a quota.

Run the service's unit and HTTP regression tests with `pnpm run test:access-account`.

## S2: trusted sandbox orders (no payment channel)

No merchant/order verifier exists in this repository. Until a payment channel is
selected, this integration accepts **operator-confirmed local sandbox records**.
It does not verify real payments. Use a separate private sandbox database, never
a production node database. The operator's filesystem access is the authority;
protect the database and SQLite journal with `umask 077`. Public callers cannot
create orders, assert payment, choose accounts, or supply grant terms. There is
no unsigned callback or public administrative import route.

Existing S1 databases require no recreation. This additive migration is
transactional and idempotent; enabling sandbox orders also runs it at startup:

```sh
python3 -m services.access_account.orders --database accounts.sqlite migrate
python3 -m services.access_account.orders --database accounts.sqlite record \
  --order-id sandbox-order-001 --account-id A --plan-id sandbox-plan \
  --period-id sandbox-period-A --panel-client sandbox-client-A \
  --quota-bytes 1048576 --duration-ms 86400000 --paid
python3 -m services.access_account.server --database accounts.sqlite \
  --stored-snapshots --sandbox-orders --port 8787
```

Provision account A and its session as described above before importing. These
are confirmed terms, not browser-selected catalog values. The order identity,
account, plan, period, client, byte increment and duration are immutable.
Omitting `--paid` records an unpaid order which cannot be redeemed. The trusted
operator can confirm it later by rerunning the same `record` command with
identical terms and `--paid`. Duplicate confirmations are no-ops; stale unpaid
imports with identical terms also succeed without downgrading the paid state.
Conflicting terms always fail, including during confirmation. Payment can only
advance from unpaid to paid; this is internal controlled confirmation, not real
payment verification. The migration also upgrades the earlier S2 trigger while
retaining existing orders and grant receipts.

With that account's existing Bearer session, send
`POST /v1/me/orders/redeem`, `Content-Type: application/json`, and
`{"orderId":"sandbox-order-001"}`. No other body fields are accepted. Success
returns `{orderId, grantedAt, mode: "sandbox"}`; read the resulting entitlement
through the existing `GET /v1/me/entitlement`. Invalid sessions return 401;
unknown, unpaid, differently owned or incompatible orders return the same 409;
invalid request bodies return 400 and storage failures return 503. Incomplete
bodies (EOF or the five-second read timeout), excessive JSON recursion, and
escaped lone surrogates return a JSON 400 without granting an order. Retry the
same order after a timeout or 503. The endpoint is disabled by default (404).

A SQLite `BEGIN IMMEDIATE` transaction checks the current session, paid record
and account binding, then commits the plan/snapshot changes and unique order
receipt together. Concurrent requests, response loss and process restarts
cannot duplicate a grant. A replay returns its original receipt even if the
current plan later changes; it never recreates that plan. Retain receipts and
orders permanently. Other operator writers must also use transactions and
foreign keys; direct privileged database edits remain outside this trust boundary.

For initial subscription, the grant starts a new snapshot at zero consumption.
For renewal, confirmed plan/period/client must match the existing binding.
Quota is added to the existing total; uploaded/downloaded bytes, period start,
and measurement timestamps are retained. Expiry and period end become
`max(now, min(previous period end, previous expiry)) + duration`, using S1's
effective expiry. A later inactive bound cannot add unpurchased time. An expired account
can renew without losing consumption. Missing/inconsistent snapshots and
numeric overflow fail atomically. Orders cannot roll usage into another period.

**Snapshot versus panel:** this is an offline sandbox ledger, not node quota
provisioning or traffic enforcement. The sandbox flag cannot be combined with
panel mode. S1 panel reads continue to report the panel's actual finite quota,
expiry and consumption, never the sandbox quota increment. A snapshot grant is
not evidence that a node can deliver that allowance. Production activation
requires the selected merchant verifier and a node provisioning/reconciliation
protocol with confirmed enforceable limits before exposing paid capacity;
real payment, refunds, chargebacks, reset/rollover policy and that protocol are
not implemented here. No live secrets or release artifacts are needed.

`pnpm run test:access-account` includes order unit/regression tests, repeated S1
migration, operator CLI, concurrent same/different orders, crash rollback,
restart replay, consumed/expired renewal, panel authority, and end-to-end
loopback HTTP authentication, rejection, response-loss and entitlement reads.
Targeted regressions cover monotonic operator confirmation, immutable terms,
stale unpaid notifications, both S1 expiry orderings, incomplete HTTP bodies,
JSON recursion and non-SQLite-encodable order IDs.

## Managed node credentials (S3)

The account service issues temporary HTTPS CONNECT credentials to a browser-owned
context. The issuer and node share the same private SQLite authority and the
same usage source. A node credential belongs to one authenticated session,
account, plan period, node and regular/private context. Its default lifetime
is 60 seconds (configurable up to five minutes), capped by the earliest
session or plan expiry. The authority stores a password digest.

Before expiry, the owning session can POST the original JSON scope
(`contextId`, `mode`) with its Bearer token to
`/v1/me/node-credentials/{credentialId}/renew`. A successful response contains
`accountId`, `periodId`, `contextId`, `mode`, `credentialId` and the new
`expiresAt` in UTC milliseconds. The credential ID and password remain usable
on the existing connection. Renewal checks current entitlement, usage freshness,
the session, node and original scope. Expiry or revocation requires fresh issuance.

Configure a dedicated Xray SOCKS5 listener on numeric loopback for each
enabled panel client. Each listener must use the outbound for that client's
own 3X-UI identity. Use a distinct port per identity. Keep the node's private
configuration, backend listeners and account database on the trusted service
host. For example, a controlled deployment can admit one destination:

```json
{
  "nodeId": "test-node",
  "upstreams": { "test-account-panel-client": 10811 },
  "targets": { "site.example:443": "192.0.2.10" }
}
```

The target IP is the operator's pin. The node selects the account's local
SOCKS5 port from verified server state and passes that numeric destination to
Xray. Configure the Xray outbound, controlled target and port mapping before
adding the account to this node. Certificates must cover the advertised node
hostname. Start both processes with the same panel URL and panel credential:

```sh
python3 -m services.access_account.server --database accounts.sqlite --port 8787 \
  --panel-url https://panel.example.test/private-prefix \
  --node-config node.json --node-host proxy.example.test --node-port 9443

python3 -m services.access_account.node --database accounts.sqlite --port 9443 \
  --host 0.0.0.0 --config node.json --cert tls-chain.pem --key tls-key.pem \
  --panel-url https://panel.example.test/private-prefix
```

Expose the loopback account service to native callers through HTTPS. The node
serves TLS itself. Controlled offline integration can run both processes with
`--stored-snapshots` and matching, recently measured snapshots. Live panel
mode keeps reading the associated client's counters and finite limits.

Using the current Aegis bearer, the native client sends
`POST /v1/me/node-credentials` with a canonical lowercase UUID in `contextId`
and a `mode` of `regular` or `private`. After validating the account, context
and expiry in the response, the client uses the returned credentials only for
CONNECT over TLS to the advertised proxy. Keep the password in process memory
and out of website rules, diagnostics, history and page APIs.
`DELETE /v1/me/node-credentials/<credentialId>` revokes the session's grant.
Closing a browser context also requires closing its local transport. A lost
revocation request leaves the server-side expiry in effect.

The node checks authorization on connection setup and while relaying. It
schedules a fresh check after two seconds and allows one second for the
authority to respond. Revocation, exhaustion, expiry, or failure to obtain
a current authorization closes the stream. This periodic check has bounded
latency. Byte-exact transfer cutoff and settlement are tracked separately.

## Metering a managed Xray node

The metered profile uses the authenticated VLESS client on the REALITY server
and the existing account database. Configure one distinct VLESS client for
each panel client admitted by this node. Its server-configured user label must
match the plan's permanent `panel_client` binding. The managed CONNECT entry
continues to select the dedicated SOCKS listener from the verified account.
A shared Alpha/Beta client can provide a smoke test but cannot provide two
accounts' independent usage.

Byte counts include the target's TLS handshake and encrypted application data.
Upstream writes count the confirmed prefix accepted by the target connection.
Downstream writes count the target bytes in confirmed Vision writes, excluding
the protocol header and padding. In raw mode the receiver is the underlying
client connection. These counters advance during an open connection. Direct
traffic, local cache hits and the node's control requests do not enter these
writers.

Build the server from the pinned Xray-core v26.11.9 source with Go 1.27.3.
The supported node profile uses VLESS Vision over REALITY/TCP and a direct
Freedom TCP outbound. Use a dedicated process for this profile. Its paid
connections use the instrumented writers even on hosts that support kernel
splice. Keep mux, fragmentation, outbound chaining and address overrides
disabled for this profile.
The build helper reads the pinned commit from an upstream Git checkout,
applies the writer changes in a new directory, and runs adapter tests:

```sh
services/access_account/xray_meter/build.sh /path/to/Xray-core \
  /path/to/new-build-directory /path/to/xray-metered
```

Use a dedicated service account for the collector and metered Xray process.
Give that account a private run directory (mode 0700). The collector creates
a mode-0600 Unix socket and adds its meter tables to the existing account
database. Its trusted node ID and admitted clients come from the same private
node configuration used by the CONNECT service.

```sh
python3 -m services.access_account.metering serve \
  --database /private/access/accounts.sqlite --config /private/access/node.json \
  --socket /private/access/run/meter.sock
```

Start the metered server with `AEGIS_XRAY_METER_SOCKET` set to that socket's
absolute path. Use a separate Xray process/configuration for the outbound
client. Confirmed writes and terminal records are persisted in a private
`<socket>.outbox` directory before reporting. The process retries unacknowledged
records in order, including after restart, and stops a flow on reporting failure.
Sample records preserve the writer's measurement time across delayed delivery;
the collector's arrival time does not replace it. Preserve that directory across restarts. A process or storage failure before a
writer can persist its result leaves the flow open with a confirmed lower bound.
If a crash leaves the socket path behind, confirm that the owning
collector is stopped before removing that path.

Read a consistent account and node snapshot for one period with:

```sh
python3 -m services.access_account.metering usage \
  --database /private/access/accounts.sqlite --node test-node --period billing-period
```

`uploadedBytes` and `downloadedBytes` are directional totals. `sampledAt` is
the UTC epoch time in milliseconds of the last recorded increase and is null
until the first increase. `openFlows` includes live connections and connections
whose terminal record has not arrived. `incompleteFlows` records a known
incomplete transfer. Treat the counters as confirmed lower bounds until all
relevant writers have finished successfully. The result also includes the
confirmed byte counts by writer path. The local reader is intended for
operators and does not grant access to other accounts through the public API.

Omit `--period` to include all recorded periods in the node total. Use the
account and period on each row when reconciling it to a particular plan.

To check the complete path on loopback, run the following from the repository
root with a stock v26.11.9 client, the built server, Python with TLS 1.3
support, and OpenSSL on PATH. Install the HTTP cache test dependencies in
your test virtual environment. Choose a new receipt filename for each run.

```sh
python3 -m pip install 'requests==2.32.5' 'CacheControl==0.14.3'
python3 -m services.access_account.tests.wire.acceptance \
  --client /path/to/xray-stock --server /path/to/xray-metered \
  --receipt /path/to/new-receipt.jsonl
```

The runner issues credentials to two test accounts and compares the node's
directional counts with the independent target during concurrent transfers
and after close. A separate plaintext TCP target exercises the unpadded Vision
writer. A direct transfer, an HTTP cache hit and a REALITY cover probe must
leave usage unchanged.

Run the collector and Xray restart regression with the same arguments using
`python3 -m services.access_account.tests.wire.recovery`. It interrupts the
collector while a target accepts bytes, restarts both processes, and verifies
that the pending confirmed prefix and terminal record are recovered.

## Settle managed-node usage into an account period

The operator usage command above reads one node's retained writer counters.
To make those bytes authoritative for an account's entitlement and managed
credentials, explicitly bind that node to the account and period. This local
deployment shares the private account database between the collector, issuer
and CONNECT service. There is no public report-import endpoint or independent
remote-node settlement transport.

Binding captures the existing snapshot's uploaded and downloaded bytes once
as the period's opening baseline. Subsequent confirmed node increments are
added to that baseline. The collector commits the durable flow update, node
source position and confirmed settlement position in the same SQLite write
transaction; a failed settlement rolls back the flow increment too. Entitlement
reads use a single read transaction, and credential issuance and verification
use the same settlement source. A bound period does not also add or query the
panel's cumulative traffic. Snapshot quota and expiry remain the grant terms;
same-period sandbox top-ups retain consumption and cannot apply twice.

For the first cutover of each **node, account and period**:

1. Stop traffic and credential issuance, drain existing writers and reconcile
   pending outbox records before provisioning. Retain
   the account's session, permanent panel-client binding and current plan. In
   one operator transaction, provision a reconciled snapshot for this period,
   including quota, expiry, opening directional totals and their real timestamps.
   Do not reset previously consumed bytes or replace an old measurement time
   with the time of provisioning.
2. Use the same trusted node configuration as the collector and CONNECT service.
   The account's dedicated client must be admitted by that configuration. Before
   this node records its first byte for the account and period, run:

   ```sh
   python3 -m services.access_account.settlement bind \
     --database /private/access/accounts.sqlite --config /private/access/node.json \
     --account account-A --period billing-period-A
   ```

   The command adds its tables transactionally to the existing database and
   returns `{"ok":true}`. Repeating an existing binding is a no-op. An unknown
   or inconsistent plan/client binding fails. If the collector has already
   recorded any positive usage for this node, account and period, a first bind fails with
   `settlement unavailable`: those bytes might already be in the baseline.
   Reconcile that cutover separately; deleting history or retrying with a zero
   baseline cannot establish which bytes were already charged.
3. Run the account service and CONNECT service against that same database, then
   reopen the entry only after reading the expected account and period through
   `GET /v1/me/entitlement` with that account's Bearer session. For a controlled
   snapshot deployment, use `--stored-snapshots` on both processes as described
   above. No panel read is used for this bound period, even in panel mode.

Read the node source using the existing operator CLI:

```sh
python3 -m services.access_account.metering usage \
  --database /private/access/accounts.sqlite --node test-node --period billing-period-A
```

Use the matching `accounts` row's `accountId`, `periodId`, `uploadedBytes`,
`downloadedBytes` and `sampledAt`, rather than the node-wide totals. The account's
HTTP entitlement includes the opening baseline plus all nodes explicitly
admitted to that account and period. It returns exact decimal byte strings and
retains the last confirmed measurement time during idle reads. Old display
freshness alone does not invalidate an idle bound account's credentials: the
local durable authority still checks its current quota, expiry and session.

To retry delivery of an already retained cumulative node position, use:

```sh
python3 -m services.access_account.settlement replay \
  --database /private/access/accounts.sqlite --config /private/access/node.json \
  --account account-A --period billing-period-A \
  --uploaded 1048576 --downloaded 2097152 --measured-at 1794528000000
```

The example numbers must be replaced with that account/period row's actual
directional counters and UTC Unix millisecond sample time. This command can
confirm only positions already retained by the configured trusted node. It
rejects negative counters, future sample times, unknown bindings and counters
above the retained source. Repeated, older and out-of-order positions use the
directional maximum, never add the cumulative total again. A no-op replay does
not change the measurement or receipt time. Retained positions survive a
collector restart; local collection already confirms them atomically, so
replay does not import new traffic from an external report.

At rollover, transactionally replace the current plan and snapshot with the new
period and a new, unused panel client. Keep the old `panel_bindings`, meter flows
and settlement rows. Bind the new period before its first byte. Each existing
flow retains its original account and period, so a late sample or replay for an
old period changes only that old ledger. It cannot charge another account or
the current period. This is a one-way source handoff; changing configuration or
stopping the collector does not switch an already bound period back to panel
counters.

The loopback settlement runner exercises live A/B transfers, entitlement reads,
duplicate and out-of-order replay, collector restart and late prior-period
delivery against an independent target:

```sh
python3 -m services.access_account.tests.wire.settlement \
  --client /path/to/xray-stock --server /path/to/xray-metered \
  --receipt /path/to/new-settlement-receipt.jsonl
```

Use the dependencies and private controlled runtime described above. Each
receipt records its checkout SHA and source/binary hashes; a passing receipt
applies to those inputs, not a later candidate or production deployment.

## Enforcing the shared account budget

Bind the account and period to node settlement before enabling quota execution,
using the settlement setup above. Run the collector with `--enforce-quota` and
set `AEGIS_XRAY_QUOTA=enforce` on the metered Xray server process as well as
`AEGIS_XRAY_METER_SOCKET`. Keep all of the account's paid Xray clients on admitted
nodes sharing this authority database. Each admitted node needs its own node ID,
collector socket, private recovery directory and permanent client bindings.

The collector serializes reservations for both directions, every stream and
every admitted node in one SQLite write transaction. A reservation is persisted
before granting a target write. Its directional ticket is confirmed after the
write, advancing node counters and the account settlement in the same
transaction. Confirmed short writes release only the known unused part.
Uncertain writes and missing confirmations retain their outstanding allocation.
Preserve both the database and recovery directory across node restarts.

The node closes active and idle streams when the account is exhausted or
expired and refuses fresh streams. A flow's cutoff remains recorded after a
top-up, so recovery requires a fresh authorized connection. The writer also
applies the authority's absolute expiry as its local socket deadline. A
reservation granted before cutoff may finish within its bounded write deadline.
Operator receipts expose those outstanding bytes separately from confirmed
traffic.

Inspect one account's allocation history with the local operator command.

```sh
python3 -m services.access_account.quota --database /private/access/accounts.sqlite \
  --account account-a --period billing-period
```

`confirmedBytes` is confirmed traffic under quota execution. `heldBytes`
includes allocations whose final progress is still unknown. `releasedBytes`
is the known unused allocation. `grantedBytes` is the historical sum of all
three. The existing entitlement response publishes confirmed used and remaining
bytes. Use the existing confirmed controlled-order redemption to add quota.

Run the real two-direction TLS cutoff, idle-stream, restart, top-up and expiry
regression with the normal wire arguments.

```sh
python3 -m services.access_account.tests.wire.cutoff \
  --client /path/to/xray-stock --server /path/to/xray-quota \
  --receipt /path/to/new-cutoff-receipt.jsonl
```
