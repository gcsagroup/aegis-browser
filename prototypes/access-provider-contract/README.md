# Access provider contract: Stage A

This isolated ESM package implements bounded, reusable **local contract checks** for
the accepted minimum-provider design (e26cdc01) and I's clarifications (9f659145).
It creates no service, database, authenticated installation, node authorization,
browser publisher or native adapter. Source baseline is 12c2654a.

The executable schemas are a Stage A version-1 wire draft, not a deployed API.
All values in vectors.json are explicitly fixture-only. Tests generate temporary
keys in memory; no real credential, Xray configuration or historical binary is used.

The ordinary-Profile first slice represents server-issued installation guest
authority, two independent Profile credentials and one shared entitlement pool.
OTR and Guest explicitly return unavailable; System is unsupported. This is not
complete OTR product delivery. The installation label alone cannot create a
credential, principal or entitlement; local Profile labels are expected bindings,
not proof of native ownership or bootstrap possession.

The module separates these operations:

- parseUntrusted validates bytes, duplicate/unknown fields, types and version.
  It confers no authority.
- verifyArtifact verifies compact JWS with jose and explicitly supplied issuer,
  audience, realm, environment, local key ID and algorithm bindings. Header key
  URLs/embedded keys and unsigned/symmetric tokens are rejected. No key fetch occurs.
  Only a successful signature and exact parent/context checks create an opaque
  in-process handle. A client boolean or copied object cannot substitute for it.
- admitContract rechecks the handle, ancestor expiry, revision and local revocation.
  This is a reference admission check, not node stream/writer enforcement.
- RevisionLedger and IdempotencyLedger model rollback, same-revision conflicts and
  same-key replay without reissue. Their state is bounded and **in memory only**;
  durable server transactions/recovery are not implemented. Expired results cannot
  reactivate. Revision state is writable only after successful verification.
  Idempotency persists across credential revisions for the same Profile identity.
  Local revocation is fencing, not a server revocation receipt.
- Capacity reservations represent slots. Byte grants separately represent bounded
  byte authorization. UsageRepresentationLedger checks exact identifiers and
  cumulative report invariants per grant revision; it neither authenticates a node mTLS channel nor
  proves actual traffic, target-byte accounting, refunds or authoritative settlement.
  Old reports cannot renew send authority. Budget conservation is representation only.
- inspectConfidentialConfiguration uses jose JWE decryption and exact recipient/
  lease binding, then discards plaintext. Its result is CONFIDENTIALITY_ONLY and
  cannot become executable configuration. Encryption to a public key does not
  establish the sender. requireExecutableConfiguration always fails closed.

An explicit conservative clock interval is required; equality at expiry rejects.
Child expiry cannot exceed parent expiry, and the first slice requires connection
deadline equal to expiry. No wall-clock/monotonic-clock or restart provider is
implemented. Trusted configuration, time and native ownership inputs must come
from their owners, never renderer or request fields.

Unresolved production bindings remain concrete: algorithm/key-rotation policy,
trust roots and issuer/audience/realm values, installation possession proof,
browser recipient-key generation/storage/private delivery, and the signed
authenticity binding for encrypted configuration. No production defaults are chosen.
The tests use ES256 and RSA-OAEP-256/A256GCM only as an explicit ephemeral test suite.
HTTP/CONNECT 407 credential handling, node admission/session expiry, actual writer
paths and durable metering are outside Stage A. Exactly one selected exit is
represented; faults do not imply alternate/DIRECT fallback. guard=false; realLoop=0.

Import the package through its ESM entry point or import contract.mjs directly.
The payload drafts are enumerated in vectors.json. Signed artifact kinds are
installation-credential, profile-credential, directory, capacity-reservation,
endpoint-lease and byte-grant. Each verification takes explicit trust and context;
the caller keeps the resulting handle and supplies it as the typed parent for the
next artifact. Every ledger instance is a caller-owned local trust domain, retained
across validations. Recreating a ledger loses its rollback/revocation history.
Never persist, serialize or reconstruct handles as proof of authority.

Use the repository's fixed acceptance toolchain, Node **22.23.1** and pnpm
**9.15.0**, selected for the current process. The package engine range remains
Node >=22; the acceptance receipt records the exact tested versions.
Run only this module's tests:

~~~sh
node --version
pnpm --version
pnpm install --ignore-scripts --ignore-pnpmfile --ignore-workspace --frozen-lockfile
node --test contract.test.mjs
~~~

For this assignment the identical six files are copied into a fresh ignored
artifact runtime; dependency installation and test output stay there. Attempt02
uses the fixed acceptance toolchain and preserves all attempt01 receipts. Root
workspace/package/lock/CI files are untouched. I owns the fresh built-in review.

Dependency: jose **6.2.12**, MIT, no transitive dependencies. The lock records exact
npm integrity. Package metadata, pinned API docs, license, command receipts,
source hashes and protection receipts are retained in the Stage A artifact.

Primary references: [jose source at v6.2.12](https://github.com/panva/jose/tree/v6.2.12),
[compactVerify](https://github.com/panva/jose/blob/v6.2.12/docs/jws/compact/verify/functions/compactVerify.md),
[compactDecrypt](https://github.com/panva/jose/blob/v6.2.12/docs/jwe/compact/decrypt/functions/compactDecrypt.md),
[npm metadata](https://registry.npmjs.org/jose/6.2.12),
[Node SHA-256 API](https://nodejs.org/api/crypto.html#cryptocreatehashalgorithm-options).
