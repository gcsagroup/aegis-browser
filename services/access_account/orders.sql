-- Additive S2 migration: safe to repeat on an existing S1 database.
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS sandbox_orders (
    order_id TEXT PRIMARY KEY CHECK (length(order_id) BETWEEN 1 AND 128),
    account_id TEXT NOT NULL REFERENCES accounts(id),
    plan_id TEXT NOT NULL CHECK (length(plan_id) > 0),
    period_id TEXT NOT NULL CHECK (length(period_id) > 0),
    panel_client TEXT NOT NULL CHECK (length(panel_client) > 0),
    quota_bytes INTEGER NOT NULL CHECK (quota_bytes BETWEEN 1 AND 9223372036854775807),
    duration_ms INTEGER NOT NULL CHECK (duration_ms BETWEEN 1 AND 9007199254740991),
    paid INTEGER NOT NULL CHECK (paid IN (0, 1))
) STRICT;
CREATE TABLE IF NOT EXISTS sandbox_grants (
    order_id TEXT PRIMARY KEY REFERENCES sandbox_orders(order_id),
    granted_at INTEGER NOT NULL CHECK (granted_at BETWEEN 0 AND 9007199254740991)
) STRICT;
-- Replace the earlier S2 trigger too, retaining all existing orders and receipts.
DROP TRIGGER IF EXISTS immutable_sandbox_order_update;
CREATE TRIGGER immutable_sandbox_order_update
BEFORE UPDATE ON sandbox_orders
WHEN (OLD.order_id, OLD.account_id, OLD.plan_id, OLD.period_id, OLD.panel_client,
      OLD.quota_bytes, OLD.duration_ms) <>
     (NEW.order_id, NEW.account_id, NEW.plan_id, NEW.period_id, NEW.panel_client,
      NEW.quota_bytes, NEW.duration_ms)
     OR NEW.paid < OLD.paid
BEGIN
    SELECT RAISE(ABORT, 'confirmed order terms are immutable');
END;
CREATE TRIGGER IF NOT EXISTS immutable_sandbox_order_delete
BEFORE DELETE ON sandbox_orders BEGIN
    SELECT RAISE(ABORT, 'retain order identity');
END;
CREATE TRIGGER IF NOT EXISTS immutable_sandbox_grant_update
BEFORE UPDATE ON sandbox_grants BEGIN
    SELECT RAISE(ABORT, 'retain grant receipt');
END;
CREATE TRIGGER IF NOT EXISTS immutable_sandbox_grant_delete
BEFORE DELETE ON sandbox_grants BEGIN
    SELECT RAISE(ABORT, 'retain grant receipt');
END;
COMMIT;
