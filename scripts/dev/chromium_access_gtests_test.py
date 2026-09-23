#!/usr/bin/env python3
import os
import json
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True

import chromium_access_gtests as sut


class ChromiumAccessGTestsRunnerTests(unittest.TestCase):
    def test_product_commit_during_admission_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            product = Path(root)
            sut.git(product, "init", "-q")
            sut.git(product, "config", "user.name", "Fixture")
            sut.git(product, "config", "user.email", "fixture@example.invalid")
            file = product / "overlay"
            file.write_text("A")
            sut.git(product, "add", ".")
            sut.git(product, "commit", "-qm", "A")
            original_git = sut.git

            def repo_git(repo, *args, **kwargs):
                if repo == product:
                    return original_git(repo, *args, **kwargs)
                return "head"
            mutated = False

            def mutate_product(*_args):
                nonlocal mutated
                if not mutated:
                    file.write_text("B")
                    original_git(product, "add", ".")
                    original_git(product, "commit", "-qm", "B")
                    mutated = True
                return "tree"
            with mock.patch.object(sut, "ROOT", product), \
                    mock.patch.object(sut, "require_clean"), \
                    mock.patch.object(sut, "git", side_effect=repo_git), \
                    mock.patch.object(sut, "is_ancestor", return_value=True), \
                    mock.patch.object(sut, "verify_tree", side_effect=mutate_product):
                with self.assertRaisesRegex(ValueError, "product HEAD changed during source admission"):
                    sut.verify_sources(Path("/candidate"))
            self.assertTrue(mutated)

    def test_command_boundary_rejects_shell_strings_and_unsafe_executables(self):
        with tempfile.TemporaryDirectory() as root:
            not_executable = Path(root) / "data"
            not_executable.write_text("not a tool")
            for command in ("echo unsafe", [], ["python", "-V"], [str(not_executable)],
                            [sys.executable, "null\0byte"], [sys.executable, 1]):
                with self.subTest(command=command), self.assertRaises(ValueError):
                    sut.command_argv(command)
            marker = Path(root) / "must-not-exist"
            payload = f"$(touch {marker}); `touch {marker}`"
            result = sut.run_process([sys.executable, "-c", "import sys; print(sys.argv[1])", payload])
            self.assertEqual(result.stdout.strip(), payload)
            self.assertFalse(marker.exists())

    def test_disk_space_rejects_before_generation(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            options = sut.parser().parse_args([])
            with mock.patch.object(sut, "verify_sources", return_value={}), \
                    mock.patch.object(sut.shutil, "disk_usage", return_value=mock.Mock(free=0)):
                with self.assertRaisesRegex(ValueError, "not enough free space"):
                    sut.prepare_build(options, root / "src", root, {})

    def test_nonancestor_pin_rejects_before_patch_verification(self):
        with mock.patch.object(sut, "require_clean"), \
                mock.patch.object(sut, "git", return_value="head"), \
                mock.patch.object(sut, "is_ancestor", return_value=False), \
                mock.patch.object(sut, "verify_tree") as replay:
            with self.assertRaisesRegex(ValueError, "not an ancestor"):
                sut.verify_sources(Path("/candidate"))
        replay.assert_not_called()

    def test_chromium_overlay_preserves_v8_gitlink(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            repo, patches, overlay = (root / n for n in ("repo", "patches", "overlay"))
            for directory in (repo, patches, overlay):
                directory.mkdir()
            sut.git(repo, "init", "-q")
            sut.git(repo, "config", "user.name", "Fixture")
            sut.git(repo, "config", "user.email", "fixture@example.invalid")
            (repo / "source").write_text("base\n")
            sut.git(repo, "add", ".")
            sut.git(repo, "commit", "-qm", "base")
            v8 = sut.git(repo, "rev-parse", "HEAD")
            sut.git(repo, "update-index", "--add", "--cacheinfo", f"160000,{v8},v8")
            sut.git(repo, "commit", "-qm", "v8 link")
            base = sut.git(repo, "rev-parse", "HEAD")
            (repo / "source").write_text("patched\n")
            (patches / "a.patch").write_text(sut.git(repo, "diff", "--", "source") + "\n")
            (patches / "series").write_text("a.patch\n")
            (overlay / "v8").mkdir()
            (overlay / "v8/source").write_text("v8 overlay\n")
            tree = sut.replay_tree(repo, base, patches, overlay)
            self.assertEqual(sut.git(repo, "ls-tree", tree, "v8"), f"160000 commit {v8}\tv8")

    def test_real_patch_overlay_identity_rejects_drift_and_extra_files(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            repo, patches, overlay = (root / n for n in ("repo", "patches", "overlay"))
            for directory in (repo, patches, overlay):
                directory.mkdir()
            sut.git(repo, "init", "-q")
            sut.git(repo, "config", "user.name", "Fixture")
            sut.git(repo, "config", "user.email", "fixture@example.invalid")
            source = repo / "source.txt"
            source.write_text("base\n")
            sut.git(repo, "add", ".")
            sut.git(repo, "commit", "-qm", "base")
            base = sut.git(repo, "rev-parse", "HEAD")
            source.write_text("patched\n")
            (patches / "a.patch").write_text(sut.git(repo, "diff") + "\n")
            (patches / "series").write_text("a.patch\n")
            (overlay / "source.txt").write_text("overlay\n")
            (overlay / "extra.txt").write_text("added by overlay\n")
            expected = sut.replay_tree(repo, base, patches, overlay)
            source.write_text("overlay\n")
            (repo / "extra.txt").write_text("added by overlay\n")
            sut.git(repo, "add", ".")
            sut.git(repo, "commit", "-qm", "composed")
            self.assertEqual(sut.verify_tree(repo, base, patches, overlay), expected)
            sut.require_clean(repo, "fixture")
            source.write_text("dirty\n")
            with self.assertRaisesRegex(ValueError, "dirty"):
                sut.require_clean(repo, "fixture")
            sut.git(repo, "checkout", "--", "source.txt")
            (repo / "unexpected.txt").write_text("untracked\n")
            with self.assertRaisesRegex(ValueError, "dirty"):
                sut.require_clean(repo, "fixture")
            sut.git(repo, "add", ".")
            sut.git(repo, "commit", "-qm", "unexpected")
            with self.assertRaisesRegex(ValueError, "does not match"):
                sut.verify_tree(repo, base, patches, overlay)

    def test_failure_command_keeps_exit_and_raw_output(self):
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "command.log"
            with self.assertRaises(subprocess.CalledProcessError):
                sut.run_logged([sys.executable, "-c", "print('failure'); exit(7)"],
                               cwd=Path(root), env=dict(os.environ), log=log)
            self.assertIn("failure", log.read_text())
            self.assertEqual(json.loads(log.with_suffix(".log.json").read_text())["exitCode"], 7)

    def test_admission_failure_writes_full_not_run_matrix(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "src").mkdir()
            (root / "src/BUILD.gn").write_text("")
            report = root / "report"
            options = sut.parser().parse_args(["--report-dir", str(report), "--min-free-gib", "1"])
            with mock.patch.object(sut, "resolve_chromium_root", return_value=root), \
                    mock.patch.object(sut, "require_clean", side_effect=ValueError("dirty")):
                with self.assertRaisesRegex(ValueError, "dirty"):
                    sut.execute(options)
            result = json.loads((report / "result.json").read_text())
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual(len(result["targets"]), 17)
            self.assertTrue(all(t["result"] == "NOT_RUN" for t in result["targets"]))
            self.assertFalse((root / ".aegis-access-gtest-lock").exists())

    def test_failed_gn_retains_primary_and_post_source_failure(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "src").mkdir()
            (root / "src/BUILD.gn").write_text("")
            report = root / "report"
            options = sut.parser().parse_args(["--report-dir", str(report), "--min-free-gib", "1"])
            failure = subprocess.CalledProcessError(7, ["fake-gn"], output="original GN diagnostic")
            with mock.patch.object(sut, "resolve_chromium_root", return_value=root), \
                    mock.patch.object(sut, "require_clean"), \
                    mock.patch.object(sut, "git", return_value="h"), \
                    mock.patch.object(sut, "is_ancestor", return_value=True), \
                    mock.patch.object(sut, "verify_tree", return_value="tree"), \
                    mock.patch.object(sut, "tool", return_value="/usr/bin/false"), \
                    mock.patch.object(sut, "run_logged", side_effect=failure), \
                    mock.patch.object(sut, "verify_stable", side_effect=ValueError("source mutated")) as stable:
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    sut.execute(options)
            self.assertEqual(caught.exception.returncode, 7)
            stable.assert_called_once()
            result = json.loads((report / "result.json").read_text())
            self.assertFalse(result["sourceStable"])
            self.assertIn("source mutated", result["stabilityError"])
            self.assertIn("original GN diagnostic", (report / "failure.log").read_text())

    def test_record_error_preserves_git_stdout_and_stderr(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "failure.log"
            error = subprocess.CalledProcessError(1, ["git", "apply"],
                                                 output="patch does not apply", stderr="specific.cc:7")
            sut.record_error(error, path)
            self.assertIn("patch does not apply", path.read_text())
            self.assertIn("specific.cc:7", path.read_text())
            self.assertEqual(json.loads(path.with_suffix(".log.json").read_text())["exitCode"], 1)

    def test_target_inventory_is_complete_and_unique(self):
        self.assertEqual(len(sut.TARGETS), 17)
        labels = [item[0] for item in sut.TARGETS]
        binaries = [item[2] for item in sut.TARGETS]
        self.assertEqual(len(labels), len(set(labels)))
        self.assertEqual(len(binaries), len(set(binaries)))
        self.assertIn(
            "//chrome/browser/aegis/access:access_service_coordinator_unittests",
            labels,
        )
        self.assertIn(
            "//chrome/browser/aegis/access:access_network_context_transport_unittests",
            labels,
        )
        self.assertIn("//components/aegis_access:aegis_access_unittests", labels)

    def test_count_gtests_counts_only_test_rows(self):
        listing = """SuiteOne.
  First
  Second
SuiteTwo/Variant.
  Third/0  # GetParam() = 1
"""
        self.assertEqual(sut.count_gtests(listing), 3)

    def test_series_rejects_duplicate_and_unsafe_paths(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            (directory / "a.patch").write_text("patch", encoding="utf-8")
            (directory / "series").write_text("a.patch\na.patch\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicated"):
                sut.series(directory)

            (directory / "series").write_text("../a.patch\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unsafe"):
                sut.series(directory)

    def test_verify_tree_requires_exact_replayed_tree(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            patches = directory / "patches"
            patches.mkdir()
            (patches / "series").write_text("a.patch\n", encoding="utf-8")
            (patches / "a.patch").write_text("patch", encoding="utf-8")

            def fake_git(_repo, *args, env=None):
                del env
                if args == ("status", "--porcelain"):
                    return ""
                if args == ("write-tree",):
                    return "expected-tree"
                if args == ("rev-parse", "HEAD^{tree}"):
                    return "expected-tree"
                return ""

            with mock.patch.object(sut, "git", side_effect=fake_git):
                self.assertEqual(
                    sut.verify_tree(directory, "base", patches),
                    "expected-tree",
                )

            def mismatched_git(_repo, *args, env=None):
                del env
                if args == ("write-tree",):
                    return "expected-tree"
                if args == ("rev-parse", "HEAD^{tree}"):
                    return "other-tree"
                return ""

            with mock.patch.object(sut, "git", side_effect=mismatched_git):
                with self.assertRaisesRegex(ValueError, "does not match"):
                    sut.verify_tree(directory, "base", patches)

    def test_run_target_builds_lists_and_executes_without_retry(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            src = base / "src"
            out = base / "out"
            report = base / "report"
            src.mkdir()
            out.mkdir()
            report.mkdir()

            autoninja = base / "autoninja"
            autoninja.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            autoninja.chmod(0o755)

            binary = out / "fake_unittests"
            trace = base / "trace.txt"
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import os, sys\n"
                "if '--gtest_list_tests' in sys.argv:\n"
                "    print('FakeSuite.')\n"
                "    print('  First')\n"
                "    print('  Second')\n"
                "    raise SystemExit(0)\n"
                "with open(os.environ['AEGIS_TEST_TRACE'], 'w', encoding='utf-8') as f:\n"
                "    f.write(' '.join(sys.argv[1:]))\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            env = dict(os.environ, AEGIS_TEST_TRACE=str(trace))

            context = sut.TargetContext(src, out, report, env, str(autoninja), 3)
            result = sut.run_target(
                ("//fake:fake_unittests", "fake:fake_unittests", "fake_unittests"), context)

            self.assertEqual(result["tests"], 2)
            self.assertEqual(result["result"], "PASS")
            invocation = trace.read_text(encoding="utf-8")
            self.assertIn("--test-launcher-jobs=3", invocation)
            self.assertIn("--test-launcher-retry-limit=0", invocation)
            self.assertTrue((report / "fake_unittests.build.log").is_file())
            self.assertTrue((report / "fake_unittests.list.log").is_file())
            self.assertTrue((report / "fake_unittests.test.log").is_file())
            binary.write_text(binary.read_text() + "\nraise SystemExit(7)\n")
            row = {}
            with self.assertRaises(subprocess.CalledProcessError):
                sut.run_target(("//fake:fake_unittests", "fake:fake_unittests", "fake_unittests"),
                               context, evidence=row)
            self.assertEqual(row["tests"], 2)
            self.assertEqual(row["binarySha256"], sut.sha256(binary))
            self.assertEqual(row["build"], "PASS")
            self.assertEqual(row["listing"], "PASS")

    def test_acquire_lock_rejects_candidate_or_parallel_run(self):
        with tempfile.TemporaryDirectory() as root:
            parent = Path(root)
            src = parent / "src"
            src.mkdir()

            candidate = parent / ".aegis-ci-lock"
            candidate.mkdir()
            with self.assertRaisesRegex(ValueError, "candidate build"):
                sut.acquire_lock(src)
            candidate.rmdir()

            lock = sut.acquire_lock(src)
            try:
                with self.assertRaisesRegex(ValueError, "already active"):
                    sut.acquire_lock(src)
            finally:
                lock.rmdir()


if __name__ == "__main__":
    unittest.main()
