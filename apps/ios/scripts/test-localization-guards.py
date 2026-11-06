#!/usr/bin/env python3
"""Regression checks for localization validation, also run with python3 -O."""
import ast
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LocalizationGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.checks = load("test-localizations")
        cls.app = load("test-app-language")
        cls.runner = load("test-agent-localizations")
        cls.coverage = json.loads((cls.checks.FIXTURES / "coverage.json").read_text())
        cls.catalog = json.loads((cls.checks.ROOT / "AegisApp/Localizable.xcstrings").read_text())
        cls.probes = json.loads((cls.checks.FIXTURES / "literal-probes.json").read_text())

    def test_guards_are_explicit_and_remain_active_under_optimization(self):
        for name, module in [("test-localizations", self.checks), ("test-app-language", self.app)]:
            with self.subTest(module=name):
                tree = ast.parse((SCRIPTS / f"{name}.py").read_text())
                self.assertFalse(any(isinstance(node, ast.Assert) for node in ast.walk(tree)))
                with self.assertRaisesRegex(ValueError, "bad fixture"):
                    module.require(False, "bad fixture")

    def test_original_seven_negative_catalog_cases(self):
        self.checks.verify_regression_detection(self.coverage, self.catalog, self.probes)

    def test_inventory_source_language_and_preservation_rejections(self):
        mutations = [
            lambda c: c.update(sourceLanguage="en"),
            lambda c: c["strings"].pop("语言"),
            lambda c: c["strings"].update({"unexpected": copy.deepcopy(c["strings"]["语言"])}),
            lambda c: c["strings"]["语言"]["localizations"].pop("de"),
            lambda c: c["strings"][self.coverage["preservedKeys"][0]]["localizations"]["en"]["stringUnit"].update(value="tampered"),
        ]
        for mutation in mutations:
            changed = copy.deepcopy(self.catalog)
            mutation(changed)
            with self.assertRaises((ValueError, KeyError)):
                self.checks.validate_catalog(self.coverage, changed, self.probes)

    def test_agent_table_rejections(self):
        original = json.loads((self.checks.ROOT / "AgentKit/AgentErrors.xcstrings").read_text())
        key = next(iter(original["strings"]))
        mutations = [
            lambda c: c.update(sourceLanguage="en"),
            lambda c: c["strings"][key].update(extractionState="automatic"),
            lambda c: c["strings"][key]["localizations"].pop("en-GB"),
            lambda c: c["strings"][key]["localizations"]["de"]["stringUnit"].update(state="needs_review"),
            lambda c: c["strings"][key]["localizations"]["de"]["stringUnit"].update(value=""),
            lambda c: c["strings"][key]["localizations"]["de"]["stringUnit"].update(value="unexpected %lld 99"),
        ]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "AgentKit").mkdir()
            for mutation in mutations:
                changed = copy.deepcopy(original)
                mutation(changed)
                (root / "AgentKit/AgentErrors.xcstrings").write_text(json.dumps(changed))
                with patch.object(self.checks, "ROOT", root), self.assertRaises(ValueError):
                    self.checks.validate_agent_errors(self.coverage)

    def test_project_membership_rejection(self):
        project = self.checks.plist(self.checks.ROOT / "Aegis.xcodeproj/project.pbxproj")
        objects = project["objects"]
        for obj in objects.values():
            if obj.get("isa") == "PBXSourcesBuildPhase":
                obj["files"] = [ref for ref in obj["files"]
                                if objects[objects[ref]["fileRef"]].get("path") != "AppLocalization.swift"]
        with patch.object(self.checks, "plist", return_value=project), self.assertRaises(ValueError):
            self.checks.validate_project(self.coverage["resourceLocales"])

    def test_web_extension_permissions_and_csp_rejections(self):
        self.checks.validate_web_extension()
        original = json.loads((self.checks.ROOT / "SharedWebExtension/manifest.json").read_text())
        mutations = [
            lambda c: c.update(default_locale="de"),
            lambda c: c.update(permissions=["<all_urls>"]),
            lambda c: c["content_security_policy"].update(extension_pages="script-src *"),
        ]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "SharedWebExtension").mkdir()
            for mutation in mutations:
                changed = copy.deepcopy(original)
                mutation(changed)
                (root / "SharedWebExtension/manifest.json").write_text(json.dumps(changed))
                with patch.object(self.checks, "ROOT", root), self.assertRaises(ValueError):
                    self.checks.validate_web_extension()

    def test_native_runner_rejects_non_uuid_destination_before_execution(self):
        with patch("sys.argv", ["runner", "--device", "UUID,-only-testing:Other", "--xctestrun", "/missing.xctestrun",
                                "--work-dir", "/unused"]), patch.object(self.runner.subprocess, "Popen") as process:
            with self.assertRaises(SystemExit) as error:
                self.runner.main()
            self.assertEqual(error.exception.code, 2)
            process.assert_not_called()

    def test_native_runner_fixed_command_and_missing_evidence_fail_closed(self):
        import plistlib
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base = root / "base.xctestrun"
            base.write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 1},
                                            "AegisTests": {}, "AegisUITests": {}}))
            work = root / "run"
            device = "00000000-0000-4000-8000-000000000001"
            with patch("sys.argv", ["runner", "--device", device, "--xctestrun", str(base),
                                    "--work-dir", str(work), "--language", "en"]), \
                    patch.object(self.runner.subprocess, "Popen") as process:
                process.return_value.wait.return_value = 0
                self.assertEqual(self.runner.main(), 1, "A zero process exit cannot replace locale evidence")
                argv = process.call_args.args[0]
                self.assertEqual(argv[:4], ["/usr/bin/xcrun", "xcodebuild", "test-without-building", "-xctestrun"])
                self.assertEqual(argv[4], str(work / "en.xctestrun"))
                self.assertIn(f"platform=iOS Simulator,id={device}", argv)
                self.assertIs(process.call_args.kwargs["shell"], False)
                manifest = json.loads((work / "results.json").read_text())
                self.assertEqual(manifest["runs"][0]["command"], argv)
                self.assertEqual(manifest["status"], "failed")

    def test_missing_and_mismatched_native_evidence_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "fixture.log"
            for text in ["", self.runner.MARKER + json.dumps({"expected": "en", "selected": "de"})]:
                log.write_text(text)
                with self.assertRaises(ValueError):
                    self.runner.read_evidence(log, "en")


if __name__ == "__main__":
    unittest.main()
