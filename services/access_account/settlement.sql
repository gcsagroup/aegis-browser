-- One-way handoff for a paid account/period. Preserve both bindings after rollover.
CREATE TABLE IF NOT EXISTS settlement_periods (
    account_id TEXT NOT NULL,
    period_id TEXT NOT NULL,
    panel_client TEXT NOT NULL,
    baseline_up INTEGER NOT NULL CHECK (baseline_up >= 0),
    baseline_down INTEGER NOT NULL CHECK (baseline_down >= 0),
    measured_at INTEGER,
    received_at INTEGER NOT NULL,
    PRIMARY KEY (account_id, period_id)
) STRICT;
CREATE TABLE IF NOT EXISTS settlement_nodes (
    account_id TEXT NOT NULL,
    period_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    -- Decimal cumulative positions may exceed SQLite's signed SUM range.
    source_up TEXT NOT NULL DEFAULT '0',
    source_down TEXT NOT NULL DEFAULT '0',
    uploaded TEXT NOT NULL DEFAULT '0',
    downloaded TEXT NOT NULL DEFAULT '0',
    measured_at INTEGER,
    received_at INTEGER,
    PRIMARY KEY (account_id, period_id, node_id)
) STRICT;
