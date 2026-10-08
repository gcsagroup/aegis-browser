"""Real loopback process tests for the bounded two-node lease data path."""

from __future__ import annotations

import select
import socket
# Owned local fixture processes are required to test kill/restart windows.
import subprocess  # nosec B404
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from lease_ledger import LeaseLedger
from lease_node import JournalStorageError, NodeError, NodeJournal
from lease_relay import CenterTemporarilyUnavailable, LeaseRelay


ROOT = Path(__file__).parent


def wait_until(predicate, timeout: float = 4.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("bounded fixture wait expired")


class LeaseRelayProcessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="aegis-w2-relay-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.center_path = self.root / "center.db"
        self.clock_path = self.root / "clock.txt"
        self.clock_path.write_text("0", encoding="ascii")
        self.processes: list[subprocess.Popen[str]] = []
        self.connections: list[socket.socket] = []
        self.addCleanup(self._cleanup)

    def _cleanup(self) -> None:
        for connection in self.connections:
            connection.close()
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()

    def clock(self) -> int:
        return int(self.clock_path.read_text(encoding="ascii"))

    def center(self, quota: int) -> LeaseLedger:
        center = LeaseLedger(self.center_path, self.clock, create=True)
        center.configure("acct", "p1", quota)
        return center

    def _spawn(self, script: str, args: list[str]) -> subprocess.Popen[str]:
        # argv contains only this checkout's trusted scripts and temporary fixture values.
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        process = subprocess.Popen(  # nosec B603
            [sys.executable, str(ROOT / script), *args],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            bufsize=1, close_fds=True, shell=False)
        self.processes.append(process)
        return process

    def _ready(self, process: subprocess.Popen[str], script: str) -> int:
        if process.stdout is None:
            self.fail("子进程没有提供标准输出管道")
        readable, _, _ = select.select([process.stdout], [], [], 4)
        if not readable:
            self.fail(f"{script} did not become ready; exit={process.poll()}")
        line = process.stdout.readline().strip()
        if not line.startswith("READY "):
            self.fail(f"{script} startup: {line}; exit={process.poll()}")
        return int(line.split()[1])

    def _start(self, script: str, args: list[str]) -> tuple[subprocess.Popen[str], int]:
        process = self._spawn(script, args)
        return process, self._ready(process, script)

    def origin(self, name: str, *, echo: bool = False) -> tuple[int, Path]:
        counts = self.root / f"{name}-counts.txt"
        args = ["--port", "0", "--counts-file", str(counts)]
        if not echo:
            args.append("--no-echo")
        _, port = self._start("origin.py", args)
        return port, counts

    def relay_args(self, node: str, origin_port: int, grant: int,
                   extra: list[str] | None = None) -> tuple[list[str], Path]:
        journal_path = self.root / f"node-{node}.db"
        if not journal_path.exists():
            NodeJournal(journal_path, node, self.clock, create=True)
        args = ["--center-db", str(self.center_path), "--journal-db", str(journal_path),
                "--clock-file", str(self.clock_path), "--account", "acct",
                "--period", "p1", "--node", node, "--grant-bytes", str(grant),
                "--origin-port", str(origin_port), "--listen-port", "0",
                "--io-timeout", "3"]
        return [*args, *(extra or [])], journal_path

    def relay(self, node: str, origin_port: int, grant: int,
              extra: list[str] | None = None) -> tuple[subprocess.Popen[str], int, Path]:
        args, journal_path = self.relay_args(node, origin_port, grant, extra)
        process, port = self._start("lease_relay.py", args)
        return process, port, journal_path

    def connect(self, port: int) -> socket.socket:
        connection = socket.create_connection(("127.0.0.1", port), timeout=2)
        connection.settimeout(2)
        self.connections.append(connection)
        return connection

    @staticmethod
    def counts(path: Path) -> tuple[int, int] | None:
        if not path.exists():
            return None
        values = path.read_text(encoding="ascii").split()
        return int(values[0]), int(values[1])

    def test_two_relay_processes_share_finite_quota_and_independent_origins(self) -> None:
        center = self.center(10)
        a_origin, a_counts = self.origin("A")
        b_origin, b_counts = self.origin("B")
        _, a_port, a_journal = self.relay("A", a_origin, 7)
        _, b_port, b_journal = self.relay("B", b_origin, 7)
        self.connect(a_port).sendall(b"abcd")
        self.connect(b_port).sendall(b"xyz")
        wait_until(lambda: center.snapshot("acct", "p1").actual_bytes == 7)
        wait_until(lambda: self.counts(a_counts) == (4, 0) and self.counts(b_counts) == (3, 0))
        balance = center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.remaining_bytes), (7, 3, 0))
        a = NodeJournal(a_journal, "A", self.clock)
        b = NodeJournal(b_journal, "B", self.clock)
        self.assertEqual(a.local_balance(a.lease_ids()[0]), (4, 0, 4))
        self.assertEqual(b.local_balance(b.lease_ids()[0]), (3, 0, 3))

    def test_concurrent_process_boots_reserve_no_more_than_account_quota(self) -> None:
        center = self.center(10)
        a_origin, _ = self.origin("A")
        b_origin, _ = self.origin("B")
        a_args, a_path = self.relay_args("A", a_origin, 7)
        b_args, b_path = self.relay_args("B", b_origin, 7)
        a_process = self._spawn("lease_relay.py", a_args)
        b_process = self._spawn("lease_relay.py", b_args)
        self._ready(a_process, "lease_relay.py")
        self._ready(b_process, "lease_relay.py")
        grants = []
        for node, path in (("A", a_path), ("B", b_path)):
            journal = NodeJournal(path, node, self.clock)
            lease_id = journal.lease_ids()[0]
            with center._connection() as connection:
                grants.append(connection.execute("SELECT budget FROM leases WHERE lease_id=?",
                                                 (lease_id,)).fetchone()[0])
        self.assertEqual(sorted(grants), [3, 7])
        balance = center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.remaining_bytes), (0, 10, 0))

    def test_echo_counts_both_directions_while_connection_stays_open(self) -> None:
        center = self.center(16)
        origin_port, counts = self.origin("echo", echo=True)
        _, relay_port, _ = self.relay("A", origin_port, 16)
        connection = self.connect(relay_port)
        connection.sendall(b"ping")
        self.assertEqual(connection.recv(4), b"ping")
        wait_until(lambda: center.snapshot("acct", "p1").actual_bytes == 8)
        self.assertEqual(self.counts(counts), (4, 4))
        balance = center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes), (8, 8))

    def test_short_write_counts_only_sent_prefix_and_keeps_full_reservation(self) -> None:
        center = self.center(8)
        origin_port, counts = self.origin("short")
        _, relay_port, journal = self.relay("A", origin_port, 8,
                                             ["--test-send-limit", "2"])
        connection = self.connect(relay_port)
        connection.sendall(b"abcd")
        wait_until(lambda: center.snapshot("acct", "p1").actual_bytes == 2)
        wait_until(lambda: self.counts(counts) == (2, 0))
        self.assertEqual(connection.recv(1), b"")
        node = NodeJournal(journal, "A", self.clock)
        self.assertEqual(node.local_balance(node.lease_ids()[0]), (2, 0, 4))
        balance = center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.remaining_bytes), (2, 6, 0))

    def _crash_at(self, stage: str) -> None:
        center = self.center(10)
        origin_port, counts = self.origin(stage)
        marker = self.root / f"{stage}.marker"
        resume = self.root / f"{stage}.resume"
        process, relay_port, journal = self.relay("A", origin_port, 7,
            ["--pause-stage", stage, "--marker-file", str(marker),
             "--resume-file", str(resume)])
        self.connect(relay_port).sendall(b"abcd")
        wait_until(marker.exists)
        expected_origin = 0 if stage == "prepared" else 4
        wait_until(lambda: self.counts(counts) == (expected_origin, 0))
        before = center.snapshot("acct", "p1")
        self.assertEqual((before.actual_bytes, before.held_bytes),
                         (4, 3) if stage == "reported" else (0, 7))
        old_lease = NodeJournal(journal, "A", self.clock).lease_ids()[0]
        local = NodeJournal(journal, "A", self.clock).local_balance(old_lease)
        self.assertEqual(local[0], 4 if stage in ("completed", "reported") else 0)
        self.assertEqual(local[2], 4)
        process.kill()
        process.wait(timeout=2)
        self.relay("A", origin_port, 1)
        balance = center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.uncertain_bytes, balance.remaining_bytes),
                         (4, 4, 3, 2) if stage in ("completed", "reported")
                         else (0, 8, 7, 2))
        self.assertEqual(self.counts(counts), (expected_origin, 0))

    def test_crash_after_prepare_does_not_resend(self) -> None:
        self._crash_at("prepared")

    def test_crash_after_socket_send_keeps_origin_and_ledger_distinct(self) -> None:
        self._crash_at("sent")

    def test_crash_after_complete_replays_durable_cumulative_report(self) -> None:
        self._crash_at("completed")

    def test_crash_after_center_report_before_ack_is_idempotent(self) -> None:
        self._crash_at("reported")

    def test_expiry_after_prepare_blocks_actual_socket_send(self) -> None:
        center = self.center(7)
        origin_port, counts = self.origin("expiry")
        marker = self.root / "prepared.marker"
        resume = self.root / "prepared.resume"
        _, relay_port, journal = self.relay("A", origin_port, 7,
            ["--pause-stage", "prepared", "--marker-file", str(marker),
             "--resume-file", str(resume)])
        connection = self.connect(relay_port)
        connection.sendall(b"abcd")
        wait_until(marker.exists)
        temporary = self.root / "next-clock.txt"
        temporary.write_text("10", encoding="ascii")
        temporary.replace(self.clock_path)
        resume.touch()
        self.assertEqual(connection.recv(1), b"")
        self.assertEqual(self.counts(counts), (0, 0))
        self.assertEqual(center.snapshot("acct", "p1").actual_bytes, 0)
        node = NodeJournal(journal, "A", self.clock)
        self.assertEqual(node.local_balance(node.lease_ids()[0]), (0, 0, 4))

    def test_known_new_epoch_after_prepare_blocks_socket_send(self) -> None:
        center = self.center(7)
        origin_port, counts = self.origin("fence")
        marker = self.root / "prepared.marker"
        resume = self.root / "prepared.resume"
        _, relay_port, journal = self.relay("A", origin_port, 7,
            ["--pause-stage", "prepared", "--marker-file", str(marker),
             "--resume-file", str(resume)])
        connection = self.connect(relay_port)
        connection.sendall(b"abcd")
        wait_until(marker.exists)
        newer = center.start_session("acct", "p1", "A", "test-new-epoch")
        NodeJournal(journal, "A", self.clock).learn_fence("acct", "p1", "A", newer.epoch)
        resume.touch()
        self.assertEqual(connection.recv(1), b"")
        self.assertEqual(self.counts(counts), (0, 0))
        balance = center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.uncertain_bytes), (0, 7, 7))

    def test_center_outage_preserves_pending_and_idle_recovery_settles_once(self) -> None:
        center = self.center(8)
        origin_port, counts = self.origin("outage")
        offline = self.root / "center-offline.marker"
        _, relay_port, journal = self.relay("A", origin_port, 8,
            ["--center-offline-marker", str(offline)])
        connection = self.connect(relay_port)
        connection.sendall(b"a")
        wait_until(lambda: center.snapshot("acct", "p1").actual_bytes == 1)
        offline.touch()
        connection.sendall(b"b")
        node = NodeJournal(journal, "A", self.clock)
        wait_until(lambda: node.local_balance(node.lease_ids()[0])[0] == 2)
        self.assertEqual(center.snapshot("acct", "p1").actual_bytes, 1)
        offline.unlink()
        wait_until(lambda: center.snapshot("acct", "p1").actual_bytes == 2)
        self.assertEqual(self.counts(counts), (2, 0))
        self.assertEqual(center.snapshot("acct", "p1").held_bytes, 6)

    def test_center_outage_on_restart_never_opens_old_session(self) -> None:
        center = self.center(8)
        origin_port, counts = self.origin("restart-offline")
        first, relay_port, _ = self.relay("A", origin_port, 8)
        self.connect(relay_port).sendall(b"a")
        wait_until(lambda: center.snapshot("acct", "p1").actual_bytes == 1)
        first.kill()
        first.wait(timeout=2)
        offline = self.root / "center-offline.marker"
        offline.touch()
        args, _ = self.relay_args("A", origin_port, 1,
                                  ["--center-offline-marker", str(offline)])
        second = self._spawn("lease_relay.py", args)
        self.assertNotEqual(second.wait(timeout=2), 0)
        self.assertEqual(self.counts(counts), (1, 0))
        balance = center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.uncertain_bytes), (1, 7, 0))

    def test_report_retry_cap_stops_new_sends_and_keeps_pending(self) -> None:
        center = self.center(8)
        origin_port, counts = self.origin("retry-cap")
        offline = self.root / "center-offline.marker"
        stopped = self.root / "retry-stopped.marker"
        _, relay_port, journal = self.relay("A", origin_port, 8,
            ["--center-offline-marker", str(offline), "--fatal-marker", str(stopped),
             "--io-timeout", "5"])
        offline.touch()
        self.connect(relay_port).sendall(b"a")
        wait_until(lambda: self.counts(counts) == (1, 0))
        wait_until(stopped.exists, timeout=6)
        second = self.connect(relay_port)
        second.sendall(b"b")
        try:
            received = second.recv(1)
        except ConnectionResetError:
            received = b""
        self.assertEqual(received, b"")
        self.assertEqual(self.counts(counts), (1, 0))
        self.assertEqual(center.snapshot("acct", "p1").actual_bytes, 0)
        node = NodeJournal(journal, "A", self.clock)
        self.assertIsNotNone(node.pending_report(node.lease_ids()[0]))

    def test_report_conflict_stops_future_connections(self) -> None:
        center = self.center(8)
        origin_port, counts = self.origin("conflict")
        conflict = self.root / "report-conflict.marker"
        stopped = self.root / "stopped.marker"
        _, relay_port, _ = self.relay("A", origin_port, 8,
                                      ["--report-conflict-marker", str(conflict),
                                       "--fatal-marker", str(stopped)])
        conflict.touch()
        self.connect(relay_port).sendall(b"a")
        wait_until(lambda: self.counts(counts) == (1, 0))
        wait_until(stopped.exists)
        second = self.connect(relay_port)
        second.sendall(b"b")
        try:
            received = second.recv(1)
        except ConnectionResetError:
            received = b""
        self.assertEqual(received, b"")
        self.assertEqual(self.counts(counts), (1, 0))
        self.assertEqual(center.snapshot("acct", "p1").actual_bytes, 0)


