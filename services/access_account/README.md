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

A successful response identifies the account and returns `status`,
`planId`, `periodId`, `periodStart`, `periodEnd`, `expiresAt`, byte
counters and freshness. Exact byte counts are decimal strings, including
`usedBytes = uploadedBytes + downloadedBytes` and
`remainingBytes = max(0, quotaBytes - usedBytes)`. Status is `active`,
`exhausted`, or `expired` (expiry takes precedence). `not_subscribed`
returns null plan, usage and timing fields. `401` indicates an invalid session.
`503` indicates an unreadable, inconsistent, manually disabled or unsupported
source. All responses specify `Cache-Control: no-store`.

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
