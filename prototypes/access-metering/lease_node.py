"""Independent durable node journal for the local W2 lease fixture."""

from __future__ import annotations

import os
import secrets
import socket
import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Iterator
from urllib.parse import quote

from lease_ledger import (ACCOUNTING_VERSION, APPLICATION_ID as CENTER_APPLICATION_ID,
                          MAX_LEASE_BYTES, Lease, LeaseError, ReportResult, Session,
                          UsageRecord, _integer, _name)


MAX_JOURNAL_ROWS = 64
MAX_NODE_LEASES = 64
MAX_CHUNK_BYTES = 16 * 1024
APPLICATION_ID = CENTER_APPLICATION_ID + 1
SCHEMA_VERSION = 1


class NodeError(RuntimeError):
    """No simulated send may proceed without a durable local permit."""


class JournalStorageError(NodeError):
    """The journal cannot reliably prove or persist its accounting state."""


def _node_valid(value: object, label: str, *, minimum: int | None = None,
                maximum: int | None = None) -> None:
    try:
        if minimum is None:
            _name(value, label)
        elif maximum is None:
            _integer(value, label, minimum)
        else:
            _integer(value, label, minimum, maximum)
    except LeaseError as error:
        raise NodeError(str(error)) from error


class NodeJournal:
    def __init__(self, path: str | Path, node_id: str, clock: Callable[[], int],
                 *, create: bool = False):
        _node_valid(node_id, "node")
        self.path = str(path)
        self.node_id = node_id
        self.clock = clock
        self.fail_before_commit: Callable[[], None] | None = None
        self.active_sessions: dict[tuple[str, str, str], str] = {}
        self.sent_chunks: dict[str, int] = {}
        self.blocked_scopes: set[tuple[str, str, str]] = set()
        self.blocked_all = False
        self._send_lock = threading.RLock()
        try:
            flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY if create else os.O_RDONLY
            descriptor = os.open(self.path, flags | getattr(os, "O_NOFOLLOW", 0), 0o600)
            os.close(descriptor)
        except OSError as error:
            raise NodeError(f"journal file unavailable: {error}") from error
        try:
            with self._connection() as connection:
                if create:
                    connection.executescript("""
                        CREATE TABLE fences (account_id TEXT NOT NULL, period_id TEXT NOT NULL,
                            node_id TEXT NOT NULL, epoch INTEGER NOT NULL,
                            PRIMARY KEY(account_id, period_id, node_id));
                        CREATE TABLE sessions (session_id TEXT PRIMARY KEY, account_id TEXT NOT NULL,
                            period_id TEXT NOT NULL, node_id TEXT NOT NULL, epoch INTEGER NOT NULL);
                        CREATE TABLE leases (lease_id TEXT PRIMARY KEY, account_id TEXT NOT NULL,
                            period_id TEXT NOT NULL, node_id TEXT NOT NULL, session_id TEXT NOT NULL,
                            epoch INTEGER NOT NULL, budget INTEGER NOT NULL, expires_at INTEGER NOT NULL,
                            accounting_version TEXT NOT NULL, up INTEGER NOT NULL DEFAULT 0,
                            down INTEGER NOT NULL DEFAULT 0, last_sequence INTEGER NOT NULL DEFAULT 0,
                            acked_up INTEGER NOT NULL DEFAULT 0, acked_down INTEGER NOT NULL DEFAULT 0);
                        CREATE TABLE chunks (chunk_id TEXT PRIMARY KEY, lease_id TEXT NOT NULL,
                            direction TEXT NOT NULL, size INTEGER NOT NULL, state TEXT NOT NULL);
                        CREATE TABLE pending (lease_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL,
                            up INTEGER NOT NULL, down INTEGER NOT NULL);
                    """)
                    connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
                    connection.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
                self._check_database(connection)
        except sqlite3.Error as error:
            raise JournalStorageError(f"journal unavailable: {error}") from error

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(f"file:{quote(self.path)}?mode=rw", timeout=5,
                                     isolation_level=None, uri=True)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("PRAGMA synchronous=FULL")
            connection.execute("PRAGMA busy_timeout=5000")
            yield connection
        finally:
            connection.close()

    @staticmethod
    def _check_database(connection: sqlite3.Connection) -> None:
        if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise JournalStorageError("journal integrity check failed")
        if connection.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
            raise JournalStorageError("unknown journal application id")
        if connection.execute("PRAGMA user_version").fetchone()[0] != SCHEMA_VERSION:
            raise JournalStorageError("unknown journal schema version")
        for table in ("fences", "sessions", "leases", "chunks", "pending"):
            connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()

    @contextmanager
    def _transaction(self, *, run_fault_hook: bool = True) -> Iterator[sqlite3.Connection]:
        try:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    self._check_database(connection)
                    yield connection
                    if run_fault_hook and self.fail_before_commit is not None:
                        self.fail_before_commit()
                    connection.commit()
                except BaseException:
                    if connection.in_transaction:
                        connection.rollback()
                    raise
        except sqlite3.Error as error:
            raise JournalStorageError(f"journal unavailable: {error}") from error

    @staticmethod
    def _scope(row: sqlite3.Row) -> tuple[str, str, str]:
        return row["account_id"], row["period_id"], row["node_id"]

    @staticmethod
    def _fence(connection: sqlite3.Connection, scope: tuple[str, str, str]) -> int:
        row = connection.execute("""SELECT epoch FROM fences WHERE
            account_id=? AND period_id=? AND node_id=?""", scope).fetchone()
        return row[0] if row is not None else 0

    @classmethod
    def _advance_fence(cls, connection: sqlite3.Connection,
                       scope: tuple[str, str, str], epoch: int) -> None:
        if cls._fence(connection, scope) == 0:
            if connection.execute("SELECT COUNT(*) FROM fences").fetchone()[0] >= MAX_JOURNAL_ROWS:
                raise NodeError("fence scope capacity reached")
        connection.execute("""INSERT INTO fences VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id,period_id,node_id) DO UPDATE SET
            epoch=MAX(epoch,excluded.epoch)""", (*scope, epoch))

    def _usable(self, connection: sqlite3.Connection, lease: sqlite3.Row) -> None:
        scope = self._scope(lease)
        if self.blocked_all or scope in self.blocked_scopes:
            raise NodeError("fence not durably known")
        if self.active_sessions.get(scope) != lease["session_id"]:
            raise NodeError("inactive node session")
        if lease["epoch"] < self._fence(connection, scope):
            raise NodeError("known epoch fence")
        now = self.clock()
        _integer(now, "clock")
        if now >= lease["expires_at"]:
            raise NodeError("lease expired")

    def activate(self, session: Session) -> None:
        for value, label in zip((session.account_id, session.period_id,
                                 session.node_id, session.session_id),
                                ("account", "period", "node", "session")):
            _node_valid(value, label)
        _node_valid(session.epoch, "epoch", minimum=1)
        if session.node_id != self.node_id:
            raise NodeError("wrong node session")
        scope = session.account_id, session.period_id, session.node_id
        with self._send_lock:
            was_active = scope in self.active_sessions
            try:
                with self._transaction() as connection:
                    if self.blocked_all or scope in self.blocked_scopes:
                        raise NodeError("blocked node scope")
                    old = connection.execute("SELECT * FROM sessions WHERE session_id=?",
                                             (session.session_id,)).fetchone()
                    if old is not None and (old["account_id"], old["period_id"],
                                            old["node_id"], old["epoch"]) != (
                                                *scope, session.epoch):
                        raise NodeError("conflicting local session")
                    if old is not None and self.active_sessions.get(scope) != session.session_id:
                        raise NodeError("reopened old session cannot send")
                    if session.epoch < self._fence(connection, scope):
                        raise NodeError("old epoch")
                    if old is None:
                        count = connection.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
                        if count >= MAX_JOURNAL_ROWS:
                            raise NodeError("session journal capacity reached")
                        connection.execute("INSERT INTO sessions VALUES (?, ?, ?, ?, ?)",
                                           (session.session_id, *scope, session.epoch))
                    self._advance_fence(connection, scope, session.epoch)
            except BaseException:
                if was_active:
                    self.blocked_scopes.add(scope)
                raise
            self.active_sessions[scope] = session.session_id

    def learn_fence(self, account: str, period: str, node: str, epoch: int) -> None:
        scope = account, period, node
        if node != self.node_id:
            raise NodeError("wrong fence owner")
        for value, label in zip(scope, ("account", "period", "node")):
            _name(value, label)
        with self._send_lock:
            try:
                _integer(epoch, "epoch", 1)
                with self._transaction() as connection:
                    self._advance_fence(connection, scope, epoch)
            except BaseException:
                if scope in self.active_sessions:
                    self.blocked_scopes.add(scope)
                else:
                    self.blocked_all = True
                raise

    def max_seen_epoch(self, account: str, period: str, node: str) -> int:
        with self._connection() as connection:
            self._check_database(connection)
            return self._fence(connection, (account, period, node))

    def remember(self, lease: Lease) -> None:
        for value, label in zip((lease.lease_id, lease.account_id, lease.period_id,
                                 lease.node_id, lease.session_id),
                                ("lease", "account", "period", "node", "session")):
            _node_valid(value, label)
        _node_valid(lease.epoch, "epoch", minimum=1)
        _node_valid(lease.budget_bytes, "lease budget", minimum=1,
                    maximum=MAX_LEASE_BYTES)
        _node_valid(lease.expires_at, "expiry", minimum=0)
        if lease.accounting_version != ACCOUNTING_VERSION:
            raise NodeError("unsupported accounting version")
        if lease.node_id != self.node_id:
            raise NodeError("wrong lease owner")
        with self._transaction() as connection:
            scope = lease.account_id, lease.period_id, lease.node_id
            if self.blocked_all or scope in self.blocked_scopes or lease.epoch < self._fence(connection, scope):
                raise NodeError("known epoch fence")
            if self.active_sessions.get(scope) != lease.session_id:
                raise NodeError("inactive node session")
            session = connection.execute("SELECT * FROM sessions WHERE session_id=?",
                                         (lease.session_id,)).fetchone()
            if session is None or (session["account_id"], session["period_id"],
                                   session["node_id"], session["epoch"]) != (
                                       *scope, lease.epoch):
                raise NodeError("lease does not match durable node session")
            existing = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                          (lease.lease_id,)).fetchone()
            if existing is not None:
                if (existing["account_id"], existing["period_id"], existing["node_id"],
                    existing["session_id"], existing["epoch"], existing["budget"],
                    existing["expires_at"], existing["accounting_version"]) != (
                        lease.account_id, lease.period_id, lease.node_id, lease.session_id,
                        lease.epoch, lease.budget_bytes, lease.expires_at, lease.accounting_version):
                    raise NodeError("conflicting local lease")
                return
            if connection.execute("SELECT COUNT(*) FROM leases").fetchone()[0] >= MAX_NODE_LEASES:
                raise NodeError("local lease capacity reached")
            connection.execute("""INSERT INTO leases
                (lease_id,account_id,period_id,node_id,session_id,epoch,budget,expires_at,accounting_version)
                VALUES (?,?,?,?,?,?,?,?,?)""", (lease.lease_id, lease.account_id,
                lease.period_id, lease.node_id, lease.session_id, lease.epoch,
                lease.budget_bytes, lease.expires_at, lease.accounting_version))

    def prepare(self, lease_id: str, direction: str, size: int) -> str:
        _name(lease_id, "lease")
        if direction not in ("up", "down"):
            raise NodeError("invalid direction")
        _integer(size, "chunk size", 1, MAX_CHUNK_BYTES)
        with self._transaction() as connection:
            lease = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                       (lease_id,)).fetchone()
            if lease is None:
                raise NodeError("unknown local lease")
            self._usable(connection, lease)
            if connection.execute("SELECT COUNT(*) FROM chunks").fetchone()[0] >= MAX_JOURNAL_ROWS:
                raise NodeError("chunk journal capacity reached")
            reserved = connection.execute("SELECT COALESCE(SUM(size),0) FROM chunks WHERE lease_id=?",
                                          (lease_id,)).fetchone()[0]
            if reserved + size > lease["budget"]:
                raise NodeError("local lease budget exhausted")
            chunk_id = secrets.token_hex(16)
            connection.execute("INSERT INTO chunks VALUES (?, ?, ?, ?, 'PREPARED')",
                               (chunk_id, lease_id, direction, size))
            return chunk_id

    def send(self, chunk_id: str, sink: Callable[[str, int], None]) -> None:
        with self._send_lock:
            with self._transaction() as connection:
                chunk = connection.execute("SELECT * FROM chunks WHERE chunk_id=?",
                                           (chunk_id,)).fetchone()
                if chunk is None or chunk["state"] != "PREPARED":
                    raise NodeError("chunk not ready to send")
                lease = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                           (chunk["lease_id"],)).fetchone()
                self._usable(connection, lease)
                connection.execute("UPDATE chunks SET state='SENDING' WHERE chunk_id=?", (chunk_id,))
            # The durable transition may advance the clock. A second write lock keeps
            # another journal handle from committing a fence before the simulated sink.
            with self._transaction(run_fault_hook=False) as connection:
                lease = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                           (chunk["lease_id"],)).fetchone()
                self._usable(connection, lease)
                sink(chunk["direction"], chunk["size"])
                self.sent_chunks[chunk_id] = chunk["size"]

    def send_socket_once(self, chunk_id: str, destination: socket.socket,
                         data: bytes, *, send_limit: int | None = None) -> int:
        """One bounded nonblocking syscall; an unsent tail remains reserved."""
        _node_valid(chunk_id, "chunk")
        if not isinstance(destination, socket.socket) or destination.getblocking():
            raise NodeError("destination must be a nonblocking socket")
        if type(data) is not bytes or not data or len(data) > MAX_CHUNK_BYTES:
            raise NodeError("invalid socket data length")
        if send_limit is not None:
            _node_valid(send_limit, "single send limit", minimum=1,
                        maximum=MAX_CHUNK_BYTES)
        with self._send_lock:
            with self._transaction() as connection:
                chunk = connection.execute("SELECT * FROM chunks WHERE chunk_id=?",
                                           (chunk_id,)).fetchone()
                if chunk is None or chunk["state"] != "PREPARED":
                    raise NodeError("chunk not ready to send")
                if len(data) != chunk["size"]:
                    raise NodeError("socket data length differs from prepared size")
                if send_limit is not None and send_limit > chunk["size"]:
                    raise NodeError("single send limit exceeds prepared size")
                lease = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                           (chunk["lease_id"],)).fetchone()
                self._usable(connection, lease)
                connection.execute("UPDATE chunks SET state='SENDING' WHERE chunk_id=?",
                                   (chunk_id,))
            # This second write lock serializes other journal handles' fences with
            # the one nonblocking syscall. No network wait or callback runs here.
            with self._transaction(run_fault_hook=False) as connection:
                lease = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                           (chunk["lease_id"],)).fetchone()
                self._usable(connection, lease)
                sent = destination.send(data[:send_limit])
                if not 0 <= sent <= (send_limit or len(data)):
                    raise NodeError("invalid socket send result")
                if sent:
                    self.sent_chunks[chunk_id] = sent
                return sent

    def complete(self, chunk_id: str) -> None:
        with self._send_lock:
            sent = self.sent_chunks.get(chunk_id)
            if sent is None:
                raise NodeError("no send proof in this process")
            with self._transaction() as connection:
                chunk = connection.execute("SELECT * FROM chunks WHERE chunk_id=?",
                                           (chunk_id,)).fetchone()
                if chunk is None or chunk["state"] != "SENDING" or sent > chunk["size"]:
                    raise NodeError("chunk not awaiting completion")
                field = "up" if chunk["direction"] == "up" else "down"
                connection.execute("UPDATE chunks SET state='COMPLETE' WHERE chunk_id=?", (chunk_id,))
                connection.execute(f"UPDATE leases SET {field}={field}+? WHERE lease_id=?",
                                   (sent, chunk["lease_id"]))
            del self.sent_chunks[chunk_id]

    def lease_ids(self) -> list[str]:
        """Bounded durable lease inventory for report replay before a new boot."""
        with self._connection() as connection:
            self._check_database(connection)
            rows = connection.execute("SELECT lease_id FROM leases ORDER BY lease_id").fetchall()
            if len(rows) > MAX_NODE_LEASES:
                raise NodeError("local lease capacity exceeded")
            return [row[0] for row in rows]

    def local_balance(self, lease_id: str) -> tuple[int, int, int]:
        with self._connection() as connection:
            self._check_database(connection)
            lease = connection.execute("SELECT up,down FROM leases WHERE lease_id=?",
                                       (lease_id,)).fetchone()
            if lease is None:
                raise NodeError("unknown local lease")
            reserved = connection.execute("SELECT COALESCE(SUM(size),0) FROM chunks WHERE lease_id=?",
                                          (lease_id,)).fetchone()[0]
            return lease["up"], lease["down"], reserved

    @staticmethod
    def _record(lease: sqlite3.Row, sequence: int, up: int, down: int) -> UsageRecord:
        return UsageRecord(lease["lease_id"], lease["account_id"], lease["period_id"],
                           lease["node_id"], lease["session_id"], lease["epoch"],
                           lease["accounting_version"], sequence, up, down)

    def pending_report(self, lease_id: str) -> UsageRecord | None:
        with self._transaction() as connection:
            lease = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                       (lease_id,)).fetchone()
            if lease is None:
                raise NodeError("unknown local lease")
            pending = connection.execute("SELECT * FROM pending WHERE lease_id=?",
                                         (lease_id,)).fetchone()
            if pending is not None:
                return self._record(lease, pending["sequence"], pending["up"], pending["down"])
            if lease["up"] == lease["acked_up"] and lease["down"] == lease["acked_down"]:
                return None
            if connection.execute("SELECT COUNT(*) FROM pending").fetchone()[0] >= MAX_JOURNAL_ROWS:
                raise NodeError("pending report capacity reached")
            sequence = lease["last_sequence"] + 1
            connection.execute("INSERT INTO pending VALUES (?, ?, ?, ?)",
                               (lease_id, sequence, lease["up"], lease["down"]))
            return self._record(lease, sequence, lease["up"], lease["down"])

    def ack(self, record: UsageRecord, result: ReportResult) -> None:
        _node_valid(result.sequence, "response sequence", minimum=1)
        _node_valid(result.up, "response uplink", minimum=0)
        _node_valid(result.down, "response downlink", minimum=0)
        with self._transaction() as connection:
            lease = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                       (record.lease_id,)).fetchone()
            pending = connection.execute("SELECT * FROM pending WHERE lease_id=?",
                                         (record.lease_id,)).fetchone()
            if lease is None or pending is None or self._record(lease, pending["sequence"],
                    pending["up"], pending["down"]) != record:
                raise NodeError("ack does not match pending report")
            if result.status == "ACK":
                if (result.sequence, result.up, result.down) != (record.sequence, record.up, record.down):
                    raise NodeError("ack watermark mismatch")
            elif result.status == "STALE":
                if result.sequence <= record.sequence:
                    raise NodeError("stale response sequence is not newer")
                if result.up > pending["up"] or result.down > pending["down"]:
                    raise NodeError("stale watermark exceeds pending durable completion")
                if result.up < lease["acked_up"] or result.down < lease["acked_down"]:
                    raise NodeError("stale watermark rolls back acknowledged completion")
            else:
                raise NodeError("invalid report response")
            connection.execute("""UPDATE leases SET last_sequence=?, acked_up=?, acked_down=?
                WHERE lease_id=?""", (result.sequence, result.up, result.down, record.lease_id))
            connection.execute("DELETE FROM pending WHERE lease_id=?", (record.lease_id,))
