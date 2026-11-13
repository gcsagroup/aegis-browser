"""Read the authenticated account and its current plan from the operator's store."""

import hashlib
from contextlib import closing
from pathlib import Path
import sqlite3


class Unavailable(Exception):
    """No trustworthy current entitlement can be read."""


CURRENT_ACCOUNT_SQL = """
    SELECT a.id, t.expires_at AS session_expiry, p.plan_id, p.period_id, p.period_start, p.period_end, p.panel_client,
           s.quota_bytes, s.uploaded_bytes, s.downloaded_bytes,
           s.expires_at, s.measured_at, s.received_at
    FROM sessions AS t
    JOIN accounts AS a ON a.id = t.account_id
    LEFT JOIN plans AS p ON p.account_id = a.id
    LEFT JOIN snapshots AS s ON s.account_id = p.account_id AND s.period_id = p.period_id
    WHERE t.token_hash = ? AND t.revoked_at IS NULL AND t.expires_at > ?
"""


def _response(account, usage, now):
    plan = account["plan_id"]
    result = dict(entitlementAccountId=account["id"], status="not_subscribed",
                  planId=plan, periodId=account["period_id"], periodStart=account["period_start"],
                  periodEnd=account["period_end"], expiresAt=None, quotaBytes=None,
                  uploadedBytes=None, downloadedBytes=None, usedBytes=None, remainingBytes=None,
                  measuredAt=None, receivedAt=None, snapshotAgeMs=None, freshness=None)
    if plan is None:
        return result
    received, measured = usage["received_at"], usage["measured_at"]
    if (received is None or not account["period_start"] <= received <= now
            or measured is not None and measured < account["period_start"]):
        raise Unavailable("current period or snapshot unavailable")

    quota = usage["quota_bytes"]
    up, down = usage["uploaded_bytes"], usage["downloaded_bytes"]
    expiry = usage["expires_at"]
    if "quota_source" in usage.keys() and usage["quota_source"] == "3xui_alpha":
        result.update(quotaSource="3xui_alpha",
                      panelExpiryMode="none" if expiry == 0 else "absolute",
                      panelExpiresAt=None if expiry == 0 else expiry)
        # A panel without an expiry never grants an unbounded local authorization.
        expiry = account["period_end"] if expiry == 0 else min(account["period_end"], expiry)
    used = up + down
    if now >= min(account["period_end"], expiry):
        status = "expired"
    elif used >= quota:
        status = "exhausted"
    else:
        status = "active"
    age = None if measured is None else now - measured
    freshness = ("unavailable" if age is None or age > 15000 else
                 "delayed" if age > 5000 else "current")
    result.update(status=status, expiresAt=expiry, quotaBytes=str(quota),
                  uploadedBytes=str(up), downloadedBytes=str(down), usedBytes=str(used),
                  remainingBytes=str(max(0, quota - used)), measuredAt=measured,
                  receivedAt=received, snapshotAgeMs=age, freshness=freshness)
    return result


def read_current(database_path, token, clock_ms, *, panel=None):
    """Resolve identity afresh and recheck it after any remote panel request."""
    if not isinstance(token, str) or not token or not token.isascii():
        return None
    digest = hashlib.sha256(token.encode("ascii")).digest()
    uri = Path(database_path).absolute().as_uri() + "?mode=ro"
    try:
        with closing(sqlite3.connect(uri, uri=True)) as db:
            db.row_factory = sqlite3.Row
            now = clock_ms()
            account = db.execute(CURRENT_ACCOUNT_SQL, (digest, now)).fetchone()
            if account is None:
                return None
            if panel is None or account["plan_id"] is None:
                return _response(account, account, now)
            observed = panel.read(account["panel_client"], clock_ms)
            now = clock_ms()
            current = db.execute(CURRENT_ACCOUNT_SQL, (digest, now)).fetchone()
            if current is None:
                return None
            if any(current[k] != account[k] for k in
                   ("id", "plan_id", "period_id", "period_start", "period_end", "panel_client")):
                raise Unavailable("account or plan changed during panel read")
            return _response(current, observed, now)
    except sqlite3.Error as error:
        raise Unavailable("account store unavailable") from error
