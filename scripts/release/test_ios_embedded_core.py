"""Binary provenance and live-leaf regression checks; no Xcode or private node required."""
import copy
import json
import os
from pathlib import Path
import plistlib
import runpy
import select
import shutil
import subprocess
import sys
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
        self.toolchain = {"go": "1.27.3", "xcode": "27A266a",
                          "gomobile": "golang.org/x/mobile@v0.0.0-20261011034528-197770444867"}
        sum_source = Path(__file__).resolve().parents[2] / "apps/ios/EmbeddedCore/bridge/go.sum"
        shutil.copyfile(sum_source, bridge / "go.sum")
        self.lock.write_text(json.dumps({"status": "verified_build", "xrayCore": {"commit": "a" * 40},
                                         "toolchain": self.toolchain,
                                         "artifacts": {key: "0" * 64 for key in core.SLICE_KEYS.values()}}))
        self.original = self.lock.read_bytes()
        self.compiler = self.root / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        self.compiler.parent.mkdir(parents=True)
        self.compiler.write_bytes(b"synthetic compiler identity")
        self.products = self.root / "separate-build-output"
        self.build_bridge = self.products / "work/bridge"
        self.framework = self.products / "AegisEmbeddedCore.xcframework"
        for name in core.SLICE_KEYS:
            binary = self.framework / name / "AegisEmbeddedCore.framework/AegisEmbeddedCore"
            binary.parent.mkdir(parents=True)
            binary.write_bytes((name + " actual binary bytes").encode())
        self.copy_build_bridge()

    def copy_build_bridge(self):
        shutil.copytree(self.lock.parent / "bridge", self.build_bridge, dirs_exist_ok=True)
        (self.products / "compiled-bridge.sha256").write_text(core.directory_digest(self.build_bridge) + "\n")

    def record(self, mode="ci-rebuild", commit="a" * 40, **kwargs):
        def tool_output(args, **_kwargs):
            if args[:4] == ["go", "version", "-m", "-json"]:
                return json.dumps(self.binding_metadata(Path(args[-1]).name))
            return {
                "go": f"go version go{self.toolchain['go']} darwin/arm64\n",
                "git": commit + "\n",
                "xcodebuild": "Xcode 27.0\nBuild version 27A266a\n",
                "xcrun": str(self.compiler) + "\n" if args[-1] == "clang" else
                    "24A222\n" if args[-1] == "--show-sdk-build-version" else "27.0\n",
            }[args[0]]
        with patch.dict(os.environ, {"DEVELOPER_DIR": str(self.root), "TOOLCHAINS": "org.fixture.alternative"}), \
                patch.object(core.subprocess, "check_output", side_effect=tool_output):
            apple = core.apple_metadata(core.apple_build_environment(os.environ))
            return core.record(self.root, self.lock, self.products, mode, apple=apple, go="go",
                               tools=("/fixture/gomobile", "/fixture/gobind"), **kwargs)

    def freeze_synthetic_slices(self):
        layout = core.normalized_xcframework_info()
        (self.framework / "ios-arm64-simulator").rename(self.framework / "ios-arm64_x86_64-simulator")
        for library in layout["AvailableLibraries"]:
            leaf = self.framework / library["LibraryIdentifier"] / core.FRAMEWORK_NAME
            for name in ("Info.plist", "Modules/module.modulemap", "Headers/AegisEmbeddedCore.h",
                         "Headers/Embeddedcore.objc.h", "Headers/Universe.objc.h", "Headers/ref.h"):
                path = leaf / name
                path.parent.mkdir(exist_ok=True)
                path.write_text(f"synthetic {name}\n")
        (self.framework / "Info.plist").write_bytes(plistlib.dumps(layout, sort_keys=True))
        source_lock = json.loads(self.lock.read_bytes())
        source_lock["artifacts"] = core.slice_digests(self.framework)
        core.write_json(self.lock, source_lock)

    def git_snapshot(self):
        # The fixture commits only synthetic inputs and the actual installer.
        repo = Path(core.__file__).resolve().parents[2]
        snapshot_source = runpy.run_path(str(repo / "apps/ios/scripts/prepare-alpha-device-project.py"))
        for relative in snapshot_source["SNAPSHOT_PATHS"][1:]:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(Path(core.__file__).read_bytes() if path.name == "ios_embedded_core.py" else b"fixture\n")
        recipe = self.root / "scripts/release/ios_core_build.py"
        recipe.write_text('from pathlib import Path\nimport sys\nPath(sys.argv[1]).write_bytes(bytes.fromhex(sys.argv[2]))\n')
        launch = recipe.with_name("launch.py")
        launch.write_text('import os\nimport sys\nprint("ready", flush=True)\n'
                          'if sys.stdin.readline() != "build\\n": sys.exit(2)\n'
                          'os.execv(sys.executable, [sys.executable, "-B", *sys.argv[1:]])\n')
        self.git = ["git", "--no-replace-objects", "-C", str(self.root)]
        subprocess.run([*self.git, "init", "-q"], check=True)
        subprocess.run([*self.git, "add", "apps", "packages", "scripts"], check=True)
        subprocess.run([*self.git, "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-qm", "synthetic freeze"], check=True)
        commit = subprocess.check_output([*self.git, "rev-parse", "HEAD"], text=True).strip()
        prepared = self.root / "prepared"
        snapshot_source["snapshot_source"](self.root, commit, prepared)
        return prepared, commit, recipe, launch

    def install(self, bundle, prepared=None, commit=None):
        verifier = (prepared / "scripts/release/ios_embedded_core.py") if prepared else Path(core.__file__)
        command = [sys.executable, "-B", str(verifier), "install", "--root", str(self.root),
                   "--source-lock", str(self.lock), "--products", str(self.products), "--bundle", str(bundle)]
        if prepared:
            command.extend(("--prepared-source", str(prepared), commit))
        return subprocess.run(command, capture_output=True, text=True, timeout=10)

    def binding_metadata(self, name):
        path = "golang.org/x/mobile"
        graph = {module: {key: value for key, value in info.items() if key != "GoModSum"}
                 for module, info in core.mobile_modules(self.toolchain, self.lock.parent / "bridge").items()}
        return {"GoVersion": "go1.27.3", "Path": f"{path}/cmd/{name}", "Main": graph.pop(path),
                "Deps": list(graph.values()),
                "Settings": [{"Key": "GOOS", "Value": "darwin"}, {"Key": "GOARCH", "Value": "arm64"}]}

    def test_binding_metadata_rejects_wrong_platform_or_injected_dependency(self):
        graph = core.mobile_modules(self.toolchain, self.build_bridge)
        for fault in ("foreign OS", "foreign arch", "local replacement", "wrong checksum", "missing dependency"):
            metadata = self.binding_metadata("gobind")
            if fault == "foreign OS":
                metadata["Settings"][0]["Value"] = "linux"
            if fault == "foreign arch":
                metadata["Settings"][1]["Value"] = "amd64"
            if fault == "local replacement":
                metadata["Deps"][-1]["Replace"] = {"Path": "../fixture"}
            if fault == "wrong checksum":
                metadata["Deps"][-1]["Sum"] = "h1:" + "a" * 43 + "="
            if fault == "missing dependency":
                metadata["Deps"].pop()
            with self.subTest(fault=fault), patch.object(core.subprocess, "check_output", return_value=json.dumps(metadata)):
                with self.assertRaisesRegex(ValueError, "host or module graph"):
                    core.check_mobile_tool("go", "/fixture/gobind", "gobind", self.toolchain, graph, "arm64")

    def test_old_binding_receipt_needs_regeneration(self):
        receipt = self.record()
        del receipt["bindingToolPolicy"]
        core.write_json(self.products / "build-manifest.json", receipt)
        with self.assertRaisesRegex(ValueError, "private binding tool provenance"):
            core.verify(self.root, self.lock, self.products)

    def test_hosted_rebuild_keeps_source_lock_and_binds_the_actual_slices(self):
        self.record()
        verified = core.verify(self.root, self.lock, self.products)
        self.assertEqual(self.original, self.lock.read_bytes())
        self.assertEqual(verified["slices"], core.slice_digests(self.products / "AegisEmbeddedCore.xcframework"))
        self.assertNotEqual(verified["slices"]["iosArm64Sha256"], "0" * 64)
        self.assertEqual(verified["appleToolchain"], core.APPLE_TOOLCHAIN)
        self.assertEqual(verified["clangSha256"], dict.fromkeys(core.IOS_SDKS, core.file_digest(self.compiler)))

    def test_compiler_outside_selected_default_toolchain_is_rejected(self):
        other_compiler = self.root / "alternate-toolchain-clang"
        other_compiler.write_bytes(b"synthetic alternate compiler")
        with patch.object(core.subprocess, "check_output", return_value=str(other_compiler) + "\n"):
            with self.assertRaisesRegex(ValueError, "outside the pinned Xcode toolchain"):
                core.apple_metadata({"DEVELOPER_DIR": str(self.root), "TOOLCHAINS": core.APPLE_TOOLCHAIN})

    def test_cached_receipt_requires_the_pinned_apple_toolchain_and_both_clang_identities(self):
        recorded = self.record()
        for changed in (dict(recorded, appleToolchain="org.fixture.alternative"),
                        dict(recorded, clangSha256={"iphoneos": "a" * 64})):
            core.write_json(self.products / "build-manifest.json", changed)
            with self.assertRaisesRegex(ValueError, "Apple compiler provenance"):
                core.verify(self.root, self.lock, self.products)

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
            core.record(self.root, self.lock, self.products, "strict", apple={}, go="go", tools=())
        self.assertEqual(self.original, self.lock.read_bytes())

    def test_strict_apple_metadata_enforces_the_frozen_xcode_and_any_sdk_pins(self):
        sdk_versions = {"iphoneos": "27.2", "iphonesimulator": "27.2"}
        sdk_builds = {"iphoneos": "24B8118", "iphonesimulator": "24B8118"}
        toolchain = {"xcode": "27B52", "sdkVersions": sdk_versions, "sdkBuildVersions": sdk_builds}
        metadata = {"xcodeVersion": "Xcode 27.2\nBuild version 27B52",
                    "sdkVersions": sdk_versions, "sdkBuildVersions": sdk_builds}
        core.verify_apple_pin(metadata, toolchain)
        for changed in (dict(metadata, xcodeVersion="Xcode 27.2\nBuild version 27B53"),
                        dict(metadata, sdkVersions={"iphoneos": "27.3", "iphonesimulator": "27.2"}),
                        dict(metadata, sdkBuildVersions={"iphoneos": "24B8118", "iphonesimulator": "24B9999"})):
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, "Apple toolchain"):
                core.verify_apple_pin(changed, toolchain)

    def test_prepared_source_rejects_a_rebuild_from_edited_bridge_at_same_commit(self):
        from shutil import copytree
        self.freeze_synthetic_slices()
        prepared = self.root / "prepared"
        copytree(self.root / "apps", prepared / "apps")
        self.record("strict")
        verified = core.verify(self.root, self.lock, self.products)
        core.verify_prepared_source(verified, prepared, verified["sourceCommit"], self.framework)
        with self.assertRaisesRegex(ValueError, "prepared Alpha source"):
            core.verify_prepared_source(verified, prepared, "other commit", self.framework)
        (self.root / "apps/ios/EmbeddedCore/bridge/bridge.go").write_text("package bridge\n// modified input\n")
        self.copy_build_bridge()
        self.record()
        rebuilt = core.verify(self.root, self.lock, self.products)
        self.assertEqual(rebuilt["sourceCommit"], verified["sourceCommit"])
        with self.assertRaisesRegex(ValueError, "prepared Alpha source"):
            core.verify_prepared_source(rebuilt, prepared, verified["sourceCommit"], self.framework)

    def test_frozen_layout_follows_generated_headers_only_when_both_slices_agree(self):
        self.freeze_synthetic_slices()
        leaves = [self.framework / library["LibraryIdentifier"] / core.FRAMEWORK_NAME / "Headers"
                  for library in core.normalized_xcframework_info()["AvailableLibraries"]]
        for headers in leaves:
            (headers / "Newexport.objc.h").write_text("synthetic export\n")
        core.verify_frozen_xcframework_layout(self.framework)
        faults = {"one slice": [leaves[0] / "Extra.objc.h"],
                  "hidden header": [headers / ".hidden.h" for headers in leaves],
                  "non-header": [headers / "notes.txt" for headers in leaves]}
        for fault, added in faults.items():
            with self.subTest(fault=fault):
                for path in added:
                    path.write_text("synthetic\n")
                with self.assertRaisesRegex(ValueError, "frozen Alpha layout"):
                    core.verify_frozen_xcframework_layout(self.framework)
                for path in added:
                    path.unlink()
        umbrellas = [headers / "AegisEmbeddedCore.h" for headers in leaves]
        saved = [path.read_bytes() for path in umbrellas]
        for path in umbrellas:
            path.unlink()
        with self.subTest(fault="missing umbrella"), self.assertRaisesRegex(ValueError, "frozen Alpha layout"):
            core.verify_frozen_xcframework_layout(self.framework)
        for path, data in zip(umbrellas, saved):
            path.write_bytes(data)
        core.verify_frozen_xcframework_layout(self.framework)

    def test_restoring_checkout_cannot_relabel_different_compiled_bridge(self):
        prepared = self.root / "prepared"
        shutil.copytree(self.root / "apps", prepared / "apps")
        live = self.lock.parent / "bridge/bridge.go"
        original = live.read_bytes()
        live.write_bytes(original + b"// different during build\n")
        self.copy_build_bridge()
        live.write_bytes(original)

        recorded = self.record()
        with self.assertRaisesRegex(ValueError, "prepared Alpha source"):
            core.verify_prepared_source(recorded, prepared, recorded["sourceCommit"], self.framework)
        with self.assertRaisesRegex(ValueError, "build inputs differ"):
            core.verify(self.root, self.lock, self.products)
        self.assertEqual(recorded["compiledBridgeSha256"], core.directory_digest(self.build_bridge))

    def test_copy_changed_after_bind_or_missing_digest_cannot_be_recorded(self):
        (self.build_bridge / "bridge.go").write_text("changed after compilation")
        with self.assertRaisesRegex(ValueError, "differs from the gomobile build input"):
            self.record()
        (self.products / "compiled-bridge.sha256").unlink()
        with self.assertRaises(FileNotFoundError):
            self.record()

    def test_legacy_checkout_only_manifest_cannot_stamp_prepared_source(self):
        manifest = self.record()
        manifest.pop("compiledBridgeSha256", None)
        with self.assertRaisesRegex(ValueError, "prepared Alpha source"):
            core.verify_prepared_source(manifest, self.root, manifest["sourceCommit"], self.framework)

    def test_stamped_install_requires_approved_slices_and_strict_mode_despite_recipe_drift(self):
        self.freeze_synthetic_slices()
        prepared, commit, recipe, launch = self.git_snapshot()
        bundle = self.root / "AccessKit.framework"
        bundle.mkdir()
        binary = self.framework / "ios-arm64" / core.FRAMEWORK_NAME / core.CORE_NAME
        frozen = binary.read_bytes()
        original_recipe = recipe.read_bytes()
        changed_recipe = original_recipe.replace(b"bytes.fromhex(sys.argv[2])", b"b'changed compiler output'")
        self.assertNotEqual(changed_recipe, original_recipe)
        for reproduction in ("clean ci-rebuild", "locally edited recipe", "recipe switched during build"):
            with self.subTest(reproduction=reproduction):
                command = [sys.executable, "-B", str(recipe), str(binary), frozen.hex()]
                if reproduction == "clean ci-rebuild":
                    subprocess.run(command, check=True, timeout=5)
                    self.assertEqual(binary.read_bytes(), frozen)
                elif reproduction == "locally edited recipe":
                    recipe.write_bytes(changed_recipe)
                    subprocess.run(command, check=True, timeout=5)
                else:
                    recipe.write_bytes(original_recipe)
                    with subprocess.Popen([sys.executable, "-B", str(launch), *command[2:]], stdin=subprocess.PIPE,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as child:
                        try:
                            self.assertTrue(select.select([child.stdout], [], [], 5)[0])
                            self.assertEqual(child.stdout.readline(), "ready\n")
                            recipe.write_bytes(changed_recipe)
                            _, stderr = child.communicate("build\n", timeout=5)
                            self.assertEqual(child.returncode, 0, stderr)
                        finally:
                            if child.poll() is None:
                                child.kill()
                    recipe.write_bytes(original_recipe)
                    self.assertEqual(subprocess.check_output([*self.git, "diff", "HEAD", "--", "scripts"]), b"")
                self.assertEqual(subprocess.check_output([*self.git, "rev-parse", "HEAD"], text=True).strip(), commit)
                self.assertEqual(subprocess.check_output([*self.git, "diff", "HEAD", "--", "apps/ios"]), b"")
                if reproduction != "clean ci-rebuild":
                    self.assertEqual(binary.read_bytes(), b"changed compiler output")
                rebuilt = self.record(commit=commit)
                ordinary = self.install(bundle)
                self.assertEqual(ordinary.returncode, 0, ordinary.stderr)
                self.assertEqual(json.loads((bundle / "embedded-core-build.json").read_bytes()), rebuilt)
                for child in bundle.iterdir():
                    child.unlink()
                stamped = self.install(bundle, prepared, commit)
                self.assertNotEqual(stamped.returncode, 0)
                self.assertIn("requires a strict EmbeddedCore build", stamped.stderr)
                self.assertEqual(list(bundle.iterdir()), [])
                if reproduction != "clean ci-rebuild":
                    core.write_json(self.products / "build-manifest.json", dict(rebuilt, digestMode="strict"))
                    stamped = self.install(bundle, prepared, commit)
                    self.assertNotEqual(stamped.returncode, 0)
                    self.assertIn("frozen digests", stamped.stderr)
                    self.assertEqual(list(bundle.iterdir()), [])
        binary.write_bytes(frozen)
        accepted = self.record("strict", commit=commit)
        for substitution in (dict(accepted, sourceCommit="b" * 40),
                             {key: value for key, value in accepted.items() if key != "compiledBridgeSha256"}):
            core.write_json(self.products / "build-manifest.json", substitution)
            self.assertNotEqual(self.install(bundle, prepared, commit).returncode, 0)
            self.assertEqual(list(bundle.iterdir()), [])
        routing = self.framework / "Info.plist"
        layout = plistlib.loads(routing.read_bytes())
        layout["AvailableLibraries"][0]["BinaryPath"] = "Alternate.framework/Alternate"
        routing.write_bytes(plistlib.dumps(layout, sort_keys=True))
        self.record("strict", commit=commit)  # Unchanged, frozen slice digests alone are insufficient.
        diverted = self.install(bundle, prepared, commit)
        self.assertNotEqual(diverted.returncode, 0)
        self.assertIn("frozen Alpha layout", diverted.stderr)
        self.assertEqual(list(bundle.iterdir()), [])
        routing.write_bytes(plistlib.dumps(core.normalized_xcframework_info(), sort_keys=True))
        self.record("strict", commit=commit)
        stamped = self.install(bundle, prepared, commit)
        self.assertEqual(stamped.returncode, 0, stamped.stderr)
        self.assertEqual((bundle / "embedded-core-build.json").read_bytes(), (self.products / "build-manifest.json").read_bytes())
        self.assertEqual((bundle / "embedded-core-lock.json").read_bytes(), (self.products / "embedded-core-lock.json").read_bytes())

    def test_install_refuses_receipts_swapped_after_verification(self):
        self.record()
        verified = core.verify(self.root, self.lock, self.products)
        bundle = self.root / "AccessKit.framework"
        bundle.mkdir()
        for name in ("build-manifest.json", "embedded-core-lock.json"):
            path = self.products / name
            original = path.read_bytes()
            path.write_bytes(original + b"\n")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "changed during installation"):
                core.install_verified_receipts(self.products, bundle, verified)
            self.assertEqual(list(bundle.iterdir()), [])
            path.write_bytes(original)

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
        linked.assert_called_once_with(app, self.products, self.root / "DerivedData", "simulator", owned_linker_paths=False)
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
