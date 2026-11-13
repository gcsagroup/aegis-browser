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

    def test_all_existing_policy_names_are_safe_basenames(self):
        cases = json.loads((self.checks.FIXTURES / "language-policy.json").read_text())
        self.assertEqual(len(cases), 51)
        self.assertIn("None-en-en_GB17", [case["name"] for case in cases])
        self.assertIn("alias-zh_HK", [case["name"] for case in cases])
        for case in cases:
            with self.subTest(name=case["name"]):
                self.runner.validate_case_name(case["name"])
                self.assertEqual(Path(case["name"]).name, case["name"])
        with tempfile.TemporaryDirectory() as temp:
            absolute_case = str(Path(temp) / "en")
            for unsafe in ["", "../en", "en/GB", "en\\GB", "--option", "-en", absolute_case, "en..GB", "en;echo", "en\nGB", None]:
                with self.subTest(unsafe=unsafe), self.assertRaises(ValueError):
                    self.runner.validate_case_name(unsafe)

    def test_existing_underscore_policy_runs_with_independent_evidence(self):
        import plistlib
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base = root / "base.xctestrun"
            base.write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 1},
                                            "AegisTests": {}, "AegisUITests": {}}))
            work = root / "run"
            def native_fixture(argv, **kwargs):
                kwargs["stdout"].write((self.runner.MARKER + json.dumps({
                    "expected": "en-GB", "selected": "en-GB", "expectedSource": "environment",
                    "requested": ["en"], "expectedFamily": "en", "selectedFamily": "en", "region": "GB"
                }) + "\n").encode())
                return Mock(wait=Mock(return_value=0))
            with patch("sys.argv", ["runner", "--device", "d5367c00-914d-4ed9-89f1-746c5ed9277a",
                                    "--xctestrun", str(base), "--work-dir", str(work),
                                    "--policy-case", "None-en-en_GB17"]), \
                    patch.object(self.runner.subprocess, "Popen", side_effect=native_fixture) as process:
                self.assertEqual(self.runner.main(), 0)
                config = work / "None-en-en_GB17.xctestrun"
                self.assertEqual(process.call_args.args[0][4], str(config))
                settings = plistlib.loads(config.read_bytes())["AegisTests"]
                self.assertEqual(settings["TestRegion"], "GB")
                self.assertEqual(settings["EnvironmentVariables"]["AEGIS_EXPECTED_LANGUAGE"], "en-GB")
                result = json.loads((work / "results.json").read_text())
                self.assertEqual(result["status"], "passed")
                self.assertEqual(result["runs"][0]["evidence"][0]["requested"], ["en"])

    def test_native_runner_uses_persisted_manual_default_expectations(self):
        import plistlib
        from unittest.mock import Mock
        for name, resource, family, preferences, region in [
            ("en-en-GB-en_US23", "en", "en", ["en-GB"], "US"),
            ("manual-traditional-region", "zh-Hant", "zh-Hant", ["de"], "HK"),
        ]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                base = root / "base.xctestrun"
                base.write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 1},
                                                "AegisTests": {}, "AegisUITests": {}}))
                work = root / "run"

                def native_fixture(argv, **kwargs):
                    kwargs["stdout"].write((self.runner.MARKER + json.dumps({
                        "expected": resource, "selected": resource, "expectedSource": "environment",
                        "requested": preferences, "expectedFamily": family, "selectedFamily": family, "region": region,
                    }) + "\n").encode())
                    return Mock(wait=Mock(return_value=0))

                with patch("sys.argv", ["runner", "--device", "d5367c00-914d-4ed9-89f1-746c5ed9277a",
                                        "--xctestrun", str(base), "--work-dir", str(work), "--policy-case", name]), \
                        patch.object(self.runner.subprocess, "Popen", side_effect=native_fixture):
                    self.assertEqual(self.runner.main(), 0)
                settings = plistlib.loads((work / f"{name}.xctestrun").read_bytes())["AegisTests"]
                self.assertEqual(settings["EnvironmentVariables"]["AEGIS_EXPECTED_LANGUAGE"], resource)
                self.assertEqual(json.loads((work / "results.json").read_text())["runs"][0]["expected"], resource)

    def test_native_runner_rejects_non_uuid_destination_before_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            work = root / "unused"
            with patch("sys.argv", ["runner", "--device", "UUID,-only-testing:Other",
                                    "--xctestrun", str(root / "missing.xctestrun"), "--work-dir", str(work)]), \
                    patch.object(self.runner.subprocess, "Popen") as process:
                with self.assertRaises(SystemExit) as error:
                    self.runner.main()
                self.assertEqual(error.exception.code, 2)
                process.assert_not_called()
                self.assertFalse(work.exists())

    def test_native_runner_fixed_command_and_missing_evidence_fail_closed(self):
        import plistlib
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base = root / "base.xctestrun"
            base.write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 1},
                                            "AegisTests": {}, "AegisUITests": {}}))
            work = root / "run"
            device = "d5367c00-914d-4ed9-89f1-746c5ed9277a"
            with patch("sys.argv", ["runner", "--device", device, "--xctestrun", str(base),
                                    "--work-dir", str(work), "--language", "en"]), \
                    patch.object(self.runner.subprocess, "Popen") as process:
                process.return_value.wait.return_value = 0
                self.assertEqual(self.runner.main(), 1, "A zero process exit cannot replace locale evidence")
                argv = process.call_args.args[0]
                self.assertEqual(argv[:4], ["/usr/bin/xcrun", "xcodebuild", "test-without-building", "-xctestrun"])
                self.assertEqual(argv[4], str(work / "en.xctestrun"))
                self.assertEqual(argv[argv.index("-destination") + 1],
                                 "platform=iOS Simulator,id=D5367C00-914D-4ED9-89F1-746C5ED9277A")
                self.assertIs(process.call_args.kwargs["shell"], False)
                manifest = json.loads((work / "results.json").read_text())
                self.assertEqual(manifest["runs"][0]["command"], argv)
                self.assertEqual(manifest["status"], "failed")

    def test_native_runner_nonzero_process_persists_terminal_failure(self):
        import plistlib
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base = root / "base.xctestrun"
            base.write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 1},
                                            "AegisTests": {}, "AegisUITests": {}}))
            work = root / "run"
            def exit_with_destination_failure(timeout):
                self.assertEqual(timeout, 900)
                active = json.loads((work / "results.json").read_text())
                self.assertEqual(active["status"], "running")
                self.assertEqual(active["runs"][0]["status"], "running")
                return 70
            with patch("sys.argv", ["runner", "--device", "0581734b-dea4-4da5-8617-30c1f2012622",
                                    "--xctestrun", str(base), "--work-dir", str(work), "--language", "en-GB"]), \
                    patch.object(self.runner.subprocess, "Popen") as process, \
                    patch.object(self.runner, "read_evidence") as evidence:
                process.return_value.wait.side_effect = exit_with_destination_failure
                self.assertEqual(self.runner.main(), 1)
                evidence.assert_not_called()
                manifest = json.loads((work / "results.json").read_text())
                run = manifest["runs"][0]
                self.assertEqual(manifest["device"], "0581734B-DEA4-4DA5-8617-30C1F2012622")
                self.assertEqual(manifest["status"], "failed")
                self.assertEqual(run["status"], "failed")
                self.assertEqual(run["exit_code"], 70)
                self.assertEqual(run["error"], "en-GB: xcodebuild exit 70")
                self.assertEqual(manifest["error"], run["error"])
                self.assertGreaterEqual(run["elapsed_seconds"], 0)
                self.assertEqual(run["command"], process.call_args.args[0])
                self.assertIs(process.call_args.kwargs["shell"], False)
                self.assertIs(process.call_args.kwargs["start_new_session"], True)

    def test_missing_and_mismatched_native_evidence_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "fixture.log"
            for text in ["", self.runner.MARKER + json.dumps({"expected": "en", "selected": "de"})]:
                log.write_text(text)
                with self.assertRaises(ValueError):
                    self.runner.read_evidence(log, "en")


if __name__ == "__main__":
    unittest.main()
