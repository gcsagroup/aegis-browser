PRAGMA foreign_keys = ON;
BEGIN;

CREATE TABLE accounts (
    id TEXT PRIMARY KEY CHECK (length(id) > 0)
) STRICT;

CREATE TABLE sessions (
    token_hash BLOB PRIMARY KEY CHECK (length(token_hash) = 32),
    account_id TEXT NOT NULL REFERENCES accounts(id),
    expires_at INTEGER NOT NULL CHECK (expires_at BETWEEN 1 AND 9007199254740991),
    revoked_at INTEGER CHECK (revoked_at BETWEEN 0 AND 9007199254740991)
) STRICT;

-- Retain the source identity even when a plan is removed or rolls over:
-- cumulative panel traffic must never be inherited by another account/period.
CREATE TABLE panel_bindings (
    panel_client TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    period_id TEXT NOT NULL,
    UNIQUE (account_id, period_id)
) STRICT;

CREATE TABLE plans (
    account_id TEXT PRIMARY KEY REFERENCES accounts(id),
    plan_id TEXT NOT NULL CHECK (length(plan_id) > 0),
    period_id TEXT NOT NULL CHECK (length(period_id) > 0),
    period_start INTEGER NOT NULL CHECK (period_start BETWEEN 0 AND 9007199254740991),
    period_end INTEGER NOT NULL CHECK (period_end BETWEEN period_start + 1 AND 9007199254740991),
    panel_client TEXT NOT NULL UNIQUE CHECK (length(panel_client) > 0),
    UNIQUE (account_id, period_id)
) STRICT;

CREATE TRIGGER bind_panel_client BEFORE INSERT ON plans BEGIN
    SELECT RAISE(ABORT, 'panel client previously bound') WHERE EXISTS (
        SELECT 1 FROM panel_bindings WHERE panel_client = NEW.panel_client
        AND (account_id <> NEW.account_id OR period_id <> NEW.period_id)
    );
    INSERT INTO panel_bindings VALUES (NEW.panel_client, NEW.account_id, NEW.period_id)
        ON CONFLICT(panel_client) DO NOTHING;
END;
-- Reprovision binding changes by deleting the old plan (and snapshot)
-- and inserting the new one transactionally, never by relabeling old totals.
CREATE TRIGGER immutable_plan_binding BEFORE UPDATE OF account_id, period_id, panel_client ON plans
WHEN (OLD.account_id, OLD.period_id, OLD.panel_client) <> (NEW.account_id, NEW.period_id, NEW.panel_client)
BEGIN
    SELECT RAISE(ABORT, 'replace plan binding');
END;

CREATE TABLE snapshots (
    account_id TEXT PRIMARY KEY,
    period_id TEXT NOT NULL,
    quota_bytes INTEGER NOT NULL CHECK (quota_bytes >= 0),
    uploaded_bytes INTEGER NOT NULL CHECK (uploaded_bytes >= 0),
    downloaded_bytes INTEGER NOT NULL CHECK (downloaded_bytes >= 0),
    expires_at INTEGER NOT NULL CHECK (expires_at BETWEEN 1 AND 9007199254740991),
    measured_at INTEGER CHECK (measured_at BETWEEN 0 AND received_at),
    received_at INTEGER NOT NULL CHECK (received_at BETWEEN 0 AND 9007199254740991),
    FOREIGN KEY (account_id, period_id) REFERENCES plans(account_id, period_id) ON DELETE CASCADE
) STRICT;
COMMIT;
