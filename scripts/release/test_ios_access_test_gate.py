#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

from ios_access_test_gate import evaluate, expected_cases, observed_cases


class GateTests(unittest.TestCase):
    def test_empty_expected_list_fails(self):
        self.assertIn("expected test list is empty", evaluate(set(), {}, 0)[0])

    def test_wrong_target_log_is_missing(self):
        expected = {("AccessSiteIntentTests", "testParsesIntents")}
        observed = observed_cases("Test Case '-[AccessKitTests.AccessSiteIntentTests testParsesIntents]' passed\n")
        errors = evaluate(expected, observed, 0)
        self.assertTrue(any(item.startswith("missing:") for item in errors))

    def test_missing_case_fails(self):
        expected = {("AccessSiteIntentTests", "testParsesIntents"), ("AccessSiteIntentTests", "testOther")}
        observed = observed_cases(
            "Test Case '-[AegisTests.AccessSiteIntentTests testParsesIntents]' passed\n"
        )
        errors = evaluate(expected, observed, 0)
        self.assertTrue(any("testOther" in item for item in errors))

    def test_failed_case_fails(self):
        expected = {("AccessSiteIntentTests", "testParsesIntents")}
        observed = observed_cases(
            "Test Case '-[AegisTests.AccessSiteIntentTests testParsesIntents]' failed\n"
        )
        errors = evaluate(expected, observed, 65)
        self.assertTrue(any(item.startswith("failed:") for item in errors))
        self.assertTrue(any(item.startswith("xcodebuild exit") for item in errors))

    def test_skipped_case_fails(self):
        expected = {("AccessSiteIntentTests", "testParsesIntents")}
        observed = observed_cases(
            "Test Case '-[AegisTests.AccessSiteIntentTests testParsesIntents]' skipped\n"
        )
        errors = evaluate(expected, observed, 0)
        self.assertTrue(any(item.startswith("skipped:") for item in errors))

    def test_current_xcode_case_line_counts(self):
        observed = observed_cases(
            "Test case 'AccessNavigationRecoveryTests.testHeadIsPreservedAndPostDoesNotRetry()' passed\n"
        )
        self.assertEqual(
            observed,
            {("AccessNavigationRecoveryTests", "testHeadIsPreservedAndPostDoesNotRetry"): "passed"},
        )

    def test_pass_requires_every_expected_case(self):
        expected = {("AccessSiteIntentTests", "testParsesIntents")}
        observed = observed_cases(
            "Test Case '-[AegisTests.AccessSiteIntentTests testParsesIntents]' passed\n"
        )
        self.assertEqual(evaluate(expected, observed, 0), [])

    def test_source_scan_finds_test_methods(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "Sample.swift").write_text(
                "final class SampleTests: XCTestCase {\n    func testOne() {}\n}\n",
                encoding="utf-8",
            )
            self.assertEqual(expected_cases([root]), {("SampleTests", "testOne")})


if __name__ == "__main__":
    unittest.main()
