"""Two-process local W2 lease data path; never contacts an external endpoint."""

from __future__ import annotations

import argparse
import select
import secrets
import socket
import sys
import time
from pathlib import Path
from typing import Callable

from lease_ledger import Lease, LeaseError, LeaseLedger
from lease_node import (MAX_CHUNK_BYTES, MAX_NODE_LEASES, JournalStorageError,
                        NodeError, NodeJournal)


MAX_REPORT_RETRIES = 32
REPORT_RETRY_INTERVAL = 0.1
MAX_PAUSE_SECONDS = 30.0


class CenterTemporarilyUnavailable(RuntimeError):
    """Test-only control-plane outage, distinct from semantic ledger errors."""


class LeaseRelay:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.clock: Callable[[], int] = lambda: int(args.clock_file.read_text(encoding="ascii"))
        self.center = LeaseLedger(args.center_db, self.clock)
        self.node = NodeJournal(args.journal_db, args.node, self.clock)
        self.lease: Lease | None = None
        self.fatal = False
        self.report_retries = 0
        self.last_report_attempt: dict[str, int] = {}
        self.next_report_attempt = 0.0

    def _stop_sending(self) -> None:
        self.fatal = True
        if self.args.fatal_marker is not None:
            self.args.fatal_marker.write_text("stopped", encoding="ascii")

    def _center_call(self, operation: Callable[..., object], *values: object) -> object:
        if self.args.center_offline_marker is not None and self.args.center_offline_marker.exists():
            raise CenterTemporarilyUnavailable("test center outage")
        return operation(*values)

    def _pause(self, stage: str) -> None:
        if self.args.pause_stage != stage:
            return
        self.args.marker_file.write_text(stage, encoding="ascii")
        deadline = time.monotonic() + MAX_PAUSE_SECONDS
        while not self.args.resume_file.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError(f"{stage} marker timed out")
            time.sleep(0.01)

    def _flush_lease(self, lease_id: str, *, replay_existing: bool = False) -> bool:
        """Return False only for the explicit temporary outage marker."""
        for _ in range(MAX_NODE_LEASES + 1):
            try:
                record = self.node.pending_report(lease_id)
            except NodeError:
                self._stop_sending()
                raise
            if record is None:
                return True
            retry = (replay_existing or
                     self.last_report_attempt.get(lease_id) == record.sequence)
            if retry and self.report_retries >= MAX_REPORT_RETRIES:
                self._stop_sending()
                raise NodeError("report retry limit reached")
            delay = self.next_report_attempt - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            self.last_report_attempt[lease_id] = record.sequence
            if retry:
                self.report_retries += 1
            try:
                if (self.args.report_conflict_marker is not None and
                        self.args.report_conflict_marker.exists()):
                    raise LeaseError("injected report conflict")
                result = self._center_call(self.center.report, record)
                self._pause("reported")
                self.node.ack(record, result)
            except CenterTemporarilyUnavailable:
                self.next_report_attempt = time.monotonic() + REPORT_RETRY_INTERVAL
                if self.report_retries >= MAX_REPORT_RETRIES:
                    self._stop_sending()
                return False
            except (LeaseError, NodeError):
                self._stop_sending()
                raise
            self.next_report_attempt = 0.0
            if self.report_retries >= MAX_REPORT_RETRIES:
                self._stop_sending()
                raise NodeError("report retry limit reached")
        self._stop_sending()
        raise NodeError("report replay did not converge")

    def boot(self) -> None:
        for lease_id in self.node.lease_ids():
            if not self._flush_lease(lease_id, replay_existing=True):
                raise CenterTemporarilyUnavailable("old report not settled")
        boot_key = secrets.token_hex(16)
        session = self._center_call(self.center.start_session,
                                    self.args.account, self.args.period,
                                    self.args.node, boot_key)
        self.node.activate(session)
        grant_key = secrets.token_hex(16)
        lease = self._center_call(self.center.grant, self.args.account,
                                  self.args.period, self.args.node,
                                  session.session_id, session.epoch,
                                  grant_key, self.args.grant_bytes)
        if lease is None:
            raise NodeError("no quota available for new node lease")
        self.node.remember(lease)
        self.lease = lease

    def _transfer(self, destination: socket.socket, direction: str,
                  data: bytes) -> bool:
        if self.lease is None or self.fatal:
            raise NodeError("inactive relay lease")
        if not self._flush_lease(self.lease.lease_id) and self.fatal:
            raise NodeError("center retry limit reached")
        chunk_id = self.node.prepare(self.lease.lease_id, direction, len(data))
        self._pause("prepared")
        sent = self.node.send_socket_once(chunk_id, destination, data,
                                          send_limit=self.args.test_send_limit)
        self._pause("sent")
        if sent == 0:
            return False
        self.node.complete(chunk_id)
        self._pause("completed")
        self._flush_lease(self.lease.lease_id)
        if self.fatal:
            return False
        return sent == len(data)

    def _client(self, client: socket.socket) -> None:
        origin: socket.socket | None = None
        try:
            origin = socket.create_connection(("127.0.0.1", self.args.origin_port),
                                               timeout=self.args.io_timeout)
            client.setblocking(False)
            origin.setblocking(False)
            readable = [client, origin]
            last_activity = time.monotonic()
            while readable and not self.fatal:
                if self.lease is not None:
                    self._flush_lease(self.lease.lease_id)
                ready, _, _ = select.select(readable, [], [], REPORT_RETRY_INTERVAL)
                if not ready:
                    if time.monotonic() - last_activity >= self.args.io_timeout:
                        break
                    continue
                for source in ready:
                    destination = origin if source is client else client
                    try:
                        data = source.recv(self.args.chunk_bytes)
                    except BlockingIOError:
                        continue
                    if not data:
                        readable.remove(source)
                        try:
                            destination.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                        continue
                    direction = "up" if source is client else "down"
                    if not self._transfer(destination, direction, data):
                        return
                    last_activity = time.monotonic()
        except (CenterTemporarilyUnavailable, LeaseError, NodeError,
                OSError, TimeoutError, ValueError) as error:
            print(f"lease relay closed: {error}", file=sys.stderr, flush=True)
            if isinstance(error, (LeaseError, JournalStorageError, ValueError)):
                self._stop_sending()
        finally:
            client.close()
            if origin is not None:
                origin.close()

    def serve(self) -> None:
        self.boot()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", self.args.listen_port))
        listener.listen(8)
        listener.settimeout(REPORT_RETRY_INTERVAL)
        print(f"READY {listener.getsockname()[1]}", flush=True)
        try:
            while True:
                try:
                    client, _ = listener.accept()
                except socket.timeout:
                    if not self.fatal and self.lease is not None:
                        try:
                            self._flush_lease(self.lease.lease_id)
                        except (LeaseError, NodeError):
                            self._stop_sending()
                    continue
                if self.fatal:
                    client.close()
                    continue
                self._client(client)
        finally:
            listener.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Local-only two-node lease relay")
    parser.add_argument("--center-db", type=Path, required=True)
    parser.add_argument("--journal-db", type=Path, required=True)
    parser.add_argument("--clock-file", type=Path, required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--period", required=True)
    parser.add_argument("--node", required=True)
    parser.add_argument("--grant-bytes", type=int, required=True)
    parser.add_argument("--origin-port", type=int, required=True)
    parser.add_argument("--listen-port", type=int, default=0)
    parser.add_argument("--chunk-bytes", type=int, default=4096)
    parser.add_argument("--io-timeout", type=float, default=3.0)
    parser.add_argument("--center-offline-marker", type=Path)
    parser.add_argument("--report-conflict-marker", type=Path)
    parser.add_argument("--fatal-marker", type=Path)
    parser.add_argument("--test-send-limit", type=int)
    parser.add_argument("--pause-stage", choices=("prepared", "sent", "completed", "reported"))
    parser.add_argument("--marker-file", type=Path)
    parser.add_argument("--resume-file", type=Path)
    args = parser.parse_args()
    if not (1 <= args.origin_port <= 65535 and 0 <= args.listen_port <= 65535 and
            1 <= args.chunk_bytes <= MAX_CHUNK_BYTES and 0 < args.io_timeout <= 30 and
            1 <= args.grant_bytes <= 64 * 1024):
        parser.error("invalid fixture bounds")
    if args.test_send_limit is not None and not 1 <= args.test_send_limit <= args.chunk_bytes:
        parser.error("invalid test send limit")
    if args.pause_stage is not None and (args.marker_file is None or args.resume_file is None):
        parser.error("pause stage requires marker and resume files")
    try:
        LeaseRelay(args).serve()
    except (CenterTemporarilyUnavailable, LeaseError, NodeError, OSError,
            TimeoutError, ValueError) as error:
        print(f"lease relay startup failed: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
