CREATE TABLE IF NOT EXISTS quota_flows (
    node_id TEXT NOT NULL,
    flow_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    period_id TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    cut_at INTEGER,
    reason TEXT,
    PRIMARY KEY (node_id, flow_id)
) STRICT;
CREATE INDEX IF NOT EXISTS quota_period ON quota_flows(account_id, period_id, cut_at);

-- A writer has at most one unresolved ticket per direction. Keep its latest
-- receipt and cumulative history after close or restart.
CREATE TABLE IF NOT EXISTS quota_writers (
    node_id TEXT NOT NULL,
    flow_id TEXT NOT NULL,
    direction TEXT NOT NULL CHECK(direction IN ('up','down')),
    ticket INTEGER NOT NULL,
    path TEXT NOT NULL,
    requested INTEGER NOT NULL,
    granted INTEGER NOT NULL,
    deadline INTEGER NOT NULL,
    confirmed INTEGER,
    complete INTEGER CHECK(complete IN (0,1)),
    held INTEGER NOT NULL CHECK(held >= 0),
    confirmed_total INTEGER NOT NULL,
    released_total INTEGER NOT NULL,
    PRIMARY KEY (node_id, flow_id, direction)
) STRICT;

CREATE TABLE IF NOT EXISTS quota_holds (
    account_id TEXT NOT NULL,
    period_id TEXT NOT NULL,
    held INTEGER NOT NULL CHECK(held >= 0),
    PRIMARY KEY (account_id,period_id)
) STRICT;
CREATE TRIGGER IF NOT EXISTS quota_initial_hold AFTER INSERT ON quota_writers BEGIN
    INSERT INTO quota_holds(account_id,period_id,held)
    SELECT account_id,period_id,NEW.held FROM quota_flows
    WHERE node_id=NEW.node_id AND flow_id=NEW.flow_id
    ON CONFLICT(account_id,period_id) DO UPDATE SET held=held+excluded.held;
END;
CREATE TRIGGER IF NOT EXISTS quota_change_hold AFTER UPDATE OF held ON quota_writers BEGIN
    UPDATE quota_holds SET held=held+(NEW.held-OLD.held)
    WHERE (account_id,period_id)=(SELECT account_id,period_id FROM quota_flows
        WHERE node_id=NEW.node_id AND flow_id=NEW.flow_id);
END;
