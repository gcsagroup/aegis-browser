"""Durable central byte leases for a local W2 state-machine fixture only."""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator
from urllib.parse import quote


MAX_ACCOUNTS = 8
MAX_PERIODS_PER_ACCOUNT = 8
MAX_SESSIONS = 64
MAX_LEASES = 64
MAX_BOOT_KEYS = 64
MAX_GRANT_KEYS = 64
MAX_AUDIT = 256
MAX_ID_BYTES = 128
MAX_LEASE_BYTES = 64 * 1024
LEASE_TTL = 10
MAX_SQLITE_INT = 2**63 - 1
APPLICATION_ID = 0x57324C53  # W2LS
SCHEMA_VERSION = 1
ACCOUNTING_VERSION = "fixture-target-bytes-v1"


class LeaseError(RuntimeError):
    """The fixture refuses to grant or settle when evidence is invalid."""


@dataclass(frozen=True)
class Session:
    account_id: str
    period_id: str
    node_id: str
    session_id: str
    epoch: int


@dataclass(frozen=True)
class Lease:
    lease_id: str
    account_id: str
    period_id: str
    node_id: str
    session_id: str
    epoch: int
    budget_bytes: int
    expires_at: int
    accounting_version: str = ACCOUNTING_VERSION


@dataclass(frozen=True)
class Balance:
    account_id: str
    period_id: str
    quota_bytes: int
    actual_bytes: int
    held_bytes: int
    uncertain_bytes: int
    remaining_bytes: int


@dataclass(frozen=True)
class UsageRecord:
    lease_id: str
    account_id: str
    period_id: str
    node_id: str
    session_id: str
    epoch: int
    accounting_version: str
    sequence: int
    up: int
    down: int

    @classmethod
    def for_lease(cls, lease: Lease, sequence: int, up: int, down: int,
                  session_id: str | None = None) -> UsageRecord:
        return cls(lease.lease_id, lease.account_id, lease.period_id, lease.node_id,
                   session_id or lease.session_id, lease.epoch, lease.accounting_version,
                   sequence, up, down)


@dataclass(frozen=True)
class ReportResult:
    status: str
    sequence: int
    up: int
    down: int


def _name(value: str, label: str) -> None:
    if (not isinstance(value, str) or not value or "\x00" in value or
            len(value.encode("utf-8")) > MAX_ID_BYTES):
        raise LeaseError(f"invalid {label}")


def _integer(value: int, label: str, minimum: int = 0,
             maximum: int = MAX_SQLITE_INT) -> None:
    if type(value) is not int or not minimum <= value <= maximum:
        raise LeaseError(f"invalid {label}")


