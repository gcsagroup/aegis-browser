"""Local two-node lease fixture; no Xray, real identity, or external traffic."""

from __future__ import annotations

import concurrent.futures
import socket
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from lease_ledger import (MAX_AUDIT, MAX_BOOT_KEYS, MAX_GRANT_KEYS, LeaseLedger,
                          LeaseError, ReportResult, Session, UsageRecord)
from lease_node import MAX_JOURNAL_ROWS, NodeJournal, NodeError


class Clock:
    def __init__(self) -> None:
        self.value = 0

    def now(self) -> int:
        return self.value


def injected_failure() -> None:
    raise RuntimeError("injected transaction failure")


class LeaseLedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="aegis-w2-leases-")
        self.addCleanup(self.temporary.cleanup)
        self.db = Path(self.temporary.name) / "center.db"
        self.clock = Clock()
        self.center = LeaseLedger(self.db, self.clock.now, create=True)
        self.center.configure("acct", "p1", 10)

    def session(self, node: str, boot: str | None = None):
        return self.center.start_session("acct", "p1", node, boot or f"boot-{node}")

    def test_lost_grant_reply_and_partial_grant_retry_preserve_budget(self) -> None:
        a = self.session("A")
        b = self.session("B")
        first = self.center.grant("acct", "p1", "A", a.session_id, a.epoch, "grant-A", 7)
        second = self.center.grant("acct", "p1", "B", b.session_id, b.epoch, "grant-B", 7)
        self.assertEqual((first.budget_bytes, second.budget_bytes), (7, 3))
        self.assertEqual(self.center.snapshot("acct", "p1").held_bytes, 10)
        reopened = LeaseLedger(self.db, self.clock.now)
        self.assertEqual(reopened.grant("acct", "p1", "B", b.session_id, b.epoch,
                                        "grant-B", 7), second)
        self.assertEqual(reopened.snapshot("acct", "p1").held_bytes, 10)
        with self.assertRaises(LeaseError):
            reopened.grant("acct", "p1", "B", b.session_id, b.epoch, "grant-B", 6)

    def test_concurrent_nodes_and_same_key_retry_never_overgrant(self) -> None:
        a = self.session("A")
        b = self.session("B")
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            pending = [
                pool.submit(self.center.grant, "acct", "p1", node, session.session_id,
                            session.epoch, request, 7)
                for node, session, request in (("A", a, "grant-A"), ("B", b, "grant-B"),
                                               ("A", a, "grant-A"), ("B", b, "grant-B"))
            ]
            results = [task.result(timeout=5) for task in pending]
        self.assertEqual(results[0], results[2])
        self.assertEqual(results[1], results[3])
        self.assertEqual(sorted((results[0].budget_bytes, results[1].budget_bytes)), [3, 7])
        balance = self.center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.remaining_bytes), (0, 10, 0))

    def test_old_boot_retry_does_not_reactivate_fenced_epoch(self) -> None:
        first = self.session("A")
        lease = self.center.grant("acct", "p1", "A", first.session_id,
                                  first.epoch, "grant-A", 4)
        second = self.session("A", "boot-A-new")
        self.assertGreater(second.epoch, first.epoch)
        self.assertEqual(self.session("A"), first)
        self.assertEqual(self.center.snapshot("acct", "p1").uncertain_bytes, 4)
        self.assertEqual(self.center.grant("acct", "p1", "A", first.session_id,
                                           first.epoch, "grant-A", 4), lease)
        with self.assertRaises(LeaseError):
            self.center.grant("acct", "p1", "A", first.session_id,
                              first.epoch, "new-old-epoch", 1)

    def test_report_replay_stale_and_wrong_owner_do_not_change_balance(self) -> None:
        a = self.session("A")
        lease = self.center.grant("acct", "p1", "A", a.session_id, a.epoch, "grant-A", 7)
        one = UsageRecord.for_lease(lease, sequence=1, up=2, down=1)
        self.assertEqual(self.center.report(one).status, "ACK")
        self.assertEqual(self.center.report(one).status, "ACK")
        three = UsageRecord.for_lease(lease, sequence=3, up=4, down=1)
        self.assertEqual(self.center.report(three).status, "ACK")
        self.assertEqual(self.center.report(one).status, "STALE")
        wrong = UsageRecord.for_lease(lease, sequence=0, up=0, down=0,
                                      session_id="wrong-session")
        with self.assertRaisesRegex(LeaseError, "identity mismatch"):
            self.center.report(wrong)
        for bad in (UsageRecord.for_lease(lease, sequence=3, up=4, down=2),
                    UsageRecord.for_lease(lease, sequence=4, up=3, down=2),
                    UsageRecord.for_lease(lease, sequence=4, up=7, down=1)):
            with self.assertRaises(LeaseError):
                self.center.report(bad)
        balance = self.center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.uncertain_bytes, balance.remaining_bytes), (5, 2, 0, 3))

    def test_rollover_rejects_held_then_closes_old_new_grants(self) -> None:
        a = self.session("A")
        lease = self.center.grant("acct", "p1", "A", a.session_id, a.epoch, "grant-A", 4)
        with self.assertRaises(LeaseError):
            self.center.rollover("acct", "p1", "p2", 6)
        final = UsageRecord.for_lease(lease, sequence=1, up=3, down=1)
        self.center.report(final)
        self.center.rollover("acct", "p1", "p2", 6)
        with self.assertRaises(LeaseError):
            self.center.start_session("acct", "p1", "A", "new-old-boot")
        with self.assertRaises(LeaseError):
            self.center.grant("acct", "p1", "A", a.session_id, a.epoch, "new-old-grant", 1)
        self.assertEqual(self.center.start_session("acct", "p1", "A", "boot-A"), a)
        self.assertEqual(self.center.grant("acct", "p1", "A", a.session_id,
                                           a.epoch, "grant-A", 4), lease)
        self.assertEqual(self.center.report(final).status, "ACK")
        self.assertEqual(self.center.snapshot("acct", "p2").remaining_bytes, 6)

    def test_old_partial_grant_retry_after_expiry_and_epoch_change_is_historical(self) -> None:
        a = self.session("A")
        b = self.session("B")
        self.center.grant("acct", "p1", "A", a.session_id, a.epoch, "grant-A", 7)
        partial = self.center.grant("acct", "p1", "B", b.session_id, b.epoch,
                                    "grant-B", 7)
        self.clock.value = partial.expires_at
        self.center.expire_leases()
        self.center.start_session("acct", "p1", "B", "boot-B-next")
        reopened = LeaseLedger(self.db, self.clock.now)
        self.assertEqual(reopened.grant("acct", "p1", "B", b.session_id,
                                        b.epoch, "grant-B", 7), partial)
        self.assertEqual(reopened.snapshot("acct", "p1").remaining_bytes, 0)
        self.assertEqual(reopened.snapshot("acct", "p1").uncertain_bytes, 10)

    def test_boot_key_capacity_survives_restart_and_known_retry(self) -> None:
        first = self.session("A")
        for index in range(1, MAX_BOOT_KEYS):
            self.center.start_session("acct", "p1", "A", f"boot-{index}")
        reopened = LeaseLedger(self.db, self.clock.now)
        self.assertEqual(reopened.start_session("acct", "p1", "A", "boot-A"), first)
        with self.assertRaisesRegex(LeaseError, "capacity"):
            reopened.start_session("acct", "p1", "A", "boot-extra")
        with self.assertRaises(LeaseError):
            reopened.start_session("acct", "p1", "A", "é" * 65)

    def test_audit_cap_fails_closed_but_last_report_retries_after_restart(self) -> None:
        a = self.session("A")
        lease = self.center.grant("acct", "p1", "A", a.session_id, a.epoch,
                                  "grant-A", 1)
        # configure + boot + grant already occupy three durable audit rows.
        for sequence in range(1, MAX_AUDIT - 2):
            self.center.report(UsageRecord.for_lease(lease, sequence, 0, 0))
        latest = UsageRecord.for_lease(lease, MAX_AUDIT - 3, 0, 0)
        reopened = LeaseLedger(self.db, self.clock.now)
        self.assertEqual(reopened.report(latest).status, "ACK")
        with self.assertRaisesRegex(LeaseError, "audit capacity"):
            reopened.report(UsageRecord.for_lease(lease, MAX_AUDIT - 2, 1, 0))
        self.assertEqual(reopened.snapshot("acct", "p1").held_bytes, 1)

    def test_rollover_and_new_old_period_grant_serialize(self) -> None:
        a = self.session("A")
        first = self.center.grant("acct", "p1", "A", a.session_id, a.epoch,
                                  "grant-A", 4)
        self.center.report(UsageRecord.for_lease(first, 1, 4, 0))

        def grant_remaining() -> bool:
            try:
                self.center.grant("acct", "p1", "A", a.session_id, a.epoch,
                                  "grant-remaining", 6)
                return True
            except LeaseError:
                return False

        def advance_period() -> bool:
            try:
                self.center.rollover("acct", "p1", "p2", 5)
                return True
            except LeaseError:
                return False

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            granted = pool.submit(grant_remaining)
            rolled = pool.submit(advance_period)
            self.assertNotEqual(granted.result(timeout=5), rolled.result(timeout=5))

    def test_grant_failure_before_commit_rolls_back_key_lease_and_balance(self) -> None:
        a = self.session("A")
        self.center.fail_before_commit = injected_failure
        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.center.grant("acct", "p1", "A", a.session_id, a.epoch, "grant-A", 4)
        reopened = LeaseLedger(self.db, self.clock.now)
        self.assertEqual(reopened.snapshot("acct", "p1").remaining_bytes, 10)
        self.assertEqual(reopened.grant("acct", "p1", "A", a.session_id,
                                        a.epoch, "grant-A", 4).budget_bytes, 4)

    def test_report_failure_before_commit_rolls_back_watermark_and_usage(self) -> None:
        a = self.session("A")
        lease = self.center.grant("acct", "p1", "A", a.session_id, a.epoch,
                                  "grant-A", 4)
        report = UsageRecord.for_lease(lease, 1, 3, 1)
        self.center.fail_before_commit = injected_failure
        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.center.report(report)
        reopened = LeaseLedger(self.db, self.clock.now)
        self.assertEqual((reopened.snapshot("acct", "p1").actual_bytes,
                          reopened.snapshot("acct", "p1").held_bytes), (0, 4))
        self.assertEqual(reopened.report(report).status, "ACK")
        self.assertEqual(reopened.snapshot("acct", "p1").actual_bytes, 4)

    def test_expiry_marks_uncertain_only_when_explicitly_observed(self) -> None:
        a = self.session("A")
        lease = self.center.grant("acct", "p1", "A", a.session_id, a.epoch,
                                  "grant-A", 4)
        self.clock.value = lease.expires_at
        self.assertEqual(self.center.snapshot("acct", "p1").uncertain_bytes, 0)
        self.assertEqual(self.center.expire_leases(), 1)
        self.assertEqual(self.center.expire_leases(), 0)
        balance = self.center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.uncertain_bytes, balance.remaining_bytes), (0, 4, 4, 6))
        self.center.report(UsageRecord.for_lease(lease, 1, 2, 0))
        balance = self.center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.uncertain_bytes, balance.remaining_bytes), (2, 2, 2, 6))

    def test_old_period_duplicate_stale_conflict_and_new_sequence_are_distinct(self) -> None:
        a = self.session("A")
        lease = self.center.grant("acct", "p1", "A", a.session_id, a.epoch,
                                  "grant-A", 4)
        old = UsageRecord.for_lease(lease, 1, 2, 0)
        final = UsageRecord.for_lease(lease, 2, 4, 0)
        self.center.report(old)
        self.center.report(final)
        self.center.rollover("acct", "p1", "p2", 6)
        self.assertEqual(self.center.report(final).status, "ACK")
        self.assertEqual(self.center.report(old).status, "STALE")
        with self.assertRaisesRegex(LeaseError, "conflicting"):
            self.center.report(UsageRecord.for_lease(lease, 2, 3, 1))
        with self.assertRaisesRegex(LeaseError, "closed period"):
            self.center.report(UsageRecord.for_lease(lease, 3, 4, 0))
        self.assertEqual(self.center.snapshot("acct", "p2").remaining_bytes, 6)

    def test_grant_key_capacity_retains_partial_and_denial_history(self) -> None:
        self.center.configure("large", "p1", MAX_GRANT_KEYS - 1)
        session = self.center.start_session("large", "p1", "A", "boot-large")
        for index in range(MAX_GRANT_KEYS - 1):
            lease = self.center.grant("large", "p1", "A", session.session_id,
                                      session.epoch, f"grant-{index}", 1)
            self.assertEqual(lease.budget_bytes, 1)
        denied = self.center.grant("large", "p1", "A", session.session_id,
                                    session.epoch, "grant-denied", 1)
        self.assertIsNone(denied)
        reopened = LeaseLedger(self.db, self.clock.now)
        self.assertIsNone(reopened.grant("large", "p1", "A", session.session_id,
                                          session.epoch, "grant-denied", 1))
        with self.assertRaisesRegex(LeaseError, "capacity"):
            reopened.grant("large", "p1", "A", session.session_id,
                           session.epoch, "grant-extra", 1)
        self.assertEqual(reopened.snapshot("large", "p1").remaining_bytes, 0)

    def test_missing_center_requires_explicit_initialization(self) -> None:
        missing = Path(self.temporary.name) / "missing-center.db"
        with self.assertRaises(LeaseError):
            LeaseLedger(missing, self.clock.now)
        fresh = LeaseLedger(missing, self.clock.now, create=True)
        fresh.configure("first", "p1", 1)
        self.assertEqual(LeaseLedger(missing, self.clock.now).snapshot("first", "p1").quota_bytes, 1)

    def test_account_period_and_utf8_id_caps_survive_restart(self) -> None:
        for index in range(2, 9):
            self.center.configure(f"account-{index}", "p1", 0)
        reopened = LeaseLedger(self.db, self.clock.now)
        with self.assertRaisesRegex(LeaseError, "account capacity"):
            reopened.configure("account-9", "p1", 0)
        with self.assertRaises(LeaseError):
            reopened.start_session("acct", "p1", "A", "é" * 65)
        for index in range(2, 9):
            reopened.rollover("acct", f"p{index - 1}", f"p{index}", 10)
        with self.assertRaisesRegex(LeaseError, "period capacity"):
            LeaseLedger(self.db, self.clock.now).rollover("acct", "p8", "p9", 10)

    def test_lease_byte_cap_rejects_oversized_request(self) -> None:
        session = self.session("A")
        with self.assertRaises(LeaseError):
            self.center.grant("acct", "p1", "A", session.session_id,
                              session.epoch, "oversized", 64 * 1024 + 1)
        self.assertEqual(self.center.snapshot("acct", "p1").remaining_bytes, 10)


class NodeJournalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="aegis-w2-node-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.clock = Clock()
        self.center = LeaseLedger(root / "center.db", self.clock.now, create=True)
        self.center.configure("acct", "p1", 10)
        self.path = root / "A.db"
        self.node = NodeJournal(self.path, "A", self.clock.now, create=True)
        self.session = self.center.start_session("acct", "p1", "A", "boot-A")
        self.node.activate(self.session)
        self.lease = self.center.grant("acct", "p1", "A", self.session.session_id,
                                       self.session.epoch, "grant-A", 7)
        self.node.remember(self.lease)

    def test_prepared_chunk_is_not_replayed_after_reopen(self) -> None:
        chunk = self.node.prepare(self.lease.lease_id, "up", 4)
        reopened = NodeJournal(self.path, "A", self.clock.now)
        received: list[tuple[str, int]] = []
        with self.assertRaises(NodeError):
            reopened.send(chunk, lambda direction, count: received.append((direction, count)))
        self.assertEqual(received, [])
        self.assertEqual(reopened.local_balance(self.lease.lease_id), (0, 0, 4))
        self.assertEqual(self.center.snapshot("acct", "p1").held_bytes, 7)

    def test_send_then_crash_before_complete_stays_uncertain(self) -> None:
        chunk = self.node.prepare(self.lease.lease_id, "up", 4)
        received: list[tuple[str, int]] = []
        self.node.send(chunk, lambda direction, count: received.append((direction, count)))
        self.assertEqual(received, [("up", 4)])
        reopened = NodeJournal(self.path, "A", self.clock.now)
        self.assertEqual(reopened.local_balance(self.lease.lease_id), (0, 0, 4))
        with self.assertRaises(NodeError):
            reopened.complete(chunk)
        newer = self.center.start_session("acct", "p1", "A", "boot-A-2")
        reopened.activate(newer)
        self.assertEqual(self.center.snapshot("acct", "p1").uncertain_bytes, 7)

    def test_completed_chunk_replays_report_without_resending(self) -> None:
        chunk = self.node.prepare(self.lease.lease_id, "down", 4)
        received: list[tuple[str, int]] = []
        self.node.send(chunk, lambda direction, count: received.append((direction, count)))
        self.node.complete(chunk)
        report = self.node.pending_report(self.lease.lease_id)
        reopened = NodeJournal(self.path, "A", self.clock.now)
        self.assertEqual(reopened.pending_report(self.lease.lease_id), report)
        self.assertEqual(self.center.report(report).status, "ACK")
        self.assertEqual(self.center.report(report).status, "ACK")
        reopened.ack(report, self.center.report(report))
        self.assertEqual(reopened.local_balance(self.lease.lease_id), (0, 4, 4))
        self.assertEqual(received, [("down", 4)])
        self.assertEqual(self.center.snapshot("acct", "p1").actual_bytes, 4)

    def test_expiry_between_prepare_and_send_blocks_sink(self) -> None:
        chunk = self.node.prepare(self.lease.lease_id, "up", 3)
        self.clock.value = self.lease.expires_at
        received: list[tuple[str, int]] = []
        with self.assertRaises(NodeError):
            self.node.send(chunk, lambda direction, count: received.append((direction, count)))
        self.assertEqual(received, [])
        self.assertEqual(self.node.local_balance(self.lease.lease_id), (0, 0, 3))
        self.center.expire_leases()
        self.assertEqual(self.center.snapshot("acct", "p1").uncertain_bytes, 7)

    def test_fence_is_scoped_and_late_lease_does_not_clear_it(self) -> None:
        second = self.center.start_session("acct", "p1", "A", "boot-A-2")
        self.node.learn_fence("acct", "p1", "A", second.epoch)
        with self.assertRaises(NodeError):
            self.node.prepare(self.lease.lease_id, "up", 1)
        reopened = NodeJournal(self.path, "A", self.clock.now)
        with self.assertRaises(NodeError):
            reopened.remember(self.lease)
        self.center.configure("other", "p1", 2)
        for index in range(3):
            old = self.center.start_session("other", "p1", "A", f"boot-other-{index}")
        reopened.activate(old)
        self.center.rollover("other", "p1", "p2", 2)
        current = self.center.start_session("other", "p2", "A", "boot-other-p2")
        reopened.activate(current)
        self.assertEqual(reopened.max_seen_epoch("other", "p1", "A"), 3)
        self.assertEqual(reopened.max_seen_epoch("other", "p2", "A"), 1)
        self.assertEqual(reopened.max_seen_epoch("acct", "p1", "A"), second.epoch)
        reopened.learn_fence("other", "p1", "A", 5)
        current_lease = self.center.grant("other", "p2", "A", current.session_id,
                                          current.epoch, "grant-other-p2", 1)
        reopened.remember(current_lease)
        reopened.prepare(current_lease.lease_id, "up", 1)

    def test_invalid_fence_message_blocks_corresponding_scope(self) -> None:
        with self.assertRaises(LeaseError):
            self.node.learn_fence("acct", "p1", "A", 0)
        with self.assertRaises(NodeError):
            self.node.prepare(self.lease.lease_id, "up", 1)

    def test_failed_fence_persist_blocks_send_in_this_process(self) -> None:
        self.node.fail_before_commit = injected_failure
        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.node.learn_fence("acct", "p1", "A", 2)
        self.node.fail_before_commit = None
        self.assertEqual(self.node.max_seen_epoch("acct", "p1", "A"), 1)
        with self.assertRaises(NodeError):
            self.node.prepare(self.lease.lease_id, "up", 1)

    def test_failed_new_session_activation_blocks_old_prepared_and_new_sends(self) -> None:
        prepared = self.node.prepare(self.lease.lease_id, "up", 1)
        newer = self.center.start_session("acct", "p1", "A", "boot-next")
        self.node.fail_before_commit = injected_failure
        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.node.activate(newer)
        self.node.fail_before_commit = None
        received: list[tuple[str, int]] = []
        with self.assertRaises(NodeError):
            self.node.prepare(self.lease.lease_id, "up", 1)
        with self.assertRaises(NodeError):
            self.node.send(prepared, lambda direction, count: received.append((direction, count)))
        self.assertEqual(received, [])
        self.assertEqual(self.node.max_seen_epoch("acct", "p1", "A"), 1)
        self.assertEqual(self.center.snapshot("acct", "p1").uncertain_bytes, 7)

    def test_failed_local_complete_keeps_chunk_unconfirmed_after_reopen(self) -> None:
        chunk = self.node.prepare(self.lease.lease_id, "up", 2)
        self.node.send(chunk, lambda direction, count: None)
        self.node.fail_before_commit = injected_failure
        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.node.complete(chunk)
        reopened = NodeJournal(self.path, "A", self.clock.now)
        self.assertEqual(reopened.local_balance(self.lease.lease_id), (0, 0, 2))
        with self.assertRaises(NodeError):
            reopened.complete(chunk)

    def test_offline_old_epoch_and_new_epoch_share_original_account_budget(self) -> None:
        old = self.node
        newer = self.center.start_session("acct", "p1", "A", "boot-A-next")
        new_node = NodeJournal(Path(self.temporary.name) / "A-new.db", "A",
                               self.clock.now, create=True)
        new_node.activate(newer)
        new_lease = self.center.grant("acct", "p1", "A", newer.session_id,
                                      newer.epoch, "grant-new", 7)
        self.assertEqual(new_lease.budget_bytes, 3)
        new_node.remember(new_lease)
        observed: list[tuple[str, int]] = []
        chunk = old.prepare(self.lease.lease_id, "up", 4)
        old.send(chunk, lambda direction, count: observed.append((direction, count)))
        old.complete(chunk)
        self.center.report(old.pending_report(self.lease.lease_id))
        balance = self.center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.uncertain_bytes, balance.remaining_bytes), (4, 6, 3, 0))
        self.assertEqual(observed, [("up", 4)])
        old.learn_fence("acct", "p1", "A", newer.epoch)
        with self.assertRaises(NodeError):
            old.prepare(self.lease.lease_id, "up", 1)

    def test_no_new_completion_needs_no_new_report(self) -> None:
        self.assertIsNone(self.node.pending_report(self.lease.lease_id))
        chunk = self.node.prepare(self.lease.lease_id, "up", 2)
        self.node.send(chunk, lambda direction, count: None)
        self.node.complete(chunk)
        report = self.node.pending_report(self.lease.lease_id)
        self.node.ack(report, self.center.report(report))
        self.assertIsNone(self.node.pending_report(self.lease.lease_id))

    def test_stale_response_cannot_fabricate_local_completion(self) -> None:
        chunk = self.node.prepare(self.lease.lease_id, "up", 2)
        self.node.send(chunk, lambda direction, count: None)
        self.node.complete(chunk)
        pending = self.node.pending_report(self.lease.lease_id)
        with self.assertRaisesRegex(NodeError, "exceeds pending durable completion"):
            self.node.ack(pending, ReportResult("STALE", 2, 4, 0))
        self.assertEqual(self.node.pending_report(self.lease.lease_id), pending)
        self.assertEqual(self.node.local_balance(self.lease.lease_id), (2, 0, 2))

    def test_stale_response_cannot_ack_later_unreported_completion(self) -> None:
        first = self.node.prepare(self.lease.lease_id, "up", 2)
        self.node.send(first, lambda direction, count: None)
        self.node.complete(first)
        pending = self.node.pending_report(self.lease.lease_id)
        second = self.node.prepare(self.lease.lease_id, "up", 1)
        self.node.send(second, lambda direction, count: None)
        self.node.complete(second)
        with self.assertRaisesRegex(NodeError, "exceeds pending durable completion"):
            self.node.ack(pending, ReportResult("STALE", 2, 3, 0))
        self.assertEqual(self.node.pending_report(self.lease.lease_id), pending)

    def test_journal_chunk_cap_survives_reopen_and_new_epoch(self) -> None:
        self.center.configure("large", "p1", MAX_JOURNAL_ROWS + 1)
        first = self.center.start_session("large", "p1", "A", "boot-large-1")
        self.node.activate(first)
        lease = self.center.grant("large", "p1", "A", first.session_id,
                                  first.epoch, "grant-large", MAX_JOURNAL_ROWS)
        self.node.remember(lease)
        for _ in range(MAX_JOURNAL_ROWS):
            self.node.prepare(lease.lease_id, "up", 1)
        second = self.center.start_session("large", "p1", "A", "boot-large-2")
        next_lease = self.center.grant("large", "p1", "A", second.session_id,
                                       second.epoch, "grant-large-next", 1)
        reopened = NodeJournal(self.path, "A", self.clock.now)
        reopened.activate(second)
        reopened.remember(next_lease)
        with self.assertRaisesRegex(NodeError, "capacity"):
            reopened.prepare(next_lease.lease_id, "up", 1)

    def test_missing_node_journal_requires_explicit_initialization(self) -> None:
        missing = Path(self.temporary.name) / "missing-A.db"
        with self.assertRaises(NodeError):
            NodeJournal(missing, "A", self.clock.now)
        NodeJournal(missing, "A", self.clock.now, create=True)
        self.assertEqual(NodeJournal(missing, "A", self.clock.now).node_id, "A")

    def test_expiry_during_sending_commit_prevents_sink(self) -> None:
        prepared = self.node.prepare(self.lease.lease_id, "up", 1)
        self.node.fail_before_commit = lambda: setattr(self.clock, "value", self.lease.expires_at)
        received: list[tuple[str, int]] = []
        with self.assertRaisesRegex(NodeError, "expired"):
            self.node.send(prepared, lambda direction, count: received.append((direction, count)))
        self.node.fail_before_commit = None
        self.assertEqual(received, [])
        self.assertEqual(self.node.local_balance(self.lease.lease_id), (0, 0, 1))
        reopened = NodeJournal(self.path, "A", self.clock.now)
        with self.assertRaises(NodeError):
            reopened.send(prepared, lambda direction, count: received.append((direction, count)))
        self.assertEqual(received, [])

    def test_prepare_failure_and_session_cap_fail_closed_after_reopen(self) -> None:
        self.node.fail_before_commit = injected_failure
        with self.assertRaisesRegex(RuntimeError, "injected"):
            self.node.prepare(self.lease.lease_id, "up", 1)
        reopened = NodeJournal(self.path, "A", self.clock.now)
        self.assertEqual(reopened.local_balance(self.lease.lease_id), (0, 0, 0))
        for index in range(2, MAX_JOURNAL_ROWS + 1):
            reopened.activate(Session("acct", "p1", "A", f"session-{index}", index))
        with self.assertRaisesRegex(NodeError, "session journal capacity"):
            reopened.activate(Session("acct", "p1", "A", "overflow", MAX_JOURNAL_ROWS + 1))
        self.assertEqual(NodeJournal(self.path, "A", self.clock.now).max_seen_epoch(
            "acct", "p1", "A"), MAX_JOURNAL_ROWS)

    def test_fence_scope_rows_are_bounded_across_restarts(self) -> None:
        for index in range(MAX_JOURNAL_ROWS - 1):
            self.node.learn_fence("acct", f"other-p{index}", "A", 1)
        reopened = NodeJournal(self.path, "A", self.clock.now)
        self.assertEqual(reopened.max_seen_epoch("acct", "p1", "A"), 1)
        with self.assertRaisesRegex(NodeError, "capacity"):
            reopened.learn_fence("acct", "overflow", "A", 1)
        self.assertTrue(reopened.blocked_all)
        self.assertEqual(len(reopened.blocked_scopes), 0)

    def test_rejected_fence_inputs_do_not_grow_failure_tracking(self) -> None:
        for index in range(1000):
            with self.assertRaises(LeaseError):
                self.node.learn_fence("acct", "x" * 129 + str(index), "A", 2)
        self.assertEqual(len(self.node.blocked_scopes), 0)
        self.assertFalse(self.node.blocked_all)
        with self.assertRaises(LeaseError):
            self.node.learn_fence("acct", "p1", "A", 0)
        self.assertEqual(len(self.node.blocked_scopes), 1)
        with self.assertRaises(NodeError):
            self.node.prepare(self.lease.lease_id, "up", 1)

    def test_node_rejects_oversized_session_and_lease_identifiers(self) -> None:
        with self.assertRaises(NodeError):
            self.node.activate(Session("acct", "p1", "A", "x" * 129, 2))
        with self.assertRaises(NodeError):
            self.node.remember(replace(self.lease, lease_id="x" * 129))
        self.assertEqual(self.node.max_seen_epoch("acct", "p1", "A"), 1)

    def test_lease_must_match_durable_session_and_epoch(self) -> None:
        with self.assertRaisesRegex(NodeError, "durable node session"):
            self.node.remember(replace(self.lease, lease_id="other", epoch=2))
        with self.assertRaisesRegex(NodeError, "conflicting local session"):
            self.node.activate(replace(self.session, account_id="other"))
        self.assertEqual(self.node.max_seen_epoch("acct", "p1", "A"), 1)

    def test_stale_response_cannot_roll_back_prior_acknowledgment(self) -> None:
        first = self.node.prepare(self.lease.lease_id, "up", 2)
        self.node.send(first, lambda direction, count: None)
        self.node.complete(first)
        initial = self.node.pending_report(self.lease.lease_id)
        self.node.ack(initial, self.center.report(initial))
        second = self.node.prepare(self.lease.lease_id, "up", 1)
        self.node.send(second, lambda direction, count: None)
        self.node.complete(second)
        pending = self.node.pending_report(self.lease.lease_id)
        with self.assertRaisesRegex(NodeError, "rolls back"):
            self.node.ack(pending, ReportResult("STALE", pending.sequence + 1, 1, 0))
        self.assertEqual(self.node.pending_report(self.lease.lease_id), pending)

    def test_all_five_crash_windows_reopen_without_releasing_budget(self) -> None:
        for stage in ("grant", "prepared", "sending", "completed", "reported"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as root:
                center_path = Path(root) / "center.db"
                node_path = Path(root) / "node.db"
                center = LeaseLedger(center_path, self.clock.now, create=True)
                center.configure("acct", "p1", 4)
                node = NodeJournal(node_path, "A", self.clock.now, create=True)
                session = center.start_session("acct", "p1", "A", "boot")
                node.activate(session)
                lease = center.grant("acct", "p1", "A", session.session_id,
                                     session.epoch, "grant", 4)
                received: list[tuple[str, int]] = []
                if stage != "grant":
                    node.remember(lease)
                    chunk = node.prepare(lease.lease_id, "up", 4)
                    if stage in ("sending", "completed", "reported"):
                        node.send(chunk, lambda direction, count: received.append((direction, count)))
                    if stage in ("completed", "reported"):
                        node.complete(chunk)
                    if stage == "reported":
                        report = node.pending_report(lease.lease_id)
                        center.report(report)
                center = LeaseLedger(center_path, self.clock.now)
                reopened = NodeJournal(node_path, "A", self.clock.now)
                balance = center.snapshot("acct", "p1")
                expected = (4, 0, 0) if stage == "reported" else (0, 4, 0)
                self.assertEqual((balance.actual_bytes, balance.held_bytes,
                                  balance.uncertain_bytes), expected)
                self.assertEqual(center.grant("acct", "p1", "A", session.session_id,
                                              session.epoch, "grant", 4), lease)
                if stage in ("prepared", "sending"):
                    with self.assertRaises(NodeError):
                        reopened.send(chunk, lambda direction, count: received.append((direction, count)))
                    self.assertEqual(reopened.local_balance(lease.lease_id), (0, 0, 4))
                    center.start_session("acct", "p1", "A", "next-boot")
                    self.assertEqual(center.snapshot("acct", "p1").uncertain_bytes, 4)
                if stage in ("completed", "reported"):
                    if stage == "completed":
                        center.start_session("acct", "p1", "A", "next-boot")
                        self.assertEqual(center.snapshot("acct", "p1").uncertain_bytes, 4)
                    replay = reopened.pending_report(lease.lease_id)
                    self.assertEqual(center.report(replay).status, "ACK")
                    reopened.ack(replay, center.report(replay))
                    balance = center.snapshot("acct", "p1")
                    self.assertEqual((balance.actual_bytes, balance.held_bytes,
                                      balance.uncertain_bytes), (4, 0, 0))
                self.assertEqual(len(received), int(stage in ("sending", "completed", "reported")))

    def test_one_nonblocking_socket_send_counts_only_short_write(self) -> None:
        destination, peer = socket.socketpair()
        self.addCleanup(destination.close)
        self.addCleanup(peer.close)
        destination.setblocking(False)
        peer.settimeout(1)
        chunk = self.node.prepare(self.lease.lease_id, "up", 4)
        self.assertEqual(self.node.send_socket_once(chunk, destination, b"abcd", send_limit=2), 2)
        self.node.complete(chunk)
        self.assertEqual(peer.recv(4), b"ab")
        self.assertEqual(self.node.local_balance(self.lease.lease_id), (2, 0, 4))
        record = self.node.pending_report(self.lease.lease_id)
        self.node.ack(record, self.center.report(record))
        balance = self.center.snapshot("acct", "p1")
        self.assertEqual((balance.actual_bytes, balance.held_bytes,
                          balance.remaining_bytes), (2, 5, 3))
        with self.assertRaises(NodeError):
            self.node.send_socket_once(chunk, destination, b"abcd")

    def test_socket_send_validates_nonblocking_and_exact_prepared_data(self) -> None:
        destination, peer = socket.socketpair()
        self.addCleanup(destination.close)
        self.addCleanup(peer.close)
        chunk = self.node.prepare(self.lease.lease_id, "up", 4)
        with self.assertRaisesRegex(NodeError, "nonblocking"):
            self.node.send_socket_once(chunk, destination, b"abcd")
        destination.setblocking(False)
        with self.assertRaisesRegex(NodeError, "length"):
            self.node.send_socket_once(chunk, destination, b"abc")
        self.assertEqual(self.node.send_socket_once(chunk, destination, b"abcd"), 4)
        self.node.complete(chunk)

    def test_socket_send_rechecks_expiry_after_sending_commit(self) -> None:
        destination, peer = socket.socketpair()
        self.addCleanup(destination.close)
        self.addCleanup(peer.close)
        destination.setblocking(False)
        peer.setblocking(False)
        chunk = self.node.prepare(self.lease.lease_id, "up", 1)
        self.node.fail_before_commit = lambda: setattr(self.clock, "value", self.lease.expires_at)
        with self.assertRaisesRegex(NodeError, "expired"):
            self.node.send_socket_once(chunk, destination, b"a")
        self.node.fail_before_commit = None
        with self.assertRaises(BlockingIOError):
            peer.recv(1)
        self.assertEqual(self.node.local_balance(self.lease.lease_id), (0, 0, 1))


if __name__ == "__main__":
    unittest.main()
