"""Local Xray writer acknowledgements and operator usage reads (N1)."""

import argparse
import asyncio
from contextlib import closing
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import stat
import sys
import time

from . import settlement
from .credentials import ManagedNode

PATHS = {'up': ('target_tcp',), 'down': ('vision_padded', 'vision_plain', 'vision_raw')}
ALL_PATHS = PATHS['up'] + PATHS['down']
DIRECTION = {'up': 'uploaded', 'down': 'downloaded'}
MAX_BYTES = 2**63 - 1
FRAME_LIMIT = 4096


def _connect(database, mode):
    db = sqlite3.connect(Path(database).absolute().as_uri() + '?mode=' + mode,
                         uri=True, isolation_level=None)
    db.row_factory = sqlite3.Row
    return db


def _count(n):
    return type(n) is int and 0 <= n <= MAX_BYTES


def _unique(pairs):
    data = dict(pairs)
    if len(data) != len(pairs):
        raise ValueError('duplicate field')
    return data


def _validate(frame):
    if (not isinstance(frame, dict) or type(frame.get('v')) is not int or frame['v'] != 1
            or not isinstance(frame.get('flow'), str)
            or not re.fullmatch('[0-9a-f]{32}', frame['flow'])):
        raise ValueError('invalid frame')
    if 'measuredAt' in frame:
        if (frame.get('op') != 'sample' or not _count(frame['measuredAt'])
                or frame['measuredAt'] == 0):
            raise ValueError('invalid measurement instant')
        frame = {k:v for k,v in frame.items() if k != 'measuredAt'}
    op = frame.get('op')
    extra = set(frame) - {'v', 'op', 'flow'}
    if op == 'abort' and not extra:
        return
    if op == 'open' and extra == {'client'} and isinstance(frame['client'], str):
        return
    if op == 'sample' and extra == {'direction', 'bytes', 'path', 'pathBytes'}:
        direction = frame['direction']
        if (isinstance(direction, str) and frame['path'] in PATHS.get(direction, ())
                and _count(frame['bytes']) and _count(frame['pathBytes'])
                and frame['pathBytes'] <= frame['bytes']
                and (direction != 'up' or frame['pathBytes'] == frame['bytes'])):
            return
    if op == 'finish' and extra == {'uploadedBytes', 'downloadedBytes', 'complete'}:
        if (_count(frame['uploadedBytes']) and _count(frame['downloadedBytes'])
                and type(frame['complete']) is bool):
            return
    raise ValueError('invalid frame')