def _digest(*values: object) -> str:
    data = json.dumps(values, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


class LeaseLedger:
    def __init__(self, path: str | Path, clock: Callable[[], int], *, create: bool = False):
        self.path = str(path)
        self.clock = clock
        self.fail_before_commit: Callable[[], None] | None = None
        try:
            flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY if create else os.O_RDONLY
            descriptor = os.open(self.path, flags | getattr(os, "O_NOFOLLOW", 0), 0o600)
            os.close(descriptor)
        except OSError as error:
            raise LeaseError(f"center file unavailable: {error}") from error
        try:
            with self._connection() as connection:
                if create:
                    connection.execute("BEGIN EXCLUSIVE")
                    connection.executescript("""
                        CREATE TABLE accounts (account_id TEXT PRIMARY KEY, current_period TEXT NOT NULL);
                        CREATE TABLE periods (account_id TEXT NOT NULL, period_id TEXT NOT NULL,
                            quota INTEGER NOT NULL, PRIMARY KEY(account_id, period_id));
                        CREATE TABLE epochs (account_id TEXT NOT NULL, period_id TEXT NOT NULL,
                            node_id TEXT NOT NULL, epoch INTEGER NOT NULL, session_id TEXT NOT NULL,
                            PRIMARY KEY(account_id, period_id, node_id));
                        CREATE TABLE sessions (session_id TEXT PRIMARY KEY, account_id TEXT NOT NULL,
                            period_id TEXT NOT NULL, node_id TEXT NOT NULL, epoch INTEGER NOT NULL);
                        CREATE TABLE boot_keys (request_id TEXT PRIMARY KEY, digest TEXT NOT NULL,
                            session_id TEXT NOT NULL);
                        CREATE TABLE grant_keys (request_id TEXT PRIMARY KEY, digest TEXT NOT NULL,
                            lease_id TEXT, granted INTEGER NOT NULL);
                        CREATE TABLE leases (lease_id TEXT PRIMARY KEY, account_id TEXT NOT NULL,
                            period_id TEXT NOT NULL, node_id TEXT NOT NULL, session_id TEXT NOT NULL,
                            epoch INTEGER NOT NULL, budget INTEGER NOT NULL, expires_at INTEGER NOT NULL,
                            accounting_version TEXT NOT NULL, up INTEGER NOT NULL DEFAULT 0,
                            down INTEGER NOT NULL DEFAULT 0, sequence INTEGER NOT NULL DEFAULT 0,
                            last_digest TEXT NOT NULL DEFAULT '', uncertain INTEGER NOT NULL DEFAULT 0);
                        CREATE TABLE audit (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, ref TEXT NOT NULL);
                    """)
                    connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
                    connection.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
                    connection.commit()
                self._check_database(connection)
        except sqlite3.Error as error:
            raise LeaseError(f"center unavailable: {error}") from error

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
            raise LeaseError("center integrity check failed")
        if connection.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
            raise LeaseError("unknown center application id")
        if connection.execute("PRAGMA user_version").fetchone()[0] != SCHEMA_VERSION:
            raise LeaseError("unknown center schema version")
        for table in ("accounts", "periods", "epochs", "sessions", "boot_keys",
                      "grant_keys", "leases", "audit"):
            connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        try:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    self._check_database(connection)
                    yield connection
                    if self.fail_before_commit is not None:
                        self.fail_before_commit()
                    connection.commit()
                except BaseException:
                    if connection.in_transaction:
                        connection.rollback()
                    raise
        except sqlite3.Error as error:
            raise LeaseError(f"center unavailable: {error}") from error

    @staticmethod
    def _count(connection: sqlite3.Connection, table: str) -> int:
        return connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

    @classmethod
    def _audit(cls, connection: sqlite3.Connection, kind: str, ref: str) -> None:
        if cls._count(connection, "audit") >= MAX_AUDIT:
            raise LeaseError("audit capacity reached")
        connection.execute("INSERT INTO audit(kind, ref) VALUES (?, ?)", (kind, ref))

    @staticmethod
    def _current_period(connection: sqlite3.Connection, account: str, period: str) -> None:
        row = connection.execute("SELECT current_period FROM accounts WHERE account_id=?",
                                 (account,)).fetchone()
        if row is None or row[0] != period:
            raise LeaseError("unknown account or stale period")

    @staticmethod
    def _balance(connection: sqlite3.Connection, account: str, period: str) -> Balance:
        row = connection.execute("SELECT quota FROM periods WHERE account_id=? AND period_id=?",
                                 (account, period)).fetchone()
        if row is None:
            raise LeaseError("unknown account period")
        quota = row[0]
        actual, held, uncertain = connection.execute("""SELECT
            COALESCE(SUM(up + down), 0),
            COALESCE(SUM(budget - up - down), 0),
            COALESCE(SUM(CASE WHEN uncertain=1 THEN budget - up - down ELSE 0 END), 0)
            FROM leases WHERE account_id=? AND period_id=?""", (account, period)).fetchone()
        if not 0 <= uncertain <= held or actual + held > quota:
            raise LeaseError("inconsistent center balance")
        return Balance(account, period, quota, actual, held, uncertain, quota - actual - held)

    def configure(self, account: str, period: str, quota: int) -> None:
        _name(account, "account")
        _name(period, "period")
        _integer(quota, "quota")
        with self._transaction() as connection:
            existing = connection.execute("SELECT current_period FROM accounts WHERE account_id=?",
                                          (account,)).fetchone()
            if existing is not None:
                old = connection.execute("SELECT quota FROM periods WHERE account_id=? AND period_id=?",
                                         (account, period)).fetchone()
                if existing[0] != period or old is None or old[0] != quota:
                    raise LeaseError("account configuration mismatch")
                return
            if self._count(connection, "accounts") >= MAX_ACCOUNTS:
                raise LeaseError("account capacity reached")
            self._audit(connection, "configure", account)
            connection.execute("INSERT INTO accounts VALUES (?, ?)", (account, period))
            connection.execute("INSERT INTO periods VALUES (?, ?, ?)", (account, period, quota))

    def start_session(self, account: str, period: str, node: str,
                      boot_request_id: str) -> Session:
        for value, label in ((account, "account"), (period, "period"),
                             (node, "node"), (boot_request_id, "boot request")):
            _name(value, label)
        digest = _digest(account, period, node)
        with self._transaction() as connection:
            existing = connection.execute("SELECT digest, session_id FROM boot_keys WHERE request_id=?",
                                          (boot_request_id,)).fetchone()
            if existing is not None:
                if existing[0] != digest:
                    raise LeaseError("conflicting boot request")
                row = connection.execute("SELECT * FROM sessions WHERE session_id=?",
                                         (existing[1],)).fetchone()
                return Session(row["account_id"], row["period_id"], row["node_id"],
                               row["session_id"], row["epoch"])
            self._current_period(connection, account, period)
            if self._count(connection, "boot_keys") >= MAX_BOOT_KEYS or self._count(connection, "sessions") >= MAX_SESSIONS:
                raise LeaseError("session capacity reached")
            old = connection.execute("SELECT epoch FROM epochs WHERE account_id=? AND period_id=? AND node_id=?",
                                     (account, period, node)).fetchone()
            epoch = (old[0] + 1) if old is not None else 1
            session_id = secrets.token_hex(16)
            self._audit(connection, "session", boot_request_id)
            connection.execute("INSERT INTO sessions VALUES (?, ?, ?, ?, ?)",
                               (session_id, account, period, node, epoch))
            connection.execute("INSERT INTO boot_keys VALUES (?, ?, ?)",
                               (boot_request_id, digest, session_id))
            connection.execute("""INSERT INTO epochs VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, period_id, node_id) DO UPDATE SET
                epoch=excluded.epoch, session_id=excluded.session_id""",
                               (account, period, node, epoch, session_id))
            connection.execute("""UPDATE leases SET uncertain=1 WHERE account_id=? AND period_id=?
                AND node_id=? AND session_id<>? AND budget>up+down""",
                               (account, period, node, session_id))
            return Session(account, period, node, session_id, epoch)

    @staticmethod
    def _lease(row: sqlite3.Row) -> Lease:
        return Lease(row["lease_id"], row["account_id"], row["period_id"], row["node_id"],
                     row["session_id"], row["epoch"], row["budget"], row["expires_at"],
                     row["accounting_version"])

    def grant(self, account: str, period: str, node: str, session_id: str,
              epoch: int, grant_request_id: str, requested_bytes: int) -> Lease | None:
        for value, label in ((account, "account"), (period, "period"), (node, "node"),
                             (session_id, "session"), (grant_request_id, "grant request")):
            _name(value, label)
        _integer(epoch, "epoch", 1)
        _integer(requested_bytes, "requested bytes", 1, MAX_LEASE_BYTES)
        digest = _digest(account, period, node, session_id, epoch, requested_bytes)
        with self._transaction() as connection:
            existing = connection.execute("SELECT digest, lease_id FROM grant_keys WHERE request_id=?",
                                          (grant_request_id,)).fetchone()
            if existing is not None:
                if existing[0] != digest:
                    raise LeaseError("conflicting grant request")
                if existing[1] is None:
                    return None
                row = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                         (existing[1],)).fetchone()
                return self._lease(row)
            self._current_period(connection, account, period)
            current = connection.execute("""SELECT epoch, session_id FROM epochs
                WHERE account_id=? AND period_id=? AND node_id=?""",
                                         (account, period, node)).fetchone()
            if current is None or current[0] != epoch or current[1] != session_id:
                raise LeaseError("stale or unknown node session")
            if self._count(connection, "grant_keys") >= MAX_GRANT_KEYS:
                raise LeaseError("grant request capacity reached")
            balance = self._balance(connection, account, period)
            granted = min(requested_bytes, balance.remaining_bytes)
            if granted and self._count(connection, "leases") >= MAX_LEASES:
                raise LeaseError("lease capacity reached")
            self._audit(connection, "grant", grant_request_id)
            if granted == 0:
                connection.execute("INSERT INTO grant_keys VALUES (?, ?, NULL, 0)",
                                   (grant_request_id, digest))
                return None
            now = self.clock()
            _integer(now, "clock", 0, MAX_SQLITE_INT - LEASE_TTL)
            lease_id = secrets.token_hex(16)
            expires = now + LEASE_TTL
            connection.execute("""INSERT INTO leases
                (lease_id,account_id,period_id,node_id,session_id,epoch,budget,expires_at,accounting_version)
                VALUES (?,?,?,?,?,?,?,?,?)""",
                               (lease_id, account, period, node, session_id, epoch,
                                granted, expires, ACCOUNTING_VERSION))
            connection.execute("INSERT INTO grant_keys VALUES (?, ?, ?, ?)",
                               (grant_request_id, digest, lease_id, granted))
            return Lease(lease_id, account, period, node, session_id, epoch,
                         granted, expires)

    def report(self, record: UsageRecord) -> ReportResult:
        with self._transaction() as connection:
            row = connection.execute("SELECT * FROM leases WHERE lease_id=?",
                                     (record.lease_id,)).fetchone()
            if row is None or any((row[column] != value) for column, value in (
                    ("account_id", record.account_id), ("period_id", record.period_id),
                    ("node_id", record.node_id), ("session_id", record.session_id),
                    ("epoch", record.epoch), ("accounting_version", record.accounting_version))):
                raise LeaseError("report identity mismatch")
            _integer(record.sequence, "sequence", 1)
            _integer(record.up, "uplink")
            _integer(record.down, "downlink")
            digest = _digest(record.lease_id, record.account_id, record.period_id,
                             record.node_id, record.session_id, record.epoch,
                             record.accounting_version, record.sequence, record.up, record.down)
            result = ReportResult("ACK", row["sequence"], row["up"], row["down"])
            if record.sequence == row["sequence"]:
                if row["last_digest"] != digest:
                    raise LeaseError("conflicting latest report")
                return result
            if record.sequence < row["sequence"]:
                return ReportResult("STALE", row["sequence"], row["up"], row["down"])
            current = connection.execute("SELECT current_period FROM accounts WHERE account_id=?",
                                         (record.account_id,)).fetchone()
            if current is None or current[0] != record.period_id:
                raise LeaseError("closed period")
            if record.up < row["up"] or record.down < row["down"]:
                raise LeaseError("counter rollback")
            if record.up + record.down > row["budget"]:
                raise LeaseError("lease budget exceeded")
            self._audit(connection, "report", record.lease_id)
            connection.execute("""UPDATE leases SET up=?, down=?, sequence=?, last_digest=?
                WHERE lease_id=?""", (record.up, record.down, record.sequence,
                                      digest, record.lease_id))
            return ReportResult("ACK", record.sequence, record.up, record.down)

    def expire_leases(self) -> int:
        now = self.clock()
        _integer(now, "clock")
        with self._transaction() as connection:
            rows = connection.execute("""SELECT lease_id FROM leases WHERE expires_at<=?
                AND uncertain=0 AND budget>up+down""", (now,)).fetchall()
            if rows:
                self._audit(connection, "expire", str(now))
                connection.execute("""UPDATE leases SET uncertain=1 WHERE expires_at<=?
                    AND uncertain=0 AND budget>up+down""", (now,))
            return len(rows)

    def rollover(self, account: str, old_period: str, new_period: str, quota: int) -> None:
        for value, label in ((account, "account"), (old_period, "old period"),
                             (new_period, "new period")):
            _name(value, label)
        _integer(quota, "quota")
        if old_period == new_period:
            raise LeaseError("period must change")
        with self._transaction() as connection:
            self._current_period(connection, account, old_period)
            if self._balance(connection, account, old_period).held_bytes:
                raise LeaseError("pending leases block rollover")
            if connection.execute("SELECT 1 FROM periods WHERE account_id=? AND period_id=?",
                                  (account, new_period)).fetchone() is not None:
                raise LeaseError("period id already used")
            count = connection.execute("SELECT COUNT(*) FROM periods WHERE account_id=?",
                                       (account,)).fetchone()[0]
            if count >= MAX_PERIODS_PER_ACCOUNT:
                raise LeaseError("period capacity reached")
            self._audit(connection, "rollover", new_period)
            connection.execute("INSERT INTO periods VALUES (?, ?, ?)", (account, new_period, quota))
            connection.execute("UPDATE accounts SET current_period=? WHERE account_id=?",
                               (new_period, account))

    def snapshot(self, account: str, period: str) -> Balance:
        _name(account, "account")
        _name(period, "period")
        try:
            with self._connection() as connection:
                connection.execute("BEGIN")
                self._check_database(connection)
                balance = self._balance(connection, account, period)
                connection.commit()
                return balance
        except sqlite3.Error as error:
            raise LeaseError(f"center unavailable: {error}") from error
