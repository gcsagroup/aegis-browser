-- Additive S3 migration: run only when the managed node issuer is enabled.
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS node_credentials (
    credential_id TEXT PRIMARY KEY,
    token_hash BLOB NOT NULL CHECK(length(token_hash) = 32),
    account_id TEXT NOT NULL,
    plan_id TEXT NOT NULL,
    period_id TEXT NOT NULL,
    period_start INTEGER NOT NULL,
    period_end INTEGER NOT NULL,
    panel_client TEXT NOT NULL,
    node_id TEXT NOT NULL,
    context_id TEXT NOT NULL,
    mode TEXT NOT NULL CHECK(mode IN ('regular', 'private')),
    password_hash BLOB NOT NULL CHECK(length(password_hash) = 32),
    expires_at INTEGER NOT NULL,
    revoked INTEGER NOT NULL DEFAULT 0 CHECK(revoked IN (0, 1))
) STRICT;
-- Upgrade the original account-wide scope without deleting credential records.
DROP INDEX IF EXISTS node_credentials_scope;
CREATE UNIQUE INDEX IF NOT EXISTS node_credentials_session_scope
    ON node_credentials(token_hash, node_id, context_id, mode) WHERE revoked = 0;
CREATE INDEX IF NOT EXISTS node_credentials_expiry ON node_credentials(expires_at);
-- Fence a remote read even if an operator changes then restores a binding.
CREATE TABLE IF NOT EXISTS node_authority_versions (
    account_id TEXT PRIMARY KEY,
    version INTEGER NOT NULL
) STRICT;
-- Deletion/recreation and revoke/unrevoke must not resurrect old grants.
CREATE TRIGGER IF NOT EXISTS node_session_update AFTER UPDATE ON sessions BEGIN
    UPDATE node_credentials SET revoked=1 WHERE token_hash=OLD.token_hash;
    INSERT INTO node_authority_versions VALUES (OLD.account_id, 1)
        ON CONFLICT(account_id) DO UPDATE SET version=version+1;
END;
CREATE TRIGGER IF NOT EXISTS node_session_delete AFTER DELETE ON sessions BEGIN
    UPDATE node_credentials SET revoked=1 WHERE token_hash=OLD.token_hash;
    INSERT INTO node_authority_versions VALUES (OLD.account_id, 1)
        ON CONFLICT(account_id) DO UPDATE SET version=version+1;
END;
CREATE TRIGGER IF NOT EXISTS node_plan_update AFTER UPDATE ON plans BEGIN
    UPDATE node_credentials SET revoked=1 WHERE account_id=OLD.account_id;
    INSERT INTO node_authority_versions VALUES (OLD.account_id, 1)
        ON CONFLICT(account_id) DO UPDATE SET version=version+1;
END;
CREATE TRIGGER IF NOT EXISTS node_plan_delete AFTER DELETE ON plans BEGIN
    UPDATE node_credentials SET revoked=1 WHERE account_id=OLD.account_id;
    INSERT INTO node_authority_versions VALUES (OLD.account_id, 1)
        ON CONFLICT(account_id) DO UPDATE SET version=version+1;
END;
COMMIT;
