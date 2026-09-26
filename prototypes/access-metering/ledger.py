"""Local W2 byte-permit ledger. This is a fixture, not a service accounting API."""

from __future__ import annotations

import os
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator


MAX_PERMIT_BYTES = 16 * 1024
MAX_PENDING_PERMITS = 8
MAX_SQLITE_INT = 2**63 - 1
APPLICATION_ID = 0x57324D54  # W2MT
SCHEMA_VERSION = 1


class LedgerError(RuntimeError):
    """No byte may be forwarded after a ledger error."""


@dataclass(frozen=True)
class Permit:
    permit_id: str
    granted_bytes: int


@dataclass(frozen=True)
class Balance:
    account_id: str
    period_id: str
    quota_bytes: int
    actual_bytes: int
    held_bytes: int
    uncertain_bytes: int
    remaining_bytes: int


def _name(value: str, label: str) -> None:
    if not isinstance(value, str) or not value or len(value) > 128:
        raise LedgerError(f"invalid {label}")


def _integer(value: int, label: str, minimum: int, maximum: int = MAX_SQLITE_INT) -> None:
    if type(value) is not int or not minimum <= value <= maximum:
        raise LedgerError(f"invalid {label}")


class Ledger:
    def __init__(self, path: str | Path):
        self.path = str(path)
        created = False
        try:
            descriptor = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            pass
        else:
            os.close(descriptor)
            created = True

        try:
            with self._connection() as connection:
                if created:
                    connection.execute("BEGIN EXCLUSIVE")
                    connection.execute("CREATE TABLE accounts (account_id TEXT PRIMARY KEY, current_period TEXT NOT NULL)")
                    connection.execute("CREATE TABLE periods (account_id TEXT NOT NULL, period_id TEXT NOT NULL, quota_bytes INTEGER NOT NULL CHECK(quota_bytes >= 0), PRIMARY KEY(account_id, period_id), FOREIGN KEY(account_id) REFERENCES accounts(account_id))")
                    connection.execute("""CREATE TABLE permits (
                        permit_id TEXT PRIMARY KEY,
                        account_id TEXT NOT NULL,
                        period_id TEXT NOT NULL,
                        stream_id TEXT NOT NULL,
                        direction TEXT NOT NULL CHECK(direction IN ('up', 'down')),
                        sequence INTEGER NOT NULL CHECK(sequence > 0),
                        reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes > 0),
                        actual_bytes INTEGER NOT NULL DEFAULT 0 CHECK(actual_bytes >= 0 AND actual_bytes <= reserved_bytes),
                        state TEXT NOT NULL CHECK(state IN ('PENDING', 'COMPLETE')),
                        uncertain INTEGER NOT NULL DEFAULT 0 CHECK(uncertain IN (0, 1)),
                        UNIQUE(account_id, period_id, stream_id, direction, sequence),
                        FOREIGN KEY(account_id, period_id) REFERENCES periods(account_id, period_id)
                    )""")
                    connection.execute("PRAGMA application_id=0x57324D54")
                    connection.execute("PRAGMA user_version=1")
                    connection.commit()
                self._check_database(connection)
        except sqlite3.Error as error:
            raise LedgerError(f"ledger unavailable: {error}") from error

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        try:
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA synchronous=FULL")
            connection.execute("PRAGMA busy_timeout=5000")
            yield connection
        finally:
            connection.close()

    @staticmethod
    def _check_database(connection: sqlite3.Connection) -> None:
        if connection.execute("PRAGMA quick_check").fetchone() != ("ok",):
            raise LedgerError("ledger integrity check failed")
        if connection.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
            raise LedgerError("unknown ledger application id")
        if connection.execute("PRAGMA user_version").fetchone()[0] != SCHEMA_VERSION:
            raise LedgerError("unknown ledger schema version")
        if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise LedgerError("ledger foreign key check failed")
        # Keep the required-table probes literal: no identifier comes from input.
        connection.execute("SELECT 1 FROM accounts LIMIT 1").fetchone()
        connection.execute("SELECT 1 FROM periods LIMIT 1").fetchone()
        connection.execute("SELECT 1 FROM permits LIMIT 1").fetchone()

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        try:
            with self._connection() as connection:
                try:
                    connection.execute("BEGIN IMMEDIATE")
                    self._check_database(connection)
                    yield connection
                    connection.commit()
                except BaseException:
                    if connection.in_transaction:
                        connection.rollback()
                    raise
        except sqlite3.Error as error:
            raise LedgerError(f"ledger unavailable: {error}") from error

    @staticmethod
    def _active_period(connection: sqlite3.Connection, account_id: str, period_id: str) -> int:
        row = connection.execute("""SELECT periods.quota_bytes FROM accounts
            JOIN periods ON periods.account_id=accounts.account_id AND periods.period_id=accounts.current_period
            WHERE accounts.account_id=? AND accounts.current_period=?""", (account_id, period_id)).fetchone()
        if row is None:
            raise LedgerError("unknown account or stale period")
        return row[0]

    @staticmethod
    def _balance(connection: sqlite3.Connection, account_id: str, period_id: str) -> Balance:
        quota = Ledger._active_period(connection, account_id, period_id)
        actual, held, uncertain = connection.execute("""SELECT
            COALESCE(SUM(CASE WHEN state='COMPLETE' THEN actual_bytes ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN state='PENDING' THEN reserved_bytes ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN state='PENDING' AND uncertain=1 THEN reserved_bytes ELSE 0 END), 0)
            FROM permits WHERE account_id=? AND period_id=?""", (account_id, period_id)).fetchone()
        if min(actual, held, uncertain) < 0 or uncertain > held or actual + held > quota:
            raise LedgerError("inconsistent ledger balance")
        return Balance(account_id, period_id, quota, actual, held, uncertain, quota - actual - held)

    def configure(self, account_id: str, period_id: str, quota_bytes: int) -> None:
        _name(account_id, "account")
        _name(period_id, "period")
        _integer(quota_bytes, "quota", 0)
        with self._transaction() as connection:
            row = connection.execute("SELECT current_period FROM accounts WHERE account_id=?", (account_id,)).fetchone()
            if row is None:
                connection.execute("INSERT INTO accounts VALUES (?, ?)", (account_id, period_id))
                connection.execute("INSERT INTO periods VALUES (?, ?, ?)", (account_id, period_id, quota_bytes))
            elif row[0] != period_id or self._active_period(connection, account_id, period_id) != quota_bytes:
                raise LedgerError("account period or quota mismatch")

    def recover(self) -> int:
        """Relay startup only: retain all old reservations and mark them uncertain."""
        with self._transaction() as connection:
            result = connection.execute("UPDATE permits SET uncertain=1 WHERE state='PENDING'")
            return result.rowcount

    def rollover(self, account_id: str, old_period_id: str, new_period_id: str, quota_bytes: int) -> None:
        _name(account_id, "account")
        _name(old_period_id, "old period")
        _name(new_period_id, "new period")
        _integer(quota_bytes, "quota", 0)
        if old_period_id == new_period_id:
            raise LedgerError("period must change")
        with self._transaction() as connection:
            self._active_period(connection, account_id, old_period_id)
            if self._balance(connection, account_id, old_period_id).held_bytes:
                raise LedgerError("pending permits block rollover")
            if connection.execute("SELECT 1 FROM periods WHERE account_id=? AND period_id=?", (account_id, new_period_id)).fetchone():
                raise LedgerError("period id was already used")
            connection.execute("INSERT INTO periods VALUES (?, ?, ?)", (account_id, new_period_id, quota_bytes))
            connection.execute("UPDATE accounts SET current_period=? WHERE account_id=?", (new_period_id, account_id))

    def prepare(self, account_id: str, period_id: str, stream_id: str, direction: str,
                sequence: int, permit_id: str, requested_bytes: int) -> Permit | None:
        for value, label in ((account_id, "account"), (period_id, "period"),
                             (stream_id, "stream"), (permit_id, "permit")):
            _name(value, label)
        if direction not in ("up", "down"):
            raise LedgerError("invalid direction")
        _integer(sequence, "sequence", 1)
        _integer(requested_bytes, "requested bytes", 1, MAX_PERMIT_BYTES)
        with self._transaction() as connection:
            balance = self._balance(connection, account_id, period_id)
            last = connection.execute("""SELECT COALESCE(MAX(sequence), 0) FROM permits
                WHERE account_id=? AND period_id=? AND stream_id=? AND direction=?""",
                (account_id, period_id, stream_id, direction)).fetchone()[0]
            if sequence != last + 1:
                raise LedgerError("duplicate or out-of-order sequence")
            if connection.execute("SELECT 1 FROM permits WHERE permit_id=?", (permit_id,)).fetchone():
                raise LedgerError("duplicate permit id")
            if balance.remaining_bytes == 0:
                return None
            pending_count = connection.execute(
                "SELECT COUNT(*) FROM permits WHERE state='PENDING'").fetchone()[0]
            if pending_count >= MAX_PENDING_PERMITS:
                raise LedgerError("pending permit cap reached")
            granted = min(requested_bytes, balance.remaining_bytes)
            connection.execute("""INSERT INTO permits
                (permit_id, account_id, period_id, stream_id, direction, sequence, reserved_bytes, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'PENDING')""",
                (permit_id, account_id, period_id, stream_id, direction, sequence, granted))
            return Permit(permit_id, granted)

    def complete(self, permit_id: str, forwarded_bytes: int) -> bool:
        _name(permit_id, "permit")
        _integer(forwarded_bytes, "forwarded bytes", 1, MAX_PERMIT_BYTES)
        with self._transaction() as connection:
            row = connection.execute("""SELECT account_id, period_id, reserved_bytes, actual_bytes, state, uncertain
                FROM permits WHERE permit_id=?""", (permit_id,)).fetchone()
            if row is None:
                raise LedgerError("unknown permit")
            account_id, period_id, reserved, actual, state, uncertain = row
            self._active_period(connection, account_id, period_id)
            if uncertain:
                raise LedgerError("uncertain permit requires external reconciliation proof")
            if forwarded_bytes != reserved:
                raise LedgerError("settlement must match the full forwarded permit")
            if state == "COMPLETE":
                if actual != forwarded_bytes:
                    raise LedgerError("conflicting duplicate settlement")
                return False
            connection.execute("""UPDATE permits SET actual_bytes=?, state='COMPLETE', uncertain=0
                WHERE permit_id=? AND state='PENDING'""", (forwarded_bytes, permit_id))
            return True

    def snapshot(self, account_id: str, period_id: str) -> Balance:
        _name(account_id, "account")
        _name(period_id, "period")
        with self._transaction() as connection:
            return self._balance(connection, account_id, period_id)
