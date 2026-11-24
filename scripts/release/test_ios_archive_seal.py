"""Check the archive seal against current scratch linker records, without Xcode."""
import errno
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import signal
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

import ios_embedded_core as core
import ios_linked_core as linked


def ci_module(name):
    path = Path(__file__).resolve().parents[1] / "ci" / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


storage = ci_module("ios-ci-storage")
supervisor = ci_module("ios-archive-supervisor")


class ArchiveSealTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name).resolve()
        self.root = self.parent / "current"
        self.root.mkdir(mode=0o700)
        self.workspace = self.root / "Source"
        lock = self.workspace / "apps/ios/EmbeddedCore/embedded-core-lock.json"
        bridge = lock.parent / "bridge"
        bridge.mkdir(parents=True)
        (bridge / "bridge.go").write_text("package fixture\n")
        self.products = self.root / "EmbeddedCore"
        framework = self.products / "AegisEmbeddedCore.xcframework"
        self.selected = framework / "ios-arm64" / linked.CORE
        for item in (self.selected, framework / "ios-arm64_x86_64-simulator" / linked.CORE):
            item.parent.mkdir(parents=True)
            item.write_bytes(b"synthetic static archive")
        (framework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [
            {"LibraryIdentifier": "ios-arm64", "SupportedPlatform": "ios"}]}))
        pin = {"gomobile": "golang.org/x/mobile@fixture"}
        source = {"status": "verified_build", "toolchain": pin, "artifacts": core.slice_digests(framework)}
        lock.write_text(json.dumps(source))
        effective = self.products / "embedded-core-lock.json"
        shutil.copyfile(lock, effective)
        inputs = self.products / "build-inputs.xcfilelist"
        inputs.write_text(core.input_list(self.workspace, lock, self.products, framework))
        bridge_hash = core.directory_digest(bridge)
        manifest = self.products / "build-manifest.json"
        core.write_json(manifest, {"schemaVersion": 1, "kind": "ios-embedded-core-build",
            "bridgeSha256": bridge_hash, "compiledBridgeSha256": bridge_hash, "sourceLockSha256": core.file_digest(lock),
            "effectiveLockSha256": core.file_digest(effective), "inputFileListSha256": core.file_digest(inputs),
            "frameworkSha256": core.directory_digest(framework), "slices": source["artifacts"],
            "gomobileModule": pin["gomobile"], "gobindModule": pin["gomobile"],
            "bindingToolPolicy": core.BINDING_TOOL_POLICY,
            "appleToolchain": core.APPLE_TOOLCHAIN, "clangSha256": dict.fromkeys(core.IOS_SDKS, "1" * 64)})
        self.bundle = self.root / "Aegis.xcarchive/Products/Applications/Aegis.app"
        bundled = self.bundle / "Frameworks" / linked.ACCESS
        bundled.parent.mkdir(parents=True)
        bundled.write_bytes(b"synthetic dylib")
        (self.bundle / "Aegis").write_bytes(b"synthetic app")
        shutil.copyfile(effective, bundled.parent / effective.name)
        shutil.copyfile(manifest, bundled.parent / "embedded-core-build.json")
        self.native_run = storage.subprocess.run
        self.metadata = dict(source_sha="a" * 40, source_tree="b" * 40, run_id="100", run_attempt="1", job="ios-archive")
        self.state = dict(self.metadata, root=str(self.root), device=self.root.stat().st_dev, inode=self.root.stat().st_ino,
                          placement="hosted-ephemeral")
        self.historical = self.parent / "historical"
        self.historical.mkdir(mode=0o700)
        (self.historical / "sentinel").write_text("historical evidence")
        self.other = supervisor.JobScratch(self.historical)
        (self.other.path / "sentinel").write_text("other job evidence")

    def write_dependency_record(self, derived):
        record = derived / "Build/Intermediates/Release-iphoneos/AccessKit.build/Objects-normal/arm64/AccessKit_dependency_info.dat"
        record.parent.mkdir(parents=True)
        linked_output = derived / "Build/Products/AccessKit"
        linked_output.parent.mkdir(parents=True)
        linked_output.write_bytes(b"synthetic dylib")
        record.write_bytes(b"\x10" + os.fsencode(self.selected) + b"\0\x40" + os.fsencode(linked_output) + b"\0")
        return record

    def native_output(self, tool, *args):
        if tool == "lipo":
            return "arm64\n"
        if tool == "otool":
            return "synthetic Mach-O:\n @rpath/" + linked.ACCESS + " (compatibility version 1.0.0)\n"
        if tool == "dwarfdump":
            return "UUID: ABCDEF01 (arm64)\n"
        if tool == "nm":
            return "_proxyembeddedcore__Start\n_proxyembeddedcore__Dial\n"
        raise AssertionError((tool, args))

    def native_process(self, command, **kwargs):
        if command[0] == "ar":
            kwargs["stdout"].write(b"synthetic Go object")
        elif command[0] == "/usr/bin/ditto" and not Path(command[0]).is_file():
            with ZipFile(command[-1], "x") as archive:
                archive.write(self.bundle / "Aegis", "Aegis.xcarchive/Aegis")
        else:
            return self.native_run(command, **kwargs)

    def run_seal(self, path, environment):
        with (patch.object(storage, "source_metadata", return_value=self.metadata),
              patch.object(storage, "private_json", return_value=(self.state, "")),
              patch.object(linked, "output", side_effect=self.native_output),
              patch.object(linked, "sections", return_value={("__TEXT", "__text"): "text", ("__TEXT", "__gopclntab"): "go"}),
              patch.object(storage.subprocess, "run", side_effect=self.native_process)):
            storage.seal(self.root, environment, derived=path)

    def assert_other_job_unchanged(self):
        self.assertEqual((self.historical / "sentinel").read_text(), "historical evidence")
        self.assertEqual((self.other.path / "sentinel").read_text(), "other job evidence")

    def test_seal_uses_current_linker_record_before_supervised_cleanup(self):
        for mode in ("success", "missing", "cancelled", "unconfirmed"):
            with self.subTest(mode=mode):
                self.run_stage_fixture(mode)
                self.assert_other_job_unchanged()

    def run_stage_fixture(self, mode):
        locations = []
        def stage(command, environment, cancelled, _signaler):
            action = command[-1]
            scratch = Path(environment["IOS_CI_SCRATCH"])
            derived = scratch / "DerivedData"
            locations[:] = [scratch]
            if action == "--compile-archive":
                if mode != "missing":
                    self.write_dependency_record(derived)
                if mode == "cancelled":
                    signal.raise_signal(signal.SIGTERM)
                if mode == "unconfirmed":
                    raise OSError(errno.EBUSY, "fixture stage has not stopped")
            if action == "--verify-archive":
                assert not cancelled()
                self.run_seal(derived, environment)
            return 0
        with (patch.object(supervisor, "archive_environment", return_value={
                    "IOS_CI_ROOT": str(self.root), "IOS_CI_SOURCE": str(Path.cwd())}),
              patch.object(supervisor, "run_stage", side_effect=stage)):
            handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGCHLD)}
            try:
                arguments = (str(self.root / "status.log"), "fixture-shell", "fixture-wrapper")
                if mode in ("missing", "unconfirmed"):
                    error = ValueError if mode == "missing" else OSError
                    with self.assertRaises(error):
                        supervisor.main(*arguments)
                else:
                    self.assertEqual(supervisor.main(*arguments), 143 if mode == "cancelled" else 0)
            finally:
                for sig, handler in handlers.items():
                    signal.signal(sig, handler)
        self.assertEqual(locations[0].exists(), mode == "unconfirmed")
        receipt = self.root / "unsigned-artifact.json"
        archive = self.root / "Aegis.xcarchive.zip"
        self.assertEqual(receipt.is_file(), mode == "success")
        self.assertEqual(archive.is_file(), mode == "success")
        if mode == "success":
            data = json.loads(receipt.read_text())
            self.assertEqual(data["archive_sha256"], core.file_digest(archive))
            self.assertEqual(data["embedded_core"]["linkedArchitectures"]["arm64"]["linkedStaticArchiveSha256"],
                             core.file_digest(self.selected))
            receipt.unlink()
            archive.unlink()

    def test_seal_refuses_other_job_identity_and_redirected_linker_records(self):
        scratch = supervisor.JobScratch(self.root)
        env = scratch.environment({}, for_archive=True)
        history = self.other.path / "DerivedData"
        self.write_dependency_record(history)
        derived = scratch.path / "DerivedData"
        original = derived.rename(scratch.path / "original")
        derived.symlink_to(history, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.run_seal(derived, env)
        with self.assertRaisesRegex(ValueError, "outside"):
            self.run_seal(history, env)
        derived.unlink()
        derived.mkdir(mode=0o700)
        with self.assertRaisesRegex(ValueError, "identity"):
            self.run_seal(derived, env)
        derived.rmdir()
        original.rename(derived)
        record = self.write_dependency_record(derived)
        with self.assertRaisesRegex(ValueError, "identity"):
            self.run_seal(derived, dict(env, IOS_CI_SCRATCH_ID="0:0"))
        data = record.read_bytes()
        record.write_bytes(data.replace(os.fsencode(derived / "Build/Products/AccessKit"),
                                        os.fsencode(history / "Build/Products/AccessKit")))
        with self.assertRaisesRegex(ValueError, "outside the current"):
            self.run_seal(derived, env)
        record.unlink()
        record.symlink_to(next(history.rglob("*dependency_info.dat")))
        with self.assertRaisesRegex(ValueError, "ordinary file"):
            self.run_seal(derived, env)
        self.assertFalse((self.root / "unsigned-artifact.json").exists())
        self.assertTrue(scratch.clean())
        self.assert_other_job_unchanged()


if __name__ == "__main__":
    unittest.main()
