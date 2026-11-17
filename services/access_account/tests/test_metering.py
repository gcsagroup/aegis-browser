"""N1 cumulative observations, trusted binding and local wire contract."""

import asyncio
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from services.access_account import metering as m


class MeterTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.db = self.root / 'accounts.sqlite'
        self.config = dict(nodeId='node-1', upstreams={'client-A': 1080, 'client-B': 1081})
        self.now = 500
        with sqlite3.connect(self.db) as db:
            db.executescript(Path(m.__file__).with_name('schema.sql').read_text())
            for account in ('A', 'B'):
                db.execute('INSERT INTO accounts VALUES (?)', (account,))
                db.execute("INSERT INTO plans VALUES (?, 'plan', 'p', 100, 900, ?)",
                           (account, 'client-' + account))
        self.meter = m.Meter(self.db, self.config, lambda: self.now)
        self.flow = '1' * 32
        self.open = self.frame('open', client='client-A')
        self.meter.accept(self.open)

    def frame(self, op, **kwargs):
        return dict(v=1, op=op, flow=self.flow, **kwargs)

    def sample(self, direction, path, total, path_total):
        return self.frame('sample', direction=direction, path=path, bytes=total, pathBytes=path_total)

    def usage(self):
        return m.usage(self.db, 'node-1', 'p')

    def test_abort_opening_is_idempotent_and_cannot_erase_traffic(self):
        abort = self.frame('abort')
        self.meter.accept(abort)
        self.meter.accept(abort)
        self.assertEqual(self.usage()['openFlows'], 0)
        self.flow = '2' * 32
        self.meter.accept(self.frame('abort'))
        self.meter = m.Meter(self.db, self.config, lambda: self.now)
        with self.assertRaises(ValueError):
            self.meter.accept(self.frame('open', client='client-A'))
        self.assertEqual(self.usage()['openFlows'], 0)
        self.flow = '3' * 32
        self.meter.accept(self.frame('open', client='client-A'))
        self.meter.accept(self.sample('up', 'target_tcp', 1, 1))
        with self.assertRaises(ValueError):
            self.meter.accept(self.frame('abort'))
        self.assertEqual(self.usage()['uploadedBytes'], 1)

    def test_delayed_replay_preserves_measurement_time(self):
        sample = dict(self.sample('up', 'target_tcp', 3, 3), measuredAt=450)
        self.meter.accept(sample)
        self.assertEqual(self.usage()['sampledAt'], 450)
        self.now = 700
        self.meter.accept(sample)
        self.assertEqual(self.usage()['sampledAt'], 450)
        with self.assertRaises(ValueError):
            self.meter.accept(dict(sample, measuredAt=701))

    def test_reordered_path_samples_restart_and_terminal_replay(self):
        late = self.sample('down', 'vision_raw', 100, 40)
        early = self.sample('down', 'vision_padded', 60, 60)
        for frame in (late, early, late, early):
            self.meter.accept(frame)
        self.meter = m.Meter(self.db, self.config, lambda: self.now)
        self.meter.accept(self.open)
        self.now += 1
        self.meter.accept(early)
        end = self.frame('finish', uploadedBytes=0, downloadedBytes=100, complete=True)
        self.meter.accept(end)
        self.meter.accept(end)
        self.meter.accept(early)
        for invalid in (dict(end, complete=False), self.sample('down', 'vision_raw', 101, 41)):
            with self.assertRaises(ValueError):
                self.meter.accept(invalid)
        report = self.usage()
        self.assertEqual(report['downloadedBytes'], 100)
        self.assertEqual(report['sampledAt'], 500)
        self.assertEqual((report['openFlows'], report['incompleteFlows']), (0, 0))
        self.assertEqual(report['pathBytes'], dict(target_tcp=0, vision_raw=40,
                                                  vision_padded=60, vision_plain=0))
        self.assertEqual(report['accounts'][0]['pathBytes'], report['pathBytes'])
        self.assertNotIn('client-A', json.dumps(report))
        self.assertNotIn(self.flow, json.dumps(report))

    def test_isolation_out_of_order_concurrent_samples_and_wide_totals(self):
        first = self.flow
        self.flow = '2' * 32
        self.meter.accept(self.frame('open', client='client-B'))
        frames = [self.sample('up', 'target_tcp', n, n) for n in [10, 50, 20, 100, 60, m.MAX_BYTES]]
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(self.meter.accept, frames))
        self.flow = first
        self.meter.accept(self.sample('up', 'target_tcp', 10, 10))
        report = self.usage()
        self.assertEqual([a['uploadedBytes'] for a in report['accounts']], [10, m.MAX_BYTES])
        self.assertEqual(report['uploadedBytes'], 10 + m.MAX_BYTES)
        self.assertEqual(report['openFlows'], 2)
        for node, period in [('node-2', 'p'), ('node-1', 'q')]:
            blank = m.usage(self.db, node, period)
            self.assertEqual((blank['accounts'], blank['uploadedBytes'], blank['sampledAt']), ([], 0, None))

    def test_node_totals_include_accounts_with_different_periods(self):
        with sqlite3.connect(self.db) as db:
            db.execute("DELETE FROM plans WHERE account_id='B'")
            db.execute("INSERT INTO plans VALUES ('B','plan','other',100,900,'client-new')")
        config = dict(nodeId='node-1', upstreams={'client-A': 1080, 'client-new': 1081})
        meter = m.Meter(self.db, config, lambda: self.now)
        self.meter.accept(self.sample('up', 'target_tcp', 10, 10))
        self.flow = '2' * 32
        meter.accept(self.frame('open', client='client-new'))
        meter.accept(self.sample('up', 'target_tcp', 20, 20))
        report = m.usage(self.db, 'node-1')
        self.assertIsNone(report['periodId'])
        self.assertEqual([(a['accountId'], a['periodId'], a['uploadedBytes'])
                          for a in report['accounts']], [('A', 'p', 10), ('B', 'other', 20)])
        self.assertEqual(report['uploadedBytes'], 30)

    def test_frozen_binding_and_uncertain_final_prefix(self):
        with sqlite3.connect(self.db) as db:
            db.execute("DELETE FROM plans WHERE account_id='A'")
            db.execute("INSERT INTO plans VALUES ('A','plan','next',900,2000,'client-new')")
        self.now = 901
        self.meter.accept(self.open)
        for invalid in (dict(self.open, flow='2' * 32), dict(self.open, client='client-B'),
                        dict(self.open, flow='3' * 32, client='client-new')):
            with self.assertRaises(ValueError):
                self.meter.accept(invalid)
        self.meter.accept(self.sample('down', 'vision_raw', 6, 6))
        end = self.frame('finish', uploadedBytes=0, downloadedBytes=7, complete=True)
        with self.assertRaises(ValueError):
            self.meter.accept(end)
        self.meter.accept(dict(end, complete=False))
        report = self.usage()
        self.assertEqual((report['downloadedBytes'], report['incompleteFlows'], report['openFlows']), (7, 1, 0))
        self.assertEqual(report['pathBytes']['vision_raw'], 6)
        self.assertEqual(m.usage(self.db, 'node-1', 'next')['accounts'], [])

    def test_invalid_frames_cannot_write_or_create_authority(self):
        frames = [self.frame('sample', direction='up', bytes=True, path='target_tcp', pathBytes=1),
                  self.sample('up', 'vision_raw', 1, 1), self.sample('up', 'target_tcp', 1, 0),
                  self.sample('down', 'vision_raw', 1, 2),
                  self.sample('down', 'vision_raw', -1, 0),
                  self.sample('down', 'vision_raw', m.MAX_BYTES + 1, 0),
                  dict(self.open, accountId='B'), dict(self.open, v=True),
                  dict(self.open, client='client-missing', flow='2' * 32)]
        for frame in frames:
            with self.assertRaises(ValueError):
                self.meter.accept(frame)
        self.assertEqual(self.usage()['sampledAt'], None)
        missing = self.root / 'missing.sqlite'
        for call in (lambda: m.Meter(missing, self.config), lambda: m.usage(missing, 'node-1', 'p')):
            with self.assertRaises(sqlite3.Error):
                call()
        self.assertFalse(missing.exists())

    def test_private_socket_wire_commit_before_ack_and_protocol_rejection(self):
        async def wire():
            path = self.root / 'private.sock'
            self.root.chmod(0o755)
            with self.assertRaises(ValueError):
                await m.serve(self.meter, path)
            self.root.chmod(0o700)
            daemon = asyncio.create_task(m.serve(self.meter, path))
            try:
                for _ in range(100):
                    if path.exists():
                        break
                    await asyncio.sleep(.005)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                with self.assertRaises(OSError):
                    await m.serve(self.meter, path)
                reader, writer = await asyncio.open_unix_connection(path)
                for frame in (self.open, self.sample('up', 'target_tcp', 23, 23)):
                    writer.write(json.dumps(frame).encode() + b'\n')
                    self.assertEqual(await reader.readline(), b'{"ok":true}\n')
                self.assertEqual(self.usage()['uploadedBytes'], 23)
                writer.write(b'{"v":1,"v":1}\n')
                self.assertEqual(await reader.readline(), b'{"ok":false}\n')
                self.assertEqual(await reader.readline(), b'')
                writer.close()
                await writer.wait_closed()
            finally:
                daemon.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await daemon
            self.assertFalse(path.exists())
        asyncio.run(wire())
