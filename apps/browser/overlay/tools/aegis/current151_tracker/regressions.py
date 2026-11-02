#!/usr/bin/env python3
"""Unit and regression tests of the actual bounded admission/result adapters.

No GN, compiler or native binary is invoked by this suite. Native boundary
qualification and the original two GTests are separate required evidence.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


def load(name):
    path = Path(__file__).resolve().parent / (name + ".py")
    spec = importlib.util.spec_from_file_location("bounded_tracker_" + name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


driver = load("driver")
closure = load("closure")
driver.isolated_entry()


def xml(case=driver.CASES[0], detail="", status="run"):
    suite, name = case.split(".")
    return (f'<testsuites><testsuite><x-teststart name="{name}" classname="{suite}" '
            f'timestamp="2026-10-09T00:00:00Z"/><testcase name="{name}" classname="{suite}" '
            f'status="{status}" time="0.001" timestamp="2026-10-09T00:00:00Z">'
            f'{detail}</testcase></testsuite></testsuites>').encode()


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def attempt(self, guard=lambda: None):
        return driver.Attempt(driver.Deadline(driver.deadline_clock_ns() + 10**10, "boot"),
                              lambda: "boot", guard)


    def terminal(self, attempt, *, command=("owner", "fixture-invocation"),
                 owner_exit=0, completed=True, **changes):
        # PURE fixtures: these bytes/completion objects are never native proof.
        receipt = {"version": 1, "kind": "provisional", "command": list(command),
                   "deadline_ns": attempt.deadline.monotonic_ns, "boot": attempt.deadline.boot,
                   "reaped": True, "stopped": False, "go": True, "status": 0}
        receipt.update(changes)
        return {"terminal": json.dumps(receipt).encode(), "command": command,
                "completion": driver.OwnerCompletion(command, owner_exit, completed)}

    def finalize(self, attempt, root, cleanup, validate):
        return driver.finalize(attempt, root, cleanup, validate, **self.terminal(attempt))


class DeadlineUnitTests(Fixture):
    def test_admission_and_checks_use_explicit_native_clock_domain(self):
        # Simulate different accumulated-suspend offsets in Python's implicit
        # mach clock and CLOCK_MONOTONIC. Only the latter may bind the grant.
        with patch.object(driver.time, "monotonic_ns", return_value=7), \
             patch.object(driver.time, "clock_gettime_ns", return_value=10**12) as explicit:
            deadline = driver.Deadline.admit(110, "boot", utc_now=100)
            self.assertEqual(deadline.monotonic_ns, 10**12 + 10**10)
            deadline.check("boot")
            self.assertEqual(explicit.call_count, 2)
            self.assertEqual(explicit.call_args.args, (time.CLOCK_MONOTONIC,))

    def test_clock_probe_reconciles_original_deadline_and_sample_bracket(self):
        deadline = driver.Deadline(400, "boot")
        probe = {"clock": "CLOCK_MONOTONIC", "now_ns": 200,
                 "deadline_ns": 400, "boot": "boot"}
        self.assertEqual(driver.validate_clock_probe(json.dumps(probe).encode(), deadline,
                                                     before_ns=190, after_ns=210), 200)
        for key, value in [("clock", "mach_absolute_time"), ("now_ns", 5),
                           ("now_ns", 220), ("now_ns", True),
                           ("deadline_ns", 401), ("boot", "other")]:
            altered = dict(probe, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(driver.Refusal):
                driver.validate_clock_probe(json.dumps(altered).encode(), deadline,
                                            before_ns=190, after_ns=210)

    def test_clock_probe_rejects_duplicate_fields_and_expired_bracket(self):
        deadline = driver.Deadline(400, "boot")
        probe = b'{"clock":"CLOCK_MONOTONIC","now_ns":200,"deadline_ns":400,"boot":"boot"}'
        for data, after in [(probe[:-1] + b',"now_ns":200}', 210), (probe, 400)]:
            with self.assertRaises(driver.Refusal):
                driver.validate_clock_probe(data, deadline, before_ns=190, after_ns=after)

    def test_guard_induced_cancellation_refuses_all_command_boundaries(self):
        for operation in ["before_create", "before_go", "accept"]:
            attempt = self.attempt()
            attempt.guard = attempt.cancel
            with self.subTest(operation=operation), self.assertRaises(driver.Refusal):
                if operation == "accept":
                    attempt.accept(lambda: "provisional", retired=True)
                else:
                    getattr(attempt, operation)()
            self.assertTrue(attempt.stopped)
            self.assertEqual(attempt.stage, 0)

    def test_guard_time_advance_refuses_dispatch_and_acceptance(self):
        for operation in ["before_create", "before_go", "accept"]:
            clock = [100]
            def guard():
                clock[0] = 200
            attempt = driver.Attempt(driver.Deadline(200, "boot"), lambda: "boot", guard)
            with patch.object(driver, "deadline_clock_ns", side_effect=lambda: clock[0]):
                with self.subTest(operation=operation), self.assertRaises(driver.Refusal):
                    if operation == "accept":
                        attempt.accept(lambda: "provisional", retired=True)
                    else:
                        getattr(attempt, operation)()
            self.assertTrue(attempt.stopped)
            self.assertEqual(attempt.stage, 0)

    def test_final_guard_cancel_or_expiry_cannot_advance_acceptance(self):
        for cancel in [True, False]:
            clock, calls = [100], [0]
            attempt = driver.Attempt(driver.Deadline(200, "boot"), lambda: "boot", lambda: None)
            def guard():
                calls[0] += 1
                if calls[0] == 2:
                    if cancel:
                        attempt.cancel()
                    else:
                        clock[0] = 200
            attempt.guard = guard
            with patch.object(driver, "deadline_clock_ns", side_effect=lambda: clock[0]):
                with self.subTest(cancel=cancel), self.assertRaises(driver.Refusal):
                    attempt.accept(lambda: "provisional", retired=True)
            self.assertEqual(attempt.stage, 0)
            self.assertTrue(attempt.stopped)

    def test_original_deadline_ignores_wall_clock_rollback(self):
        deadline = driver.Deadline.admit(110, "boot", utc_now=100, monotonic_now=1000)
        self.assertEqual(deadline.monotonic_ns, 10_000_001_000)
        with patch.object(driver.time, "time", return_value=-10000):
            with self.assertRaises(driver.Refusal):
                deadline.check("boot", now_ns=deadline.monotonic_ns)

    def test_boot_identity_change_refuses(self):
        with self.assertRaises(driver.Refusal):
            driver.Deadline(100, "first").check("second", now_ns=1)

    def test_excessive_and_nonfinite_grants_refuse(self):
        for seconds in [0, -1, 28801, float("nan"), float("inf")]:
            with self.subTest(seconds=seconds), self.assertRaises(driver.Refusal):
                driver.Deadline.admit(seconds, "boot", utc_now=0, monotonic_now=0)

    def test_cancel_is_sticky_after_repaired_xml(self):
        attempt = self.attempt()
        attempt.cancel()
        with self.assertRaises(driver.Refusal):
            attempt.accept(lambda: driver.validate_xml(xml(), driver.CASES[0], exit_code=0),
                           retired=True)
        self.assertEqual(attempt.stage, 0)

    def test_validator_exception_latches_before_propagation(self):
        attempt = self.attempt()
        with self.assertRaises(RuntimeError):
            attempt.accept(lambda: (_ for _ in ()).throw(RuntimeError("bad XML")), retired=True)
        with self.assertRaises(driver.Refusal):
            attempt.accept(lambda: "repaired", retired=True)
        self.assertEqual(attempt.stage, 0)

    def test_final_guard_failure_cannot_advance(self):
        calls = []
        def guard():
            calls.append(1)
            if len(calls) == 2:
                raise RuntimeError("drift during validation")
        attempt = self.attempt(guard)
        with self.assertRaises(RuntimeError):
            attempt.accept(lambda: "provisional", retired=True)
        self.assertTrue(attempt.stopped)
        self.assertEqual(attempt.stage, 0)

    def test_guards_at_creation_and_go(self):
        attempt = self.attempt(lambda: (_ for _ in ()).throw(RuntimeError("drift")))
        with self.assertRaises(RuntimeError):
            attempt.before_create()
        with self.assertRaises(driver.Refusal):
            attempt.before_go()

    def test_unretired_child_refuses(self):
        attempt = self.attempt()
        with self.assertRaises(driver.Refusal):
            attempt.accept(lambda: "success", retired=False)
        self.assertTrue(attempt.stopped)

    def test_build_is_sealed(self):
        with self.assertRaisesRegex(driver.Refusal, "B1"):
            driver.build_dispatch("gn", "gen", qualified=True)


class ClosureRegressionTests(Fixture):
    def test_bounded_read_detects_sparse_oversize(self):
        path = self.root / "sparse.rsp"
        with path.open("wb") as stream:
            stream.truncate(2**30)
        with self.assertRaises(closure.Refusal):
            closure.expand(["@sparse.rsp"], self.root)

    def test_aggregate_budget_spans_response_files(self):
        (self.root / "a.rsp").write_text("a " * 17000)
        (self.root / "b.rsp").write_text("b " * 17000)
        with self.assertRaisesRegex(closure.Refusal, "byte budget"):
            closure.expand(["@a.rsp", "@b.rsp"], self.root,
                           closure.Budget(items_left=100000))

    def test_response_cycle_refuses(self):
        (self.root / "a.rsp").write_text("@b.rsp")
        (self.root / "b.rsp").write_text("@a.rsp")
        with self.assertRaisesRegex(closure.Refusal, "cycle"):
            closure.expand(["@a.rsp"], self.root)

    def test_depth_is_bounded(self):
        for i in range(10):
            (self.root / f"{i}.rsp").write_text(f"@{i+1}.rsp" if i < 9 else "input.cc")
        with self.assertRaisesRegex(closure.Refusal, "depth"):
            closure.expand(["@0.rsp"], self.root)

    def test_trailing_cwd_override_refuses_before_path_resolution(self):
        for suffix in [["-working-directory", "/old"], ["--working-directory=/old"],
                       ["-Wl,-working-directory,/old"], ["-Xclang", "-working-directory"]]:
            with self.subTest(suffix=suffix), self.assertRaises(closure.Refusal):
                closure.expand(["earlier.cc", *suffix], self.root)

    def test_nested_cwd_override_refuses(self):
        (self.root / "a.rsp").write_text("input.cc --working-directory=/old")
        with self.assertRaises(closure.Refusal):
            closure.expand(["@a.rsp"], self.root)

    def test_repeated_dependency_items_are_charged(self):
        path = self.root / "input.cc"
        path.write_text("input")
        admitted = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()}
        self.assertEqual(len(closure.references(["input.cc"] * 4096, self.root, admitted)), 4096)
        with self.assertRaisesRegex(closure.Refusal, "reference budget"):
            closure.references(["input.cc"] * 4097, self.root, admitted)

    def test_historical_alias_and_unknown_input_refuse(self):
        path = self.root / "old.o"
        path.write_text("old")
        (self.root / "new.o").symlink_to(path)
        with self.assertRaises(closure.Refusal):
            closure.references(["new.o"], self.root, {str(path): "hash"})
        with self.assertRaises(closure.Refusal):
            closure.references(["old.o"], self.root, {})

    def test_literal_arguments_expand_without_shell_execution(self):
        (self.root / "a.rsp").write_text('"literal;$(touch nope).cc" -c')
        self.assertEqual(closure.expand(["@a.rsp"], self.root), ["literal;$(touch nope).cc", "-c"])
        self.assertFalse((self.root / "nope").exists())

    def test_filelist_grammar_is_not_silently_accepted(self):
        with self.assertRaisesRegex(closure.Refusal, "filelist"):
            closure.expand(["-Wl,-filelist,unknown"], self.root)

    def alias_fixture(self):
        fresh = self.root / "fresh"
        historical = self.root / "historical"
        fresh.mkdir()
        (historical / "subdir").mkdir(parents=True)
        for name, fresh_bytes, old_bytes in [("input.o", "current", "historical"),
                                            ("input.rsp", "fresh.cc", "historical.cc")]:
            (fresh / name).write_text(fresh_bytes)
            (historical / name).write_text(old_bytes)
        (fresh / "alias").symlink_to(historical / "subdir", target_is_directory=True)
        (fresh / "real").mkdir()
        return fresh

    def test_original_alias_parent_sequence_refuses_relative_and_absolute_inputs(self):
        fresh = self.alias_fixture()
        admitted = {str(fresh / "input.o"): "current-hash"}
        for value in ["alias/../input.o", str(fresh / "alias/../input.o")]:
            with self.subTest(value=value), self.assertRaisesRegex(closure.Refusal, "symlink"):
                closure.references([value], fresh, admitted)
        self.assertEqual(closure.references(["real/../input.o", "input.o"], fresh, admitted),
                         [fresh / "input.o"] * 2)

    def test_alias_parent_responses_refuse_before_reading_lexical_neighbor(self):
        fresh = self.alias_fixture()
        for value in ["alias/../input.rsp", str(fresh / "alias/../input.rsp")]:
            with self.subTest(value=value), patch.object(closure, "read_bounded") as reader:
                with self.assertRaisesRegex(closure.Refusal, "symlink"):
                    closure.expand(["@" + value], fresh)
                reader.assert_not_called()
        (fresh / "outer.rsp").write_text("@alias/../input.rsp")
        with self.assertRaisesRegex(closure.Refusal, "symlink"):
            closure.expand(["@outer.rsp"], fresh)
        self.assertEqual(closure.expand(["@real/../input.rsp"], fresh), ["fresh.cc"])

    def test_same_identity_alias_and_file_parent_refuse(self):
        fresh = self.alias_fixture()
        (fresh / "same").symlink_to(fresh / "real", target_is_directory=True)
        for value in ["same/../input.o", "input.o/../input.o"]:
            with self.subTest(value=value), self.assertRaises(closure.Refusal):
                closure.references([value], fresh, {str(fresh / "input.o"): "hash"})

    def test_parent_canonicalization_keeps_direct_absolute_and_relative_controls(self):
        (self.root / "dir").mkdir()
        (self.root / "input.o").write_text("current")
        self.assertEqual(closure.canonical(self.root / "dir/../input.o"), self.root / "input.o")
        with patch.object(closure.Path, "cwd", return_value=self.root):
            self.assertEqual(closure.canonical(Path("dir/../input.o")), self.root / "input.o")


class TerminalRegressionTests(Fixture):
    def listing(self, attempt, receipt):
        sequence = driver.TrackerSequence(attempt)
        return sequence.listing(
            b"PolicyPublicationAckTrackerTest.\n  SharedUnitContract\n"
            b"PolicyPublicationAckTrackerRegressionTest.\n  SharedRegressionContract\n",
            owner_exit_code=0, leaf_exit_code=0, retired=True, **receipt)

    def test_provisional_success_requires_current_owner_completion(self):
        attempt = self.attempt()
        self.assertEqual(self.listing(attempt, self.terminal(attempt)), driver.CASES)
        self.assertEqual(attempt.stage, 1)

    def test_stale_provisional_receipt_cannot_hide_owner_cancellation_or_loss(self):
        for exit_code, completed in [(125, True), (-9, True), (1, True),
                                     (None, False), (0, False), (False, True)]:
            attempt = self.attempt()
            with self.subTest(exit=exit_code, completed=completed), self.assertRaises(driver.Refusal):
                self.listing(attempt, self.terminal(attempt, owner_exit=exit_code, completed=completed))
            self.assertEqual(attempt.stage, 0)
            self.assertTrue(attempt.stopped)

    def test_terminal_leaf_failure_and_incomplete_observations_cannot_advance(self):
        for key, value in [("status", 256), ("status", 9), ("status", False),
                           ("reaped", False), ("stopped", True), ("go", False),
                           ("reaped", 1), ("kind", "accepted"), ("version", True)]:
            attempt = self.attempt()
            with self.subTest(key=key, value=value), self.assertRaises(driver.Refusal):
                self.listing(attempt, self.terminal(attempt, **{key: value}))
            self.assertEqual(attempt.stage, 0)

    def test_authoritative_accepted_duplicate_unknown_and_oversize_receipts_refuse(self):
        for mutation in ["accepted", "duplicate", "unknown", "oversize", "missing"]:
            attempt = self.attempt()
            receipt = self.terminal(attempt)
            data = receipt["terminal"]
            if mutation in ("accepted", "unknown"):
                data = data[:-1] + (b',"accepted":true}' if mutation == "accepted" else b',"extra":0}')
            elif mutation == "duplicate":
                data = data[:-1] + b',"status":0}'
            elif mutation == "oversize":
                data += b" " * driver.TERMINAL_CAP
            else:
                parsed = json.loads(data)
                del parsed["reaped"]
                data = json.dumps(parsed).encode()
            receipt["terminal"] = data
            with self.subTest(mutation=mutation), self.assertRaises(driver.Refusal):
                self.listing(attempt, receipt)
            self.assertEqual(attempt.stage, 0)

    def test_original_deadline_boot_and_invocation_bindings_must_match(self):
        for mutation in ["deadline", "boot", "receipt-command", "completion-command"]:
            attempt = self.attempt()
            receipt = self.terminal(attempt)
            parsed = json.loads(receipt["terminal"])
            if mutation == "deadline":
                parsed["deadline_ns"] += 1
            elif mutation == "boot":
                parsed["boot"] = "other"
            elif mutation == "receipt-command":
                parsed["command"] = ["owner", "old-invocation"]
            else:
                receipt["completion"] = driver.OwnerCompletion(("owner", "old-invocation"), 0, True)
            receipt["terminal"] = json.dumps(parsed).encode()
            with self.subTest(mutation=mutation), self.assertRaises(driver.Refusal):
                self.listing(attempt, receipt)
            self.assertEqual(attempt.stage, 0)

    def test_missing_dispatch_completion_refuses_listing_result_and_finalization(self):
        for mode in ["listing", "result", "finalize"]:
            attempt = self.attempt()
            sequence = driver.TrackerSequence(attempt)
            with self.subTest(mode=mode), self.assertRaises(driver.Refusal):
                if mode == "listing":
                    self.listing(attempt, {})
                elif mode == "result":
                    attempt.stage = 1
                    path = self.root / "case.xml"
                    sequence.prepare(driver.CASES[0], path)
                    path.write_bytes(xml())
                    sequence.result(driver.CASES[0], exit_code=0, retired=True)
                else:
                    driver.finalize(attempt, self.root, lambda: True, lambda: "pass")
            self.assertEqual(attempt.stage, 1 if mode == "result" else 0)
            self.assertTrue(attempt.stopped)

    def test_result_requires_actual_successful_owner_even_with_complete_xml(self):
        attempt = self.attempt()
        attempt.stage = 1
        sequence = driver.TrackerSequence(attempt)
        path = self.root / "case.xml"
        sequence.prepare(driver.CASES[0], path)
        path.write_bytes(xml())
        with self.assertRaises(driver.Refusal):
            sequence.result(driver.CASES[0], exit_code=0, retired=True,
                            **self.terminal(attempt, owner_exit=125))
        self.assertEqual(attempt.stage, 1)
        self.assertTrue(attempt.stopped)

    def test_cancellation_during_final_accounting_cannot_accept_provisional_success(self):
        attempt = self.attempt()
        original, calls = driver.census, [0]
        def accounting(root):
            calls[0] += 1
            result = original(root)
            if calls[0] == 3:
                attempt.cancel()
            return result
        with patch.object(driver, "census", side_effect=accounting):
            with self.assertRaises(driver.Refusal):
                self.finalize(attempt, self.root, lambda: True, lambda: "pass")
        self.assertEqual(attempt.stage, 0)
        self.assertTrue(attempt.stopped)


class ResultRegressionTests(Fixture):
    def test_sequence_requires_listing_then_unit_then_regression(self):
        sequence = driver.TrackerSequence(self.attempt())
        sequence.listing(b"PolicyPublicationAckTrackerTest.\n  SharedUnitContract\nPolicyPublicationAckTrackerRegressionTest.\n  SharedRegressionContract\n",
                         owner_exit_code=0, leaf_exit_code=0, retired=True,
                         **self.terminal(sequence.attempt))
        for index, case in enumerate(driver.CASES):
            path = self.root / f"{index}.xml"
            sequence.prepare(case, path)
            path.write_bytes(xml(case))
            self.assertEqual(sequence.result(case, exit_code=0, retired=True,
                                             **self.terminal(sequence.attempt, command=("owner", case))), case)
        self.assertEqual(sequence.attempt.stage, 3)

    def test_preexisting_xml_refuses_and_latches(self):
        attempt = self.attempt()
        attempt.stage = 1
        sequence = driver.TrackerSequence(attempt)
        path = self.root / "old.xml"
        path.write_bytes(xml())
        with self.assertRaises(driver.Refusal):
            sequence.prepare(driver.CASES[0], path)
        self.assertTrue(attempt.stopped)

    def test_out_of_order_and_retry_refuse(self):
        attempt = self.attempt()
        attempt.stage = 1
        sequence = driver.TrackerSequence(attempt)
        with self.assertRaises(driver.Refusal):
            sequence.prepare(driver.CASES[1], self.root / "wrong.xml")
        attempt = self.attempt()
        attempt.stage = 1
        sequence = driver.TrackerSequence(attempt)
        sequence.prepare(driver.CASES[0], self.root / "first.xml")
        with self.assertRaises(driver.Refusal):
            sequence.prepare(driver.CASES[0], self.root / "second.xml")

    def test_unknown_xml_attributes_and_nonfinite_duration_refuse(self):
        for data in [xml().replace(b'status="run"', b'status="run" result="skipped"'),
                     xml().replace(b'time="0.001"', b'time="nan"')]:
            with self.assertRaises(driver.Refusal):
                driver.validate_xml(data, driver.CASES[0], exit_code=0)

    def test_exact_listing(self):
        listing = b"PolicyPublicationAckTrackerTest.\n  SharedUnitContract\nPolicyPublicationAckTrackerRegressionTest.\n  SharedRegressionContract\n"
        self.assertEqual(driver.validate_listing(listing), driver.CASES)
        with self.assertRaises(driver.Refusal):
            driver.validate_listing(listing + b"  SharedRegressionContract\n")

    def test_correct_listing_cannot_hide_failed_execution(self):
        data = b"PolicyPublicationAckTrackerTest.\n  SharedUnitContract\nPolicyPublicationAckTrackerRegressionTest.\n  SharedRegressionContract\n"
        for owner, leaf, retired, cancelled in [(1, 0, True, False), (0, 1, True, False),
                                                (0, -14, True, False), (0, 0, False, False),
                                                (0, 0, True, True), (False, 0, True, False)]:
            sequence = driver.TrackerSequence(self.attempt())
            with self.subTest(owner=owner, leaf=leaf, retired=retired, cancelled=cancelled, **self.terminal(sequence.attempt)), \
                    self.assertRaises(driver.Refusal):
                sequence.listing(data, owner_exit_code=owner, leaf_exit_code=leaf,
                                 retired=retired, cancelled=cancelled, **self.terminal(sequence.attempt))
            self.assertEqual(sequence.attempt.stage, 0)
            self.assertTrue(sequence.attempt.stopped)
            with self.assertRaises(driver.Refusal):
                sequence.prepare(driver.CASES[0], self.root / "case.xml")

    def test_failed_listing_cannot_be_repaired_and_retried(self):
        data = b"PolicyPublicationAckTrackerTest.\n  SharedUnitContract\nPolicyPublicationAckTrackerRegressionTest.\n  SharedRegressionContract\n"
        sequence = driver.TrackerSequence(self.attempt())
        with self.assertRaises(driver.Refusal):
            sequence.listing(data, owner_exit_code=0, leaf_exit_code=-9, retired=True,
                             **self.terminal(sequence.attempt))
        with self.assertRaises(driver.Refusal):
            sequence.listing(data, owner_exit_code=0, leaf_exit_code=0, retired=True,
                         **self.terminal(sequence.attempt))
        self.assertEqual(sequence.attempt.stage, 0)

    def test_each_original_case_complete_xml(self):
        for case in driver.CASES:
            self.assertEqual(driver.validate_xml(xml(case), case, exit_code=0), case)

    def test_success_detail(self):
        detail = '<x-test-result-part type="success" file="test.cc" line="1"><summary/><message/></x-test-result-part>'
        driver.validate_xml(xml(detail=detail), driver.CASES[0], exit_code=0)

    def test_fail_skip_unknown_and_nonzero_exit_refuse(self):
        for detail in ['<failure/>', '<skipped/>', '<unknown/>',
                       '<x-test-result-part type="skip"><summary/><message/></x-test-result-part>']:
            with self.subTest(detail=detail), self.assertRaises(driver.Refusal):
                driver.validate_xml(xml(detail=detail), driver.CASES[0], exit_code=0)
        with self.assertRaises(driver.Refusal):
            driver.validate_xml(xml(), driver.CASES[0], exit_code=1)
        with self.assertRaises(driver.Refusal):
            driver.validate_xml(xml(status="notrun"), driver.CASES[0], exit_code=0)

    def test_truncated_duplicate_and_wrong_identity_refuse(self):
        for data in [xml()[:-3], xml().replace(b"</testsuite>", b"<testcase/></testsuite>"),
                     xml(driver.CASES[1]), b'<!DOCTYPE testsuites [<!ENTITY x "value">]>' + xml()]:
            with self.subTest(data=data), self.assertRaises(driver.Refusal):
                driver.validate_xml(data, driver.CASES[0], exit_code=0)

    def test_symlink_and_oversized_results_refuse(self):
        path = self.root / "result.xml"
        path.write_bytes(xml())
        link = self.root / "link.xml"
        link.symlink_to(path)
        with self.assertRaises(OSError):
            driver.read_regular(link, driver.XML_CAP)
        with self.assertRaises(driver.Refusal):
            driver.read_regular(path, 4)

    def test_vanished_census_entry_still_cleans_up_and_latches(self):
        (self.root / "entry").write_text("result")
        attempt = self.attempt()
        cleaned = []
        with patch.object(driver.os, "stat", side_effect=FileNotFoundError("raced")):
            with self.assertRaises(FileNotFoundError):
                self.finalize(attempt, self.root, lambda: cleaned.append(True), lambda: "pass")
        self.assertEqual(cleaned, [True])
        self.assertTrue(attempt.stopped)
        self.assertEqual(attempt.stage, 0)

    def test_cleanup_failure_preserves_prior_accounting_exception(self):
        (self.root / "entry").write_text("result")
        attempt = self.attempt()
        first = FileNotFoundError("accounting lost entry")
        second = RuntimeError("retirement failed")
        with patch.object(driver.os, "stat", side_effect=first):
            with self.assertRaises(FileNotFoundError) as caught:
                self.finalize(attempt, self.root,
                                lambda: (_ for _ in ()).throw(second), lambda: "pass")
        self.assertIs(caught.exception, first)
        self.assertIs(caught.exception.__cause__, second)
        self.assertTrue(attempt.stopped)

    def test_retirement_output_growth_is_counted(self):
        attempt = self.attempt()
        original_census = driver.census
        def cleanup():
            (self.root / "terminal").write_bytes(b"12345")
            return True
        with patch.object(driver, "census", side_effect=lambda root: original_census(root, cap=4)):
            with self.assertRaises(driver.Refusal):
                self.finalize(attempt, self.root, cleanup, lambda: "pass")
        self.assertTrue(attempt.stopped)
        self.assertEqual(attempt.stage, 0)

    def test_validation_output_growth_is_counted(self):
        attempt = self.attempt()
        original_census = driver.census
        def validate():
            (self.root / "final").write_bytes(b"12345")
            return "pass"
        with patch.object(driver, "census", side_effect=lambda root: original_census(root, cap=4)):
            with self.assertRaises(driver.Refusal):
                self.finalize(attempt, self.root, lambda: True, validate)
        self.assertTrue(attempt.stopped)
        self.assertEqual(attempt.stage, 0)

    def test_final_guard_unaccountable_output_is_counted(self):
        calls = [0]
        def guard():
            calls[0] += 1
            if calls[0] == 2:
                (self.root / "link").symlink_to(self.root)
        attempt = self.attempt(guard)
        with self.assertRaises(driver.Refusal):
            self.finalize(attempt, self.root, lambda: True, lambda: "pass")
        self.assertTrue(attempt.stopped)
        self.assertEqual(attempt.stage, 0)

    def test_final_census_time_advance_refuses_acceptance(self):
        clock, calls = [100], [0]
        original_census = driver.census
        attempt = driver.Attempt(driver.Deadline(200, "boot"), lambda: "boot", lambda: None)
        def counting_census(root):
            calls[0] += 1
            result = original_census(root)
            if calls[0] == 3:
                clock[0] = 200
            return result
        with patch.object(driver, "census", side_effect=counting_census), \
             patch.object(driver, "deadline_clock_ns", side_effect=lambda: clock[0]):
            with self.assertRaises(driver.Refusal):
                self.finalize(attempt, self.root, lambda: True, lambda: "pass")
        self.assertTrue(attempt.stopped)
        self.assertEqual(attempt.stage, 0)

    def test_census_preserves_terminal_reserve(self):
        (self.root / "entry").write_bytes(b"abcde")
        self.assertEqual(driver.census(self.root, cap=5), 5)
        with self.assertRaises(driver.Refusal):
            driver.census(self.root, cap=4)

    def test_source_drift_refuses(self):
        path = self.root / "source.cc"
        path.write_text("original")
        inputs = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()}
        driver.check_hashes(inputs)
        path.write_text("changed")
        with self.assertRaises(driver.Refusal):
            driver.check_hashes(inputs)

    def test_real_python_startup_hook_isolation(self):
        marker = self.root / "hook-ran"
        (self.root / "sitecustomize.py").write_text(
            "from pathlib import Path\nPath(" + repr(str(marker)) + ").write_text('ran')\n")
        env = {"PATH": "/usr/bin:/bin", "PYTHONPATH": str(self.root)}
        # Positive control proves the fixture is executable startup code.
        subprocess.run([sys.executable, "-B", "-c", "pass"], env=env, cwd=self.root,
                       check=True, timeout=5, capture_output=True)
        self.assertTrue(marker.exists())
        marker.unlink()
        subprocess.run([sys.executable, "-I", "-S", "-B", "-c", "pass"],
                       env=env, cwd=self.root, check=True, timeout=5, capture_output=True)
        self.assertFalse(marker.exists())


class QualificationCompletionRegressionTests(Fixture):
    def test_positive_probe_exit73_is_not_owner_or_tracker_success(self):
        attempt = self.attempt()
        value = self.terminal(attempt, owner_exit=73)
        with self.assertRaises(driver.Refusal):
            driver.validate_terminal(value["terminal"], attempt.deadline,
                                     value["command"], value["completion"])

    def test_qualification_stopped_terminal_never_accepts_even_reaped(self):
        attempt = self.attempt()
        value = self.terminal(attempt, stopped=True, reaped=True)
        with self.assertRaises(driver.Refusal):
            driver.finalize(attempt, self.root, lambda: True, lambda: "PASS", **value)
        self.assertTrue(attempt.stopped)

    def test_qualified_fixture_does_not_unseal_build_dispatch(self):
        with self.assertRaises(driver.Refusal):
            driver.build_dispatch(qualified=True, process_probe_exit=73)


if __name__ == "__main__":
    unittest.main(verbosity=2)
