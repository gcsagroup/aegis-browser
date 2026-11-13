"""Binary provenance and live-leaf regression checks; no Xcode or private node required."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ios_access_core_gate as gate
import ios_embedded_core as core


class EmbeddedCoreInputsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        bridge = self.root / "apps/ios/EmbeddedCore/bridge"
        bridge.mkdir(parents=True)
        (bridge / "bridge.go").write_text("package bridge\n")
        self.lock = bridge.parent / "embedded-core-lock.json"
        self.lock.write_text(json.dumps({"status": "verified_build", "xrayCore": {"commit": "a" * 40},
                                         "artifacts": {key: "0" * 64 for key in core.SLICE_KEYS.values()}}))
        self.original = self.lock.read_bytes()
        self.products = self.root / "separate-build-output"
        for name in core.SLICE_KEYS:
            binary = self.products / "AegisEmbeddedCore.xcframework" / name / "AegisEmbeddedCore.framework/AegisEmbeddedCore"
            binary.parent.mkdir(parents=True)
            binary.write_bytes((name + " actual binary bytes").encode())

    def record(self, **kwargs):
        def tool_output(args, **_kwargs):
            return "\tmod\tgolang.org/x/mobile\tv-fixture\n" if args[:3] == ["go", "version", "-m"] else "fixture toolchain/source\n"
        with patch.object(core.shutil, "which", return_value="/fixture/gomobile"), \
                patch.object(core.subprocess, "check_output", side_effect=tool_output):
            return core.record(self.root, self.lock, self.products, "ci-rebuild", **kwargs)

    def test_hosted_rebuild_keeps_source_lock_and_binds_the_actual_slices(self):
        self.record()
        verified = core.verify(self.root, self.lock, self.products)
        self.assertEqual(self.original, self.lock.read_bytes())
        self.assertEqual(verified["slices"], core.slice_digests(self.products / "AegisEmbeddedCore.xcframework"))
        self.assertNotEqual(verified["slices"]["iosArm64Sha256"], "0" * 64)

    def test_packaging_work_uses_its_own_xcode_inputs_and_verifies_staged_sources(self):
        from shutil import copytree
        work = self.root / "clean work"
        copytree(self.root / "apps", work / "apps")
        staged_lock = work / self.lock.relative_to(self.root)
        self.record(xcode_root=work, xcode_lock=staged_lock)
        core.verify(work, staged_lock, self.products)
        with self.assertRaisesRegex(ValueError, "Xcode input list"):
            core.verify(self.root, self.lock, self.products)
        (work / "apps/ios/EmbeddedCore/bridge/bridge.go").write_text("changed")
        with self.assertRaisesRegex(ValueError, "manifest"):
            core.verify(work, staged_lock, self.products)

    def test_strict_build_does_not_accept_a_new_binary_digest(self):
        with self.assertRaisesRegex(ValueError, "frozen digests"):
            core.record(self.root, self.lock, self.products, "strict")
        self.assertEqual(self.original, self.lock.read_bytes())

    def test_each_stale_or_changed_slice_is_rejected_before_linking(self):
        self.record()
        for name in core.SLICE_KEYS:
            binary = self.products / "AegisEmbeddedCore.xcframework" / name / "AegisEmbeddedCore.framework/AegisEmbeddedCore"
            original = binary.read_bytes()
            binary.write_bytes(b"binary left by another build")
            with self.subTest(slice=name), self.assertRaisesRegex(ValueError, "manifest"):
                core.verify(self.root, self.lock, self.products)
            binary.write_bytes(original)

    def test_changed_effective_lock_and_bridge_are_rejected(self):
        self.record()
        for path in [self.products / "embedded-core-lock.json", self.root / "apps/ios/EmbeddedCore/bridge/bridge.go"]:
            original = path.read_bytes()
            path.write_bytes(original + b"changed")
            with self.subTest(input=path.name), self.assertRaisesRegex(ValueError, "manifest"):
                core.verify(self.root, self.lock, self.products)
            path.write_bytes(original)

    def test_bundle_requires_the_effective_manifest_and_records_the_actual_app_binary(self):
        self.record()
        app = self.root / "Aegis.app"
        resource = app / "Frameworks/AccessKit.framework/embedded-core-lock.json"
        resource.parent.mkdir(parents=True)
        resource.write_bytes(self.original)
        (app / "Aegis").write_bytes(b"actual linked app")
        with self.assertRaisesRegex(ValueError, "bundled"):
            core.verify_bundle(app, self.products, self.root / "DerivedData", "simulator")
        resource.write_bytes((self.products / "embedded-core-lock.json").read_bytes())
        (resource.parent / "embedded-core-build.json").write_bytes((self.products / "build-manifest.json").read_bytes())
        with patch("ios_linked_core.verify_link", return_value={"coreCarrierSha256": "fixture"}) as linked:
            receipt = core.verify_bundle(app, self.products, self.root / "DerivedData", "simulator")
        linked.assert_called_once_with(app, self.products, self.root / "DerivedData", "simulator")
        self.assertEqual(receipt["appBinarySha256"], core.file_digest(app / "Aegis"))

    def test_internal_archive_upgrades_legacy_cache_and_passes_the_resolved_products_to_xcode(self):
        from shutil import copy2
        import os
        import plistlib
        import subprocess

        release = self.root / "scripts/release"
        release.mkdir(parents=True)
        for name in ("ios_embedded_core.py", "ios-internal-archive.sh"):
            copy2(Path(__file__).with_name(name), release / name)
        legacy = self.root / "apps/ios/EmbeddedCore/Products/AegisEmbeddedCore.xcframework"
        legacy.mkdir(parents=True)
        (legacy / "legacy").write_bytes(b"old cache must not satisfy this build")
        for target in ("AegisApp", "SafariWebExtension", "ShareExtension"):
            info = self.root / "apps/ios" / target / "Info.plist"
            info.parent.mkdir()
            info.write_bytes(plistlib.dumps({}))
        tools = self.root / "bin"
        tools.mkdir()
        # Stop at the Xcode archive invocation, before signing or packaging.
        for name, body in {"xcodegen": "exit 0", "xcodebuild": 'printf "%s\\n" "$@" > "$ARGS"; exit 73'}.items():
            tool = tools / name
            tool.write_text("#!/bin/sh\n" + body + "\n")
            tool.chmod(0o755)
        (release / "prepare-ios-access-core.sh").write_text(
            'set -eu\nprintf "%s\\n" "$@" >> "$PREP"\nmkdir -p "$(dirname "$2")"\ncp -R "$TEMPLATE" "$2"\n')
        for relative in (".artifacts/ios-embedded-core", "external cache/products"):
            original = self.products
            self.products = self.root / relative
            self.products.parent.mkdir(exist_ok=True, parents=True)
            original.rename(self.products)
            self.record()
            template = self.root / "prepared-fixture"
            self.products.rename(template)
            args, prep = self.root / "args", self.root / "prep"
            env = dict(os.environ, PATH=str(tools) + ":" + os.environ["PATH"], ARGS=str(args),
                       PREP=str(prep), TEMPLATE=str(template), AEGIS_EMBEDDED_CORE_DIGEST_MODE="ci-rebuild")
            env.pop("AEGIS_EMBEDDED_CORE_PRODUCTS", None)
            if relative.startswith("external"):
                env["AEGIS_EMBEDDED_CORE_PRODUCTS"] = relative
            for _ in range(2):
                result = subprocess.run(["bash", release / "ios-internal-archive.sh"], cwd=self.root, env=env,
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 73, result.stdout)
                self.assertIn("AEGIS_EMBEDDED_CORE_PRODUCTS=" + str(self.products), args.read_text().splitlines())
            self.assertEqual(prep.read_text().splitlines(), [str(self.lock), str(self.products)])
            self.assertTrue((legacy / "legacy").is_file())
            prep.unlink()
            template.rename(original)
            self.products = original


class RequiredLiveLeavesTests(unittest.TestCase):
    def results(self, statuses=("Passed", "Passed", "Passed")):
        return {"testNodes": [{"nodeType": "Unit test bundle", "name": "AegisTests", "result": "Passed",
                               "children": [{"nodeType": "Test Suite", "name": "AccessEmbeddedCoreLiveTests",
                                             "result": "Passed", "children": [
                                                 {"nodeType": "Test Case", "name": identifier.split("/")[-1],
                                                  "nodeIdentifier": identifier, "result": status}
                                                 for identifier, status in zip(gate.REQUIRED, statuses)]}]}]}

    def test_requires_all_three_explicit_successful_identifiers(self):
        result = gate.evaluate(self.results())
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(set(result["requiredTestCases"]), set(gate.REQUIRED))

    def test_import_pass_with_dial_and_tunnel_skipped_is_not_pass(self):
        document = self.results(("Passed", "Skipped", "Skipped"))
        leaves = document["testNodes"][0]["children"][0]["children"]
        for leaf in leaves[1:]:
            leaf["children"] = [{"nodeType": "Skip Message", "name": "fixture configuration missing"}]
        result = gate.evaluate(document)
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["requiredTestCases"][gate.REQUIRED[1]], ["Skipped"])

    def test_failed_missing_or_unknown_leaf_is_not_pass(self):
        for status in ("Failed", "Skipped", "Unknown", "Expected Failure"):
            with self.subTest(status=status):
                self.assertEqual(gate.evaluate(self.results(("Passed", status, "Passed")))["status"], "FAIL")
        document = self.results()
        document["testNodes"][0]["children"][0]["children"].pop()
        self.assertEqual(gate.evaluate(document)["status"], "FAIL")

    def test_suite_success_and_display_names_cannot_satisfy_required_leaves(self):
        document = self.results()
        suite = document["testNodes"][0]["children"][0]
        suite["children"] = []
        self.assertEqual(gate.evaluate(document)["status"], "FAIL")
        document = self.results()
        for leaf in document["testNodes"][0]["children"][0]["children"]:
            leaf["nodeIdentifier"] = "OtherTests/" + leaf["nodeIdentifier"].split("/", 1)[1]
        self.assertEqual(gate.evaluate(document)["status"], "FAIL")

    def test_bundle_context_resolves_short_identifiers_but_keeps_prior_failure(self):
        document = self.results()
        leaves = document["testNodes"][0]["children"][0]["children"]
        for leaf in leaves:
            leaf["nodeIdentifier"] = leaf["nodeIdentifier"].split("/", 1)[1]
        self.assertEqual(gate.evaluate(document)["status"], "PASS")
        failure = copy.deepcopy(leaves[0])
        failure["result"] = "Failed"
        leaves.append(failure)
        self.assertEqual(gate.evaluate(document)["status"], "FAIL")


if __name__ == "__main__":
    unittest.main()
