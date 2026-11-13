"""Offline preparation tests; no device, signing or Apple operations."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
from tempfile import TemporaryDirectory
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("alpha_device", HERE / "prepare-alpha-device-project.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class AlphaDeviceProjectTest(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name).resolve()
        self.root = self.base / "source"
        self.ios = self.root / "apps/ios"
        self.ios.mkdir(parents=True)
        source = HERE.parent
        self.spec = module.load_spec(source / "project.yml")
        paths = set(module.REPLACEMENTS) | {"project.yml"}
        for target in self.spec["targets"].values():
            paths.update(value for key, value in target["settings"]["base"].items()
                         if key in ("INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS"))
        for rel in paths:
            destination = self.ios / rel
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / rel, destination)
        self.products = self.base / "products"
        (self.products / "AegisEmbeddedCore.xcframework").mkdir(parents=True)
        self.out = self.base / "alpha"

    def prepare(self, **kwargs):
        return module.prepare(self.root, self.out, self.products, "R3JK7R29AC", **kwargs)

    def hashes(self):
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.root.rglob("*") if p.is_file()}

    def test_isolated_spec_preserves_sources_targets_permissions_and_build_contract(self):
        before = self.hashes()
        receipt = self.prepare()
        self.assertEqual(before, self.hashes())
        spec = module.load_spec(self.out / "project.yml")
        self.assertEqual(set(spec["targets"]), set(self.spec["targets"]))
        self.assertEqual(spec["packages"], self.spec["packages"])
        self.assertEqual(spec["schemes"], self.spec["schemes"])
        self.assertFalse(spec["options"]["createIntermediateGroups"])
        for name, target in spec["targets"].items():
            original = self.spec["targets"][name]
            settings = target["settings"]["base"]
            self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], module.APP + module.IDS[name])
            self.assertEqual(settings["PRODUCT_NAME"], original["settings"]["base"]["PRODUCT_NAME"])
            self.assertEqual(target.get("dependencies"), original.get("dependencies"))
            self.assertTrue(all(Path(row["path"]).is_absolute() for row in target["sources"]))
            for script in target.get("postBuildScripts", []):
                self.assertNotIn("SRCROOT", json.dumps(script))
                self.assertNotIn(" record ", script["script"])
            if name in ("Aegis", "ShareExtension"):
                ent = plistlib.loads(Path(settings["CODE_SIGN_ENTITLEMENTS"]).read_bytes())
                self.assertEqual(ent, {"com.apple.security.application-groups": [module.GROUP]})
            if name == "SafariWebExtension":
                self.assertEqual(plistlib.loads(Path(settings["CODE_SIGN_ENTITLEMENTS"]).read_bytes()), {})
        app = spec["targets"]["Aegis"]
        self.assertTrue(all(c["AEGIS_FIREBASE_CHANNEL"] == "disabled" for c in app["settings"]["configs"].values()))
        app_info = plistlib.loads(Path(app["settings"]["base"]["INFOPLIST_FILE"]).read_bytes())
        old_info = plistlib.loads((self.ios / "AegisApp/Info.plist").read_bytes())
        for key in old_info.keys() - {"CFBundleURLTypes", "CFBundleDisplayName"}:
            self.assertEqual(app_info[key], old_info[key])
        self.assertEqual(app_info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], [module.SCHEME])
        for name in ("Aegis", "SafariWebExtension"):
            entries = spec["targets"][name]["sources"]
            original_js = next(e for e in entries if e["path"] == str(self.ios / "SharedWebExtension"))
            self.assertIn("background.js", original_js["excludes"])
            self.assertEqual(sum(e["path"].endswith("background.js") for e in entries), 1)
        self.assertEqual(receipt["kind"], "isolated-alpha-device-test-variant")
        for item in receipt["overlays"]:
            self.assertEqual(hashlib.sha256((self.out / item["path"]).read_bytes()).hexdigest(), item["overlaySha256"])
        self.assertEqual(receipt["coreVerification"], "NOT_RUN")

    def test_all_group_and_external_scheme_runtime_occurrences_are_replaced(self):
        self.prepare()
        for rel, (old, new, count) in module.REPLACEMENTS.items():
            text = (self.out / "overlay" / rel).read_text()
            self.assertNotIn(old, text)
            self.assertEqual(text.count(new), count)
        local = self.out / "overlay/Shared/AppLocalization.swift"
        self.assertIn(module.GROUP, local.read_text())

    def test_unknown_group_reference_blocks_generation(self):
        extra = self.ios / "AegisApp/Unexpected.swift"
        extra.write_text('let group = "' + module.OLD_GROUP + '"')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.out.exists())

    def test_replacement_count_change_blocks_generation(self):
        path = self.ios / "Shared/ShareInbox.swift"
        path.write_text(path.read_text() + '\n// ' + module.OLD_GROUP)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.out.exists())

    def test_existing_output_and_symlink_are_not_overwritten(self):
        self.out.mkdir()
        marker = self.out / "keep"
        marker.write_text("keep")
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(marker.read_text(), "keep")
        link = self.base / "linked"
        link.symlink_to(self.out)
        with self.assertRaises(ValueError):
            module.prepare(self.root, link, self.products, "R3JK7R29AC")

    def test_output_inside_ios_is_rejected(self):
        with self.assertRaises(ValueError):
            module.prepare(self.root, self.ios / "variant", self.products, "R3JK7R29AC")

    def test_private_node_path_only_and_receipt_does_not_contain_it(self):
        private = self.base / "private"
        private.mkdir(mode=0o700)
        node = private / "test-node"
        node.write_text("SECRET-NODE-CONTENT")
        node.chmod(0o600)
        self.prepare(node_file=node)
        receipt = (self.out / "preparation-receipt.json").read_text()
        self.assertNotIn(str(node), receipt)
        self.assertNotIn("SECRET-NODE-CONTENT", receipt)
        spec = json.loads((self.out / "project.yml").read_text())
        self.assertEqual(spec["targets"]["Aegis"]["settings"]["base"]["AEGIS_PRIVATE_TEST_NODE_FILE"], str(node))
        node.chmod(0o644)
        with self.assertRaises(ValueError):
            module.private_path(node)


if __name__ == "__main__":
    unittest.main()
