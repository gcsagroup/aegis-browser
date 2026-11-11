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
