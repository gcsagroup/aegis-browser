"""Disposable tests for unsigned CI placement and retained archive evidence."""
import hashlib
import importlib.util
import io
import json
import os
import pwd
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/ci/ios-ci-storage.py"


class WorkflowStorageTests(unittest.TestCase):
    def test_unsigned_archive_uses_admitted_storage_and_retains_archive_manifest(self):
        workflow = (ROOT / ".github/workflows/ios-release-validation.yml").read_text()
        self.assertNotIn('-derivedDataPath "$RUNNER_TEMP/DerivedData"', workflow)
        self.assertIn("scripts/ci/ios-ci-storage.py prepare", workflow)
        self.assertIn("scripts/ci/ios-ci-storage.py seal", workflow)
        self.assertIn("Aegis.xcarchive.zip", workflow)
        self.assertIn("unsigned-artifact.json", workflow)


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HELPER.is_file(), "unsigned CI storage helper is missing")
        spec = importlib.util.spec_from_file_location("ios_ci_storage", HELPER)
        self.storage = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.storage)
        fixture_root = ROOT / ".artifacts/ios-ci-storage-fixtures"
        fixture_root.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="aegis-storage-", dir=fixture_root)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.volume = self.root / "External Fixture Volume"
        self.volume.mkdir()
        self.config = self.root / "host.json"
        self.identity = {"schema_version": 1, "mount_point": str(self.volume),
                         "volume_uuid": "11111111-2222-4333-8444-555555555555",
                         "runner_roots": {"fixture-mac": "gcsa-ci/aegis/slot-fixture"}}
        self.write_identity()
        self.info = {"MountPoint": str(self.volume), "VolumeUUID": self.identity["volume_uuid"],
                     "FilesystemType": "apfs", "GlobalPermissionsEnabled": True,
                     "Internal": False, "Writable": True}
        self.repo = self.root / "source"
        self.repo.mkdir()
        (self.repo / "README").write_text("disposable source\n")
        (self.repo / ".gitignore").write_text(".artifacts/\nnode_modules/\n*.local\n")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
        head = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        self.temp = self.root / "runner-temp"
        self.temp.mkdir()
        self.environment = {"GITHUB_WORKSPACE": str(self.repo), "GITHUB_SHA": head,
                            "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
                            "GITHUB_JOB": "ios-archive", "RUNNER_TEMP": str(self.temp)}
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(self.storage, "volume_info", return_value=self.info).start()
        mock.patch.object(self.storage, "available_bytes", return_value=100 * 2**30).start()

    def write_identity(self):
        self.config.write_text(json.dumps(self.identity))
        self.config.chmod(0o600)

    def prepare(self, runner_environment="self-hosted", **environment):
        return self.storage.prepare({**self.environment, **environment}, runner_environment,
                                    "fixture-mac", config_path=self.config)

    def artifact_snapshot(self):
        seed = self.volume / "gcsa-ci/aegis/slot-fixture/artifact-seed-v1"
        artifacts = seed / "artifacts"
        artifacts.mkdir(parents=True, mode=0o700)
        payload = artifacts / "https___fixture_invalid_package_zip"
        payload.write_bytes(b"disposable archive bytes")
        payload.chmod(0o400)
        catalog = {"schema_version": 1, "artifacts": [{"name": payload.name,
                   "bytes": payload.stat().st_size,
                   "sha256": hashlib.sha256(payload.read_bytes()).hexdigest()}]}
        manifest = seed / "manifest.json"
        manifest.write_text(json.dumps(catalog))
        manifest.chmod(0o600)
        return seed, payload, manifest, catalog

    def test_snapshot_archives_are_private_copies_with_digest_receipts(self):
        seed, payload, manifest, _ = self.artifact_snapshot()
        first, second = self.prepare(), self.prepare()
        copied = first / "PackageCache/artifacts" / payload.name
        other = second / "PackageCache/artifacts" / payload.name
        self.assertEqual(copied.read_bytes(), payload.read_bytes())
        self.assertEqual(other.read_bytes(), payload.read_bytes())
        self.assertEqual(len({payload.stat().st_ino, copied.stat().st_ino, other.stat().st_ino}), 3)
        copied.write_bytes(b"one job changed its own cache")
        self.assertEqual(other.read_bytes(), payload.read_bytes())
        receipt = json.loads((first / "storage-receipt.json").read_text())
        self.assertEqual(receipt["artifact_seed_sha256"], hashlib.sha256(manifest.read_bytes()).hexdigest())
        self.assertEqual(receipt["seed_artifact_count"], 1)
        self.assertNotIn(str(seed), json.dumps(receipt))

    def test_snapshot_digest_size_and_writable_payload_are_denied(self):
        _, payload, manifest, catalog = self.artifact_snapshot()
        for fault in ("digest", "size", "writable"):
            changed = json.loads(json.dumps(catalog))
            if fault == "digest":
                changed["artifacts"][0]["sha256"] = "0" * 64
            elif fault == "size":
                changed["artifacts"][0]["bytes"] += 1
            payload.chmod(0o600 if fault == "writable" else 0o400)
            manifest.write_text(json.dumps(changed))
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                self.prepare()
        self.assertEqual(list(self.temp.iterdir()), [])

    def test_snapshot_symlink_hardlink_and_unlisted_payloads_are_denied(self):
        _, payload, _, _ = self.artifact_snapshot()
        raw = payload.read_bytes()
        elsewhere = self.root / "retained.zip"
        elsewhere.write_bytes(raw)
        elsewhere.chmod(0o400)
        payload.unlink()
        payload.symlink_to(elsewhere)
        with self.assertRaises(ValueError):
            self.prepare()
        payload.unlink()
        os.link(elsewhere, payload)
        with self.assertRaises(ValueError):
            self.prepare()
        payload.unlink()
        payload.write_bytes(raw)
        payload.chmod(0o400)
        (payload.parent / "unlisted").write_bytes(b"unlisted archive")
        with self.assertRaises(ValueError):
            self.prepare()

    def test_snapshot_catalog_rejects_names_duplicates_and_unbounded_sizes(self):
        _, _, manifest, original = self.artifact_snapshot()
        variants = []
        for name in ("../escape", "/absolute", "with/slash"):
            catalog = json.loads(json.dumps(original))
            catalog["artifacts"][0]["name"] = name
            variants.append(catalog)
        variants.append({**original, "artifacts": original["artifacts"] * 2})
        for size in (True, 0, 512 * 2**20 + 1):
            catalog = json.loads(json.dumps(original))
            catalog["artifacts"][0]["bytes"] = size
            variants.append(catalog)
        for catalog in variants:
            manifest.write_text(json.dumps(catalog))
            with self.subTest(catalog=catalog), self.assertRaises(ValueError):
                self.prepare()

    def test_hosted_route_ignores_self_hosted_snapshot(self):
        _, _, manifest, _ = self.artifact_snapshot()
        manifest.write_text("invalid host snapshot")
        root = self.prepare("github-hosted")
        self.assertFalse((root / "PackageCache/artifacts").exists())

    def test_no_snapshot_retains_cold_cache_route(self):
        root = self.prepare()
        self.assertEqual(list((root / "PackageCache").iterdir()), [])
        receipt = json.loads((root / "storage-receipt.json").read_text())
        self.assertIsNone(receipt["artifact_seed_sha256"])
        self.assertEqual(receipt["seed_artifact_count"], 0)

    def test_snapshot_special_files_are_rejected_without_waiting_for_a_writer(self):
        _, payload, manifest, _ = self.artifact_snapshot()
        raw = payload.read_bytes()
        payload.unlink()
        os.mkfifo(payload, 0o400)
        with self.assertRaises(ValueError):
            self.prepare()
        payload.unlink()
        payload.write_bytes(raw)
        payload.chmod(0o400)
        manifest.unlink()
        os.mkfifo(manifest, 0o600)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_snapshot_foreign_device_and_payload_acl_are_denied(self):
        _, payload, _, _ = self.artifact_snapshot()
        original_fstat = os.fstat
        inode = payload.stat().st_ino
        def foreign_device(descriptor):
            info = original_fstat(descriptor)
            if info.st_ino != inode:
                return info
            fields = {key: getattr(info, key) for key in dir(info) if key.startswith("st_")}
            return SimpleNamespace(**{**fields, "st_dev": info.st_dev + 1})
        with mock.patch.object(self.storage.os, "fstat", side_effect=foreign_device):
            with self.assertRaises(ValueError):
                self.prepare()
        original_acl = self.storage.acl_entries
        with mock.patch.object(self.storage, "acl_entries", side_effect=lambda path:
                               ["0: everyone allow read"] if Path(path) == payload else original_acl(path)):
            with self.assertRaises(ValueError):
                self.prepare()

    def test_snapshot_copy_rechecks_free_space_before_admission(self):
        self.artifact_snapshot()
        with mock.patch.object(self.storage, "available_bytes", side_effect=[100 * 2**30, 19 * 2**30]):
            with self.assertRaisesRegex(ValueError, "capacity"):
                self.prepare()

    def test_doctor_verifies_snapshot_without_creating_a_job(self):
        seed, payload, manifest, _ = self.artifact_snapshot()
        before = payload.read_bytes()
        output = io.StringIO()
        with mock.patch.object(self.storage, "CONFIG", self.config), mock.patch.object(
                self.storage.sys, "argv", [str(HELPER), "doctor", "--runner-name", "fixture-mac"]):
            with redirect_stdout(output):
                self.storage.main()
        receipt = json.loads(output.getvalue())
        self.assertEqual(receipt["seed_artifact_count"], 1)
        self.assertEqual(receipt["artifact_seed_sha256"], hashlib.sha256(manifest.read_bytes()).hexdigest())
        self.assertFalse((seed.parent / "jobs").exists())
        self.assertEqual(payload.read_bytes(), before)

    def test_external_names_and_uuids_come_only_from_host_enrollment(self):
        first = self.prepare()
        second = self.prepare()
        self.assertTrue(Path(first).is_relative_to(self.volume))
        self.assertNotEqual(first, second)
        self.assertEqual(list(self.temp.iterdir()), [])
        receipt = json.loads((first / "storage-receipt.json").read_text())
        self.assertEqual(receipt["enrollment_sha256"], hashlib.sha256(self.config.read_bytes()).hexdigest())
        self.assertNotIn("volume_uuid", receipt)
        self.assertNotIn("mount_point", receipt)
        self.assertEqual(receipt["source_sha"], self.environment["GITHUB_SHA"])

    def test_job_HOME_cannot_select_a_different_host_enrollment(self):
        spec = importlib.util.spec_from_file_location("storage_home_override", HELPER)
        module = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, {"HOME": str(self.root / "job-selected-home")}):
            spec.loader.exec_module(module)
        expected = Path(pwd.getpwuid(os.getuid()).pw_dir) / ".config/gcsa-ci/aegis-volume-identity.json"
        self.assertEqual(module.CONFIG, expected)

    def test_hosted_fallback_never_reads_self_hosted_enrollment(self):
        self.config.unlink()
        with mock.patch.object(self.storage, "available_bytes", return_value=14 * 2**30):
            root = self.prepare("github-hosted")
        self.assertTrue(root.is_relative_to(self.temp))
        self.storage.volume_info.assert_not_called()

    def test_unenrolled_runner_does_not_fall_back_to_internal_temp(self):
        self.identity["runner_roots"] = {"another-runner": "gcsa-ci/aegis/other"}
        self.write_identity()
        with self.assertRaisesRegex(ValueError, "runner"):
            self.prepare()
        self.assertEqual(list(self.temp.iterdir()), [])

    def test_wrong_uuid_internal_volume_owners_and_read_only_are_denied(self):
        for change in [{"VolumeUUID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"},
                       {"Internal": True}, {"GlobalPermissionsEnabled": False}, {"Writable": False}]:
            with self.subTest(change=change), mock.patch.object(self.storage, "volume_info", return_value={**self.info, **change}):
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertEqual(list(self.temp.iterdir()), [])

    def test_low_capacity_is_denied_before_job_creation(self):
        with mock.patch.object(self.storage, "available_bytes", return_value=19 * 2**30):
            with self.assertRaisesRegex(ValueError, "capacity"):
                self.prepare()
        self.assertFalse((self.volume / "gcsa-ci").exists())

    def test_symlink_and_traversing_cache_roots_are_denied(self):
        for relative in ["../outside", "/absolute", "gcsa-ci/../outside"]:
            self.identity["runner_roots"]["fixture-mac"] = relative
            self.write_identity()
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                self.prepare()
        self.identity["runner_roots"]["fixture-mac"] = "linked/slot"
        self.write_identity()
        (self.volume / "linked").symlink_to(self.temp, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.prepare()

    def test_nonprivate_or_symlink_host_config_is_denied(self):
        self.config.chmod(0o644)
        with self.assertRaises(ValueError):
            self.prepare()
        self.config.chmod(0o600)
        original = self.config.with_suffix(".original")
        self.config.rename(original)
        self.config.symlink_to(original)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_invalid_run_metadata_and_wrong_source_fail_before_job_creation(self):
        for change in [{"GITHUB_RUN_ID": "../escape"}, {"GITHUB_JOB": "with\nnewline"},
                       {"GITHUB_SHA": "f" * 40}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.prepare(**change)
        self.assertFalse((self.volume / "gcsa-ci").exists())

    def test_tracked_source_drift_and_overlapping_runner_caches_are_denied(self):
        (self.repo / "README").write_text("uncommitted drift\n")
        with self.assertRaisesRegex(ValueError, "source"):
            self.prepare()
        (self.repo / "README").write_text("disposable source\n")
        self.identity["runner_roots"]["another-mac"] = "gcsa-ci/aegis/slot-fixture/nested"
        self.write_identity()
        with self.assertRaisesRegex(ValueError, "overlap"):
            self.prepare()

    def test_case_equivalent_runner_caches_are_denied(self):
        self.identity["runner_roots"] = {"fixture-mac": "ci/Slot", "other-mac": "CI/slot"}
        self.write_identity()
        with self.assertRaisesRegex(ValueError, "overlap"):
            self.prepare()

    def test_artifact_glob_characters_in_host_paths_fail_before_build(self):
        for relative in ("cache/slot[2026]", "cache/slot*", "cache/slot?", "cache/{slot}", "cache/(slot)", "cache/!slot"):
            self.identity["runner_roots"]["fixture-mac"] = relative
            self.write_identity()
            with self.subTest(relative=relative), self.assertRaisesRegex(ValueError, "artifact-glob"):
                self.prepare()
        self.identity["runner_roots"]["fixture-mac"] = "gcsa-ci/aegis/slot-fixture"
        renamed = self.volume.with_name("External Fixture [2026]")
        self.volume.rename(renamed)
        self.volume = renamed
        self.identity["mount_point"] = str(renamed)
        self.info["MountPoint"] = str(renamed)
        self.write_identity()
        with self.assertRaisesRegex(ValueError, "artifact-glob"):
            self.prepare()

    def test_hosted_temp_globs_are_rejected_before_creating_job_data(self):
        renamed = self.temp.with_name("runner [temp]")
        self.temp.rename(renamed)
        with self.assertRaisesRegex(ValueError, "artifact-glob"):
            self.prepare("github-hosted", RUNNER_TEMP=str(renamed))
        self.assertEqual(list(renamed.iterdir()), [])

    def test_hosted_temp_controls_cannot_inject_output_records(self):
        renamed = self.temp.with_name("runner\ninjected")
        self.temp.rename(renamed)
        with self.assertRaisesRegex(ValueError, "control"):
            self.prepare("github-hosted", RUNNER_TEMP=str(renamed))
        self.assertEqual(list(renamed.iterdir()), [])

    def test_untracked_resource_cannot_acquire_a_clean_source_manifest(self):
        (self.repo / "untracked-resource").write_text("not in the source tree\n")
        with self.assertRaisesRegex(ValueError, "source"):
            self.prepare()

    def test_source_workspace_must_be_absolute_canonical_and_without_controls(self):
        alias = self.root / "source-alias"
        alias.symlink_to(self.repo, target_is_directory=True)
        for workspace in (str(alias), str(self.repo / ".." / "source")):
            with self.subTest(workspace=workspace), self.assertRaisesRegex(ValueError, "workspace"):
                self.storage.source_metadata({**self.environment, "GITHUB_WORKSPACE": workspace})
        previous = Path.cwd()
        try:
            os.chdir(self.root)
            with self.assertRaisesRegex(ValueError, "workspace"):
                self.storage.source_metadata({**self.environment, "GITHUB_WORKSPACE": "source"})
        finally:
            os.chdir(previous)
        renamed = self.repo.with_name("source\ncontrol")
        self.repo.rename(renamed)
        with self.assertRaisesRegex(ValueError, "workspace"):
            self.storage.source_metadata({**self.environment, "GITHUB_WORKSPACE": str(renamed)})

    def fsmonitor_hook(self):
        hook = self.root / "fsmonitor-fixture"
        hook.write_text('#!/bin/sh\n: > "$0.ran"\n')
        hook.chmod(0o700)
        return hook, Path(str(hook) + ".ran")

    def test_inherited_git_configuration_cannot_execute_fsmonitor(self):
        hook, marker = self.fsmonitor_hook()
        global_config = self.root / "global-git-config-fixture"
        global_config.write_text('[core]\nfsmonitor = "' + str(hook) + '"\n')
        variants = (
            {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": str(hook)},
            {"GIT_CONFIG_PARAMETERS": "'core.fsmonitor=" + str(hook) + "'"},
            {"GIT_CONFIG_GLOBAL": str(global_config)},
        )
        for variables in variants:
            marker.unlink(missing_ok=True)
            with self.subTest(variables=tuple(variables)), mock.patch.dict(os.environ, variables):
                self.storage.source_metadata(self.environment)
                self.assertFalse(marker.exists(), "source verification executed inherited Git configuration")

    def test_local_git_configuration_cannot_execute_fsmonitor(self):
        hook, marker = self.fsmonitor_hook()
        subprocess.run(["/usr/bin/git", "-C", str(self.repo), "config", "core.fsmonitor", str(hook)], check=True)
        self.storage.source_metadata(self.environment)
        self.assertFalse(marker.exists(), "source verification executed a repository-local fsmonitor")

    def test_source_workspace_shell_characters_are_literal_data(self):
        renamed = self.repo.with_name("source ; touch shell-marker ; #")
        self.repo.rename(renamed)
        result = self.storage.source_metadata({**self.environment, "GITHUB_WORKSPACE": str(renamed)})
        self.assertEqual(result["source_sha"], self.environment["GITHUB_SHA"])
        self.assertFalse((self.root / "shell-marker").exists())

    def test_ignored_build_resource_is_denied_but_generated_evidence_is_allowed(self):
        generated = self.repo / ".artifacts/build.local"
        generated.parent.mkdir()
        generated.write_text("generated evidence outside product inputs\n")
        self.prepare()
        resource = self.repo / "apps/ios/Resources/untracked.local"
        resource.parent.mkdir(parents=True)
        resource.write_text("ignored file copied into product resources\n")
        with self.assertRaisesRegex(ValueError, "source"):
            self.prepare()

    def test_changed_enrollment_cannot_seal_a_prepared_job(self):
        root = self.prepare()
        self.identity["volume_uuid"] = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        self.write_identity()
        with self.assertRaises(ValueError):
            self.storage.seal(root, self.environment)
        self.assertFalse((root / "Aegis.xcarchive.zip").exists())

    def test_archive_symlinks_cannot_export_files_outside_the_archive(self):
        root = self.prepare()
        archive = root / "Aegis.xcarchive"
        archive.mkdir()
        outside = self.root / "unrelated-private-fixture"
        outside.write_text("synthetic private data")
        (archive / "escape").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.storage.seal(root, self.environment)
        self.assertFalse((root / "Aegis.xcarchive.zip").exists())

    @unittest.skipUnless(os.uname().sysname == "Darwin", "native ACL fixture")
    def test_directory_acl_write_grant_is_denied(self):
        subprocess.run(["/bin/chmod", "+a", "user:nobody allow add_file", str(self.volume)], check=True)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-N", str(self.volume)], check=True)
        with self.assertRaisesRegex(ValueError, "ACL"):
            self.prepare()

    @unittest.skipUnless(os.uname().sysname == "Darwin", "native ACL fixture")
    def test_directory_acl_delete_grant_is_denied(self):
        subprocess.run(["/bin/chmod", "+a", "user:nobody allow delete", str(self.volume)], check=True)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-N", str(self.volume)], check=True)
        with self.assertRaisesRegex(ValueError, "ACL"):
            self.prepare()

    @unittest.skipUnless(os.uname().sysname == "Darwin", "native ACL/xattr fixture")
    def test_xattr_cannot_hide_private_file_acl_grants(self):
        subprocess.run(["/usr/bin/xattr", "-w", "com.example.aegis-storage-fixture", "fixture", str(self.config)], check=True)
        subprocess.run(["/bin/chmod", "+a", "user:nobody allow read,write", str(self.config)], check=True)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-N", str(self.config)], check=True)
        with self.assertRaisesRegex(ValueError, "ACL"):
            self.prepare()

    @unittest.skipUnless(os.uname().sysname == "Darwin", "native inherited ACL fixture")
    def test_inherited_acl_is_denied_before_creating_private_job_data(self):
        subprocess.run(["/bin/chmod", "+a", "user:nobody allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit",
                        str(self.volume)], check=True)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-RN", str(self.volume)], check=True)
        with self.assertRaisesRegex(ValueError, "ACL"):
            self.prepare()
        self.assertFalse((self.volume / "gcsa-ci").exists())

    @unittest.skipUnless(os.uname().sysname == "Darwin", "native non-inherited ACL fixture")
    def test_noninherited_directory_delete_denial_does_not_grant_access(self):
        subprocess.run(["/bin/chmod", "+a", "group:everyone deny delete", str(self.volume)], check=True)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-N", str(self.volume)], check=True)
        self.prepare()

    def test_jobs_on_a_different_device_are_denied_before_job_creation(self):
        jobs = self.volume / self.identity["runner_roots"]["fixture-mac"] / "jobs"
        original = Path.stat
        def changed_device(path, *args, **kwargs):
            info = original(path, *args, **kwargs)
            if path == jobs:
                fields = list(info); fields[2] += 1
                return os.stat_result(fields)
            return info
        with mock.patch.object(Path, "stat", changed_device), self.assertRaisesRegex(ValueError, "backing"):
            self.prepare()
        self.assertEqual(list(jobs.iterdir()), [])

    def test_final_job_device_is_checked_before_writing_private_state(self):
        jobs = self.volume / self.identity["runner_roots"]["fixture-mac"] / "jobs"
        original = Path.stat
        def changed_device(path, *args, **kwargs):
            info = original(path, *args, **kwargs)
            if path.parent == jobs:
                fields = list(info); fields[2] += 1
                return os.stat_result(fields)
            return info
        with mock.patch.object(Path, "stat", changed_device), self.assertRaisesRegex(ValueError, "backing"):
            self.prepare()
        roots = list(jobs.iterdir())
        self.assertEqual(len(roots), 1)
        self.assertEqual(list(roots[0].iterdir()), [])

    @unittest.skipUnless(os.uname().sysname == "Darwin", "native ditto archive fixture")
    def test_seal_retains_archive_digest_and_rechecks_source_binding(self):
        root = self.prepare()
        archive = root / "Aegis.xcarchive"
        archive.mkdir()
        (archive / "fixture").write_bytes(b"unsigned disposable archive")
        self.storage.seal(root, self.environment)
        receipt = json.loads((root / "unsigned-artifact.json").read_text())
        self.assertEqual(receipt["source_sha"], self.environment["GITHUB_SHA"])
        self.assertEqual(receipt["archive_sha256"], hashlib.sha256((root / "Aegis.xcarchive.zip").read_bytes()).hexdigest())
        self.assertIs(receipt["signed"], False)
        with self.assertRaisesRegex(ValueError, "source"):
            self.storage.seal(root, {**self.environment, "GITHUB_SHA": "f" * 40})


if __name__ == "__main__":
    unittest.main()
