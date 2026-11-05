"""Stdlib unit and historical-semantic regressions; no external runner required."""
import base64
from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import terminal_receipt as tr


def context(**changes):
    return replace(tr.ExpectedContext(1, "unit-task", "ab" * 16, "a" * 40,
                                      "b" * 40, "target-host", "target-boot", 100,
                                      "receiver-boot", (1, 1), 64, 64, 65536, 4096),
                   **changes)


class Clock:
    def __init__(self):
        self.now = 1
        self.boot = "receiver-boot"
        self.timebase = (1, 1)

    def __call__(self):
        return tr.ClockSample(self.now, self.boot, self.timebase)


def data(ctx, seq=0, stream="stdout", value=b"hello"):
    return {"version": 1, "context": ctx.wire(), "seq": seq, "kind": "data",
            "stream": stream, "data": base64.b64encode(value).decode(), "bytes": len(value)}


def terminal(ctx, seq=0, code=0):
    return {"version": 1, "context": ctx.wire(), "seq": seq, "kind": "terminal",
            "actualExit": code, "stdoutEOF": True, "stderrEOF": True,
            "waitObserved": True, "observationSource": "controller-observation"}


def encode(frame):
    return json.dumps(frame, separators=(",", ":")).encode()


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = context()
        self.clock = Clock()
        self.receiver = tr.Receiver(self.ctx, self.clock, self.tmp.name)
        self.addCleanup(self.close_receiver)

    def close_receiver(self):
        if self.receiver.result is None:
            self.receiver.abort("CANCELLED")

    @property
    def slot(self):
        return Path(self.tmp.name, tr.SLOT_NAME)

    def feed(self, frame):
        return self.receiver.feed(encode(frame))

    def test_receives_zero_without_granting_execution(self):
        result = self.feed(terminal(self.ctx))
        self.assertEqual(result["state"], "RECEIVED")
        self.assertEqual(result["actualExit"], 0)
        self.assertIs(result["grantsExecution"], False)
        self.assertEqual(result["storage"], "FSYNC_COMPLETED")
        disk = json.loads(self.slot.read_bytes())
        self.assertEqual(disk["state"], "RECEIVED")
        self.assertIs(disk["stdoutEOF"], True)
        self.assertIs(disk["stderrEOF"], True)
        self.assertIs(disk["waitObserved"], True)
        self.assertEqual(disk["storage"], "UNCONFIRMED")

    def test_all_binding_fields_are_checked(self):
        for key, value in [("taskID", "other"), ("nonce", "cd" * 16),
                           ("productSHA", "c" * 40), ("nativeSHA", "d" * 40),
                           ("hostID", "other"), ("bootID", "other"),
                           ("deadlineNS", 200), ("stdoutMax", 63),
                           ("clockBootID", "other"), ("timebase", [2, 1])]:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as root:
                receiver = tr.Receiver(self.ctx, self.clock, root)
                frame = terminal(self.ctx)
                frame["context"][key] = value
                self.assertEqual(receiver.feed(encode(frame))["state"], "FAILED")

    def test_duplicate_json_key_at_top_and_nested(self):
        for raw in [encode(terminal(self.ctx)).replace(b'"seq":0', b'"seq":0,"seq":0'),
                    encode(terminal(self.ctx)).replace(b'"taskID":"unit-task"',
                                                       b'"taskID":"unit-task","taskID":"unit-task"')]:
            with tempfile.TemporaryDirectory() as root:
                receiver = tr.Receiver(self.ctx, self.clock, root)
                self.assertEqual(receiver.feed(raw)["reason"], "INVALID_FRAME")

    def test_bool_float_and_nonfinite_are_not_integers(self):
        for token in [b'true', b'0.0', b'NaN', b'Infinity', b'-Infinity']:
            with self.subTest(token=token), tempfile.TemporaryDirectory() as root:
                receiver = tr.Receiver(self.ctx, self.clock, root)
                raw = encode(terminal(self.ctx)).replace(b'"actualExit":0', b'"actualExit":' + token)
                self.assertEqual(receiver.feed(raw)["state"], "FAILED")
        with self.assertRaises(ValueError):
            context(deadlineNS=True)
        with self.assertRaises(ValueError):
            context(productSHA="G" * 40)

    def test_exact_deadline_closes_and_late_zero_cannot_replace(self):
        self.clock.now = 100
        first = self.feed(terminal(self.ctx))
        self.assertEqual(first["reason"], "DEADLINE")
        original = self.slot.read_bytes()
        self.clock.now = 101
        with self.assertRaises(tr.ClosedReceipt):
            self.feed(terminal(self.ctx))
        self.assertEqual(self.receiver.result, first)
        self.assertEqual(self.slot.read_bytes(), original)

    def test_deadline_crossed_during_frame_validation(self):
        with patch.object(self.receiver, "_clock", side_effect=[
                tr.ClockSample(99, "receiver-boot", (1, 1)),
                tr.ClockSample(100, "receiver-boot", (1, 1))]):
            self.assertEqual(self.feed(terminal(self.ctx))["reason"], "DEADLINE")

    def test_clock_regression(self):
        self.clock.now = 0
        self.assertEqual(self.receiver.poll()["reason"], "CLOCK_REGRESSION")

    def test_clock_boot_and_timebase_change(self):
        for name, value in [("boot", "new-boot"), ("timebase", (125, 3))]:
            with tempfile.TemporaryDirectory() as root:
                clock = Clock()
                receiver = tr.Receiver(self.ctx, clock, root)
                setattr(clock, name, value)
                self.assertEqual(receiver.poll()["reason"], "CLOCK_BINDING")

    def test_clock_exception_or_wrong_type_closes(self):
        for sample in [RuntimeError("no clock"), 3, {"continuousNS": 1}]:
            with tempfile.TemporaryDirectory() as root:
                receiver = tr.Receiver(self.ctx, Clock(), root)
                with patch.object(receiver, "_clock", side_effect=[sample]):
                    self.assertEqual(receiver.poll()["reason"], "CLOCK_FAILURE")

    def test_creation_at_deadline_and_frozen_context(self):
        with tempfile.TemporaryDirectory() as root:
            clock = Clock()
            clock.now = 100
            receiver = tr.Receiver(self.ctx, clock, root)
            self.assertEqual(receiver.result["reason"], "DEADLINE")
        with self.assertRaises(AttributeError):
            self.ctx.deadlineNS = 200

    def test_duplicate_or_skipped_sequence_keeps_partial(self):
        self.assertIsNone(self.feed(data(self.ctx)))
        result = self.feed(data(self.ctx, seq=0))
        self.assertEqual(result["state"], "FAILED")
        self.assertEqual(result["streams"]["stdout"]["bytes"], 5)
        self.assertEqual(result["streams"]["stdout"]["sha256"], hashlib.sha256(b"hello").hexdigest())
        with tempfile.TemporaryDirectory() as root:
            receiver = tr.Receiver(self.ctx, self.clock, root)
            self.assertEqual(receiver.feed(encode(terminal(self.ctx, seq=2)))["state"], "FAILED")

    def test_stream_limits_are_separate(self):
        self.feed(data(self.ctx, value=b"x" * 64))
        self.feed(data(self.ctx, seq=1, stream="stderr", value=b"y" * 64))
        result = self.feed(data(self.ctx, seq=2, value=b"z"))
        self.assertEqual(result["reason"], "STREAM_LIMIT")
        self.assertEqual([result["streams"][s]["bytes"] for s in ("stdout", "stderr")], [64, 64])

    def test_declared_length_truncation_and_strict_base64(self):
        for field, value in [("bytes", 4), ("bytes", True), ("data", "aGVsbG8=\n"),
                             ("data", "aGVsbG8"), ("data", "aGVsbG9=")]:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as root:
                receiver = tr.Receiver(self.ctx, self.clock, root)
                frame = data(self.ctx)
                frame[field] = value
                self.assertEqual(receiver.feed(encode(frame))["state"], "FAILED")

    def test_raw_limit_and_fragment_are_not_complete(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = tr.Receiver(context(rawMax=2), self.clock, root)
            self.assertEqual(receiver.feed(b"{}x")["reason"], "RAW_LIMIT")
        result = self.receiver.feed(encode(terminal(self.ctx))[:-1])
        self.assertEqual(result["state"], "FAILED")
        self.assertIsNone(result["actualExit"])

    def test_both_eof_wait_and_controller_source_required(self):
        for key, value in [("stdoutEOF", False), ("stderrEOF", False),
                           ("waitObserved", False), ("waitObserved", 1),
                           ("observationSource", "producer")]:
            with tempfile.TemporaryDirectory() as root:
                receiver = tr.Receiver(self.ctx, self.clock, root)
                frame = terminal(self.ctx)
                frame[key] = value
                self.assertEqual(receiver.feed(encode(frame))["state"], "FAILED")

    def test_missing_fields_and_extra_authority_are_rejected(self):
        for mutate in [lambda f: f.pop("stdoutEOF"),
                       lambda f: f.update(groupAbsent=True),
                       lambda f: f.update(allWritersRetired=True),
                       lambda f: f.update(now=1)]:
            with tempfile.TemporaryDirectory() as root:
                receiver = tr.Receiver(self.ctx, self.clock, root)
                frame = terminal(self.ctx)
                mutate(frame)
                self.assertEqual(receiver.feed(encode(frame))["state"], "FAILED")

    def test_loss_preserves_partial_and_never_reopens(self):
        self.feed(data(self.ctx))
        first = self.receiver.abort("LOSS")
        self.assertEqual(first["state"], "UNKNOWN")
        self.assertIsNone(first["actualExit"])
        self.assertEqual(first["streams"]["stdout"]["bytes"], 5)
        with self.assertRaises(tr.ClosedReceipt):
            self.feed(terminal(self.ctx, 1))
        self.assertEqual(self.receiver.poll(), first)

    def test_cancel_and_empty_incomplete(self):
        first = self.receiver.abort("CANCELLED")
        self.assertEqual(first["reason"], "CANCELLED")
        with tempfile.TemporaryDirectory() as root:
            receiver = tr.Receiver(self.ctx, self.clock, root)
            self.assertEqual(receiver.abort("INCOMPLETE")["actualExit"], None)

    def test_results_are_deep_copies_and_duplicate_terminal_rejected(self):
        first = self.feed(terminal(self.ctx))
        first["context"]["timebase"][0] = 999
        first["streams"]["stdout"]["bytes"] = 900
        self.assertEqual(self.receiver.result["context"]["timebase"], [1, 1])
        self.assertEqual(self.receiver.result["streams"]["stdout"]["bytes"], 0)
        with self.assertRaises(tr.ClosedReceipt):
            self.feed(terminal(self.ctx, 1, 23))
        self.assertEqual(self.receiver.result["actualExit"], 0)

    def test_occupied_empty_partial_and_complete_stay_closed_on_restart(self):
        for payload in [b"", b'{"state":', b'{"state":"RECEIVED","actualExit":0}', b"x" * 5000]:
            with tempfile.TemporaryDirectory() as root:
                slot = Path(root, tr.SLOT_NAME)
                slot.write_bytes(payload)
                receiver = tr.Receiver(self.ctx, self.clock, root)
                self.assertEqual(receiver.result["reason"], "SLOT_OCCUPIED")
                self.assertEqual(receiver.result["state"], "UNKNOWN")
                self.assertLessEqual(receiver.result["restart"]["prefixBytes"], 4097)
                with self.assertRaises(tr.ClosedReceipt):
                    receiver.feed(encode(terminal(self.ctx)))
                self.assertEqual(slot.read_bytes(), payload)

    def test_successful_receipt_restart_is_conservative_unknown(self):
        self.feed(terminal(self.ctx, code=23))
        original = self.slot.read_bytes()
        restarted = tr.Receiver(self.ctx, self.clock, self.tmp.name)
        self.assertEqual(restarted.result["state"], "UNKNOWN")
        self.assertEqual(self.slot.read_bytes(), original)

    def test_two_receivers_cannot_claim_the_same_slot(self):
        second = tr.Receiver(self.ctx, self.clock, self.tmp.name)
        self.assertEqual(second.result["reason"], "SLOT_OCCUPIED")
        self.assertEqual(self.feed(terminal(self.ctx))["state"], "RECEIVED")

    def test_positive_short_writes_are_completed(self):
        original = os.write
        with patch.object(tr.os, "write", side_effect=lambda fd, b: original(fd, b[:7])):
            self.assertEqual(self.feed(terminal(self.ctx))["state"], "RECEIVED")
        self.assertEqual(json.loads(self.slot.read_bytes())["actualExit"], 0)

    def test_partial_write_failure_is_not_retried_or_repaired(self):
        original = os.write
        calls = []
        def failing(fd, value):
            if calls:
                raise OSError("injected")
            calls.append(True)
            return original(fd, value[:5])
        with patch.object(tr.os, "write", side_effect=failing):
            result = self.feed(terminal(self.ctx))
        self.assertEqual(result["reason"], "PERSISTENCE_ERROR")
        self.assertEqual(result["decisionReason"], "COMPLETE_TERMINAL")
        before = self.slot.read_bytes()
        self.assertEqual(len(before), 5)
        restarted = tr.Receiver(self.ctx, self.clock, self.tmp.name)
        self.assertEqual(restarted.result["state"], "UNKNOWN")
        self.assertEqual(self.slot.read_bytes(), before)

    def test_zero_write_and_fsync_failure_keep_unknown(self):
        with patch.object(tr.os, "write", return_value=0):
            self.assertEqual(self.feed(terminal(self.ctx))["state"], "UNKNOWN")
        with tempfile.TemporaryDirectory() as root:
            receiver = tr.Receiver(self.ctx, self.clock, root)
            with patch.object(tr.os, "fsync", side_effect=OSError("injected")):
                result = receiver.feed(encode(terminal(self.ctx)))
            self.assertEqual(result["state"], "UNKNOWN")
            self.assertEqual(result["reason"], "PERSISTENCE_ERROR")
            restarted = tr.Receiver(self.ctx, self.clock, root)
            self.assertEqual(restarted.result["state"], "UNKNOWN")

    def test_initial_fsync_failure_leaves_reserved_slot(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(tr.os, "fsync", side_effect=OSError("injected")):
                receiver = tr.Receiver(self.ctx, self.clock, root)
            self.assertEqual(receiver.result["reason"], "SLOT_UNAVAILABLE")
            self.assertTrue(Path(root, tr.SLOT_NAME).exists())
            self.assertEqual(tr.Receiver(self.ctx, self.clock, root).result["reason"], "SLOT_OCCUPIED")

    def test_cumulative_raw_budget_keeps_first_data(self):
        ctx = context(rawMax=1600)
        # rawMax is serialized too: converge after its decimal width changes.
        for _ in range(10):
            first = encode(data(ctx))
            raw_max = 2 * len(first) - 1
            if raw_max == ctx.rawMax:
                break
            ctx = context(rawMax=raw_max)
        else:
            self.fail("raw cap fixture did not converge")
        # The converged exact cap is fixed and shared by both frames.
        self.assertLess(len(first), ctx.rawMax)
        self.assertGreater(2 * len(first), ctx.rawMax)
        with tempfile.TemporaryDirectory() as root:
            receiver = tr.Receiver(ctx, self.clock, root)
            receiver.feed(first)
            result = receiver.feed(encode(data(ctx, seq=1)))
            self.assertEqual(result["reason"], "RAW_LIMIT")
            self.assertEqual(result["streams"]["stdout"]["bytes"], 5)

    def test_record_cap_and_wire_context_integer_types(self):
        for cap in (4095, 65537, True):
            with self.assertRaises(ValueError):
                context(recordMax=cap)
        frame = terminal(self.ctx)
        frame["context"]["version"] = True
        self.assertEqual(self.feed(frame)["reason"], "INVALID_FRAME")

    def test_named_slot_replacement_does_not_report_received(self):
        self.slot.unlink()
        self.slot.write_bytes(b"replacement")
        result = self.feed(terminal(self.ctx))
        self.assertEqual(result["state"], "UNKNOWN")
        self.assertEqual(result["reason"], "PERSISTENCE_ERROR")
        self.assertEqual(self.slot.read_bytes(), b"replacement")

    def test_symlink_slot_is_not_followed(self):
        with tempfile.TemporaryDirectory() as root:
            other = Path(root, "protected")
            other.write_bytes(b"preserve")
            Path(root, tr.SLOT_NAME).symlink_to(other)
            receiver = tr.Receiver(self.ctx, self.clock, root)
            self.assertEqual(receiver.result["state"], "UNKNOWN")
            self.assertEqual(other.read_bytes(), b"preserve")


class HistoricalReceiverRegressions(unittest.TestCase):
    """Synthetic reproductions of witness23, delayed29 and loss semantics."""

    def test_witness_exit23_and_delayed_exit29_keep_actual_nonzero(self):
        for code in (23, 29):
            with tempfile.TemporaryDirectory() as root:
                ctx = context()
                receiver = tr.Receiver(ctx, Clock(), root)
                receiver.feed(encode(data(ctx, value=b"out\n")))
                receiver.feed(encode(data(ctx, 1, "stderr", b"err\n")))
                result = receiver.feed(encode(terminal(ctx, 2, code)))
                self.assertEqual(result["actualExit"], code)
                self.assertEqual(result["state"], "RECEIVED")
                self.assertEqual(result["streams"]["stderr"]["sha256"], hashlib.sha256(b"err\n").hexdigest())

    def test_late_29_and_late_zero_after_loss_cannot_revive(self):
        for reason, code in (("DEADLINE", 29), ("LOSS", 0)):
            with tempfile.TemporaryDirectory() as root:
                ctx, clock = context(), Clock()
                receiver = tr.Receiver(ctx, clock, root)
                receiver.feed(encode(data(ctx)))
                if reason == "DEADLINE":
                    clock.now = 100
                    first = receiver.poll()
                else:
                    first = receiver.abort("LOSS")
                with self.assertRaises(tr.ClosedReceipt):
                    receiver.feed(encode(terminal(ctx, 1, code)))
                self.assertEqual(receiver.result, first)
                self.assertEqual(first["reason"], reason)


if __name__ == "__main__":
    unittest.main()
