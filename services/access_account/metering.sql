-- Each row belongs to one authenticated target stream and survives plan rollover.
CREATE TABLE IF NOT EXISTS node_meter_flows (
    node_id TEXT NOT NULL,
    flow_id TEXT NOT NULL,
    panel_client TEXT NOT NULL,
    account_id TEXT NOT NULL,
    period_id TEXT NOT NULL,
    uploaded INTEGER NOT NULL DEFAULT 0 CHECK (uploaded >= 0),
    downloaded INTEGER NOT NULL DEFAULT 0 CHECK (downloaded >= 0),
    target_tcp INTEGER NOT NULL DEFAULT 0 CHECK (target_tcp >= 0),
    vision_padded INTEGER NOT NULL DEFAULT 0 CHECK (vision_padded >= 0),
    vision_plain INTEGER NOT NULL DEFAULT 0 CHECK (vision_plain >= 0),
    vision_raw INTEGER NOT NULL DEFAULT 0 CHECK (vision_raw >= 0),
    sampled_at INTEGER,
    state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','complete','incomplete')),
    PRIMARY KEY (node_id, flow_id)
) STRICT;
CREATE INDEX IF NOT EXISTS node_meter_usage ON node_meter_flows(node_id, period_id, account_id);

-- A timed-out OPEN may reach SQLite after its recovery ABORT on another socket.
CREATE TABLE IF NOT EXISTS node_meter_aborts (
    node_id TEXT NOT NULL,
    flow_id TEXT NOT NULL,
    PRIMARY KEY(node_id,flow_id)
) STRICT;