class Meter:
    def __init__(self, database, config, clock_ms=lambda: time.time_ns() // 1_000_000):
        node = ManagedNode.from_config(config, 'localhost', 1)
        self.node = node.node_id
        self.clients = node.admitted_clients
        self.database = database
        self.clock_ms = clock_ms
        with closing(_connect(database, 'rw')) as db:
            db.execute('SELECT panel_client, account_id, period_id FROM panel_bindings LIMIT 0')
            db.executescript('BEGIN IMMEDIATE;\n' + Path(__file__).with_suffix('.sql').read_text()
                             + '\nCOMMIT;')

    def accept(self, frame):
        _validate(frame)
        with closing(_connect(self.database, 'rw')) as db:
            db.execute('PRAGMA synchronous=FULL')
            db.execute('BEGIN IMMEDIATE')
            self._apply(db, frame, self.clock_ms())
            db.commit()

    def _apply(self, db, frame, now):
        """Apply a validated writer frame inside an existing immediate transaction."""
        key = (self.node, frame['flow'])
        row = db.execute('SELECT * FROM node_meter_flows WHERE node_id=? AND flow_id=?',
                         key).fetchone()
        if frame['op'] == 'open':
            if db.execute('SELECT 1 FROM node_meter_aborts WHERE node_id=? AND flow_id=?',
                          key).fetchone():
                raise ValueError('opening previously aborted')
            client = frame['client']
            if client not in self.clients or row is not None and row['panel_client'] != client:
                raise ValueError('unknown binding')
            if row is None:
                binding = db.execute('SELECT b.account_id, b.period_id FROM panel_bindings b '
                                     'JOIN plans p USING (panel_client,account_id,period_id) '
                                     'WHERE b.panel_client=? AND p.period_start<=? AND p.period_end>?',
                                     (client, now, now)).fetchone()
                if binding is None:
                    raise ValueError('inactive binding')
                db.execute('INSERT INTO node_meter_flows '
                           '(node_id,flow_id,panel_client,account_id,period_id) VALUES (?,?,?,?,?)',
                           (*key, client, *binding))
        elif frame['op'] == 'abort':
            db.execute('INSERT INTO node_meter_aborts VALUES (?,?) ON CONFLICT DO NOTHING', key)
            if row is None:
                return
            self._finish(db, key, row, dict(uploadedBytes=0, downloadedBytes=0, complete=True), now)
        elif row is None:
            raise ValueError('unknown flow')
        elif frame['op'] == 'sample':
            stamp = frame.get('measuredAt', now)
            if stamp > now:
                raise ValueError('future measurement')
            self._sample(db, key, row, frame, stamp)
        else:
            self._finish(db, key, row, frame, now)
        new = db.execute('SELECT * FROM node_meter_flows WHERE node_id=? AND flow_id=?', key).fetchone()
        settlement.advance(db, self.node, new['account_id'], new['period_id'],
                           new['uploaded'] - (row['uploaded'] if row else 0),
                           new['downloaded'] - (row['downloaded'] if row else 0), new['sampled_at'], now)

    @staticmethod
    def _sample(db, key, row, frame, now):
        column = DIRECTION[frame['direction']]
        path = frame['path']
        total = max(row[column], frame['bytes'])
        n = max(row[path], frame['pathBytes'])
        if total == row[column] and n == row[path]:
            return
        path_sum = n + sum(row[p] for p in PATHS[frame['direction']] if p != path)
        if row['state'] != 'open' or path_sum > total:
            raise ValueError('invalid watermark')
        # Both identifiers come exclusively from the validated direction/path contract.
        db.execute(f'UPDATE node_meter_flows SET {column}=?, {path}=?, sampled_at=? '
                   'WHERE node_id=? AND flow_id=?', (total, n, max(now, row['sampled_at'] or 0), *key))

    @staticmethod
    def _finish(db, key, row, frame, now):
        up, down = frame['uploadedBytes'], frame['downloadedBytes']
        state = 'complete' if frame['complete'] else 'incomplete'
        if row['state'] != 'open':
            if (row['uploaded'], row['downloaded'], row['state']) != (up, down, state):
                raise ValueError('terminal conflict')
            return
        if (up < row['uploaded'] or down < row['downloaded']
                or frame['complete'] and (up != row['target_tcp']
                                         or down != sum(row[p] for p in PATHS['down']))):
            raise ValueError('invalid final watermark')
        stamp = row['sampled_at']
        if up > row['uploaded'] or down > row['downloaded']:
            stamp = max(now, stamp or 0)
        db.execute('UPDATE node_meter_flows SET uploaded=?, downloaded=?, sampled_at=?, state=? '
                   'WHERE node_id=? AND flow_id=?', (up, down, stamp, state, *key))


def _totals():
    return dict(uploadedBytes=0, downloadedBytes=0, sampledAt=None, openFlows=0, incompleteFlows=0,
                pathBytes=dict.fromkeys(ALL_PATHS, 0))


def usage(database, node, period=None):
    totals = _totals()
    accounts = {}
    with closing(_connect(database, 'ro')) as db:
        # One read snapshot. Python integers preserve sums beyond SQLite's signed SUM range.
        query = 'SELECT * FROM node_meter_flows WHERE node_id=?'
        params = (node,)
        if period is not None:
            query += ' AND period_id=?'
            params += (period,)
        rows = db.execute(query + ' ORDER BY account_id, period_id', params)
        for row in rows:
            key = (row['account_id'], row['period_id'])
            account = accounts.get(key)
            if account is None:
                account = accounts[key] = dict(accountId=key[0], periodId=key[1], **_totals())
            for out in (account, totals):
                out['uploadedBytes'] += row['uploaded']
                out['downloadedBytes'] += row['downloaded']
                out['openFlows'] += row['state'] == 'open'
                out['incompleteFlows'] += row['state'] == 'incomplete'
                if row['sampled_at'] is not None:
                    out['sampledAt'] = max(row['sampled_at'], out['sampledAt'] or 0)
                for path in ALL_PATHS:
                    out['pathBytes'][path] += row[path]
    return dict(nodeId=node, periodId=period, accounts=list(accounts.values()), **totals)


async def _handle(reader, writer, meter):
    try:
        while True:
            try:
                line = await reader.readline()
                if not line:
                    return
                if len(line) > FRAME_LIMIT or not line.endswith(b'\n'):
                    raise ValueError('invalid frame')
                data = json.loads(line.decode('utf-8'), object_pairs_hook=_unique)
                reply = await asyncio.to_thread(meter.accept, data)
            except (ValueError, RecursionError, sqlite3.Error):
                writer.write(b'{"ok":false}\n')
                await writer.drain()
                return
            writer.write(json.dumps(reply or {"ok": True}, separators=(",", ":")).encode() + b"\n")
            await writer.drain()
    except OSError:
        pass
    finally:
        writer.close()


async def serve(meter, path):
    path = Path(path)
    parent = path.parent.stat()
    if parent.st_uid != os.geteuid() or stat.S_IMODE(parent.st_mode) != 0o700:
        raise ValueError('socket requires an owned directory with mode 0700')
    # Explicit bind never replaces an active listener or an operator-owned entry.
    with socket.socket(socket.AF_UNIX) as sock:
        sock.bind(str(path))
        inode = path.lstat().st_ino
        try:
            path.chmod(0o600)
            listener = await asyncio.start_unix_server(
                lambda r, w: _handle(r, w, meter), sock=sock, limit=FRAME_LIMIT)
            async with listener:
                await listener.serve_forever()
        finally:
            if path.exists() and path.lstat().st_ino == inode:
                path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name, flags in [('serve', ('config', 'socket')), ('usage', ('node', 'period'))]:
        command = commands.add_parser(name)
        for flag in ('database', *flags):
            command.add_argument('--' + flag, required=flag != 'period')
        if name == 'serve':
            command.add_argument('--enforce-quota', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'usage':
            print(json.dumps(usage(args.database, args.node, args.period), separators=(',', ':')))
        else:
            config = json.loads(Path(args.config).read_text(), object_pairs_hook=_unique)
            factory = Meter
            if args.enforce_quota:
                from .quota import EnforcedMeter
                factory = EnforcedMeter
            asyncio.run(serve(factory(args.database, config), args.socket))
    except (ValueError, OSError, sqlite3.Error, RecursionError):
        sys.exit('metering operation unavailable')


if __name__ == '__main__':
    main()