class LeaseRelayFailureTests(unittest.TestCase):
    @staticmethod
    def relay() -> LeaseRelay:
        relay = LeaseRelay.__new__(LeaseRelay)
        relay.args = SimpleNamespace(fatal_marker=None, report_conflict_marker=None,
                                     origin_port=1, io_timeout=1, chunk_bytes=4096)
        relay.node = Mock()
        relay.center = Mock()
        relay.lease = SimpleNamespace(lease_id="lease")
        relay.fatal = False
        relay.report_retries = 0
        relay.last_report_attempt = {}
        relay.next_report_attempt = 0.0
        relay._pause = Mock()
        relay._center_call = Mock(return_value=object())
        return relay

    def test_pending_journal_error_latches_before_next_connection(self) -> None:
        relay = self.relay()
        relay.node.pending_report.side_effect = [NodeError("journal integrity"), None]
        with self.assertRaises(NodeError):
            relay._flush_lease("lease")
        self.assertTrue(relay.fatal)
        client, origin = Mock(spec=socket.socket), Mock(spec=socket.socket)
        relay._transfer = Mock()
        with patch("lease_relay.socket.create_connection", return_value=origin):
            relay._client(client)
        relay._transfer.assert_not_called()
        relay.node.pending_report.assert_called_once_with("lease")
        client.close.assert_called_once()
        origin.close.assert_called_once()

    def test_data_path_journal_storage_error_latches_relay(self) -> None:
        relay = self.relay()
        relay._flush_lease = Mock(return_value=True)
        relay._transfer = Mock(side_effect=JournalStorageError("journal unavailable"))
        client, origin = Mock(spec=socket.socket), Mock(spec=socket.socket)
        client.recv.return_value = b"x"
        with patch("lease_relay.socket.create_connection", return_value=origin), \
             patch("lease_relay.select.select", return_value=([client], [], [])):
            relay._client(client)
        self.assertTrue(relay.fatal)
        relay._transfer.reset_mock()
        next_client, next_origin = Mock(spec=socket.socket), Mock(spec=socket.socket)
        with patch("lease_relay.socket.create_connection", return_value=next_origin):
            relay._client(next_client)
        relay._transfer.assert_not_called()

    def test_retry_cap_counts_successful_replays_across_recovery(self) -> None:
        relay = self.relay()
        pending = [None]
        offline = [False]
        relay.node.pending_report.side_effect = lambda _: pending[0]
        relay.node.ack.side_effect = lambda *_: pending.__setitem__(0, None)

        def center_call(*_args: object) -> object:
            if offline[0]:
                raise CenterTemporarilyUnavailable("test outage")
            return object()

        relay._center_call.side_effect = center_call
        with patch("lease_relay.time.sleep"):
            for sequence in range(1, 32):
                pending[0] = SimpleNamespace(sequence=sequence)
                offline[0] = True
                self.assertFalse(relay._flush_lease("lease"))
                offline[0] = False
                self.assertTrue(relay._flush_lease("lease"))
                self.assertFalse(relay.fatal)
            self.assertEqual(relay.report_retries, 31)
            pending[0] = SimpleNamespace(sequence=32)
            offline[0] = True
            self.assertFalse(relay._flush_lease("lease"))
            self.assertFalse(relay._flush_lease("lease"))
            self.assertEqual(relay.report_retries, 32)
            self.assertTrue(relay.fatal)
            self.assertEqual(pending[0].sequence, 32)
            previous_attempts = relay._center_call.call_count
            with self.assertRaises(NodeError):
                relay._flush_lease("lease")
            self.assertEqual(relay._center_call.call_count, previous_attempts)


if __name__ == "__main__":
    unittest.main()
