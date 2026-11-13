"""Controlled localhost tests; never read operator credentials or a real panel."""
from contextlib import closing, redirect_stderr, redirect_stdout
import hashlib
import http.client
from http.server import ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
from tempfile import TemporaryDirectory
import threading
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

from services.access_account.tests.test_panel import PanelHandler, PREFIX, SETTINGS, traffic

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("alpha_runner", ROOT / "apps/ios/scripts/alpha-entitlement-runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class AlphaRunnerTest(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        os.chmod(self.root, 0o700)
        self.token = self.root / "panel-token"
        self.token.write_text("fixture-panel-key\n")
        self.token.chmod(0o600)
        self.receipt = self.root / "receipt.json"
        self.mock = ThreadingHTTPServer(("127.0.0.1", 0), PanelHandler)
        self.addCleanup(self.mock.server_close)
        worker = threading.Thread(target=self.mock.serve_forever, kwargs={"poll_interval": 0.01})
        worker.start()
        self.addCleanup(worker.join)
        self.addCleanup(self.mock.shutdown)
        row = traffic("fixture-alpha", 21, 34, 1000000000)
        row["expiryTime"] = 0
        self.mock.rows = {PREFIX + "fixture-alpha": row}
        self.mock.settings = {SETTINGS + "fixture-alpha": dict(row, totalGB=1000000000, trafficReset="never")}
        self.mock.paths, self.mock.status, self.mock.body, self.mock.during_read = [], 200, None, None
        self.args = ["--panel-url", f"http://127.0.0.1:{self.mock.server_port}/tenant",
                     "--panel-token-file", str(self.token), "--client-email", "fixture-alpha",
                     "--account-id", "fixture-account", "--output-receipt", str(self.receipt)]

    def run_runner(self, extra=(), child=None):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(runner, "run_child", side_effect=child, return_value=0) as run, \
                redirect_stdout(out), redirect_stderr(err):
            code = runner.main(self.args + list(extra) + ["--", "xcodebuild", "test"])
        self.assertNotIn("fixture-panel-key", out.getvalue() + err.getvalue())
        return code, run

    def test_private_token_permissions_symlink_parent_and_missing(self):
        for mode in (0o644, 0o400, 0o660):
            self.token.chmod(mode)
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                runner.private_token(self.token)
        self.token.chmod(0o600)
        self.assertEqual(runner.private_token(self.token), "fixture-panel-key")
        link = self.root / "link"
        link.symlink_to(self.token)
        with self.assertRaises(OSError):
            runner.private_token(link)
        self.root.chmod(0o750)
        try:
            with self.assertRaises(ValueError):
                runner.private_token(self.token)
        finally:
            self.root.chmod(0o700)
        with patch.object(runner.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(ValueError):
                runner.private_token(self.token)
        with self.assertRaises(OSError):
            runner.private_token(self.root / "absent")

    def test_child_env_hash_only_database_http_and_cleanup_with_nonzero_exit(self):
        databases, addresses = [], []
        original = runner.create_server

        def capture(database, **kwargs):
            databases.append(Path(database))
            return original(database, **kwargs)

        def child(command, env, seconds):
            self.assertEqual(command, ["xcodebuild", "test"])
            self.assertEqual(seconds, 1800)
            self.assertFalse(any("PANEL" in k or "3XUI" in k for k in env))
            self.assertNotIn("OTHER_PASSWORD", env)
            self.assertNotIn("BASH_ENV", env)
            self.assertNotIn("fixture-panel-key", env.values())
            token = env["TEST_RUNNER_AEGIS_ALPHA_TOKEN"]
            with closing(sqlite3.connect(databases[0])) as db:
                row = db.execute("SELECT token_hash, expires_at FROM sessions").fetchone()
                self.assertEqual(row[0], hashlib.sha256(token.encode()).digest())
                self.assertEqual(db.execute("SELECT panel_client FROM plans").fetchone()[0], "fixture-alpha")
            self.assertNotIn(token.encode(), databases[0].read_bytes())
            self.assertEqual(databases[0].stat().st_mode & 0o777, 0o600)
            self.assertEqual(databases[0].parent.stat().st_mode & 0o777, 0o700)
            origin = urlsplit(env["TEST_RUNNER_AEGIS_ALPHA_ORIGIN"])
            addresses.append((origin.hostname, origin.port))
            self.assertEqual(origin.hostname, "127.0.0.1")
            with closing(http.client.HTTPConnection(origin.hostname, origin.port, timeout=2)) as conn:
                conn.request("GET", "/v1/me/entitlement", headers={"Authorization": "Bearer " + token})
                response = conn.getresponse()
                self.assertEqual(response.status, 200)
                data = json.loads(response.read())
                self.assertEqual((data["quotaSource"], data["usedBytes"]), ("3xui_alpha", "55"))
            return 7

        with patch.object(runner, "create_server", side_effect=capture), patch.dict(os.environ, {
                "AEGIS_3XUI_TOKEN": "fixture-panel-key", "PANEL_TOKEN": "fixture-panel-key",
                "OTHER_PASSWORD": "secret", "BASH_ENV": "unsafe"}):
            code, _ = self.run_runner(child=child)
        self.assertEqual(code, 7)
        self.assertTrue(all(not p.parent.exists() for p in databases))
        with closing(http.client.HTTPConnection(*addresses[0], timeout=1)) as conn:
            with self.assertRaises(OSError):
                conn.connect()
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual((receipt["exitCode"], receipt["childExitCode"], receipt["stage"]), (7, 7, "completed"))
        self.assertEqual(set(receipt), {"schemaVersion", "kind", "startedAt", "finishedAt", "stage", "exitCode", "childExitCode"})
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o600)

    def test_missing_token_does_not_query_or_start_child(self):
        self.args[self.args.index("--panel-token-file") + 1] = str(self.root / "absent")
        code, child = self.run_runner()
        self.assertEqual(code, 3)
        child.assert_not_called()
        self.assertEqual(self.mock.paths, [])

    def test_wrong_client_response_fails_preflight_without_child(self):
        self.mock.rows[PREFIX + "fixture-alpha"]["email"] = "wrong-fixture-client"
        code, child = self.run_runner()
        self.assertEqual(code, 3)
        child.assert_not_called()
        self.assertEqual(json.loads(self.receipt.read_text())["stage"], "preflight")
        self.assertTrue(all(p.endswith("fixture-alpha") for p in self.mock.paths))

    def test_panel_failure_is_failfast_and_redacted(self):
        self.mock.status, self.mock.body = 503, b"private-panel-detail"
        code, child = self.run_runner()
        self.assertEqual(code, 3)
        child.assert_not_called()
        self.assertNotIn("private-panel-detail", self.receipt.read_text())

    def test_invalid_duration_no_network(self):
        code, child = self.run_runner(["--session-seconds", "59"])
        self.assertEqual(code, 3)
        child.assert_not_called()
        self.assertEqual(self.mock.paths, [])

    def test_timeout_cleanup_and_receipt(self):
        def child(*args):
            raise subprocess.TimeoutExpired("secret-command", 60)
        code, _ = self.run_runner(["--session-seconds", "60"], child)
        self.assertEqual(code, 124)
        self.assertEqual(json.loads(self.receipt.read_text())["stage"], "timeout")
        self.assertNotIn("secret-command", self.receipt.read_text())

    def test_receipt_overwrite_prevents_network(self):
        self.receipt.write_text("preserve")
        code, child = self.run_runner()
        self.assertEqual(code, 3)
        child.assert_not_called()
        self.assertEqual(self.mock.paths, [])
        self.assertEqual(self.receipt.read_text(), "preserve")

    def test_upper_duration_bound_and_success(self):
        code, child = self.run_runner(["--session-seconds", "3601"])
        self.assertEqual(code, 3)
        child.assert_not_called()
        self.assertEqual(self.mock.paths, [])

    def test_success_keeps_receipt_secret_free(self):
        code, child = self.run_runner(["--session-seconds", "3600"])
        self.assertEqual(code, 0)
        self.assertEqual(child.call_args.args[2], 3600)
        data = json.loads(self.receipt.read_text())
        self.assertEqual((data["stage"], data["childExitCode"]), ("completed", 0))
        self.assertGreaterEqual(data["finishedAt"], data["startedAt"])
        self.assertNotIn("fixture-alpha", self.receipt.read_text())
        self.assertNotIn("fixture-panel-key", self.receipt.read_text())

    def test_interruption_is_redacted(self):
        def child(*args):
            raise KeyboardInterrupt
        code, _ = self.run_runner(child=child)
        self.assertEqual(code, 130)
        self.assertEqual(json.loads(self.receipt.read_text())["stage"], "interrupted")

    def test_real_child_output_is_not_forwarded(self):
        code = runner.run_child(["/bin/sh", "-c", "printf 'secret'; printf 'secret' >&2; exit 9"],
                                {"PATH": "/usr/bin:/bin"}, 60)
        self.assertEqual(code, 9)


if __name__ == "__main__":
    unittest.main()
