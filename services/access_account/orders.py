"""Operator-controlled sandbox orders. No payment provider or public callback."""

import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3

from .store import Unavailable, _response


class Rejected(Exception):
    """Order is unknown, unpaid, owned by another account, or incompatible."""


def connect(path):
    # Never create a new/empty authority by mistyping a database path.
    db = sqlite3.connect(Path(path).absolute().as_uri() + '?mode=rw', uri=True,
                         timeout=5, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA foreign_keys = ON')
    return db


def migrate(path):
    with closing(connect(path)) as db:
        db.executescript(Path(__file__).with_name('orders.sql').read_text())


def record(path, *, order_id, account_id, plan_id, period_id, panel_client,
           quota_bytes, duration_ms, paid):
    """Import immutable terms and monotonically confirm payment as the operator."""
    values = (order_id, account_id, plan_id, period_id, panel_client,
              quota_bytes, duration_ms, int(paid))
    with closing(connect(path)) as db, db:
        db.execute('BEGIN IMMEDIATE')
        old = db.execute('SELECT * FROM sandbox_orders WHERE order_id=?', (order_id,)).fetchone()
        if old is not None:
            if tuple(old)[:-1] != values[:-1]:
                raise Rejected('order identity already has different terms')
            if paid and not old['paid']:
                db.execute('UPDATE sandbox_orders SET paid=1 WHERE order_id=?', (order_id,))
            return
        db.execute('INSERT INTO sandbox_orders VALUES (?,?,?,?,?,?,?,?)', values)


def redeem(path, token, order_id, clock_ms):
    """Serialize authentication, trusted verification, grant and receipt in one commit."""
    if not isinstance(token, str) or not token or not token.isascii():
        return None
    if not isinstance(order_id, str) or not 1 <= len(order_id) <= 128:
        raise Rejected('invalid order')
    try:
        order_id.encode('utf-8')
    except UnicodeEncodeError as error:
        raise Rejected('invalid order') from error
    try:
        with closing(connect(path)) as db, db:
            db.execute('BEGIN IMMEDIATE')
            now = clock_ms()
            account = db.execute(
                'SELECT account_id FROM sessions WHERE token_hash=? '
                'AND revoked_at IS NULL AND expires_at>?',
                (hashlib.sha256(token.encode('ascii')).digest(), now)).fetchone()
            if account is None:
                return None
            order = db.execute('SELECT * FROM sandbox_orders WHERE order_id=?', (order_id,)).fetchone()
            if order is None or not order['paid'] or order['account_id'] != account[0]:
                raise Rejected('order unavailable')
            receipt = db.execute('SELECT granted_at FROM sandbox_grants WHERE order_id=?',
                                 (order_id,)).fetchone()
            if receipt is not None:
                return dict(orderId=order_id, grantedAt=receipt[0], mode='sandbox')
            plan = db.execute('SELECT *, account_id AS id FROM plans WHERE account_id=?',
                              (account[0],)).fetchone()
            if plan is None:
                expiry = now + order['duration_ms']
                db.execute('INSERT INTO plans VALUES (?,?,?,?,?,?)',
                           (account[0], order['plan_id'], order['period_id'], now, expiry,
                            order['panel_client']))
                db.execute('INSERT INTO snapshots VALUES (?,?,?,?,?,?,?,?)',
                           (account[0], order['period_id'], order['quota_bytes'], 0, 0,
                            expiry, now, now))
            else:
                if any(plan[k] != order[k] for k in ('plan_id', 'period_id', 'panel_client')):
                    raise Rejected('order binding differs from current plan')
                snapshot = db.execute('SELECT * FROM snapshots WHERE account_id=? AND period_id=?',
                                      (account[0], plan['period_id'])).fetchone()
                if snapshot is None:
                    raise Unavailable('snapshot missing')
                _response(plan, snapshot, now)  # Preserve S1 source validity checks.
                effective_expiry = min(plan['period_end'], snapshot['expires_at'])
                expiry = max(now, effective_expiry) + order['duration_ms']
                quota = snapshot['quota_bytes'] + order['quota_bytes']
                db.execute('UPDATE plans SET period_end=? WHERE account_id=?', (expiry, account[0]))
                # Purchasing is not a traffic measurement: retain counters and their timestamps.
                db.execute('UPDATE snapshots SET quota_bytes=?, expires_at=? WHERE account_id=?',
                           (quota, expiry, account[0]))
            db.execute('INSERT INTO sandbox_grants VALUES (?,?)', (order_id, now))
            return dict(orderId=order_id, grantedAt=now, mode='sandbox')
    except (sqlite3.Error, OverflowError) as error:
        raise Unavailable('order store unavailable') from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('migrate')
    add = sub.add_parser('record')
    for name in ('order-id', 'account-id', 'plan-id', 'period-id', 'panel-client'):
        add.add_argument('--' + name, required=True)
    for name in ('quota-bytes', 'duration-ms'):
        add.add_argument('--' + name, required=True, type=int)
    add.add_argument('--paid', action='store_true', help='operator confirms sandbox payment')
    args = vars(parser.parse_args())
    path, command = args.pop('database'), args.pop('command')
    migrate(path)
    if command == 'record':
        record(path, **args)
    print(json.dumps({'mode': 'sandbox', 'result': 'ok'}))


if __name__ == '__main__':
    main()
