"""Offline preparation tests; no device, signing or Apple operations."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
# Local test fixtures use system Git with no shell.
import subprocess  # nosec B404
import tarfile
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

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

    def git(self, *arguments, text=True):
        # Every argument comes from the fixture or its temporary Git repository.
        output = subprocess.check_output(["/usr/bin/git", *arguments],
                                         cwd=self.root, text=text, shell=False)  # nosec B603
        return output.strip() if text else output

    def commit_fixture(self, message):
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def commit_snapshot_fixture(self):
        for relative in module.SNAPSHOT_PATHS[1:]:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture\0\n")
        return self.commit_fixture("source snapshot")

    def test_isolated_spec_preserves_sources_targets_permissions_and_build_contract(self):
        before = self.hashes()
        receipt = self.prepare()
        self.assertEqual(before, self.hashes())
        spec = module.load_spec(self.out / "project.yml")
        self.assertEqual(set(spec["targets"]), set(self.spec["targets"]))
        self.assertEqual(spec["packages"], self.spec["packages"])
        self.assertEqual(spec["schemes"], self.spec["schemes"])
        self.assertFalse(spec["options"]["createIntermediateGroups"])
        alpha_configs = spec["settings"]["configs"]
        for name, flags in alpha_configs.items():
            self.assertEqual(flags["AEGIS_ACCESS_RELEASE_CHANNEL"], "alpha", name)
            self.assertEqual(flags["AEGIS_ACCESS_INTERNAL_OPTIONS"], "YES", name)
        self.assertEqual(self.spec["settings"]["configs"]["Release"]["AEGIS_ACCESS_INTERNAL_OPTIONS"], "NO")
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

    def test_only_clean_git_inputs_stamp_the_prepared_app(self):
        self.assertIsNone(module.prepared_source_commit(self.root))
        # Keep a minimal but complete synthetic source tree for all XcodeGen
        # source entries, including those outside apps/ios.
        files_to_mutate = [self.ios / "AegisApp/Frozen.swift", self.ios / "Tests/AegisTests/Frozen.swift"]
        for target in self.spec["targets"].values():
            for row in target["sources"]:
                rel = Path(row["path"])
                path = (self.ios / rel).resolve()
                if not rel.suffix:
                    path = path / "fixture.swift"
                if not path.exists():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("// committed placeholder\n")
        for path in [*files_to_mutate, self.root / module.SNAPSHOT_PATHS[-1]]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// committed inputs\n")
        substitution = self.ios / "Tests/AegisTests/Export.swift"
        substitution.write_text('// approved literal $Format:%an$\n')
        executable = self.ios / "AegisApp/helper.sh"
        executable.write_text("#!/bin/sh\n")
        executable.chmod(0o755)
        (self.root / ".gitignore").write_text("Ignored.swift\n")
        commit = self.commit_fixture("fixture")
        files_to_mutate[0].write_text("// replacement bytes must not compile\n")
        self.git("add", str(files_to_mutate[0]))
        replacement = self.git("-c", "user.name=Synthetic Fixture", "-c", "user.email=fixture@example.invalid",
                               "-c", "commit.gpgSign=false", "commit-tree", self.git("write-tree"), "-m", "replacement")
        self.git("restore", "--staged", "--worktree", str(files_to_mutate[0]))
        self.git("replace", commit, replacement)
        archive_args = ("archive", commit, "--", *module.SNAPSHOT_PATHS)
        replaced = self.git(*archive_args, text=False)
        with tarfile.open(fileobj=io.BytesIO(replaced)) as archive:
            synthetic = archive.extractfile(str(files_to_mutate[0].relative_to(self.root))).read()
        self.assertEqual(synthetic, b"// replacement bytes must not compile\n")
        original = self.git("--no-replace-objects", *archive_args, text=False)
        self.assertNotEqual(replaced, original)
        self.assertEqual(module.prepared_source_commit(self.root), commit)
        (self.ios / "AegisApp/Ignored.swift").write_text("// ignored input must never compile\n")
        receipt = self.prepare()
        variant = module.load_spec(self.out / "project.yml")
        app_info = self.out / "overlay/AegisApp/Info.plist"
        self.assertEqual(receipt["sourceCommit"], commit)
        self.assertEqual(receipt["sourceArchiveSha256"], hashlib.sha256(original).hexdigest())
        self.assertEqual((self.out / "source/apps/ios/AegisApp/helper.sh").stat().st_mode & 0o777, 0o555)
        self.assertEqual((self.out / "source" / substitution.relative_to(self.root)).read_bytes(), substitution.read_bytes())
        self.assertEqual(plistlib.loads(app_info.read_bytes())["AegisPreparedSourceCommit"], commit)
        for target in ("AegisTests", "AegisUITests"):
            info = Path(variant["targets"][target]["settings"]["base"]["INFOPLIST_FILE"])
            self.assertEqual(plistlib.loads(info.read_bytes())["AegisPreparedSourceCommit"], commit)
        verifier = variant["targets"]["AccessKit"]["postBuildScripts"][0]
        self.assertIn(f'--prepared-source "{self.out / "source"}" {commit}', verifier["script"])
        self.assertIn(str(self.out / "source" / module.SNAPSHOT_PATHS[-1]), verifier["inputFiles"])
        for target in variant["targets"].values():
            for row in target["sources"]:
                self.assertTrue(Path(row["path"]).is_relative_to(self.out))
        for name, path in zip(("Aegis", "AegisTests"), files_to_mutate):
            compiled = next(Path(row["path"]) for row in variant["targets"][name]["sources"]
                            if Path(row["path"]).name == path.parent.name) / path.name
            path.write_text("// changed after XcodeGen preparation\n")
            self.assertEqual(compiled.read_text(), "// committed inputs\n")
            self.assertEqual(compiled.stat().st_mode & 0o777, 0o444)
            self.assertEqual(compiled.parent.stat().st_mode & 0o777, 0o555)
        self.assertFalse((self.out / "source/apps/ios/AegisApp/Ignored.swift").exists())
        for path in files_to_mutate:
            self.git("--no-replace-objects", "restore", str(path))
        attrs = self.root / ".git/info/attributes"
        for path, attribute, failure in [(files_to_mutate[1], "export-ignore", "omitted Git tree entries"),
                                         (substitution, "export-subst", "changed Git blob contents")]:
            with self.subTest(attribute=attribute):
                attrs.write_text(path.relative_to(self.root).as_posix() + f" {attribute}\n")
                altered = self.git("--no-replace-objects", *archive_args, text=False)
                with tarfile.open(fileobj=io.BytesIO(altered)) as archive:
                    self.assertTrue(archive.getmember("apps/ios/Tests/AegisTests").isdir())
                    if attribute == "export-ignore":
                        self.assertNotIn(path.relative_to(self.root).as_posix(), archive.getnames())
                    else:
                        altered_blob = archive.extractfile(path.relative_to(self.root).as_posix()).read()
                        self.assertEqual(len(altered_blob), path.stat().st_size)
                        self.assertNotEqual(altered_blob, path.read_bytes())
                self.out = self.base / attribute
                with self.assertRaisesRegex(ValueError, failure):
                    self.prepare()
                self.assertFalse(self.out.exists())
        attrs.unlink()
        extra = self.ios / "untracked.swift"
        extra.write_text("// synthetic untracked input\n")
        self.assertIsNone(module.prepared_source_commit(self.root))
        extra.unlink()
        with (self.ios / "AegisApp/Info.plist").open("ab") as stream:
            stream.write(b"\n")
        self.assertIsNone(module.prepared_source_commit(self.root))

    def test_source_commit_and_snapshot_do_not_require_git_on_path(self):
        commit = self.commit_snapshot_fixture()
        with patch.dict(os.environ, {"PATH": str(self.base)}):
            self.assertEqual(module.prepared_source_commit(self.root), commit)
            module.snapshot_source(self.root, commit, self.out)
        self.assertEqual((self.out / module.SNAPSHOT_PATHS[-1]).read_bytes(), b"fixture\0\n")

    def test_snapshot_requires_full_commit_id(self):
        self.commit_snapshot_fixture()
        with self.assertRaisesRegex(ValueError, "invalid Alpha source commit"):
            module.snapshot_source(self.root, "HEAD", self.out)
        self.assertFalse(self.out.exists())

    def test_snapshot_rejects_tracked_escaping_symlink(self):
        path = self.ios / "AegisApp/escaping"
        path.symlink_to("../../../../outside")
        commit = self.commit_fixture("symlink fixture")
        with self.assertRaisesRegex(ValueError, "unsupported Git tree entry"):
            module.snapshot_source(self.root, commit, self.out)
        self.assertFalse(self.out.exists())

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
