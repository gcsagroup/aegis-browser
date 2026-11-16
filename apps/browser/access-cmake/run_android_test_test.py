"""Offline runner checks. The only child process is a temporary fake adb."""

import contextlib
import json
import os
from pathlib import Path
import subprocess  # nosec B404 - exception types and a mock around the fake-adb boundary only.
import sys
import tempfile
import unittest
from unittest import mock

import run_android_test as runner


FAKE_ADB = """
import json, os, sys
args = sys.argv[1:]
with open(os.environ['AEGIS_FAKE_ADB_LOG'], 'a', encoding='utf-8') as log:
    log.write(json.dumps({'args': args, 'serial': os.environ.get('ANDROID_SERIAL')}) + '\\n')
if args[:1] == ['-s']:
    args = args[2:]
if args == ['get-serialno']:
    print(os.environ.get('ANDROID_SERIAL', 'unknown'))
elif args == ['shell', 'getprop', 'ro.product.cpu.abilist']:
    print('arm64-v8a,armeabi-v7a')
elif args == ['shell', 'getprop', 'ro.build.version.sdk']:
    print('35')
elif args[:2] == ['shell', 'mktemp']:
    print(os.environ.get('AEGIS_FAKE_ADB_DIRECTORY', '/data/local/tmp/aegis-access.Abc123'))
elif args[:1] == ['push'] and os.environ.get('AEGIS_FAKE_ADB_FAILURE') == 'push':
    sys.exit(7)
elif args[:2] == ['shell', 'chmod'] and os.environ.get('AEGIS_FAKE_ADB_FAILURE') == 'chmod':
    sys.exit(8)
elif len(args) == 2 and args[0] == 'shell' and args[1].endswith('/contract'):
    if os.environ.get('AEGIS_FAKE_ADB_BLOCK_CONTRACT') == '1':
        import time
        time.sleep(60)
    sys.exit(9 if os.environ.get('AEGIS_FAKE_ADB_FAILURE') == 'contract' else 0)
"""


