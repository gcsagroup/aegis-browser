"""Local trusted-node cumulative settlement for managed account/period bindings."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys
import time


def _now():
    return time.time_ns() // 1_000_000


def _installed(db):
    return db.execute("SELECT 1 FROM sqlite_schema WHERE type='table' AND name='settlement_periods'").fetchone()


def period(db, account, period_id):
    if period_id is None or not _installed(db):
        return None
    return db.execute('SELECT * FROM settlement_periods WHERE account_id=? AND period_id=?',
                      (account, period_id)).fetchone()


def _node(db, key):
    return db.execute('SELECT * FROM settlement_nodes WHERE account_id=? AND period_id=? AND node_id=?',
                      key).fetchone()


def admitted(db, account, period_id, node):
    return _node(db, (account, period_id, node)) is not None


def bind(database, config, account, period_id, now):
    from . import metering
    from .store import _response
    meter = metering.Meter(database, config)
    with closing(metering._connect(database, 'rw')) as db:
        db.executescript('BEGIN IMMEDIATE;\n' + Path(__file__).with_suffix('.sql').read_text())
        row = db.execute('SELECT p.*, p.account_id AS id, s.* FROM plans p '
                         'JOIN panel_bindings b USING(account_id,period_id,panel_client) '
                         'JOIN snapshots s USING(account_id,period_id) WHERE p.account_id=? AND p.period_id=?',
                         (account, period_id)).fetchone()
        if row is None or row['panel_client'] not in meter.clients:
            raise ValueError('missing authorized plan binding')
        if admitted(db, account, period_id, meter.node):
            db.commit()
            return
        # Existing transfers may already be included in the opening snapshot. Without an
        # explicit reconciled cutover, attribution of those bytes would be ambiguous.
        if db.execute('SELECT 1 FROM node_meter_flows WHERE node_id=? AND account_id=? AND period_id=? '
                      'AND (uploaded>0 OR downloaded>0) LIMIT 1', (meter.node, account, period_id)).fetchone():
            raise ValueError('provision node settlement before its first measured byte')
        if not period(db, account, period_id):
            _response(row, row, now)
            db.execute('INSERT INTO settlement_periods VALUES (?,?,?,?,?,?,?)',
                       (account, period_id, row['panel_client'], row['uploaded_bytes'],
                        row['downloaded_bytes'], row['measured_at'], row['received_at']))
        db.execute('INSERT INTO settlement_nodes (account_id,period_id,node_id) VALUES (?,?,?)',
                   (account, period_id, meter.node))
        db.commit()


def _confirm(db, key, row, up, down, measured, now):
    if (type(up) is not int or type(down) is not int or min(up, down) < 0
            or up > int(row['source_up']) or down > int(row['source_down'])
            or type(measured) is not int or not 0 <= measured <= now):
        raise ValueError('unsupported node watermark')
    up, down = max(up, int(row['uploaded'])), max(down, int(row['downloaded']))
    if (up, down) == (int(row['uploaded']), int(row['downloaded'])):
        return
    db.execute('UPDATE settlement_nodes SET uploaded=?, downloaded=?, measured_at=?, received_at=? '
               'WHERE account_id=? AND period_id=? AND node_id=?',
               (str(up), str(down), max(row['measured_at'] or 0, measured), max(row['received_at'] or 0, now), *key))


def advance(db, node, account, period_id, up_delta, down_delta, measured, now):
    """Apply N1 durable flow advancement and local delivery within the writer transaction."""
    if period(db, account, period_id) is None:
        return
    key = account, period_id, node
    row = _node(db, key)
    if row is None:
        raise ValueError('node not admitted for settled period')
    if not (up_delta or down_delta):
        return
    up, down = int(row['source_up']) + up_delta, int(row['source_down']) + down_delta
    db.execute('UPDATE settlement_nodes SET source_up=?,source_down=? '
               'WHERE account_id=? AND period_id=? AND node_id=?', (str(up), str(down), *key))
    _confirm(db, key, _node(db, key), up, down, measured, now)


def replay(database, config, account, period_id, up, down, measured, now):
    from .credentials import ManagedNode
    from .metering import _connect
    node = ManagedNode.from_config(config, 'localhost', 1)
    key = account, period_id, node.node_id
    with closing(_connect(database, 'rw')) as db:
        db.execute('BEGIN IMMEDIATE')
        binding = period(db, account, period_id)
        row = _node(db, key) if binding is not None else None
        if row is None or binding['panel_client'] not in node.admitted_clients:
            raise ValueError('unknown trusted binding')
        _confirm(db, key, row, up, down, measured, now)
        db.commit()


def reading(db, account, binding):
    """Snapshot terms remain the order authority. Traffic comes solely from retained counters."""
    if (account['quota_bytes'] is None or account['expires_at'] is None
            or account['panel_client'] != binding['panel_client']):
        from .store import Unavailable
        raise Unavailable('missing managed plan terms')
    up, down = binding['baseline_up'], binding['baseline_down']
    measured, received = binding['measured_at'], binding['received_at']
    rows = db.execute('SELECT uploaded, downloaded, measured_at, received_at FROM settlement_nodes '
                      'WHERE account_id=? AND period_id=?', (binding['account_id'], binding['period_id'])).fetchall()
    if not rows:
        from .store import Unavailable
        raise Unavailable('missing managed node positions')
    for row in rows:
        up += int(row['uploaded'])
        down += int(row['downloaded'])
        if row['measured_at'] is not None:
            measured = max(measured or 0, row['measured_at'])
            received = max(received, row['received_at'])
    return dict(quota_bytes=account['quota_bytes'], expires_at=account['expires_at'],
                uploaded_bytes=up, downloaded_bytes=down, measured_at=measured, received_at=received)


def authority(db, account_id, period_id, now):
    """Return active confirmed terms/totals inside the caller's transaction, else None."""
    binding = period(db, account_id, period_id)
    if binding is None:
        return None
    account = db.execute('SELECT p.*, s.quota_bytes, s.expires_at FROM plans p '
                         'JOIN snapshots s USING(account_id,period_id) WHERE p.account_id=? AND p.period_id=?',
                         (account_id, period_id)).fetchone()
    if account is None:
        return None
    result = reading(db, account, binding)
    result['expires_at'] = min(result['expires_at'], account['period_end'])
    if not account['period_start'] <= now < result['expires_at'] or result['received_at'] > now:
        return None
    return result if result['uploaded_bytes'] + result['downloaded_bytes'] < result['quota_bytes'] else None


def main():
    from .store import Unavailable
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    for name in ('bind', 'replay'):
        cmd = subs.add_parser(name)
        for arg in ('database', 'config', 'account', 'period'):
            cmd.add_argument('--' + arg, required=True)
        if name == 'replay':
            for arg in ('uploaded', 'downloaded', 'measured-at'):
                cmd.add_argument('--' + arg, required=True, type=int)
    args = parser.parse_args()
    try:
        config = json.loads(Path(args.config).read_text())
        identity = args.database, config, args.account, args.period
        if args.command == 'bind':
            bind(*identity, _now())
        else:
            replay(*identity, args.uploaded, args.downloaded, args.measured_at, _now())
    except (ValueError, sqlite3.Error, OSError, Unavailable):
        sys.exit('settlement unavailable')
    print('{"ok":true}')


if __name__ == '__main__':
    main()