@unittest.skipIf(os.name == "nt", "The fake adb fixture uses a POSIX shebang")
class AndroidRunnerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="aegis adb fixture ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.executable = self.root / "Android SDK" / "platform-tools" / "adb"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_text(f"#!{sys.executable}\n" + FAKE_ADB, encoding="utf-8")
        self.executable.chmod(0o700)
        self.log = self.root / "adb.jsonl"
        self.binary = self.root / "contract $(touch INJECTED); literal"
        self.binary.write_bytes(b"Android ELF fixture; never run on the host")
        environment = mock.patch.dict(os.environ, {
            "ADB": str(self.executable), "ANDROID_SERIAL": "emulator-5554",
            "AEGIS_FAKE_ADB_LOG": str(self.log), "AEGIS_FAKE_ADB_FAILURE": "",
            "AEGIS_FAKE_ADB_BLOCK_CONTRACT": "0",
            "AEGIS_FAKE_ADB_DIRECTORY": "/data/local/tmp/aegis-access.Abc123",
        })
        environment.start()
        self.addCleanup(environment.stop)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def test_real_argv_preserves_sdk_spaces_serial_binary_metacharacters_and_cleanup(self):
        with contextlib.chdir(self.root):
            runner.main(Path(self.binary.name), "arm64-v8a", 24)
        calls = self.calls()
        self.assertEqual(calls[0]["args"], ["get-serialno"])
        self.assertTrue(all(call["serial"] == "emulator-5554" for call in calls))
        self.assertTrue(all(call["args"][:2] == ["-s", "emulator-5554"] for call in calls[1:]))
        destination = "/data/local/tmp/aegis-access.Abc123/contract"
        self.assertEqual(calls[4]["args"], ["-s", "emulator-5554", "push", str(self.binary), destination])
        self.assertEqual(calls[-1]["args"], ["-s", "emulator-5554", "shell", "rm", "-rf",
                                              "/data/local/tmp/aegis-access.Abc123"])
        self.assertFalse((self.root / "INJECTED").exists())

    def test_path_lookup_and_explicit_sdk_override_resolve_the_same_adb(self):
        expected = runner.Adb().executable
        with mock.patch.dict(os.environ, {"ADB": "adb", "PATH": str(self.executable.parent)}):
            self.assertEqual(runner.Adb().executable, expected)
            runner.Adb().run("version")
        self.assertEqual(self.calls()[0]["args"], ["version"])

    def test_rejects_other_executables_shell_commands_and_adb_symlinks_to_other_tools(self):
        for configured in (sys.executable, "/bin/sh", "adb --serial unsafe", ""):
            with self.subTest(configured=configured), mock.patch.dict(os.environ, {"ADB": configured}):
                with self.assertRaises(ValueError):
                    runner.Adb()
        self.executable.unlink()
        self.executable.symlink_to(sys.executable)
        with self.assertRaises(ValueError):
            runner.Adb()
        self.assertFalse(self.log.exists())

    def test_missing_nonexecutable_adb_and_nonfile_binary_fail_before_device_contact(self):
        self.executable.chmod(0o600)
        with self.assertRaises(ValueError):
            runner.Adb()
        self.executable.unlink()
        with self.assertRaises(ValueError):
            runner.Adb()
        with self.assertRaises(ValueError):
            runner.main(self.root, "arm64-v8a", 24)
        self.assertFalse(self.log.exists())

    def test_command_configuration_is_frozen_and_shell_or_timeout_overrides_are_rejected(self):
        adb = runner.Adb()
        with mock.patch.dict(os.environ, {"ADB": "/bin/sh"}):
            adb.run("version")
        for args in (("null\0byte",), (1,)):
            with self.assertRaises(ValueError):
                adb.run(*args)
        for options in ({"shell": True}, {"timeout": None}, {"check": False}):
            with self.assertRaises(TypeError):
                adb.run("version", **options)
        self.assertEqual(len(self.calls()), 1)

    def test_remote_directory_injection_is_rejected_before_push_execute_or_cleanup(self):
        for directory in ("/data/local/tmp/aegis-access.ok; touch INJECTED",
                          "/data/local/tmp/aegis-access.ok/../../escape", "-rf /", ""):
            with self.subTest(directory=directory), mock.patch.dict(os.environ, {"AEGIS_FAKE_ADB_DIRECTORY": directory}):
                self.log.unlink(missing_ok=True)
                with self.assertRaisesRegex(RuntimeError, "Unexpected test directory"):
                    runner.main(self.binary, "arm64-v8a", 24)
                self.assertEqual(len(self.calls()), 4)

    def test_abi_api_and_missing_serial_fail_before_remote_allocation(self):
        for abi, minimum, serial in (("x86_64", 24, "emulator-5554"),
                                    ("arm64-v8a", 36, "emulator-5554"), ("arm64-v8a", 24, "unknown")):
            with self.subTest(abi=abi, minimum=minimum, serial=serial), mock.patch.dict(os.environ, {"ANDROID_SERIAL": serial}):
                self.log.unlink(missing_ok=True)
                with self.assertRaises(RuntimeError):
                    runner.main(self.binary, abi, minimum)
                self.assertLessEqual(len(self.calls()), 3)

    def test_push_chmod_and_contract_failures_still_cleanup_and_keep_the_exit_status(self):
        for operation, status in (("push", 7), ("chmod", 8), ("contract", 9)):
            with self.subTest(operation=operation), mock.patch.dict(os.environ, {"AEGIS_FAKE_ADB_FAILURE": operation}):
                self.log.unlink(missing_ok=True)
                with self.assertRaises(subprocess.CalledProcessError) as failure:
                    runner.main(self.binary, "arm64-v8a", 24)
                self.assertEqual(failure.exception.returncode, status)
                self.assertEqual(self.calls()[-1]["args"][-4:], ["shell", "rm", "-rf", "/data/local/tmp/aegis-access.Abc123"])

    def test_contract_timeout_is_bounded_and_still_cleanup(self):
        real_run = runner.subprocess.run
        fixture_timeout = 2

        def run(argv, **options):
            self.assertFalse(options["shell"])
            self.assertTrue(options["check"])
            self.assertEqual(options["timeout"], 25)
            if argv[-2:] == ["shell", "/data/local/tmp/aegis-access.Abc123/contract"]:
                options["timeout"] = fixture_timeout
            return real_run(argv, **options)

        with mock.patch.dict(os.environ, {"AEGIS_FAKE_ADB_BLOCK_CONTRACT": "1"}), \
                mock.patch.object(runner.subprocess, "run", side_effect=run):
            with self.assertRaises(subprocess.TimeoutExpired) as failure:
                runner.main(self.binary, "arm64-v8a", 24)
        self.assertGreater(failure.exception.timeout, 0)
        self.assertLessEqual(failure.exception.timeout, fixture_timeout)
        self.assertEqual(self.calls()[-2]["args"][-2:], ["shell", "/data/local/tmp/aegis-access.Abc123/contract"])
        self.assertEqual(self.calls()[-1]["args"][-4:], ["shell", "rm", "-rf", "/data/local/tmp/aegis-access.Abc123"])


if __name__ == "__main__":
    unittest.main()
